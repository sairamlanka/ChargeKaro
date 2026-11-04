-- Customer improvements (2026-11-04):
--   1. Energy price per kWh on each charging point, shown to customers so the
--      app can estimate what the charge will cost at the station.
--   2. Charger status follows check-in: a point turns "In use" when a booking
--      on it is checked in and back to "Available" when charging ends.
--   3. Reschedule: a customer may move a paid booking once, keeping the
--      booking fee.
--   4. Station ratings: customers rate a station after a completed booking.

-------------------------------------------------------------------------------
-- 1. Energy price
-------------------------------------------------------------------------------

alter table public.charging_points
  add column price_per_kwh_paise int check (price_per_kwh_paise is null or price_per_kwh_paise between 0 and 10000);

comment on column public.charging_points.price_per_kwh_paise is
  'Energy price the station charges at the point, in paise per kWh. Paid at the station, not through ChargeKaro. Null = not published.';

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
    'price_per_kwh_paise', p_point.price_per_kwh_paise,
    'connectors', coalesce((select jsonb_agg(jsonb_build_object('number', c.connector_number, 'type', c.connector_type,
                                                                 'max_power_kw', coalesce(c.max_power_kw, p_point.max_power_kw))
                                             order by c.connector_number)
                              from public.charging_connectors c where c.charging_point_id = p_point.id), '[]'::jsonb)
  )
  from public.station_booking_policies pol where pol.station_id = p_point.station_id;
$$;

-------------------------------------------------------------------------------
-- 2. Charger status follows check-in
-------------------------------------------------------------------------------

-- Only touches manually reported points that are Available / In use, so a
-- point staff marked Maintenance or Out of service stays that way, and
-- telemetry (when connected) stays authoritative.
create or replace function private.point_status_from_booking()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_was boolean := old.status in ('arrived', 'in_progress');
  v_is boolean := new.status in ('arrived', 'in_progress');
begin
  if v_is and not v_was then
    update public.charging_points
       set operational_status = 'in_use',
           status_note = 'Set automatically at check-in',
           status_updated_at = now(),
           status_updated_by = null
     where id = new.charging_point_id and operational_status = 'available' and status_source = 'manual';
  elsif v_was and not v_is then
    update public.charging_points p
       set operational_status = 'available',
           status_note = 'Set automatically when charging ended',
           status_updated_at = now(),
           status_updated_by = null
     where p.id = new.charging_point_id and p.operational_status = 'in_use' and p.status_source = 'manual'
       and not exists (select 1 from public.bookings b
                        where b.charging_point_id = p.id and b.id <> new.id and b.status in ('arrived', 'in_progress'));
  end if;
  return null;
end;
$$;

create trigger bookings_point_status after update of status on public.bookings
  for each row when (old.status is distinct from new.status)
  execute function private.point_status_from_booking();

-------------------------------------------------------------------------------
-- 3. Reschedule once
-------------------------------------------------------------------------------

alter table public.bookings
  add column reschedule_count smallint not null default 0 check (reschedule_count between 0 and 5),
  add column rescheduled_at timestamptz,
  add column original_period tstzrange;

-- Same as before, plus: a confirmed booking's time (and point at the same
-- station) may change inside public.reschedule_booking.
create or replace function private.booking_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_reschedule boolean := coalesce(current_setting('app.booking_reschedule', true) = 'on', false);
begin
  if tg_op = 'UPDATE' then
    if (new.charging_point_id is distinct from old.charging_point_id
          and current_setting('app.booking_reassign', true) is distinct from 'on'
          and not v_reschedule)
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
    if new.period is distinct from old.period and old.status <> 'payment_pending'
       and not (v_reschedule and old.status = 'confirmed') then
      perform private.raise_error(409, 'booking_time_locked', 'Only unpaid holds can change time');
    end if;
  end if;
  new.occupancy := tstzrange(lower(new.period), upper(new.period) + make_interval(mins => new.buffer_minutes), '[)');
  return new;
end;
$$;

-- Platform setting: how many times a customer may move one booking (default 1).
create or replace function private.max_reschedules()
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((private.setting('booking_reschedule') ->> 'max_per_booking')::int, 1);
$$;

-- Why the customer cannot move this booking now, or null when they can.
create or replace function private.reschedule_problem(p_b public.bookings)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_b.status <> 'confirmed' then 'not_reschedulable'
    when p_b.payment_status not in ('paid', 'not_required') then 'not_reschedulable'
    when p_b.reschedule_count >= private.max_reschedules() then 'reschedule_limit_reached'
    when now() >= lower(p_b.period) - make_interval(mins => coalesce(pol.customer_cancel_until_minutes, 0)) then 'reschedule_too_late'
  end
  from public.station_booking_policies pol where pol.station_id = p_b.station_id;
$$;

-- Moves the caller's confirmed booking to a new time at the same station.
-- Tries the booking's own point first, then any other free point that has
-- the requested connector. The fee stays with the booking (nothing is
-- charged or refunded). Old check-in QR codes stop working.
create or replace function public.reschedule_booking(
  p_booking_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_connector_type public.connector_type default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_b public.bookings;
  v_problem text;
  v_point uuid;
  v_code text;
  v_last text;
  v_buffer int;
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  select * into v_b from public.bookings where id = p_booking_id and customer_id = v_user for update;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  v_problem := private.reschedule_problem(v_b);
  if v_problem is not null then
    perform private.raise_error(409, v_problem);
  end if;
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    perform private.raise_error(422, 'invalid_period');
  end if;
  if tstzrange(p_start_at, p_end_at, '[)') = v_b.period then
    perform private.raise_error(422, 'same_time', 'Choose a different time');
  end if;
  if exists (select 1 from public.bookings b
              where b.customer_id = v_user and b.id <> v_b.id
                and (b.status in ('confirmed', 'arrived', 'in_progress')
                     or (b.status = 'payment_pending' and b.hold_expires_at > now()))
                and b.period && tstzrange(p_start_at, p_end_at, '[)')) then
    perform private.raise_error(409, 'overlapping_booking', 'You already have a booking at this time.');
  end if;
  select buffer_minutes into v_buffer from public.station_booking_policies where station_id = v_b.station_id;

  for v_point in
    select p.id
      from public.charging_points p
     where p.station_id = v_b.station_id and p.archived_at is null and p.booking_enabled
       and p.operational_status in ('available', 'in_use')
       and (p.id = v_b.charging_point_id
            or exists (select 1 from public.charging_connectors c
                        where c.charging_point_id = p.id
                          and c.connector_type = coalesce(p_connector_type,
                                (select c0.connector_type from public.charging_connectors c0
                                  where c0.charging_point_id = v_b.charging_point_id order by c0.connector_number limit 1))))
     order by (p.id = v_b.charging_point_id) desc, p.code
  loop
    begin
      perform private.assert_bookable(v_point, p_start_at, p_end_at);
      perform set_config('app.booking_reschedule', 'on', true);
      perform private.set_booking_context('customer', 'Rescheduled by customer');
      update public.bookings
         set period = tstzrange(p_start_at, p_end_at, '[)'),
             buffer_minutes = coalesce(v_buffer, buffer_minutes),
             charging_point_id = v_point,
             original_period = coalesce(original_period, period),
             reschedule_count = reschedule_count + 1,
             rescheduled_at = now()
       where id = v_b.id
      returning * into v_b;
      perform set_config('app.booking_reschedule', 'off', true);
      update public.booking_qr_tokens
         set revoked_at = now(), revoke_reason = 'rescheduled'
       where booking_id = v_b.id and revoked_at is null and consumed_at is null;
      return private.customer_booking_json(v_b, true);
    exception
      when exclusion_violation then
        perform set_config('app.booking_reschedule', 'off', true);
        v_last := 'slot_unavailable';
      when sqlstate 'PT409' or sqlstate 'PT422' or sqlstate 'PT404' then
        perform set_config('app.booking_reschedule', 'off', true);
        get stacked diagnostics v_code = message_text;
        if v_code not in ('point_not_bookable', 'blocked_period', 'outside_operating_hours', 'charging_point_not_found') then
          raise;
        end if;
        v_last := v_code;
    end;
  end loop;

  if v_last = 'outside_operating_hours' then
    perform private.raise_error(422, v_last);
  end if;
  perform private.raise_error(409, 'station_full', 'Every charging point is booked for this time. Please choose another time.');
end;
$$;

-------------------------------------------------------------------------------
-- 4. Station ratings
-------------------------------------------------------------------------------

create table public.station_reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings (id) on delete cascade,
  station_id uuid not null references public.stations (id) on delete cascade,
  customer_id uuid not null references public.profiles (id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text check (comment is null or char_length(comment) <= 500),
  hidden_at timestamptz,
  hidden_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index station_reviews_station_idx on public.station_reviews (station_id, created_at desc) where hidden_at is null;
create trigger station_reviews_updated_at before update on public.station_reviews
  for each row execute function private.set_updated_at();

alter table public.station_reviews enable row level security;
-- No direct table access: everything goes through the functions below.

-- Customer rates a station after a booking there was completed (or charging
-- started). Rating again within 30 days replaces the earlier one.
create or replace function public.submit_station_review(p_booking_id uuid, p_rating int, p_comment text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_b public.bookings;
  v_r public.station_reviews;
  v_comment text := nullif(trim(coalesce(p_comment, '')), '');
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  select * into v_b from public.bookings where id = p_booking_id and customer_id = v_user;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if v_b.status not in ('completed', 'in_progress') then
    perform private.raise_error(409, 'review_not_allowed', 'You can rate a station after charging there');
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    perform private.raise_error(422, 'invalid_rating');
  end if;
  if char_length(v_comment) > 500 then
    perform private.raise_error(422, 'comment_too_long');
  end if;
  select * into v_r from public.station_reviews where booking_id = v_b.id;
  if found and v_r.created_at < now() - interval '30 days' then
    perform private.raise_error(409, 'review_locked', 'Reviews can be changed for 30 days');
  end if;
  insert into public.station_reviews (booking_id, station_id, customer_id, rating, comment)
  values (v_b.id, v_b.station_id, v_user, p_rating, v_comment)
  on conflict (booking_id) do update set rating = excluded.rating, comment = excluded.comment
  returning * into v_r;
  return jsonb_build_object('rating', v_r.rating, 'comment', v_r.comment, 'created_at', v_r.created_at, 'updated_at', v_r.updated_at);
end;
$$;

-- Average, count, star breakdown and the latest visible reviews. Reviewer
-- shown by first name only.
create or replace function public.get_station_reviews(p_station_id uuid, p_limit int default 10)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'average', (select round(avg(r.rating)::numeric, 1) from public.station_reviews r
                 where r.station_id = p_station_id and r.hidden_at is null),
    'count', (select count(*) from public.station_reviews r where r.station_id = p_station_id and r.hidden_at is null),
    'stars', (select jsonb_object_agg(s, (select count(*) from public.station_reviews r
                                           where r.station_id = p_station_id and r.hidden_at is null and r.rating = s))
                from generate_series(1, 5) s),
    'recent', coalesce((select jsonb_agg(x order by x ->> 'created_at' desc) from (
                select jsonb_build_object(
                         'rating', r.rating,
                         'comment', r.comment,
                         'name', coalesce(nullif(split_part(trim(coalesce(pr.full_name, '')), ' ', 1), ''), 'Customer'),
                         'created_at', r.created_at) as x
                  from public.station_reviews r
                  left join public.profiles pr on pr.id = r.customer_id
                 where r.station_id = p_station_id and r.hidden_at is null
                 order by r.created_at desc
                 limit least(greatest(coalesce(p_limit, 10), 0), 50)) t), '[]'::jsonb)
  )
  where private.is_public_station(p_station_id)
     or private.has_station_permission(p_station_id, 'bookings.view')
     or private.is_platform_staff();
$$;

-- Platform staff hide abusive reviews (or show them again).
create or replace function public.admin_set_review_hidden(p_review_id uuid, p_hidden boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_staff() then
    perform private.raise_error(403, 'forbidden');
  end if;
  update public.station_reviews
     set hidden_at = case when p_hidden then now() end,
         hidden_by = case when p_hidden then (select auth.uid()) end
   where id = p_review_id;
  if not found then
    perform private.raise_error(404, 'review_not_found');
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Booking JSON: reschedule state and the customer's own rating
-------------------------------------------------------------------------------

create or replace function private.booking_json(p_booking public.bookings)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_booking.id,
    'reference', p_booking.reference,
    'station_id', p_booking.station_id,
    'charging_point_id', p_booking.charging_point_id,
    'start_at', lower(p_booking.period),
    'end_at', upper(p_booking.period),
    'status', p_booking.status,
    'payment_status', p_booking.payment_status,
    'booking_fee_paise', p_booking.booking_fee_paise,
    'currency', p_booking.currency,
    'hold_expires_at', p_booking.hold_expires_at,
    'reschedule_count', p_booking.reschedule_count,
    'rescheduled_at', p_booking.rescheduled_at,
    'original_start_at', lower(p_booking.original_period),
    'original_end_at', upper(p_booking.original_period),
    'can_reschedule', private.reschedule_problem(p_booking) is null,
    'reschedule_problem', private.reschedule_problem(p_booking),
    'my_rating', (select r.rating from public.station_reviews r where r.booking_id = p_booking.id),
    'my_review_comment', (select r.comment from public.station_reviews r where r.booking_id = p_booking.id)
  );
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------

revoke execute on function
  private.point_status_from_booking(),
  private.max_reschedules(),
  private.reschedule_problem(public.bookings),
  public.reschedule_booking(uuid, timestamptz, timestamptz, public.connector_type),
  public.submit_station_review(uuid, int, text),
  public.get_station_reviews(uuid, int),
  public.admin_set_review_hidden(uuid, boolean)
from public, anon, authenticated;

grant execute on function public.get_station_reviews(uuid, int) to anon, authenticated;
grant execute on function
  public.reschedule_booking(uuid, timestamptz, timestamptz, public.connector_type),
  public.submit_station_review(uuid, int, text),
  public.admin_set_review_hidden(uuid, boolean)
to authenticated;
