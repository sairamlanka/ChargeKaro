-- Business creation, station applications, documents and reviews, station
-- lifecycle (approval, closure, deactivation) and sensitive change requests.

-------------------------------------------------------------------------------
-- Document configuration (admin-managed, not hard-coded)
-------------------------------------------------------------------------------

create type public.document_scope as enum ('business', 'station');

create table public.document_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z][a-z0-9_]{1,63}$'),
  name text not null check (char_length(name) between 2 and 120),
  description text check (description is null or char_length(description) <= 1000),
  scope public.document_scope not null,
  is_required boolean not null default false,
  -- null = applies to every business type
  required_for_business_types public.business_type[],
  allowed_mime_types text[] not null default array['application/pdf', 'image/jpeg', 'image/png'],
  max_size_bytes int not null default 10485760 check (max_size_bytes between 1024 and 26214400),
  requires_expiry_date boolean not null default false,
  reminder_days_before int[] not null default array[30, 7],
  -- Explicit policy switch. Expiry never suspends a station unless this is on.
  expiry_suspends_station boolean not null default false,
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (allowed_mime_types <@ array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
);

create trigger document_types_updated_at before update on public.document_types
  for each row execute function private.set_updated_at();
create trigger document_types_audit after insert or update or delete on public.document_types
  for each row execute function private.audit_row_change();

-- Initial configuration. Administrators can change requirements at any time;
-- these are starting defaults, not legal advice.
insert into public.document_types (code, name, description, scope, is_required, requires_expiry_date, sort_order) values
  ('owner_identity_proof', 'Owner identity proof', 'Government-issued identity document of the business owner or authorised signatory.', 'business', true, false, 10),
  ('business_registration', 'Business registration', 'Certificate of incorporation, partnership deed, shop and establishment registration or equivalent, where applicable.', 'business', false, false, 20),
  ('gst_certificate', 'GST registration certificate', 'If the business is GST-registered.', 'business', false, false, 30),
  ('electricity_connection', 'Electricity connection / load sanction', 'Electricity bill or sanctioned-load document for the charging connection.', 'station', true, false, 40),
  ('site_authorisation', 'Site ownership or lease', 'Proof of ownership, lease or permission to operate at the site.', 'station', true, true, 50),
  ('local_approvals', 'Local approvals and licences', 'Applicable local authority approvals, fire safety or other licences.', 'station', false, true, 60);

-------------------------------------------------------------------------------
-- Applications
-------------------------------------------------------------------------------

create type public.application_status as enum (
  'draft', 'submitted', 'under_review', 'additional_information_required', 'approved', 'rejected', 'suspended'
);

create table public.station_applications (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null unique references public.stations (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  status public.application_status not null default 'draft',
  revision int not null default 0,
  submitted_at timestamptz,
  submitted_by uuid references public.profiles (id),
  reviewer_id uuid references public.profiles (id),
  review_started_at timestamptz,
  decided_at timestamptz,
  decided_by uuid references public.profiles (id),
  latest_feedback text,
  resubmission_allowed boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index station_applications_status_idx on public.station_applications (status, submitted_at);
create index station_applications_business_idx on public.station_applications (business_id);

create trigger station_applications_updated_at before update on public.station_applications
  for each row execute function private.set_updated_at();

create table public.application_events (
  id bigint generated always as identity primary key,
  application_id uuid not null references public.station_applications (id) on delete cascade,
  from_status public.application_status,
  to_status public.application_status not null,
  actor_id uuid references public.profiles (id),
  note text,
  created_at timestamptz not null default now()
);

create index application_events_application_idx on public.application_events (application_id, created_at);

create trigger application_events_immutable before update or delete on public.application_events
  for each row execute function private.prevent_mutation();

create or replace function private.application_transition(
  p_application uuid,
  p_to public.application_status,
  p_note text default null
)
returns public.station_applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.station_applications;
  v_from public.application_status;
  v_allowed boolean;
begin
  select * into v_app from public.station_applications where id = p_application for update;
  if not found then
    perform private.raise_error(404, 'application_not_found');
  end if;
  v_from := v_app.status;
  v_allowed := case v_from
    when 'draft' then p_to in ('submitted')
    when 'submitted' then p_to in ('under_review', 'additional_information_required', 'rejected')
    when 'under_review' then p_to in ('additional_information_required', 'approved', 'rejected')
    when 'additional_information_required' then p_to in ('submitted', 'rejected')
    when 'rejected' then p_to in ('submitted')
    when 'approved' then p_to in ('suspended')
    when 'suspended' then p_to in ('approved')
  end;
  if not v_allowed then
    perform private.raise_error(409, 'invalid_status_transition',
      format('Application cannot move from %s to %s', v_from, p_to));
  end if;
  update public.station_applications
     set status = p_to,
         latest_feedback = case when p_to in ('additional_information_required', 'rejected', 'suspended') then p_note
                                when p_to = 'submitted' then null
                                else latest_feedback end
   where id = p_application
  returning * into v_app;
  insert into public.application_events (application_id, from_status, to_status, actor_id, note)
  values (p_application, v_from, p_to, (select auth.uid()), p_note);
  return v_app;
end;
$$;

-- Each new station gets a draft application.
create or replace function private.create_draft_application()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.station_applications (station_id, business_id) values (new.id, new.business_id);
  insert into public.application_events (application_id, from_status, to_status, actor_id, note)
  select id, null, 'draft', (select auth.uid()), 'Application created' from public.station_applications where station_id = new.id;
  return new;
end;
$$;

create trigger stations_create_application after insert on public.stations
  for each row execute function private.create_draft_application();

-------------------------------------------------------------------------------
-- Documents
-------------------------------------------------------------------------------

create type public.document_status as enum (
  'pending_review', 'approved', 'rejected', 'correction_required', 'expired', 'superseded'
);

create table public.station_documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  station_id uuid references public.stations (id) on delete cascade,  -- null = business-level document
  document_type_id uuid not null references public.document_types (id) on delete restrict,
  storage_path text not null unique,
  file_name text not null check (char_length(file_name) between 1 and 200),
  mime_type text not null,
  size_bytes int not null check (size_bytes > 0),
  status public.document_status not null default 'pending_review',
  issued_on date,
  expires_on date,
  review_note text,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  uploaded_by uuid not null references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_on is null or issued_on is null or expires_on > issued_on)
);

create index station_documents_business_idx on public.station_documents (business_id);
create index station_documents_station_idx on public.station_documents (station_id);
create index station_documents_expiry_idx on public.station_documents (expires_on) where status = 'approved';

create trigger station_documents_updated_at before update on public.station_documents
  for each row execute function private.set_updated_at();

-- Runs as the invoker (not SECURITY DEFINER) so is_client_write() sees the
-- caller's role.
create or replace function private.validate_station_document()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_type public.document_types;
begin
  select * into v_type from public.document_types where id = new.document_type_id;
  if private.is_client_write() then
    if tg_op = 'UPDATE' then
      perform private.raise_error(403, 'protected_field', 'Documents are reviewed by the platform; upload a new version instead');
    end if;
    new.status := 'pending_review';
    new.review_note := null;
    new.reviewed_by := null;
    new.reviewed_at := null;
    new.uploaded_by := (select auth.uid());
    if not v_type.is_active then
      perform private.raise_error(422, 'document_type_inactive');
    end if;
    if not (new.mime_type = any (v_type.allowed_mime_types)) then
      perform private.raise_error(422, 'invalid_file_type', format('Allowed: %s', array_to_string(v_type.allowed_mime_types, ', ')));
    end if;
    if new.size_bytes > v_type.max_size_bytes then
      perform private.raise_error(422, 'file_too_large', format('Maximum %s bytes', v_type.max_size_bytes));
    end if;
    if v_type.requires_expiry_date and new.expires_on is null then
      perform private.raise_error(422, 'expiry_date_required');
    end if;
    if new.expires_on is not null and new.expires_on <= current_date then
      perform private.raise_error(422, 'document_already_expired');
    end if;
  end if;
  if (v_type.scope = 'station') <> (new.station_id is not null) then
    perform private.raise_error(422, 'document_scope_mismatch',
      format('%s documents must %s a station', v_type.scope, case when v_type.scope = 'station' then 'reference' else 'not reference' end));
  end if;
  if new.station_id is not null and not exists (
      select 1 from public.stations where id = new.station_id and business_id = new.business_id) then
    perform private.raise_error(422, 'station_business_mismatch');
  end if;
  -- Object path must sit under the business folder of the private bucket.
  if split_part(new.storage_path, '/', 1) <> new.business_id::text then
    perform private.raise_error(422, 'invalid_storage_path', 'Path must start with the business id');
  end if;
  return new;
end;
$$;

create trigger station_documents_validate before insert or update on public.station_documents
  for each row execute function private.validate_station_document();

-- A new upload supersedes earlier non-approved versions of the same document.
-- Approved versions stay valid until the new one is approved.
create or replace function private.supersede_previous_documents()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.station_documents
     set status = 'superseded'
   where id <> new.id
     and business_id = new.business_id
     and document_type_id = new.document_type_id
     and station_id is not distinct from new.station_id
     and status in ('pending_review', 'rejected', 'correction_required');
  return new;
end;
$$;

create trigger station_documents_supersede after insert on public.station_documents
  for each row execute function private.supersede_previous_documents();

create table public.document_reviews (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.station_documents (id) on delete cascade,
  reviewer_id uuid not null references public.profiles (id),
  decision public.document_status not null check (decision in ('approved', 'rejected', 'correction_required')),
  comment text,
  created_at timestamptz not null default now(),
  check (decision = 'approved' or char_length(trim(coalesce(comment, ''))) > 0)
);

create index document_reviews_document_idx on public.document_reviews (document_id, created_at);
create trigger document_reviews_immutable before update or delete on public.document_reviews
  for each row execute function private.prevent_mutation();

-- Required document types for a station application, with the best current
-- upload for each.
create or replace function public.application_document_checklist(p_application_id uuid)
returns table (
  document_type_id uuid, code text, name text, scope public.document_scope, is_required boolean,
  document_id uuid, document_status public.document_status, expires_on date
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_app public.station_applications;
  v_btype public.business_type;
begin
  select * into v_app from public.station_applications where id = p_application_id;
  if not found then
    perform private.raise_error(404, 'application_not_found');
  end if;
  if not (private.is_business_member(v_app.business_id) or private.has_platform_permission('applications.review')) then
    perform private.raise_error(403, 'forbidden');
  end if;
  select business_type into v_btype from public.businesses where id = v_app.business_id;
  return query
  select t.id, t.code, t.name, t.scope,
         (t.is_required and (t.required_for_business_types is null or v_btype = any (t.required_for_business_types))),
         d.id, d.status, d.expires_on
    from public.document_types t
    left join lateral (
      select sd.* from public.station_documents sd
       where sd.document_type_id = t.id
         and sd.business_id = v_app.business_id
         and (case when t.scope = 'station' then sd.station_id = v_app.station_id else sd.station_id is null end)
         and sd.status <> 'superseded'
       order by (sd.status = 'approved') desc, sd.created_at desc
       limit 1) d on true
   where t.is_active
   order by t.sort_order, t.name;
end;
$$;

-------------------------------------------------------------------------------
-- Business RPCs
-------------------------------------------------------------------------------

create or replace function public.create_business(
  p_legal_name text,
  p_display_name text,
  p_owner_full_name text,
  p_contact_phone text,
  p_contact_email text,
  p_business_type public.business_type,
  p_registration_number text default null,
  p_gstin text default null,
  p_registered_address_line1 text default null,
  p_registered_address_line2 text default null,
  p_registered_city text default null,
  p_registered_state text default null,
  p_registered_postal_code text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_id uuid;
begin
  if v_user is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if private.is_platform_staff() then
    perform private.raise_error(403, 'staff_cannot_own_business', 'Platform staff accounts cannot register businesses');
  end if;
  if (select count(*) from public.businesses where owner_id = v_user and archived_at is null) >= 10 then
    perform private.raise_error(422, 'business_limit_reached');
  end if;
  insert into public.businesses (owner_id, legal_name, display_name, owner_full_name, contact_phone, contact_email,
                                 business_type, registration_number, gstin, registered_address_line1,
                                 registered_address_line2, registered_city, registered_state, registered_postal_code)
  values (v_user, trim(p_legal_name), nullif(trim(p_display_name), ''), trim(p_owner_full_name), p_contact_phone,
          lower(trim(p_contact_email)), p_business_type, nullif(trim(p_registration_number), ''),
          nullif(upper(trim(p_gstin)), ''), p_registered_address_line1, p_registered_address_line2,
          p_registered_city, p_registered_state, p_registered_postal_code)
  returning id into v_id;
  insert into public.business_members (business_id, user_id, role, added_by) values (v_id, v_user, 'owner', v_user);
  perform private.write_audit('business.create', 'businesses', v_id::text, null,
                              jsonb_build_object('legal_name', p_legal_name, 'business_type', p_business_type));
  return v_id;
end;
$$;

-- What the signed-in business user can access: memberships, roles,
-- permissions and assigned stations. Used after login to route the user.
create or replace function public.my_business_access()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_id', b.id,
    'business_name', coalesce(b.display_name, b.legal_name),
    'business_status', b.status,
    'business_status_reason', b.status_reason,
    'member_id', m.id,
    'role', m.role,
    'permissions', to_jsonb(m.permissions),
    'station_ids', case when m.role = 'owner'
                     then (select coalesce(jsonb_agg(s.id), '[]'::jsonb) from public.stations s where s.business_id = b.id)
                     else (select coalesce(jsonb_agg(a.station_id), '[]'::jsonb) from public.station_assignments a where a.member_id = m.id)
                   end
  ) order by b.created_at), '[]'::jsonb)
  from public.business_members m
  join public.businesses b on b.id = m.business_id
  where m.user_id = (select auth.uid()) and m.status = 'active' and b.archived_at is null;
$$;

create or replace function public.add_business_member(
  p_business_id uuid,
  p_email text,
  p_role public.business_member_role,
  p_permissions text[] default null,
  p_station_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_member uuid;
begin
  if not private.is_business_owner(p_business_id) then
    perform private.raise_error(403, 'forbidden', 'Only the business owner manages members');
  end if;
  if p_role = 'owner' then
    perform private.raise_error(422, 'cannot_add_owner');
  end if;
  select id into v_user from public.profiles where lower(email) = lower(trim(p_email)) and deleted_at is null;
  if v_user is null then
    perform private.raise_error(404, 'user_not_found', 'The person must first create an account with this email');
  end if;
  if exists (select 1 from public.platform_staff where user_id = v_user and is_active) then
    perform private.raise_error(422, 'staff_cannot_join_business');
  end if;
  insert into public.business_members (business_id, user_id, role, permissions, added_by, status)
  values (p_business_id, v_user, p_role, coalesce(p_permissions, private.default_member_permissions(p_role)),
          (select auth.uid()), 'active')
  on conflict (business_id, user_id) do update
    set role = excluded.role, permissions = excluded.permissions, status = 'active'
  returning id into v_member;
  if (select role from public.business_members where id = v_member) = 'owner' then
    perform private.raise_error(422, 'cannot_change_owner');
  end if;
  delete from public.station_assignments where member_id = v_member;
  insert into public.station_assignments (member_id, station_id)
  select v_member, unnest(coalesce(p_station_ids, '{}'));
  perform private.notify(v_user, 'system', 'business.member_added', 'You were added to a business',
    format('You now have %s access.', replace(p_role::text, '_', ' ')),
    jsonb_build_object('business_id', p_business_id));
  return v_member;
end;
$$;

create or replace function public.update_business_member(
  p_member_id uuid,
  p_role public.business_member_role,
  p_permissions text[],
  p_station_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.business_members;
begin
  select * into v_member from public.business_members where id = p_member_id for update;
  if not found or not private.is_business_owner(v_member.business_id) then
    perform private.raise_error(403, 'forbidden');
  end if;
  if v_member.role = 'owner' or p_role = 'owner' then
    perform private.raise_error(422, 'cannot_change_owner');
  end if;
  update public.business_members set role = p_role, permissions = p_permissions where id = p_member_id;
  delete from public.station_assignments where member_id = p_member_id;
  insert into public.station_assignments (member_id, station_id) select p_member_id, unnest(coalesce(p_station_ids, '{}'));
end;
$$;

create or replace function public.revoke_business_member(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.business_members;
begin
  select * into v_member from public.business_members where id = p_member_id for update;
  if not found or not private.is_business_owner(v_member.business_id) then
    perform private.raise_error(403, 'forbidden');
  end if;
  if v_member.role = 'owner' then
    perform private.raise_error(422, 'cannot_change_owner');
  end if;
  update public.business_members set status = 'revoked' where id = p_member_id;
  delete from public.station_assignments where member_id = p_member_id;
end;
$$;

-------------------------------------------------------------------------------
-- Application workflow RPCs
-------------------------------------------------------------------------------

create or replace function public.submit_station_application(p_application_id uuid)
returns public.station_applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.station_applications;
  v_missing text;
  v_business public.businesses;
begin
  select * into v_app from public.station_applications where id = p_application_id;
  if not found then
    perform private.raise_error(404, 'application_not_found');
  end if;
  if not private.is_business_owner(v_app.business_id) then
    perform private.raise_error(403, 'forbidden', 'Only the business owner can submit applications');
  end if;
  select * into v_business from public.businesses where id = v_app.business_id;
  if v_business.status in ('suspended', 'deactivated') then
    perform private.raise_error(403, 'business_not_active');
  end if;
  if v_app.status = 'rejected' and not v_app.resubmission_allowed then
    perform private.raise_error(409, 'resubmission_not_allowed');
  end if;
  if not exists (select 1 from public.charging_points where station_id = v_app.station_id and archived_at is null) then
    perform private.raise_error(422, 'charging_point_required', 'Add at least one charging point before submitting');
  end if;
  if not exists (select 1 from public.station_operating_hours where station_id = v_app.station_id and charging_point_id is null) then
    perform private.raise_error(422, 'operating_hours_required', 'Set operating hours before submitting');
  end if;
  select string_agg(c.name, ', ' order by c.name) into v_missing
    from public.application_document_checklist(p_application_id) c
   where c.is_required and (c.document_id is null or c.document_status in ('rejected', 'correction_required', 'expired'));
  if v_missing is not null then
    perform private.raise_error(422, 'missing_documents', 'Upload required documents: ' || v_missing);
  end if;
  v_app := private.application_transition(p_application_id, 'submitted', null);
  update public.station_applications
     set submitted_at = now(), submitted_by = (select auth.uid()), revision = revision + 1,
         decided_at = null, decided_by = null
   where id = p_application_id
  returning * into v_app;
  perform private.write_audit('application.submit', 'station_applications', p_application_id::text, null,
                              jsonb_build_object('revision', v_app.revision));
  perform private.notify_platform_staff('applications.review', 'application', 'application.submitted',
    'New station application',
    format('%s submitted %s for review.', coalesce(v_business.display_name, v_business.legal_name),
           (select name from public.stations where id = v_app.station_id)),
    jsonb_build_object('application_id', p_application_id),
    format('application.submitted:%s:%s', p_application_id, v_app.revision));
  return v_app;
end;
$$;

create or replace function private.require_reviewer_not_member(p_business uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  -- Separation of duties: nobody reviews a business they belong to.
  if private.is_business_member(p_business) then
    perform private.raise_error(403, 'conflict_of_interest', 'You cannot review an application of your own business');
  end if;
end;
$$;

create or replace function public.start_application_review(p_application_id uuid)
returns public.station_applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.station_applications;
begin
  perform private.require_platform_permission('applications.review');
  select * into v_app from public.station_applications where id = p_application_id;
  if not found then
    perform private.raise_error(404, 'application_not_found');
  end if;
  perform private.require_reviewer_not_member(v_app.business_id);
  v_app := private.application_transition(p_application_id, 'under_review', null);
  update public.station_applications set reviewer_id = (select auth.uid()), review_started_at = now()
   where id = p_application_id returning * into v_app;
  perform private.write_audit('application.start_review', 'station_applications', p_application_id::text);
  return v_app;
end;
$$;

create or replace function public.request_application_information(p_application_id uuid, p_note text)
returns public.station_applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.station_applications;
begin
  perform private.require_platform_permission('applications.request_info');
  if char_length(trim(coalesce(p_note, ''))) < 5 then
    perform private.raise_error(422, 'note_required', 'Explain what information is needed');
  end if;
  select * into v_app from public.station_applications where id = p_application_id;
  if not found then
    perform private.raise_error(404, 'application_not_found');
  end if;
  perform private.require_reviewer_not_member(v_app.business_id);
  v_app := private.application_transition(p_application_id, 'additional_information_required', trim(p_note));
  perform private.write_audit('application.request_info', 'station_applications', p_application_id::text, null, null, p_note);
  perform private.notify_business(v_app.business_id, v_app.station_id, 'documents.manage', 'application',
    'application.info_requested', 'More information needed', trim(p_note),
    jsonb_build_object('application_id', p_application_id, 'station_id', v_app.station_id),
    format('application.info_requested:%s:%s', p_application_id, (select count(*) from public.application_events where application_id = p_application_id)));
  return v_app;
end;
$$;

create or replace function public.approve_station_application(p_application_id uuid, p_note text default null)
returns public.station_applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.station_applications;
  v_pending text;
  v_station_name text;
begin
  perform private.require_platform_permission('applications.decide');
  select * into v_app from public.station_applications where id = p_application_id;
  if not found then
    perform private.raise_error(404, 'application_not_found');
  end if;
  perform private.require_reviewer_not_member(v_app.business_id);
  select string_agg(c.name, ', ' order by c.name) into v_pending
    from public.application_document_checklist(p_application_id) c
   where c.is_required and (c.document_id is null or c.document_status <> 'approved');
  if v_pending is not null then
    perform private.raise_error(422, 'documents_not_verified', 'Verify required documents first: ' || v_pending);
  end if;
  v_app := private.application_transition(p_application_id, 'approved', p_note);
  update public.station_applications set decided_at = now(), decided_by = (select auth.uid())
   where id = p_application_id returning * into v_app;
  update public.stations
     set status = 'active', status_reason = null, approved_at = now(), approved_by = (select auth.uid())
   where id = v_app.station_id
  returning name into v_station_name;
  update public.businesses
     set status = 'active', status_changed_at = now(), status_changed_by = (select auth.uid())
   where id = v_app.business_id and status = 'pending_verification';
  perform private.write_audit('application.approve', 'station_applications', p_application_id::text,
    null, jsonb_build_object('station_id', v_app.station_id), p_note);
  perform private.notify_business(v_app.business_id, v_app.station_id, null, 'application', 'application.approved',
    'Station approved', format('%s is approved. You can now configure it and accept bookings.', v_station_name),
    jsonb_build_object('application_id', p_application_id, 'station_id', v_app.station_id),
    format('application.approved:%s:%s', p_application_id, v_app.revision));
  return v_app;
end;
$$;

create or replace function public.reject_station_application(
  p_application_id uuid,
  p_reason text,
  p_allow_resubmission boolean default true
)
returns public.station_applications
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.station_applications;
begin
  perform private.require_platform_permission('applications.decide');
  if char_length(trim(coalesce(p_reason, ''))) < 5 then
    perform private.raise_error(422, 'reason_required', 'A rejection reason is mandatory');
  end if;
  select * into v_app from public.station_applications where id = p_application_id;
  if not found then
    perform private.raise_error(404, 'application_not_found');
  end if;
  perform private.require_reviewer_not_member(v_app.business_id);
  v_app := private.application_transition(p_application_id, 'rejected', trim(p_reason));
  update public.station_applications
     set decided_at = now(), decided_by = (select auth.uid()), resubmission_allowed = coalesce(p_allow_resubmission, true)
   where id = p_application_id returning * into v_app;
  perform private.write_audit('application.reject', 'station_applications', p_application_id::text, null,
    jsonb_build_object('resubmission_allowed', v_app.resubmission_allowed), p_reason);
  perform private.notify_business(v_app.business_id, v_app.station_id, null, 'application', 'application.rejected',
    'Application rejected', trim(p_reason),
    jsonb_build_object('application_id', p_application_id, 'station_id', v_app.station_id),
    format('application.rejected:%s:%s', p_application_id, v_app.revision));
  return v_app;
end;
$$;

create or replace function public.review_document(
  p_document_id uuid,
  p_decision public.document_status,
  p_comment text default null
)
returns public.station_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc public.station_documents;
  v_type_name text;
begin
  perform private.require_platform_permission('documents.review');
  if p_decision not in ('approved', 'rejected', 'correction_required') then
    perform private.raise_error(422, 'invalid_decision');
  end if;
  if p_decision <> 'approved' and char_length(trim(coalesce(p_comment, ''))) < 3 then
    perform private.raise_error(422, 'comment_required', 'Explain why the document is not accepted');
  end if;
  select * into v_doc from public.station_documents where id = p_document_id for update;
  if not found then
    perform private.raise_error(404, 'document_not_found');
  end if;
  perform private.require_reviewer_not_member(v_doc.business_id);
  if v_doc.status = 'superseded' then
    perform private.raise_error(409, 'document_superseded', 'A newer version has been uploaded');
  end if;
  update public.station_documents
     set status = p_decision, review_note = nullif(trim(p_comment), ''), reviewed_by = (select auth.uid()), reviewed_at = now()
   where id = p_document_id returning * into v_doc;
  -- An approved new version replaces the previously approved one.
  if p_decision = 'approved' then
    update public.station_documents
       set status = 'superseded'
     where id <> p_document_id and business_id = v_doc.business_id and document_type_id = v_doc.document_type_id
       and station_id is not distinct from v_doc.station_id and status = 'approved';
  end if;
  insert into public.document_reviews (document_id, reviewer_id, decision, comment)
  values (p_document_id, (select auth.uid()), p_decision, nullif(trim(p_comment), ''));
  perform private.write_audit('document.review', 'station_documents', p_document_id::text, null,
    jsonb_build_object('decision', p_decision), p_comment);
  if p_decision <> 'approved' then
    select name into v_type_name from public.document_types where id = v_doc.document_type_id;
    perform private.notify_business(v_doc.business_id, v_doc.station_id, 'documents.manage', 'compliance',
      'document.' || p_decision::text, format('%s needs attention', v_type_name), trim(p_comment),
      jsonb_build_object('document_id', p_document_id, 'station_id', v_doc.station_id),
      format('document.review:%s:%s', p_document_id, p_decision));
  end if;
  return v_doc;
end;
$$;

-------------------------------------------------------------------------------
-- Sensitive station changes
-------------------------------------------------------------------------------

create or replace function public.request_station_change(p_station_id uuid, p_changes jsonb, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bad text;
  v_id uuid;
begin
  perform private.require_station_permission(p_station_id, 'station.edit');
  if jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    perform private.raise_error(422, 'changes_required');
  end if;
  select string_agg(k, ', ') into v_bad from jsonb_object_keys(p_changes) k
   where k <> all (private.station_sensitive_fields());
  if v_bad is not null then
    perform private.raise_error(422, 'field_not_change_requestable', 'Edit these fields directly: ' || v_bad);
  end if;
  insert into public.station_change_requests (station_id, changes, note, requested_by)
  values (p_station_id, p_changes, p_note, (select auth.uid()))
  returning id into v_id;
  perform private.notify_platform_staff('stations.manage', 'station', 'station.change_requested',
    'Station change request', 'A business requested a change to sensitive station details.',
    jsonb_build_object('change_request_id', v_id, 'station_id', p_station_id), 'station.change_requested:' || v_id);
  return v_id;
exception when unique_violation then
  perform private.raise_error(409, 'change_request_pending', 'A change request for this station is already pending');
end;
$$;

create or replace function public.decide_station_change(p_request_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.station_change_requests;
  v_before jsonb;
  v_station public.stations;
begin
  perform private.require_platform_permission('stations.manage');
  select * into v_req from public.station_change_requests where id = p_request_id for update;
  if not found then
    perform private.raise_error(404, 'change_request_not_found');
  end if;
  if v_req.status <> 'pending' then
    perform private.raise_error(409, 'change_request_closed');
  end if;
  select * into v_station from public.stations where id = v_req.station_id;
  perform private.require_reviewer_not_member(v_station.business_id);
  if not p_approve and char_length(trim(coalesce(p_note, ''))) < 3 then
    perform private.raise_error(422, 'reason_required');
  end if;
  if p_approve then
    v_before := (select jsonb_object_agg(k, to_jsonb(v_station) -> k) from jsonb_object_keys(v_req.changes) k);
    -- jsonb_populate_record applies only the requested keys over the current row.
    update public.stations s
       set name = r.name, address_line1 = r.address_line1, address_line2 = r.address_line2, landmark = r.landmark,
           city = r.city, district = r.district, state = r.state, postal_code = r.postal_code,
           country_code = r.country_code, latitude = r.latitude, longitude = r.longitude, timezone = r.timezone
      from jsonb_populate_record(v_station, v_req.changes) r
     where s.id = v_station.id;
    perform private.write_audit('station.change_approved', 'stations', v_station.id::text, v_before, v_req.changes, p_note);
  else
    perform private.write_audit('station.change_rejected', 'stations', v_station.id::text, null, v_req.changes, p_note);
  end if;
  update public.station_change_requests
     set status = case when p_approve then 'approved'::public.change_request_status else 'rejected' end,
         reviewed_by = (select auth.uid()), reviewed_at = now(), review_note = p_note
   where id = p_request_id;
  perform private.notify_business(v_station.business_id, v_station.id, 'station.edit', 'station',
    case when p_approve then 'station.change_approved' else 'station.change_rejected' end,
    case when p_approve then 'Station change approved' else 'Station change rejected' end,
    coalesce(p_note, case when p_approve then 'Your requested station changes are live.' else 'Your change request was rejected.' end),
    jsonb_build_object('station_id', v_station.id, 'change_request_id', p_request_id),
    'station.change_decided:' || p_request_id);
end;
$$;
