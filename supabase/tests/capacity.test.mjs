import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import {
  rpc, sql, one, rejectsWith, closePool, createUser, approvedStation, setFee, ist, idemKey, hold,
} from './lib/db.mjs';

after(async () => {
  await setFee(0);
  await closePool();
});
before(() => setFee(0));

/** Books by station, as the customer app does. */
const book = (customer, stationId, start, minutes, { key = idemKey(), connector = null } = {}) =>
  rpc(customer.id, 'create_station_booking_hold', [
    stationId, start.toISOString(), new Date(start.getTime() + minutes * 60000).toISOString(), key, connector, null,
  ]);
const check = (stationId, start, minutes, connector = null) =>
  rpc('anon', 'check_station_availability', [
    stationId, start.toISOString(), new Date(start.getTime() + minutes * 60000).toISOString(), connector,
  ]);
const pointOf = async (bookingId) =>
  (await one(`select cp.code from public.bookings b join public.charging_points cp on cp.id = b.charging_point_id where b.id = $1`, [bookingId])).code;

async function setConnector(pointId, type) {
  await sql(`insert into public.charging_connectors (charging_point_id, connector_number, connector_type) values ($1, 1, $2)`, [pointId, type]);
}

describe('booking by station', () => {
  test('three points take three cars at 9:00; the fourth sees the station as full', async () => {
    const { stationId } = await approvedStation({ points: ['A', 'B', 'C'] });
    const nine = ist(1, 9);
    const first = await book(await createUser('customer'), stationId, nine, 30);
    const second = await book(await createUser('customer'), stationId, nine, 30);
    assert.notEqual(first.charging_point_id, second.charging_point_id);
    const left = await check(stationId, nine, 30);
    assert.equal(left.available, true);
    assert.equal(left.free_points, 1);
    assert.equal(left.total_points, 3);
    const third = await book(await createUser('customer'), stationId, nine, 30);
    assert.equal(new Set([first, second, third].map((b) => b.charging_point_id)).size, 3);
    const full = await check(stationId, nine, 30);
    assert.equal(full.available, false);
    assert.equal(full.reason, 'station_full');
    await rejectsWith(book(await createUser('customer'), stationId, nine, 30), { status: 409, code: 'station_full' });
    // A later time is still open.
    assert.equal((await book(await createUser('customer'), stationId, ist(1, 10), 30)).status, 'confirmed');
  });

  test('45- and 30-minute bookings share points on a 15-minute grid, best fit first', async () => {
    const { stationId } = await approvedStation({ points: ['A', 'B'] });
    const a = await book(await createUser('customer'), stationId, ist(1, 9), 45); // 9:00-9:45
    const b = await book(await createUser('customer'), stationId, ist(1, 9), 30); // 9:00-9:30
    assert.notEqual(a.charging_point_id, b.charging_point_id);
    // 9:30-10:00 only fits on the point free from 9:30.
    const c = await book(await createUser('customer'), stationId, ist(1, 9, 30), 30);
    assert.equal(c.charging_point_id, b.charging_point_id);
    // 9:45-10:30 goes to the point free from 9:45.
    const d = await book(await createUser('customer'), stationId, ist(1, 9, 45), 45);
    assert.equal(d.charging_point_id, a.charging_point_id);
    await rejectsWith(book(await createUser('customer'), stationId, ist(1, 9, 15), 30), { status: 409, code: 'station_full' });
    await rejectsWith(book(await createUser('customer'), stationId, ist(1, 9, 10), 30), { status: 422, code: 'slot_misaligned' });
  });

  test('the same request twice returns the same booking', async () => {
    const { stationId } = await approvedStation({ points: ['A', 'B'] });
    const customer = await createUser('customer');
    const key = idemKey();
    const first = await book(customer, stationId, ist(1, 11), 30, { key });
    const again = await book(customer, stationId, ist(1, 11), 30, { key });
    assert.equal(again.id, first.id);
    assert.equal((await one(`select count(*)::int as n from public.bookings where customer_id = $1`, [customer.id])).n, 1);
  });

  test('a customer cannot hold two bookings at the same time, even at different stations', async () => {
    const s1 = await approvedStation({ points: ['A', 'B'] });
    const s2 = await approvedStation();
    const customer = await createUser('customer');
    await book(customer, s1.stationId, ist(1, 12), 60);
    await rejectsWith(book(customer, s1.stationId, ist(1, 12, 30), 30), { status: 409, code: 'overlapping_booking' });
    await rejectsWith(book(customer, s2.stationId, ist(1, 12), 30), { status: 409, code: 'overlapping_booking' });
    assert.equal((await book(customer, s2.stationId, ist(1, 13), 30)).status, 'confirmed');
  });

  test('only points with the chosen connector are assigned', async () => {
    const { stationId, pointIds } = await approvedStation({ points: ['A', 'B'] });
    await setConnector(pointIds[0], 'ccs2');
    await setConnector(pointIds[1], 'type2_ac');
    const ccs = await book(await createUser('customer'), stationId, ist(1, 15), 30, { connector: 'ccs2' });
    assert.equal(ccs.charging_point_id, pointIds[0]);
    assert.equal((await check(stationId, ist(1, 15), 30, 'ccs2')).available, false);
    assert.equal((await check(stationId, ist(1, 15), 30, 'type2_ac')).available, true);
    await rejectsWith(book(await createUser('customer'), stationId, ist(1, 15), 30, { connector: 'ccs2' }), { status: 409, code: 'station_full' });
  });

  test('guests can check availability but cannot book', async () => {
    const { stationId } = await approvedStation({ points: ['A'] });
    assert.equal((await check(stationId, ist(1, 16), 30)).available, true);
    await rejectsWith(
      rpc('anon', 'create_station_booking_hold', [stationId, ist(1, 16).toISOString(), ist(1, 16, 30).toISOString(), idemKey(), null, null]),
      { sqlstate: '42501' },
    );
  });
});

describe('when a point cannot serve its bookings', () => {
  test('taking a point out of service moves its bookings to a free compatible point', async () => {
    const { owner, stationId, pointIds } = await approvedStation({ points: ['A', 'B'] });
    const customer = await createUser('customer');
    const b = await book(customer, stationId, ist(1, 9), 30);
    const from = b.charging_point_id;
    const res = await rpc(owner.id, 'set_charging_point_status', [from, 'out_of_service', 'Cable damaged']);
    assert.equal(res.moved_bookings, 1);
    assert.equal(res.upcoming_bookings, 0);
    const moved = await one(`select charging_point_id, status from public.bookings where id = $1`, [b.id]);
    assert.notEqual(moved.charging_point_id, from);
    assert.ok(pointIds.includes(moved.charging_point_id));
    assert.equal(moved.status, 'confirmed');
    const note = await one(`select title from public.notifications where recipient_id = $1 and type = 'booking.point_changed'`, [customer.id]);
    assert.equal(note.title, 'Charging point changed');
  });

  test('a booking stays put when no other point is free, and the station is told', async () => {
    const { owner, stationId } = await approvedStation({ points: ['A', 'B'] });
    const one1 = await book(await createUser('customer'), stationId, ist(1, 9), 30);
    await book(await createUser('customer'), stationId, ist(1, 9), 30);
    const res = await rpc(owner.id, 'set_charging_point_status', [one1.charging_point_id, 'out_of_service', null]);
    assert.equal(res.moved_bookings, 0);
    assert.equal(res.upcoming_bookings, 1);
  });

  test('a maintenance block moves bookings first and needs confirmation only for the rest', async () => {
    const { owner, stationId, pointIds } = await approvedStation({ points: ['A', 'B'] });
    const b = await hold(await createUser('customer'), pointIds[0], ist(1, 10), 30);
    const res = await rpc(owner.id, 'create_blocked_period',
      [stationId, pointIds[0], ist(1, 9).toISOString(), ist(1, 12).toISOString(), 'maintenance', 'Cable', false]);
    assert.equal(res.moved_bookings, 1);
    assert.equal(res.cancelled_bookings, 0);
    assert.equal((await one(`select charging_point_id from public.bookings where id = $1`, [b.id])).charging_point_id, pointIds[1]);

    // Both points busy at 14:00: blocking A cannot move its booking.
    const c = await hold(await createUser('customer'), pointIds[0], ist(1, 14), 30);
    await hold(await createUser('customer'), pointIds[1], ist(1, 14), 30);
    await rejectsWith(rpc(owner.id, 'create_blocked_period',
      [stationId, pointIds[0], ist(1, 13).toISOString(), ist(1, 15).toISOString(), 'maintenance', 'Cable', false]),
    { status: 409, code: 'bookings_conflict' });
    assert.equal((await one(`select status from public.bookings where id = $1`, [c.id])).status, 'confirmed');
  });

  test('customers and staff still cannot change a booking point directly', async () => {
    const { stationId, pointIds } = await approvedStation({ points: ['A', 'B'] });
    const b = await book(await createUser('customer'), stationId, ist(1, 9), 30);
    const other = pointIds.find((p) => p !== b.charging_point_id);
    await rejectsWith(sql(`update public.bookings set charging_point_id = $2 where id = $1`, [b.id, other]), { status: 403, code: 'protected_field' });
  });
});
