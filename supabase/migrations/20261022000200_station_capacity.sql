-- Station-level booking: customers choose a station and a time, not a
-- charging point. Any compatible point that is free for the whole period is
-- assigned when the hold is created, so a station with three points takes
-- three overlapping bookings and only then shows as full.
--
-- Also:
-- * a customer cannot hold two bookings that overlap in time;
-- * when a point goes out of service or is blocked, its upcoming bookings
--   move to another free compatible point at the same station before any
--   are cancelled;
-- * an unchecked-in booking becomes a no-show once the arrival grace period
--   ends, releasing the rest of the slot.

-------------------------------------------------------------------------------
-- Candidate points
-------------------------------------------------------------------------------

-- Points at a station that could take [p_start, p_end): bookable, with the
-- requested connector, and not overlapping another active booking (with the
-- station buffer). Best fit first: the point whose previous booking ends
-- closest to p_start, so longer gaps stay open for longer bookings.
-- Advisory only; the exclusion constraint is the real guarantee.
create or replace function private.station_candidate_points(
  p_station uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_connector public.connector_type default null,
  p_exclude_point uuid default null
)
returns table (charging_point_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id
    from public.charging_points p
    join public.station_booking_policies pol on pol.station_id = p.station_id
   where p.station_id = p_station
     and p.archived_at is null
     and p.booking_enabled
     and p.operational_status in ('available', 'in_use')
     and (p_exclude_point is null or p.id <> p_exclude_point)
     and (p_connector is null or exists (
           select 1 from public.charging_connectors c where c.charging_point_id = p.id and c.connector_type = p_connector))
     and not exists (
           select 1 from public.bookings b
            where b.charging_point_id = p.id
              and (b.status in ('confirmed', 'arrived', 'in_progress')
                   or (b.status = 'payment_pending' and b.hold_expires_at > now()))
              and b.occupancy && tstzrange(p_start, p_end + make_interval(mins => pol.buffer_minutes), '[)'))
     and not exists (
           select 1 from public.blocked_periods bp
            where bp.station_id = p_station and bp.cancelled_at is null
              and (bp.charging_point_id is null or bp.charging_point_id = p.id)
              and bp.period && tstzrange(p_start, p_end + make_interval(mins => pol.buffer_minutes), '[)'))
   order by (select p_start - max(upper(b.occupancy))
               from public.bookings b
              where b.charging_point_id = p.id
                and b.status in ('payment_pending', 'confirmed', 'arrived', 'in_progress')
                and upper(b.occupancy) <= p_start
                and upper(b.occupancy) > p_start - interval '1 day') asc nulls last,
            p.code;
$$;

-- Points a booking can move to: same station, sharing a connector type with
-- its current point.
create or replace function private.compatible_points(p_point uuid)
returns table (charging_point_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct o.id
    from public.charging_points p
    join public.charging_points o on o.station_id = p.station_id and o.id <> p.id and o.archived_at is null
   where p.id = p_point
     and (not exists (select 1 from public.charging_connectors c where c.charging_point_id = p.id)
          or exists (select 1 from public.charging_connectors a
                       join public.charging_connectors b on b.connector_type = a.connector_type
                      where a.charging_point_id = p.id and b.charging_point_id = o.id));
$$;

-------------------------------------------------------------------------------
-- Availability check (guests and customers)
-------------------------------------------------------------------------------

-- Problems with the request itself (time in the past, misaligned, too far
-- ahead, station closed) that apply whichever point is used. Returns the
-- error code, or null.
create or replace function private.station_request_problem(p_station uuid, p_start timestamptz, p_end timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_point uuid;
  v_code text;
begin
  select id into v_point from public.charging_points
   where station_id = p_station and archived_at is null
   order by (booking_enabled and operational_status in ('available', 'in_use')) desc, code
   limit 1;
  if v_point is null then
    return 'station_full';
  end if;
  begin
    perform private.assert_bookable(v_point, p_start, p_end);
  exception when sqlstate 'PT409' or sqlstate 'PT422' or sqlstate 'PT404' then
    get stacked diagnostics v_code = message_text;
    if v_code in ('invalid_period', 'too_soon', 'too_far_ahead', 'slot_misaligned', 'station_not_bookable') then
      return v_code;
    end if;
  end;
  return null;
end;
$$;


create or replace function public.check_station_availability(
  p_station_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_connector_type public.connector_type default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_point uuid;
  v_free int := 0;
  v_total int;
  v_reason text;
  v_code text;
  v_fee bigint := (private.setting('booking_fee_paise'))::bigint;
begin
  if not private.is_public_station(p_station_id) then
    perform private.raise_error(404, 'station_not_found');
  end if;
  v_reason := private.station_request_problem(p_station_id, p_start_at, p_end_at);
  if v_reason is not null then
    return jsonb_build_object('available', false, 'free_points', 0, 'total_points', 0, 'reason', v_reason,
                              'booking_fee_paise', v_fee, 'checked_at', now());
  end if;
  select count(*) into v_total from public.charging_points p
   where p.station_id = p_station_id and p.archived_at is null
     and (p_connector_type is null or exists (
           select 1 from public.charging_connectors c where c.charging_point_id = p.id and c.connector_type = p_connector_type));
  for v_point in select charging_point_id from private.station_candidate_points(p_station_id, p_start_at, p_end_at, p_connector_type) loop
    begin
      perform private.assert_bookable(v_point, p_start_at, p_end_at);
      v_free := v_free + 1;
    exception when sqlstate 'PT409' or sqlstate 'PT422' or sqlstate 'PT404' then
      get stacked diagnostics v_code = message_text;
      v_reason := coalesce(v_reason, v_code);
    end;
  end loop;
  return jsonb_build_object(
    'available', v_free > 0,
    'free_points', v_free,
    'total_points', v_total,
    'reason', case when v_free > 0 then null else coalesce(v_reason, 'station_full') end,
    'booking_fee_paise', v_fee,
    'checked_at', now());
end;
$$;

-------------------------------------------------------------------------------
-- Hold by station
-------------------------------------------------------------------------------

create or replace function public.create_station_booking_hold(
  p_station_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_idempotency_key text,
  p_connector_type public.connector_type default null,
  p_vehicle_label text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_existing public.bookings;
  v_point uuid;
  v_code text;
  v_last text;
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 80 then
    perform private.raise_error(422, 'idempotency_key_required');
  end if;
  -- Retried request: the booking already made, whichever point it got.
  select * into v_existing from public.bookings where customer_id = v_user and idempotency_key = p_idempotency_key;
  if found then
    return private.booking_json(v_existing);
  end if;
  if not private.is_public_station(p_station_id) then
    perform private.raise_error(404, 'station_not_found');
  end if;
  -- One car, one place at a time.
  if exists (select 1 from public.bookings b
              where b.customer_id = v_user
                and (b.status in ('confirmed', 'arrived', 'in_progress')
                     or (b.status = 'payment_pending' and b.hold_expires_at > now()))
                and b.period && tstzrange(p_start_at, p_end_at, '[)')) then
    perform private.raise_error(409, 'overlapping_booking', 'You already have a booking at this time.');
  end if;
  v_code := private.station_request_problem(p_station_id, p_start_at, p_end_at);
  if v_code = 'station_not_bookable' then
    perform private.raise_error(409, v_code, 'This station is not accepting reservations');
  elsif v_code is not null and v_code <> 'station_full' then
    perform private.raise_error(422, v_code);
  end if;

  for v_point in select charging_point_id from private.station_candidate_points(p_station_id, p_start_at, p_end_at, p_connector_type) loop
    begin
      return public.create_booking_hold(v_point, p_start_at, p_end_at, p_idempotency_key, p_vehicle_label);
    exception when sqlstate 'PT409' or sqlstate 'PT422' or sqlstate 'PT404' then
      get stacked diagnostics v_code = message_text;
      -- Point-specific problems: try the next point. Anything about the
      -- customer or the request itself applies to every point.
      if v_code not in ('slot_unavailable', 'point_not_bookable', 'blocked_period', 'outside_operating_hours',
                        'charging_point_not_found', 'invalid_duration') then
        raise;
      end if;
      v_last := v_code;
    end;
  end loop;

  if v_last in ('outside_operating_hours', 'invalid_duration') then
    perform private.raise_error(422, v_last);
  end if;
  perform private.raise_error(409, 'station_full', 'Every charging point is booked for this time. Please choose another time.');
end;
$$;

-------------------------------------------------------------------------------
-- Moving bookings off a point that cannot serve them
-------------------------------------------------------------------------------

-- The point of a booking is fixed, except when the platform moves it to an
-- equivalent point at the same station.
create or replace function private.booking_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if (new.charging_point_id is distinct from old.charging_point_id
          and current_setting('app.booking_reassign', true) is distinct from 'on')
       or new.station_id is distinct from old.station_id
       or new.customer_id is distinct from old.customer_id
       or new.reference is distinct from old.reference
       or new.qr_token is distinct from old.qr_token
       or new.booking_fee_paise is distinct from old.booking_fee_paise
       or new.created_at is distinct from old.created_at then
      perform private.raise_error(403, 'protected_field', 'Booking identity, point and fee are immutable');
    end if;
    if new.status is distinct from old.status
       and not private.is_valid_booking_transition(old.status, new.status)
       and not (current_setting('app.booking_override', true) = 'on'
                and private.is_valid_override_transition(old.status, new.status)) then
      perform private.raise_error(409, 'invalid_status_transition',
        format('Booking cannot move from %s to %s', old.status, new.status));
    end if;
    if new.period is distinct from old.period and old.status <> 'payment_pending' then
      perform private.raise_error(409, 'booking_time_locked', 'Only unpaid holds can change time');
    end if;
  end if;
  new.occupancy := tstzrange(lower(new.period), upper(new.period) + make_interval(mins => new.buffer_minutes), '[)');
  return new;
end;
$$;

-- Moves one upcoming booking to another free compatible point at the same
-- station. Returns the new point code, or null if none is free.
create or replace function private.try_reassign_booking(p_booking uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_s public.stations;
  v_point uuid;
  v_code text;
begin
  select * into v_b from public.bookings where id = p_booking for update;
  if not found or v_b.status not in ('payment_pending', 'confirmed') then
    return null;
  end if;
  select * into v_s from public.stations where id = v_b.station_id;
  for v_point in
    select c.charging_point_id
      from private.station_candidate_points(v_b.station_id, lower(v_b.period), upper(v_b.period), null, v_b.charging_point_id) c
     where c.charging_point_id in (select charging_point_id from private.compatible_points(v_b.charging_point_id))
  loop
    begin
      perform set_config('app.booking_reassign', 'on', true);
      update public.bookings set charging_point_id = v_point where id = p_booking;
      perform set_config('app.booking_reassign', 'off', true);
      select code into v_code from public.charging_points where id = v_point;
      perform private.notify(v_b.customer_id, 'booking', 'booking.point_changed', 'Charging point changed',
        format('Your booking %s at %s now uses point %s. Your time is unchanged.', v_b.reference, v_s.name, v_code),
        jsonb_build_object('booking_id', v_b.id), 'booking.point_changed:' || v_b.id || ':' || v_point);
      perform private.notify_business(v_s.business_id, v_s.id, 'bookings.view', 'booking', 'booking.point_changed',
        'Booking moved', format('%s moved to point %s (%s).', v_b.reference, v_code, coalesce(p_reason, 'point unavailable')),
        jsonb_build_object('booking_id', v_b.id, 'station_id', v_s.id), 'booking.point_changed.business:' || v_b.id || ':' || v_point);
      return v_code;
    exception when exclusion_violation then
      perform set_config('app.booking_reassign', 'off', true);
    end;
  end loop;
  return null;
end;
$$;

-- Point-level blocks first try to move the affected bookings; only those
-- that cannot move count as conflicts.
create or replace function public.create_blocked_period(
  p_station_id uuid,
  p_charging_point_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_kind public.blocked_period_kind,
  p_reason text,
  p_cancel_conflicting boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_conflicts uuid[];
  v_booking uuid;
  v_moved int := 0;
begin
  if p_kind = 'maintenance' and p_charging_point_id is not null then
    if not (private.has_station_permission(p_station_id, 'points.status')
            or private.has_station_permission(p_station_id, 'availability.edit')) then
      perform private.require_station_permission(p_station_id, 'availability.edit');
    end if;
  else
    perform private.require_station_permission(p_station_id, 'availability.edit');
  end if;
  if p_ends_at <= p_starts_at then
    perform private.raise_error(422, 'invalid_period');
  end if;
  if p_ends_at < now() then
    perform private.raise_error(422, 'period_in_past');
  end if;
  if p_charging_point_id is not null and not exists (
      select 1 from public.charging_points where id = p_charging_point_id and station_id = p_station_id) then
    perform private.raise_error(422, 'point_station_mismatch');
  end if;
  select array_agg(b.id order by lower(b.period)) into v_conflicts from public.bookings b
   where b.station_id = p_station_id
     and (p_charging_point_id is null or b.charging_point_id = p_charging_point_id)
     and b.status in ('payment_pending', 'confirmed')
     and b.occupancy && tstzrange(p_starts_at, p_ends_at, '[)');

  -- Point blocks first move what they can. If anything is left and the
  -- caller has not confirmed cancellation, the error rolls the moves back
  -- too, so nothing changes until they confirm.
  if v_conflicts is not null and p_charging_point_id is not null then
    foreach v_booking in array v_conflicts loop
      if private.try_reassign_booking(v_booking, coalesce(nullif(trim(p_reason), ''), replace(p_kind::text, '_', ' '))) is not null then
        v_moved := v_moved + 1;
        v_conflicts := array_remove(v_conflicts, v_booking);
      end if;
    end loop;
    if cardinality(v_conflicts) = 0 then
      v_conflicts := null;
    end if;
  end if;
  if v_conflicts is not null and not coalesce(p_cancel_conflicting, false) then
    perform private.raise_error(409, 'bookings_conflict',
      format('%s booking(s) overlap this period and cannot move to another point. Confirm cancellation to continue.',
             cardinality(v_conflicts)));
  end if;

  insert into public.blocked_periods (station_id, charging_point_id, period, kind, reason, created_by)
  values (p_station_id, p_charging_point_id, tstzrange(p_starts_at, p_ends_at, '[)'), p_kind, p_reason, (select auth.uid()))
  returning id into v_id;
  if v_conflicts is not null then
    foreach v_booking in array v_conflicts loop
      perform private.cancel_booking_internal(v_booking, 'business',
        coalesce(nullif(trim(p_reason), ''), 'Station unavailable: ' || replace(p_kind::text, '_', ' ')));
    end loop;
  end if;
  return jsonb_build_object('blocked_period_id', v_id, 'cancelled_bookings', coalesce(cardinality(v_conflicts), 0),
                            'moved_bookings', v_moved);
end;
$$;

-- A point taken out of service hands its upcoming bookings to other free
-- points where it can. Bookings that cannot move stay and are reported as
-- before (upcoming_bookings), for the station to decide.
create or replace function public.set_charging_point_status(
  p_charging_point_id uuid,
  p_status public.point_status,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_point public.charging_points;
  v_upcoming int;
  v_moved int := 0;
  v_booking uuid;
begin
  select * into v_point from public.charging_points where id = p_charging_point_id and archived_at is null;
  if not found then
    perform private.raise_error(404, 'charging_point_not_found');
  end if;
  perform private.require_station_permission(v_point.station_id, 'points.status');
  if p_status = 'disabled' then
    perform private.require_station_permission(v_point.station_id, 'points.manage');
  end if;
  update public.charging_points
     set operational_status = p_status, status_source = 'manual', status_note = nullif(trim(p_note), ''),
         status_updated_at = now(), status_updated_by = (select auth.uid())
   where id = p_charging_point_id;
  if p_status not in ('available', 'in_use') then
    for v_booking in
      select id from public.bookings
       where charging_point_id = p_charging_point_id and status in ('payment_pending', 'confirmed')
         and upper(period) > now()
       order by lower(period)
    loop
      if private.try_reassign_booking(v_booking, coalesce(nullif(trim(p_note), ''), 'point ' || replace(p_status::text, '_', ' '))) is not null then
        v_moved := v_moved + 1;
      end if;
    end loop;
  end if;
  select count(*) into v_upcoming from public.bookings
   where charging_point_id = p_charging_point_id and status in ('payment_pending', 'confirmed')
     and upper(period) > now();
  return jsonb_build_object('status', p_status, 'status_source', 'manual', 'upcoming_bookings', v_upcoming,
                            'moved_bookings', v_moved);
end;
$$;

-------------------------------------------------------------------------------
-- No-show as soon as the arrival grace period ends
-------------------------------------------------------------------------------

create or replace function public.run_booking_jobs()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired int;
  v_orders int;
  v_no_show int;
  v_reminders int := 0;
  r record;
begin
  perform private.set_booking_context('system', 'Payment hold expired');
  with x as (
    update public.bookings set status = 'expired', payment_status = 'abandoned', expired_at = now()
     where status = 'payment_pending' and hold_expires_at <= now()
    returning id
  ) select count(*) into v_expired from x;

  with x as (
    update public.payment_orders o set status = 'expired'
      from public.bookings b
     where b.id = o.booking_id and o.status = 'created' and b.status in ('expired', 'cancelled')
    returning o.id
  ) select count(*) into v_orders from x;

  -- The point is held until the arrival grace period ends. A customer who
  -- has not checked in by then is a no-show and the rest of the slot is
  -- released for others.
  perform private.set_booking_context('system', 'Automatic no-show: not checked in within the arrival grace period');
  with x as (
    update public.bookings b set status = 'no_show', no_show_at = now()
      from public.station_booking_policies p
     where p.station_id = b.station_id and p.auto_no_show_enabled
       and b.status = 'confirmed'
       and now() >= least(upper(b.period), lower(b.period) + make_interval(mins => p.arrival_grace_minutes))
    returning b.id
  ) select count(*) into v_no_show from x;

  -- Upcoming-arrival reminders (once per booking via dedupe key).
  for r in
    select b.id, b.reference, b.customer_display_name, b.station_id, s.business_id, s.timezone, b.period
      from public.bookings b join public.stations s on s.id = b.station_id
     where b.status = 'confirmed' and lower(b.period) between now() and now() + interval '30 minutes'
  loop
    perform private.notify_business(r.business_id, r.station_id, 'bookings.view', 'booking', 'booking.upcoming_arrival',
      'Upcoming arrival', format('%s is due at %s (%s).', r.customer_display_name,
        to_char(lower(r.period) at time zone r.timezone, 'HH24:MI'), r.reference),
      jsonb_build_object('booking_id', r.id, 'station_id', r.station_id), 'booking.upcoming:' || r.id);
    v_reminders := v_reminders + 1;
  end loop;

  return jsonb_build_object('expired_holds', v_expired, 'expired_orders', v_orders, 'no_shows', v_no_show,
                            'arrival_reminders', v_reminders, 'ran_at', now());
end;
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------

revoke execute on function
  private.station_candidate_points(uuid, timestamptz, timestamptz, public.connector_type, uuid),
  private.station_request_problem(uuid, timestamptz, timestamptz),
  private.compatible_points(uuid),
  private.try_reassign_booking(uuid, text),
  public.check_station_availability(uuid, timestamptz, timestamptz, public.connector_type),
  public.create_station_booking_hold(uuid, timestamptz, timestamptz, text, public.connector_type, text)
from public, anon, authenticated;

grant execute on function public.check_station_availability(uuid, timestamptz, timestamptz, public.connector_type)
to anon, authenticated;
grant execute on function public.create_station_booking_hold(uuid, timestamptz, timestamptz, text, public.connector_type, text)
to authenticated;
