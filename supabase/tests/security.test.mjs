// Authorization and Row Level Security: positive and negative cases per role.
import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import {
  as, rpc, sql, one, rejectsWith, closePool, createUser, createStaff, approvedStation, insertBooking, ist, setFee,
} from './lib/db.mjs';

after(closePool);

let a; // business A (owner, admin who approved it)
let b; // business B
let staffA; // station staff at A
let customer;
let bookingA;

before(async () => {
  await setFee(0);
  a = await approvedStation();
  b = await approvedStation();
  staffA = await createUser('staff');
  await rpc(a.owner.id, 'add_business_member', [a.businessId, staffA.email, 'station_staff', null, [a.stationId]]);
  customer = await createUser('customer');
  bookingA = await insertBooking({ customer, stationId: a.stationId, pointId: a.pointIds[0], start: ist(1, 10) });
});

const count = async (who, table, where = 'true', params = []) =>
  (await as(who, (q) => q(`select count(*)::int as n from public.${table} where ${where}`, params)))[0].n;

describe('anonymous access', () => {
  for (const table of ['profiles', 'businesses', 'stations', 'bookings', 'platform_settings', 'audit_logs', 'ledger_entries']) {
    test(`anon cannot read ${table}`, async () => {
      await rejectsWith(as('anon', (q) => q(`select 1 from public.${table} limit 1`)), { sqlstate: '42501' });
    });
  }
  test('anon cannot execute RPCs', async () => {
    await rejectsWith(as('anon', (q) => q(`select public.my_platform_access()`)), { sqlstate: '42501' });
  });
});

describe('cross-business isolation', () => {
  test('owner A sees only business A records', async () => {
    assert.equal(await count(a.owner.id, 'businesses', 'id = $1', [b.businessId]), 0);
    assert.equal(await count(a.owner.id, 'businesses', 'id = $1', [a.businessId]), 1);
    assert.equal(await count(a.owner.id, 'station_documents', 'business_id = $1', [b.businessId]), 0);
    assert.ok(await count(a.owner.id, 'station_documents', 'business_id = $1', [a.businessId]) > 0);
    assert.equal(await count(a.owner.id, 'station_applications', 'business_id = $1', [b.businessId]), 0);
    assert.equal(await count(a.owner.id, 'business_members', 'business_id = $1', [b.businessId]), 0);
    assert.equal(await count(b.owner.id, 'bookings', 'id = $1', [bookingA.id]), 0);
    assert.equal(await count(a.owner.id, 'bookings', 'id = $1', [bookingA.id]), 1);
  });

  test('owner B cannot modify business A, its stations or points', async () => {
    const r1 = await as(b.owner.id, (q) => q(`update public.businesses set display_name = 'Hacked' where id = $1 returning id`, [a.businessId]));
    assert.equal(r1.length, 0);
    const r2 = await as(b.owner.id, (q) => q(`update public.stations set description = 'Hacked' where id = $1 returning id`, [a.stationId]));
    assert.equal(r2.length, 0);
    const r3 = await as(b.owner.id, (q) => q(`update public.charging_points set name = 'Hacked' where id = $1 returning id`, [a.pointIds[0]]));
    assert.equal(r3.length, 0);
    await rejectsWith(as(b.owner.id, (q) => q(
      `insert into public.charging_points (station_id, code, current_type, max_power_kw) values ($1, 'EVIL', 'ac', 3)`, [a.stationId])),
      { sqlstate: '42501' });
    await rejectsWith(as(b.owner.id, (q) => q(
      `insert into public.stations (business_id, name, address_line1, city, district, state, postal_code, latitude, longitude, contact_phone)
       values ($1, 'Evil', '1 Road', 'Pune', 'Pune', 'MH', '411001', 18.5, 73.8, '+919800000009')`, [a.businessId])),
      { sqlstate: '42501' });
    await rejectsWith(rpc(b.owner.id, 'set_charging_point_status', [a.pointIds[0], 'disabled', null]), { status: 403 });
    await rejectsWith(rpc(b.owner.id, 'create_blocked_period', [a.stationId, null, ist(3, 9).toISOString(), ist(3, 10).toISOString(), 'other', 'x', true]), { status: 403 });
    await rejectsWith(rpc(b.owner.id, 'add_business_member', [a.businessId, b.owner.email, 'station_manager', null, []]), { status: 403 });
    await rejectsWith(rpc(b.owner.id, 'get_business_report', [a.businessId, '2026-01-01', '2026-01-31', null]), { status: 403 });
  });

  test('owner B cannot upload documents into business A', async () => {
    const type = await one(`select id from public.document_types where code = 'owner_identity_proof'`);
    await rejectsWith(as(b.owner.id, (q) => q(
      `insert into public.station_documents (business_id, document_type_id, storage_path, file_name, mime_type, size_bytes)
       values ($1, $2, $3, 'x.pdf', 'application/pdf', 100)`, [a.businessId, type.id, `${a.businessId}/business/${randomUUID()}.pdf`])),
      { sqlstate: '42501' });
  });

  test('a customer sees only their own bookings and no QR tokens of others', async () => {
    const other = await createUser('customer');
    assert.equal(await count(other.id, 'bookings'), 0);
    assert.equal(await count(customer.id, 'bookings', 'id = $1', [bookingA.id]), 1);
    await rejectsWith(as(customer.id, (q) => q(`select qr_token from public.bookings`)), { sqlstate: '42501' });
    const qr = await rpc(customer.id, 'get_my_booking_qr', [bookingA.id]);
    assert.equal(qr.qr_payload, `CKB1:${bookingA.qr_token}`);
    await rejectsWith(rpc(other.id, 'get_my_booking_qr', [bookingA.id]), { status: 404 });
    await rejectsWith(rpc(a.owner.id, 'get_my_booking_qr', [bookingA.id]), { status: 404 });
  });

  test('station staff cannot read customer profiles', async () => {
    assert.equal(await count(staffA.id, 'profiles', 'id = $1', [customer.id]), 0);
    assert.equal(await count(a.owner.id, 'profiles', 'id = $1', [customer.id]), 0);
  });
});

describe('station staff permissions', () => {
  test('staff can view bookings of the assigned station but not manage the station', async () => {
    assert.equal(await count(staffA.id, 'bookings', 'id = $1', [bookingA.id]), 1);
    const r = await as(staffA.id, (q) => q(`update public.stations set description = 'x' where id = $1 returning id`, [a.stationId]));
    assert.equal(r.length, 0);
    await rejectsWith(rpc(staffA.id, 'close_station_temporarily', [a.stationId, ist(2, 0).toISOString(), 'x', true]), { status: 403 });
    await rejectsWith(rpc(staffA.id, 'cancel_booking', [bookingA.id, 'no reason']), { status: 404 });
    await rejectsWith(rpc(staffA.id, 'submit_station_application', [a.applicationId]), { status: 403 });
    assert.equal(await count(staffA.id, 'station_documents'), 0, 'documents.manage is not a staff permission');
  });

  test('staff may set operational status (manual) and report maintenance', async () => {
    const res = await rpc(staffA.id, 'set_charging_point_status', [a.pointIds[0], 'in_use', 'Walk-in customer']);
    assert.equal(res.status_source, 'manual');
    await rejectsWith(rpc(staffA.id, 'set_charging_point_status', [a.pointIds[0], 'disabled', null]), { status: 403 });
    const reportId = await rpc(staffA.id, 'report_maintenance_issue', [a.stationId, a.pointIds[0], 'Cable damaged', 'Outer sheath cut', 'high', true]);
    const point = await one(`select operational_status from public.charging_points where id = $1`, [a.pointIds[0]]);
    assert.equal(point.operational_status, 'maintenance');
    await rejectsWith(rpc(staffA.id, 'update_maintenance_report', [reportId, 'resolved', 'Replaced', true]), { status: 403 });
    await rpc(a.owner.id, 'update_maintenance_report', [reportId, 'resolved', 'Cable replaced', true]);
    assert.equal((await one(`select operational_status from public.charging_points where id = $1`, [a.pointIds[0]])).operational_status, 'available');
  });

  test('clients cannot claim telemetry as the status source', async () => {
    await as(a.owner.id, (q) => q(`update public.charging_points set status_source = 'telemetry', operational_status = 'available' where id = $1`, [a.pointIds[0]]));
    assert.equal((await one(`select status_source from public.charging_points where id = $1`, [a.pointIds[0]])).status_source, 'manual');
  });

  test('revoked members lose access immediately', async () => {
    const temp = await createUser('staff');
    const memberId = await rpc(a.owner.id, 'add_business_member', [a.businessId, temp.email, 'station_manager', null, [a.stationId]]);
    assert.equal(await count(temp.id, 'bookings', 'id = $1', [bookingA.id]), 1);
    await rpc(a.owner.id, 'revoke_business_member', [memberId]);
    assert.equal(await count(temp.id, 'bookings', 'id = $1', [bookingA.id]), 0);
    assert.deepEqual(await rpc(temp.id, 'my_business_access'), []);
  });

  test('station staff cannot be granted account-management permissions', async () => {
    await rejectsWith(rpc(a.owner.id, 'add_business_member', [a.businessId, (await createUser('x')).email, 'station_staff', ['documents.manage'], []]),
      { sqlstate: '23514' });
    await rejectsWith(rpc(a.owner.id, 'add_business_member', [a.businessId, (await createUser('x')).email, 'owner', null, []]),
      { status: 422, code: 'cannot_add_owner' });
  });
});

describe('role escalation', () => {
  test('users cannot grant themselves platform roles or permissions', async () => {
    const u = await createUser('mallory');
    await rejectsWith(as(u.id, (q) => q(`insert into public.platform_staff (user_id, role) values ($1, 'super_admin')`, [u.id])), { sqlstate: '42501' });
    await rejectsWith(rpc(u.id, 'grant_platform_role', [u.id, 'super_admin']), { status: 403 });
    await rejectsWith(rpc(u.id, 'set_platform_permission_override', [u.id, 'finance.read', true]), { status: 403 });
    await rejectsWith(rpc(u.id, 'bootstrap_super_admin', [u.email]), { sqlstate: '42501' });
    const access = await rpc(u.id, 'my_platform_access');
    assert.equal(access.is_staff, false);
  });

  test('user metadata cannot carry a role', async () => {
    const id = randomUUID();
    await sql(`insert into auth.users (id, email, raw_user_meta_data) values ($1, $2, '{"role":"super_admin","full_name":"Eve"}')`, [id, `eve-${id}@x.io`]);
    const access = await rpc(id, 'my_platform_access');
    assert.equal(access.is_staff, false);
  });

  test('admins cannot change their own role, and only super admins manage super admins', async () => {
    const admin = await createStaff('admin', { 'admins.manage': true });
    const su = await createStaff('super_admin');
    await rejectsWith(rpc(admin.id, 'grant_platform_role', [admin.id, 'super_admin']), { status: 403, code: 'cannot_change_own_role' });
    await rejectsWith(rpc(admin.id, 'revoke_platform_role', [su.id, 'Taking over']), { status: 403 });
    const u = await createUser('newhire');
    await rpc(admin.id, 'grant_platform_role', [u.id, 'compliance_reviewer']);
    await rejectsWith(rpc(admin.id, 'grant_platform_role', [u.id, 'super_admin']), { status: 403 });
    const audit = await one(`select actor_id from public.audit_logs where action = 'platform_staff.insert' and entity_id = $1`, [u.id]);
    assert.equal(audit.actor_id, admin.id);
  });

  test('bootstrap_super_admin works once, then refuses', async () => {
    const exists = await one(`select count(*)::int n from public.platform_staff where role = 'super_admin' and is_active`);
    assert.ok(exists.n > 0);
    const u = await createUser('late');
    await rejectsWith(rpc('service', 'bootstrap_super_admin', [u.email]), { status: 409, code: 'super_admin_exists' });
  });

  test('owners cannot edit their profile email/phone directly', async () => {
    await rejectsWith(as(customer.id, (q) => q(`update public.profiles set email = 'x@y.z' where id = $1`, [customer.id])), { sqlstate: '42501' });
    await as(customer.id, (q) => q(`update public.profiles set full_name = 'Chitra K' where id = $1`, [customer.id]));
  });
});

describe('platform configuration', () => {
  test('only settings.manage may change the booking fee; changes are validated and audited', async () => {
    const admin = await createStaff('admin');
    await rejectsWith(rpc(a.owner.id, 'update_platform_setting', ['booking_fee_paise', 0, 'free']), { status: 403 });
    await rejectsWith(rpc(admin.id, 'update_platform_setting', ['booking_fee_paise', 0, 'free']), { status: 403 });
    await rejectsWith(as(admin.id, (q) => q(`update public.platform_settings set value = '0' where key = 'booking_fee_paise'`)), { sqlstate: '42501' });
    const su = await createStaff('super_admin');
    await rejectsWith(rpc(su.id, 'update_platform_setting', ['booking_fee_paise', 12.5, 'typo']), { status: 422 });
    await rejectsWith(rpc(su.id, 'update_platform_setting', ['booking_fee_paise', -1, 'typo']), { status: 422 });
    await rejectsWith(rpc(su.id, 'update_platform_setting', ['booking_fee_paise', 1500, '']), { status: 422, code: 'reason_required' });
    await rpc(su.id, 'update_platform_setting', ['booking_fee_paise', 1500, 'Pricing test']);
    const audit = await one(`select before_data->>'value' b, after_data->>'value' a, actor_id from public.audit_logs
                              where action = 'platform_settings.update' and entity_id = 'booking_fee_paise' order by id desc limit 1`);
    assert.equal(audit.a, '1500');
    assert.equal(audit.actor_id, su.id);
    await setFee(0);
  });

  test('document requirements are configurable only by document_types.manage', async () => {
    const reviewer = await createStaff('compliance_reviewer');
    await rejectsWith(as(reviewer.id, (q) => q(
      `insert into public.document_types (code, name, scope) values ('evil_doc', 'Evil', 'station')`)), { sqlstate: '42501' });
    const su = await createStaff('super_admin');
    const code = `fire_noc_${Math.floor(Math.random() * 1e6)}`;
    await as(su.id, (q) => q(`insert into public.document_types (code, name, scope, is_required, is_active) values ($1, 'Fire NOC', 'station', false, false)`, [code]));
  });

  test('audit logs are readable only with audit.read and cannot be written by clients', async () => {
    const admin = await createStaff('admin');
    assert.equal(await count(admin.id, 'audit_logs'), 0);
    const su = await createStaff('super_admin');
    assert.ok(await count(su.id, 'audit_logs') > 0);
    await rejectsWith(as(su.id, (q) => q(`insert into public.audit_logs (actor_kind, action, entity_type) values ('user', 'fake.entry', 'x')`)), { sqlstate: '42501' });
    await rejectsWith(as(su.id, (q) => q(`delete from public.audit_logs`)), { sqlstate: '42501' });
  });
});

describe('storage policies', () => {
  const put = (who, bucket, path) => as(who, (q) => q(`insert into storage.objects (bucket_id, name) values ($1, $2)`, [bucket, path]));
  const read = (who, bucket, path) => as(who, async (q) => (await q(`select count(*)::int n from storage.objects where bucket_id = $1 and name = $2`, [bucket, path]))[0].n);

  test('private documents: own business only, reviewers can read', async () => {
    const path = `${a.businessId}/${a.stationId}/${randomUUID()}.pdf`;
    await put(a.owner.id, 'station-documents', path);
    await rejectsWith(put(b.owner.id, 'station-documents', `${a.businessId}/${a.stationId}/${randomUUID()}.pdf`), { sqlstate: '42501' });
    await rejectsWith(put(a.owner.id, 'station-documents', `${a.businessId}/${b.stationId}/${randomUUID()}.pdf`), { sqlstate: '42501' });
    assert.equal(await read(a.owner.id, 'station-documents', path), 1);
    assert.equal(await read(b.owner.id, 'station-documents', path), 0);
    assert.equal(await read(staffA.id, 'station-documents', path), 0);
    assert.equal(await read(customer.id, 'station-documents', path), 0);
    const reviewer = await createStaff('compliance_reviewer');
    assert.equal(await read(reviewer.id, 'station-documents', path), 1);
    await rejectsWith(as(a.owner.id, (q) => q(`delete from storage.objects where name = $1 returning id`, [path])).then((r) => { if (r.length === 0) throw Object.assign(new Error('blocked'), { code: '42501' }); }),
      { sqlstate: '42501' });
  });

  test('expense receipts are finance-only', async () => {
    const fin = await createStaff('admin', { 'finance.expenses.write': true, 'finance.read': true });
    const path = `${randomUUID()}/${randomUUID()}.pdf`;
    await put(fin.id, 'expense-receipts', path);
    await rejectsWith(put(a.owner.id, 'expense-receipts', `${randomUUID()}/x.pdf`), { sqlstate: '42501' });
    assert.equal(await read(a.owner.id, 'expense-receipts', path), 0);
    assert.equal(await read((await createStaff('admin')).id, 'expense-receipts', path), 0);
  });
});

describe('notifications', () => {
  test('users read only their own notifications and can only mark them read', async () => {
    const mine = await count(a.owner.id, 'notifications');
    assert.ok(mine > 0);
    assert.equal(await count(b.owner.id, 'notifications', 'recipient_id = $1', [a.owner.id]), 0);
    await rejectsWith(as(a.owner.id, (q) => q(`update public.notifications set title = 'x' where recipient_id = $1`, [a.owner.id])), { sqlstate: '42501' });
    const n = await rpc(a.owner.id, 'mark_notifications_read', [null]);
    assert.equal(n, mine);
  });

  test('device tokens move to the latest signed-in user', async () => {
    const token = `tok_${randomUUID()}_${'x'.repeat(20)}`;
    await rpc(a.owner.id, 'register_device_token', [token, 'android', 'business']);
    await rpc(staffA.id, 'register_device_token', [token, 'android', 'business']);
    assert.equal(await count(a.owner.id, 'device_tokens', 'token = $1', [token]), 0);
    assert.equal(await count(staffA.id, 'device_tokens', 'token = $1', [token]), 1);
  });

  test('push queue claims each notification once', async () => {
    const [x, y] = await Promise.all([
      as('service', (q) => q(`select notification_id from public.claim_push_notifications(1000)`)),
      as('service', (q) => q(`select notification_id from public.claim_push_notifications(1000)`)),
    ]);
    const ids = new Set(x.map((r) => r.notification_id));
    for (const r of y) assert.ok(!ids.has(r.notification_id));
  });
});
