-- Reservations, booking events, check-in, slot rules, blocked periods and the
-- station lifecycle operations that affect bookings.
--
-- Double booking is prevented by the exclusion constraint
-- bookings_no_overlap. Everything else here is policy validation; the
-- constraint is what makes concurrent requests safe.

create type public.booking_status as enum (
  'payment_pending', 'confirmed', 'arrived', 'in_progress', 'completed', 'cancelled', 'expired', 'no_show'
);

create type public.booking_payment_status as enum (
  'not_required',    -- booking fee was zero when the booking was made
  'pending',         -- awaiting booking-fee payment
  'paid',            -- verified by the server
  'failed',          -- last attempt failed; booking may still be retried until the hold expires
  'abandoned',       -- hold expired without a successful payment
  'refund_pending',  -- refund requested, not yet processed by the gateway
  'refunded'         -- refund processed
);

create type public.actor_kind as enum ('customer', 'business', 'platform', 'system');

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique default ('CK' || private.random_code(10)),
  -- Opaque value encoded in the QR code. Contains no personal data.
  qr_token text not null unique default private.random_token(16),
  customer_id uuid not null references public.profiles (id) on delete restrict,
  station_id uuid not null references public.stations (id) on delete restrict,
  charging_point_id uuid not null references public.charging_points (id) on delete restrict,
  period tstzrange not null check (not isempty(period) and not lower_inf(period) and not upper_inf(period)
                                   and lower_inc(period) and not upper_inc(period)),
  buffer_minutes int not null default 0 check (buffer_minutes between 0 and 120),
  -- period extended by the station buffer; this is what the exclusion constraint compares.
  occupancy tstzrange not null,
  status public.booking_status not null,
  payment_status public.booking_payment_status not null,
  booking_fee_paise bigint not null check (booking_fee_paise >= 0),
  currency text not null default 'INR' check (currency = 'INR'),
  hold_expires_at timestamptz,
  customer_display_name text not null,
  vehicle_label text check (vehicle_label is null or char_length(vehicle_label) <= 80),
  idempotency_key text check (idempotency_key is null or char_length(idempotency_key) between 8 and 80),
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id),
  cancellation_actor public.actor_kind,
  cancellation_reason text,
  refund_eligible boolean,
  checked_in_at timestamptz,
  charging_started_at timestamptz,
  completed_at timestamptz,
  no_show_at timestamptz,
  expired_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (customer_id, idempotency_key),
  check (status <> 'payment_pending' or hold_expires_at is not null),
  check (status <> 'cancelled' or (cancelled_at is not null and cancellation_actor is not null)),
  constraint bookings_no_overlap exclude using gist (
    charging_point_id with =,
    occupancy with &&
  ) where (status in ('payment_pending', 'confirmed', 'arrived', 'in_progress'))
);

comment on constraint bookings_no_overlap on public.bookings is
  'Database-level guarantee that two active bookings never overlap on one charging point.';

create index bookings_station_period_idx on public.bookings using gist (station_id, period);
create index bookings_customer_idx on public.bookings (customer_id, created_at desc);
create index bookings_status_idx on public.bookings (status, (lower(period)));
create index bookings_hold_idx on public.bookings (hold_expires_at) where status = 'payment_pending';

create trigger bookings_updated_at before update on public.bookings
  for each row execute function private.set_updated_at();

create table public.booking_events (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings (id) on delete cascade,
  -- Denormalised so Realtime subscriptions can be scoped to one station.
  station_id uuid not null references public.stations (id) on delete cascade,
  from_status public.booking_status,
  to_status public.booking_status not null,
  from_payment_status public.booking_payment_status,
  to_payment_status public.booking_payment_status not null,
  actor_id uuid references public.profiles (id),
  actor public.actor_kind not null,
  note text,
  created_at timestamptz not null default now()
);

create index booking_events_booking_idx on public.booking_events (booking_id, created_at);
create index booking_events_station_idx on public.booking_events (station_id, created_at);
create trigger booking_events_immutable before update or delete on public.booking_events
  for each row execute function private.prevent_mutation();

create or replace function private.is_valid_booking_transition(
  p_from public.booking_status,
  p_to public.booking_status
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case p_from
    when 'payment_pending' then p_to in ('confirmed', 'expired', 'cancelled')
    when 'confirmed' then p_to in ('arrived', 'cancelled', 'no_show')
    when 'arrived' then p_to in ('in_progress', 'completed')
    when 'in_progress' then p_to in ('completed')
    -- A payment that arrives after the hold expired may revive the booking
    -- if the slot is still free (see record_gateway_payment).
    when 'expired' then p_to in ('confirmed')
    else false
  end;
$$;

-- Additional transitions only an audited admin override may perform.
create or replace function private.is_valid_override_transition(
  p_from public.booking_status,
  p_to public.booking_status
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select (p_from, p_to) in (
    ('no_show'::public.booking_status, 'completed'::public.booking_status),
    ('arrived', 'no_show'),
    ('arrived', 'cancelled'),
    ('in_progress', 'cancelled'),
    ('confirmed', 'completed')
  );
$$;

create or replace function private.booking_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.charging_point_id is distinct from old.charging_point_id
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

create trigger bookings_before_write before insert or update on public.bookings
  for each row execute function private.booking_before_write();

create or replace function private.booking_after_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor public.actor_kind := coalesce(nullif(current_setting('app.booking_actor', true), '')::public.actor_kind, 'system');
  v_note text := nullif(current_setting('app.booking_note', true), '');
begin
  if tg_op = 'INSERT' then
    insert into public.booking_events (booking_id, station_id, from_status, to_status, from_payment_status, to_payment_status, actor_id, actor, note)
    values (new.id, new.station_id, null, new.status, null, new.payment_status, (select auth.uid()), v_actor, v_note);
  elsif new.status is distinct from old.status or new.payment_status is distinct from old.payment_status then
    insert into public.booking_events (booking_id, station_id, from_status, to_status, from_payment_status, to_payment_status, actor_id, actor, note)
    values (new.id, new.station_id, old.status, new.status, old.payment_status, new.payment_status, (select auth.uid()), v_actor, v_note);
  end if;
  return new;
end;
$$;

create trigger bookings_after_write after insert or update on public.bookings
  for each row execute function private.booking_after_write();

-- Sets who is acting for the booking_events written by the trigger above.
create or replace function private.set_booking_context(p_actor public.actor_kind, p_note text default null)
returns void
language sql
set search_path = ''
as $$
  select set_config('app.booking_actor', p_actor::text, true), set_config('app.booking_note', coalesce(p_note, ''), true);
$$;

create table public.check_ins (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings (id) on delete restrict,  -- one check-in per booking
  station_id uuid not null references public.stations (id),
  checked_in_by uuid not null references public.profiles (id),
  method text not null check (method in ('qr', 'reference')),
  created_at timestamptz not null default now()
);

create trigger check_ins_immutable before update or delete on public.check_ins
  for each row execute function private.prevent_mutation();

create table public.booking_support_notes (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings (id) on delete cascade,
  author_id uuid not null references public.profiles (id) default auth.uid(),
  note text not null check (char_length(trim(note)) between 2 and 2000),
  created_at timestamptz not null default now()
);

create trigger booking_support_notes_immutable before update or delete on public.booking_support_notes
  for each row execute function private.prevent_mutation();

-------------------------------------------------------------------------------
-- Slot rules
-------------------------------------------------------------------------------

-- Raises a 4xx error if the period violates any station or point rule.
-- Does not check other bookings: the exclusion constraint does that.
create or replace function private.assert_bookable(p_point uuid, p_start timestamptz, p_end timestamptz)
returns void
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
  v_local_start timestamp;
  v_local_end timestamp;
  v_dow int;
  v_start_min int;
  v_end_min int;
  v_minutes numeric;
  v_max int;
begin
  if p_start is null or p_end is null or p_end <= p_start then
    perform private.raise_error(422, 'invalid_period', 'End must be after start');
  end if;
  select * into v_point from public.charging_points where id = p_point and archived_at is null;
  if not found then
    perform private.raise_error(404, 'charging_point_not_found');
  end if;
  select * into v_station from public.stations where id = v_point.station_id;
  select status into v_business_status from public.businesses where id = v_station.business_id;
  select * into v_policy from public.station_booking_policies where station_id = v_station.id;

  if v_station.status <> 'active' or v_business_status <> 'active' then
    perform private.raise_error(409, 'station_not_bookable', 'This station is not accepting reservations');
  end if;
  if not v_point.booking_enabled or v_point.operational_status not in ('available', 'in_use') then
    perform private.raise_error(409, 'point_not_bookable', 'This charging point is not accepting reservations');
  end if;

  if p_start < now() + make_interval(mins => v_policy.min_advance_minutes) then
    perform private.raise_error(422, 'too_soon', format('Book at least %s minutes in advance', v_policy.min_advance_minutes));
  end if;
  if p_start > now() + make_interval(days => v_policy.max_advance_days) then
    perform private.raise_error(422, 'too_far_ahead', format('Book at most %s days ahead', v_policy.max_advance_days));
  end if;

  v_minutes := extract(epoch from (p_end - p_start)) / 60;
  v_max := least(v_policy.max_booking_minutes, coalesce(v_point.max_booking_minutes_override, v_policy.max_booking_minutes));
  if v_minutes < v_policy.min_booking_minutes or v_minutes > v_max then
    perform private.raise_error(422, 'invalid_duration',
      format('Duration must be between %s and %s minutes', v_policy.min_booking_minutes, v_max));
  end if;
  if v_minutes <> trunc(v_minutes) or v_minutes::int % v_policy.slot_duration_minutes <> 0 then
    perform private.raise_error(422, 'invalid_duration', format('Duration must be a multiple of %s minutes', v_policy.slot_duration_minutes));
  end if;

  -- Operating hours are evaluated in the station's local time, so DST
  -- transitions (where applicable) are handled by the tz database.
  v_local_start := p_start at time zone v_station.timezone;
  v_local_end := p_end at time zone v_station.timezone;
  v_dow := extract(isodow from v_local_start)::int;
  v_start_min := extract(hour from v_local_start)::int * 60 + extract(minute from v_local_start)::int;
  if extract(second from v_local_start) <> 0 or v_start_min % v_policy.slot_duration_minutes <> 0 then
    perform private.raise_error(422, 'slot_misaligned', format('Start must align to %s-minute slots', v_policy.slot_duration_minutes));
  end if;
  if v_local_end::date = v_local_start::date then
    v_end_min := extract(hour from v_local_end)::int * 60 + extract(minute from v_local_end)::int;
  elsif v_local_end = (v_local_start::date + 1)::timestamp then
    v_end_min := 1440;
  else
    perform private.raise_error(422, 'outside_operating_hours', 'A booking cannot span midnight');
  end if;

  if not exists (
    select 1 from public.station_operating_hours h
     where h.station_id = v_station.id and h.charging_point_id is null and h.day_of_week = v_dow
       and h.opens_minute <= v_start_min and h.closes_minute >= v_end_min) then
    perform private.raise_error(422, 'outside_operating_hours', 'The station is closed for part of this period');
  end if;
  if exists (select 1 from public.station_operating_hours h where h.charging_point_id = p_point)
     and not exists (
       select 1 from public.station_operating_hours h
        where h.charging_point_id = p_point and h.day_of_week = v_dow
          and h.opens_minute <= v_start_min and h.closes_minute >= v_end_min) then
    perform private.raise_error(422, 'outside_operating_hours', 'This charging point is not bookable for part of this period');
  end if;

  if exists (
    select 1 from public.blocked_periods b
     where b.station_id = v_station.id and b.cancelled_at is null
       and (b.charging_point_id is null or b.charging_point_id = p_point)
       and b.period && tstzrange(p_start, p_end + make_interval(mins => v_policy.buffer_minutes), '[)')) then
    perform private.raise_error(409, 'blocked_period', 'The point is unavailable (maintenance or closure) during this period');
  end if;
  if v_station.closed_until is not null and p_start < v_station.closed_until then
    perform private.raise_error(409, 'station_not_bookable', 'The station is temporarily closed');
  end if;
end;
$$;

create or replace function private.display_name_for(p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- First name plus last initial: enough for staff to greet the customer.
  select coalesce(
    nullif(trim(split_part(p.full_name, ' ', 1) ||
           case when position(' ' in trim(p.full_name)) > 0
                then ' ' || left(reverse(split_part(reverse(trim(p.full_name)), ' ', 1)), 1) || '.' else '' end), ''),
    'Customer')
  from public.profiles p where p.id = p_user;
$$;

-- Customer-facing booking projection (no internal ids of other users).
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
    'hold_expires_at', p_booking.hold_expires_at
  );
$$;

-------------------------------------------------------------------------------
-- Customer RPCs (used by the future Retailer App)
-------------------------------------------------------------------------------

create or replace function public.create_booking_hold(
  p_charging_point_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_idempotency_key text,
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
  v_booking public.bookings;
  v_fee bigint;
  v_hold int;
  v_station uuid;
  v_buffer int;
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 80 then
    perform private.raise_error(422, 'idempotency_key_required');
  end if;
  -- Retried request: return the original result instead of a second booking.
  select * into v_existing from public.bookings where customer_id = v_user and idempotency_key = p_idempotency_key;
  if found then
    return private.booking_json(v_existing);
  end if;

  -- Abuse limits: open holds and booking attempts per hour.
  if (select count(*) from public.bookings where customer_id = v_user and status = 'payment_pending' and hold_expires_at > now()) >= 2 then
    perform private.raise_error(409, 'too_many_pending_holds', 'Complete or cancel your pending booking first');
  end if;
  if (select count(*) from public.bookings where customer_id = v_user and created_at > now() - interval '1 hour') >= 10 then
    perform private.raise_error(409, 'rate_limited', 'Too many booking attempts; try again later');
  end if;

  perform private.assert_bookable(p_charging_point_id, p_start_at, p_end_at);

  select station_id into v_station from public.charging_points where id = p_charging_point_id;
  select buffer_minutes into v_buffer from public.station_booking_policies where station_id = v_station;
  v_fee := (private.setting('booking_fee_paise'))::bigint;
  v_hold := (private.setting('payment_hold_minutes'))::int;

  perform private.set_booking_context('system', 'Expired stale hold before new booking');
  update public.bookings
     set status = 'expired', payment_status = 'abandoned', expired_at = now()
   where charging_point_id = p_charging_point_id and status = 'payment_pending' and hold_expires_at <= now();

  perform private.set_booking_context('customer', null);
  begin
    insert into public.bookings (customer_id, station_id, charging_point_id, period, buffer_minutes, occupancy,
                                 status, payment_status, booking_fee_paise, hold_expires_at, confirmed_at,
                                 customer_display_name, vehicle_label, idempotency_key)
    values (v_user, v_station, p_charging_point_id, tstzrange(p_start_at, p_end_at, '[)'), v_buffer,
            tstzrange(p_start_at, p_end_at, '[)'),
            case when v_fee = 0 then 'confirmed'::public.booking_status else 'payment_pending' end,
            case when v_fee = 0 then 'not_required'::public.booking_payment_status else 'pending' end,
            v_fee,
            case when v_fee = 0 then null else now() + make_interval(mins => v_hold) end,
            case when v_fee = 0 then now() end,
            private.display_name_for(v_user), nullif(trim(p_vehicle_label), ''), p_idempotency_key)
    returning * into v_booking;
  exception
    when exclusion_violation then
      perform private.raise_error(409, 'slot_unavailable', 'This slot was just taken. Please choose another slot.');
    when unique_violation then
      -- Same idempotency key raced with itself.
      select * into v_booking from public.bookings where customer_id = v_user and idempotency_key = p_idempotency_key;
      if not found then
        raise;
      end if;
      return private.booking_json(v_booking);
  end;

  if v_booking.status = 'confirmed' then
    perform private.on_booking_confirmed(v_booking.id);
  end if;
  return private.booking_json(v_booking);
end;
$$;

create or replace function private.on_booking_confirmed(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_s public.stations;
  v_point_code text;
begin
  select * into v_b from public.bookings where id = p_booking;
  select * into v_s from public.stations where id = v_b.station_id;
  select code into v_point_code from public.charging_points where id = v_b.charging_point_id;
  perform private.notify_business(v_s.business_id, v_s.id, 'bookings.view', 'booking', 'booking.confirmed',
    'New booking', format('%s booked point %s on %s.', v_b.customer_display_name, v_point_code,
      to_char(lower(v_b.period) at time zone v_s.timezone, 'DD Mon HH24:MI')),
    jsonb_build_object('booking_id', v_b.id, 'station_id', v_s.id), 'booking.confirmed:' || v_b.id);
  perform private.notify(v_b.customer_id, 'booking', 'booking.confirmed', 'Booking confirmed',
    format('Your slot at %s on %s is confirmed. Reference %s.', v_s.name,
      to_char(lower(v_b.period) at time zone v_s.timezone, 'DD Mon HH24:MI'), v_b.reference),
    jsonb_build_object('booking_id', v_b.id), 'booking.confirmed.customer:' || v_b.id);
end;
$$;

-- Busy intervals for a point (no customer data). Used by booking calendars.
create or replace function public.get_point_busy_periods(p_charging_point_id uuid, p_from timestamptz, p_to timestamptz)
returns table (starts_at timestamptz, ends_at timestamptz, kind text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_station uuid;
begin
  select station_id into v_station from public.charging_points where id = p_charging_point_id;
  if v_station is null then
    perform private.raise_error(404, 'charging_point_not_found');
  end if;
  if not (exists (select 1 from public.stations where id = v_station and status = 'active')
          or private.can_view_station(v_station) or private.has_platform_permission('bookings.read_all')) then
    perform private.raise_error(403, 'forbidden');
  end if;
  if p_to - p_from > interval '93 days' then
    perform private.raise_error(422, 'range_too_large');
  end if;
  return query
    select lower(b.occupancy), upper(b.occupancy), 'booking'::text
      from public.bookings b
     where b.charging_point_id = p_charging_point_id
       and b.status in ('payment_pending', 'confirmed', 'arrived', 'in_progress')
       and b.occupancy && tstzrange(p_from, p_to)
    union all
    select lower(bp.period), upper(bp.period), bp.kind::text
      from public.blocked_periods bp
     where bp.station_id = v_station and bp.cancelled_at is null
       and (bp.charging_point_id is null or bp.charging_point_id = p_charging_point_id)
       and bp.period && tstzrange(p_from, p_to)
    order by 1;
end;
$$;

-------------------------------------------------------------------------------
-- Cancellation
-------------------------------------------------------------------------------

create or replace function private.cancel_booking_internal(
  p_booking_id uuid,
  p_actor public.actor_kind,
  p_reason text,
  p_refund_override boolean default null
)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_policy jsonb := private.setting('refund_policy');
  v_eligible boolean;
  v_s public.stations;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.status not in ('payment_pending', 'confirmed') and current_setting('app.booking_override', true) is distinct from 'on' then
    perform private.raise_error(409, 'not_cancellable', format('A %s booking cannot be cancelled', v_b.status));
  end if;

  v_eligible := case
    when v_b.payment_status <> 'paid' then false
    when p_refund_override is not null then p_refund_override
    when p_actor = 'customer' then
      (v_policy ->> 'customer_cancellation_refundable')::boolean
      and now() <= lower(v_b.period) - make_interval(mins => (v_policy ->> 'customer_cancellation_cutoff_minutes')::int)
    when p_actor in ('business', 'platform', 'system') then (v_policy ->> 'business_cancellation_refundable')::boolean
    else false
  end;

  perform private.set_booking_context(p_actor, p_reason);
  update public.bookings
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = (select auth.uid()),
         cancellation_actor = p_actor,
         cancellation_reason = p_reason,
         refund_eligible = v_eligible,
         payment_status = case when v_b.payment_status = 'pending' then 'abandoned'::public.booking_payment_status
                               else v_b.payment_status end,
         hold_expires_at = null
   where id = p_booking_id
  returning * into v_b;

  if v_eligible then
    perform private.create_refund_request(p_booking_id, v_b.booking_fee_paise,
      format('Automatic refund under policy: %s cancellation', p_actor), true);
  end if;

  select * into v_s from public.stations where id = v_b.station_id;
  if p_actor = 'customer' then
    perform private.notify_business(v_s.business_id, v_s.id, 'bookings.view', 'booking', 'booking.cancelled',
      'Booking cancelled', format('%s cancelled booking %s.', v_b.customer_display_name, v_b.reference),
      jsonb_build_object('booking_id', v_b.id, 'station_id', v_s.id), 'booking.cancelled:' || v_b.id);
  else
    perform private.notify(v_b.customer_id, 'booking', 'booking.cancelled', 'Booking cancelled',
      format('Your booking %s at %s was cancelled: %s', v_b.reference, v_s.name, coalesce(p_reason, 'no reason given')),
      jsonb_build_object('booking_id', v_b.id), 'booking.cancelled.customer:' || v_b.id);
    if p_actor <> 'business' then
      perform private.notify_business(v_s.business_id, v_s.id, 'bookings.view', 'booking', 'booking.cancelled',
        'Booking cancelled', format('Booking %s was cancelled by the platform.', v_b.reference),
        jsonb_build_object('booking_id', v_b.id, 'station_id', v_s.id), 'booking.cancelled:' || v_b.id);
    end if;
  end if;
  return v_b;
end;
$$;

create or replace function public.cancel_booking(p_booking_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_actor public.actor_kind;
  v_policy public.station_booking_policies;
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if v_b.customer_id = (select auth.uid()) then
    v_actor := 'customer';
    select * into v_policy from public.station_booking_policies where station_id = v_b.station_id;
    if v_b.status = 'confirmed' and now() > lower(v_b.period) - make_interval(mins => v_policy.customer_cancel_until_minutes) then
      perform private.raise_error(409, 'cancellation_window_closed');
    end if;
  elsif private.has_station_permission(v_b.station_id, 'bookings.manage') then
    v_actor := 'business';
    if char_length(trim(coalesce(p_reason, ''))) < 3 then
      perform private.raise_error(422, 'reason_required');
    end if;
  else
    perform private.raise_error(404, 'booking_not_found');
  end if;
  v_b := private.cancel_booking_internal(p_booking_id, v_actor, nullif(trim(p_reason), ''));
  perform private.write_audit('booking.cancel', 'bookings', p_booking_id::text, null,
    jsonb_build_object('actor', v_actor, 'refund_eligible', v_b.refund_eligible), p_reason);
  return private.booking_json(v_b);
end;
$$;

-------------------------------------------------------------------------------
-- Check-in and operational events (manual, no charger control)
-------------------------------------------------------------------------------

create or replace function private.staff_booking_json(p_b public.bookings)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.booking_json(p_b) || jsonb_build_object(
    'customer_display_name', p_b.customer_display_name,
    'vehicle_label', p_b.vehicle_label,
    'charging_point_code', (select code from public.charging_points where id = p_b.charging_point_id),
    'station_name', (select name from public.stations where id = p_b.station_id),
    'checked_in_at', p_b.checked_in_at,
    'charging_started_at', p_b.charging_started_at,
    'completed_at', p_b.completed_at,
    'cancelled_at', p_b.cancelled_at,
    'cancellation_reason', p_b.cancellation_reason
  );
$$;

-- Accepts either the QR payload (CKB1:<token> or the bare token) or the
-- human-readable reference. Returns 404 for bookings of other stations so
-- staff cannot probe references across businesses.
create or replace function public.lookup_booking_for_checkin(p_station_id uuid, p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_code text := trim(coalesce(p_code, ''));
  v_b public.bookings;
begin
  perform private.require_station_permission(p_station_id, 'bookings.checkin');
  if v_code like 'CKB1:%' then
    v_code := substr(v_code, 6);
  end if;
  select * into v_b from public.bookings
   where station_id = p_station_id and (qr_token = v_code or reference = upper(v_code));
  if not found then
    perform private.raise_error(404, 'booking_not_found', 'No booking with this code at this station');
  end if;
  return private.staff_booking_json(v_b);
end;
$$;

create or replace function public.check_in_booking(p_station_id uuid, p_code text, p_method text default 'reference')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := trim(coalesce(p_code, ''));
  v_b public.bookings;
  v_policy public.station_booking_policies;
begin
  perform private.require_station_permission(p_station_id, 'bookings.checkin');
  if p_method not in ('qr', 'reference') then
    perform private.raise_error(422, 'invalid_method');
  end if;
  if v_code like 'CKB1:%' then
    v_code := substr(v_code, 6);
  end if;
  select * into v_b from public.bookings
   where station_id = p_station_id and (qr_token = v_code or reference = upper(v_code))
   for update;
  if not found then
    perform private.raise_error(404, 'booking_not_found', 'No booking with this code at this station');
  end if;
  if v_b.checked_in_at is not null or v_b.status in ('arrived', 'in_progress', 'completed') then
    perform private.raise_error(409, 'already_checked_in', 'This booking has already been checked in');
  end if;
  if v_b.status <> 'confirmed' then
    perform private.raise_error(409, 'booking_not_checkinable', format('Booking is %s', v_b.status));
  end if;
  if v_b.payment_status not in ('paid', 'not_required') then
    perform private.raise_error(409, 'booking_fee_unpaid');
  end if;
  select * into v_policy from public.station_booking_policies where station_id = v_b.station_id;
  if now() < lower(v_b.period) - make_interval(mins => v_policy.early_checkin_minutes) then
    perform private.raise_error(409, 'too_early', format('Check-in opens %s minutes before the slot', v_policy.early_checkin_minutes));
  end if;
  if now() > lower(v_b.period) + make_interval(mins => v_policy.arrival_grace_minutes) then
    perform private.raise_error(409, 'grace_period_over', 'The arrival grace period has ended');
  end if;
  insert into public.check_ins (booking_id, station_id, checked_in_by, method)
  values (v_b.id, p_station_id, (select auth.uid()), p_method);
  perform private.set_booking_context('business', 'Checked in via ' || p_method);
  update public.bookings set status = 'arrived', checked_in_at = now() where id = v_b.id returning * into v_b;
  perform private.notify(v_b.customer_id, 'booking', 'booking.checked_in', 'Checked in',
    format('You are checked in for booking %s.', v_b.reference), jsonb_build_object('booking_id', v_b.id),
    'booking.checked_in.customer:' || v_b.id);
  perform private.notify_business((select business_id from public.stations where id = p_station_id), p_station_id,
    'bookings.view', 'booking', 'booking.checked_in', 'Customer checked in',
    format('%s checked in for %s.', v_b.customer_display_name, v_b.reference),
    jsonb_build_object('booking_id', v_b.id, 'station_id', p_station_id), 'booking.checked_in:' || v_b.id);
  return private.staff_booking_json(v_b);
end;
$$;

create or replace function public.update_booking_progress(p_booking_id uuid, p_status public.booking_status)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_policy public.station_booking_policies;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if p_status in ('in_progress', 'completed') then
    perform private.require_station_permission(v_b.station_id, 'bookings.checkin');
  elsif p_status = 'no_show' then
    perform private.require_station_permission(v_b.station_id, 'bookings.manage');
    select * into v_policy from public.station_booking_policies where station_id = v_b.station_id;
    -- Never release a slot before the grace period ends.
    if now() <= lower(v_b.period) + make_interval(mins => v_policy.arrival_grace_minutes) then
      perform private.raise_error(409, 'grace_period_active', 'A no-show can be recorded only after the grace period');
    end if;
  else
    perform private.raise_error(422, 'invalid_status', 'Use check-in or cancel for other changes');
  end if;
  perform private.set_booking_context('business', null);
  update public.bookings
     set status = p_status,
         charging_started_at = case when p_status = 'in_progress' then now() else charging_started_at end,
         completed_at = case when p_status = 'completed' then now() else completed_at end,
         no_show_at = case when p_status = 'no_show' then now() else no_show_at end
   where id = p_booking_id
  returning * into v_b;
  if p_status = 'no_show' then
    perform private.notify(v_b.customer_id, 'booking', 'booking.no_show', 'Marked as no-show',
      format('Booking %s was marked as a no-show.', v_b.reference), jsonb_build_object('booking_id', v_b.id),
      'booking.no_show.customer:' || v_b.id);
  end if;
  return private.staff_booking_json(v_b);
end;
$$;

create or replace function public.admin_override_booking(
  p_booking_id uuid,
  p_status public.booking_status,
  p_reason text,
  p_refund boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before public.bookings;
  v_b public.bookings;
begin
  perform private.require_platform_permission('bookings.override');
  if char_length(trim(coalesce(p_reason, ''))) < 5 then
    perform private.raise_error(422, 'reason_required', 'Overrides require a reason');
  end if;
  select * into v_before from public.bookings where id = p_booking_id for update;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if p_refund is not null and not private.has_platform_permission('finance.refunds.issue') then
    perform private.raise_error(403, 'forbidden', 'Refund decisions need finance.refunds.issue');
  end if;
  perform set_config('app.booking_override', 'on', true);
  if p_status = 'cancelled' then
    v_b := private.cancel_booking_internal(p_booking_id, 'platform', trim(p_reason), p_refund);
  else
    perform private.set_booking_context('platform', trim(p_reason));
    update public.bookings
       set status = p_status,
           completed_at = case when p_status = 'completed' then coalesce(completed_at, now()) else completed_at end,
           no_show_at = case when p_status = 'no_show' then now() else no_show_at end
     where id = p_booking_id
    returning * into v_b;
  end if;
  perform set_config('app.booking_override', 'off', true);
  perform private.write_audit('booking.override', 'bookings', p_booking_id::text,
    jsonb_build_object('status', v_before.status, 'payment_status', v_before.payment_status),
    jsonb_build_object('status', v_b.status, 'payment_status', v_b.payment_status, 'refund', p_refund),
    p_reason);
  return private.staff_booking_json(v_b);
exception when exclusion_violation then
  perform private.raise_error(409, 'slot_unavailable', 'Another booking now occupies this slot');
end;
$$;

create or replace function public.add_booking_support_note(p_booking_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('bookings.support_notes');
  if not exists (select 1 from public.bookings where id = p_booking_id) then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  insert into public.booking_support_notes (booking_id, author_id, note) values (p_booking_id, (select auth.uid()), trim(p_note));
end;
$$;

-------------------------------------------------------------------------------
-- Availability management
-------------------------------------------------------------------------------

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
  select array_agg(b.id) into v_conflicts from public.bookings b
   where b.station_id = p_station_id
     and (p_charging_point_id is null or b.charging_point_id = p_charging_point_id)
     and b.status in ('payment_pending', 'confirmed')
     and b.occupancy && tstzrange(p_starts_at, p_ends_at, '[)');
  if v_conflicts is not null and not coalesce(p_cancel_conflicting, false) then
    perform private.raise_error(409, 'bookings_conflict',
      format('%s booking(s) overlap this period. Confirm cancellation to continue.', cardinality(v_conflicts)));
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
  return jsonb_build_object('blocked_period_id', v_id, 'cancelled_bookings', coalesce(cardinality(v_conflicts), 0));
end;
$$;

create or replace function public.cancel_blocked_period(p_blocked_period_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_station uuid;
begin
  select station_id into v_station from public.blocked_periods where id = p_blocked_period_id and cancelled_at is null;
  if v_station is null then
    perform private.raise_error(404, 'blocked_period_not_found');
  end if;
  perform private.require_station_permission(v_station, 'availability.edit');
  update public.blocked_periods set cancelled_at = now(), cancelled_by = (select auth.uid()) where id = p_blocked_period_id;
end;
$$;

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
  select count(*) into v_upcoming from public.bookings
   where charging_point_id = p_charging_point_id and status in ('payment_pending', 'confirmed')
     and upper(period) > now();
  return jsonb_build_object('status', p_status, 'status_source', 'manual', 'upcoming_bookings', v_upcoming);
end;
$$;

-------------------------------------------------------------------------------
-- Station lifecycle
-------------------------------------------------------------------------------

create or replace function private.cancel_future_station_bookings(p_station uuid, p_reason text, p_actor public.actor_kind)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_count int := 0;
begin
  for v_id in
    select id from public.bookings
     where station_id = p_station and status in ('payment_pending', 'confirmed') and lower(period) > now()
     order by lower(period)
  loop
    perform private.cancel_booking_internal(v_id, p_actor, p_reason);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.suspend_station(p_station_id uuid, p_reason text, p_cancel_future_bookings boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.stations;
  v_app uuid;
  v_cancelled int := 0;
begin
  perform private.require_platform_permission('stations.suspend');
  if char_length(trim(coalesce(p_reason, ''))) < 5 then
    perform private.raise_error(422, 'reason_required');
  end if;
  select * into v_s from public.stations where id = p_station_id for update;
  if not found then
    perform private.raise_error(404, 'station_not_found');
  end if;
  perform private.require_reviewer_not_member(v_s.business_id);
  if v_s.status not in ('active', 'temporarily_closed') then
    perform private.raise_error(409, 'invalid_status_transition', format('A %s station cannot be suspended', v_s.status));
  end if;
  update public.stations set status = 'suspended', status_reason = trim(p_reason) where id = p_station_id;
  select id into v_app from public.station_applications where station_id = p_station_id;
  perform private.application_transition(v_app, 'suspended', trim(p_reason));
  if p_cancel_future_bookings then
    v_cancelled := private.cancel_future_station_bookings(p_station_id, 'Station suspended by the platform', 'platform');
  end if;
  perform private.write_audit('station.suspend', 'stations', p_station_id::text,
    jsonb_build_object('status', v_s.status), jsonb_build_object('status', 'suspended', 'cancelled_bookings', v_cancelled), p_reason);
  perform private.notify_business(v_s.business_id, p_station_id, null, 'station', 'station.suspended',
    'Station suspended', format('%s was suspended: %s', v_s.name, trim(p_reason)),
    jsonb_build_object('station_id', p_station_id), format('station.suspended:%s:%s', p_station_id, now()));
  return jsonb_build_object('status', 'suspended', 'cancelled_bookings', v_cancelled);
end;
$$;

create or replace function public.reactivate_station(p_station_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.stations;
  v_app uuid;
begin
  perform private.require_platform_permission('stations.suspend');
  if char_length(trim(coalesce(p_note, ''))) < 5 then
    perform private.raise_error(422, 'note_required', 'Record the review outcome before reactivating');
  end if;
  select * into v_s from public.stations where id = p_station_id for update;
  if not found then
    perform private.raise_error(404, 'station_not_found');
  end if;
  perform private.require_reviewer_not_member(v_s.business_id);
  if v_s.status <> 'suspended' then
    perform private.raise_error(409, 'invalid_status_transition', 'Only suspended stations can be reactivated');
  end if;
  update public.stations set status = 'active', status_reason = null where id = p_station_id;
  select id into v_app from public.station_applications where station_id = p_station_id;
  perform private.application_transition(v_app, 'approved', trim(p_note));
  perform private.write_audit('station.reactivate', 'stations', p_station_id::text,
    jsonb_build_object('status', 'suspended'), jsonb_build_object('status', 'active'), p_note);
  perform private.notify_business(v_s.business_id, p_station_id, null, 'station', 'station.reactivated',
    'Station reactivated', format('%s is active again.', v_s.name),
    jsonb_build_object('station_id', p_station_id), format('station.reactivated:%s:%s', p_station_id, now()));
end;
$$;

create or replace function public.close_station_temporarily(
  p_station_id uuid,
  p_until timestamptz,
  p_reason text,
  p_cancel_conflicting boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.stations;
  v_result jsonb;
begin
  perform private.require_station_permission(p_station_id, 'availability.edit');
  select * into v_s from public.stations where id = p_station_id for update;
  if v_s.status <> 'active' then
    perform private.raise_error(409, 'invalid_status_transition', 'Only active stations can be closed');
  end if;
  if p_until is null or p_until <= now() or p_until > now() + interval '180 days' then
    perform private.raise_error(422, 'invalid_period', 'Choose a reopening time within 180 days');
  end if;
  v_result := public.create_blocked_period(p_station_id, null, now(), p_until, 'temporary_closure', p_reason, p_cancel_conflicting);
  update public.stations set status = 'temporarily_closed', closed_until = p_until, status_reason = p_reason where id = p_station_id;
  perform private.write_audit('station.close_temporarily', 'stations', p_station_id::text, null,
    jsonb_build_object('closed_until', p_until), p_reason);
  return v_result;
end;
$$;

create or replace function public.reopen_station(p_station_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_station_permission(p_station_id, 'availability.edit');
  update public.stations set status = 'active', closed_until = null, status_reason = null
   where id = p_station_id and status = 'temporarily_closed';
  if not found then
    perform private.raise_error(409, 'invalid_status_transition', 'Station is not temporarily closed');
  end if;
  update public.blocked_periods set cancelled_at = now(), cancelled_by = (select auth.uid())
   where station_id = p_station_id and kind = 'temporary_closure' and cancelled_at is null and upper(period) > now();
  perform private.write_audit('station.reopen', 'stations', p_station_id::text);
end;
$$;

create or replace function public.request_station_deactivation(p_station_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.stations;
begin
  select * into v_s from public.stations where id = p_station_id;
  if not found or not private.is_business_owner(v_s.business_id) then
    perform private.raise_error(403, 'forbidden', 'Only the business owner can request deactivation');
  end if;
  if v_s.status = 'deactivated' then
    perform private.raise_error(409, 'already_deactivated');
  end if;
  update public.stations set deactivation_requested_at = now(), deactivation_request_reason = p_reason where id = p_station_id;
  perform private.write_audit('station.request_deactivation', 'stations', p_station_id::text, null, null, p_reason);
  perform private.notify_platform_staff('stations.manage', 'station', 'station.deactivation_requested',
    'Station deactivation requested', format('%s requested permanent deactivation.', v_s.name),
    jsonb_build_object('station_id', p_station_id), 'station.deactivation_requested:' || p_station_id);
end;
$$;

create or replace function public.deactivate_station(p_station_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s public.stations;
  v_cancelled int;
begin
  perform private.require_platform_permission('stations.manage');
  if char_length(trim(coalesce(p_reason, ''))) < 5 then
    perform private.raise_error(422, 'reason_required');
  end if;
  select * into v_s from public.stations where id = p_station_id for update;
  if not found then
    perform private.raise_error(404, 'station_not_found');
  end if;
  v_cancelled := private.cancel_future_station_bookings(p_station_id, 'Station permanently closed', 'platform');
  update public.stations set status = 'deactivated', status_reason = p_reason,
                             approved_at = coalesce(approved_at, now())
   where id = p_station_id;
  perform private.write_audit('station.deactivate', 'stations', p_station_id::text,
    jsonb_build_object('status', v_s.status), jsonb_build_object('status', 'deactivated', 'cancelled_bookings', v_cancelled), p_reason);
  perform private.notify_business(v_s.business_id, p_station_id, null, 'station', 'station.deactivated',
    'Station deactivated', format('%s has been deactivated.', v_s.name),
    jsonb_build_object('station_id', p_station_id), 'station.deactivated:' || p_station_id);
  return jsonb_build_object('cancelled_bookings', v_cancelled);
end;
$$;
