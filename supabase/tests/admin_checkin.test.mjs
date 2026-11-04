// Admin check-in counts, filter and details (20261103000300_admin_checkin_stats.sql).
import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import {
  rpc, sql, rejectsWith, closePool, createUser, createStaff, approvedStation, idemKey, setFee, insertBooking, addMinutes,
} from './lib/db.mjs';

after(closePool);
before(() => setFee(0));

const minute = 60000;
const soon = () => new Date(Math.floor(Date.now() / minute) * minute + 5 * minute);

async function setup() {
  const owner = await createUser('owner');
  const station = await approvedStation({ owner, points: ['A', 'B'] });
  const staff = await createUser('staff');
  await rpc(owner.id, 'add_business_member', [station.businessId, staff.email, 'station_staff', null, [station.stationId]]);
  const customer = await createUser('customer');
  const [a, b] = station.pointIds;
  const s0 = soon();
  const checkedIn = await insertBooking({ customer, stationId: station.stationId, pointId: a, start: s0 });
  const waiting = await insertBooking({ customer, stationId: station.stationId, pointId: a, start: addMinutes(s0, 120) });
  const missed = await insertBooking({ customer, stationId: station.stationId, pointId: b, start: addMinutes(s0, -24 * 60) });
  const cancelled = await insertBooking({ customer, stationId: station.stationId, pointId: b, start: addMinutes(s0, 240) });
  const unpaid = await insertBooking({ customer, stationId: station.stationId, pointId: b, start: addMinutes(s0, 360), status: 'payment_pending', paymentStatus: 'pending' });
  await sql(`update public.bookings set status = 'cancelled', cancelled_at = now(), cancellation_actor = 'customer' where id = $1`, [cancelled.id]);
  const r = await rpc(staff.id, 'checkin_booking', [station.stationId, checkedIn.id, 'manual', idemKey(), null, 'qr_not_working', null, 'device-9', null]);
  assert.equal(r.result, 'accepted');
  return { ...station, owner, staff, customer, checkedIn, waiting, missed, cancelled, unpaid };
}

describe('admin check-in stats', () => {
  test('counts checked-in and not-checked-in bookings', async () => {
    const s = await setup();
    const admin = await createStaff('super_admin');
    const st = await rpc(admin.id, 'admin_booking_checkin_stats', [null, null, s.stationId]);
    assert.equal(st.total, 5);
    assert.equal(st.checked_in, 1);
    assert.equal(st.not_checked_in, 2);
    assert.equal(st.awaiting, 1);
    assert.equal(st.missed, 1);
    assert.equal(st.not_due, 2);
    assert.equal(st.cancelled, 1);
    assert.equal(st.by_method.manual, 1);
    assert.equal(st.by_method.qr, 0);
  });

  test('search filters by check-in state and names who checked in', async () => {
    const s = await setup();
    const admin = await createStaff('super_admin');
    const yes = await rpc(admin.id, 'admin_search_bookings', [null, s.stationId, null, null, null, null, 50, 0, 'checked_in']);
    assert.deepEqual(yes.map((b) => b.id), [s.checkedIn.id]);
    assert.equal(yes[0].checked_in_by_name, 'Staff Tester');
    assert.equal(yes[0].checkin_method, 'manual');
    const no = await rpc(admin.id, 'admin_search_bookings', [null, s.stationId, null, null, null, null, 50, 0, 'not_checked_in']);
    assert.deepEqual(no.map((b) => b.id).sort(), [s.waiting.id, s.missed.id].sort());
    const all = await rpc(admin.id, 'admin_search_bookings', [null, s.stationId]);
    assert.equal(all.length, 5);
    await rejectsWith(rpc(admin.id, 'admin_search_bookings', [null, s.stationId, null, null, null, null, 50, 0, 'bogus']), { status: 422 });
  });

  test('booking check-in details include staff, reason, device and log', async () => {
    const s = await setup();
    const admin = await createStaff('super_admin');
    const d = await rpc(admin.id, 'admin_get_booking_checkin', [s.checkedIn.id]);
    assert.equal(d.state, 'checked_in');
    assert.equal(d.method, 'manual');
    assert.equal(d.verification_status, 'verified');
    assert.equal(d.checked_in_by_name, 'Staff Tester');
    assert.equal(d.reason_label, 'QR code not working');
    assert.equal(d.device_id, 'device-9');
    assert.ok(d.logs.some((l) => l.action === 'checkin' && l.result === 'accepted' && l.staff_name === 'Staff Tester'));
    const w = await rpc(admin.id, 'admin_get_booking_checkin', [s.waiting.id]);
    assert.equal(w.state, 'not_checked_in');
    assert.equal(w.checked_in_at, null);
  });

  test('business users and customers cannot call the admin functions', async () => {
    const s = await setup();
    for (const who of [s.owner, s.staff, s.customer]) {
      await rejectsWith(rpc(who.id, 'admin_booking_checkin_stats', []), { status: 403 });
      await rejectsWith(rpc(who.id, 'admin_get_booking_checkin', [s.checkedIn.id]), { status: 403 });
      await rejectsWith(rpc(who.id, 'admin_search_bookings', []), { status: 403 });
    }
  });
});
