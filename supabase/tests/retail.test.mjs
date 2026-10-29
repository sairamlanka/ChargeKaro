import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import {
  as, rpc, sql, one, rejectsWith, closePool, createUser, approvedStation, hold, setFee, ist, insertBooking, addMinutes,
} from './lib/db.mjs';

after(async () => {
  await setFee(0);
  await closePool();
});
before(() => setFee(0));

/** A customer created by phone OTP sign-in (profile gets the verified phone). */
async function phoneCustomer(name = 'Ravi Kumar') {
  const id = randomUUID();
  const phone = `+9197${String(Math.floor(Math.random() * 1e8)).padStart(8, '0')}`;
  await sql(`insert into auth.users (id, phone, raw_user_meta_data) values ($1, $2, $3)`, [id, phone.slice(1), { full_name: name }]);
  return { id, phone };
}

/** Puts a station somewhere unique so radius searches only find it. */
async function placeStation(stationId, lat, lng, extra = {}) {
  await sql(`update public.stations set latitude = $2, longitude = $3, postal_code = coalesce($4, postal_code),
                                      city = coalesce($5, city), landmark = coalesce($6, landmark)
              where id = $1`, [stationId, lat, lng, extra.postal ?? null, extra.city ?? null, extra.landmark ?? null]);
}

const anonCall = (fn, args = []) => rpc('anon', fn, args);
const istDate = (dayOffset) => new Date(Date.now() + 330 * 60000 + dayOffset * 86400000).toISOString().slice(0, 10);

describe('guest discovery', () => {
  test('anon finds nearby public stations nearest first, with distance and next free slot', async () => {
    const near = await approvedStation({ points: ['A', 'B'] });
    const far = await approvedStation();
    await placeStation(near.stationId, 17.385, 78.4867);
    await placeStation(far.stationId, 17.385, 78.5267); // ~4.2 km east
    const res = await anonCall('search_stations', [17.385, 78.4867, 5, 50]);
    assert.equal(res.in_service_area, true);
    const ids = res.stations.map((s) => s.id);
    assert.ok(ids.indexOf(near.stationId) < ids.indexOf(far.stationId));
    const card = res.stations.find((s) => s.id === near.stationId);
    assert.equal(card.distance_km, 0);
    assert.equal(card.bookable, true);
    assert.equal(card.points.total, 2);
    assert.equal(card.booking_fee_paise, 0);
    assert.ok(card.next_available?.start_at, 'next available slot is computed');
    const farCard = res.stations.find((s) => s.id === far.stationId);
    assert.ok(farCard.distance_km > 3.5 && farCard.distance_km < 5, `distance ${farCard.distance_km}`);

    const narrow = await anonCall('search_stations', [17.385, 78.4867, 2, 50]);
    assert.ok(!narrow.stations.some((s) => s.id === far.stationId), 'radius is respected');
  });

  test('draft, suspended and closed stations are handled; guests still cannot read tables', async () => {
    const s = await approvedStation();
    await placeStation(s.stationId, 18.52, 73.8567);
    await rpc(s.admin.id, 'suspend_station', [s.stationId, 'Compliance check', true]);
    const res = await anonCall('search_stations', [18.52, 73.8567, 5, 50]);
    assert.ok(!res.stations.some((x) => x.id === s.stationId), 'suspended station is not listed');
    const detail = await anonCall('get_public_station', [s.stationId, null, null]);
    assert.deepEqual(detail, { id: s.stationId, name: 'Test Station', bookable: false, unavailable_reason: 'not_accepting_bookings', public: false });

    const c = await approvedStation();
    await placeStation(c.stationId, 18.62, 73.8567);
    await rpc(c.owner.id, 'close_station_temporarily', [c.stationId, ist(3, 0).toISOString(), 'Renovation', true]);
    const closed = await anonCall('search_stations', [18.62, 73.8567, 5, 50]);
    const card = closed.stations.find((x) => x.id === c.stationId);
    assert.equal(card.bookable, false);
    assert.equal(card.unavailable_reason, 'temporarily_closed');

    await rejectsWith(as('anon', (q) => q(`select 1 from public.stations limit 1`)), { sqlstate: '42501' });
    await rejectsWith(as('anon', (q) => q(`select public.get_my_bookings(10)`)), { sqlstate: '42501' });
    await rejectsWith(as('anon', (q) => q(`select * from private.point_cells($1, now(), now())`, [c.pointIds[0]])), { sqlstate: '42501' });
  });

  test('outside the service area and invalid input are explained', async () => {
    const res = await anonCall('search_stations', [51.5072, -0.1276, 5, 50]);
    assert.equal(res.in_service_area, false);
    assert.deepEqual(res.stations, []);
    await rejectsWith(anonCall('search_stations', [17.385, 78.4867, 80, 50]), { status: 422, code: 'invalid_radius' });
    await rejectsWith(anonCall('search_stations', [null, 78.4867, 5, 50]), { status: 422, code: 'invalid_location' });
  });

  test('station details include points, policy, hours and the unconfirmed refund policy', async () => {
    const s = await approvedStation({ points: ['DC1'] });
    const d = await anonCall('get_public_station', [s.stationId, 12.9716, 77.5946]);
    assert.equal(d.public, true);
    assert.equal(d.points_detail.length, 1);
    assert.equal(d.points_detail[0].code, 'DC1');
    assert.equal(d.points_detail[0].bookable, true);
    assert.equal(d.policy.slot_duration_minutes, 15);
    assert.equal(d.policy.report_before_minutes, 5);
    assert.equal(d.policy.arrival_grace_minutes, 5);
    assert.equal(d.hours.length, 7);
    assert.equal(d.refund_policy.policy_confirmed, false);
    assert.equal(d.refund_policy.customer_cancellation_refundable, false);
    assert.equal(d.distance_km, 0);
    await rejectsWith(anonCall('get_public_station', [randomUUID(), null, null]), { status: 404, code: 'station_not_found' });
  });

  test('area search works from station localities without a geocoder', async () => {
    const s = await approvedStation();
    await placeStation(s.stationId, 17.44, 78.35, { postal: '500032', city: 'Hyderabad', landmark: 'Gachibowli Stadium' });
    const byPin = await anonCall('search_areas', ['500032', 8]);
    assert.ok(byPin.some((a) => a.label.startsWith('500032')));
    const byLandmark = await anonCall('search_areas', ['gachibowli', 8]);
    assert.ok(byLandmark.some((a) => a.label === 'Gachibowli Stadium' && Number(a.latitude) === 17.44));
    await rejectsWith(anonCall('search_areas', ['a', 8]), { status: 422, code: 'query_too_short' });
  });
});

describe('slot grid', () => {
  test('cells show booked, reserved, blocked, closed-hours and past states distinctly', async () => {
    const owner = await createUser('owner');
    const s = await approvedStation({ owner, points: ['A', 'B'], hours: [360, 1320], policy: { buffer_minutes: 0, slot_duration_minutes: 30 } });
    const customer = await createUser('customer');
    await hold(customer, s.pointIds[0], ist(1, 10), 60); // confirmed (fee 0)
    await setFee(1200);
    await hold(await createUser('customer'), s.pointIds[0], ist(1, 14), 30); // payment_pending hold
    await setFee(0);
    await rpc(owner.id, 'create_blocked_period', [s.stationId, s.pointIds[1], ist(1, 9).toISOString(), ist(1, 11).toISOString(), 'maintenance', 'Cable', false]);

    const grid = await anonCall('get_station_slots', [s.stationId, istDate(1)]);
    assert.equal(grid.slot_minutes, 30);
    const [a, b] = grid.points;
    assert.equal(a.cells.length, 32, '06:00-22:00 in 30-minute cells only');
    const at = (point, h, m = 0) => point.cells.find((c) => new Date(c.start_at).getTime() === ist(1, h, m).getTime());
    assert.equal(at(a, 10).state, 'booked');
    assert.equal(at(a, 10, 30).state, 'booked');
    assert.equal(at(a, 11).state, 'available');
    assert.equal(at(a, 14).state, 'reserved');
    assert.equal(at(b, 9).state, 'blocked');
    assert.equal(at(b, 11).state, 'available');
    // A minimum-length booking may end exactly where the next booking starts.
    assert.equal(at(a, 9, 30).can_start, true);
    // Closing time: the last cell can start a 30-minute booking ending at 22:00.
    assert.equal(at(a, 21, 30).can_start, true);

    const today = await anonCall('get_station_slots', [s.stationId, istDate(0)]);
    const past = today.points[0].cells.filter((c) => new Date(c.end_at) <= new Date());
    assert.ok(past.every((c) => c.state === 'past' && c.can_start === false));

    await rejectsWith(anonCall('get_station_slots', [s.stationId, istDate(-1)]), { status: 422, code: 'period_in_past' });
    await rejectsWith(anonCall('get_station_slots', [s.stationId, istDate(30)]), { status: 422, code: 'too_far_ahead' });
  });

  test('the station buffer stops a start that would run into the next booking', async () => {
    const s = await approvedStation({ policy: { buffer_minutes: 15 } });
    await hold(await createUser('customer'), s.pointIds[0], ist(1, 12), 30);
    const grid = await anonCall('get_station_slots', [s.stationId, istDate(1)]);
    const cell = (h, m = 0) => grid.points[0].cells.find((c) => new Date(c.start_at).getTime() === ist(1, h, m).getTime());
    assert.equal(cell(11, 30).state, 'available');
    assert.equal(cell(11, 30).can_start, false, '11:30-12:00 + 15 min buffer overlaps 12:00');
    assert.equal(cell(12, 30).state, 'booked', 'the booking buffer occupies 12:30-12:45');
    assert.equal(cell(11).can_start, true);
  });

  test('maintenance points are unavailable and check_slot_availability agrees with create_booking_hold', async () => {
    const s = await approvedStation({ points: ['A', 'B'] });
    await rpc(s.owner.id, 'set_charging_point_status', [s.pointIds[1], 'maintenance', 'Servicing']);
    const grid = await anonCall('get_station_slots', [s.stationId, istDate(1)]);
    assert.ok(grid.points[1].cells.filter((c) => c.state !== 'past').every((c) => c.state === 'unavailable'));
    assert.equal(grid.points[1].unavailable_reason, 'maintenance');

    const start = ist(2, 10);
    const ok = await anonCall('check_slot_availability', [s.pointIds[0], start.toISOString(), addMinutes(start, 30).toISOString()]);
    assert.equal(ok.available, true);
    await hold(await createUser('customer'), s.pointIds[0], start, 30);
    const taken = await anonCall('check_slot_availability', [s.pointIds[0], start.toISOString(), addMinutes(start, 30).toISOString()]);
    assert.deepEqual([taken.available, taken.reason], [false, 'slot_unavailable']);
    const misaligned = await anonCall('check_slot_availability', [s.pointIds[0], ist(2, 10, 10).toISOString(), ist(2, 10, 40).toISOString()]);
    assert.deepEqual([misaligned.available, misaligned.reason], [false, 'slot_misaligned']);
    const broken = await anonCall('check_slot_availability', [s.pointIds[1], start.toISOString(), addMinutes(start, 30).toISOString()]);
    assert.deepEqual([broken.available, broken.reason], [false, 'point_not_bookable']);
  });
});

describe('customer bookings', () => {
  test('customers see only their own bookings, by id or reference, with station and payment details', async () => {
    const s = await approvedStation();
    const me = await phoneCustomer();
    const other = await phoneCustomer('Other Person');
    const mine = await hold(me, s.pointIds[0], ist(1, 10), 30);
    const theirs = await hold(other, s.pointIds[0], ist(1, 12), 30);

    const list = await rpc(me.id, 'get_my_bookings', [100]);
    assert.deepEqual(list.map((b) => b.id), [mine.id]);
    assert.equal(list[0].station.name, 'Test Station');
    assert.equal(list[0].point.code, 'P1');
    assert.equal(list[0].customer_display_name, 'Ravi K.');

    const byRef = await rpc(me.id, 'get_my_booking', [null, mine.reference.toLowerCase()]);
    assert.equal(byRef.id, mine.id);
    assert.ok(Array.isArray(byRef.events) && byRef.events.length >= 1);
    await rejectsWith(rpc(me.id, 'get_my_booking', [theirs.id, null]), { status: 404, code: 'booking_not_found' });
    await rejectsWith(rpc(me.id, 'get_my_booking', [null, theirs.reference]), { status: 404, code: 'booking_not_found' });
  });

  test('preview_cancellation follows the station window and the refund policy setting', async () => {
    const s = await approvedStation({ policy: { customer_cancel_until_minutes: 30 } });
    const me = await phoneCustomer();
    const paid = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start: ist(2, 10), paymentStatus: 'paid', fee: 1200 });
    const p = await rpc(me.id, 'preview_cancellation', [paid.id]);
    assert.equal(p.allowed, true);
    assert.equal(p.refund_eligible, false, 'default placeholder policy keeps the fee on customer cancellation');
    assert.equal(p.refund_amount_paise, 0);
    assert.equal(p.policy_confirmed, false);

    const policy = await one(`select value from public.platform_settings where key = 'refund_policy'`);
    await sql(`update public.platform_settings set value = value || '{"customer_cancellation_refundable": true}' where key = 'refund_policy'`);
    try {
      const p2 = await rpc(me.id, 'preview_cancellation', [paid.id]);
      assert.equal(p2.refund_eligible, true);
      assert.equal(p2.refund_amount_paise, 1200);
    } finally {
      await sql(`update public.platform_settings set value = $1 where key = 'refund_policy'`, [policy.value]);
    }

    const soon = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start: addMinutes(new Date(), 20) });
    const late = await rpc(me.id, 'preview_cancellation', [soon.id]);
    assert.deepEqual([late.allowed, late.reason], [false, 'cancellation_window_closed']);
    await rejectsWith(rpc(me.id, 'cancel_booking', [soon.id, null]), { status: 409, code: 'cancellation_window_closed' });

    await rpc(me.id, 'cancel_booking', [paid.id, null]);
    const done = await rpc(me.id, 'preview_cancellation', [paid.id]);
    assert.deepEqual([done.allowed, done.reason], [false, 'not_cancellable']);
    const stranger = await phoneCustomer();
    await rejectsWith(rpc(stranger.id, 'preview_cancellation', [paid.id]), { status: 404, code: 'booking_not_found' });
  });
});

describe('customer messages', () => {
  test('confirmation queues SMS to the verified phone and email only when given; queue is claimed once', async () => {
    const s = await approvedStation();
    const me = await phoneCustomer();
    const b1 = await hold(me, s.pointIds[0], ist(1, 10), 30);
    let msgs = await sql(`select channel, template, destination from public.customer_messages where booking_id = $1`, [b1.id]);
    assert.deepEqual(msgs, [{ channel: 'sms', template: 'booking_confirmed', destination: me.phone }]);

    await as(me.id, (q) => q(`update public.profiles set receipt_email = 'ravi@example.com' where id = $1`, [me.id]));
    const b2 = await hold(me, s.pointIds[0], ist(1, 12), 30);
    msgs = await sql(`select channel::text from public.customer_messages where booking_id = $1 order by 1`, [b2.id]);
    assert.deepEqual(msgs.map((m) => m.channel), ['email', 'sms']);

    const claimed = await as('service', (q) => q(`select id from public.claim_customer_messages(500)`));
    const again = await as('service', (q) => q(`select id from public.claim_customer_messages(500)`));
    const mineIds = new Set((await sql(`select id from public.customer_messages where recipient_id = $1`, [me.id])).map((r) => r.id));
    assert.ok([...mineIds].every((id) => claimed.some((c) => c.id === id)));
    assert.ok(!again.some((c) => mineIds.has(c.id)));
    for (const c of claimed) await rpc('service', 'complete_customer_message', [c.id, 'skipped', null, 'channel_not_configured']);

    await rejectsWith(as(me.id, (q) => q(`select * from public.customer_messages`)), { sqlstate: '42501' });
    await rejectsWith(as(me.id, (q) => q(`select public.claim_customer_messages(10)`)), { sqlstate: '42501' });
  });

  test('cancellation and refunds queue messages; resend email validates and is rate limited', async () => {
    const s = await approvedStation();
    const me = await phoneCustomer();
    const b = await hold(me, s.pointIds[0], ist(1, 10), 30);
    await rejectsWith(rpc(me.id, 'resend_booking_email', [b.id, 'not-an-email']), { status: 422, code: 'invalid_email' });
    for (let i = 0; i < 4; i++) await rpc(me.id, 'resend_booking_email', [b.id, i === 0 ? 'me@example.com' : null]);
    await rejectsWith(rpc(me.id, 'resend_booking_email', [b.id, null]), { status: 409, code: 'rate_limited' });
    const profile = await one(`select receipt_email from public.profiles where id = $1`, [me.id]);
    assert.equal(profile.receipt_email, 'me@example.com');

    await rpc(me.id, 'cancel_booking', [b.id, null]);
    const t = await sql(`select distinct template from public.customer_messages where booking_id = $1 order by 1`, [b.id]);
    assert.deepEqual(t.map((r) => r.template), ['booking_cancelled', 'booking_confirmed']);
    const other = await phoneCustomer();
    await rejectsWith(rpc(other.id, 'resend_booking_email', [b.id, null]), { status: 404, code: 'booking_not_found' });
  });

  test('reminders are queued once for bookings starting within the hour, respecting the preference', async () => {
    const s = await approvedStation({ points: ['A', 'B'] });
    const me = await phoneCustomer();
    const quiet = await phoneCustomer();
    await as(quiet.id, (q) => q(`update public.profiles set notification_prefs = '{"reminders": false}' where id = $1`, [quiet.id]));
    const b = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start: addMinutes(new Date(), 45) });
    const q2 = await insertBooking({ customer: quiet, stationId: s.stationId, pointId: s.pointIds[1], start: addMinutes(new Date(), 50) });
    await rpc('service', 'enqueue_booking_reminders');
    await rpc('service', 'enqueue_booking_reminders');
    const rows = await sql(`select booking_id from public.customer_messages where template = 'booking_reminder' and booking_id = any($1)`, [[b.id, q2.id]]);
    assert.deepEqual(rows.map((r) => r.booking_id), [b.id]);
  });
});

describe('profile, consents, reports and deletion', () => {
  test('customers update name, receipt email and preferences but not their phone; consents are append-only', async () => {
    const me = await phoneCustomer();
    await as(me.id, (q) => q(`update public.profiles set full_name = 'Ravi K', receipt_email = 'r@example.com', notification_prefs = '{"reminders": false}' where id = $1`, [me.id]));
    await rejectsWith(as(me.id, (q) => q(`update public.profiles set phone = '+919999999999' where id = $1`, [me.id])), { sqlstate: '42501' });
    await rejectsWith(as(me.id, (q) => q(`update public.profiles set receipt_email = 'bad' where id = $1`, [me.id])), { sqlstate: '23514' });

    await as(me.id, (q) => q(`insert into public.customer_consents (kind, version, granted) values ('booking_terms', '2026-10-22', true), ('marketing', '2026-10-22', false)`));
    const other = await phoneCustomer();
    await rejectsWith(as(me.id, (q) => q(`insert into public.customer_consents (user_id, kind, version, granted) values ($1, 'marketing', 'v', true)`, [other.id])), { sqlstate: '42501' });
    const rows = await as(me.id, (q) => q(`select kind, granted from public.customer_consents order by kind`));
    assert.deepEqual(rows, [{ kind: 'booking_terms', granted: true }, { kind: 'marketing', granted: false }]);
    await rejectsWith(as(me.id, (q) => q(`delete from public.customer_consents`)), { sqlstate: '42501' });
    assert.equal((await as(other.id, (q) => q(`select * from public.customer_consents`))).length, 0);
  });

  test('guests can report station information; booking problems need the booking customer', async () => {
    const s = await approvedStation();
    const me = await phoneCustomer();
    const b = await hold(me, s.pointIds[0], ist(1, 10), 30);
    const r = await anonCall('submit_customer_report', ['incorrect_station_info', 'The entrance is on the side road', null, s.stationId]);
    assert.match(r.reference, /^CS[0-9A-Z]{8}$/);
    await rejectsWith(anonCall('submit_customer_report', ['point_occupied', 'busy', b.id, null]), { status: 401 });
    await rejectsWith(anonCall('submit_customer_report', ['point_occupied', 'busy', null, s.stationId]), { status: 422, code: 'booking_required' });
    const other = await phoneCustomer();
    await rejectsWith(rpc(other.id, 'submit_customer_report', ['point_occupied', null, b.id, null]), { status: 404 });
    await rpc(me.id, 'submit_customer_report', ['point_occupied', 'Someone is parked here', b.id, null]);
    const notes = await as(s.owner.id, (q) => q(`select type from public.notifications where data->>'booking_id' = $1`, [b.id]));
    assert.ok(notes.some((n) => n.type === 'booking.customer_report'));
    const seen = await as(me.id, (q) => q(`select kind from public.customer_reports`));
    assert.deepEqual(seen.map((x) => x.kind), ['point_occupied']);
  });

  test('account deletion is blocked by active bookings and recorded once otherwise', async () => {
    const s = await approvedStation();
    const me = await phoneCustomer();
    const b = await hold(me, s.pointIds[0], ist(1, 10), 30);
    const check = await rpc(me.id, 'get_account_deletion_check');
    assert.equal(check.active_bookings, 1);
    await rejectsWith(rpc(me.id, 'request_account_deletion', ['moving']), { status: 409, code: 'deletion_blocked' });
    await rpc(me.id, 'cancel_booking', [b.id, null]);
    const req = await rpc(me.id, 'request_account_deletion', ['moving']);
    assert.equal(req.status, 'pending');
    const again = await rpc(me.id, 'request_account_deletion', [null]);
    assert.equal(again.id, req.id);
    await rejectsWith(rpc(s.owner.id, 'request_account_deletion', [null]), { status: 409, code: 'deletion_blocked_role' });
  });
});

describe('phone sign-in identity', () => {
  test('the same verified phone maps to one profile; a different phone cannot see the booking', async () => {
    const me = await phoneCustomer('Asha Rao');
    const rows = await sql(`select count(*)::int as n from public.profiles where phone = $1`, [me.phone]);
    assert.equal(rows[0].n, 1);
    await rejectsWith(sql(`insert into auth.users (id, phone) values ($1, $2)`, [randomUUID(), me.phone.slice(1)]), { sqlstate: '23505' });
  });
});
