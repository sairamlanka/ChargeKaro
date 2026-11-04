-- Reminders, waitlist and booking for someone else (2026-11-04).
--   1. Reminders: the SMS/email reminder goes 30 minutes before the slot
--      (was 30-70), a moved booking gets its own reminder, and in-app/push
--      notifications are added for 30 minutes before, check-in open and
--      5 minutes before the late window closes. The customer app also
--      schedules the same three on the phone, so they work before Firebase.
--   2. Waitlist: a customer waits for a time at a full station and is
--      notified when a booking there is cancelled or expires.
--   3. Driver: the person charging can be someone else (family, fleet).
--      Staff see the driver's name; the driver gets the confirmation SMS.

-------------------------------------------------------------------------------
-- 1. Reminders
-------------------------------------------------------------------------------

create or replace function public.enqueue_booking_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_n int := 0;
  v_key text;
begin
  for r in
    select b.id, b.customer_id, b.reference, lower(b.period) as starts_at, s.name as station, s.timezone,
           w.opens_at, w.closes_at
      from public.bookings b
      join public.stations s on s.id = b.station_id
      cross join lateral private.checkin_window(b) w
     where b.status = 'confirmed'
       and lower(b.period) between now() - interval '2 hours' and now() + interval '2 hours'
  loop
    -- Keys include the start time, so a rescheduled booking is reminded again.
    v_key := r.id::text || ':' || extract(epoch from r.starts_at)::bigint::text;
    if r.starts_at between now() + interval '25 minutes' and now() + interval '35 minutes' then
      perform private.enqueue_booking_messages(r.id, 'booking_reminder', 'booking_reminder:' || v_key);
      perform private.notify(r.customer_id, 'booking', 'booking.reminder', 'Your charging slot starts in 30 minutes',
        format('%s at %s. Check in by %s.', r.station, to_char(r.starts_at at time zone r.timezone, 'HH12:MI AM'),
               to_char(r.closes_at at time zone r.timezone, 'HH12:MI AM')),
        jsonb_build_object('booking_id', r.id), 'booking.reminder:' || v_key);
      v_n := v_n + 1;
    end if;
    if r.opens_at between now() - interval '5 minutes' and now() + interval '1 minute' then
      perform private.notify(r.customer_id, 'booking', 'booking.checkin_open', 'Check-in is open',
        format('Show your booking QR code to the staff at %s.', r.station),
        jsonb_build_object('booking_id', r.id), 'booking.checkin_open:' || v_key);
    end if;
    if r.closes_at - interval '5 minutes' between now() - interval '3 minutes' and now() + interval '1 minute' then
      perform private.notify(r.customer_id, 'booking', 'booking.checkin_closing', 'Check-in closes in 5 minutes',
        format('Reach %s by %s or your slot will be released.', r.station, to_char(r.closes_at at time zone r.timezone, 'HH12:MI AM')),
        jsonb_build_object('booking_id', r.id), 'booking.checkin_closing:' || v_key);
    end if;
  end loop;
  return v_n;
end;
$$;

-- Also run every minute from the database (the message dispatcher calls it
-- too; dedupe keys make the double call harmless).
create or replace function public.run_customer_reminders()
returns int
language sql
security definer
set search_path = ''
as $$
  select public.enqueue_booking_reminders();
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('chargekaro-customer-reminders', '* * * * *', 'select public.run_customer_reminders()');
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- 2. Waitlist
-------------------------------------------------------------------------------

create table public.station_waitlist (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles (id) on delete cascade,
  station_id uuid not null references public.stations (id) on delete cascade,
  -- Any start from window_start, finishing by window_end, for `minutes`.
  window_start timestamptz not null,
  window_end timestamptz not null,
  minutes int not null check (minutes between 5 and 1440),
  connector_type public.connector_type,
  created_at timestamptz not null default now(),
  notified_at timestamptz,
  notified_start timestamptz,
  cancelled_at timestamptz,
  check (window_end > window_start),
  check (window_end - window_start >= make_interval(mins => minutes))
);

create index station_waitlist_open_idx on public.station_waitlist (station_id, window_start)
  where cancelled_at is null and notified_at is null;
create index station_waitlist_customer_idx on public.station_waitlist (customer_id, created_at desc);

alter table public.station_waitlist enable row level security;

create or replace function private.waitlist_json(w public.station_waitlist)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', w.id, 'station_id', w.station_id, 'station_name', s.name,
    'window_start', w.window_start, 'window_end', w.window_end, 'minutes', w.minutes,
    'connector_type', w.connector_type, 'created_at', w.created_at,
    'notified_at', w.notified_at, 'notified_start', w.notified_start,
    'active', w.cancelled_at is null and w.window_end > now())
  from public.stations s where s.id = w.station_id;
$$;

create or replace function public.join_waitlist(
  p_station_id uuid,
  p_window_start timestamptz,
  p_window_end timestamptz,
  p_minutes int,
  p_connector_type public.connector_type default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_w public.station_waitlist;
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if not private.is_public_station(p_station_id) then
    perform private.raise_error(404, 'station_not_found');
  end if;
  if p_window_start is null or p_window_end is null or p_minutes is null
     or p_window_end <= greatest(p_window_start, now())
     or p_window_end - greatest(p_window_start, now()) < make_interval(mins => p_minutes)
     or p_window_start > now() + interval '8 days' then
    perform private.raise_error(422, 'invalid_waitlist_window');
  end if;
  if (select count(*) from public.station_waitlist
       where customer_id = v_user and cancelled_at is null and notified_at is null and window_end > now()) >= 5 then
    perform private.raise_error(409, 'waitlist_limit', 'You can wait for up to 5 times at once');
  end if;
  select * into v_w from public.station_waitlist
   where customer_id = v_user and station_id = p_station_id and cancelled_at is null and notified_at is null
     and window_start = p_window_start and window_end = p_window_end and minutes = p_minutes;
  if not found then
    insert into public.station_waitlist (customer_id, station_id, window_start, window_end, minutes, connector_type)
    values (v_user, p_station_id, p_window_start, p_window_end, p_minutes, p_connector_type)
    returning * into v_w;
  end if;
  return private.waitlist_json(v_w);
end;
$$;

create or replace function public.leave_waitlist(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.station_waitlist set cancelled_at = now()
   where id = p_id and customer_id = (select auth.uid()) and cancelled_at is null;
  if not found then
    perform private.raise_error(404, 'waitlist_not_found');
  end if;
end;
$$;

create or replace function public.get_my_waitlist()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(private.waitlist_json(w) order by w.window_start), '[]'::jsonb)
    from public.station_waitlist w
   where w.customer_id = (select auth.uid()) and w.cancelled_at is null
     and w.window_end > now() and (w.notified_at is null or w.notified_at > now() - interval '1 day');
$$;

-- When a booking frees its time (cancelled, expired, no-show), tell waiting
-- customers whose window now has a free point. Everyone matching is told;
-- the first to book gets it.
create or replace function private.waitlist_on_booking_freed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  w record;
  v_start timestamptz;
  v_slot int;
begin
  if not (old.status in ('payment_pending', 'confirmed') and new.status in ('cancelled', 'expired', 'no_show')) then
    return null;
  end if;
  if upper(new.period) <= now() then
    return null;
  end if;
  select slot_duration_minutes into v_slot from public.station_booking_policies where station_id = new.station_id;
  for w in
    select * from public.station_waitlist
     where station_id = new.station_id and cancelled_at is null and notified_at is null
       and customer_id <> new.customer_id
       and window_end > now()
       and tstzrange(window_start, window_end, '[)') && new.period
     order by created_at
     for update skip locked
  loop
    -- Earliest aligned start in both the window and the freed time.
    v_start := greatest(w.window_start, lower(new.period));
    if v_start < now() then
      v_start := lower(new.period);
      while v_start < now() loop
        v_start := v_start + make_interval(mins => coalesce(v_slot, 15));
      end loop;
    end if;
    continue when v_start + make_interval(mins => w.minutes) > w.window_end;
    continue when not exists (select 1 from private.station_candidate_points(new.station_id, v_start,
                                                                                v_start + make_interval(mins => w.minutes), w.connector_type));
    update public.station_waitlist set notified_at = now(), notified_start = v_start where id = w.id;
    perform private.notify(w.customer_id, 'booking', 'waitlist.slot_open', 'A slot just opened',
      format('%s has a free charger at %s. Book now before someone else does.',
             (select name from public.stations where id = new.station_id),
             to_char(v_start at time zone (select timezone from public.stations where id = new.station_id), 'Dy DD Mon, HH12:MI AM')),
      jsonb_build_object('station_id', new.station_id, 'start_at', v_start, 'minutes', w.minutes, 'waitlist_id', w.id),
      'waitlist.slot_open:' || w.id);
  end loop;
  return null;
end;
$$;

create trigger bookings_waitlist after update of status on public.bookings
  for each row when (old.status is distinct from new.status)
  execute function private.waitlist_on_booking_freed();

-------------------------------------------------------------------------------
-- 3. Booking for someone else
-------------------------------------------------------------------------------

alter table public.bookings
  add column driver_phone text check (driver_phone is null or driver_phone ~ '^\+[1-9][0-9]{7,14}$'),
  add column booked_for_other boolean not null default false;

-- Sets who will charge. The name is what station staff see (the existing
-- customer_display_name); the phone gets the booking confirmation by SMS.
-- Null name = "I'm driving" (back to the account holder's name).
create or replace function public.set_booking_driver(p_booking_id uuid, p_name text, p_phone text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_b public.bookings;
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '[\s-]', '', 'g'), '');
  v_own text;
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  select * into v_b from public.bookings where id = p_booking_id and customer_id = v_user for update;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if v_b.status not in ('payment_pending', 'confirmed') or upper(v_b.period) <= now() then
    perform private.raise_error(409, 'driver_locked', 'The driver can be changed until the booking starts');
  end if;
  if v_name is not null and char_length(v_name) > 80 then
    perform private.raise_error(422, 'invalid_name');
  end if;
  if v_phone is not null and v_phone ~ '^[6-9][0-9]{9}$' then
    v_phone := '+91' || v_phone;
  end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    perform private.raise_error(422, 'invalid_phone');
  end if;
  select coalesce(nullif(trim(full_name), ''), 'Customer') into v_own from public.profiles where id = v_user;
  update public.bookings
     set customer_display_name = coalesce(v_name, v_own),
         driver_phone = case when v_name is null then null else v_phone end,
         booked_for_other = v_name is not null
   where id = v_b.id
  returning * into v_b;
  if v_b.status = 'confirmed' and v_b.driver_phone is not null then
    perform private.send_driver_confirmation(v_b);
  end if;
  return private.customer_booking_json(v_b, true);
end;
$$;

create or replace function private.send_driver_confirmation(p_b public.bookings)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_b.driver_phone is null then
    return;
  end if;
  insert into public.customer_messages (recipient_id, booking_id, channel, template, destination, payload, dedupe_key)
  values (p_b.customer_id, p_b.id, 'sms', 'booking_confirmed', p_b.driver_phone,
          private.booking_message_payload(p_b.id) || jsonb_build_object('customer_name', p_b.customer_display_name, 'for_driver', true),
          'sms:driver:booking_confirmed:' || p_b.id || ':' || p_b.driver_phone || ':' || extract(epoch from lower(p_b.period))::bigint)
  on conflict (dedupe_key) do nothing;
end;
$$;

-- Driver set before payment: confirm them once the booking is paid.
create or replace function private.driver_on_confirm()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' and new.driver_phone is not null then
    perform private.send_driver_confirmation(new);
  end if;
  return null;
end;
$$;

create trigger bookings_driver_confirm after update of status on public.bookings
  for each row when (old.status is distinct from new.status)
  execute function private.driver_on_confirm();

-- Booking JSON: previous fields plus the driver.
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
    'my_review_comment', (select r.comment from public.station_reviews r where r.booking_id = p_booking.id),
    'booked_for_other', p_booking.booked_for_other,
    'driver_phone', p_booking.driver_phone
  );
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------

revoke execute on function
  public.run_customer_reminders(),
  private.waitlist_json(public.station_waitlist),
  public.join_waitlist(uuid, timestamptz, timestamptz, int, public.connector_type),
  public.leave_waitlist(uuid),
  public.get_my_waitlist(),
  private.waitlist_on_booking_freed(),
  public.set_booking_driver(uuid, text, text),
  private.send_driver_confirmation(public.bookings),
  private.driver_on_confirm()
from public, anon, authenticated;

grant execute on function
  public.join_waitlist(uuid, timestamptz, timestamptz, int, public.connector_type),
  public.leave_waitlist(uuid),
  public.get_my_waitlist(),
  public.set_booking_driver(uuid, text, text)
to authenticated;
grant execute on function public.run_customer_reminders() to service_role;
