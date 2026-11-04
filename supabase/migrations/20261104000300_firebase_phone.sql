-- Firebase phone sign-in (customer app). Firebase sends and checks the SMS
-- code; the firebase-phone-auth Edge Function verifies Firebase's ID token
-- and then signs the customer in to Supabase with that phone number. This
-- lookup lets the function find an existing login by phone. Service role only.

create or replace function public.auth_user_id_for_phone(p_phone text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.id
    from auth.users u
   where u.phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')
   order by u.created_at
   limit 1;
$$;

revoke all on function public.auth_user_id_for_phone(text) from public, anon, authenticated;
grant execute on function public.auth_user_id_for_phone(text) to service_role;

comment on function public.auth_user_id_for_phone(text) is
  'Login id for a phone number (digits as Auth stores them). Used by the firebase-phone-auth Edge Function only.';
