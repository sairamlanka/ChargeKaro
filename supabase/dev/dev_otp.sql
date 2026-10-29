-- LOCAL DEVELOPMENT ONLY. Never add this to supabase/migrations or run it on
-- a hosted project.
--
-- Lets phone sign-in work without an SMS provider: Supabase Auth hands each
-- code to the "send SMS" hook below instead of sending a text, the hook
-- keeps it here, and the customer app (APP_ENV=development) shows it on the
-- Verify screen. Wired up in supabase/config.toml under
-- [auth.hook.send_sms]; loaded on `supabase db reset` via [db.seed], or by
-- hand with:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -f supabase/dev/dev_otp.sql

create table if not exists private.dev_otp_codes (
  phone text not null,
  code text not null,
  created_at timestamptz not null default now()
);
create index if not exists dev_otp_codes_phone_idx on private.dev_otp_codes (phone, created_at desc);

-- Called by Supabase Auth instead of an SMS provider.
create or replace function public.dev_send_sms(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone text := regexp_replace(
    coalesce(nullif(event->'user'->>'phone_change', ''), event->'user'->>'phone', ''), '\D', '', 'g');
begin
  delete from private.dev_otp_codes where created_at < now() - interval '1 hour';
  insert into private.dev_otp_codes (phone, code) values (v_phone, event->'sms'->>'otp');
  return '{}'::jsonb;
end;
$$;

revoke all on function public.dev_send_sms(jsonb) from public, anon, authenticated;
grant execute on function public.dev_send_sms(jsonb) to supabase_auth_admin;

-- The latest code sent to a number in the last 10 minutes, for the app's
-- dev banner. Empty unless the hook above is enabled.
create or replace function public.dev_otp_code(p_phone text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select code
  from private.dev_otp_codes
  where phone = regexp_replace(p_phone, '\D', '', 'g')
    and created_at > now() - interval '10 minutes'
  order by created_at desc
  limit 1;
$$;

revoke all on function public.dev_otp_code(text) from public;
grant execute on function public.dev_otp_code(text) to anon, authenticated;
