-- Businesses, membership, stations, operating hours, booking policies,
-- charging points, connectors and blocked periods.
--
-- Guard triggers use current_user to tell direct client writes
-- ('authenticated') from writes made inside SECURITY DEFINER RPCs (function
-- owner) or by the service role. Clients cannot change current_user.

create or replace function private.is_client_write()
returns boolean
language sql
stable
set search_path = ''
as $$
  select current_user in ('authenticated', 'anon');
$$;

-------------------------------------------------------------------------------
-- Businesses
-------------------------------------------------------------------------------

create type public.business_type as enum (
  'individual', 'sole_proprietorship', 'partnership', 'llp', 'private_limited',
  'public_limited', 'cooperative', 'government', 'trust_or_society', 'other'
);

-- Account status of the business itself, separate from station applications.
create type public.business_status as enum ('pending_verification', 'active', 'suspended', 'deactivated');

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete restrict,
  legal_name text not null check (char_length(trim(legal_name)) between 2 and 160),
  display_name text check (display_name is null or char_length(trim(display_name)) between 2 and 160),
  owner_full_name text not null check (char_length(trim(owner_full_name)) between 2 and 120),
  contact_phone text not null check (contact_phone ~ '^\+[1-9][0-9]{7,14}$'),
  contact_email text not null check (contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  business_type public.business_type not null,
  registration_number text check (registration_number is null or char_length(registration_number) <= 64),
  gstin text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  registered_address_line1 text check (registered_address_line1 is null or char_length(registered_address_line1) <= 200),
  registered_address_line2 text check (registered_address_line2 is null or char_length(registered_address_line2) <= 200),
  registered_city text,
  registered_state text,
  registered_postal_code text check (registered_postal_code is null or registered_postal_code ~ '^[1-9][0-9]{5}$'),
  status public.business_status not null default 'pending_verification',
  status_reason text,
  status_changed_at timestamptz,
  status_changed_by uuid references public.profiles (id),
  is_demo boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);

create index businesses_owner_idx on public.businesses (owner_id);
create index businesses_status_idx on public.businesses (status);
create unique index businesses_gstin_unique on public.businesses (gstin) where gstin is not null and archived_at is null;

create trigger businesses_updated_at before update on public.businesses
  for each row execute function private.set_updated_at();

create or replace function private.guard_business_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.is_client_write() then
    if new.owner_id is distinct from old.owner_id
       or new.status is distinct from old.status
       or new.status_reason is distinct from old.status_reason
       or new.status_changed_at is distinct from old.status_changed_at
       or new.status_changed_by is distinct from old.status_changed_by
       or new.is_demo is distinct from old.is_demo
       or new.archived_at is distinct from old.archived_at
       or new.created_at is distinct from old.created_at then
      perform private.raise_error(403, 'protected_field', 'Business status and ownership change only through platform workflows');
    end if;
    -- Legal identity is fixed once the business is verified.
    if old.status <> 'pending_verification' and (
         new.legal_name is distinct from old.legal_name
         or new.business_type is distinct from old.business_type
         or new.registration_number is distinct from old.registration_number
         or new.gstin is distinct from old.gstin) then
      perform private.raise_error(403, 'sensitive_change_requires_approval',
        'Legal name, type, registration number and GSTIN of a verified business can be changed only by the platform');
    end if;
  end if;
  return new;
end;
$$;

create trigger businesses_guard before update on public.businesses
  for each row execute function private.guard_business_update();

create trigger businesses_audit after update or delete on public.businesses
  for each row execute function private.audit_row_change();

-------------------------------------------------------------------------------
-- Business membership
-------------------------------------------------------------------------------

create type public.business_member_role as enum ('owner', 'station_manager', 'station_staff');
create type public.member_status as enum ('active', 'revoked');

-- Every permission a non-owner member can be granted. Owners hold all.
create or replace function private.business_permission_codes()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'station.edit', 'availability.edit', 'points.manage', 'points.status',
    'bookings.view', 'bookings.checkin', 'bookings.manage',
    'maintenance.report', 'maintenance.manage', 'documents.manage', 'reports.view'
  ];
$$;

create or replace function private.default_member_permissions(p_role public.business_member_role)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_role
    when 'owner' then private.business_permission_codes()
    when 'station_manager' then array[
      'station.edit', 'availability.edit', 'points.manage', 'points.status',
      'bookings.view', 'bookings.checkin', 'bookings.manage',
      'maintenance.report', 'maintenance.manage', 'reports.view']
    else array['bookings.view', 'bookings.checkin', 'points.status', 'maintenance.report']
  end;
$$;

create table public.business_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.business_member_role not null,
  permissions text[] not null default '{}',
  status public.member_status not null default 'active',
  added_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, user_id),
  constraint business_members_permissions_valid check (permissions <@ private.business_permission_codes()),
  -- Account-management and finance functions are never delegable.
  constraint business_members_staff_limits check (
    role <> 'station_staff' or not (permissions && array['documents.manage', 'availability.edit', 'station.edit'])
  )
);

create unique index business_members_one_owner on public.business_members (business_id) where role = 'owner';
create index business_members_user_idx on public.business_members (user_id) where status = 'active';

create trigger business_members_updated_at before update on public.business_members
  for each row execute function private.set_updated_at();
create trigger business_members_audit after insert or update or delete on public.business_members
  for each row execute function private.audit_row_change();

create or replace function private.normalize_member_permissions()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.role = 'owner' then
    new.permissions := private.business_permission_codes();
  elsif tg_op = 'INSERT' and coalesce(cardinality(new.permissions), 0) = 0 then
    new.permissions := private.default_member_permissions(new.role);
  end if;
  return new;
end;
$$;

create trigger business_members_normalize before insert or update on public.business_members
  for each row execute function private.normalize_member_permissions();

-------------------------------------------------------------------------------
-- Stations
-------------------------------------------------------------------------------

create type public.station_status as enum (
  'draft',               -- never approved; editable by the owner
  'active',              -- approved and open for reservations
  'temporarily_closed',  -- owner closed it; no new bookings
  'suspended',           -- platform suspended it
  'deactivated'          -- permanently closed
);

create table public.stations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete restrict,
  name text not null check (char_length(trim(name)) between 2 and 120),
  description text check (description is null or char_length(description) <= 2000),
  logo_path text,
  address_line1 text not null check (char_length(trim(address_line1)) between 3 and 200),
  address_line2 text check (address_line2 is null or char_length(address_line2) <= 200),
  landmark text check (landmark is null or char_length(landmark) <= 120),
  city text not null check (char_length(trim(city)) between 2 and 80),
  district text not null check (char_length(trim(district)) between 2 and 80),
  state text not null check (char_length(trim(state)) between 2 and 80),
  postal_code text not null check (postal_code ~ '^[1-9][0-9]{5}$'),
  country_code text not null default 'IN' check (country_code ~ '^[A-Z]{2}$'),
  latitude numeric(9, 6) not null check (latitude between -90 and 90),
  longitude numeric(9, 6) not null check (longitude between -180 and 180),
  timezone text not null default 'Asia/Kolkata',
  contact_phone text not null check (contact_phone ~ '^\+[1-9][0-9]{7,14}$'),
  emergency_contact_name text check (emergency_contact_name is null or char_length(emergency_contact_name) <= 120),
  emergency_contact_phone text check (emergency_contact_phone is null or emergency_contact_phone ~ '^\+[1-9][0-9]{7,14}$'),
  parking_spaces int not null default 0 check (parking_spaces between 0 and 1000),
  amenities text[] not null default '{}',
  accepted_payment_methods text[] not null default '{}',
  status public.station_status not null default 'draft',
  status_reason text,
  approved_at timestamptz,
  approved_by uuid references public.profiles (id),
  closed_until timestamptz,
  deactivation_requested_at timestamptz,
  deactivation_request_reason text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stations_amenities_valid check (amenities <@ array[
    'restroom', 'drinking_water', 'cafe', 'restaurant', 'wifi', 'waiting_lounge', 'shopping',
    'covered_parking', 'cctv', 'wheelchair_accessible', 'air_pump', 'atm', 'open_24x7']),
  -- Informational only: the platform never collects charging fees.
  constraint stations_payment_methods_valid check (accepted_payment_methods <@ array[
    'cash', 'upi', 'debit_card', 'credit_card', 'rfid_card', 'operator_app', 'wallet']),
  -- India bounding box when the station is in India.
  constraint stations_coordinates_plausible check (
    country_code <> 'IN' or (latitude between 6.0 and 37.6 and longitude between 68.0 and 97.5)),
  constraint stations_approval_consistent check (status = 'draft' or approved_at is not null)
);

create index stations_business_idx on public.stations (business_id);
create index stations_status_idx on public.stations (status);
create index stations_location_idx on public.stations (state, city);

create trigger stations_updated_at before update on public.stations
  for each row execute function private.set_updated_at();

create or replace function private.validate_station()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_valid_timezone(new.timezone) then
    perform private.raise_error(422, 'invalid_timezone', format('Unknown time zone %s', new.timezone));
  end if;
  return new;
end;
$$;

create trigger stations_validate before insert or update of timezone on public.stations
  for each row execute function private.validate_station();

-- Fields that, once the station has been approved, change only through an
-- admin-approved station_change_request.
create or replace function private.station_sensitive_fields()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['name', 'address_line1', 'address_line2', 'landmark', 'city', 'district', 'state',
               'postal_code', 'country_code', 'latitude', 'longitude', 'timezone'];
$$;

create or replace function private.guard_station_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  f text;
begin
  if not private.is_client_write() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.approved_at := null;
    new.approved_by := null;
    new.status_reason := null;
    new.closed_until := null;
    new.deactivation_requested_at := null;
    new.deactivation_request_reason := null;
    new.created_by := (select auth.uid());
    return new;
  end if;
  if new.business_id is distinct from old.business_id
     or new.status is distinct from old.status
     or new.status_reason is distinct from old.status_reason
     or new.approved_at is distinct from old.approved_at
     or new.approved_by is distinct from old.approved_by
     or new.closed_until is distinct from old.closed_until
     or new.deactivation_requested_at is distinct from old.deactivation_requested_at
     or new.deactivation_request_reason is distinct from old.deactivation_request_reason
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    perform private.raise_error(403, 'protected_field', 'Station status changes only through station workflows');
  end if;
  if old.approved_at is not null then
    foreach f in array private.station_sensitive_fields() loop
      if (to_jsonb(new) -> f) is distinct from (to_jsonb(old) -> f) then
        perform private.raise_error(403, 'sensitive_change_requires_approval',
          format('Changing %s on an approved station needs admin approval; submit a change request', f));
      end if;
    end loop;
  end if;
  return new;
end;
$$;

create trigger stations_guard before insert or update on public.stations
  for each row execute function private.guard_station_write();

create trigger stations_audit after update or delete on public.stations
  for each row execute function private.audit_row_change();

create table public.station_assignments (
  member_id uuid not null references public.business_members (id) on delete cascade,
  station_id uuid not null references public.stations (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (member_id, station_id)
);

create index station_assignments_station_idx on public.station_assignments (station_id);

create or replace function private.validate_station_assignment()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.business_members m join public.stations s on s.business_id = m.business_id
     where m.id = new.member_id and s.id = new.station_id) then
    perform private.raise_error(422, 'assignment_business_mismatch', 'Member and station belong to different businesses');
  end if;
  return new;
end;
$$;

create trigger station_assignments_validate before insert or update on public.station_assignments
  for each row execute function private.validate_station_assignment();
create trigger station_assignments_audit after insert or delete on public.station_assignments
  for each row execute function private.audit_row_change();

create table public.station_photos (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations (id) on delete cascade,
  storage_path text not null unique,
  caption text check (caption is null or char_length(caption) <= 200),
  sort_order int not null default 0,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);

create index station_photos_station_idx on public.station_photos (station_id, sort_order);

-------------------------------------------------------------------------------
-- Business authorization helpers
-------------------------------------------------------------------------------

create or replace function private.business_role(p_business uuid)
returns public.business_member_role
language sql
stable
security definer
set search_path = ''
as $$
  select m.role from public.business_members m
   where m.business_id = p_business and m.user_id = (select auth.uid()) and m.status = 'active';
$$;

create or replace function private.is_business_member(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.business_role(p_business) is not null;
$$;

create or replace function private.is_business_owner(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.business_role(p_business) = 'owner';
$$;

-- Owner: every permission on every station of the business.
-- Manager/staff: only listed permissions, only on assigned stations.
create or replace function private.has_station_permission(p_station uuid, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.stations s
      join public.business_members m on m.business_id = s.business_id
     where s.id = p_station
       and m.user_id = (select auth.uid())
       and m.status = 'active'
       and (m.role = 'owner'
            or (p_permission = any (m.permissions)
                and exists (select 1 from public.station_assignments a
                             where a.member_id = m.id and a.station_id = s.id)))
  );
$$;

create or replace function private.can_view_station(p_station uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.stations s
      join public.business_members m on m.business_id = s.business_id
     where s.id = p_station
       and m.user_id = (select auth.uid())
       and m.status = 'active'
       and (m.role = 'owner'
            or exists (select 1 from public.station_assignments a where a.member_id = m.id and a.station_id = s.id))
  );
$$;

create or replace function private.require_station_permission(p_station uuid, p_permission text)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if not exists (select 1 from public.stations where id = p_station) then
    perform private.raise_error(404, 'station_not_found');
  end if;
  if not private.has_station_permission(p_station, p_permission) then
    perform private.raise_error(403, 'forbidden', format('Missing station permission %s', p_permission));
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Operating hours, booking policy, charging points
-------------------------------------------------------------------------------

create type public.current_type as enum ('ac', 'dc');
create type public.connector_type as enum (
  'ccs2', 'chademo', 'type2_ac', 'type1_ac', 'gb_t', 'bharat_ac001', 'bharat_dc001',
  'type6_lev', 'three_pin_socket', 'other'
);
-- Operational status of the hardware. BOOKED is not stored here: it is derived
-- from bookings, so a reservation never overwrites a maintenance state.
create type public.point_status as enum ('available', 'in_use', 'maintenance', 'out_of_service', 'disabled');
create type public.status_source as enum ('manual', 'telemetry');
create type public.telemetry_capability as enum ('none', 'unknown', 'ocpp_1_6', 'ocpp_2_0_1', 'other');

create table public.charging_points (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations (id) on delete restrict,
  code text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$'),
  name text check (name is null or char_length(name) <= 80),
  current_type public.current_type not null,
  max_power_kw numeric(6, 2) not null check (max_power_kw > 0 and max_power_kw <= 1000),
  vehicle_compatibility text[] not null default '{}',
  operational_status public.point_status not null default 'available',
  status_source public.status_source not null default 'manual',
  status_note text check (status_note is null or char_length(status_note) <= 500),
  status_updated_at timestamptz not null default now(),
  status_updated_by uuid references public.profiles (id),
  telemetry_capability public.telemetry_capability not null default 'unknown',
  ocpp_charge_point_id text check (ocpp_charge_point_id is null or char_length(ocpp_charge_point_id) <= 64),
  booking_enabled boolean not null default true,
  max_booking_minutes_override int check (max_booking_minutes_override is null or max_booking_minutes_override between 5 and 1440),
  restrictions_note text check (restrictions_note is null or char_length(restrictions_note) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  constraint charging_points_vehicle_compat_valid check (vehicle_compatibility <@ array[
    'two_wheeler', 'three_wheeler', 'four_wheeler', 'commercial', 'bus'])
);

create unique index charging_points_code_unique on public.charging_points (station_id, lower(code)) where archived_at is null;
create index charging_points_station_idx on public.charging_points (station_id) where archived_at is null;

create trigger charging_points_updated_at before update on public.charging_points
  for each row execute function private.set_updated_at();

-- Clients may not claim telemetry: a status set from the apps is always manual.
create or replace function private.guard_charging_point_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.is_client_write() then
    new.status_source := 'manual';
    if tg_op = 'INSERT' or new.operational_status is distinct from old.operational_status
       or new.status_note is distinct from old.status_note then
      new.status_updated_at := now();
      new.status_updated_by := (select auth.uid());
    end if;
    if tg_op = 'UPDATE' and new.station_id is distinct from old.station_id then
      perform private.raise_error(403, 'protected_field', 'A charging point cannot move between stations');
    end if;
  end if;
  return new;
end;
$$;

create trigger charging_points_guard before insert or update on public.charging_points
  for each row execute function private.guard_charging_point_write();
create trigger charging_points_audit after insert or update or delete on public.charging_points
  for each row execute function private.audit_row_change();

create table public.charging_connectors (
  id uuid primary key default gen_random_uuid(),
  charging_point_id uuid not null references public.charging_points (id) on delete cascade,
  connector_number smallint not null check (connector_number between 1 and 16),
  connector_type public.connector_type not null,
  max_power_kw numeric(6, 2) check (max_power_kw is null or (max_power_kw > 0 and max_power_kw <= 1000)),
  created_at timestamptz not null default now(),
  unique (charging_point_id, connector_number)
);

-- Weekly operating hours in station-local wall-clock minutes. Rows with a
-- charging_point_id further restrict that point (point-specific bookable
-- periods); points without rows inherit the station hours.
create table public.station_operating_hours (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations (id) on delete cascade,
  charging_point_id uuid references public.charging_points (id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 1 and 7),   -- ISO: 1 = Monday
  opens_minute smallint not null check (opens_minute between 0 and 1439),
  closes_minute smallint not null check (closes_minute between 1 and 1440),
  minutes int4range generated always as (int4range(opens_minute, closes_minute)) stored,
  created_at timestamptz not null default now(),
  check (closes_minute > opens_minute),
  constraint station_operating_hours_no_overlap exclude using gist (
    station_id with =,
    (coalesce(charging_point_id, '00000000-0000-0000-0000-000000000000'::uuid)) with =,
    day_of_week with =,
    minutes with &&
  )
);

create index station_operating_hours_station_idx on public.station_operating_hours (station_id, day_of_week);

create or replace function private.validate_operating_hours_point()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.charging_point_id is not null and not exists (
      select 1 from public.charging_points where id = new.charging_point_id and station_id = new.station_id) then
    perform private.raise_error(422, 'point_station_mismatch');
  end if;
  return new;
end;
$$;

create trigger station_operating_hours_validate before insert or update on public.station_operating_hours
  for each row execute function private.validate_operating_hours_point();

create table public.station_booking_policies (
  station_id uuid primary key references public.stations (id) on delete cascade,
  slot_duration_minutes int not null default 30 check (slot_duration_minutes between 5 and 240),
  min_booking_minutes int not null default 30 check (min_booking_minutes between 5 and 1440),
  max_booking_minutes int not null default 120 check (max_booking_minutes between 5 and 1440),
  min_advance_minutes int not null default 15 check (min_advance_minutes between 0 and 10080),
  max_advance_days int not null default 7 check (max_advance_days between 1 and 90),
  buffer_minutes int not null default 0 check (buffer_minutes between 0 and 120),
  arrival_grace_minutes int not null default 15 check (arrival_grace_minutes between 0 and 120),
  early_checkin_minutes int not null default 15 check (early_checkin_minutes between 0 and 120),
  customer_cancel_until_minutes int not null default 0 check (customer_cancel_until_minutes between 0 and 1440),
  auto_no_show_enabled boolean not null default true,
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now(),
  check (max_booking_minutes >= min_booking_minutes),
  check (min_booking_minutes % slot_duration_minutes = 0),
  check (max_booking_minutes % slot_duration_minutes = 0)
);

comment on column public.station_booking_policies.customer_cancel_until_minutes is
  'Customers may cancel until this many minutes before the start. Refund eligibility is governed separately by platform_settings.refund_policy.';

create trigger station_booking_policies_updated_at before update on public.station_booking_policies
  for each row execute function private.set_updated_at();
create trigger station_booking_policies_audit after update on public.station_booking_policies
  for each row execute function private.audit_row_change();

create or replace function private.create_default_booking_policy()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.station_booking_policies (station_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

create trigger stations_default_policy after insert on public.stations
  for each row execute function private.create_default_booking_policy();

create type public.blocked_period_kind as enum ('maintenance', 'temporary_closure', 'other');

create table public.blocked_periods (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations (id) on delete cascade,
  charging_point_id uuid references public.charging_points (id) on delete cascade,  -- null = whole station
  period tstzrange not null check (not isempty(period) and not lower_inf(period) and not upper_inf(period)),
  kind public.blocked_period_kind not null,
  reason text check (reason is null or char_length(reason) <= 500),
  maintenance_report_id uuid,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles (id)
);

create index blocked_periods_station_idx on public.blocked_periods using gist (station_id, period) where cancelled_at is null;
create trigger blocked_periods_audit after insert or update on public.blocked_periods
  for each row execute function private.audit_row_change();

-------------------------------------------------------------------------------
-- Sensitive station change requests
-------------------------------------------------------------------------------

create type public.change_request_status as enum ('pending', 'approved', 'rejected', 'cancelled');

create table public.station_change_requests (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations (id) on delete cascade,
  changes jsonb not null check (jsonb_typeof(changes) = 'object' and changes <> '{}'::jsonb),
  note text check (note is null or char_length(note) <= 1000),
  status public.change_request_status not null default 'pending',
  requested_by uuid not null references public.profiles (id),
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now()
);

create unique index station_change_requests_one_pending on public.station_change_requests (station_id) where status = 'pending';
