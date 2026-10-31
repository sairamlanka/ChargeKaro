-- LOCAL DEVELOPMENT SEED DATA. DEMO ONLY. NEVER RUN AGAINST PRODUCTION.
--
-- Every business created here has is_demo = true and a "[DEMO]" name prefix.
-- Platform configuration (settings, document types, expense categories) lives
-- in migrations, not here. Demo accounts all use the password DemoPass#2026.
--
--   admin@chargekaro.local      super_admin
--   ops@chargekaro.local        admin (+ finance.read, finance.expenses.write)
--   reviewer@chargekaro.local   compliance_reviewer
--   owner@demo-ev.local         business owner (one approved, one submitted station)
--   staff@demo-ev.local         station staff at the approved station
--   customer@demo-ev.local      customer (future Retailer App)

do $$
declare
  full_auth boolean := exists (select 1 from information_schema.columns
                                where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password');
  u record;
begin
  for u in select * from (values
    ('00000000-0000-4000-a000-000000000001'::uuid, 'admin@chargekaro.local', 'Asha Admin'),
    ('00000000-0000-4000-a000-000000000002'::uuid, 'ops@chargekaro.local', 'Omkar Ops'),
    ('00000000-0000-4000-a000-000000000003'::uuid, 'reviewer@chargekaro.local', 'Riya Reviewer'),
    ('00000000-0000-4000-a000-000000000011'::uuid, 'owner@demo-ev.local', 'Dev Owner'),
    ('00000000-0000-4000-a000-000000000012'::uuid, 'staff@demo-ev.local', 'Sanjay Staff'),
    ('00000000-0000-4000-a000-000000000021'::uuid, 'customer@demo-ev.local', 'Chitra Customer')
  ) as t(id, email, name) loop
    if full_auth then
      execute $q$
        insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                                raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                                confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('00000000-0000-0000-0000-000000000000', $1, 'authenticated', 'authenticated', $2,
                extensions.crypt('DemoPass#2026', extensions.gen_salt('bf')), now(),
                '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', $3), now(), now(),
                '', '', '', '')
        on conflict (id) do nothing $q$ using u.id, u.email, u.name;
      execute $q$
        insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
        values (gen_random_uuid(), $1, $1::text, jsonb_build_object('sub', $1::text, 'email', $2), 'email', now(), now(), now())
        on conflict do nothing $q$ using u.id, u.email;
    else
      insert into auth.users (id, email, raw_user_meta_data) values (u.id, u.email, jsonb_build_object('full_name', u.name))
      on conflict (id) do nothing;
    end if;
  end loop;
end;
$$;

insert into public.platform_staff (user_id, role) values
  ('00000000-0000-4000-a000-000000000001', 'super_admin'),
  ('00000000-0000-4000-a000-000000000002', 'admin'),
  ('00000000-0000-4000-a000-000000000003', 'compliance_reviewer')
on conflict do nothing;

insert into public.platform_staff_permission_overrides (user_id, permission, granted) values
  ('00000000-0000-4000-a000-000000000002', 'finance.read', true),
  ('00000000-0000-4000-a000-000000000002', 'finance.expenses.write', true)
on conflict do nothing;

insert into public.businesses (id, owner_id, legal_name, display_name, owner_full_name, contact_phone, contact_email,
                               business_type, registration_number, status, status_changed_at, is_demo)
values ('00000000-0000-4000-b000-000000000001', '00000000-0000-4000-a000-000000000011',
        '[DEMO] Green Volt Charging Pvt Ltd', '[DEMO] Green Volt', 'Dev Owner', '+919800000001', 'owner@demo-ev.local',
        'private_limited', 'DEMO-U00000KA2026PTC000001', 'active', now(), true)
on conflict do nothing;

insert into public.business_members (id, business_id, user_id, role) values
  ('00000000-0000-4000-b100-000000000001', '00000000-0000-4000-b000-000000000001', '00000000-0000-4000-a000-000000000011', 'owner'),
  ('00000000-0000-4000-b100-000000000002', '00000000-0000-4000-b000-000000000001', '00000000-0000-4000-a000-000000000012', 'station_staff')
on conflict do nothing;

insert into public.stations (id, business_id, name, description, address_line1, city, district, state, postal_code,
                             latitude, longitude, contact_phone, parking_spaces, amenities, accepted_payment_methods,
                             status, approved_at, approved_by)
values
  ('00000000-0000-4000-c000-000000000001', '00000000-0000-4000-b000-000000000001', '[DEMO] Green Volt Koramangala',
   'Demo station for local development.', '80 Feet Road, 4th Block', 'Bengaluru', 'Bengaluru Urban', 'Karnataka', '560034',
   12.934533, 77.626579, '+919800000002', 4, array['restroom', 'cafe', 'cctv'], array['upi', 'debit_card', 'cash'],
   'active', now(), '00000000-0000-4000-a000-000000000001'),
  ('00000000-0000-4000-c000-000000000002', '00000000-0000-4000-b000-000000000001', '[DEMO] Green Volt Indiranagar',
   'Demo station awaiting review.', '100 Feet Road', 'Bengaluru', 'Bengaluru Urban', 'Karnataka', '560038',
   12.971891, 77.641151, '+919800000003', 2, array['wifi'], array['upi'],
   'draft', null, null)
on conflict do nothing;

insert into public.station_assignments (member_id, station_id)
values ('00000000-0000-4000-b100-000000000002', '00000000-0000-4000-c000-000000000001')
on conflict do nothing;

-- Open 24 hours every day.
insert into public.station_operating_hours (station_id, day_of_week, opens_minute, closes_minute)
select s, d, 0, 1440
  from unnest(array['00000000-0000-4000-c000-000000000001'::uuid, '00000000-0000-4000-c000-000000000002'::uuid]) s,
       generate_series(1, 7) d
on conflict do nothing;

insert into public.charging_points (id, station_id, code, name, current_type, max_power_kw, vehicle_compatibility,
                                    telemetry_capability)
values
  ('00000000-0000-4000-d000-000000000001', '00000000-0000-4000-c000-000000000001', 'KRM-DC1', 'DC fast 1', 'dc', 60, array['four_wheeler'], 'unknown'),
  ('00000000-0000-4000-d000-000000000002', '00000000-0000-4000-c000-000000000001', 'KRM-AC1', 'AC 1', 'ac', 7.4, array['four_wheeler', 'two_wheeler'], 'none'),
  ('00000000-0000-4000-d000-000000000003', '00000000-0000-4000-c000-000000000002', 'IND-DC1', 'DC fast 1', 'dc', 30, array['four_wheeler'], 'unknown')
on conflict do nothing;

insert into public.charging_connectors (charging_point_id, connector_number, connector_type, max_power_kw) values
  ('00000000-0000-4000-d000-000000000001', 1, 'ccs2', 60),
  ('00000000-0000-4000-d000-000000000002', 1, 'type2_ac', 7.4),
  ('00000000-0000-4000-d000-000000000003', 1, 'ccs2', 30)
on conflict do nothing;

update public.station_applications
   set status = 'approved', revision = 1, submitted_at = now() - interval '2 days',
       submitted_by = '00000000-0000-4000-a000-000000000011', decided_at = now() - interval '1 day',
       decided_by = '00000000-0000-4000-a000-000000000001'
 where station_id = '00000000-0000-4000-c000-000000000001' and status = 'draft';

update public.station_applications
   set status = 'submitted', revision = 1, submitted_at = now() - interval '3 hours',
       submitted_by = '00000000-0000-4000-a000-000000000011'
 where station_id = '00000000-0000-4000-c000-000000000002' and status = 'draft';

insert into public.application_events (application_id, from_status, to_status, actor_id, note)
select a.id, 'draft', 'submitted', '00000000-0000-4000-a000-000000000011', '[DEMO] seeded'
  from public.station_applications a where a.business_id = '00000000-0000-4000-b000-000000000001';
insert into public.application_events (application_id, from_status, to_status, actor_id, note)
select a.id, 'submitted', 'approved', '00000000-0000-4000-a000-000000000001', '[DEMO] seeded'
  from public.station_applications a where a.station_id = '00000000-0000-4000-c000-000000000001';

-- Demo document records (no file objects exist for these paths locally).
insert into public.station_documents (business_id, station_id, document_type_id, storage_path, file_name, mime_type,
                                      size_bytes, status, expires_on, uploaded_by)
select '00000000-0000-4000-b000-000000000001', case when t.scope = 'station' then s.id end, t.id,
       '00000000-0000-4000-b000-000000000001/' || coalesce(s.id::text, 'business') || '/demo-' || t.code || '.pdf',
       'demo-' || t.code || '.pdf', 'application/pdf', 120000,
       case when s.id = '00000000-0000-4000-c000-000000000002' then 'pending_review'::public.document_status else 'approved' end,
       case when t.requires_expiry_date then current_date + 365 end,
       '00000000-0000-4000-a000-000000000011'
  from public.document_types t
  left join public.stations s on t.scope = 'station' and s.business_id = '00000000-0000-4000-b000-000000000001'
 where t.is_required
on conflict do nothing;

-- Two upcoming demo bookings with no booking fee charged (not_required), so
-- no payment or ledger rows are fabricated.
insert into public.bookings (customer_id, station_id, charging_point_id, period, occupancy, status, payment_status,
                             booking_fee_paise, confirmed_at, customer_display_name, vehicle_label)
select '00000000-0000-4000-a000-000000000021', '00000000-0000-4000-c000-000000000001', p.point,
       tstzrange(t.start_at, t.start_at + interval '60 minutes'), tstzrange(t.start_at, t.start_at + interval '60 minutes'),
       'confirmed', 'not_required', 0, now(), 'Chitra C.', '[DEMO] Tata Nexon EV'
  from (values ('00000000-0000-4000-d000-000000000001'::uuid, 1), ('00000000-0000-4000-d000-000000000002'::uuid, 2)) p(point, day_offset)
  cross join lateral (select ((current_date + p.day_offset)::timestamp + interval '10 hours') at time zone 'Asia/Kolkata' as start_at) t
 where not exists (select 1 from public.bookings where customer_id = '00000000-0000-4000-a000-000000000021');

-- A three-point station in Hyderabad for trying station-level booking in the
-- customer app: two CCS2 fast chargers and one Type 2 AC point. Search for
-- "Banjara Hills" (the emulator's default location is not in India).
insert into public.stations (id, business_id, name, description, address_line1, landmark, city, district, state, postal_code,
                             latitude, longitude, contact_phone, parking_spaces, amenities, accepted_payment_methods,
                             status, approved_at, approved_by)
values
  ('00000000-0000-4000-c000-000000000003', '00000000-0000-4000-b000-000000000001', '[DEMO] Green Volt Banjara Hills',
   'Demo station with three points for local development.', 'Road No. 12, Banjara Hills', 'Opp. KBR Park gate 3',
   'Hyderabad', 'Hyderabad', 'Telangana', '500034', 17.412600, 78.438200, '+919800000004', 3,
   array['restroom', 'cafe', 'cctv'], array['upi', 'debit_card', 'cash'], 'active', now(), '00000000-0000-4000-a000-000000000001')
on conflict do nothing;

insert into public.station_operating_hours (station_id, day_of_week, opens_minute, closes_minute)
select '00000000-0000-4000-c000-000000000003'::uuid, d, 0, 1440 from generate_series(1, 7) d
on conflict do nothing;

insert into public.charging_points (id, station_id, code, name, current_type, max_power_kw, vehicle_compatibility,
                                    telemetry_capability)
values
  ('00000000-0000-4000-d000-000000000011', '00000000-0000-4000-c000-000000000003', 'BH-DC1', 'DC fast 1', 'dc', 60, array['four_wheeler'], 'none'),
  ('00000000-0000-4000-d000-000000000012', '00000000-0000-4000-c000-000000000003', 'BH-DC2', 'DC fast 2', 'dc', 60, array['four_wheeler'], 'none'),
  ('00000000-0000-4000-d000-000000000013', '00000000-0000-4000-c000-000000000003', 'BH-AC1', 'AC 1', 'ac', 7.4, array['four_wheeler', 'two_wheeler'], 'none')
on conflict do nothing;

insert into public.charging_connectors (charging_point_id, connector_number, connector_type, max_power_kw) values
  ('00000000-0000-4000-d000-000000000011', 1, 'ccs2', 60),
  ('00000000-0000-4000-d000-000000000012', 1, 'ccs2', 60),
  ('00000000-0000-4000-d000-000000000013', 1, 'type2_ac', 7.4)
on conflict do nothing;

update public.station_applications
   set status = 'approved', revision = 1, submitted_at = now() - interval '2 days',
       submitted_by = '00000000-0000-4000-a000-000000000011', decided_at = now() - interval '1 day',
       decided_by = '00000000-0000-4000-a000-000000000001'
 where station_id = '00000000-0000-4000-c000-000000000003' and status = 'draft';

-- Ten route-test stations for Along My Route (Customer App), all on highways
-- so each appears only for the trips it lies on (default 5 km from the road):
--   Hyderabad -> Vijayawada (NH65):  1 Choutuppal, 2 Suryapet
--   Bengaluru -> Hyderabad (NH44):   5 Kurnool, 7 Jadcherla
--   Tirupati -> Bengaluru:           3 Chittoor, 4 Palamaner, 6 Kolar
--   Pune -> Mumbai (Expressway):     8 Lonavala, 9 Khalapur, 10 Panvel
-- Open 24 hours, so they are listed whatever time you test.
insert into public.stations (id, business_id, name, description, address_line1, city, district, state, postal_code,
                             latitude, longitude, contact_phone, parking_spaces, amenities, accepted_payment_methods,
                             status, approved_at, approved_by)
select ('00000000-0000-4000-c000-0000000001' || lpad(n::text, 2, '0'))::uuid, '00000000-0000-4000-b000-000000000001',
       '[DEMO] Station ' || n || ' ' || city, 'Route test station ' || n || ' (' || route || ').', road, city, district, state, pin,
       lat, lng, '+9198000001' || lpad(n::text, 2, '0'), 4, array['restroom', 'cafe'], array['upi', 'cash'],
       'active', now(), '00000000-0000-4000-a000-000000000001'
  from (values
    (1,  'Hyderabad -> Vijayawada', 'NH65, Choutuppal',         'Choutuppal', 'Yadadri Bhuvanagiri', 'Telangana',      '508252', 17.251600, 78.897700),
    (2,  'Hyderabad -> Vijayawada', 'NH65, Suryapet bypass',    'Suryapet',   'Suryapet',            'Telangana',      '508213', 17.144000, 79.625000),
    (3,  'Tirupati -> Bengaluru',   'NH69, Chittoor',           'Chittoor',   'Chittoor',            'Andhra Pradesh', '517001', 13.217600, 79.100300),
    (4,  'Tirupati -> Bengaluru',   'NH69, Palamaner',          'Palamaner',  'Chittoor',            'Andhra Pradesh', '517408', 13.200000, 78.750000),
    (5,  'Bengaluru -> Hyderabad',  'NH44, Kurnool bypass',     'Kurnool',    'Kurnool',             'Andhra Pradesh', '518002', 15.798000, 78.042000),
    (6,  'Tirupati -> Bengaluru',   'NH75, Kolar',              'Kolar',      'Kolar',               'Karnataka',      '563101', 13.136000, 78.129000),
    (7,  'Bengaluru -> Hyderabad',  'NH44, Jadcherla',          'Jadcherla',  'Mahabubnagar',        'Telangana',      '509301', 16.763000, 78.138000),
    (8,  'Pune -> Mumbai',          'Mumbai-Pune Expressway, Lonavala', 'Lonavala', 'Pune',          'Maharashtra',    '410401', 18.750000, 73.407000),
    (9,  'Pune -> Mumbai',          'Mumbai-Pune Expressway, Khalapur', 'Khalapur', 'Raigad',        'Maharashtra',    '410202', 18.824000, 73.270000),
    (10, 'Pune -> Mumbai',          'Mumbai-Pune Expressway, Panvel',   'Panvel',   'Raigad',        'Maharashtra',    '410206', 18.989400, 73.117500)
  ) as t(n, route, road, city, district, state, pin, lat, lng)
on conflict do nothing;

insert into public.station_operating_hours (station_id, day_of_week, opens_minute, closes_minute)
select ('00000000-0000-4000-c000-0000000001' || lpad(n::text, 2, '0'))::uuid, d, 0, 1440
  from generate_series(1, 10) n, generate_series(1, 7) d
on conflict do nothing;

insert into public.charging_points (id, station_id, code, name, current_type, max_power_kw, vehicle_compatibility,
                                    telemetry_capability)
select ('00000000-0000-4000-d000-00000001' || lpad(n::text, 2, '0') || p.suffix)::uuid,
       ('00000000-0000-4000-c000-0000000001' || lpad(n::text, 2, '0'))::uuid,
       'S' || n || '-' || p.code, p.name, p.kind::public.current_type, p.kw, p.vehicles, 'none'
  from generate_series(1, 10) n,
       (values ('01', 'DC1', 'DC fast 1', 'dc', 60::numeric, array['four_wheeler']),
               ('02', 'AC1', 'AC 1', 'ac', 7.4::numeric, array['four_wheeler', 'two_wheeler'])) as p(suffix, code, name, kind, kw, vehicles)
on conflict do nothing;

insert into public.charging_connectors (charging_point_id, connector_number, connector_type, max_power_kw)
select ('00000000-0000-4000-d000-00000001' || lpad(n::text, 2, '0') || c.suffix)::uuid, 1, c.kind::public.connector_type, c.kw
  from generate_series(1, 10) n,
       (values ('01', 'ccs2', 60::numeric), ('02', 'type2_ac', 7.4::numeric)) as c(suffix, kind, kw)
on conflict do nothing;

update public.station_applications
   set status = 'approved', revision = 1, submitted_at = now() - interval '2 days',
       submitted_by = '00000000-0000-4000-a000-000000000011', decided_at = now() - interval '1 day',
       decided_by = '00000000-0000-4000-a000-000000000001'
 where station_id::text like '00000000-0000-4000-c000-0000000001%' and status = 'draft';

-- Five more Hyderabad city stations so the Nearby list has something to show
-- around the city. Open 24 hours, one DC fast and one AC point each.
insert into public.stations (id, business_id, name, description, address_line1, city, district, state, postal_code,
                             latitude, longitude, contact_phone, parking_spaces, amenities, accepted_payment_methods,
                             status, approved_at, approved_by)
select ('00000000-0000-4000-c000-0000000002' || lpad(n::text, 2, '0'))::uuid, '00000000-0000-4000-b000-000000000001',
       '[DEMO] Green Volt ' || area, 'Hyderabad city test station (' || area || ').', road, 'Hyderabad', district, 'Telangana', pin,
       lat, lng, '+9198000002' || lpad(n::text, 2, '0'), 4, array['restroom', 'cafe', 'cctv'], array['upi', 'debit_card', 'cash'],
       'active', now(), '00000000-0000-4000-a000-000000000001'
  from (values
    (1, 'HITEC City',   'Cyber Towers Road, Madhapur',      'Rangareddy',          '500081', 17.447400, 78.376200),
    (2, 'Gachibowli',   'Old Mumbai Highway, Gachibowli',   'Rangareddy',          '500032', 17.440100, 78.348900),
    (3, 'Kukatpally',   'JNTU Road, KPHB Colony',           'Medchal-Malkajgiri',  '500072', 17.484900, 78.413800),
    (4, 'Secunderabad', 'Sarojini Devi Road, Secunderabad', 'Hyderabad',           '500003', 17.439900, 78.498300),
    (5, 'LB Nagar',     'Vijayawada Highway, LB Nagar',     'Rangareddy',          '500074', 17.345700, 78.552200)
  ) as t(n, area, road, district, pin, lat, lng)
on conflict do nothing;

insert into public.station_operating_hours (station_id, day_of_week, opens_minute, closes_minute)
select ('00000000-0000-4000-c000-0000000002' || lpad(n::text, 2, '0'))::uuid, d, 0, 1440
  from generate_series(1, 5) n, generate_series(1, 7) d
on conflict do nothing;

insert into public.charging_points (id, station_id, code, name, current_type, max_power_kw, vehicle_compatibility,
                                    telemetry_capability)
select ('00000000-0000-4000-d000-00000002' || lpad(n::text, 2, '0') || p.suffix)::uuid,
       ('00000000-0000-4000-c000-0000000002' || lpad(n::text, 2, '0'))::uuid,
       'H' || n || '-' || p.code, p.name, p.kind::public.current_type, p.kw, p.vehicles, 'none'
  from generate_series(1, 5) n,
       (values ('01', 'DC1', 'DC fast 1', 'dc', 60::numeric, array['four_wheeler']),
               ('02', 'AC1', 'AC 1', 'ac', 7.4::numeric, array['four_wheeler', 'two_wheeler'])) as p(suffix, code, name, kind, kw, vehicles)
on conflict do nothing;

insert into public.charging_connectors (charging_point_id, connector_number, connector_type, max_power_kw)
select ('00000000-0000-4000-d000-00000002' || lpad(n::text, 2, '0') || c.suffix)::uuid, 1, c.kind::public.connector_type, c.kw
  from generate_series(1, 5) n,
       (values ('01', 'ccs2', 60::numeric), ('02', 'type2_ac', 7.4::numeric)) as c(suffix, kind, kw)
on conflict do nothing;

update public.station_applications
   set status = 'approved', revision = 1, submitted_at = now() - interval '2 days',
       submitted_by = '00000000-0000-4000-a000-000000000011', decided_at = now() - interval '1 day',
       decided_by = '00000000-0000-4000-a000-000000000001'
 where station_id::text like '00000000-0000-4000-c000-0000000002%' and status = 'draft';

-- Every demo station is open 24 hours so testing works at any time of day.
-- Also corrects hosted projects seeded before this, when some stations were
-- 06:00 to 23:00 (the inserts above skip rows that already exist).
delete from public.station_operating_hours h
 using public.stations s
 where s.id = h.station_id and s.business_id = '00000000-0000-4000-b000-000000000001'
   and h.charging_point_id is null and (h.opens_minute, h.closes_minute) <> (0, 1440);

insert into public.station_operating_hours (station_id, day_of_week, opens_minute, closes_minute)
select s.id, d, 0, 1440
  from public.stations s, generate_series(1, 7) d
 where s.business_id = '00000000-0000-4000-b000-000000000001'
on conflict do nothing;
