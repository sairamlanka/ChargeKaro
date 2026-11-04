// Customer improvements (20261104000100_customer_improvements.sql): energy
// price, charger status from check-in, reschedule once, station ratings.
import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import {
  rpc, sql, one, rejectsWith, closePool, createUser, approvedStation, idemKey, setFee, insertBooking, slotStart, addMinutes,
} from './lib/db.mjs';

after(closePool);
before(() => setFee(0));

async function station(points = ['A', 'B']) {
  const s = await approvedStation({ points });
  for (const id of s.pointIds) {
    await sql(`insert into public.charging_connectors (charging_point_id, connector_number, connector_type) values ($1, 1, 'ccs2')`, [id]);
  }
  return s;
}

describe('energy price', () => {
  test('owners set a price per kWh and customers see it on the station', async () => {
    const s = await station(['A']);
    await sql(`update public.charging_points set price_per_kwh_paise = 1800 where id = $1`, [s.pointIds[0]]);
    const d = await rpc('anon', 'get_public_station', [s.stationId, null, null]);
    assert.equal(d.points_detail[0].price_per_kwh_paise, 1800);
    await rejectsWith(sql(`update public.charging_points set price_per_kwh_paise = 20000 where id = $1`, [s.pointIds[0]]), { sqlstate: '23514' });
  });
});

describe('charger status follows check-in', () => {
  test('in use while the booking is checked in, available after; maintenance is left alone', async () => {
    const s = await station(['A']);
    const customer = await createUser('customer');
    const start = new Date(Math.floor(Date.now() / 60000) * 60000);
    const b = await insertBooking({ customer, stationId: s.stationId, pointId: s.pointIds[0], start });
    const status = async () => (await one(`select operational_status from public.charging_points where id = $1`, [s.pointIds[0]])).operational_status;
    await sql(`update public.bookings set status = 'arrived', checked_in_at = now() where id = $1`, [b.id]);
    assert.equal(await status(), 'in_use');
    await sql(`update public.bookings set status = 'in_progress' where id = $1`, [b.id]);
    assert.equal(await status(), 'in_use');
    await sql(`update public.bookings set status = 'completed', completed_at = now() where id = $1`, [b.id]);
    assert.equal(await status(), 'available');

    const b2 = await insertBooking({ customer, stationId: s.stationId, pointId: s.pointIds[0], start: addMinutes(start, 31) });
    await sql(`update public.charging_points set operational_status = 'maintenance' where id = $1`, [s.pointIds[0]]);
    await sql(`update public.bookings set status = 'arrived', checked_in_at = now() where id = $1`, [b2.id]);
    assert.equal(await status(), 'maintenance');
  });
});

describe('reschedule', () => {
  test('a paid booking moves once to a free time, keeps its fee and gets a new QR', async () => {
    const s = await station(['A']);
    const customer = await createUser('customer');
    const start = slotStart(120);
    const b = await insertBooking({ customer, stationId: s.stationId, pointId: s.pointIds[0], start, paymentStatus: 'paid', fee: 1200 });
    const qr = (await rpc(customer.id, 'get_my_booking_qr', [b.id])).qr_payload;
    assert.ok(qr);
    const before = await rpc(customer.id, 'get_my_booking', [b.id, null]);
    assert.equal(before.can_reschedule, true);

    const newStart = addMinutes(start, 120);
    const r = await rpc(customer.id, 'reschedule_booking', [b.id, newStart.toISOString(), addMinutes(newStart, 30).toISOString(), null]);
    assert.equal(new Date(r.start_at).getTime(), newStart.getTime());
    assert.equal(new Date(r.original_start_at).getTime(), start.getTime());
    assert.equal(r.reschedule_count, 1);
    assert.equal(r.can_reschedule, false);
    assert.equal(r.reschedule_problem, 'reschedule_limit_reached');
    assert.equal(r.booking_fee_paise, 1200);
    assert.equal(r.payment_status, 'paid');
    const live = await sql(`select 1 from public.booking_qr_tokens where booking_id = $1 and revoked_at is null`, [b.id]);
    assert.equal(live.length, 0, 'old QR revoked');

    const again = addMinutes(start, 240);
    await rejectsWith(rpc(customer.id, 'reschedule_booking', [b.id, again.toISOString(), addMinutes(again, 30).toISOString(), null]),
      { status: 409, code: 'reschedule_limit_reached' });
  });

  test('moves to another point when its own point is taken; full station is refused', async () => {
    const s = await station(['A', 'B']);
    const [me, other, third] = [await createUser('me'), await createUser('other'), await createUser('third')];
    const start = slotStart(120);
    const target = addMinutes(start, 60);
    const b = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start });
    await insertBooking({ customer: other, stationId: s.stationId, pointId: s.pointIds[0], start: target });
    const r = await rpc(me.id, 'reschedule_booking', [b.id, target.toISOString(), addMinutes(target, 30).toISOString(), null]);
    assert.equal(r.charging_point_id, s.pointIds[1]);

    const b2 = await insertBooking({ customer: third, stationId: s.stationId, pointId: s.pointIds[1], start: addMinutes(start, 180) });
    await rejectsWith(rpc(third.id, 'reschedule_booking', [b2.id, target.toISOString(), addMinutes(target, 30).toISOString(), null]),
      { status: 409, code: 'station_full' });
    const unchanged = await one(`select reschedule_count, lower(period) s from public.bookings where id = $1`, [b2.id]);
    assert.equal(unchanged.reschedule_count, 0);
  });

  test('only the owner, only confirmed bookings, not after the slot started, not onto their own other booking', async () => {
    const s = await station(['A', 'B']);
    const [me, stranger] = [await createUser('me'), await createUser('stranger')];
    const start = slotStart(120);
    const b = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start });
    const t = addMinutes(start, 60);
    const args = [b.id, t.toISOString(), addMinutes(t, 30).toISOString(), null];
    await rejectsWith(rpc(stranger.id, 'reschedule_booking', args), { status: 404, code: 'booking_not_found' });
    await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[1], start: t });
    await rejectsWith(rpc(me.id, 'reschedule_booking', args), { status: 409, code: 'overlapping_booking' });

    const past = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start: new Date(Date.now() - 5 * 60000) });
    const t2 = addMinutes(start, 300);
    await rejectsWith(rpc(me.id, 'reschedule_booking', [past.id, t2.toISOString(), addMinutes(t2, 30).toISOString(), null]),
      { status: 409, code: 'reschedule_too_late' });
    await sql(`update public.bookings set status = 'cancelled', cancelled_at = now(), cancellation_actor = 'customer' where id = $1`, [b.id]);
    await rejectsWith(rpc(me.id, 'reschedule_booking', [b.id, t2.toISOString(), addMinutes(t2, 30).toISOString(), null]),
      { status: 409, code: 'not_reschedulable' });
  });

  test('direct time changes on a paid booking are still blocked', async () => {
    const s = await station(['A']);
    const me = await createUser('me');
    const start = slotStart(120);
    const b = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start });
    await rejectsWith(sql(`update public.bookings set period = tstzrange(lower(period) + interval '1 hour', upper(period) + interval '1 hour') where id = $1`, [b.id]),
      { code: 'booking_time_locked' });
  });
});

describe('station ratings', () => {
  test('rate after charging, change it, everyone sees the average; staff can hide', async () => {
    const s = await station(['A']);
    const [asha, ravi] = [await createUser('asha'), await createUser('ravi')];
    await sql(`update public.profiles set full_name = 'Asha Kumari' where id = $1`, [asha.id]);
    const start = new Date(Date.now() - 3 * 3600000);
    const b1 = await insertBooking({ customer: asha, stationId: s.stationId, pointId: s.pointIds[0], start });
    const b2 = await insertBooking({ customer: ravi, stationId: s.stationId, pointId: s.pointIds[0], start: addMinutes(start, 60) });

    await rejectsWith(rpc(asha.id, 'submit_station_review', [b1.id, 5, 'Great']), { status: 409, code: 'review_not_allowed' });
    for (const b of [b1, b2]) {
      await sql(`update public.bookings set status = 'arrived', checked_in_at = now() where id = $1`, [b.id]);
      await sql(`update public.bookings set status = 'completed', completed_at = now() where id = $1`, [b.id]);
    }
    await rejectsWith(rpc(ravi.id, 'submit_station_review', [b1.id, 1, null]), { status: 404, code: 'booking_not_found' });
    await rejectsWith(rpc(asha.id, 'submit_station_review', [b1.id, 6, null]), { status: 422, code: 'invalid_rating' });
    await rpc(asha.id, 'submit_station_review', [b1.id, 3, 'Slow charger']);
    await rpc(asha.id, 'submit_station_review', [b1.id, 5, '  Fast and clean  ']);
    await rpc(ravi.id, 'submit_station_review', [b2.id, 4, null]);

    const r = await rpc('anon', 'get_station_reviews', [s.stationId, 10]);
    assert.equal(r.count, 2);
    assert.equal(r.average, 4.5);
    assert.equal(r.stars['5'], 1);
    assert.equal(r.recent.find((x) => x.comment === 'Fast and clean').name, 'Asha');
    const mine = await rpc(asha.id, 'get_my_booking', [b1.id, null]);
    assert.equal(mine.my_rating, 5);

    const review = await one(`select id from public.station_reviews where booking_id = $1`, [b2.id]);
    await rejectsWith(rpc(asha.id, 'admin_set_review_hidden', [review.id, true]), { status: 403 });
    await rpc(s.admin.id, 'admin_set_review_hidden', [review.id, true]);
    const after = await rpc('anon', 'get_station_reviews', [s.stationId, 10]);
    assert.equal(after.count, 1);
    assert.equal(after.average, 5);
  });
});
