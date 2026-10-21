-- Identity, platform staff roles and permissions.
--
-- Roles are never read from JWT claims or user metadata. They come from
-- platform_staff and business_members, keyed by auth.uid().
-- A customer (future RETAILER) is any authenticated user with a profile; no
-- extra role row is needed to book, so the Retailer App needs no redesign.

create type public.platform_role as enum ('super_admin', 'admin', 'compliance_reviewer');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text check (char_length(full_name) between 1 and 120),
  phone text check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  email text check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  avatar_path text,
  locale text not null default 'en-IN',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

comment on table public.profiles is 'One row per auth user. Holds no privilege information.';

create trigger profiles_updated_at before update on public.profiles
  for each row execute function private.set_updated_at();

-- Create a profile for each new auth user. Only display data is copied from
-- user metadata; nothing in metadata can grant privileges.
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone, email)
  values (
    new.id,
    nullif(left(trim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), 120), ''),
    case when new.phone is not null and new.phone <> '' then
      case when left(new.phone, 1) = '+' then new.phone else '+' || new.phone end
    end,
    nullif(new.email, '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

-- Keep the verified email/phone in sync when Auth changes them.
create or replace function private.handle_auth_user_contact_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
     set email = nullif(new.email, ''),
         phone = case when new.phone is not null and new.phone <> '' then
                   case when left(new.phone, 1) = '+' then new.phone else '+' || new.phone end
                 end
   where id = new.id;
  return new;
end;
$$;

create trigger on_auth_user_contact_changed
  after update of email, phone on auth.users
  for each row execute function private.handle_auth_user_contact_change();

-------------------------------------------------------------------------------
-- Platform permissions
-------------------------------------------------------------------------------

create table public.platform_permissions (
  code text primary key check (code ~ '^[a-z_]+(\.[a-z_]+)+$'),
  description text not null
);

insert into public.platform_permissions (code, description) values
  ('admins.manage', 'Grant, change and revoke platform staff roles and permissions'),
  ('settings.manage', 'Change platform settings including the booking fee and refund policy'),
  ('audit.read', 'Read the audit log'),
  ('businesses.read', 'Read business records'),
  ('businesses.manage', 'Suspend or reactivate business accounts'),
  ('applications.review', 'Open applications and review them'),
  ('applications.request_info', 'Request additional information on an application'),
  ('applications.decide', 'Approve or reject station applications'),
  ('documents.review', 'Approve, reject or request correction of documents'),
  ('document_types.manage', 'Configure document categories and requirements'),
  ('stations.manage', 'Edit any station and approve sensitive station changes'),
  ('stations.suspend', 'Suspend and reactivate stations'),
  ('bookings.read_all', 'Read all bookings'),
  ('bookings.override', 'Override booking status with a reason'),
  ('bookings.support_notes', 'Write customer-support notes on bookings'),
  ('reports.operational', 'Read operational reports and dashboard metrics'),
  ('finance.read', 'Read payments, refunds, ledger, expenses and financial reports'),
  ('finance.expenses.write', 'Record and edit draft platform expenses'),
  ('finance.expenses.approve', 'Approve, reject or void platform expenses'),
  ('finance.refunds.issue', 'Issue booking-fee refunds'),
  ('notifications.broadcast', 'Send platform announcements');

create table public.platform_role_permissions (
  role public.platform_role not null,
  permission text not null references public.platform_permissions (code) on delete cascade,
  primary key (role, permission)
);

-- super_admin implicitly holds every permission (see has_platform_permission),
-- so it is not listed. Finance permissions are NOT default for admin: they
-- must be granted explicitly through an override.
insert into public.platform_role_permissions (role, permission) values
  ('admin', 'businesses.read'),
  ('admin', 'businesses.manage'),
  ('admin', 'applications.review'),
  ('admin', 'applications.request_info'),
  ('admin', 'applications.decide'),
  ('admin', 'documents.review'),
  ('admin', 'stations.manage'),
  ('admin', 'stations.suspend'),
  ('admin', 'bookings.read_all'),
  ('admin', 'bookings.support_notes'),
  ('admin', 'reports.operational'),
  ('compliance_reviewer', 'businesses.read'),
  ('compliance_reviewer', 'applications.review'),
  ('compliance_reviewer', 'applications.request_info'),
  ('compliance_reviewer', 'documents.review');

create table public.platform_staff (
  user_id uuid primary key references public.profiles (id) on delete restrict,
  role public.platform_role not null,
  is_active boolean not null default true,
  granted_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.platform_staff is
  'Platform administrators. Written only by grant_platform_role()/bootstrap_super_admin(); never by client policies.';

create trigger platform_staff_updated_at before update on public.platform_staff
  for each row execute function private.set_updated_at();

create table public.platform_staff_permission_overrides (
  user_id uuid not null references public.platform_staff (user_id) on delete cascade,
  permission text not null references public.platform_permissions (code) on delete cascade,
  granted boolean not null,   -- true = add to role defaults, false = remove
  granted_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  primary key (user_id, permission)
);

create trigger platform_staff_audit after insert or update or delete on public.platform_staff
  for each row execute function private.audit_row_change();
create trigger platform_staff_permission_overrides_audit
  after insert or update or delete on public.platform_staff_permission_overrides
  for each row execute function private.audit_row_change();
create trigger platform_role_permissions_audit
  after insert or update or delete on public.platform_role_permissions
  for each row execute function private.audit_row_change();

-------------------------------------------------------------------------------
-- Authorization helpers (used by RLS policies and RPCs)
-------------------------------------------------------------------------------

create or replace function private.platform_role_of(p_user uuid)
returns public.platform_role
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.platform_staff where user_id = p_user and is_active;
$$;

create or replace function private.is_platform_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.platform_staff where user_id = (select auth.uid()) and is_active);
$$;

create or replace function private.has_platform_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with staff as (
    select role from public.platform_staff where user_id = (select auth.uid()) and is_active
  ), override as (
    select granted from public.platform_staff_permission_overrides
     where user_id = (select auth.uid()) and permission = p_permission
  )
  select case
    when not exists (select 1 from staff) then false
    when (select role from staff) = 'super_admin' then true
    when exists (select 1 from override) then (select granted from override)
    else exists (select 1 from public.platform_role_permissions rp, staff
                  where rp.role = staff.role and rp.permission = p_permission)
  end;
$$;

create or replace function private.require_platform_permission(p_permission text)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if not private.has_platform_permission(p_permission) then
    perform private.raise_error(403, 'forbidden', format('Missing permission %s', p_permission));
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Staff management RPCs
-------------------------------------------------------------------------------

-- One-time provisioning of the first super admin. Callable only from a trusted
-- context (SQL editor / psql as postgres, or service role). Refuses if any
-- active super admin already exists, so it can't be used to take over.
create or replace function public.bootstrap_super_admin(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  if exists (select 1 from public.platform_staff where role = 'super_admin' and is_active) then
    perform private.raise_error(409, 'super_admin_exists', 'A super admin already exists; use grant_platform_role');
  end if;
  select id into v_user from auth.users where lower(email) = lower(p_email);
  if v_user is null then
    perform private.raise_error(404, 'user_not_found', 'Create the user in Supabase Auth first (invite), then bootstrap');
  end if;
  insert into public.platform_staff (user_id, role) values (v_user, 'super_admin')
  on conflict (user_id) do update set role = 'super_admin', is_active = true;
  perform private.write_audit('platform_staff.bootstrap', 'platform_staff', v_user::text, null,
                              jsonb_build_object('role', 'super_admin'));
  return v_user;
end;
$$;

revoke execute on function public.bootstrap_super_admin(text) from public, anon, authenticated;
grant execute on function public.bootstrap_super_admin(text) to service_role;

create or replace function public.grant_platform_role(p_user_id uuid, p_role public.platform_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('admins.manage');
  if p_user_id = (select auth.uid()) then
    perform private.raise_error(403, 'cannot_change_own_role');
  end if;
  -- Only a super admin may create or modify another super admin.
  if (p_role = 'super_admin' or private.platform_role_of(p_user_id) = 'super_admin')
     and private.platform_role_of((select auth.uid())) <> 'super_admin' then
    perform private.raise_error(403, 'forbidden', 'Only a super admin can manage super admins');
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    perform private.raise_error(404, 'user_not_found');
  end if;
  insert into public.platform_staff (user_id, role, granted_by, is_active)
  values (p_user_id, p_role, (select auth.uid()), true)
  on conflict (user_id) do update
    set role = excluded.role, is_active = true, granted_by = excluded.granted_by;
end;
$$;

create or replace function public.revoke_platform_role(p_user_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('admins.manage');
  if p_user_id = (select auth.uid()) then
    perform private.raise_error(403, 'cannot_change_own_role');
  end if;
  if coalesce(trim(p_reason), '') = '' then
    perform private.raise_error(422, 'reason_required');
  end if;
  if private.platform_role_of(p_user_id) = 'super_admin'
     and private.platform_role_of((select auth.uid())) <> 'super_admin' then
    perform private.raise_error(403, 'forbidden', 'Only a super admin can revoke a super admin');
  end if;
  update public.platform_staff set is_active = false where user_id = p_user_id;
  if not found then
    perform private.raise_error(404, 'staff_not_found');
  end if;
  perform private.write_audit('platform_staff.revoke', 'platform_staff', p_user_id::text, null, null, p_reason);
end;
$$;

create or replace function public.set_platform_permission_override(p_user_id uuid, p_permission text, p_granted boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('admins.manage');
  if p_user_id = (select auth.uid()) then
    perform private.raise_error(403, 'cannot_change_own_role');
  end if;
  if not exists (select 1 from public.platform_staff where user_id = p_user_id) then
    perform private.raise_error(404, 'staff_not_found');
  end if;
  if p_granted is null then
    delete from public.platform_staff_permission_overrides where user_id = p_user_id and permission = p_permission;
  else
    insert into public.platform_staff_permission_overrides (user_id, permission, granted, granted_by)
    values (p_user_id, p_permission, p_granted, (select auth.uid()))
    on conflict (user_id, permission) do update set granted = excluded.granted, granted_by = excluded.granted_by;
  end if;
end;
$$;

create or replace function public.update_platform_setting(p_key text, p_value jsonb, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('settings.manage');
  if coalesce(trim(p_reason), '') = '' then
    perform private.raise_error(422, 'reason_required');
  end if;
  update public.platform_settings set value = p_value, updated_by = (select auth.uid()) where key = p_key;
  if not found then
    perform private.raise_error(404, 'setting_not_found');
  end if;
  perform private.write_audit('platform_settings.change_reason', 'platform_settings', p_key, null, null, p_reason);
end;
$$;

-- What the signed-in user is allowed to do. Clients use this to choose
-- navigation; the backend re-checks every action anyway.
create or replace function public.my_platform_access()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when s.user_id is null then jsonb_build_object('is_staff', false)
  else jsonb_build_object(
    'is_staff', true,
    'role', s.role,
    'permissions', (
      select coalesce(jsonb_agg(p.code order by p.code), '[]'::jsonb)
        from public.platform_permissions p
       where private.has_platform_permission(p.code)
    )
  ) end
  from (select 1) one
  left join public.platform_staff s on s.user_id = (select auth.uid()) and s.is_active;
$$;
