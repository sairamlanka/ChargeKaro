-- Secure booking check-in: QR (primary), manual (fallback) and offline-assisted
-- (emergency) check-in through one validation path, plus charging start and
-- completion.
--
-- * QR codes carry a 256-bit random token. Only its SHA-256 hash is stored.
--   A booking has at most one live token; issuing a new one revokes the old
--   one, arrival consumes it, and cancellation / no-show / expiry revoke it.
-- * Every verification, search, check-in, rejection, override, offline sync
--   and charging step is written to booking_checkin_logs (append-only). Raw
--   tokens, phone numbers and names are never logged.
-- * Rejections are returned as {result: 'rejected', code, message} rather
--   than raised, so the audit row survives the transaction.
-- * Staff see only the booking reference, slot and charger compatibility
--   until the booking is checked in; name, phone and vehicle are revealed
--   after arrival.
-- * Idempotency keys are unique per staff member, so retries and double taps
--   return the original result instead of acting twice.
--
-- Status names: the spec's CHARGING is the existing 'in_progress' and its
-- PENDING_PAYMENT is 'payment_pending'. Verification is tracked separately in
-- bookings.verification_status.

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

-- Platform defaults. Per-station early/late minutes stay in
-- station_booking_policies (early_checkin_minutes, arrival_grace_minutes).
-- late_window_basis: 'start' closes check-in at slot start + grace (the
-- point is then released as a no-show); 'end' closes it at slot end + grace.
insert into public.platform_settings (key, value, description, is_public) values
  ('checkin_settings', jsonb_build_object(
      'late_window_basis', 'start',
      'offline_cache_max_age_hours', 12,
      'offline_sync_max_hours', 24,
      'offline_accept_after_no_show', false,
      'clock_skew_minutes', 5,
      'search_limit_per_10_min', 20,
      'failed_verify_limit_per_10_min', 15,
      'qr_issue_limit_per_hour', 20
   ), 'Booking check-in rules: arrival window basis, offline limits and rate limits.', false)
on conflict (key) do nothing;

create or replace function private.checkin_setting(p_key text, p_default int)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((private.setting('checkin_settings') ->> p_key)::int, p_default);
$$;

-------------------------------------------------------------------------------
-- Booking columns
-------------------------------------------------------------------------------

create type public.checkin_verification_status as enum ('not_checked_in', 'verified', 'pending_sync', 'rejected');

alter table public.bookings
  add column checkin_method text check (checkin_method in ('qr', 'manual', 'offline', 'reference')),
  add column checked_in_by uuid references public.profiles (id),
  add column checkin_reason text check (checkin_reason is null or char_length(checkin_reason) <= 300),
  add column verification_status public.checkin_verification_status not null default 'not_checked_in',
  add column checkin_device_id text check (checkin_device_id is null or char_length(checkin_device_id) <= 100),
  add column checkin_event_id uuid;

comment on column public.bookings.verification_status is
  'Server-side check-in verification. pending_sync exists only on devices until the server accepts an offline event.';

-- Backfill bookings checked in before this migration.
update public.bookings b
   set verification_status = 'verified', checkin_method = c.method, checked_in_by = c.checked_in_by
  from public.check_ins c
 where c.booking_id = b.id;

alter table public.check_ins drop constraint check_ins_method_check;
alter table public.check_ins add constraint check_ins_method_check
  check (method in ('qr', 'reference', 'manual', 'offline'));

-- Staff no longer read customer names or vehicle labels from the table; the
-- check-in RPCs reveal them after arrival. New columns are readable.
revoke select (customer_display_name, vehicle_label) on public.bookings from authenticated;
grant select (checkin_method, checked_in_by, checkin_reason, verification_status, checkin_device_id, checkin_event_id)
  on public.bookings to authenticated;

-- A no-show may be reversed into an arrival only by an audited override
-- (late arrival approved by a station manager or the platform).
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
    ('no_show', 'arrived'),
    ('arrived', 'no_show'),
    ('arrived', 'cancelled'),
    ('in_progress', 'cancelled'),
    ('confirmed', 'completed')
  );
$$;

-------------------------------------------------------------------------------
-- QR tokens
-------------------------------------------------------------------------------

create table public.booking_qr_tokens (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  token_hash bytea not null unique,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoke_reason text,
  consumed_at timestamptz,
  consumed_by uuid references public.profiles (id)
);

comment on table public.booking_qr_tokens is
  'Hashes of booking QR tokens. The raw token is shown to the customer once per issue and never stored.';

-- At most one live token per booking.
create unique index booking_qr_tokens_live_idx on public.booking_qr_tokens (booking_id)
  where revoked_at is null and consumed_at is null;
create index booking_qr_tokens_booking_idx on public.booking_qr_tokens (booking_id, issued_at desc);

alter table public.booking_qr_tokens enable row level security;
revoke all on public.booking_qr_tokens from anon, authenticated;
grant all on public.booking_qr_tokens to service_role;

create or replace function private.qr_hash(p_token text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select extensions.digest(convert_to(p_token, 'UTF8'), 'sha256');
$$;

-- Revokes the live token when a booking can no longer be checked in, and
-- consumes it on arrival so it cannot be replayed.
create or replace function private.booking_qr_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status in ('cancelled', 'expired', 'no_show', 'completed') then
    update public.booking_qr_tokens set revoked_at = now(), revoke_reason = new.status::text
     where booking_id = new.id and revoked_at is null and consumed_at is null;
  elsif new.status in ('arrived', 'in_progress') then
    update public.booking_qr_tokens set consumed_at = now(), consumed_by = (select auth.uid())
     where booking_id = new.id and revoked_at is null and consumed_at is null;
  end if;
  return new;
end;
$$;

create trigger bookings_qr_lifecycle after update of status on public.bookings
  for each row when (old.status is distinct from new.status)
  execute function private.booking_qr_lifecycle();

-------------------------------------------------------------------------------
-- Check-in audit log
-------------------------------------------------------------------------------

create table public.booking_checkin_logs (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid references public.bookings (id) on delete cascade,
  station_id uuid references public.stations (id) on delete cascade,
  staff_id uuid references public.profiles (id),
  manager_id uuid references public.profiles (id),
  checkin_method text check (checkin_method in ('qr', 'manual', 'offline', 'reference')),
  action text not null check (action in (
    'qr_verify', 'search', 'checkin', 'override', 'offline_sync', 'offline_cache', 'start_charging', 'complete_charging')),
  result text not null check (result in ('accepted', 'rejected')),
  reason text check (reason is null or char_length(reason) <= 300),
  rejection_reason text,
  device_id text check (device_id is null or char_length(device_id) <= 100),
  idempotency_key text check (idempotency_key is null or char_length(idempotency_key) between 8 and 100),
  offline_timestamp timestamptz,
  server_timestamp timestamptz not null default now(),
  sync_status text check (sync_status in ('accepted', 'rejected')),
  from_status public.booking_status,
  to_status public.booking_status,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.booking_checkin_logs is
  'Append-only audit of check-in activity. Never contains raw QR tokens, phone numbers or customer names.';

create unique index booking_checkin_logs_idempotency_idx on public.booking_checkin_logs (staff_id, idempotency_key)
  where idempotency_key is not null;
create index booking_checkin_logs_booking_idx on public.booking_checkin_logs (booking_id, created_at);
create index booking_checkin_logs_station_idx on public.booking_checkin_logs (station_id, created_at desc);
create index booking_checkin_logs_staff_idx on public.booking_checkin_logs (staff_id, action, created_at desc);

create trigger booking_checkin_logs_immutable before update or delete on public.booking_checkin_logs
  for each row execute function private.prevent_mutation();

alter table public.booking_checkin_logs enable row level security;
revoke all on public.booking_checkin_logs from anon, authenticated;
grant select on public.booking_checkin_logs to authenticated;
grant all on public.booking_checkin_logs to service_role;

-- Staff see their own entries; managers/owners see their station's; platform
-- staff with bookings.read_all see everything.
create policy booking_checkin_logs_select on public.booking_checkin_logs for select to authenticated using (
  staff_id = (select auth.uid())
  or (station_id is not null and private.has_station_permission(station_id, 'bookings.manage'))
  or private.has_platform_permission('bookings.read_all'));

create or replace function private.log_checkin(
  p_action text,
  p_result text,
  p_booking uuid,
  p_station uuid,
  p_method text default null,
  p_rejection text default null,
  p_reason text default null,
  p_device text default null,
  p_key text default null,
  p_offline_at timestamptz default null,
  p_from public.booking_status default null,
  p_to public.booking_status default null,
  p_metadata jsonb default '{}'::jsonb,
  p_manager uuid default null,
  p_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := coalesce(p_id, gen_random_uuid());
begin
  insert into public.booking_checkin_logs (
    id, booking_id, station_id, staff_id, manager_id, checkin_method, action, result, reason, rejection_reason,
    device_id, idempotency_key, offline_timestamp, sync_status, from_status, to_status, metadata)
  values (
    v_id, p_booking, p_station, (select auth.uid()), p_manager, p_method, p_action, p_result, left(p_reason, 300), p_rejection,
    left(nullif(trim(p_device), ''), 100), p_key, p_offline_at,
    case when p_action = 'offline_sync' then p_result end, p_from, p_to, coalesce(p_metadata, '{}'::jsonb))
  on conflict (staff_id, idempotency_key) where idempotency_key is not null do nothing;
  return v_id;
end;
$$;

-------------------------------------------------------------------------------
-- Rules shared by every check-in method
-------------------------------------------------------------------------------

-- Check-in window in UTC. Station-local times are only for display, so DST
-- and timezone changes do not move the window.
create or replace function private.checkin_window(p_b public.bookings)
returns table (opens_at timestamptz, closes_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select lower(p_b.period) - make_interval(mins => pol.early_checkin_minutes),
         case when coalesce(private.setting('checkin_settings') ->> 'late_window_basis', 'start') = 'end'
              then upper(p_b.period) + make_interval(mins => pol.arrival_grace_minutes)
              else least(upper(p_b.period), lower(p_b.period) + make_interval(mins => pol.arrival_grace_minutes))
         end
    from public.station_booking_policies pol
   where pol.station_id = p_b.station_id;
$$;

-- Why the booking cannot be checked in at p_at, or null when it can.
-- Both window boundaries are inclusive.
create or replace function private.checkin_problem(p_b public.bookings, p_at timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_open timestamptz;
  v_close timestamptz;
begin
  case p_b.status
    when 'cancelled' then return 'booking_cancelled';
    when 'expired' then return 'booking_expired';
    when 'completed' then return 'booking_completed';
    when 'arrived', 'in_progress' then return 'already_checked_in';
    when 'no_show' then return 'marked_no_show';
    when 'payment_pending' then return 'payment_pending';
    else null;
  end case;
  if p_b.payment_status in ('refund_pending', 'refunded') then
    return 'payment_reversed';
  elsif p_b.payment_status = 'failed' then
    return 'payment_failed';
  elsif p_b.payment_status not in ('paid', 'not_required') then
    return 'payment_pending';
  end if;
  select w.opens_at, w.closes_at into v_open, v_close from private.checkin_window(p_b) w;
  if p_at < v_open then
    return 'too_early';
  elsif p_at > v_close then
    return 'too_late';
  end if;
  return null;
end;
$$;

-- Problems a station manager / owner may override. Payment, cancellation and
-- duplicate check-in can never be overridden.
create or replace function private.checkin_overridable(p_problem text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_problem in ('too_early', 'too_late', 'marked_no_show');
$$;

create or replace function private.checkin_message(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_code
    when 'invalid_qr' then 'This QR code is not valid. Use manual check-in instead.'
    when 'qr_outdated' then 'This is an old QR code. Ask the driver to reopen the booking in the ChargeKaro app.'
    when 'qr_revoked' then 'This QR code was replaced. Ask the driver to reopen the booking in the app.'
    when 'qr_used' then 'This QR code has already been used.'
    when 'qr_expired' then 'This QR code has expired.'
    when 'wrong_station' then 'This booking is for a different station.'
    when 'not_authorized' then 'You are not allowed to check in bookings at this station.'
    when 'booking_not_found' then 'No booking found.'
    when 'booking_cancelled' then 'This booking was cancelled.'
    when 'booking_expired' then 'This booking expired before the booking fee was paid.'
    when 'booking_completed' then 'This booking is already completed.'
    when 'already_checked_in' then 'This booking is already checked in.'
    when 'checked_in_by_other' then 'Another staff member already checked in this booking.'
    when 'marked_no_show' then 'This booking was marked as a no-show.'
    when 'payment_pending' then 'The booking fee has not been paid.'
    when 'payment_failed' then 'The booking fee payment failed.'
    when 'payment_reversed' then 'The booking fee was refunded or is being refunded.'
    when 'too_early' then 'Check-in for this booking has not opened yet.'
    when 'too_late' then 'The arrival window for this booking has closed.'
    when 'reason_required' then 'Choose a reason for manual check-in.'
    when 'reason_note_required' then 'Describe the reason in a few words.'
    when 'override_not_allowed' then 'Only a station manager or owner can approve this.'
    when 'override_reason_required' then 'Enter a reason for the override.'
    when 'slot_unavailable' then 'The charging point is now booked by someone else.'
    when 'rate_limited' then 'Too many attempts. Wait a few minutes and try again.'
    when 'invalid_query' then 'Enter a booking ID (starts with CK) or a mobile number.'
    when 'invalid_request' then 'The request was incomplete. Update the app and try again.'
    when 'clock_invalid' then 'The device clock was wrong when this check-in was recorded.'
    when 'sync_too_late' then 'This offline check-in is too old to sync.'
    when 'no_show_conflict' then 'The booking was marked as a no-show before this check-in synced. Ask a manager to review it.'
    when 'not_arrived' then 'The driver has not been checked in yet.'
    when 'already_charging' then 'Charging has already started.'
    when 'not_charging' then 'Charging has not started.'
    else 'This booking cannot be checked in.'
  end;
$$;

create or replace function private.checkin_rejection(p_code text, p_extra jsonb default '{}'::jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object('result', 'rejected', 'code', p_code, 'message', private.checkin_message(p_code),
                            'override_allowed', private.checkin_overridable(p_code)) || coalesce(p_extra, '{}'::jsonb);
$$;

-- Manual check-in reasons (spec list).
create or replace function private.manual_reason_label(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_code
    when 'qr_not_working' then 'QR code not working'
    when 'phone_unavailable' then 'Customer phone unavailable'
    when 'app_unavailable' then 'Customer app unavailable'
    when 'scanner_malfunction' then 'Camera/scanner malfunction'
    when 'connectivity_issue' then 'Internet connectivity issue'
    when 'qr_damaged' then 'QR damaged or unreadable'
    when 'cannot_access_booking' then 'Customer unable to access booking'
    when 'other' then 'Other'
  end;
$$;

-- Phone search input to E.164. Ten-digit Indian mobiles (6-9 first digit)
-- get +91; anything already in +<country> form is kept; else null.
create or replace function private.normalize_phone(p_input text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := regexp_replace(coalesce(p_input, ''), '[\s().-]', '', 'g');
  v_digits text;
begin
  if v ~ '^00[1-9]' then
    v := '+' || substr(v, 3);
  end if;
  if v like '+%' then
    v_digits := regexp_replace(substr(v, 2), '[^0-9]', '', 'g');
    if substr(v, 2) <> v_digits then
      return null;
    end if;
    v := '+' || v_digits;
  elsif v ~ '^[6-9][0-9]{9}$' then
    v := '+91' || v;
  elsif v ~ '^0[6-9][0-9]{9}$' then
    v := '+91' || substr(v, 2);
  elsif v ~ '^91[6-9][0-9]{9}$' then
    v := '+' || v;
  else
    return null;
  end if;
  return case when v ~ '^\+[1-9][0-9]{7,14}$' then v end;
end;
$$;

-- Last four letters/digits of a vehicle label, for staff before arrival.
create or replace function private.mask_vehicle(p_label text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_label is null or trim(p_label) = '' then null
              else '•••• ' || right(upper(regexp_replace(p_label, '[^A-Za-z0-9]', '', 'g')), 4) end;
$$;

-- Customer details are revealed to station staff only once the booking has
-- been checked in (and for 12 hours after completion), or to platform staff.
create or replace function private.can_reveal_customer(p_b public.bookings)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_b.status in ('arrived', 'in_progress')
      or (p_b.status = 'completed' and p_b.completed_at > now() - interval '12 hours')
      or private.has_platform_permission('bookings.read_all');
$$;

-- Staff projection. Customer fields are present only when p_reveal is true.
create or replace function private.checkin_booking_json(p_b public.bookings, p_reveal boolean)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_b.id,
    'reference', p_b.reference,
    'station_id', p_b.station_id,
    'station_name', s.name,
    'station_timezone', s.timezone,
    'charging_point_id', p_b.charging_point_id,
    'charging_point_code', cp.code,
    'start_at', lower(p_b.period),
    'end_at', upper(p_b.period),
    'status', p_b.status,
    'payment_status', p_b.payment_status,
    'payment_settled', p_b.payment_status in ('paid', 'not_required'),
    'booking_fee_paise', p_b.booking_fee_paise,
    'currency', p_b.currency,
    'verification_status', p_b.verification_status,
    'checkin_method', p_b.checkin_method,
    'checked_in_at', p_b.checked_in_at,
    'charging_started_at', p_b.charging_started_at,
    'completed_at', p_b.completed_at,
    'checkin_opens_at', w.opens_at,
    'checkin_closes_at', w.closes_at,
    'compatibility', jsonb_build_object(
      'current_type', cp.current_type,
      'max_power_kw', cp.max_power_kw,
      'connectors', coalesce((select jsonb_agg(c.connector_type order by c.connector_number)
                                from public.charging_connectors c where c.charging_point_id = cp.id), '[]'::jsonb)),
    'vehicle_hint', private.mask_vehicle(p_b.vehicle_label),
    'customer_revealed', p_reveal,
    'customer_display_name', case when p_reveal then coalesce(nullif(trim(p.full_name), ''), p_b.customer_display_name) end,
    'customer_phone', case when p_reveal then p.phone end,
    'vehicle_label', case when p_reveal then p_b.vehicle_label end
  )
  from public.stations s
  join public.charging_points cp on cp.id = p_b.charging_point_id
  left join public.profiles p on p.id = p_b.customer_id
  left join lateral private.checkin_window(p_b) w on true
  where s.id = p_b.station_id;
$$;

-- Replaces the old staff projection (used by lists, admin override and
-- no-show) so customer data is masked before arrival everywhere.
create or replace function private.staff_booking_json(p_b public.bookings)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.checkin_booking_json(p_b, private.can_reveal_customer(p_b)) || jsonb_build_object(
    'hold_expires_at', p_b.hold_expires_at,
    'created_at', p_b.created_at,
    'confirmed_at', p_b.confirmed_at,
    'cancelled_at', p_b.cancelled_at,
    'cancellation_actor', p_b.cancellation_actor,
    'cancellation_reason', p_b.cancellation_reason,
    'refund_eligible', p_b.refund_eligible,
    'no_show_at', p_b.no_show_at
  );
$$;

-- Reasons the caller cannot act on bookings at p_station, as a rejection
-- code, or null.
create or replace function private.checkin_auth_problem(p_station uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if p_station is null or not private.has_station_permission(p_station, 'bookings.checkin') then
    return 'not_authorized';
  end if;
  return null;
end;
$$;

-- Result of an earlier call with the same idempotency key, or null.
create or replace function private.checkin_replay(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_log public.booking_checkin_logs;
  v_b public.bookings;
begin
  if p_key is null then
    return null;
  end if;
  select * into v_log from public.booking_checkin_logs where staff_id = (select auth.uid()) and idempotency_key = p_key;
  if not found then
    return null;
  end if;
  if v_log.result = 'rejected' then
    return private.checkin_rejection(v_log.rejection_reason, jsonb_build_object('replayed', true));
  end if;
  select * into v_b from public.bookings where id = v_log.booking_id;
  return jsonb_build_object('result', 'accepted', 'replayed', true,
                            'booking', private.checkin_booking_json(v_b, private.can_reveal_customer(v_b)));
end;
$$;

-- The state transition every method ends in. Caller holds the row lock and
-- has validated everything. Returns the updated booking, or raises
-- exclusion_violation when an override re-occupies a reused slot.
create or replace function private.apply_checkin(
  p_b public.bookings,
  p_method text,
  p_reason text,
  p_device text,
  p_event uuid,
  p_override boolean
)
returns public.bookings
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
begin
  insert into public.check_ins (booking_id, station_id, checked_in_by, method)
  values (p_b.id, p_b.station_id, (select auth.uid()), p_method);
  if p_override then
    perform set_config('app.booking_override', 'on', true);
  end if;
  perform private.set_booking_context('business',
    case p_method when 'qr' then 'Checked in by QR' when 'manual' then 'Manual check-in'
                  when 'offline' then 'Offline check-in synced' else 'Checked in' end
    || case when p_override then ' (manager override)' else '' end);
  update public.bookings
     set status = 'arrived',
         checked_in_at = now(),
         checked_in_by = (select auth.uid()),
         checkin_method = p_method,
         checkin_reason = left(p_reason, 300),
         verification_status = 'verified',
         checkin_device_id = left(nullif(trim(p_device), ''), 100),
         checkin_event_id = p_event,
         no_show_at = null
   where id = p_b.id
  returning * into v_b;
  perform set_config('app.booking_override', 'off', true);
  perform private.notify_business((select business_id from public.stations where id = v_b.station_id), v_b.station_id,
    'bookings.view', 'booking', 'booking.checked_in', 'Customer checked in',
    format('Booking %s checked in at point %s.', v_b.reference,
           (select code from public.charging_points where id = v_b.charging_point_id)),
    jsonb_build_object('booking_id', v_b.id, 'station_id', v_b.station_id), 'booking.checked_in:' || v_b.id);
  return v_b;
end;
$$;

-------------------------------------------------------------------------------
-- Customer: QR code
-------------------------------------------------------------------------------

-- Issues a fresh QR for one of the caller's bookings and revokes any earlier
-- one, so only the latest code works. The app caches the payload and calls
-- this again only when the code is missing, rejected or expired (reinstall,
-- new device, logout). The raw token is returned once and never stored.
create or replace function public.get_my_booking_qr(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_open timestamptz;
  v_close timestamptz;
  v_token text;
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  select * into v_b from public.bookings where id = p_booking_id and customer_id = (select auth.uid()) for update;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if v_b.status in ('arrived', 'in_progress') then
    perform private.raise_error(409, 'already_checked_in', 'You are already checked in');
  end if;
  if v_b.status <> 'confirmed' or v_b.payment_status not in ('paid', 'not_required') then
    perform private.raise_error(409, 'qr_not_available', 'A QR code is available only for confirmed, paid bookings');
  end if;
  select w.opens_at, w.closes_at into v_open, v_close from private.checkin_window(v_b) w;
  if now() > v_close then
    perform private.raise_error(409, 'qr_expired', 'Check-in for this booking has closed');
  end if;
  if (select count(*) from public.booking_qr_tokens
       where booking_id = v_b.id and issued_at > now() - interval '1 hour')
     >= private.checkin_setting('qr_issue_limit_per_hour', 20) then
    perform private.raise_error(409, 'rate_limited', 'Too many new codes; try again later');
  end if;

  update public.booking_qr_tokens set revoked_at = now(), revoke_reason = 'reissued'
   where booking_id = v_b.id and revoked_at is null and consumed_at is null;
  v_token := private.random_token(32);
  insert into public.booking_qr_tokens (booking_id, token_hash, expires_at)
  values (v_b.id, private.qr_hash(v_token), v_close);

  return jsonb_build_object(
    'reference', v_b.reference,
    'qr_payload', 'CKB2:' || v_token,
    'issued_at', now(),
    'expires_at', v_close,
    'checkin_opens_at', v_open,
    'status', v_b.status);
end;
$$;

-------------------------------------------------------------------------------
-- Staff: QR verification (step 1 of QR check-in)
-------------------------------------------------------------------------------

-- Validates a scanned payload for the station the staff member is working
-- at. Returns minimal booking data (no customer details) and whether it can
-- be checked in now. Does not change the booking.
create or replace function public.verify_booking_qr(p_station_id uuid, p_payload text, p_device_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_problem text;
  v_payload text := trim(coalesce(p_payload, ''));
  v_tok public.booking_qr_tokens;
  v_b public.bookings;
begin
  v_problem := private.checkin_auth_problem(p_station_id);
  if v_problem is null and (
       select count(*) from public.booking_checkin_logs
        where staff_id = (select auth.uid()) and action = 'qr_verify' and result = 'rejected'
          and created_at > now() - interval '10 minutes') >= private.checkin_setting('failed_verify_limit_per_10_min', 15) then
    v_problem := 'rate_limited';
  end if;
  if v_problem is null then
    if v_payload ~ '^CKB1:' then
      v_problem := 'qr_outdated';
    elsif v_payload !~ '^CKB2:[A-Za-z0-9_-]{43}$' then
      v_problem := 'invalid_qr';
    else
      select * into v_tok from public.booking_qr_tokens where token_hash = private.qr_hash(substr(v_payload, 6));
      if not found then
        v_problem := 'invalid_qr';
      else
        select * into v_b from public.bookings where id = v_tok.booking_id;
        if v_b.station_id <> p_station_id then
          v_problem := 'wrong_station';
        elsif v_tok.consumed_at is not null or v_b.status in ('arrived', 'in_progress') then
          v_problem := case when v_b.status in ('arrived', 'in_progress') then 'already_checked_in' else 'qr_used' end;
        elsif v_tok.revoked_at is not null then
          v_problem := case v_tok.revoke_reason when 'cancelled' then 'booking_cancelled'
                                                when 'no_show' then 'marked_no_show'
                                                when 'completed' then 'booking_completed'
                                                else 'qr_revoked' end;
        elsif v_tok.expires_at < now() then
          v_problem := 'qr_expired';
        end if;
      end if;
    end if;
  end if;

  if v_problem is not null then
    -- Another station's booking is logged without the booking id so staff
    -- cannot learn anything about it from the audit trail.
    perform private.log_checkin('qr_verify', 'rejected',
      case when v_problem in ('wrong_station', 'not_authorized') then null else v_b.id end,
      case when v_problem = 'not_authorized' and not exists (select 1 from public.stations where id = p_station_id)
           then null else p_station_id end,
      'qr', v_problem, null, p_device_id);
    return private.checkin_rejection(v_problem);
  end if;

  v_problem := private.checkin_problem(v_b, now());
  perform private.log_checkin('qr_verify', 'accepted', v_b.id, v_b.station_id, 'qr', v_problem, null, p_device_id,
                              p_metadata => jsonb_build_object('eligible', v_problem is null));
  return jsonb_build_object(
    'result', 'verified',
    'eligible', v_problem is null,
    'code', v_problem,
    'message', case when v_problem is not null then private.checkin_message(v_problem) end,
    'override_allowed', coalesce(private.checkin_overridable(v_problem), false)
                        and private.has_station_permission(v_b.station_id, 'bookings.manage'),
    'booking', private.checkin_booking_json(v_b, false));
end;
$$;

-------------------------------------------------------------------------------
-- Staff: manual search
-------------------------------------------------------------------------------

-- Booking ID or registered mobile number, at this station only, for slots
-- from 12 hours ago to 24 hours ahead. Results carry no customer details.
-- Rate limited per staff member; the query itself is never logged.
create or replace function public.search_bookings_for_checkin(p_station_id uuid, p_query text, p_device_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_problem text;
  v_ref text := upper(regexp_replace(coalesce(p_query, ''), '[\s-]', '', 'g'));
  v_phone text;
  v_kind text;
  v_rows jsonb;
  v_count int;
begin
  v_problem := private.checkin_auth_problem(p_station_id);
  if v_problem is null and (
       select count(*) from public.booking_checkin_logs
        where staff_id = (select auth.uid()) and action = 'search' and created_at > now() - interval '10 minutes')
     >= private.checkin_setting('search_limit_per_10_min', 20) then
    v_problem := 'rate_limited';
  end if;
  if v_problem is null then
    if v_ref ~ '^CK[0-9A-HJKMNP-TV-Z]{10}$' then
      v_kind := 'reference';
    else
      v_phone := private.normalize_phone(p_query);
      v_kind := case when v_phone is not null then 'phone' end;
    end if;
    if v_kind is null then
      v_problem := 'invalid_query';
    end if;
  end if;
  if v_problem is not null then
    perform private.log_checkin('search', 'rejected', null,
      case when v_problem = 'not_authorized' then null else p_station_id end, 'manual', v_problem, null, p_device_id);
    return private.checkin_rejection(v_problem);
  end if;

  select coalesce(jsonb_agg(private.checkin_booking_json(b, false) order by lower(b.period)), '[]'::jsonb), count(*)
    into v_rows, v_count
    from public.bookings b
   where b.station_id = p_station_id
     and lower(b.period) between now() - interval '12 hours' and now() + interval '24 hours'
     and b.status in ('confirmed', 'arrived', 'in_progress', 'no_show', 'cancelled', 'completed')
     and ((v_kind = 'reference' and b.reference = v_ref)
          or (v_kind = 'phone' and b.customer_id in (select p.id from public.profiles p where p.phone = v_phone)));

  perform private.log_checkin('search', 'accepted', null, p_station_id, 'manual', null, null, p_device_id,
                              p_metadata => jsonb_build_object('kind', v_kind, 'results', v_count));
  return jsonb_build_object('result', 'ok', 'bookings', v_rows);
end;
$$;

-- One booking for the manual confirmation screen (no customer details).
create or replace function public.get_booking_for_checkin(p_station_id uuid, p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_problem text := private.checkin_auth_problem(p_station_id);
  v_b public.bookings;
begin
  if v_problem is not null then
    return private.checkin_rejection(v_problem);
  end if;
  select * into v_b from public.bookings where id = p_booking_id and station_id = p_station_id;
  if not found then
    return private.checkin_rejection('booking_not_found');
  end if;
  v_problem := private.checkin_problem(v_b, now());
  return jsonb_build_object(
    'result', 'verified',
    'eligible', v_problem is null,
    'code', v_problem,
    'message', case when v_problem is not null then private.checkin_message(v_problem) end,
    'override_allowed', coalesce(private.checkin_overridable(v_problem), false)
                        and private.has_station_permission(v_b.station_id, 'bookings.manage'),
    'booking', private.checkin_booking_json(v_b, private.can_reveal_customer(v_b)));
end;
$$;

-------------------------------------------------------------------------------
-- Staff: check-in (QR confirm, manual, manager override)
-------------------------------------------------------------------------------

create or replace function public.checkin_booking(
  p_station_id uuid,
  p_booking_id uuid,
  p_method text,
  p_idempotency_key text,
  p_qr_payload text default null,
  p_reason_code text default null,
  p_reason_note text default null,
  p_device_id text default null,
  p_override_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_problem text;
  v_b public.bookings;
  v_tok public.booking_qr_tokens;
  v_replay jsonb;
  v_reason text;
  v_override boolean := false;
  v_override_reason text := nullif(trim(coalesce(p_override_reason, '')), '');
  v_event uuid := gen_random_uuid();
  v_from public.booking_status;
begin
  v_problem := private.checkin_auth_problem(p_station_id);
  if v_problem is null and (p_method not in ('qr', 'manual') or p_booking_id is null
                            or p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 80) then
    v_problem := 'invalid_request';
  end if;
  if v_problem is null then
    -- Row lock: concurrent scans of the same booking queue here; the second
    -- one sees 'arrived' and is rejected.
    select * into v_b from public.bookings where id = p_booking_id and station_id = p_station_id for update;
    if not found then
      v_problem := 'booking_not_found';
    end if;
  end if;
  if v_problem is not null then
    perform private.log_checkin('checkin', 'rejected', case when v_problem = 'booking_not_found' then null else v_b.id end,
      case when v_problem = 'not_authorized' then null else p_station_id end, p_method, v_problem, null, p_device_id);
    return private.checkin_rejection(v_problem);
  end if;

  v_replay := private.checkin_replay(p_idempotency_key);
  if v_replay is not null then
    return v_replay;
  end if;

  if p_method = 'qr' then
    select * into v_tok from public.booking_qr_tokens
     where token_hash = private.qr_hash(substr(trim(coalesce(p_qr_payload, '')), 6))
       and trim(coalesce(p_qr_payload, '')) ~ '^CKB2:[A-Za-z0-9_-]{43}$';
    if not found or v_tok.booking_id <> v_b.id then
      v_problem := 'invalid_qr';
    elsif v_b.status in ('arrived', 'in_progress') then
      v_problem := 'already_checked_in';
    elsif v_tok.consumed_at is not null then
      v_problem := 'qr_used';
    elsif v_tok.revoked_at is not null then
      v_problem := 'qr_revoked';
    elsif v_tok.expires_at < now() and v_override_reason is null then
      v_problem := 'qr_expired';
    end if;
  else
    v_reason := private.manual_reason_label(p_reason_code);
    if v_reason is null then
      v_problem := 'reason_required';
    elsif p_reason_code = 'other' then
      if char_length(trim(coalesce(p_reason_note, ''))) < 5 then
        v_problem := 'reason_note_required';
      else
        v_reason := 'Other: ' || left(trim(p_reason_note), 280);
      end if;
    end if;
  end if;

  if v_problem is null then
    v_problem := private.checkin_problem(v_b, now());
    if v_problem = 'already_checked_in' and v_b.checked_in_by is distinct from (select auth.uid()) then
      v_problem := 'checked_in_by_other';
    end if;
    if v_problem is not null and v_override_reason is not null and private.checkin_overridable(v_problem) then
      if char_length(v_override_reason) < 5 then
        v_problem := 'override_reason_required';
      elsif not private.has_station_permission(v_b.station_id, 'bookings.manage') then
        v_problem := 'override_not_allowed';
      else
        v_override := true;
      end if;
    end if;
  end if;

  if v_problem is not null and not v_override then
    perform private.log_checkin('checkin', 'rejected', v_b.id, v_b.station_id, p_method, v_problem, v_reason,
                                p_device_id, p_idempotency_key, p_from => v_b.status);
    return private.checkin_rejection(v_problem, jsonb_build_object(
      'override_allowed', coalesce(private.checkin_overridable(v_problem), false)
                          and private.has_station_permission(v_b.station_id, 'bookings.manage')));
  end if;

  v_from := v_b.status;
  begin
    v_b := private.apply_checkin(v_b, p_method,
      case when v_override then concat_ws(' | ', v_reason, 'Override: ' || v_override_reason) else v_reason end,
      p_device_id, v_event, v_override);
  exception when exclusion_violation then
    perform private.log_checkin('checkin', 'rejected', p_booking_id, p_station_id, p_method, 'slot_unavailable', v_reason,
                                p_device_id, p_idempotency_key, p_from => v_from);
    return private.checkin_rejection('slot_unavailable');
  end;

  perform private.log_checkin(case when v_override then 'override' else 'checkin' end, 'accepted', v_b.id, v_b.station_id,
    p_method, null, case when v_override then concat_ws(' | ', v_reason, v_override_reason) else v_reason end,
    p_device_id, p_idempotency_key, null, v_from, 'arrived',
    case when v_override then jsonb_build_object('overridden_problem', v_problem) else '{}'::jsonb end,
    case when v_override then (select auth.uid()) end, v_event);
  return jsonb_build_object('result', 'accepted', 'booking', private.checkin_booking_json(v_b, true));
end;
$$;

-------------------------------------------------------------------------------
-- Staff: offline-assisted check-in
-------------------------------------------------------------------------------

-- Minimal snapshot for offline use: confirmed, paid bookings at this station
-- starting from 2 hours ago to 24 hours ahead. No customer data.
create or replace function public.get_offline_checkin_cache(p_station_id uuid, p_device_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_problem text := private.checkin_auth_problem(p_station_id);
  v_rows jsonb;
begin
  if v_problem is not null then
    return private.checkin_rejection(v_problem);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'reference', b.reference, 'station_id', b.station_id,
           'start_at', lower(b.period), 'end_at', upper(b.period),
           'status', b.status, 'payment_settled', true,
           'charging_point_code', cp.code, 'current_type', cp.current_type,
           'checkin_opens_at', w.opens_at, 'checkin_closes_at', w.closes_at) order by lower(b.period)), '[]'::jsonb)
    into v_rows
    from public.bookings b
    join public.charging_points cp on cp.id = b.charging_point_id
    cross join lateral private.checkin_window(b) w
   where b.station_id = p_station_id
     and b.status = 'confirmed'
     and b.payment_status in ('paid', 'not_required')
     and lower(b.period) between now() - interval '2 hours' and now() + interval '24 hours';
  perform private.log_checkin('offline_cache', 'accepted', null, p_station_id, 'offline', null, null, p_device_id,
                              p_metadata => jsonb_build_object('bookings', jsonb_array_length(v_rows)));
  return jsonb_build_object(
    'result', 'ok',
    'station_id', p_station_id,
    'generated_at', now(),
    'valid_until', now() + make_interval(hours => private.checkin_setting('offline_cache_max_age_hours', 12)),
    'bookings', v_rows);
end;
$$;

-- One offline event. Validated against the server's state now; the device
-- timestamp is used only to check the arrival fell inside the window, and is
-- rejected if it is in the future or too old.
create or replace function private.process_offline_checkin(p_event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id text := p_event ->> 'event_id';
  v_key text;
  v_station uuid;
  v_booking uuid;
  v_device text := left(p_event ->> 'device_id', 100);
  v_at timestamptz;
  v_problem text;
  v_b public.bookings;
  v_replay jsonb;
  v_from public.booking_status;
  v_log uuid := gen_random_uuid();
begin
  begin
    v_station := (p_event ->> 'station_id')::uuid;
    v_booking := (p_event ->> 'booking_id')::uuid;
    v_at := (p_event ->> 'offline_at')::timestamptz;
    perform v_event_id::uuid;
  exception when others then
    return jsonb_build_object('event_id', v_event_id) || private.checkin_rejection('invalid_request');
  end;
  if v_event_id is null or v_station is null or v_booking is null or v_at is null then
    return jsonb_build_object('event_id', v_event_id) || private.checkin_rejection('invalid_request');
  end if;
  v_key := 'offline:' || v_event_id;

  -- Authorization first: staff whose access was revoked while offline get
  -- nothing back, not even a replayed result.
  v_problem := private.checkin_auth_problem(v_station);
  if v_problem is null then
    select * into v_b from public.bookings where id = v_booking and station_id = v_station for update;
    if not found then
      v_problem := 'booking_not_found';
    end if;
  end if;
  -- Checked after taking the row lock, so the same event synced twice at
  -- once returns the first result instead of a conflict.
  if v_problem is null then
    v_replay := private.checkin_replay(v_key);
    if v_replay is not null then
      return jsonb_build_object('event_id', v_event_id) || v_replay;
    end if;
  end if;
  if v_problem is null then
    if v_at > now() + make_interval(mins => private.checkin_setting('clock_skew_minutes', 5)) or v_at < v_b.created_at then
      v_problem := 'clock_invalid';
    elsif v_at < now() - make_interval(hours => private.checkin_setting('offline_sync_max_hours', 24)) then
      v_problem := 'sync_too_late';
    else
      v_problem := private.checkin_problem(v_b, v_at);
      if v_problem = 'already_checked_in' and v_b.checked_in_by is distinct from (select auth.uid()) then
        v_problem := 'checked_in_by_other';
      elsif v_problem = 'marked_no_show' then
        -- Arrived inside the window while offline, then the no-show job ran
        -- before the event synced. Accepted only if policy allows it.
        if coalesce((private.setting('checkin_settings') ->> 'offline_accept_after_no_show')::boolean, false)
           and v_b.no_show_at > v_at
           and v_at <= (select w.closes_at from private.checkin_window(v_b) w) then
          v_problem := null;
        else
          v_problem := 'no_show_conflict';
        end if;
      end if;
    end if;
  end if;

  if v_problem is not null then
    perform private.log_checkin('offline_sync', 'rejected', case when v_problem = 'booking_not_found' then null else v_b.id end,
      case when v_problem = 'not_authorized' then null else v_station end, 'offline', v_problem, null, v_device, v_key, v_at,
      v_b.status);
    return jsonb_build_object('event_id', v_event_id) || private.checkin_rejection(v_problem);
  end if;

  v_from := v_b.status;
  begin
    v_b := private.apply_checkin(v_b, 'offline', 'Offline-assisted check-in', v_device, v_log, v_from = 'no_show');
  exception when exclusion_violation then
    perform private.log_checkin('offline_sync', 'rejected', v_b.id, v_station, 'offline', 'slot_unavailable', null, v_device,
                                v_key, v_at, v_from);
    return jsonb_build_object('event_id', v_event_id) || private.checkin_rejection('slot_unavailable');
  end;
  perform private.log_checkin('offline_sync', 'accepted', v_b.id, v_station, 'offline', null, 'Offline-assisted check-in',
    v_device, v_key, v_at, v_from, 'arrived', jsonb_build_object('device_time', p_event ->> 'offline_at'), null, v_log);
  return jsonb_build_object('event_id', v_event_id, 'result', 'accepted',
                            'booking', private.checkin_booking_json(v_b, true));
end;
$$;

-- Each event is processed on its own: one failure never affects the others,
-- and every event gets an accepted / rejected result.
create or replace function public.sync_offline_checkins(p_events jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event jsonb;
  v_results jsonb := '[]'::jsonb;
  v_res jsonb;
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 50 then
    perform private.raise_error(422, 'invalid_request', 'Send between 1 and 50 events');
  end if;
  for v_event in select * from jsonb_array_elements(p_events) loop
    begin
      v_res := private.process_offline_checkin(v_event);
    exception when others then
      v_res := jsonb_build_object('event_id', v_event ->> 'event_id') || private.checkin_rejection('invalid_request');
    end;
    v_results := v_results || jsonb_build_array(v_res);
  end loop;
  return jsonb_build_object('results', v_results, 'synced_at', now());
end;
$$;

-------------------------------------------------------------------------------
-- Staff: charging
-------------------------------------------------------------------------------

create or replace function private.charging_step(p_booking_id uuid, p_to public.booking_status, p_key text, p_device text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_problem text;
  v_action text := case when p_to = 'in_progress' then 'start_charging' else 'complete_charging' end;
  v_replay jsonb;
  v_from public.booking_status;
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if p_booking_id is null or p_key is null or char_length(p_key) not between 8 and 80 then
    return private.checkin_rejection('invalid_request');
  end if;
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not private.has_station_permission(v_b.station_id, 'bookings.checkin') then
    perform private.log_checkin(v_action, 'rejected', null, null, null,
      case when found then 'not_authorized' else 'booking_not_found' end, null, p_device);
    return private.checkin_rejection('booking_not_found');
  end if;
  v_replay := private.checkin_replay(p_key);
  if v_replay is not null then
    return v_replay;
  end if;
  v_problem := case
    when p_to = 'in_progress' and v_b.status = 'in_progress' then 'already_charging'
    when p_to = 'in_progress' and v_b.status <> 'arrived' then 'not_arrived'
    when p_to = 'completed' and v_b.status = 'completed' then 'booking_completed'
    when p_to = 'completed' and v_b.status <> 'in_progress' then 'not_charging'
  end;
  if v_problem is not null then
    perform private.log_checkin(v_action, 'rejected', v_b.id, v_b.station_id, null, v_problem, null, p_device, p_key,
                                p_from => v_b.status);
    return private.checkin_rejection(v_problem);
  end if;
  v_from := v_b.status;
  perform private.set_booking_context('business', null);
  update public.bookings
     set status = p_to,
         charging_started_at = case when p_to = 'in_progress' then now() else charging_started_at end,
         completed_at = case when p_to = 'completed' then now() else completed_at end
   where id = p_booking_id
  returning * into v_b;
  perform private.log_checkin(v_action, 'accepted', v_b.id, v_b.station_id, null, null, null, p_device, p_key, null,
                              v_from, p_to);
  return jsonb_build_object('result', 'accepted', 'booking', private.staff_booking_json(v_b));
end;
$$;

create or replace function public.start_charging(p_booking_id uuid, p_idempotency_key text, p_device_id text default null)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.charging_step(p_booking_id, 'in_progress', p_idempotency_key, p_device_id);
$$;

create or replace function public.complete_charging(p_booking_id uuid, p_idempotency_key text, p_device_id text default null)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.charging_step(p_booking_id, 'completed', p_idempotency_key, p_device_id);
$$;

-- Charging start/complete now go through the audited RPCs above; this keeps
-- only the manager's no-show action. The no-show cut-off follows the
-- check-in window.
create or replace function public.update_booking_progress(p_booking_id uuid, p_status public.booking_status)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
begin
  if p_status <> 'no_show' then
    perform private.raise_error(422, 'invalid_status', 'Use start_charging, complete_charging or checkin_booking');
  end if;
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  perform private.require_station_permission(v_b.station_id, 'bookings.manage');
  if now() <= (select w.closes_at from private.checkin_window(v_b) w) then
    perform private.raise_error(409, 'grace_period_active', 'A no-show can be recorded only after the arrival window');
  end if;
  perform private.set_booking_context('business', null);
  update public.bookings set status = 'no_show', no_show_at = now() where id = p_booking_id returning * into v_b;
  return private.staff_booking_json(v_b);
end;
$$;

-------------------------------------------------------------------------------
-- Staff: booking lists without customer data, and check-in history
-------------------------------------------------------------------------------

create or replace function public.get_station_bookings(
  p_station_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_statuses public.booking_status[] default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_station_permission(p_station_id, 'bookings.view');
  if p_to <= p_from or p_to - p_from > interval '93 days' then
    perform private.raise_error(422, 'range_too_large');
  end if;
  return coalesce((
    select jsonb_agg(private.staff_booking_json(b) order by lower(b.period))
      from public.bookings b
     where b.station_id = p_station_id
       and b.period && tstzrange(p_from, p_to, '[)')
       and (p_statuses is null or cardinality(p_statuses) = 0 or b.status = any (p_statuses))), '[]'::jsonb);
end;
$$;

create or replace function public.get_station_booking(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or not (private.has_station_permission(v_b.station_id, 'bookings.view')
                       or private.has_platform_permission('bookings.read_all')) then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  return private.staff_booking_json(v_b);
end;
$$;

-- Admin booking search (same filters as the old table query), now that the
-- customer columns are not directly readable.
create or replace function public.admin_search_bookings(
  p_reference text default null,
  p_station_id uuid default null,
  p_status public.booking_status default null,
  p_payment_status public.booking_payment_status default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ref text := upper(regexp_replace(coalesce(p_reference, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  perform private.require_platform_permission('bookings.read_all');
  return coalesce((
    select jsonb_agg(private.staff_booking_json(x) order by x.created_at desc)
      from (select b.* from public.bookings b
             where (v_ref = '' or b.reference like v_ref || '%')
               and (p_station_id is null or b.station_id = p_station_id)
               and (p_status is null or b.status = p_status)
               and (p_payment_status is null or b.payment_status = p_payment_status)
               and (p_from is null or p_to is null or b.period && tstzrange(p_from, p_to, '[)'))
             order by b.created_at desc
             limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb);
end;
$$;

create or replace function public.get_checkin_history(p_station_id uuid, p_limit int default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_manager boolean;
begin
  perform private.require_station_permission(p_station_id, 'bookings.view');
  v_manager := private.has_station_permission(p_station_id, 'bookings.manage');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'booking_id', l.booking_id, 'reference', b.reference, 'action', l.action, 'result', l.result,
             'method', l.checkin_method, 'reason', l.reason, 'rejection_reason', l.rejection_reason,
             'rejection_message', case when l.rejection_reason is not null then private.checkin_message(l.rejection_reason) end,
             'staff_name', p.full_name, 'is_mine', l.staff_id = (select auth.uid()), 'manager_override', l.manager_id is not null,
             'offline_at', l.offline_timestamp, 'server_at', l.server_timestamp, 'device_id', l.device_id)
           order by l.created_at desc)
      from (select * from public.booking_checkin_logs
             where station_id = p_station_id
               and action in ('checkin', 'override', 'offline_sync', 'start_charging', 'complete_charging', 'qr_verify')
               and (v_manager or staff_id = (select auth.uid()))
             order by created_at desc
             limit least(greatest(coalesce(p_limit, 100), 1), 500)) l
      left join public.bookings b on b.id = l.booking_id
      left join public.profiles p on p.id = l.staff_id), '[]'::jsonb);
end;
$$;

-------------------------------------------------------------------------------
-- Customer view and notifications
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
    'verification_status', p_b.verification_status,
    'checkin_method', p_b.checkin_method,
    'checkin_opens_at', (select w.opens_at from private.checkin_window(p_b) w),
    'checkin_closes_at', (select w.closes_at from private.checkin_window(p_b) w),
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

alter table public.customer_messages drop constraint customer_messages_template_check;
alter table public.customer_messages add constraint customer_messages_template_check check (template in (
  'booking_confirmed', 'booking_cancelled', 'booking_reminder', 'slot_lost', 'refund_initiated', 'refund_processed',
  'checked_in', 'charging_started', 'charging_completed', 'booking_no_show'));

-- Same as before, plus the "status_updates" preference for arrival and
-- charging messages (no-show is always sent, like cancellations).
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
  if p_template in ('checked_in', 'charging_started', 'charging_completed')
     and coalesce((v_profile.notification_prefs ->> 'status_updates')::boolean, true) = false then
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

-- Customer push + SMS/email for arrival, charging and no-show. Dedupe keys
-- make retried requests and re-run jobs notify once. Delivery problems never
-- affect the booking (outbox, processed later).
create or replace function private.booking_progress_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_station text := (select name from public.stations where id = new.station_id);
begin
  case new.status
    when 'arrived' then
      perform private.notify(new.customer_id, 'booking', 'booking.checked_in', 'Arrival verified',
        format('You are checked in at %s for booking %s.', v_station, new.reference),
        jsonb_build_object('booking_id', new.id), 'booking.checked_in.customer:' || new.id);
      perform private.enqueue_booking_messages(new.id, 'checked_in', 'checked_in:' || new.id);
    when 'in_progress' then
      perform private.notify(new.customer_id, 'booking', 'booking.charging_started', 'Charging started',
        format('Charging has started for booking %s.', new.reference),
        jsonb_build_object('booking_id', new.id), 'booking.charging_started.customer:' || new.id);
      perform private.enqueue_booking_messages(new.id, 'charging_started', 'charging_started:' || new.id);
    when 'completed' then
      perform private.notify(new.customer_id, 'booking', 'booking.completed', 'Charging completed',
        format('Your charging session for booking %s is complete. Pay the charging fee at the station.', new.reference),
        jsonb_build_object('booking_id', new.id), 'booking.completed.customer:' || new.id);
      perform private.enqueue_booking_messages(new.id, 'charging_completed', 'charging_completed:' || new.id);
    when 'no_show' then
      perform private.notify(new.customer_id, 'booking', 'booking.no_show', 'Marked as no-show',
        format('Booking %s was marked as a no-show because check-in did not happen in time.', new.reference),
        jsonb_build_object('booking_id', new.id), 'booking.no_show.customer:' || new.id);
      perform private.enqueue_booking_messages(new.id, 'booking_no_show', 'booking_no_show:' || new.id);
    else
      null;
  end case;
  return new;
end;
$$;

create trigger bookings_progress_notifications after update of status on public.bookings
  for each row when (old.status is distinct from new.status)
  execute function private.booking_progress_notifications();

-- Business notifications no longer carry customer names.
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
    'New booking', format('Booking %s for point %s on %s.', v_b.reference, v_point_code,
      to_char(lower(v_b.period) at time zone v_s.timezone, 'DD Mon HH24:MI')),
    jsonb_build_object('booking_id', v_b.id, 'station_id', v_s.id), 'booking.confirmed:' || v_b.id);
  perform private.notify(v_b.customer_id, 'booking', 'booking.confirmed', 'Booking confirmed',
    format('Your slot at %s on %s is confirmed. Reference %s.', v_s.name,
      to_char(lower(v_b.period) at time zone v_s.timezone, 'DD Mon HH24:MI'), v_b.reference),
    jsonb_build_object('booking_id', v_b.id), 'booking.confirmed.customer:' || v_b.id);
end;
$$;

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
    select * into v_b from public.bookings where id = p_booking_id;
  end if;

  select * into v_s from public.stations where id = v_b.station_id;
  if p_actor = 'customer' then
    perform private.notify_business(v_s.business_id, v_s.id, 'bookings.view', 'booking', 'booking.cancelled',
      'Booking cancelled', format('The customer cancelled booking %s.', v_b.reference),
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

-- No-show when the check-in window closes (same rule as check-in itself).
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

  perform private.set_booking_context('system', 'Automatic no-show: not checked in within the arrival window');
  with x as (
    update public.bookings b set status = 'no_show', no_show_at = now()
      from public.station_booking_policies p
     where p.station_id = b.station_id and p.auto_no_show_enabled
       and b.status = 'confirmed'
       and now() > (select w.closes_at from private.checkin_window(b) w)
    returning b.id
  ) select count(*) into v_no_show from x;

  for r in
    select b.id, b.reference, b.station_id, s.business_id, s.timezone, b.period
      from public.bookings b join public.stations s on s.id = b.station_id
     where b.status = 'confirmed' and lower(b.period) between now() and now() + interval '30 minutes'
  loop
    perform private.notify_business(r.business_id, r.station_id, 'bookings.view', 'booking', 'booking.upcoming_arrival',
      'Upcoming arrival', format('Booking %s is due at %s.', r.reference,
        to_char(lower(r.period) at time zone r.timezone, 'HH24:MI')),
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
  private.checkin_setting(text, int),
  private.qr_hash(text),
  private.booking_qr_lifecycle(),
  private.log_checkin(text, text, uuid, uuid, text, text, text, text, text, timestamptz, public.booking_status,
                      public.booking_status, jsonb, uuid, uuid),
  private.checkin_window(public.bookings),
  private.checkin_problem(public.bookings, timestamptz),
  private.checkin_overridable(text),
  private.checkin_message(text),
  private.checkin_rejection(text, jsonb),
  private.manual_reason_label(text),
  private.normalize_phone(text),
  private.mask_vehicle(text),
  private.can_reveal_customer(public.bookings),
  private.checkin_booking_json(public.bookings, boolean),
  private.checkin_auth_problem(uuid),
  private.checkin_replay(text),
  private.apply_checkin(public.bookings, text, text, text, uuid, boolean),
  private.process_offline_checkin(jsonb),
  private.charging_step(uuid, public.booking_status, text, text),
  private.booking_progress_notifications()
from public, anon, authenticated;

-- The old entry points read the plain-text CKB1 token and skip the audit
-- trail; clients use the functions below instead.
revoke execute on function
  public.lookup_booking_for_checkin(uuid, text),
  public.check_in_booking(uuid, text, text)
from authenticated;

revoke execute on function
  public.verify_booking_qr(uuid, text, text),
  public.search_bookings_for_checkin(uuid, text, text),
  public.get_booking_for_checkin(uuid, uuid),
  public.checkin_booking(uuid, uuid, text, text, text, text, text, text, text),
  public.get_offline_checkin_cache(uuid, text),
  public.sync_offline_checkins(jsonb),
  public.start_charging(uuid, text, text),
  public.complete_charging(uuid, text, text),
  public.get_station_bookings(uuid, timestamptz, timestamptz, public.booking_status[]),
  public.get_station_booking(uuid),
  public.admin_search_bookings(text, uuid, public.booking_status, public.booking_payment_status, timestamptz, timestamptz, int, int),
  public.get_checkin_history(uuid, int)
from public, anon;

grant execute on function
  public.verify_booking_qr(uuid, text, text),
  public.search_bookings_for_checkin(uuid, text, text),
  public.get_booking_for_checkin(uuid, uuid),
  public.checkin_booking(uuid, uuid, text, text, text, text, text, text, text),
  public.get_offline_checkin_cache(uuid, text),
  public.sync_offline_checkins(jsonb),
  public.start_charging(uuid, text, text),
  public.complete_charging(uuid, text, text),
  public.get_station_bookings(uuid, timestamptz, timestamptz, public.booking_status[]),
  public.get_station_booking(uuid),
  public.admin_search_bookings(text, uuid, public.booking_status, public.booking_payment_status, timestamptz, timestamptz, int, int),
  public.get_checkin_history(uuid, int)
to authenticated;
