import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import {
  as, rpc, sql, one, rejectsWith, closePool, createUser, createStaff, approvedStation, addMinutes, idemKey,
  hold, setFee, ist, insertBooking, setHours,
} from './lib/db.mjs';

after(closePool);
before(() => setFee(0));

describe('reservation rules', () => {
  test('a valid reservation is confirmed immediately when the fee is zero', async () => {
    const { pointIds } = await approvedStation();
    const customer = await createUser('customer');
    const b = await hold(customer, pointIds[0], ist(1, 10), 60);
    assert.equal(b.status, 'confirmed');
    assert.equal(b.payment_status, 'not_required');
    assert.match(b.reference, /^CK[0-9A-Z]{10}$/);
  });

  test('outside operating hours, misaligned, too long, too far ahead and past slots are refused', async () => {
    const owner = await createUser('owner');
    const { pointIds } = await approvedStation({ owner, hours: [360, 1320] }); // 06:00-22:00
    const customer = await createUser('customer');
    await rejectsWith(hold(customer, pointIds[0], ist(1, 5), 30), { status: 422, code: 'outside_operating_hours' });
    await rejectsWith(hold(customer, pointIds[0], ist(1, 21, 30), 60), { status: 422, code: 'outside_operating_hours' });
    await rejectsWith(hold(customer, pointIds[0], ist(1, 10, 10), 30), { status: 422, code: 'slot_misaligned' });
    await rejectsWith(hold(customer, pointIds[0], ist(1, 10), 45), { status: 422, code: 'invalid_duration' });
    await rejectsWith(hold(customer, pointIds[0], ist(1, 10), 180), { status: 422, code: 'invalid_duration' });
    await rejectsWith(hold(customer, pointIds[0], ist(30, 10), 30), { status: 422, code: 'too_far_ahead' });
    await rejectsWith(hold(customer, pointIds[0], ist(-1, 10), 30), { status: 422, code: 'too_soon' });
  });

  test('point-specific bookable periods further restrict station hours', async () => {
    const owner = await createUser('owner');
    const { stationId, pointIds } = await approvedStation({ owner, points: ['A', 'B'] });
    await setHours(owner, stationId, 600, 720, pointIds[1]); // B only 10:00-12:00
    const customer = await createUser('customer');
    await hold(customer, pointIds[0], ist(1, 14), 30);
    await rejectsWith(hold(customer, pointIds[1], ist(1, 14), 30), { status: 422, code: 'outside_operating_hours' });
    const ok = await hold(customer, pointIds[1], ist(1, 10), 30);
    assert.equal(ok.status, 'confirmed');
  });

  test('maintenance blocks and maintenance status prevent reservations', async () => {
    const owner = await createUser('owner');
    const { stationId, pointIds } = await approvedStation({ owner, points: ['A', 'B'] });
    const customer = await createUser('customer');
    await rpc(owner.id, 'create_blocked_period', [stationId, pointIds[0], ist(1, 9).toISOString(), ist(1, 12).toISOString(), 'maintenance', 'Cable replacement', false]);
    await rejectsWith(hold(customer, pointIds[0], ist(1, 10), 30), { status: 409, code: 'blocked_period' });
    await hold(customer, pointIds[1], ist(1, 10), 30);

    await rpc(owner.id, 'set_charging_point_status', [pointIds[1], 'out_of_service', 'Display broken']);
    await rejectsWith(hold(customer, pointIds[1], ist(1, 15), 30), { status: 409, code: 'point_not_bookable' });
    const point = await one(`select status_source from public.charging_points where id = $1`, [pointIds[1]]);
    assert.equal(point.status_source, 'manual');
  });

  test('blocking a period with existing bookings needs explicit cancellation', async () => {
    const owner = await createUser('owner');
    const { stationId, pointIds } = await approvedStation({ owner });
    const customer = await createUser('customer');
    const b = await hold(customer, pointIds[0], ist(2, 10), 30);
    const args = [stationId, null, ist(2, 9).toISOString(), ist(2, 11).toISOString(), 'temporary_closure', 'Power cut'];
    await rejectsWith(rpc(owner.id, 'create_blocked_period', [...args, false]), { status: 409, code: 'bookings_conflict' });
    const res = await rpc(owner.id, 'create_blocked_period', [...args, true]);
    assert.equal(res.cancelled_bookings, 1);
    const after = await one(`select status, cancellation_actor from public.bookings where id = $1`, [b.id]);
    assert.equal(after.status, 'cancelled');
    assert.equal(after.cancellation_actor, 'business');
  });

  test('suspended or temporarily closed stations are not bookable', async () => {
    const owner = await createUser('owner');
    const { admin, stationId, pointIds } = await approvedStation({ owner });
    const customer = await createUser('customer');
    await rpc(owner.id, 'close_station_temporarily', [stationId, ist(3, 0).toISOString(), 'Renovation', true]);
    await rejectsWith(hold(customer, pointIds[0], ist(1, 10), 30), { status: 409, code: 'station_not_bookable' });
    await rpc(owner.id, 'reopen_station', [stationId]);
    await hold(customer, pointIds[0], ist(1, 10), 30);
    await rpc(admin.id, 'suspend_station', [stationId, 'Compliance review', false]);
    await rejectsWith(hold(customer, pointIds[0], ist(1, 11), 30), { status: 409, code: 'station_not_bookable' });
  });

  test('draft stations are not bookable', async () => {
    const { pointIds, stationId } = await approvedStation();
    await sql(`update public.stations set status = 'draft', approved_at = null where id = $1`, [stationId]);
    const customer = await createUser('customer');
    await rejectsWith(hold(customer, pointIds[0], ist(1, 10), 30), { status: 409, code: 'station_not_bookable' });
  });
});

describe('double-booking protection', () => {
  test('overlapping reservations on the same point conflict; other points do not', async () => {
    const { pointIds } = await approvedStation({ points: ['A', 'B'] });
    const c1 = await createUser('customer');
    const c2 = await createUser('customer');
    await hold(c1, pointIds[0], ist(1, 10), 60);
    await rejectsWith(hold(c2, pointIds[0], ist(1, 10, 30), 30), { status: 409, code: 'slot_unavailable' });
    await hold(c2, pointIds[1], ist(1, 10, 30), 30);
    // Adjacent slot is fine (half-open ranges).
    await hold(c2, pointIds[0], ist(1, 11), 30);
  });

  test('buffer time between bookings is enforced', async () => {
    const { pointIds } = await approvedStation({ policy: { buffer_minutes: 15 } });
    const c1 = await createUser('customer');
    const c2 = await createUser('customer');
    await hold(c1, pointIds[0], ist(1, 10), 30);
    await rejectsWith(hold(c2, pointIds[0], ist(1, 10, 30), 30), { status: 409, code: 'slot_unavailable' });
    await hold(c2, pointIds[0], ist(1, 11), 30);
  });

  test('20 simultaneous requests for one slot produce exactly one booking', async () => {
    const { pointIds } = await approvedStation();
    const customers = await Promise.all(Array.from({ length: 20 }, () => createUser('customer')));
    const start = ist(2, 15);
    const results = await Promise.allSettled(customers.map((c) => hold(c, pointIds[0], start, 30)));
    const ok = results.filter((r) => r.status === 'fulfilled');
    const conflicts = results.filter((r) => r.status === 'rejected' && r.reason.message === 'slot_unavailable');
    assert.equal(ok.length, 1, 'exactly one booking succeeds');
    assert.equal(conflicts.length, 19, 'all others get a clean 409 conflict');
    const rows = await sql(
      `select count(*)::int as n from public.bookings where charging_point_id = $1 and status in ('confirmed','payment_pending')`,
      [pointIds[0]]);
    assert.equal(rows[0].n, 1);
  });

  test('simultaneous overlapping (not identical) requests also produce one booking', async () => {
    const { pointIds } = await approvedStation();
    const customers = await Promise.all(Array.from({ length: 6 }, () => createUser('customer')));
    const starts = [ist(2, 9), ist(2, 9, 30), ist(2, 10), ist(2, 9), ist(2, 9, 30), ist(2, 10)];
    const results = await Promise.allSettled(customers.map((c, i) => hold(c, pointIds[0], starts[i], 60)));
    const ok = results.filter((r) => r.status === 'fulfilled').map((r) => r.value);
    // Any accepted set must be pairwise non-overlapping.
    for (const a of ok) for (const b of ok) {
      if (a.id === b.id) continue;
      assert.ok(new Date(a.end_at) <= new Date(b.start_at) || new Date(b.end_at) <= new Date(a.start_at), 'no overlap');
    }
    assert.ok(ok.length >= 1 && ok.length <= 2);
  });

  test('a retried request with the same idempotency key returns the same booking', async () => {
    const { pointIds } = await approvedStation();
    const customer = await createUser('customer');
    const key = idemKey();
    const a = await hold(customer, pointIds[0], ist(1, 12), 30, key);
    const b = await hold(customer, pointIds[0], ist(1, 12), 30, key);
    assert.equal(a.id, b.id);
  });

  test('clients cannot insert or update bookings directly', async () => {
    const { stationId, pointIds } = await approvedStation();
    const customer = await createUser('customer');
    await rejectsWith(as(customer.id, (q) => q(
      `insert into public.bookings (customer_id, station_id, charging_point_id, period, occupancy, status, payment_status,
                                    booking_fee_paise, customer_display_name)
       values ($1, $2, $3, tstzrange(now() + interval '1 day', now() + interval '25 hours'),
               tstzrange(now() + interval '1 day', now() + interval '25 hours'), 'confirmed', 'paid', 0, 'x')`,
      [customer.id, stationId, pointIds[0]])), { sqlstate: '42501' });
    const b = await hold(customer, pointIds[0], ist(1, 10), 30);
    await rejectsWith(as(customer.id, (q) => q(`update public.bookings set payment_status = 'paid' where id = $1`, [b.id])),
      { sqlstate: '42501' });
  });
});

describe('payment holds and expiry', () => {
  test('with a fee, the booking holds the slot as payment_pending until it expires', async () => {
    await setFee(1200);
    try {
      const { pointIds } = await approvedStation();
      const c1 = await createUser('customer');
      const c2 = await createUser('customer');
      const b = await hold(c1, pointIds[0], ist(1, 10), 30);
      assert.equal(b.status, 'payment_pending');
      assert.equal(b.booking_fee_paise, 1200);
      assert.ok(new Date(b.hold_expires_at) > new Date());
      await rejectsWith(hold(c2, pointIds[0], ist(1, 10), 30), { status: 409, code: 'slot_unavailable' });

      // Expire the hold; the next customer's request lazily releases it.
      await sql(`update public.bookings set hold_expires_at = now() - interval '1 second' where id = $1`, [b.id]);
      const b2 = await hold(c2, pointIds[0], ist(1, 10), 30);
      assert.equal(b2.status, 'payment_pending');
      const old = await one(`select status, payment_status from public.bookings where id = $1`, [b.id]);
      assert.deepEqual(old, { status: 'expired', payment_status: 'abandoned' });
    } finally {
      await setFee(0);
    }
  });

  test('the scheduled job expires stale holds idempotently', async () => {
    const { stationId, pointIds } = await approvedStation();
    const customer = await createUser('customer');
    const b = await insertBooking({ customer, stationId, pointId: pointIds[0], start: ist(1, 10), status: 'payment_pending', paymentStatus: 'pending', fee: 1200 });
    await sql(`update public.bookings set hold_expires_at = now() - interval '1 minute' where id = $1`, [b.id]);
    const first = await rpc('service', 'run_booking_jobs');
    assert.ok(first.expired_holds >= 1);
    const again = await rpc('service', 'run_booking_jobs');
    const events = await sql(`select to_status from public.booking_events where booking_id = $1 order by id`, [b.id]);
    assert.deepEqual(events.map((e) => e.to_status), ['payment_pending', 'expired']);
    assert.equal(typeof again.expired_holds, 'number');
  });

  test('a customer may hold at most two unpaid bookings', async () => {
    await setFee(1200);
    try {
      const { pointIds } = await approvedStation({ points: ['A', 'B', 'C'] });
      const customer = await createUser('customer');
      await hold(customer, pointIds[0], ist(1, 10), 30);
      await hold(customer, pointIds[1], ist(1, 10), 30);
      await rejectsWith(hold(customer, pointIds[2], ist(1, 10), 30), { status: 409, code: 'too_many_pending_holds' });
    } finally {
      await setFee(0);
    }
  });
});

describe('cancellation', () => {
  test('customer cancels a confirmed booking and the slot is released', async () => {
    const { pointIds, owner } = await approvedStation();
    const customer = await createUser('customer');
    const other = await createUser('customer');
    const b = await hold(customer, pointIds[0], ist(1, 10), 30);
    await rejectsWith(rpc(other.id, 'cancel_booking', [b.id, null]), { status: 404 });
    const c = await rpc(customer.id, 'cancel_booking', [b.id, 'Plans changed']);
    assert.equal(c.status, 'cancelled');
    await hold(other, pointIds[0], ist(1, 10), 30);
    await rejectsWith(rpc(customer.id, 'cancel_booking', [b.id, null]), { status: 409, code: 'not_cancellable' });
    const notes = await as(owner.id, (q) => q(`select type from public.notifications where data->>'booking_id' = $1`, [b.id]));
    assert.ok(notes.some((n) => n.type === 'booking.cancelled'));
  });

  test('business cancellation requires bookings.manage and a reason', async () => {
    const owner = await createUser('owner');
    const { pointIds, businessId, stationId } = await approvedStation({ owner });
    const staff = await createUser('staff');
    await rpc(owner.id, 'add_business_member', [businessId, staff.email, 'station_staff', null, [stationId]]);
    const customer = await createUser('customer');
    const b = await hold(customer, pointIds[0], ist(1, 10), 30);
    await rejectsWith(rpc(staff.id, 'cancel_booking', [b.id, 'Charger fault']), { status: 404 });
    await rejectsWith(rpc(owner.id, 'cancel_booking', [b.id, '']), { status: 422, code: 'reason_required' });
    const c = await rpc(owner.id, 'cancel_booking', [b.id, 'Charger fault']);
    assert.equal(c.status, 'cancelled');
  });
});

describe('check-in', () => {
  async function bookingNearNow(opts = {}) {
    const owner = await createUser('owner');
    const station = await approvedStation({ owner, points: ['A', 'B'], ...opts });
    const customer = await createUser('customer');
    const start = new Date(Math.floor(Date.now() / 60000) * 60000 + 5 * 60000);
    const b = await insertBooking({ customer, stationId: station.stationId, pointId: station.pointIds[0], start });
    return { ...station, customer, booking: b };
  }

  test('staff check in by QR payload; duplicate check-in is rejected', async () => {
    const { owner, businessId, stationId, booking } = await bookingNearNow();
    const staff = await createUser('staff');
    await rpc(owner.id, 'add_business_member', [businessId, staff.email, 'station_staff', null, [stationId]]);
    const looked = await rpc(staff.id, 'lookup_booking_for_checkin', [stationId, `CKB1:${booking.qr_token}`]);
    assert.equal(looked.reference, booking.reference);
    assert.equal(looked.customer_display_name, 'Test C.');
    assert.equal(looked.customer_id, undefined, 'customer id is not exposed');
    const res = await rpc(staff.id, 'check_in_booking', [stationId, `CKB1:${booking.qr_token}`, 'qr']);
    assert.equal(res.status, 'arrived');
    await rejectsWith(rpc(staff.id, 'check_in_booking', [stationId, booking.reference, 'reference']), { status: 409, code: 'already_checked_in' });
    const ci = await one(`select checked_in_by, method from public.check_ins where booking_id = $1`, [booking.id]);
    assert.deepEqual(ci, { checked_in_by: staff.id, method: 'qr' });
  });

  test('manual reference entry works and is case-insensitive', async () => {
    const { owner, stationId, booking } = await bookingNearNow();
    const res = await rpc(owner.id, 'check_in_booking', [stationId, booking.reference.toLowerCase(), 'reference']);
    assert.equal(res.status, 'arrived');
    const progressed = await rpc(owner.id, 'update_booking_progress', [booking.id, 'in_progress']);
    assert.equal(progressed.status, 'in_progress');
    const done = await rpc(owner.id, 'update_booking_progress', [booking.id, 'completed']);
    assert.equal(done.status, 'completed');
  });

  test('bookings of another station or business cannot be checked in', async () => {
    const { booking } = await bookingNearNow();
    const other = await approvedStation();
    await rejectsWith(rpc(other.owner.id, 'check_in_booking', [other.stationId, booking.reference, 'reference']), { status: 404 });
    await rejectsWith(rpc(other.owner.id, 'lookup_booking_for_checkin', [other.stationId, booking.reference]), { status: 404 });
  });

  test('staff not assigned to the station cannot check in', async () => {
    const owner = await createUser('owner');
    const { businessId, stationId, booking } = await bookingNearNow({ owner });
    const staff = await createUser('staff');
    await rpc(owner.id, 'add_business_member', [businessId, staff.email, 'station_staff', null, []]);
    await rejectsWith(rpc(staff.id, 'check_in_booking', [stationId, booking.reference, 'reference']), { status: 403 });
  });

  test('check-in outside the window is refused', async () => {
    const owner = await createUser('owner');
    const { stationId, pointIds } = await approvedStation({ owner, policy: { early_checkin_minutes: 15, arrival_grace_minutes: 10 } });
    const customer = await createUser('customer');
    const early = await insertBooking({ customer, stationId, pointId: pointIds[0], start: ist(1, 10) });
    await rejectsWith(rpc(owner.id, 'check_in_booking', [stationId, early.reference, 'reference']), { status: 409, code: 'too_early' });
    const late = await insertBooking({ customer, stationId, pointId: pointIds[0], start: new Date(Date.now() - 20 * 60000), minutes: 60 });
    await rejectsWith(rpc(owner.id, 'check_in_booking', [stationId, late.reference, 'reference']), { status: 409, code: 'grace_period_over' });
  });

  test('unpaid or cancelled bookings cannot be checked in', async () => {
    const owner = await createUser('owner');
    const { stationId, pointIds } = await approvedStation({ owner });
    const customer = await createUser('customer');
    const start = new Date(Date.now() + 5 * 60000);
    const pending = await insertBooking({ customer, stationId, pointId: pointIds[0], start, status: 'payment_pending', paymentStatus: 'pending', fee: 1200 });
    await rejectsWith(rpc(owner.id, 'check_in_booking', [stationId, pending.reference, 'reference']), { status: 409, code: 'booking_not_checkinable' });
  });
});

describe('no-shows', () => {
  test('no-show is refused during the grace period and allowed after it', async () => {
    const owner = await createUser('owner');
    const { stationId, pointIds } = await approvedStation({ owner, policy: { arrival_grace_minutes: 15 } });
    const customer = await createUser('customer');
    const inGrace = await insertBooking({ customer, stationId, pointId: pointIds[0], start: new Date(Date.now() - 5 * 60000), minutes: 60 });
    await rejectsWith(rpc(owner.id, 'update_booking_progress', [inGrace.id, 'no_show']), { status: 409, code: 'grace_period_active' });
    const pastGrace = await insertBooking({ customer, stationId, pointId: pointIds[0], start: ist(-1, 10), minutes: 60 });
    const res = await rpc(owner.id, 'update_booking_progress', [pastGrace.id, 'no_show']);
    assert.equal(res.status, 'no_show');
  });

  test('the job marks no-shows only after the reserved period has ended', async () => {
    const { stationId, pointIds } = await approvedStation();
    const customer = await createUser('customer');
    const ended = await insertBooking({ customer, stationId, pointId: pointIds[0], start: ist(-1, 10), minutes: 30 });
    const ongoing = await insertBooking({ customer, stationId, pointId: pointIds[0], start: new Date(Date.now() - 20 * 60000), minutes: 60 });
    await rpc('service', 'run_booking_jobs');
    assert.equal((await one(`select status from public.bookings where id = $1`, [ended.id])).status, 'no_show');
    assert.equal((await one(`select status from public.bookings where id = $1`, [ongoing.id])).status, 'confirmed');
  });
});

describe('admin overrides', () => {
  test('overrides need permission, a reason, and are audited', async () => {
    const { stationId, pointIds } = await approvedStation();
    const customer = await createUser('customer');
    const b = await insertBooking({ customer, stationId, pointId: pointIds[0], start: ist(-1, 10), minutes: 30 });
    await sql(`update public.bookings set status = 'no_show', no_show_at = now() where id = $1`, [b.id]);
    const admin = await createStaff('admin');
    await rejectsWith(rpc(admin.id, 'admin_override_booking', [b.id, 'completed', 'Customer did charge', null]), { status: 403 });
    const su = await createStaff('super_admin');
    await rejectsWith(rpc(su.id, 'admin_override_booking', [b.id, 'completed', '', null]), { status: 422 });
    const res = await rpc(su.id, 'admin_override_booking', [b.id, 'completed', 'Staff marked no-show by mistake', null]);
    assert.equal(res.status, 'completed');
    const audit = await one(`select actor_id, reason from public.audit_logs where action = 'booking.override' and entity_id = $1`, [b.id]);
    assert.equal(audit.actor_id, su.id);
    // A normal (non-override) path still cannot do this transition.
    const b2 = await insertBooking({ customer, stationId, pointId: pointIds[0], start: ist(-2, 10), minutes: 30 });
    await sql(`update public.bookings set status = 'no_show' where id = $1`, [b2.id]);
    await rejectsWith(sql(`update public.bookings set status = 'completed' where id = $1`, [b2.id]), { status: 409, code: 'invalid_status_transition' });
  });
});

describe('availability calendar', () => {
  test('busy periods expose time ranges only', async () => {
    const owner = await createUser('owner');
    const { stationId, pointIds } = await approvedStation({ owner });
    const customer = await createUser('customer');
    await hold(customer, pointIds[0], ist(1, 10), 60);
    await rpc(owner.id, 'create_blocked_period', [stationId, pointIds[0], ist(1, 14).toISOString(), ist(1, 15).toISOString(), 'maintenance', 'x', false]);
    const other = await createUser('customer');
    const rows = await as(other.id, (q) => q(`select * from public.get_point_busy_periods($1, $2, $3)`,
      [pointIds[0], ist(1, 0).toISOString(), ist(2, 0).toISOString()]));
    assert.deepEqual(rows.map((r) => r.kind), ['booking', 'maintenance']);
    assert.deepEqual(Object.keys(rows[0]).sort(), ['ends_at', 'kind', 'starts_at']);
  });
});
