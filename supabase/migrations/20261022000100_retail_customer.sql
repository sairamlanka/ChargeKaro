-- Retail (customer) app: guest discovery, slot grids, customer booking views,
-- consents, customer reports, account deletion requests and the customer
-- message outbox (SMS / email; WhatsApp reserved).
--
-- Guests browse without an account. Everything a guest can call is a
-- read-only SECURITY DEFINER function that returns public station data only
-- (no customer data, no internal ids of people). anon still has no table
-- access. A customer account is created by Supabase phone-OTP sign-in when a
-- guest decides to book (handle_new_auth_user creates the profile), so the
-- booking itself still goes through create_booking_hold → payments-create-order
-- → payments-verify.

-------------------------------------------------------------------------------
-- Profile additions
-------------------------------------------------------------------------------

alter table public.profiles
  add column receipt_email text check (receipt_email is null or receipt_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column notification_prefs jsonb not null default '{"reminders": true, "email_receipts": true, "push": true}'::jsonb
    check (jsonb_typeof(notification_prefs) = 'object');

comment on column public.profiles.receipt_email is
  'Optional address for booking receipts, given by the customer while booking. Not an auth identity and not verified.';
comment on column public.profiles.notification_prefs is
  'Customer message preferences. Transactional messages (confirmation, cancellation, refund) are always sent when a channel exists.';

grant update (receipt_email, notification_prefs) on public.profiles to authenticated;

-------------------------------------------------------------------------------
-- Arrival rules and finer slots
-------------------------------------------------------------------------------

-- Customers are asked to reach the station a few minutes before the start,
-- and the point is held only briefly after it (then released as a no-show).
-- A 15-minute grid lets 30, 45, 60 ... minute bookings share points.
alter table public.station_booking_policies
  add column report_before_minutes int not null default 5 check (report_before_minutes between 0 and 60);
alter table public.station_booking_policies
  alter column slot_duration_minutes set default 15,
  alter column arrival_grace_minutes set default 5;

comment on column public.station_booking_policies.report_before_minutes is
  'Customers are asked to arrive this many minutes before the start. Shown to the customer; check-in itself opens early_checkin_minutes before.';
comment on column public.station_booking_policies.arrival_grace_minutes is
  'The point is held this long after the start. After it, an unchecked-in booking becomes a no-show and the point is released.';

-------------------------------------------------------------------------------
-- Public visibility helpers
-------------------------------------------------------------------------------

-- A station guests may see: approved and open, or approved and temporarily
-- closed (shown as closed), with an active business.
create or replace function private.is_public_station(p_station uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.stations s join public.businesses b on b.id = s.business_id
     where s.id = p_station and s.status in ('active', 'temporarily_closed') and b.status = 'active');
$$;

-- Straight-line (great-circle) distance in kilometres.
create or replace function private.distance_km(p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round((2 * 6371 * asin(sqrt(
    power(sin(radians((p_lat2 - p_lat1)::float8) / 2), 2) +
    cos(radians(p_lat1::float8)) * cos(radians(p_lat2::float8)) * power(sin(radians((p_lng2 - p_lng1)::float8) / 2), 2)
  )))::numeric, 2);
$$;

-- Why a station is not bookable right now, or null when it is.
create or replace function private.station_unavailable_reason(p_station uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when s.status = 'temporarily_closed' or (s.closed_until is not null and s.closed_until > now()) then 'temporarily_closed'
    when s.status <> 'active' or b.status <> 'active' then 'not_accepting_bookings'
    when not exists (select 1 from public.charging_points p
                      where p.station_id = s.id and p.archived_at is null and p.booking_enabled
                        and p.operational_status in ('available', 'in_use')) then 'no_bookable_points'
  end
  from public.stations s join public.businesses b on b.id = s.business_id
  where s.id = p_station;
$$;

create or replace function private.point_unavailable_reason(p_point public.charging_points)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when not p_point.booking_enabled then 'booking_disabled'
    when p_point.operational_status in ('maintenance') then 'maintenance'
    when p_point.operational_status in ('out_of_service', 'disabled') then 'out_of_service'
  end;
$$;

-------------------------------------------------------------------------------
-- Slot grid
-------------------------------------------------------------------------------

-- Slot cells for one point between p_from and p_to, aligned to the station's
-- slot length in station-local time. Only cells inside the station's opening
-- hours are returned.
--
-- state: past | unavailable | closed | blocked | booked | reserved |
--        too_soon | too_far | available
-- can_start: a minimum-length booking may start here (all rules that
-- assert_bookable checks, plus the station buffer against other bookings).
-- This is advisory: create_booking_hold re-checks atomically.
create or replace function private.point_cells(
  p_point uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_first_free_only boolean default false
)
returns table (start_at timestamptz, end_at timestamptz, state text, can_start boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_point public.charging_points;
  v_station public.stations;
  v_policy public.station_booking_policies;
  v_business_status public.business_status;
  v_tz text;
  v_slot interval;
  v_min interval;
  v_buf interval;
  v_now timestamptz := now();
  v_unbookable boolean;
  v_point_has_hours boolean;
  v_cursor timestamptz;
  v_end timestamptz;
  v_min_end timestamptz;
  v_local timestamp;
  v_local_end timestamp;
  v_dow int;
  v_smin int;
  v_emin int;
  v_emin2 int;
  v_state text;
  v_can boolean;
begin
  select * into v_point from public.charging_points where id = p_point and archived_at is null;
  if not found then
    return;
  end if;
  select * into v_station from public.stations where id = v_point.station_id;
  select status into v_business_status from public.businesses where id = v_station.business_id;
  select * into v_policy from public.station_booking_policies where station_id = v_station.id;
  v_tz := v_station.timezone;
  v_slot := make_interval(mins => v_policy.slot_duration_minutes);
  v_min := make_interval(mins => v_policy.min_booking_minutes);
  v_buf := make_interval(mins => v_policy.buffer_minutes);
  v_unbookable := v_station.status <> 'active' or v_business_status <> 'active'
                  or not v_point.booking_enabled or v_point.operational_status not in ('available', 'in_use');
  v_point_has_hours := exists (select 1 from public.station_operating_hours h where h.charging_point_id = p_point);

  v_cursor := (date_trunc('day', p_from at time zone v_tz)) at time zone v_tz;
  while v_cursor < p_to loop
    v_end := v_cursor + v_slot;
    if v_end <= p_from then
      v_cursor := v_end;
      continue;
    end if;

    v_local := v_cursor at time zone v_tz;
    v_local_end := v_end at time zone v_tz;
    v_dow := extract(isodow from v_local)::int;
    v_smin := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
    v_emin := case when v_local_end::date = v_local::date
                   then extract(hour from v_local_end)::int * 60 + extract(minute from v_local_end)::int
                   else 1440 end;

    if exists (select 1 from public.station_operating_hours h
                where h.station_id = v_station.id and h.charging_point_id is null and h.day_of_week = v_dow
                  and h.opens_minute <= v_smin and h.closes_minute >= v_emin) then
      v_can := false;
      v_state := case
        when v_cursor < v_now then 'past'
        when v_unbookable then 'unavailable'
        when v_station.closed_until is not null and v_cursor < v_station.closed_until then 'closed'
        when v_point_has_hours and not exists (
               select 1 from public.station_operating_hours h
                where h.charging_point_id = p_point and h.day_of_week = v_dow
                  and h.opens_minute <= v_smin and h.closes_minute >= v_emin) then 'closed'
        when exists (select 1 from public.blocked_periods bp
                      where bp.station_id = v_station.id and bp.cancelled_at is null
                        and (bp.charging_point_id is null or bp.charging_point_id = p_point)
                        and bp.period && tstzrange(v_cursor, v_end, '[)')) then 'blocked'
        when exists (select 1 from public.bookings b
                      where b.charging_point_id = p_point and b.status in ('confirmed', 'arrived', 'in_progress')
                        and b.occupancy && tstzrange(v_cursor, v_end, '[)')) then 'booked'
        when exists (select 1 from public.bookings b
                      where b.charging_point_id = p_point and b.status = 'payment_pending' and b.hold_expires_at > v_now
                        and b.occupancy && tstzrange(v_cursor, v_end, '[)')) then 'reserved'
        when v_cursor < v_now + make_interval(mins => v_policy.min_advance_minutes) then 'too_soon'
        when v_cursor > v_now + make_interval(days => v_policy.max_advance_days) then 'too_far'
        else 'available'
      end;

      if v_state = 'available' then
        v_min_end := v_cursor + v_min;
        v_local_end := v_min_end at time zone v_tz;
        if v_local_end::date = v_local::date then
          v_emin2 := extract(hour from v_local_end)::int * 60 + extract(minute from v_local_end)::int;
        elsif v_local_end = (v_local::date + 1)::timestamp then
          v_emin2 := 1440;
        else
          v_emin2 := null;
        end if;
        v_can := v_emin2 is not null
          and exists (select 1 from public.station_operating_hours h
                       where h.station_id = v_station.id and h.charging_point_id is null and h.day_of_week = v_dow
                         and h.opens_minute <= v_smin and h.closes_minute >= v_emin2)
          and (not v_point_has_hours or exists (
                select 1 from public.station_operating_hours h
                 where h.charging_point_id = p_point and h.day_of_week = v_dow
                   and h.opens_minute <= v_smin and h.closes_minute >= v_emin2))
          and not exists (select 1 from public.blocked_periods bp
                           where bp.station_id = v_station.id and bp.cancelled_at is null
                             and (bp.charging_point_id is null or bp.charging_point_id = p_point)
                             and bp.period && tstzrange(v_cursor, v_min_end + v_buf, '[)'))
          and not exists (select 1 from public.bookings b
                           where b.charging_point_id = p_point
                             and (b.status in ('confirmed', 'arrived', 'in_progress')
                                  or (b.status = 'payment_pending' and b.hold_expires_at > v_now))
                             and b.occupancy && tstzrange(v_cursor, v_min_end + v_buf, '[)'));
      end if;

      if not p_first_free_only then
        start_at := v_cursor; end_at := v_end; state := v_state; can_start := v_can;
        return next;
      elsif v_can then
        start_at := v_cursor; end_at := v_end; state := v_state; can_start := v_can;
        return next;
        return;
      end if;
    end if;
    v_cursor := v_end;
  end loop;
end;
$$;

-- Earliest bookable start across a station's points within the horizon.
create or replace function private.station_next_free(p_station uuid, p_horizon interval default interval '48 hours')
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('start_at', c.start_at, 'charging_point_id', p.id, 'charging_point_code', p.code)
    from public.charging_points p
    cross join lateral private.point_cells(p.id, now(), now() + p_horizon, true) c
   where p.station_id = p_station and p.archived_at is null and p.booking_enabled
     and p.operational_status in ('available', 'in_use')
   order by c.start_at, p.code
   limit 1;
$$;

-------------------------------------------------------------------------------
-- Public projections
-------------------------------------------------------------------------------

create or replace function private.station_hours_json(p_station uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('day', h.day_of_week, 'opens', h.opens_minute, 'closes', h.closes_minute)
                            order by h.day_of_week, h.opens_minute), '[]'::jsonb)
    from public.station_operating_hours h
   where h.station_id = p_station and h.charging_point_id is null;
$$;

-- Open now, and today's closing time, in station-local time.
create or replace function private.station_open_state(p_station uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with s as (
    select st.id, st.status, st.closed_until, (now() at time zone st.timezone) as local_now
      from public.stations st where st.id = p_station
  ), m as (
    select s.*, extract(isodow from s.local_now)::int as dow,
           (extract(hour from s.local_now) * 60 + extract(minute from s.local_now))::int as minute
      from s
  )
  select jsonb_build_object(
    'open_now', m.status = 'active' and (m.closed_until is null or m.closed_until <= now())
                and exists (select 1 from public.station_operating_hours h
                             where h.station_id = m.id and h.charging_point_id is null and h.day_of_week = m.dow
                               and h.opens_minute <= m.minute and h.closes_minute > m.minute),
    'closes_minute', (select min(h.closes_minute) from public.station_operating_hours h
                       where h.station_id = m.id and h.charging_point_id is null and h.day_of_week = m.dow
                         and h.opens_minute <= m.minute and h.closes_minute > m.minute),
    'opens_next_minute', (select min(h.opens_minute) from public.station_operating_hours h
                           where h.station_id = m.id and h.charging_point_id is null and h.day_of_week = m.dow
                             and h.opens_minute > m.minute)
  )
  from m;
$$;

create or replace function private.public_point_json(p_point public.charging_points)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_point.id,
    'code', p_point.code,
    'name', p_point.name,
    'current_type', p_point.current_type,
    'max_power_kw', p_point.max_power_kw,
    'vehicle_compatibility', to_jsonb(p_point.vehicle_compatibility),
    'operational_status', p_point.operational_status,
    'status_source', p_point.status_source,
    'status_updated_at', p_point.status_updated_at,
    'bookable', private.point_unavailable_reason(p_point) is null,
    'unavailable_reason', private.point_unavailable_reason(p_point),
    'restrictions_note', p_point.restrictions_note,
    'max_booking_minutes', least(pol.max_booking_minutes, coalesce(p_point.max_booking_minutes_override, pol.max_booking_minutes)),
    'connectors', coalesce((select jsonb_agg(jsonb_build_object('number', c.connector_number, 'type', c.connector_type,
                                                                 'max_power_kw', coalesce(c.max_power_kw, p_point.max_power_kw))
                                             order by c.connector_number)
                              from public.charging_connectors c where c.charging_point_id = p_point.id), '[]'::jsonb)
  )
  from public.station_booking_policies pol where pol.station_id = p_point.station_id;
$$;

-- Card-level summary of a station, as shown in search results.
create or replace function private.public_station_summary(p_station uuid, p_lat numeric default null, p_lng numeric default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', s.id,
    'name', s.name,
    'operator_name', coalesce(b.display_name, b.legal_name),
    'address_line1', s.address_line1,
    'address_line2', s.address_line2,
    'landmark', s.landmark,
    'city', s.city,
    'district', s.district,
    'state', s.state,
    'postal_code', s.postal_code,
    'latitude', s.latitude,
    'longitude', s.longitude,
    'timezone', s.timezone,
    'distance_km', case when p_lat is not null and p_lng is not null
                        then private.distance_km(p_lat, p_lng, s.latitude, s.longitude) end,
    'status', s.status,
    'closed_until', s.closed_until,
    'bookable', private.station_unavailable_reason(s.id) is null,
    'unavailable_reason', private.station_unavailable_reason(s.id),
    'amenities', to_jsonb(s.amenities),
    'accepted_payment_methods', to_jsonb(s.accepted_payment_methods),
    'parking_spaces', s.parking_spaces,
    'is_demo', b.is_demo,
    'points', jsonb_build_object(
      'total', (select count(*) from public.charging_points p where p.station_id = s.id and p.archived_at is null),
      'available', (select count(*) from public.charging_points p where p.station_id = s.id and p.archived_at is null
                       and p.operational_status = 'available' and p.booking_enabled),
      'in_use', (select count(*) from public.charging_points p where p.station_id = s.id and p.archived_at is null
                    and p.operational_status = 'in_use'),
      'unavailable', (select count(*) from public.charging_points p where p.station_id = s.id and p.archived_at is null
                         and (p.operational_status in ('maintenance', 'out_of_service', 'disabled') or not p.booking_enabled)),
      -- Statuses are entered by station staff unless status_source is telemetry.
      'status_source', (select case when bool_and(p.status_source = 'telemetry') then 'telemetry' else 'manual' end
                          from public.charging_points p where p.station_id = s.id and p.archived_at is null),
      'status_updated_at', (select max(p.status_updated_at) from public.charging_points p
                              where p.station_id = s.id and p.archived_at is null)
    ),
    'connector_types', coalesce((select jsonb_agg(distinct c.connector_type)
                                   from public.charging_connectors c join public.charging_points p on p.id = c.charging_point_id
                                  where p.station_id = s.id and p.archived_at is null), '[]'::jsonb),
    'current_types', coalesce((select jsonb_agg(distinct p.current_type) from public.charging_points p
                                where p.station_id = s.id and p.archived_at is null), '[]'::jsonb),
    'vehicle_types', coalesce((select jsonb_agg(distinct v) from public.charging_points p, unnest(p.vehicle_compatibility) v
                                where p.station_id = s.id and p.archived_at is null), '[]'::jsonb),
    'max_power_kw', (select max(p.max_power_kw) from public.charging_points p where p.station_id = s.id and p.archived_at is null),
    'hours', private.station_hours_json(s.id),
    'open', private.station_open_state(s.id),
    'booking_fee_paise', (private.setting('booking_fee_paise'))::bigint,
    'currency', 'INR'
  )
  from public.stations s join public.businesses b on b.id = s.business_id
  where s.id = p_station;
$$;

-------------------------------------------------------------------------------
-- Guest discovery RPCs (anon + authenticated)
-------------------------------------------------------------------------------

-- Stations within p_radius_km of a point, nearest first, each with its next
-- bookable start in the next 48 hours.
create or replace function public.search_stations(
  p_latitude numeric,
  p_longitude numeric,
  p_radius_km numeric default 5,
  p_limit int default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_radius numeric := coalesce(p_radius_km, 5);
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_dlat numeric;
  v_dlng numeric;
  v_rows jsonb;
  v_in_area boolean;
begin
  if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    perform private.raise_error(422, 'invalid_location', 'A valid latitude and longitude are required');
  end if;
  if v_radius < 0.5 or v_radius > 50 then
    perform private.raise_error(422, 'invalid_radius', 'Radius must be between 0.5 and 50 km');
  end if;
  -- The service currently covers India only (same bounds as station validation).
  v_in_area := p_latitude between 6.0 and 37.6 and p_longitude between 68.0 and 97.5;
  if not v_in_area then
    return jsonb_build_object('in_service_area', false, 'radius_km', v_radius, 'stations', '[]'::jsonb,
                              'generated_at', now());
  end if;

  v_dlat := v_radius / 111.0;
  v_dlng := v_radius / (111.0 * greatest(cos(radians(p_latitude::float8)), 0.01));

  select coalesce(jsonb_agg(private.public_station_summary(x.id, p_latitude, p_longitude)
                            || jsonb_build_object('next_available', private.station_next_free(x.id))
                            order by x.d, x.name), '[]'::jsonb)
    into v_rows
    from (
      select s.id, s.name, private.distance_km(p_latitude, p_longitude, s.latitude, s.longitude) as d
        from public.stations s join public.businesses b on b.id = s.business_id
       where s.status in ('active', 'temporarily_closed') and b.status = 'active'
         and s.latitude between p_latitude - v_dlat and p_latitude + v_dlat
         and s.longitude between p_longitude - v_dlng and p_longitude + v_dlng
    ) x
   where x.d <= v_radius
   limit v_limit;

  return jsonb_build_object('in_service_area', true, 'radius_km', v_radius, 'stations', v_rows, 'generated_at', now());
end;
$$;

-- Full public details of one station. Stations that are not public return a
-- minimal "not accepting bookings" record if they once existed (so a
-- recently viewed link explains itself) and 404 otherwise.
create or replace function public.get_public_station(p_station_id uuid, p_latitude numeric default null, p_longitude numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s public.stations;
  v_policy public.station_booking_policies;
  v_refund jsonb := private.setting('refund_policy');
begin
  select * into v_s from public.stations where id = p_station_id and status <> 'draft';
  if not found then
    perform private.raise_error(404, 'station_not_found');
  end if;
  if not private.is_public_station(p_station_id) then
    return jsonb_build_object('id', v_s.id, 'name', v_s.name, 'bookable', false,
                              'unavailable_reason', 'not_accepting_bookings', 'public', false);
  end if;
  select * into v_policy from public.station_booking_policies where station_id = p_station_id;

  return private.public_station_summary(p_station_id, p_latitude, p_longitude) || jsonb_build_object(
    'public', true,
    'description', v_s.description,
    'contact_phone', v_s.contact_phone,
    'points_detail', coalesce((select jsonb_agg(private.public_point_json(p) order by p.code)
                                 from public.charging_points p where p.station_id = p_station_id and p.archived_at is null), '[]'::jsonb),
    'policy', jsonb_build_object(
      'slot_duration_minutes', v_policy.slot_duration_minutes,
      'min_booking_minutes', v_policy.min_booking_minutes,
      'max_booking_minutes', v_policy.max_booking_minutes,
      'min_advance_minutes', v_policy.min_advance_minutes,
      'max_advance_days', v_policy.max_advance_days,
      'buffer_minutes', v_policy.buffer_minutes,
      'arrival_grace_minutes', v_policy.arrival_grace_minutes,
      'early_checkin_minutes', v_policy.early_checkin_minutes,
      'report_before_minutes', v_policy.report_before_minutes,
      'customer_cancel_until_minutes', v_policy.customer_cancel_until_minutes,
      'auto_no_show_enabled', v_policy.auto_no_show_enabled
    ),
    -- Upcoming whole-station closures (kind and time only; reasons stay internal).
    'closures', coalesce((select jsonb_agg(jsonb_build_object('starts_at', lower(bp.period), 'ends_at', upper(bp.period), 'kind', bp.kind)
                                           order by lower(bp.period))
                            from public.blocked_periods bp
                           where bp.station_id = p_station_id and bp.charging_point_id is null and bp.cancelled_at is null
                             and upper(bp.period) > now() and lower(bp.period) < now() + interval '30 days'), '[]'::jsonb),
    'refund_policy', jsonb_build_object(
      'customer_cancellation_refundable', (v_refund ->> 'customer_cancellation_refundable')::boolean,
      'customer_cancellation_cutoff_minutes', (v_refund ->> 'customer_cancellation_cutoff_minutes')::int,
      'business_cancellation_refundable', (v_refund ->> 'business_cancellation_refundable')::boolean,
      'late_payment_slot_lost_refundable', (v_refund ->> 'late_payment_slot_lost_refundable')::boolean,
      'policy_confirmed', (v_refund ->> 'policy_confirmed_for_production')::boolean
    ),
    'payment_hold_minutes', (private.setting('payment_hold_minutes'))::int,
    'next_available', private.station_next_free(p_station_id, make_interval(days => v_policy.max_advance_days))
  );
end;
$$;

-- Slot grid for every charging point of a station on one station-local date.
create or replace function public.get_station_slots(p_station_id uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_s public.stations;
  v_policy public.station_booking_policies;
  v_from timestamptz;
  v_to timestamptz;
  v_today date;
begin
  select * into v_s from public.stations where id = p_station_id;
  if not found or not private.is_public_station(p_station_id) then
    perform private.raise_error(404, 'station_not_found');
  end if;
  select * into v_policy from public.station_booking_policies where station_id = p_station_id;
  v_today := (now() at time zone v_s.timezone)::date;
  if p_date is null or p_date < v_today then
    perform private.raise_error(422, 'period_in_past', 'Choose today or a later date');
  end if;
  if p_date > v_today + v_policy.max_advance_days then
    perform private.raise_error(422, 'too_far_ahead', format('Book at most %s days ahead', v_policy.max_advance_days));
  end if;
  v_from := (p_date::timestamp) at time zone v_s.timezone;
  v_to := ((p_date + 1)::timestamp) at time zone v_s.timezone;

  return jsonb_build_object(
    'station_id', p_station_id,
    'date', p_date,
    'timezone', v_s.timezone,
    'generated_at', now(),
    'slot_minutes', v_policy.slot_duration_minutes,
    'min_booking_minutes', v_policy.min_booking_minutes,
    'buffer_minutes', v_policy.buffer_minutes,
    'booking_fee_paise', (private.setting('booking_fee_paise'))::bigint,
    'unavailable_reason', private.station_unavailable_reason(p_station_id),
    'points', coalesce((
      select jsonb_agg(private.public_point_json(p) || jsonb_build_object(
               'cells', coalesce((select jsonb_agg(jsonb_build_object('start_at', c.start_at, 'end_at', c.end_at,
                                                                      'state', c.state, 'can_start', c.can_start)
                                                   order by c.start_at)
                                    from private.point_cells(p.id, v_from, v_to) c), '[]'::jsonb))
             order by p.code)
        from public.charging_points p where p.station_id = p_station_id and p.archived_at is null), '[]'::jsonb)
  );
end;
$$;

-- Advisory re-check of one exact slot (summary screen). Never reserves.
create or replace function public.check_slot_availability(p_charging_point_id uuid, p_start_at timestamptz, p_end_at timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_station uuid;
  v_buffer int;
  v_code text;
begin
  select station_id into v_station from public.charging_points where id = p_charging_point_id;
  if v_station is null or not private.is_public_station(v_station) then
    perform private.raise_error(404, 'charging_point_not_found');
  end if;
  begin
    perform private.assert_bookable(p_charging_point_id, p_start_at, p_end_at);
  exception when sqlstate 'PT409' or sqlstate 'PT422' or sqlstate 'PT404' then
    get stacked diagnostics v_code = message_text;
    return jsonb_build_object('available', false, 'reason', v_code,
                              'booking_fee_paise', (private.setting('booking_fee_paise'))::bigint);
  end;
  select buffer_minutes into v_buffer from public.station_booking_policies where station_id = v_station;
  if exists (select 1 from public.bookings b
              where b.charging_point_id = p_charging_point_id
                and (b.status in ('confirmed', 'arrived', 'in_progress')
                     or (b.status = 'payment_pending' and b.hold_expires_at > now()))
                and b.occupancy && tstzrange(p_start_at, p_end_at + make_interval(mins => v_buffer), '[)')) then
    return jsonb_build_object('available', false, 'reason', 'slot_unavailable',
                              'booking_fee_paise', (private.setting('booking_fee_paise'))::bigint);
  end if;
  return jsonb_build_object('available', true, 'reason', null,
                            'booking_fee_paise', (private.setting('booking_fee_paise'))::bigint, 'checked_at', now());
end;
$$;

-- Areas (localities) that have public stations, matched by name, landmark,
-- city, district or PIN code. Works without any geocoding provider and is
-- merged with provider results by the app.
create or replace function public.search_areas(p_query text, p_limit int default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q text := lower(trim(coalesce(p_query, '')));
  v_like text;
begin
  if char_length(v_q) < 2 then
    perform private.raise_error(422, 'query_too_short', 'Type at least 2 characters');
  end if;
  v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return coalesce((
    select jsonb_agg(a order by a ->> 'rank', a ->> 'label')
      from (
        select jsonb_build_object(
                 'label', g.label,
                 'secondary', g.secondary,
                 'latitude', round(avg(g.latitude), 6),
                 'longitude', round(avg(g.longitude), 6),
                 'station_count', count(*),
                 'source', 'stations',
                 'rank', min(g.rank)) as a
          from (
            select s.latitude, s.longitude,
                   case when lower(s.postal_code) like v_like then s.postal_code || ', ' || s.city
                        when lower(coalesce(s.landmark, '')) like v_like then s.landmark
                        when lower(s.address_line1) like v_like or lower(s.name) like v_like then
                          coalesce(nullif(trim(split_part(s.address_line1, ',', 1)), ''), s.city)
                        when lower(s.district) like v_like and lower(s.city) not like v_like then s.district
                        else s.city end as label,
                   s.city || ', ' || s.state as secondary,
                   case when lower(s.postal_code) = v_q or lower(s.city) = v_q then '0' else '1' end as rank
              from public.stations s join public.businesses b on b.id = s.business_id
             where s.status in ('active', 'temporarily_closed') and b.status = 'active'
               and (lower(s.city) like v_like or lower(s.district) like v_like or lower(s.postal_code) like v_like
                    or lower(coalesce(s.landmark, '')) like v_like or lower(s.address_line1) like v_like
                    or lower(s.name) like v_like)
          ) g
         group by g.label, g.secondary
         limit least(greatest(coalesce(p_limit, 8), 1), 20)
      ) x), '[]'::jsonb);
end;
$$;

-- Version of the booking terms and privacy notice customers accept.
create or replace function private.current_terms_version()
returns text
language sql
immutable
set search_path = ''
as $$
  select '2026-10-22'::text;
$$;

-- Booking terms a guest sees before committing.
create or replace function public.get_booking_terms()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'booking_fee_paise', (private.setting('booking_fee_paise'))::bigint,
    'currency', 'INR',
    'taxes_included', true,
    'payment_hold_minutes', (private.setting('payment_hold_minutes'))::int,
    'refund_policy', jsonb_build_object(
      'customer_cancellation_refundable', (private.setting('refund_policy') ->> 'customer_cancellation_refundable')::boolean,
      'customer_cancellation_cutoff_minutes', (private.setting('refund_policy') ->> 'customer_cancellation_cutoff_minutes')::int,
      'business_cancellation_refundable', (private.setting('refund_policy') ->> 'business_cancellation_refundable')::boolean,
      'late_payment_slot_lost_refundable', (private.setting('refund_policy') ->> 'late_payment_slot_lost_refundable')::boolean,
      'policy_confirmed', (private.setting('refund_policy') ->> 'policy_confirmed_for_production')::boolean
    ),
    'terms_version', private.current_terms_version(),
    'privacy_version', private.current_terms_version(),
    -- Optional platform setting {"min_build": int, "maintenance": bool, "message": text}
    -- that lets the platform require an app update or show a maintenance notice.
    'app_status', private.setting('retail_app_status')
  );
$$;

-------------------------------------------------------------------------------
-- Consents (append-only)
-------------------------------------------------------------------------------

create table public.customer_consents (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  kind text not null check (kind in ('booking_terms', 'privacy_notice', 'marketing')),
  version text not null check (char_length(version) between 1 and 40),
  granted boolean not null,
  created_at timestamptz not null default now()
);

comment on table public.customer_consents is
  'Append-only consent history. Booking confirmations are never consent to marketing; marketing is its own row.';

create index customer_consents_user_idx on public.customer_consents (user_id, kind, created_at desc);
create trigger customer_consents_immutable before update or delete on public.customer_consents
  for each row execute function private.prevent_mutation();

alter table public.customer_consents enable row level security;
create policy customer_consents_select_own on public.customer_consents for select to authenticated
  using (user_id = (select auth.uid()));
create policy customer_consents_insert_own on public.customer_consents for insert to authenticated
  with check (user_id = (select auth.uid()));

-------------------------------------------------------------------------------
-- Customer message outbox (SMS / email; WhatsApp reserved for later)
-------------------------------------------------------------------------------

create type public.message_channel as enum ('sms', 'email', 'whatsapp');
create type public.message_status as enum ('pending', 'sending', 'sent', 'failed', 'skipped');

create table public.customer_messages (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  booking_id uuid references public.bookings (id) on delete cascade,
  channel public.message_channel not null,
  template text not null check (template in (
    'booking_confirmed', 'booking_cancelled', 'booking_reminder', 'slot_lost', 'refund_initiated', 'refund_processed')),
  destination text not null,
  payload jsonb not null default '{}'::jsonb,
  dedupe_key text not null unique,
  status public.message_status not null default 'pending',
  attempts int not null default 0,
  claimed_at timestamptz,
  sent_at timestamptz,
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.customer_messages is
  'Outbox of customer SMS/email. Delivery never affects booking status. "sent" means accepted by the provider, not delivered.';

create index customer_messages_queue_idx on public.customer_messages (created_at) where status in ('pending', 'sending');
create index customer_messages_booking_idx on public.customer_messages (booking_id, created_at);
create trigger customer_messages_updated_at before update on public.customer_messages
  for each row execute function private.set_updated_at();

alter table public.customer_messages enable row level security;

-- Booking details used in message templates (no internal ids).
create or replace function private.booking_message_payload(p_booking uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'reference', b.reference,
    'customer_name', p.full_name,
    'station_name', s.name,
    'station_address', concat_ws(', ', s.address_line1, s.address_line2, s.landmark, s.city, s.postal_code),
    'latitude', s.latitude,
    'longitude', s.longitude,
    'station_phone', s.contact_phone,
    'point_code', cp.code,
    'start_local', to_char(lower(b.period) at time zone s.timezone, 'Dy DD Mon YYYY, HH12:MI AM'),
    'end_local', to_char(upper(b.period) at time zone s.timezone, 'HH12:MI AM'),
    'duration_minutes', (extract(epoch from upper(b.period) - lower(b.period)) / 60)::int,
    'amount_paise', b.booking_fee_paise,
    'payment_status', b.payment_status,
    'payment_reference', (select pm.gateway_payment_id from public.payments pm
                           where pm.booking_id = b.id and pm.status = 'captured' order by pm.captured_at desc limit 1),
    'status', b.status,
    'cancellation_reason', b.cancellation_reason,
    'refund_eligible', b.refund_eligible,
    'refund_amount_paise', (select sum(r.amount_paise) from public.refunds r where r.booking_id = b.id)
  )
  from public.bookings b
  join public.stations s on s.id = b.station_id
  join public.charging_points cp on cp.id = b.charging_point_id
  join public.profiles p on p.id = b.customer_id
  where b.id = p_booking;
$$;

-- Queues SMS (to the verified phone) and email (to the receipt or auth
-- email) for a booking event. Missing channels are simply not queued.
create or replace function private.enqueue_booking_messages(p_booking uuid, p_template text, p_dedupe text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer uuid;
  v_profile public.profiles;
  v_payload jsonb;
  v_email text;
begin
  select customer_id into v_customer from public.bookings where id = p_booking;
  select * into v_profile from public.profiles where id = v_customer;
  if not found or v_profile.deleted_at is not null then
    return;
  end if;
  if p_template = 'booking_reminder' and coalesce((v_profile.notification_prefs ->> 'reminders')::boolean, true) = false then
    return;
  end if;
  v_payload := private.booking_message_payload(p_booking);
  if v_profile.phone is not null then
    insert into public.customer_messages (recipient_id, booking_id, channel, template, destination, payload, dedupe_key)
    values (v_customer, p_booking, 'sms', p_template, v_profile.phone, v_payload, 'sms:' || p_dedupe)
    on conflict (dedupe_key) do nothing;
  end if;
  v_email := coalesce(v_profile.receipt_email, v_profile.email);
  if v_email is not null and coalesce((v_profile.notification_prefs ->> 'email_receipts')::boolean, true) then
    insert into public.customer_messages (recipient_id, booking_id, channel, template, destination, payload, dedupe_key)
    values (v_customer, p_booking, 'email', p_template, v_email, v_payload, 'email:' || p_dedupe)
    on conflict (dedupe_key) do nothing;
  end if;
end;
$$;

create or replace function private.booking_messages_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from 'confirmed') then
    perform private.enqueue_booking_messages(new.id, 'booking_confirmed', 'booking_confirmed:' || new.id);
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    perform private.enqueue_booking_messages(new.id, 'booking_cancelled', 'booking_cancelled:' || new.id);
  elsif tg_op = 'UPDATE' and new.payment_status = 'paid' and old.payment_status is distinct from 'paid'
        and new.status in ('cancelled', 'expired') then
    perform private.enqueue_booking_messages(new.id, 'slot_lost', 'slot_lost:' || new.id);
  end if;
  return new;
end;
$$;

create trigger bookings_customer_messages after insert or update of status, payment_status on public.bookings
  for each row execute function private.booking_messages_trigger();

create or replace function private.refund_messages_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.enqueue_booking_messages(new.booking_id, 'refund_initiated', 'refund_initiated:' || new.id);
  elsif new.status = 'processed' and old.status is distinct from 'processed' then
    perform private.enqueue_booking_messages(new.booking_id, 'refund_processed', 'refund_processed:' || new.id);
  end if;
  return new;
end;
$$;

create trigger refunds_customer_messages after insert or update of status on public.refunds
  for each row execute function private.refund_messages_trigger();

-- Service role: queue reminders for bookings starting in the next hour.
create or replace function public.enqueue_booking_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_n int := 0;
begin
  for r in select b.id from public.bookings b
            where b.status = 'confirmed' and lower(b.period) between now() + interval '30 minutes' and now() + interval '70 minutes'
  loop
    perform private.enqueue_booking_messages(r.id, 'booking_reminder', 'booking_reminder:' || r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- Service role: claim queued messages (each claimed once; stale claims retried).
create or replace function public.claim_customer_messages(p_limit int default 50)
returns setof public.customer_messages
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
    update public.customer_messages m
       set status = 'sending', claimed_at = now(), attempts = m.attempts + 1
     where m.id in (
       select id from public.customer_messages
        where (status = 'pending' or (status = 'sending' and claimed_at < now() - interval '5 minutes'))
          and attempts < 5
        order by created_at
        limit least(greatest(coalesce(p_limit, 50), 1), 200)
        for update skip locked)
    returning m.*;
end;
$$;

create or replace function public.complete_customer_message(
  p_id uuid,
  p_status public.message_status,
  p_provider_message_id text default null,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status not in ('sent', 'failed', 'skipped', 'pending') then
    perform private.raise_error(422, 'invalid_status');
  end if;
  update public.customer_messages
     set status = case when p_status = 'failed' and attempts < 5 then 'pending'::public.message_status else p_status end,
         sent_at = case when p_status = 'sent' then now() end,
         provider_message_id = coalesce(p_provider_message_id, provider_message_id),
         last_error = left(p_error, 500)
   where id = p_id;
end;
$$;

-- Customer: resend the confirmation email (optionally to a corrected address).
create or replace function public.resend_booking_email(p_booking_id uuid, p_email text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_email text := nullif(trim(coalesce(p_email, '')), '');
  v_n int;
begin
  select * into v_b from public.bookings where id = p_booking_id and customer_id = (select auth.uid());
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if v_b.status not in ('confirmed', 'arrived', 'in_progress', 'completed') then
    perform private.raise_error(409, 'booking_not_confirmed', 'Only confirmed bookings have a confirmation email');
  end if;
  if v_email is not null then
    if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 254 then
      perform private.raise_error(422, 'invalid_email');
    end if;
    update public.profiles set receipt_email = v_email where id = v_b.customer_id;
  end if;
  select count(*) into v_n from public.customer_messages
   where booking_id = p_booking_id and channel = 'email' and created_at > now() - interval '1 hour';
  if v_n >= 4 then
    perform private.raise_error(409, 'rate_limited', 'Too many attempts; try again later');
  end if;
  perform private.enqueue_booking_messages(p_booking_id, 'booking_confirmed',
    'booking_confirmed:' || p_booking_id || ':resend:' || gen_random_uuid());
  return jsonb_build_object('queued', true);
end;
$$;

-------------------------------------------------------------------------------
-- Customer booking views
-------------------------------------------------------------------------------

create or replace function private.customer_booking_json(p_b public.bookings, p_detail boolean default false)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.booking_json(p_b) || jsonb_build_object(
    'created_at', p_b.created_at,
    'confirmed_at', p_b.confirmed_at,
    'cancelled_at', p_b.cancelled_at,
    'cancellation_actor', p_b.cancellation_actor,
    'cancellation_reason', p_b.cancellation_reason,
    'refund_eligible', p_b.refund_eligible,
    'checked_in_at', p_b.checked_in_at,
    'charging_started_at', p_b.charging_started_at,
    'completed_at', p_b.completed_at,
    'no_show_at', p_b.no_show_at,
    'expired_at', p_b.expired_at,
    'vehicle_label', p_b.vehicle_label,
    'customer_display_name', p_b.customer_display_name,
    'station', jsonb_build_object(
      'id', s.id, 'name', s.name, 'address_line1', s.address_line1, 'address_line2', s.address_line2,
      'landmark', s.landmark, 'city', s.city, 'state', s.state, 'postal_code', s.postal_code,
      'latitude', s.latitude, 'longitude', s.longitude, 'contact_phone', s.contact_phone,
      'timezone', s.timezone, 'status', s.status, 'closed_until', s.closed_until),
    'point', jsonb_build_object(
      'code', cp.code, 'name', cp.name, 'current_type', cp.current_type, 'max_power_kw', cp.max_power_kw,
      'operational_status', cp.operational_status,
      'connectors', coalesce((select jsonb_agg(c.connector_type order by c.connector_number)
                                from public.charging_connectors c where c.charging_point_id = cp.id), '[]'::jsonb)),
    'policy', jsonb_build_object(
      'arrival_grace_minutes', pol.arrival_grace_minutes,
      'early_checkin_minutes', pol.early_checkin_minutes,
      'report_before_minutes', pol.report_before_minutes,
      'customer_cancel_until_minutes', pol.customer_cancel_until_minutes,
      'auto_no_show_enabled', pol.auto_no_show_enabled),
    'payment', (select jsonb_build_object('status', pm.status, 'reference', pm.gateway_payment_id, 'method', pm.method,
                                          'amount_paise', pm.amount_paise, 'captured_at', pm.captured_at,
                                          'failed_at', pm.failed_at, 'error', pm.error_description)
                  from public.payments pm where pm.booking_id = p_b.id
                 order by (pm.status = 'captured') desc, pm.created_at desc limit 1),
    'has_open_order', exists (select 1 from public.payment_orders o where o.booking_id = p_b.id and o.status = 'created'),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('status', r.status, 'amount_paise', r.amount_paise,
                                                             'reference', r.gateway_refund_id, 'created_at', r.created_at,
                                                             'processed_at', r.processed_at) order by r.created_at)
                           from public.refunds r where r.booking_id = p_b.id), '[]'::jsonb),
    'messages', case when p_detail then coalesce((
                  select jsonb_agg(jsonb_build_object('channel', m.channel, 'template', m.template, 'status', m.status,
                                                      'updated_at', m.updated_at) order by m.created_at)
                    from public.customer_messages m where m.booking_id = p_b.id), '[]'::jsonb) end,
    'events', case when p_detail then coalesce((
                  select jsonb_agg(jsonb_build_object('status', e.to_status, 'payment_status', e.to_payment_status,
                                                      'actor', e.actor, 'at', e.created_at) order by e.created_at, e.id)
                    from public.booking_events e where e.booking_id = p_b.id), '[]'::jsonb) end
  )
  from public.stations s, public.charging_points cp, public.station_booking_policies pol
  where s.id = p_b.station_id and cp.id = p_b.charging_point_id and pol.station_id = p_b.station_id;
$$;

create or replace function public.get_my_bookings(p_limit int default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  return coalesce((
    select jsonb_agg(private.customer_booking_json(b) order by lower(b.period) desc)
      from (select * from public.bookings where customer_id = v_user
             order by lower(period) desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) b), '[]'::jsonb);
end;
$$;

-- One of the caller's bookings, by id or by reference. Other customers'
-- bookings are indistinguishable from missing ones.
create or replace function public.get_my_booking(p_booking_id uuid default null, p_reference text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_b public.bookings;
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  select * into v_b from public.bookings
   where customer_id = v_user
     and ((p_booking_id is not null and id = p_booking_id)
          or (p_booking_id is null and reference = upper(regexp_replace(coalesce(p_reference, ''), '[\s-]', '', 'g'))));
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  return private.customer_booking_json(v_b, true);
end;
$$;

-- What cancelling would do, without doing it. Mirrors cancel_booking and
-- cancel_booking_internal; the refund rule comes from platform settings.
create or replace function public.preview_cancellation(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_policy public.station_booking_policies;
  v_refund jsonb := private.setting('refund_policy');
  v_cancel_until timestamptz;
  v_refund_until timestamptz;
  v_refundable boolean;
  v_in_flight boolean;
begin
  select * into v_b from public.bookings where id = p_booking_id and customer_id = (select auth.uid());
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  select * into v_policy from public.station_booking_policies where station_id = v_b.station_id;
  v_cancel_until := lower(v_b.period) - make_interval(mins => v_policy.customer_cancel_until_minutes);
  v_refund_until := lower(v_b.period) - make_interval(mins => (v_refund ->> 'customer_cancellation_cutoff_minutes')::int);
  v_in_flight := exists (select 1 from public.payments p where p.booking_id = v_b.id and p.status = 'authorized')
                 or exists (select 1 from public.payment_orders o where o.booking_id = v_b.id and o.status = 'created'
                              and o.created_at > now() - interval '15 minutes');

  if v_b.status not in ('payment_pending', 'confirmed') then
    return jsonb_build_object('allowed', false, 'reason', 'not_cancellable', 'status', v_b.status,
                              'policy_confirmed', (v_refund ->> 'policy_confirmed_for_production')::boolean);
  end if;
  if v_b.status = 'confirmed' and now() > v_cancel_until then
    return jsonb_build_object('allowed', false, 'reason', 'cancellation_window_closed', 'cancel_until', v_cancel_until,
                              'policy_confirmed', (v_refund ->> 'policy_confirmed_for_production')::boolean);
  end if;
  v_refundable := v_b.payment_status = 'paid'
                  and (v_refund ->> 'customer_cancellation_refundable')::boolean
                  and now() <= v_refund_until;
  return jsonb_build_object(
    'allowed', true,
    'reason', null,
    'status', v_b.status,
    'payment_status', v_b.payment_status,
    'payment_in_progress', v_b.status = 'payment_pending' and v_in_flight,
    'refund_eligible', v_refundable,
    'refund_amount_paise', case when v_refundable then v_b.booking_fee_paise else 0 end,
    'refund_until', case when (v_refund ->> 'customer_cancellation_refundable')::boolean then v_refund_until end,
    'cancel_until', v_cancel_until,
    'policy_confirmed', (v_refund ->> 'policy_confirmed_for_production')::boolean
  );
end;
$$;

-------------------------------------------------------------------------------
-- Customer reports (booking problems, incorrect station info, suspicious activity)
-------------------------------------------------------------------------------

create type public.customer_report_kind as enum (
  'point_occupied', 'point_broken', 'point_incompatible', 'station_closed', 'cannot_find_station',
  'cannot_check_in', 'refund_issue', 'payment_issue', 'incorrect_station_info', 'suspicious_activity', 'other'
);

create table public.customer_reports (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique default ('CS' || private.random_code(8)),
  reporter_id uuid references public.profiles (id) on delete set null,
  booking_id uuid references public.bookings (id) on delete set null,
  station_id uuid references public.stations (id) on delete set null,
  kind public.customer_report_kind not null,
  message text check (message is null or char_length(message) <= 2000),
  status text not null default 'open' check (status in ('open', 'acknowledged', 'resolved')),
  created_at timestamptz not null default now(),
  check (booking_id is not null or station_id is not null)
);

create index customer_reports_station_idx on public.customer_reports (station_id, created_at desc);
create index customer_reports_reporter_idx on public.customer_reports (reporter_id, created_at desc);

alter table public.customer_reports enable row level security;
create policy customer_reports_select on public.customer_reports for select to authenticated using (
  reporter_id = (select auth.uid())
  or (station_id is not null and private.has_station_permission(station_id, 'bookings.view'))
  or private.has_platform_permission('bookings.read_all')
);

-- Booking problems need the booking's customer; station-information and
-- suspicious-activity reports may come from guests.
create or replace function public.submit_customer_report(
  p_kind public.customer_report_kind,
  p_message text default null,
  p_booking_id uuid default null,
  p_station_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_b public.bookings;
  v_station uuid := p_station_id;
  v_business uuid;
  v_ref text;
  v_msg text := nullif(left(trim(coalesce(p_message, '')), 2000), '');
begin
  if p_booking_id is not null then
    if v_user is null then
      perform private.raise_error(401, 'not_authenticated');
    end if;
    select * into v_b from public.bookings where id = p_booking_id and customer_id = v_user;
    if not found then
      perform private.raise_error(404, 'booking_not_found');
    end if;
    v_station := v_b.station_id;
  else
    if p_kind not in ('incorrect_station_info', 'suspicious_activity', 'other') then
      perform private.raise_error(422, 'booking_required', 'Choose the booking this problem is about');
    end if;
    if v_station is null or not private.is_public_station(v_station) then
      perform private.raise_error(404, 'station_not_found');
    end if;
    if v_msg is null or char_length(v_msg) < 5 then
      perform private.raise_error(422, 'note_required');
    end if;
  end if;

  -- Abuse limits.
  if v_user is not null and (select count(*) from public.customer_reports
                              where reporter_id = v_user and created_at > now() - interval '1 hour') >= 10 then
    perform private.raise_error(409, 'rate_limited');
  end if;
  if v_user is null and (select count(*) from public.customer_reports
                          where reporter_id is null and station_id = v_station and created_at > now() - interval '1 hour') >= 20 then
    perform private.raise_error(409, 'rate_limited');
  end if;

  insert into public.customer_reports (reporter_id, booking_id, station_id, kind, message)
  values (v_user, p_booking_id, v_station, p_kind, v_msg)
  returning reference into v_ref;

  select business_id into v_business from public.stations where id = v_station;
  if p_booking_id is not null then
    perform private.notify_business(v_business, v_station, 'bookings.view', 'booking', 'booking.customer_report',
      'Customer needs help', format('Booking %s: %s.', v_b.reference, replace(p_kind::text, '_', ' ')),
      jsonb_build_object('booking_id', p_booking_id, 'station_id', v_station, 'report', v_ref), 'report:' || v_ref);
  end if;
  perform private.notify_platform_staff('bookings.support_notes', 'system', 'customer.report',
    'Customer report ' || v_ref, format('%s at station %s.', replace(p_kind::text, '_', ' '),
      (select name from public.stations where id = v_station)),
    jsonb_build_object('station_id', v_station, 'booking_id', p_booking_id, 'report', v_ref), 'report.staff:' || v_ref);
  return jsonb_build_object('reference', v_ref);
end;
$$;

-------------------------------------------------------------------------------
-- Account deletion requests
-------------------------------------------------------------------------------

create table public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  reason text check (reason is null or char_length(reason) <= 1000),
  status text not null default 'pending' check (status in ('pending', 'completed', 'cancelled')),
  created_at timestamptz not null default now(),
  processed_at timestamptz
);

create unique index account_deletion_one_pending on public.account_deletion_requests (user_id) where status = 'pending';
alter table public.account_deletion_requests enable row level security;
create policy account_deletion_select_own on public.account_deletion_requests for select to authenticated
  using (user_id = (select auth.uid()));

-- What stops the caller's account from being deleted right now.
create or replace function public.get_account_deletion_check()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  return jsonb_build_object(
    'active_bookings', (select count(*) from public.bookings where customer_id = v_user
                          and status in ('payment_pending', 'confirmed', 'arrived', 'in_progress')),
    'pending_refunds', (select count(*) from public.refunds r join public.bookings b on b.id = r.booking_id
                          where b.customer_id = v_user and r.status in ('requested', 'processing')),
    'is_business_member', exists (select 1 from public.business_members m where m.user_id = v_user and m.status = 'active'),
    'is_platform_staff', exists (select 1 from public.platform_staff s where s.user_id = v_user and s.is_active),
    'pending_request', (select jsonb_build_object('id', id, 'created_at', created_at)
                          from public.account_deletion_requests where user_id = v_user and status = 'pending')
  );
end;
$$;

create or replace function public.request_account_deletion(p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_check jsonb;
  v_id uuid;
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  v_check := public.get_account_deletion_check();
  if (v_check ->> 'active_bookings')::int > 0 or (v_check ->> 'pending_refunds')::int > 0 then
    perform private.raise_error(409, 'deletion_blocked', 'Finish or cancel active bookings and wait for refunds first');
  end if;
  if (v_check ->> 'is_business_member')::boolean or (v_check ->> 'is_platform_staff')::boolean then
    perform private.raise_error(409, 'deletion_blocked_role', 'Business and staff accounts are closed through support');
  end if;
  if v_check -> 'pending_request' <> 'null'::jsonb then
    return jsonb_build_object('id', v_check -> 'pending_request' ->> 'id', 'status', 'pending');
  end if;
  insert into public.account_deletion_requests (user_id, reason)
  values (v_user, nullif(left(trim(coalesce(p_reason, '')), 1000), ''))
  returning id into v_id;
  perform private.write_audit('account.deletion_requested', 'profiles', v_user::text, null, null, p_reason);
  perform private.notify_platform_staff('bookings.support_notes', 'system', 'account.deletion_requested',
    'Account deletion requested', 'A customer asked for their account to be deleted.',
    jsonb_build_object('request_id', v_id), 'account.deletion:' || v_id);
  return jsonb_build_object('id', v_id, 'status', 'pending');
end;
$$;

-------------------------------------------------------------------------------
-- Privileges
-------------------------------------------------------------------------------

-- Default privileges grant new tables to anon/authenticated and new functions
-- to PUBLIC, so everything created above is revoked first and then granted
-- explicitly.
revoke all on public.customer_consents, public.customer_messages, public.customer_reports,
              public.account_deletion_requests from public, anon, authenticated;
grant select, insert (kind, version, granted) on public.customer_consents to authenticated;
grant select on public.customer_reports, public.account_deletion_requests to authenticated;
grant all on public.customer_consents, public.customer_messages, public.customer_reports,
             public.account_deletion_requests to service_role;

revoke execute on function
  public.search_stations(numeric, numeric, numeric, int),
  public.get_public_station(uuid, numeric, numeric),
  public.get_station_slots(uuid, date),
  public.check_slot_availability(uuid, timestamptz, timestamptz),
  public.search_areas(text, int),
  public.get_booking_terms(),
  public.submit_customer_report(public.customer_report_kind, text, uuid, uuid),
  public.get_my_bookings(int),
  public.get_my_booking(uuid, text),
  public.preview_cancellation(uuid),
  public.resend_booking_email(uuid, text),
  public.get_account_deletion_check(),
  public.request_account_deletion(text)
from public, anon, authenticated;

revoke execute on function
  private.is_public_station(uuid),
  private.distance_km(numeric, numeric, numeric, numeric),
  private.station_unavailable_reason(uuid),
  private.point_unavailable_reason(public.charging_points),
  private.point_cells(uuid, timestamptz, timestamptz, boolean),
  private.station_next_free(uuid, interval),
  private.station_hours_json(uuid),
  private.station_open_state(uuid),
  private.public_point_json(public.charging_points),
  private.public_station_summary(uuid, numeric, numeric),
  private.current_terms_version(),
  private.booking_message_payload(uuid),
  private.enqueue_booking_messages(uuid, text, text),
  private.booking_messages_trigger(),
  private.refund_messages_trigger(),
  private.customer_booking_json(public.bookings, boolean)
from public, anon, authenticated;

-- Guests and signed-in users.
grant execute on function
  public.search_stations(numeric, numeric, numeric, int),
  public.get_public_station(uuid, numeric, numeric),
  public.get_station_slots(uuid, date),
  public.check_slot_availability(uuid, timestamptz, timestamptz),
  public.search_areas(text, int),
  public.get_booking_terms(),
  public.submit_customer_report(public.customer_report_kind, text, uuid, uuid)
to anon, authenticated;

-- Signed-in customers.
grant execute on function
  public.get_my_bookings(int),
  public.get_my_booking(uuid, text),
  public.preview_cancellation(uuid),
  public.resend_booking_email(uuid, text),
  public.get_account_deletion_check(),
  public.request_account_deletion(text)
to authenticated;

-- Service role only (dispatch-customer-messages).
revoke execute on function
  public.enqueue_booking_reminders(),
  public.claim_customer_messages(int),
  public.complete_customer_message(uuid, public.message_status, text, text)
from public, anon, authenticated;
grant execute on function
  public.enqueue_booking_reminders(),
  public.claim_customer_messages(int),
  public.complete_customer_message(uuid, public.message_status, text, text)
to service_role;
