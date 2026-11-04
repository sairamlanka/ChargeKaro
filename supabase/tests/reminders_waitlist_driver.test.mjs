// Reminders, waitlist and booking for someone else
// (20261104000200_reminders_waitlist_driver.sql).
import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import {
  rpc, sql, one, rejectsWith, closePool, createUser, approvedStation, setFee, insertBooking, slotStart, addMinutes, nextPhone,
} from './lib/db.mjs';

// Leave no pending SMS behind: other suites claim the shared queue in pages.
after(async () => {
  await sql(`update public.customer_messages set status = 'skipped' where status = 'pending'`);
  await closePool();
});
before(() => setFee(0));

const notes = (userId, type) => sql(`select * from public.notifications where recipient_id = $1 and type = $2`, [userId, type]);

describe('reminders', () => {
  test('30 minutes before: SMS + in-app once; a moved booking is reminded again', async () => {
    const s = await approvedStation({ points: ['A'] });
    const customer = await createUser('customer');
    await sql(`update public.profiles set phone = $2 where id = $1`, [customer.id, nextPhone()]);
    const start = new Date(Math.ceil((Date.now() + 30 * 60000) / 60000) * 60000);
    const b = await insertBooking({ customer, stationId: s.stationId, pointId: s.pointIds[0], start });
    await rpc('service', 'run_customer_reminders');
    await rpc('service', 'enqueue_booking_reminders');
    const first = await notes(customer.id, 'booking.reminder');
    assert.equal(first.length, 1, JSON.stringify(first.map((n) => n.dedupe_key)));
    const sms = await sql(`select * from public.customer_messages where booking_id = $1 and template = 'booking_reminder' and channel = 'sms'`, [b.id]);
    assert.equal(sms.length, 1);

    // Simulate a reschedule to a new start 30 minutes from now (different epoch).
    await sql(`begin; set local app.booking_reschedule = 'on';
               update public.bookings set period = tstzrange(lower(period) + interval '1 minute', upper(period) + interval '1 minute') where id = '${b.id}'; commit;`);
    await rpc('service', 'run_customer_reminders');
    assert.equal((await notes(customer.id, 'booking.reminder')).length, 2);
  });

  test('check-in open and closing soon notifications', async () => {
    const s = await approvedStation({ points: ['A', 'B', 'C'], policy: { early_checkin_minutes: 15, arrival_grace_minutes: 5 } });
    const customer = await createUser('customer');
    const minute = 60000;
    const now = Math.floor(Date.now() / minute) * minute;
    await insertBooking({ customer, stationId: s.stationId, pointId: s.pointIds[0], start: new Date(now + 15 * minute) });
    await rpc('service', 'run_customer_reminders');
    assert.equal((await notes(customer.id, 'booking.checkin_open')).length, 1);

    const other = await createUser('late');
    await insertBooking({ customer: other, stationId: s.stationId, pointId: s.pointIds[1], start: new Date(now - 30 * minute) });
    await insertBooking({ customer: other, stationId: s.stationId, pointId: s.pointIds[2], start: new Date(now) });
    await rpc('service', 'run_customer_reminders');
    const closing = await notes(other.id, 'booking.checkin_closing');
    assert.equal(closing.length, 1, 'only the booking whose window closes in ~5 minutes');
  });

  test('customers cannot run the reminder job', async () => {
    const c = await createUser('c');
    await rejectsWith(rpc(c.id, 'run_customer_reminders'), { sqlstate: '42501' });
  });
});

describe('waitlist', () => {
  test('waiting customers are told when a booking in their window is cancelled', async () => {
    const s = await approvedStation({ points: ['A'] });
    const [holder, waiter, outside] = [await createUser('holder'), await createUser('waiter'), await createUser('outside')];
    const start = slotStart(180);
    const b = await insertBooking({ customer: holder, stationId: s.stationId, pointId: s.pointIds[0], start, minutes: 60 });
    const w = await rpc(waiter.id, 'join_waitlist', [s.stationId, start.toISOString(), addMinutes(start, 120).toISOString(), 30, null]);
    assert.equal(w.active, true);
    const again = await rpc(waiter.id, 'join_waitlist', [s.stationId, start.toISOString(), addMinutes(start, 120).toISOString(), 30, null]);
    assert.equal(again.id, w.id, 'joining twice keeps one entry');
    const far = addMinutes(start, 600);
    await rpc(outside.id, 'join_waitlist', [s.stationId, far.toISOString(), addMinutes(far, 60).toISOString(), 30, null]);

    await sql(`update public.bookings set status = 'cancelled', cancelled_at = now(), cancellation_actor = 'customer' where id = $1`, [b.id]);
    const n = await notes(waiter.id, 'waitlist.slot_open');
    assert.equal(n.length, 1);
    assert.equal(new Date(n[0].data.start_at).getTime(), start.getTime());
    assert.equal((await notes(outside.id, 'waitlist.slot_open')).length, 0);
    const mine = await rpc(waiter.id, 'get_my_waitlist');
    assert.ok(mine[0].notified_at);
  });

  test('no notice when another point is still busy; limits and validation', async () => {
    const s = await approvedStation({ points: ['A'] });
    const [a, waiter] = [await createUser('a'), await createUser('waiter')];
    const start = slotStart(180);
    const b = await insertBooking({ customer: a, stationId: s.stationId, pointId: s.pointIds[0], start, minutes: 30 });
    // Wants 60 minutes but only 30 are freed and the next 30 are booked.
    await insertBooking({ customer: await createUser('next'), stationId: s.stationId, pointId: s.pointIds[0], start: addMinutes(start, 30), minutes: 30 });
    await rpc(waiter.id, 'join_waitlist', [s.stationId, start.toISOString(), addMinutes(start, 60).toISOString(), 60, null]);
    await sql(`update public.bookings set status = 'cancelled', cancelled_at = now(), cancellation_actor = 'customer' where id = $1`, [b.id]);
    assert.equal((await notes(waiter.id, 'waitlist.slot_open')).length, 0);

    await rejectsWith(rpc(waiter.id, 'join_waitlist', [s.stationId, start.toISOString(), addMinutes(start, 20).toISOString(), 30, null]),
      { status: 422, code: 'invalid_waitlist_window' });
    for (let i = 1; i <= 4; i++) {
      const t = addMinutes(start, i * 120);
      await rpc(waiter.id, 'join_waitlist', [s.stationId, t.toISOString(), addMinutes(t, 60).toISOString(), 30, null]);
    }
    const t6 = addMinutes(start, 1000);
    await rejectsWith(rpc(waiter.id, 'join_waitlist', [s.stationId, t6.toISOString(), addMinutes(t6, 60).toISOString(), 30, null]),
      { status: 409, code: 'waitlist_limit' });
    const list = await rpc(waiter.id, 'get_my_waitlist');
    await rpc(waiter.id, 'leave_waitlist', [list[0].id]);
    await rejectsWith(rpc(a.id, 'leave_waitlist', [list[1].id]), { status: 404 });
  });
});

describe('booking for someone else', () => {
  test('driver name shows to staff, driver phone gets the confirmation; switching back clears it', async () => {
    const s = await approvedStation({ points: ['A'] });
    const me = await createUser('me');
    await sql(`update public.profiles set full_name = 'Sai Ram' where id = $1`, [me.id]);
    const b = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start: slotStart(120) });
    const r = await rpc(me.id, 'set_booking_driver', [b.id, 'Ravi Kumar', '98765 43210']);
    assert.equal(r.customer_display_name, 'Ravi Kumar');
    assert.equal(r.driver_phone, '+919876543210');
    assert.equal(r.booked_for_other, true);
    const sms = await sql(`select destination, payload from public.customer_messages where booking_id = $1 and destination = '+919876543210'`, [b.id]);

    assert.equal(sms.length, 1);
    assert.equal(sms[0].payload.customer_name, 'Ravi Kumar');

    const back = await rpc(me.id, 'set_booking_driver', [b.id, null, null]);
    assert.equal(back.customer_display_name, 'Sai Ram');
    assert.equal(back.driver_phone, null);
    await rejectsWith(rpc(me.id, 'set_booking_driver', [b.id, 'X', '12345']), { status: 422, code: 'invalid_phone' });
    const stranger = await createUser('stranger');
    await rejectsWith(rpc(stranger.id, 'set_booking_driver', [b.id, 'X', null]), { status: 404 });
  });

  test('driver set while unpaid gets the SMS when payment confirms', async () => {
    const s = await approvedStation({ points: ['A'] });
    const me = await createUser('me');
    const b = await insertBooking({ customer: me, stationId: s.stationId, pointId: s.pointIds[0], start: slotStart(120), status: 'payment_pending', paymentStatus: 'pending' });
    const phone = nextPhone();
    await rpc(me.id, 'set_booking_driver', [b.id, 'Fleet Driver 7', phone]);
    const driverSms = () => sql(`select 1 from public.customer_messages where booking_id = $1 and destination = $2`, [b.id, phone]);
    assert.equal((await driverSms()).length, 0);
    await sql(`update public.bookings set status = 'confirmed', payment_status = 'paid', confirmed_at = now(), hold_expires_at = null where id = $1`, [b.id]);
    assert.equal((await driverSms()).length, 1);
  });
});
