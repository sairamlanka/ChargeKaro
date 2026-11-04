-- Team management by role.
--
-- * The owner creates manager and staff logins directly (the team-members
--   Edge Function creates the account with a temporary password, then calls
--   add_business_member as the owner).
-- * A station manager cannot add or remove anyone directly. They raise a
--   request to add a staff member (only for stations they manage) or to remove
--   a staff member; the owner approves or rejects it.
-- * Removing a member deletes the membership row and its station assignments.
--   When the login was created by this business and belongs to no other
--   business, the Edge Function also closes the login and the profile's
--   personal details are wiped (scrub_member_profile). Bookings, check-ins
--   and audit rows keep the user id so history stays intact.

create type public.member_request_kind as enum ('add', 'remove');
create type public.member_request_status as enum ('pending', 'approved', 'rejected', 'cancelled');

create table public.business_member_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind public.member_request_kind not null,
  status public.member_request_status not null default 'pending',
  requested_by uuid not null references public.profiles (id),
  -- kind = 'add'
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  full_name text check (full_name is null or char_length(full_name) between 1 and 120),
  phone text check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'),
  role public.business_member_role,
  station_ids uuid[] not null default '{}',
  -- kind = 'remove'
  member_id uuid references public.business_members (id) on delete set null,
  member_name text,
  reason text check (reason is null or char_length(reason) <= 500),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  decision_note text check (decision_note is null or char_length(decision_note) <= 500),
  created_at timestamptz not null default now(),
  constraint business_member_requests_shape check (
    (kind = 'add' and email is not null and role = 'station_staff' and cardinality(station_ids) > 0)
    or (kind = 'remove')
  )
);

create index business_member_requests_business_idx on public.business_member_requests (business_id, status, created_at desc);
create unique index business_member_requests_one_pending_add
  on public.business_member_requests (business_id, lower(email)) where kind = 'add' and status = 'pending';
create unique index business_member_requests_one_pending_remove
  on public.business_member_requests (member_id) where kind = 'remove' and status = 'pending';

create trigger business_member_requests_audit after insert or update or delete on public.business_member_requests
  for each row execute function private.audit_row_change();

alter table public.business_member_requests enable row level security;

create policy business_member_requests_select on public.business_member_requests for select to authenticated using (
  requested_by = (select auth.uid())
  or private.is_business_owner(business_id)
  or private.has_platform_permission('businesses.read')
);

revoke all on public.business_member_requests from anon, authenticated;
grant select on public.business_member_requests to authenticated;

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Stations the caller manages in this business (active station manager only).
create or replace function private.managed_station_ids(p_business uuid)
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(a.station_id), '{}')
    from public.business_members m
    join public.station_assignments a on a.member_id = m.id
   where m.business_id = p_business and m.user_id = (select auth.uid())
     and m.status = 'active' and m.role = 'station_manager';
$$;

create or replace function private.member_json(m public.business_members)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', m.id,
    'business_id', m.business_id,
    'user_id', m.user_id,
    'role', m.role,
    'status', m.status,
    'permissions', to_jsonb(m.permissions),
    'created_at', m.created_at,
    'profiles', (select jsonb_build_object('full_name', p.full_name, 'email', p.email, 'phone', p.phone)
                   from public.profiles p where p.id = m.user_id),
    'station_assignments', (select coalesce(jsonb_agg(jsonb_build_object('station_id', a.station_id)), '[]'::jsonb)
                              from public.station_assignments a where a.member_id = m.id)
  );
$$;

create or replace function private.request_json(r public.business_member_requests)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select to_jsonb(r) || jsonb_build_object(
    'requested_by_name', (select coalesce(p.full_name, p.email) from public.profiles p where p.id = r.requested_by),
    'decided_by_name', (select coalesce(p.full_name, p.email) from public.profiles p where p.id = r.decided_by)
  );
$$;

create or replace function private.notify_business_owner(p_business uuid, p_type text, p_title text, p_body text, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
begin
  for v_owner in select user_id from public.business_members
                  where business_id = p_business and role = 'owner' and status = 'active' loop
    perform private.notify(v_owner, 'system', p_type, p_title, p_body, p_data);
  end loop;
end;
$$;

-------------------------------------------------------------------------------
-- Team list
-------------------------------------------------------------------------------

-- Owner: everyone. Manager: themselves plus staff who share one of their
-- stations. Staff: themselves.
create or replace function public.list_team_members(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.business_member_role := private.business_role(p_business_id);
  v_managed uuid[];
begin
  if v_role is null then
    perform private.raise_error(403, 'forbidden');
  end if;
  v_managed := private.managed_station_ids(p_business_id);
  return coalesce((
    select jsonb_agg(private.member_json(m) order by (m.role = 'owner') desc, m.role, m.created_at)
      from public.business_members m
     where m.business_id = p_business_id
       and (v_role = 'owner'
            or m.user_id = (select auth.uid())
            or (v_role = 'station_manager' and m.role = 'station_staff' and m.status = 'active'
                and exists (select 1 from public.station_assignments a
                             where a.member_id = m.id and a.station_id = any (v_managed))))), '[]'::jsonb);
end;
$$;

-------------------------------------------------------------------------------
-- Manager requests
-------------------------------------------------------------------------------

create or replace function public.request_team_member(
  p_business_id uuid,
  p_email text,
  p_full_name text,
  p_phone text default null,
  p_station_ids uuid[] default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.business_member_role := private.business_role(p_business_id);
  v_email text := lower(trim(coalesce(p_email, '')));
  v_managed uuid[];
  v_req public.business_member_requests;
begin
  if v_role = 'owner' then
    perform private.raise_error(422, 'owner_adds_directly', 'As the owner you can add the member directly');
  end if;
  if v_role is distinct from 'station_manager' then
    perform private.raise_error(403, 'forbidden', 'Only a station manager can request a new staff member');
  end if;
  if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    perform private.raise_error(422, 'invalid_email', 'Enter a valid email address');
  end if;
  if nullif(trim(coalesce(p_full_name, '')), '') is null then
    perform private.raise_error(422, 'name_required', 'Enter the staff member''s name');
  end if;
  v_managed := private.managed_station_ids(p_business_id);
  if coalesce(cardinality(p_station_ids), 0) = 0 or not (p_station_ids <@ v_managed) then
    perform private.raise_error(422, 'stations_not_managed', 'Pick one or more of the stations you manage');
  end if;
  if exists (select 1 from public.business_members m join public.profiles p on p.id = m.user_id
              where m.business_id = p_business_id and m.status = 'active' and lower(p.email) = v_email) then
    perform private.raise_error(409, 'already_member', 'This person is already on the team');
  end if;
  if exists (select 1 from public.business_member_requests
              where business_id = p_business_id and kind = 'add' and status = 'pending' and lower(email) = v_email) then
    perform private.raise_error(409, 'request_pending', 'A request for this email is already waiting for the owner');
  end if;
  insert into public.business_member_requests (business_id, kind, requested_by, email, full_name, phone, role, station_ids)
  values (p_business_id, 'add', (select auth.uid()), v_email, left(trim(p_full_name), 120), nullif(trim(coalesce(p_phone, '')), ''),
          'station_staff', p_station_ids)
  returning * into v_req;
  perform private.notify_business_owner(p_business_id, 'team.add_requested', 'New staff request',
    format('%s asked to add %s as staff.',
           coalesce((select full_name from public.profiles where id = (select auth.uid())), 'A manager'), v_req.full_name),
    jsonb_build_object('business_id', p_business_id, 'request_id', v_req.id));
  return private.request_json(v_req);
end;
$$;

create or replace function public.request_member_removal(p_member_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.business_members;
  v_role public.business_member_role;
  v_name text;
  v_req public.business_member_requests;
begin
  select * into v_member from public.business_members where id = p_member_id;
  if not found then
    perform private.raise_error(404, 'member_not_found');
  end if;
  v_role := private.business_role(v_member.business_id);
  if v_role = 'owner' then
    perform private.raise_error(422, 'owner_removes_directly', 'As the owner you can remove the member directly');
  end if;
  if v_role is distinct from 'station_manager' then
    perform private.raise_error(403, 'forbidden', 'Only a station manager can request a removal');
  end if;
  if v_member.role <> 'station_staff' or v_member.status <> 'active'
     or not exists (select 1 from public.station_assignments a
                     where a.member_id = v_member.id
                       and a.station_id = any (private.managed_station_ids(v_member.business_id))) then
    perform private.raise_error(403, 'forbidden', 'You can only request removal of staff at your stations');
  end if;
  if exists (select 1 from public.business_member_requests where member_id = p_member_id and kind = 'remove' and status = 'pending') then
    perform private.raise_error(409, 'request_pending', 'A removal request for this person is already waiting for the owner');
  end if;
  select coalesce(full_name, email) into v_name from public.profiles where id = v_member.user_id;
  insert into public.business_member_requests (business_id, kind, requested_by, member_id, member_name, reason)
  values (v_member.business_id, 'remove', (select auth.uid()), v_member.id, v_name, nullif(trim(coalesce(p_reason, '')), ''))
  returning * into v_req;
  perform private.notify_business_owner(v_member.business_id, 'team.remove_requested', 'Staff removal request',
    format('%s asked to remove %s.',
           coalesce((select full_name from public.profiles where id = (select auth.uid())), 'A manager'), coalesce(v_name, 'a staff member')),
    jsonb_build_object('business_id', v_member.business_id, 'request_id', v_req.id));
  return private.request_json(v_req);
end;
$$;

-- Owner: every request of the business. Manager: their own requests.
create or replace function public.list_member_requests(p_business_id uuid, p_pending_only boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.business_member_role := private.business_role(p_business_id);
begin
  if v_role is null then
    perform private.raise_error(403, 'forbidden');
  end if;
  return coalesce((
    select jsonb_agg(private.request_json(r) order by (r.status = 'pending') desc, r.created_at desc)
      from (select * from public.business_member_requests r
             where r.business_id = p_business_id
               and (v_role = 'owner' or r.requested_by = (select auth.uid()))
               and (not p_pending_only or r.status = 'pending')
             order by r.created_at desc
             limit 100) r), '[]'::jsonb);
end;
$$;

create or replace function public.cancel_member_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.business_member_requests set status = 'cancelled', decided_by = (select auth.uid()), decided_at = now()
   where id = p_request_id and requested_by = (select auth.uid()) and status = 'pending';
  if not found then
    perform private.raise_error(404, 'request_not_found', 'This request is no longer waiting');
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Owner decisions
-------------------------------------------------------------------------------

-- Locks and returns a pending request the caller (owner) may decide on.
create or replace function private.owner_pending_request(p_request_id uuid)
returns public.business_member_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.business_member_requests;
begin
  select * into v_req from public.business_member_requests where id = p_request_id for update;
  if not found or not private.is_business_owner(v_req.business_id) then
    perform private.raise_error(404, 'request_not_found');
  end if;
  if v_req.status <> 'pending' then
    perform private.raise_error(409, 'request_not_pending', 'This request was already handled');
  end if;
  return v_req;
end;
$$;

-- Used by the team-members Edge Function before it creates a login: checks
-- the caller owns the business and says whether the email already has one.
create or replace function public.prepare_member_account(p_business_id uuid, p_email text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid;
begin
  if not private.is_business_owner(p_business_id) then
    perform private.raise_error(403, 'forbidden', 'Only the business owner adds members');
  end if;
  select id into v_user from public.profiles where lower(email) = lower(trim(p_email)) and deleted_at is null;
  if v_user is not null and exists (select 1 from public.platform_staff where user_id = v_user and is_active) then
    perform private.raise_error(422, 'staff_cannot_join_business', 'This email belongs to a ChargeKaro admin account');
  end if;
  if v_user is not null and exists (select 1 from public.business_members
                                     where business_id = p_business_id and user_id = v_user and status = 'active') then
    perform private.raise_error(409, 'already_member', 'This person is already on the team');
  end if;
  return jsonb_build_object('exists', v_user is not null, 'user_id', v_user);
end;
$$;

create or replace function public.get_member_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return private.request_json(private.owner_pending_request(p_request_id));
end;
$$;

create or replace function public.reject_member_request(p_request_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.business_member_requests := private.owner_pending_request(p_request_id);
begin
  update public.business_member_requests
     set status = 'rejected', decided_by = (select auth.uid()), decided_at = now(),
         decision_note = nullif(trim(coalesce(p_note, '')), '')
   where id = v_req.id;
  perform private.notify(v_req.requested_by, 'system', 'team.request_rejected', 'Request declined',
    case v_req.kind when 'add' then format('The owner declined adding %s.', v_req.full_name)
                    else format('The owner declined removing %s.', coalesce(v_req.member_name, 'the staff member')) end,
    jsonb_build_object('business_id', v_req.business_id, 'request_id', v_req.id));
end;
$$;

-- Approves an add request. The Edge Function has already created the login
-- when the email had none.
create or replace function public.approve_member_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.business_member_requests := private.owner_pending_request(p_request_id);
  v_member uuid;
begin
  if v_req.kind <> 'add' then
    perform private.raise_error(422, 'use_remove_member', 'Approve removals through remove_business_member');
  end if;
  -- Only stations that still belong to the business.
  v_member := public.add_business_member(v_req.business_id, v_req.email, v_req.role, null,
    array(select s.id from public.stations s where s.business_id = v_req.business_id and s.id = any (v_req.station_ids)));
  update public.business_member_requests set status = 'approved', decided_by = (select auth.uid()), decided_at = now()
   where id = v_req.id;
  perform private.notify(v_req.requested_by, 'system', 'team.request_approved', 'Staff added',
    format('%s is now on your team.', v_req.full_name),
    jsonb_build_object('business_id', v_req.business_id, 'request_id', v_req.id));
  return jsonb_build_object('member_id', v_member);
end;
$$;

-- Deletes a member (owner only). With p_request_id it also approves that
-- removal request. Returns what the Edge Function needs to decide whether to
-- close the login.
create or replace function public.remove_business_member(p_member_id uuid, p_request_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.business_members;
  v_req public.business_member_requests;
  v_name text;
  v_managed boolean;
begin
  if p_request_id is not null then
    v_req := private.owner_pending_request(p_request_id);
    if v_req.kind <> 'remove' or v_req.member_id is distinct from p_member_id then
      perform private.raise_error(422, 'request_mismatch');
    end if;
  end if;
  select * into v_member from public.business_members where id = p_member_id for update;
  if not found or not private.is_business_owner(v_member.business_id) then
    perform private.raise_error(404, 'member_not_found');
  end if;
  if v_member.role = 'owner' then
    perform private.raise_error(422, 'cannot_change_owner', 'The owner cannot be removed');
  end if;
  select coalesce(full_name, email) into v_name from public.profiles where id = v_member.user_id;
  -- Pending removal requests for this member are settled by this delete.
  update public.business_member_requests
     set status = 'approved', decided_by = (select auth.uid()), decided_at = now()
   where member_id = v_member.id and kind = 'remove' and status = 'pending';
  delete from public.business_members where id = v_member.id;  -- cascades to station_assignments
  perform private.write_audit('business.member_removed', 'business_members', v_member.id::text,
    jsonb_build_object('user_id', v_member.user_id, 'role', v_member.role, 'business_id', v_member.business_id), null);
  if v_req.id is not null then
    perform private.notify(v_req.requested_by, 'system', 'team.request_approved', 'Staff removed',
      format('%s was removed from the team.', coalesce(v_name, 'The staff member')),
      jsonb_build_object('business_id', v_member.business_id, 'request_id', v_req.id));
  end if;
  select coalesce(u.raw_app_meta_data ->> 'created_by_business', '') = v_member.business_id::text
    into v_managed from auth.users u where u.id = v_member.user_id;
  return jsonb_build_object(
    'user_id', v_member.user_id,
    'managed_account', coalesce(v_managed, false),
    'other_memberships', (select count(*) from public.business_members where user_id = v_member.user_id),
    'is_platform_staff', exists (select 1 from public.platform_staff where user_id = v_member.user_id)
  );
end;
$$;

-- Service role only: wipes personal details of a closed member login.
create or replace function public.scrub_member_profile(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.business_members where user_id = p_user_id)
     or exists (select 1 from public.platform_staff where user_id = p_user_id) then
    perform private.raise_error(409, 'still_in_use', 'This login is still used elsewhere');
  end if;
  update public.profiles
     set full_name = 'Former team member', phone = null, email = null, avatar_path = null, deleted_at = now()
   where id = p_user_id;
  delete from public.device_tokens where user_id = p_user_id;
end;
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------

revoke execute on function
  private.managed_station_ids(uuid),
  private.member_json(public.business_members),
  private.request_json(public.business_member_requests),
  private.notify_business_owner(uuid, text, text, text, jsonb),
  private.owner_pending_request(uuid),
  public.list_team_members(uuid),
  public.request_team_member(uuid, text, text, text, uuid[]),
  public.request_member_removal(uuid, text),
  public.list_member_requests(uuid, boolean),
  public.cancel_member_request(uuid),
  public.prepare_member_account(uuid, text),
  public.get_member_request(uuid),
  public.reject_member_request(uuid, text),
  public.approve_member_request(uuid),
  public.remove_business_member(uuid, uuid),
  public.scrub_member_profile(uuid)
from public, anon;

grant execute on function
  public.list_team_members(uuid),
  public.request_team_member(uuid, text, text, text, uuid[]),
  public.request_member_removal(uuid, text),
  public.list_member_requests(uuid, boolean),
  public.cancel_member_request(uuid),
  public.prepare_member_account(uuid, text),
  public.get_member_request(uuid),
  public.reject_member_request(uuid, text),
  public.approve_member_request(uuid),
  public.remove_business_member(uuid, uuid)
to authenticated;

revoke execute on function public.scrub_member_profile(uuid) from authenticated;
grant execute on function public.scrub_member_profile(uuid) to service_role;
