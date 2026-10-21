-- Foundation: extensions, private schema, shared enums, utility functions,
-- platform settings and the append-only audit log.
--
-- Conventions
--   * Money is stored as integer minor units (paise) in *_paise bigint columns.
--   * Timestamps are timestamptz (UTC on the wire). Station-local display uses
--     stations.timezone.
--   * Enum values are lower_snake_case; the Dart layer maps them to UPPER_CASE
--     labels where the product spec uses those.
--   * Privileged functions are SECURITY DEFINER with search_path = '' and fully
--     qualified names.

create extension if not exists btree_gist with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- Functions are executable by PUBLIC by default. Lock that down: every
-- function exposed to clients is granted explicitly.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema private revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;
alter default privileges in schema private revoke execute on functions from anon, authenticated;

-------------------------------------------------------------------------------
-- Errors
-- PostgREST maps SQLSTATE 'PTxyz' to HTTP status xyz. The message is a stable
-- machine-readable code; detail carries a human-readable explanation.
-------------------------------------------------------------------------------

create or replace function private.raise_error(p_status int, p_code text, p_detail text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_status not in (400, 401, 403, 404, 409, 422) then
    p_status := 400;
  end if;
  raise exception using
    errcode = 'PT' || p_status::text,
    message = p_code,
    detail = coalesce(p_detail, p_code);
end;
$$;

-------------------------------------------------------------------------------
-- Generic helpers
-------------------------------------------------------------------------------

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function private.prevent_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'PT403',
    message = 'immutable_record',
    detail = format('%s rows are append-only', tg_table_name);
end;
$$;

-- Crockford base32 random code, used for human-enterable booking references.
create or replace function private.random_code(p_length int)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  bytes bytea := extensions.gen_random_bytes(p_length);
  result text := '';
begin
  for i in 0 .. p_length - 1 loop
    result := result || substr(alphabet, (get_byte(bytes, i) % 32) + 1, 1);
  end loop;
  return result;
end;
$$;

-- URL-safe random token (128 bits by default) for QR payloads.
create or replace function private.random_token(p_bytes int default 16)
returns text
language sql
volatile
set search_path = ''
as $$
  select rtrim(translate(encode(extensions.gen_random_bytes(p_bytes), 'base64'), '+/', '-_'), '=');
$$;

create or replace function private.is_valid_timezone(p_tz text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz);
$$;

-------------------------------------------------------------------------------
-- Platform settings (protected key/value configuration)
-------------------------------------------------------------------------------

create table public.platform_settings (
  key text primary key check (key ~ '^[a-z][a-z0-9_]*$'),
  value jsonb not null,
  description text not null,
  is_public boolean not null default false,  -- readable by any signed-in user
  updated_by uuid,
  updated_at timestamptz not null default now()
);

comment on table public.platform_settings is
  'Backend-authoritative configuration such as the booking fee. Changed only through update_platform_setting().';

-- Validates the shape of known keys so a typo cannot silently break pricing.
create or replace function private.validate_platform_setting()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  case new.key
    when 'booking_fee_paise' then
      if jsonb_typeof(new.value) <> 'number' or (new.value)::bigint < 0 or (new.value)::bigint > 100000
         or (new.value)::numeric <> trunc((new.value)::numeric) then
        perform private.raise_error(422, 'invalid_setting', 'booking_fee_paise must be an integer between 0 and 100000');
      end if;
    when 'currency' then
      if new.value <> '"INR"'::jsonb then
        perform private.raise_error(422, 'invalid_setting', 'Only INR is supported');
      end if;
    when 'payment_hold_minutes' then
      if jsonb_typeof(new.value) <> 'number' or (new.value)::int < 2 or (new.value)::int > 60 then
        perform private.raise_error(422, 'invalid_setting', 'payment_hold_minutes must be between 2 and 60');
      end if;
    when 'business_commission_enabled' then
      if jsonb_typeof(new.value) <> 'boolean' then
        perform private.raise_error(422, 'invalid_setting', 'business_commission_enabled must be boolean');
      end if;
    when 'refund_policy' then
      if jsonb_typeof(new.value) <> 'object'
         or jsonb_typeof(new.value -> 'customer_cancellation_refundable') <> 'boolean'
         or jsonb_typeof(new.value -> 'customer_cancellation_cutoff_minutes') <> 'number'
         or jsonb_typeof(new.value -> 'business_cancellation_refundable') <> 'boolean'
         or jsonb_typeof(new.value -> 'late_payment_slot_lost_refundable') <> 'boolean'
         or jsonb_typeof(new.value -> 'policy_confirmed_for_production') <> 'boolean' then
        perform private.raise_error(422, 'invalid_setting', 'refund_policy is missing required fields');
      end if;
    else
      null;
  end case;
  new.updated_at := now();
  return new;
end;
$$;

create trigger platform_settings_validate
  before insert or update on public.platform_settings
  for each row execute function private.validate_platform_setting();

insert into public.platform_settings (key, value, description, is_public) values
  ('booking_fee_paise', '1200', 'Customer booking fee per booking, in paise (1200 = INR 12).', true),
  ('currency', '"INR"', 'Platform currency.', true),
  ('payment_hold_minutes', '10', 'Minutes a payment-pending booking holds its slot before expiring.', true),
  ('business_commission_enabled', 'false', 'Future business-owner commission. Must stay false unless the platform owner explicitly enables it; no commission logic exists yet.', false),
  ('refund_policy', jsonb_build_object(
      'customer_cancellation_refundable', false,
      'customer_cancellation_cutoff_minutes', 60,
      'business_cancellation_refundable', true,
      'late_payment_slot_lost_refundable', true,
      'policy_confirmed_for_production', false,
      'notes', 'DEFAULT POLICY, NOT A BUSINESS DECISION. Booking fee is non-refundable on customer cancellation; refunded when the station cancels or a late payment loses the slot. Confirm before production.'
   ), 'Booking-fee refund policy. Requires an explicit business decision before production launch.', true);

create or replace function private.setting(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select value from public.platform_settings where key = p_key;
$$;

-------------------------------------------------------------------------------
-- Audit log (append-only)
-------------------------------------------------------------------------------

create table public.audit_logs (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  actor_id uuid,                -- null = system / service role
  actor_kind text not null check (actor_kind in ('user', 'system')),
  action text not null check (action ~ '^[a-z_]+\.[a-z_.]+$'),
  entity_type text not null,
  entity_id text,
  reason text,
  before_data jsonb,
  after_data jsonb,
  metadata jsonb not null default '{}'::jsonb
);

create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id, occurred_at desc);
create index audit_logs_actor_idx on public.audit_logs (actor_id, occurred_at desc);
create index audit_logs_action_idx on public.audit_logs (action, occurred_at desc);

comment on table public.audit_logs is
  'Append-only record of consequential actions. Rows cannot be updated or deleted (trigger enforced).';

create trigger audit_logs_immutable
  before update or delete on public.audit_logs
  for each row execute function private.prevent_mutation();

create trigger audit_logs_no_truncate
  before truncate on public.audit_logs
  for each statement execute function private.prevent_mutation();

-- Columns never copied into audit before/after snapshots.
create or replace function private.redact(p_data jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when p_data is null then null else
    p_data - array['qr_token', 'token', 'signature', 'raw_payload', 'payload', 'vehicle_label',
                   'contact_phone', 'emergency_contact_phone', 'phone', 'email', 'contact_email']
  end;
$$;

create or replace function private.write_audit(
  p_action text,
  p_entity_type text,
  p_entity_id text,
  p_before jsonb default null,
  p_after jsonb default null,
  p_reason text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := (select auth.uid());
begin
  insert into public.audit_logs (actor_id, actor_kind, action, entity_type, entity_id, reason,
                                 before_data, after_data, metadata)
  values (v_actor, case when v_actor is null then 'system' else 'user' end, p_action,
          p_entity_type, p_entity_id, p_reason, private.redact(p_before), private.redact(p_after),
          coalesce(p_metadata, '{}'::jsonb));
end;
$$;

-- Generic row-change audit trigger for configuration tables.
create or replace function private.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entity_id text;
begin
  if tg_op = 'DELETE' then
    v_entity_id := coalesce(to_jsonb(old) ->> 'id', to_jsonb(old) ->> 'key', to_jsonb(old) ->> 'user_id');
    perform private.write_audit(tg_table_name || '.delete', tg_table_name, v_entity_id, to_jsonb(old), null);
    return old;
  elsif tg_op = 'UPDATE' then
    if to_jsonb(old) = to_jsonb(new) then
      return new;
    end if;
    v_entity_id := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'key', to_jsonb(new) ->> 'user_id');
    perform private.write_audit(tg_table_name || '.update', tg_table_name, v_entity_id, to_jsonb(old), to_jsonb(new));
    return new;
  else
    v_entity_id := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'key', to_jsonb(new) ->> 'user_id');
    perform private.write_audit(tg_table_name || '.insert', tg_table_name, v_entity_id, null, to_jsonb(new));
    return new;
  end if;
end;
$$;

create trigger platform_settings_audit
  after insert or update or delete on public.platform_settings
  for each row execute function private.audit_row_change();
