import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import {
  as, rpc, sql, one, rejectsWith, closePool, createUser, createStaff, approvedStation, hold, setFee, ist,
} from './lib/db.mjs';

after(async () => {
  await setFee(0);
  await closePool();
});
before(() => setFee(1200));

const orderId = () => `order_${randomUUID().replaceAll('-', '').slice(0, 14)}`;
const payId = () => `pay_${randomUUID().replaceAll('-', '').slice(0, 14)}`;

/** Customer holds a slot and the Edge Function creates a gateway order for it. */
async function pendingBookingWithOrder(station) {
  station ??= await approvedStation();
  const customer = await createUser('customer');
  const booking = await hold(customer, station.pointIds[0], ist(1, 10 + Math.floor(Math.random() * 8)), 30);
  const prepared = await rpc('service', 'prepare_payment_order', [booking.id, customer.id]);
  const gatewayOrderId = orderId();
  await rpc('service', 'record_payment_order', [booking.id, gatewayOrderId, prepared.amount_paise, 'INR', prepared.receipt]);
  return { station, customer, booking, gatewayOrderId, prepared };
}

const capture = (order, pay, amount = 1200, fee = 28, tax = 4) =>
  rpc('service', 'record_gateway_payment', [order, pay, amount, 'INR', 'captured', 'upi', fee, tax, null, null, new Date().toISOString()]);

describe('order creation', () => {
  test('the amount comes from the booking, not the client', async () => {
    const { prepared, booking } = await pendingBookingWithOrder();
    assert.equal(prepared.amount_paise, 1200);
    assert.equal(prepared.receipt, booking.reference);
    await rejectsWith(rpc('service', 'record_payment_order', [booking.id, orderId(), 100, 'INR', 'x']), { status: 422, code: 'amount_mismatch' });
  });

  test('only the booking customer can prepare an order, and only while the hold is valid', async () => {
    const { booking } = await pendingBookingWithOrder();
    const stranger = await createUser('customer');
    await rejectsWith(rpc('service', 'prepare_payment_order', [booking.id, stranger.id]), { status: 404 });
    await sql(`update public.bookings set hold_expires_at = now() - interval '1 second' where id = $1`, [booking.id]);
    await rejectsWith(rpc('service', 'prepare_payment_order', [booking.id, (await one(`select customer_id from bookings where id=$1`, [booking.id])).customer_id]),
      { status: 409, code: 'hold_expired' });
  });

  test('clients cannot call payment-recording functions', async () => {
    const { customer, gatewayOrderId } = await pendingBookingWithOrder();
    await rejectsWith(rpc(customer.id, 'record_gateway_payment', [gatewayOrderId, payId(), 1200, 'INR', 'captured', 'upi', 0, 0, null, null, new Date().toISOString()]),
      { sqlstate: '42501' });
    await rejectsWith(rpc(customer.id, 'record_refund_result', [null, 'rfnd_x', 'pay_x', 1200, 'processed', null, new Date().toISOString()]),
      { sqlstate: '42501' });
    await rejectsWith(as(customer.id, (q) => q(`insert into public.payments (payment_order_id, booking_id, gateway_payment_id, amount_paise, currency, status, captured_at)
                                                 select id, booking_id, 'pay_fake', 1200, 'INR', 'captured', now() from public.payment_orders limit 1`)),
      { sqlstate: '42501' });
    await rejectsWith(as(customer.id, (q) => q(`insert into public.ledger_entries (entry_type, amount_paise, occurred_at, source_key) values ('booking_fee_collected', 1200, now(), 'fake')`)),
      { sqlstate: '42501' });
  });
});

describe('payment outcomes', () => {
  test('successful payment confirms the booking and posts gross + fee ledger entries', async () => {
    const { booking, gatewayOrderId, station } = await pendingBookingWithOrder();
    const p = payId();
    const res = await capture(gatewayOrderId, p);
    assert.equal(res.result, 'confirmed');
    const b = await one(`select status, payment_status, hold_expires_at from public.bookings where id = $1`, [booking.id]);
    assert.deepEqual(b, { status: 'confirmed', payment_status: 'paid', hold_expires_at: null });
    const ledger = await sql(`select entry_type, amount_paise from public.ledger_entries where booking_id = $1 order by entry_type`, [booking.id]);
    assert.deepEqual(ledger, [
      { entry_type: 'booking_fee_collected', amount_paise: 1200 },
      { entry_type: 'gateway_fee', amount_paise: -24 },
      { entry_type: 'gateway_fee_tax', amount_paise: -4 },
    ]);
    const ownerNotes = await as(station.owner.id, (q) => q(`select type from public.notifications where data->>'booking_id' = $1`, [booking.id]));
    assert.ok(ownerNotes.some((n) => n.type === 'booking.confirmed'));
  });

  test('duplicate verify + webhook deliveries are processed once', async () => {
    const { booking, gatewayOrderId } = await pendingBookingWithOrder();
    const p = payId();
    const results = await Promise.all([capture(gatewayOrderId, p), capture(gatewayOrderId, p), capture(gatewayOrderId, p)]);
    assert.equal(results.filter((r) => r.result === 'confirmed').length, 1);
    assert.equal(results.filter((r) => r.result === 'duplicate').length, 2);
    const n = await one(`select count(*)::int n from public.ledger_entries where booking_id = $1 and entry_type = 'booking_fee_collected'`, [booking.id]);
    assert.equal(n.n, 1);
    const events = await sql(`select to_status from public.booking_events where booking_id = $1 order by id`, [booking.id]);
    assert.deepEqual(events.map((e) => e.to_status), ['payment_pending', 'confirmed']);
  });

  test('fee details arriving later (capture webhook) are added once', async () => {
    const { booking, gatewayOrderId } = await pendingBookingWithOrder();
    const p = payId();
    await rpc('service', 'record_gateway_payment', [gatewayOrderId, p, 1200, 'INR', 'captured', 'card', null, null, null, null, new Date().toISOString()]);
    assert.equal((await sql(`select 1 from public.ledger_entries where booking_id = $1`, [booking.id])).length, 1);
    await capture(gatewayOrderId, p, 1200, 30, 5);
    await capture(gatewayOrderId, p, 1200, 30, 5);
    const fees = await sql(`select entry_type, amount_paise from public.ledger_entries where booking_id = $1 and entry_type <> 'booking_fee_collected' order by 1`, [booking.id]);
    assert.deepEqual(fees, [{ entry_type: 'gateway_fee', amount_paise: -25 }, { entry_type: 'gateway_fee_tax', amount_paise: -5 }]);
  });

  test('failed payment leaves the booking pending for retry and records no revenue', async () => {
    const { booking, gatewayOrderId, customer } = await pendingBookingWithOrder();
    const res = await rpc('service', 'record_gateway_payment', [gatewayOrderId, payId(), 1200, 'INR', 'failed', 'card', null, null, 'BAD_REQUEST_ERROR', 'Card declined', new Date().toISOString()]);
    assert.equal(res.result, 'failed_recorded');
    const b = await one(`select status, payment_status from public.bookings where id = $1`, [booking.id]);
    assert.deepEqual(b, { status: 'payment_pending', payment_status: 'failed' });
    assert.equal((await sql(`select 1 from public.ledger_entries where booking_id = $1`, [booking.id])).length, 0);
    // Retry with a new order succeeds.
    const prepared = await rpc('service', 'prepare_payment_order', [booking.id, customer.id]);
    const second = orderId();
    await rpc('service', 'record_payment_order', [booking.id, second, prepared.amount_paise, 'INR', prepared.receipt]);
    assert.equal((await one(`select payment_status from public.bookings where id = $1`, [booking.id])).payment_status, 'pending');
    assert.equal((await capture(second, payId())).result, 'confirmed');
  });

  test('a stale failure event after success does not undo the payment', async () => {
    const { booking, gatewayOrderId } = await pendingBookingWithOrder();
    const p = payId();
    await capture(gatewayOrderId, p);
    const res = await rpc('service', 'record_gateway_payment', [gatewayOrderId, p, 1200, 'INR', 'failed', null, null, null, 'X', 'late', new Date().toISOString()]);
    assert.equal(res.result, 'duplicate');
    assert.equal((await one(`select payment_status from public.bookings where id = $1`, [booking.id])).payment_status, 'paid');
  });

  test('mismatched amount is recorded, not confirmed, and refunded automatically', async () => {
    const { booking, gatewayOrderId } = await pendingBookingWithOrder();
    const res = await capture(gatewayOrderId, payId(), 100, 2, 0);
    assert.equal(res.result, 'refund_initiated');
    assert.equal(res.reason, 'amount_mismatch');
    const b = await one(`select status, payment_status from public.bookings where id = $1`, [booking.id]);
    assert.equal(b.status, 'payment_pending');
    const r = await one(`select amount_paise, status, is_automatic from public.refunds where booking_id = $1`, [booking.id]);
    assert.deepEqual(r, { amount_paise: 100, status: 'requested', is_automatic: true });
  });

  test('delayed payment after hold expiry revives the booking when the slot is still free', async () => {
    const { booking, gatewayOrderId } = await pendingBookingWithOrder();
    await sql(`update public.bookings set hold_expires_at = now() - interval '1 minute' where id = $1`, [booking.id]);
    await rpc('service', 'run_booking_jobs');
    assert.equal((await one(`select status from public.bookings where id = $1`, [booking.id])).status, 'expired');
    const res = await capture(gatewayOrderId, payId());
    assert.equal(res.result, 'revived');
    assert.equal((await one(`select status, payment_status from public.bookings where id = $1`, [booking.id])).status, 'confirmed');
  });

  test('delayed payment after the slot was re-booked is refunded under the policy', async () => {
    const station = await approvedStation();
    const { booking, gatewayOrderId } = await pendingBookingWithOrder(station);
    await sql(`update public.bookings set hold_expires_at = now() - interval '1 minute' where id = $1`, [booking.id]);
    const other = await createUser('customer');
    const start = await one(`select lower(period) s from public.bookings where id = $1`, [booking.id]);
    await hold(other, station.pointIds[0], start.s, 30);
    const res = await capture(gatewayOrderId, payId());
    assert.equal(res.result, 'refund_initiated');
    assert.equal(res.reason, 'slot_lost');
    const b = await one(`select status, payment_status from public.bookings where id = $1`, [booking.id]);
    assert.deepEqual(b, { status: 'expired', payment_status: 'refund_pending' });
  });

  test('a second payment for an already paid booking is refunded', async () => {
    const { booking, customer, gatewayOrderId } = await pendingBookingWithOrder();
    // Customer opened two checkouts (two orders) and paid both.
    const second = orderId();
    await rpc('service', 'record_payment_order', [booking.id, second, 1200, 'INR', booking.reference]);
    await capture(gatewayOrderId, payId());
    const res = await capture(second, payId());
    assert.equal(res.result, 'refund_initiated');
    assert.equal(res.reason, 'duplicate_payment');
    assert.ok(customer);
  });
});

describe('refunds', () => {
  test('policy: customer cancellation keeps the fee; business cancellation refunds it', async () => {
    const station = await approvedStation();
    const a = await pendingBookingWithOrder(station);
    await capture(a.gatewayOrderId, payId());
    const cancelled = await rpc(a.customer.id, 'cancel_booking', [a.booking.id, 'changed plans']);
    assert.equal(cancelled.payment_status, 'paid');
    assert.equal((await sql(`select 1 from public.refunds where booking_id = $1`, [a.booking.id])).length, 0);

    const b = await pendingBookingWithOrder(station);
    await capture(b.gatewayOrderId, payId());
    const byOwner = await rpc(station.owner.id, 'cancel_booking', [b.booking.id, 'Charger fault']);
    assert.equal(byOwner.payment_status, 'refund_pending');
    const r = await one(`select amount_paise, status from public.refunds where booking_id = $1`, [b.booking.id]);
    assert.deepEqual(r, { amount_paise: 1200, status: 'requested' });
  });

  test('refund processing is claimed once and recorded idempotently in the ledger', async () => {
    const station = await approvedStation();
    const { booking, gatewayOrderId } = await pendingBookingWithOrder(station);
    const p = payId();
    await capture(gatewayOrderId, p);
    await rpc(station.owner.id, 'cancel_booking', [booking.id, 'Station closed']);
    const claims = await Promise.all([
      as('service', (q) => q(`select * from public.claim_refunds(50)`)),
      as('service', (q) => q(`select * from public.claim_refunds(50)`)),
    ]);
    const mine = claims.flat().filter((c) => c.gateway_payment_id === p);
    assert.equal(mine.length, 1, 'only one worker claims the refund');
    const refundId = mine[0].refund_id;
    await rpc('service', 'record_refund_result', [refundId, 'rfnd_' + p, p, 1200, 'processed', null, new Date().toISOString()]);
    // Webhook for the same refund arrives later.
    const dup = await rpc('service', 'record_refund_result', [null, 'rfnd_' + p, p, 1200, 'processed', null, new Date().toISOString()]);
    assert.equal(dup.result, 'duplicate');
    const ledger = await sql(`select amount_paise from public.ledger_entries where booking_id = $1 and entry_type = 'booking_fee_refunded'`, [booking.id]);
    assert.deepEqual(ledger, [{ amount_paise: -1200 }]);
    assert.equal((await one(`select payment_status from public.bookings where id = $1`, [booking.id])).payment_status, 'refunded');
  });

  test('manual refunds need finance.refunds.issue, a reason, and cannot exceed the payment', async () => {
    const k1 = `refund-${randomUUID()}`;
    const k2 = `refund-${randomUUID()}`;
    const { booking, gatewayOrderId } = await pendingBookingWithOrder();
    await capture(gatewayOrderId, payId());
    const admin = await createStaff('admin');
    await rejectsWith(rpc(admin.id, 'issue_refund', [booking.id, 1200, 'Goodwill refund', k1]), { status: 403 });
    const finance = await createStaff('admin', { 'finance.refunds.issue': true });
    await rejectsWith(rpc(finance.id, 'issue_refund', [booking.id, 1200, '', k1]), { status: 422 });
    await rejectsWith(rpc(finance.id, 'issue_refund', [booking.id, 1300, 'Goodwill refund', k1]), { status: 422, code: 'refund_exceeds_payment' });
    const id1 = await rpc(finance.id, 'issue_refund', [booking.id, 600, 'Goodwill refund', k1]);
    const id2 = await rpc(finance.id, 'issue_refund', [booking.id, 600, 'Goodwill refund', k1]);
    assert.equal(id1, id2, 'same idempotency key, same refund');
    await rejectsWith(rpc(finance.id, 'issue_refund', [booking.id, 500, 'Goodwill refund', k1]), { status: 409, code: 'idempotency_key_reused' });
    await rejectsWith(rpc(finance.id, 'issue_refund', [booking.id, 700, 'Second refund', k2]), { status: 422, code: 'refund_exceeds_payment' });
    const audit = await one(`select actor_id from public.audit_logs where action = 'refund.issue' and entity_id = $1`, [id1]);
    assert.equal(audit.actor_id, finance.id);
  });

  test('refunds created in the gateway dashboard are recorded from the webhook', async () => {
    const { booking, gatewayOrderId } = await pendingBookingWithOrder();
    const p = payId();
    await capture(gatewayOrderId, p);
    const res = await rpc('service', 'record_refund_result', [null, 'rfnd_dash_' + p, p, 1200, 'processed', null, new Date().toISOString()]);
    assert.equal(res.result, 'processed');
    const r = await one(`select reason, is_automatic from public.refunds where booking_id = $1`, [booking.id]);
    assert.equal(r.is_automatic, false);
    assert.match(r.reason, /dashboard/);
  });
});

describe('webhook idempotency', () => {
  test('an event id is processed once', async () => {
    const id = `evt_${randomUUID()}`;
    assert.equal(await rpc('service', 'record_webhook_event', [id, 'payment.captured', { a: 1 }]), true);
    assert.equal(await rpc('service', 'record_webhook_event', [id, 'payment.captured', { a: 1 }]), false);
    await rpc('service', 'complete_webhook_event', [id, 'processed', null]);
    assert.equal(await rpc('service', 'record_webhook_event', [id, 'payment.captured', { a: 1 }]), false);
  });
});

describe('immutability', () => {
  test('ledger and audit entries cannot be modified, even by the service role', async () => {
    const { gatewayOrderId } = await pendingBookingWithOrder();
    await capture(gatewayOrderId, payId());
    await rejectsWith(as('service', (q) => q(`update public.ledger_entries set amount_paise = 1 where id = (select max(id) from public.ledger_entries)`)),
      { status: 403, code: 'immutable_record' });
    await rejectsWith(as('service', (q) => q(`delete from public.ledger_entries where id = (select max(id) from public.ledger_entries)`)),
      { status: 403, code: 'immutable_record' });
    await rejectsWith(sql(`delete from public.audit_logs where id = (select max(id) from public.audit_logs)`), { status: 403, code: 'immutable_record' });
    await rejectsWith(sql(`update public.booking_events set note = 'x' where id = (select max(id) from public.booking_events)`), { status: 403, code: 'immutable_record' });
  });
});
