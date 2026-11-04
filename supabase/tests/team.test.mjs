// Team management by role: owner adds/removes directly; a station manager
// raises add/remove requests for staff at their own stations; the owner
// approves or rejects. See 20261103000200_team_requests.sql.
import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { as, rpc, sql, one, rejectsWith, closePool, createUser, approvedStation, createStation } from './lib/db.mjs';

after(closePool);

let a; // business with two stations
let stationB; // second station of business a
let manager; // manages a.stationId only
let staff; // staff at a.stationId
let staffOther; // staff at stationB only
let other; // another business

before(async () => {
  a = await approvedStation();
  stationB = await createStation(a.owner, a.businessId);
  other = await approvedStation();
  manager = await createUser('manager');
  staff = await createUser('staff');
  staffOther = await createUser('staffother');
  await rpc(a.owner.id, 'add_business_member', [a.businessId, manager.email, 'station_manager', null, [a.stationId]]);
  await rpc(a.owner.id, 'add_business_member', [a.businessId, staff.email, 'station_staff', null, [a.stationId]]);
  await rpc(a.owner.id, 'add_business_member', [a.businessId, staffOther.email, 'station_staff', null, [stationB]]);
});

const memberId = async (user) =>
  (await one(`select id from public.business_members where business_id = $1 and user_id = $2`, [a.businessId, user.id]))?.id;

describe('team list by role', () => {
  test('owner sees everyone', async () => {
    const list = await rpc(a.owner.id, 'list_team_members', [a.businessId]);
    assert.equal(list.length, 4);
  });
  test('manager sees self and staff at their stations only', async () => {
    const list = await rpc(manager.id, 'list_team_members', [a.businessId]);
    assert.deepEqual(list.map((m) => m.user_id).sort(), [manager.id, staff.id].sort());
  });
  test('staff sees only themselves', async () => {
    const list = await rpc(staff.id, 'list_team_members', [a.businessId]);
    assert.deepEqual(list.map((m) => m.user_id), [staff.id]);
  });
  test('outsider is refused', async () => {
    await rejectsWith(rpc(other.owner.id, 'list_team_members', [a.businessId]), { status: 403 });
  });
});

describe('manager add request', () => {
  test('manager cannot add a member directly', async () => {
    const u = await createUser('direct');
    await rejectsWith(rpc(manager.id, 'add_business_member', [a.businessId, u.email, 'station_staff', null, [a.stationId]]), { status: 403 });
  });
  test('staff cannot raise requests', async () => {
    await rejectsWith(rpc(staff.id, 'request_team_member', [a.businessId, 'x@test.local', 'X', null, [a.stationId]]), { status: 403 });
  });
  test('manager cannot request for a station they do not manage', async () => {
    await rejectsWith(rpc(manager.id, 'request_team_member', [a.businessId, 'y@test.local', 'Y', null, [stationB]]),
      { code: 'stations_not_managed' });
  });
  test('owner is told to add directly', async () => {
    await rejectsWith(rpc(a.owner.id, 'request_team_member', [a.businessId, 'y@test.local', 'Y', null, [a.stationId]]),
      { code: 'owner_adds_directly' });
  });
  test('request -> owner notified -> approve adds staff with default permissions', async () => {
    const newcomer = `new-${Date.now()}@test.local`;
    const req = await rpc(manager.id, 'request_team_member', [a.businessId, newcomer, 'New Person', '+919812345678', [a.stationId]]);
    assert.equal(req.status, 'pending');
    assert.equal(req.role, 'station_staff');
    const n = await one(`select count(*)::int as n from public.notifications where recipient_id = $1 and type = 'team.add_requested'`, [a.owner.id]);
    assert.ok(n.n >= 1);
    await rejectsWith(rpc(manager.id, 'request_team_member', [a.businessId, newcomer, 'Again', null, [a.stationId]]), { code: 'request_pending' });
    // Manager cannot approve their own request.
    await rejectsWith(rpc(manager.id, 'approve_member_request', [req.id]), { code: 'request_not_found' });
    // The Edge Function creates the login first; simulate that.
    await sql(`insert into auth.users (email, raw_user_meta_data) values ($1, '{"full_name":"New Person"}')`, [newcomer]);
    const res = await rpc(a.owner.id, 'approve_member_request', [req.id]);
    const m = await one(`select role, permissions, status from public.business_members where id = $1`, [res.member_id]);
    assert.equal(m.role, 'station_staff');
    assert.ok(m.permissions.includes('bookings.view'));
    const st = await one(`select status from public.business_member_requests where id = $1`, [req.id]);
    assert.equal(st.status, 'approved');
    await rejectsWith(rpc(a.owner.id, 'approve_member_request', [req.id]), { code: 'request_not_pending' });
  });
  test('owner can reject, manager can cancel', async () => {
    const r1 = await rpc(manager.id, 'request_team_member', [a.businessId, `rej-${Date.now()}@test.local`, 'Rej', null, [a.stationId]]);
    await rpc(a.owner.id, 'reject_member_request', [r1.id, 'not needed']);
    assert.equal((await one(`select status from public.business_member_requests where id = $1`, [r1.id])).status, 'rejected');
    const r2 = await rpc(manager.id, 'request_team_member', [a.businessId, `can-${Date.now()}@test.local`, 'Can', null, [a.stationId]]);
    await rpc(manager.id, 'cancel_member_request', [r2.id]);
    assert.equal((await one(`select status from public.business_member_requests where id = $1`, [r2.id])).status, 'cancelled');
  });
  test('manager lists only own requests; owner lists all', async () => {
    const mine = await rpc(manager.id, 'list_member_requests', [a.businessId, false]);
    assert.ok(mine.every((r) => r.requested_by === manager.id));
    const all = await rpc(a.owner.id, 'list_member_requests', [a.businessId, false]);
    assert.ok(all.length >= mine.length);
  });
});

describe('removal', () => {
  test('manager cannot remove directly or request removal of staff elsewhere', async () => {
    await rejectsWith(rpc(manager.id, 'remove_business_member', [await memberId(staff), null]), { code: 'member_not_found' });
    await rejectsWith(rpc(manager.id, 'request_member_removal', [await memberId(staffOther), 'left']), { status: 403 });
    await rejectsWith(rpc(manager.id, 'request_member_removal', [await memberId(manager), 'me']), { status: 403 });
  });
  test('manager removal request approved by owner deletes the member', async () => {
    const mid = await memberId(staff);
    const req = await rpc(manager.id, 'request_member_removal', [mid, 'Left the job']);
    assert.equal(req.member_name, 'Staff Tester');
    const res = await rpc(a.owner.id, 'remove_business_member', [mid, req.id]);
    assert.equal(res.user_id, staff.id);
    assert.equal(res.managed_account, false);
    assert.equal(await memberId(staff), undefined);
    const assigned = await one(`select count(*)::int as n from public.station_assignments where member_id = $1`, [mid]);
    assert.equal(assigned.n, 0);
    assert.equal((await one(`select status from public.business_member_requests where id = $1`, [req.id])).status, 'approved');
  });
  test('owner removes directly; managed login is flagged and profile can be scrubbed', async () => {
    const u = await createUser('managed');
    await sql(`update auth.users set raw_app_meta_data = $2 where id = $1`, [u.id, { created_by_business: a.businessId }]);
    const mid = await rpc(a.owner.id, 'add_business_member', [a.businessId, u.email, 'station_staff', null, [a.stationId]]);
    const res = await rpc(a.owner.id, 'remove_business_member', [mid, null]);
    assert.equal(res.managed_account, true);
    assert.equal(res.other_memberships, 0);
    await rejectsWith(rpc(a.owner.id, 'scrub_member_profile', [u.id]), { sqlstate: '42501' });
    await rpc('service', 'scrub_member_profile', [u.id]);
    const p = await one(`select full_name, email, phone, deleted_at from public.profiles where id = $1`, [u.id]);
    assert.equal(p.email, null);
    assert.ok(p.deleted_at);
  });
  test('owner cannot be removed', async () => {
    const owner = await one(`select id from public.business_members where business_id = $1 and role = 'owner'`, [a.businessId]);
    await rejectsWith(rpc(a.owner.id, 'remove_business_member', [owner.id, null]), { code: 'cannot_change_owner' });
  });
  test('prepare_member_account is owner only and reports existing logins', async () => {
    await rejectsWith(rpc(manager.id, 'prepare_member_account', [a.businessId, 'z@test.local']), { status: 403 });
    assert.equal((await rpc(a.owner.id, 'prepare_member_account', [a.businessId, 'nobody@test.local'])).exists, false);
    await rejectsWith(rpc(a.owner.id, 'prepare_member_account', [a.businessId, manager.email]), { code: 'already_member' });
  });
});

describe('direct table access', () => {
  test('requests cannot be written directly', async () => {
    await rejectsWith(as(manager.id, (q) => q(`insert into public.business_member_requests (business_id, kind, requested_by) values ($1, 'remove', $2)`,
      [a.businessId, manager.id])), { sqlstate: '42501' });
  });
});
