import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1.0.13';
import { createOrder, handleWebhook, processRefunds, verifyPayment } from '../_shared/payments.ts';
import { dispatchNotifications, type PushSender } from '../_shared/fcm.ts';
import { GatewayError, hmacSha256Hex, type PaymentGateway, type RazorpayPayment, type RazorpayRefund, verifyPaymentSignature, verifyWebhookSignature } from '../_shared/razorpay.ts';
import { HttpError } from '../_shared/http.ts';
import type { Db } from '../_shared/db.ts';

const BOOKING = '11111111-1111-4111-8111-111111111111';
const USER = '22222222-2222-4222-8222-222222222222';
const KEY_SECRET = 'test_key_secret';
const WEBHOOK_SECRET = 'test_webhook_secret';

type Call = { fn: string; args: Record<string, unknown> };

function fakeDb(handlers: Record<string, (args: Record<string, unknown>) => unknown> = {}, owner = { booking_id: BOOKING, customer_id: USER }) {
  const calls: Call[] = [];
  const db: Db = {
    rpc<T>(fn: string, args: Record<string, unknown> = {}) {
      calls.push({ fn, args });
      const h = handlers[fn];
      try {
        return Promise.resolve((h ? h(args) : null) as T);
      } catch (e) {
        return Promise.reject(e);
      }
    },
    orderOwner: () => Promise.resolve(owner),
  };
  return { db, calls };
}

function fakeGateway(overrides: Partial<PaymentGateway> = {}): PaymentGateway & { created: unknown[] } {
  const created: unknown[] = [];
  return {
    keyId: 'rzp_test_key',
    created,
    createOrder: (input) => {
      created.push(input);
      return Promise.resolve({ id: 'order_ABC123456', amount: input.amount, currency: input.currency, receipt: input.receipt, status: 'created' });
    },
    fetchPayment: (id) => Promise.resolve(payment({ id })),
    listRefunds: () => Promise.resolve([]),
    createRefund: (paymentId, input) => Promise.resolve({ id: 'rfnd_NEW123456', payment_id: paymentId, amount: input.amount, status: 'processed', notes: input.notes, created_at: 0 }),
    ...overrides,
  };
}

const payment = (p: Partial<RazorpayPayment> = {}): RazorpayPayment => ({
  id: 'pay_XYZ123456',
  order_id: 'order_ABC123456',
  amount: 1200,
  currency: 'INR',
  status: 'captured',
  method: 'upi',
  fee: 28,
  tax: 4,
  created_at: 1_760_000_000,
  ...p,
});

const prepared = (existing: string | null = null) => ({
  booking_id: BOOKING,
  amount_paise: 1200,
  currency: 'INR',
  receipt: 'CKABCDEFGHJK',
  hold_expires_at: '2026-10-21T10:00:00Z',
  existing_gateway_order_id: existing,
});

Deno.test('signatures: checkout and webhook HMACs verify and reject tampering', async () => {
  // Reference value computed independently with Node crypto: HMAC_SHA256("order_1|pay_1", "secret").
  const sig = await hmacSha256Hex('secret', 'order_1|pay_1');
  assertEquals(sig, '52115a0d3400de9e86aade1f1b6eba9e8974604f4e267a9e9a16633a4c8dd2cb');
  assert(await verifyPaymentSignature('order_1', 'pay_1', sig, 'secret'));
  assert(!(await verifyPaymentSignature('order_1', 'pay_2', sig, 'secret')));
  assert(!(await verifyPaymentSignature('order_1', 'pay_1', sig, 'other')));
  assert(!(await verifyPaymentSignature('order_1', 'pay_1', '', 'secret')));
  const body = '{"event":"payment.captured"}';
  const wsig = await hmacSha256Hex(WEBHOOK_SECRET, body);
  assert(await verifyWebhookSignature(body, wsig, WEBHOOK_SECRET));
  assert(!(await verifyWebhookSignature(body + ' ', wsig, WEBHOOK_SECRET)));
  assert(!(await verifyWebhookSignature(body, null, WEBHOOK_SECRET)));
});

Deno.test('createOrder: amount comes from the database and the order is recorded', async () => {
  const { db, calls } = fakeDb({ prepare_payment_order: () => prepared() });
  const gateway = fakeGateway();
  const res = await createOrder({ db, gateway }, USER, BOOKING);
  assertEquals(res.amount_paise, 1200);
  assertEquals(res.order_id, 'order_ABC123456');
  assertEquals(gateway.created, [{ amount: 1200, currency: 'INR', receipt: 'CKABCDEFGHJK', notes: { booking_id: BOOKING } }]);
  assertEquals(calls.map((c) => c.fn), ['prepare_payment_order', 'record_payment_order']);
  assertEquals(calls[0].args, { p_booking_id: BOOKING, p_customer_id: USER });
});

Deno.test('createOrder: reuses an open order instead of creating another', async () => {
  const { db } = fakeDb({ prepare_payment_order: () => prepared('order_EXISTING01') });
  const gateway = fakeGateway();
  const res = await createOrder({ db, gateway }, USER, BOOKING);
  assertEquals(res.order_id, 'order_EXISTING01');
  assertEquals(gateway.created.length, 0);
});

Deno.test('createOrder: rejects malformed ids and gateway amount mismatches', async () => {
  const { db } = fakeDb({ prepare_payment_order: () => prepared() });
  await assertRejects(() => createOrder({ db, gateway: fakeGateway() }, USER, 'not-a-uuid'), HttpError, 'invalid_booking_id');
  const badGateway = fakeGateway({
    createOrder: (i) => Promise.resolve({ id: 'order_X1234567', amount: 1, currency: i.currency, receipt: i.receipt, status: 'created' }),
  });
  await assertRejects(() => createOrder({ db, gateway: badGateway }, USER, BOOKING), HttpError);
});

Deno.test('verifyPayment: invalid signature is rejected before anything is recorded', async () => {
  const { db, calls } = fakeDb();
  const err = await assertRejects(() =>
    verifyPayment({ db, gateway: fakeGateway(), keySecret: KEY_SECRET }, USER, {
      razorpay_order_id: 'order_ABC123456',
      razorpay_payment_id: 'pay_XYZ123456',
      razorpay_signature: 'deadbeef',
    }), HttpError);
  assertEquals((err as HttpError).code, 'invalid_signature');
  assertEquals(calls.length, 0);
});

Deno.test('verifyPayment: another user cannot verify someone else\'s order', async () => {
  const { db } = fakeDb({}, { booking_id: BOOKING, customer_id: 'someone-else' });
  const signature = await hmacSha256Hex(KEY_SECRET, 'order_ABC123456|pay_XYZ123456');
  await assertRejects(() =>
    verifyPayment({ db, gateway: fakeGateway(), keySecret: KEY_SECRET }, USER, {
      razorpay_order_id: 'order_ABC123456',
      razorpay_payment_id: 'pay_XYZ123456',
      razorpay_signature: signature,
    }), HttpError, 'payment_order_not_found');
});

Deno.test('verifyPayment: records the gateway\'s view of the payment, not the client\'s', async () => {
  const { db, calls } = fakeDb({ record_gateway_payment: () => ({ result: 'confirmed' }) });
  const signature = await hmacSha256Hex(KEY_SECRET, 'order_ABC123456|pay_XYZ123456');
  const gateway = fakeGateway({ fetchPayment: (id) => Promise.resolve(payment({ id, amount: 1200, fee: 30, tax: 5 })) });
  const res = await verifyPayment({ db, gateway, keySecret: KEY_SECRET }, USER, {
    razorpay_order_id: 'order_ABC123456',
    razorpay_payment_id: 'pay_XYZ123456',
    razorpay_signature: signature,
  });
  assertEquals(res, { booking_id: BOOKING, result: 'confirmed' });
  const rec = calls.find((c) => c.fn === 'record_gateway_payment')!;
  assertEquals(rec.args.p_amount_paise, 1200);
  assertEquals(rec.args.p_fee_paise, 30);
  assertEquals(rec.args.p_status, 'captured');
});

Deno.test('verifyPayment: payment from a different order is rejected', async () => {
  const { db } = fakeDb();
  const signature = await hmacSha256Hex(KEY_SECRET, 'order_ABC123456|pay_XYZ123456');
  const gateway = fakeGateway({ fetchPayment: (id) => Promise.resolve(payment({ id, order_id: 'order_OTHER0001' })) });
  await assertRejects(() =>
    verifyPayment({ db, gateway, keySecret: KEY_SECRET }, USER, {
      razorpay_order_id: 'order_ABC123456',
      razorpay_payment_id: 'pay_XYZ123456',
      razorpay_signature: signature,
    }), HttpError);
});

async function signedWebhook(event: unknown, eventId = 'evt_1') {
  const raw = JSON.stringify(event);
  const headers = new Headers({ 'x-razorpay-signature': await hmacSha256Hex(WEBHOOK_SECRET, raw), 'x-razorpay-event-id': eventId });
  return { raw, headers };
}

Deno.test('webhook: invalid signature is refused', async () => {
  const { db, calls } = fakeDb();
  const { raw } = await signedWebhook({ event: 'payment.captured' });
  await assertRejects(() => handleWebhook({ db, webhookSecret: WEBHOOK_SECRET }, raw, new Headers({ 'x-razorpay-signature': 'bad' })), HttpError, 'invalid_signature');
  assertEquals(calls.length, 0);
});

Deno.test('webhook: payment.captured is recorded and contact data is not stored', async () => {
  const { db, calls } = fakeDb({ record_webhook_event: () => true, record_gateway_payment: () => ({ result: 'confirmed' }) });
  const { raw, headers } = await signedWebhook({
    event: 'payment.captured',
    created_at: 1_760_000_100,
    payload: { payment: { entity: { ...payment(), email: 'a@b.com', contact: '+919999999999' } } },
  });
  const res = await handleWebhook({ db, webhookSecret: WEBHOOK_SECRET }, raw, headers);
  assertEquals(res.status, 'processed');
  const stored = JSON.stringify(calls.find((c) => c.fn === 'record_webhook_event')!.args.p_payload);
  assert(!stored.includes('a@b.com') && !stored.includes('+9199'));
  assertEquals(calls.map((c) => c.fn), ['record_webhook_event', 'record_gateway_payment', 'complete_webhook_event']);
});

Deno.test('webhook: duplicate delivery is acknowledged without reprocessing', async () => {
  const { db, calls } = fakeDb({ record_webhook_event: () => false });
  const { raw, headers } = await signedWebhook({ event: 'payment.captured', payload: { payment: { entity: payment() } } });
  const res = await handleWebhook({ db, webhookSecret: WEBHOOK_SECRET }, raw, headers);
  assertEquals(res.status, 'duplicate');
  assertEquals(calls.map((c) => c.fn), ['record_webhook_event']);
});

Deno.test('webhook: orders from other products are ignored, not failed', async () => {
  const { db, calls } = fakeDb({
    record_webhook_event: () => true,
    record_gateway_payment: () => {
      throw new HttpError(404, 'payment_order_not_found');
    },
  });
  const { raw, headers } = await signedWebhook({ event: 'payment.captured', payload: { payment: { entity: payment() } } });
  assertEquals((await handleWebhook({ db, webhookSecret: WEBHOOK_SECRET }, raw, headers)).status, 'ignored');
  assertEquals(calls.at(-1)!.args.p_status, 'ignored');
});

Deno.test('webhook: processing errors mark the event failed and surface for retry', async () => {
  const { db, calls } = fakeDb({
    record_webhook_event: () => true,
    record_gateway_payment: () => {
      throw new Error('db down');
    },
  });
  const { raw, headers } = await signedWebhook({ event: 'payment.failed', payload: { payment: { entity: payment({ status: 'failed' }) } } });
  await assertRejects(() => handleWebhook({ db, webhookSecret: WEBHOOK_SECRET }, raw, headers));
  assertEquals(calls.at(-1)!.args.p_status, 'failed');
});

Deno.test('webhook: refund.processed carries our refund id from notes', async () => {
  const refundId = '33333333-3333-4333-8333-333333333333';
  const { db, calls } = fakeDb({ record_webhook_event: () => true, record_refund_result: () => ({ result: 'processed' }) });
  const { raw, headers } = await signedWebhook({
    event: 'refund.processed',
    payload: { refund: { entity: { id: 'rfnd_1', payment_id: 'pay_1', amount: 1200, status: 'processed', notes: { refund_id: refundId } } } },
  });
  await handleWebhook({ db, webhookSecret: WEBHOOK_SECRET }, raw, headers);
  const rec = calls.find((c) => c.fn === 'record_refund_result')!;
  assertEquals(rec.args.p_refund_id, refundId);
  assertEquals(rec.args.p_status, 'processed');
});

Deno.test('refund worker: reuses a refund that already reached the gateway', async () => {
  const refundId = '44444444-4444-4444-8444-444444444444';
  const { db, calls } = fakeDb({
    claim_refunds: () => [{ refund_id: refundId, gateway_payment_id: 'pay_1', amount_paise: 1200, idempotency_key: 'k', reason: 'r' }],
    record_refund_result: () => ({}),
  });
  let createdCount = 0;
  const existing: RazorpayRefund = { id: 'rfnd_EXISTING', payment_id: 'pay_1', amount: 1200, status: 'processed', notes: { refund_id: refundId }, created_at: 0 };
  const gateway = fakeGateway({
    listRefunds: () => Promise.resolve([existing]),
    createRefund: () => {
      createdCount++;
      return Promise.resolve(existing);
    },
  });
  const summary = await processRefunds({ db, gateway });
  assertEquals(createdCount, 0);
  assertEquals(summary.submitted, 1);
  assertEquals(calls.find((c) => c.fn === 'record_refund_result')!.args.p_gateway_refund_id, 'rfnd_EXISTING');
});

Deno.test('refund worker: permanent gateway rejection is recorded as failed; transient errors retry later', async () => {
  const claims = [
    { refund_id: '55555555-5555-4555-8555-555555555555', gateway_payment_id: 'pay_A', amount_paise: 1200, idempotency_key: 'a', reason: 'r' },
    { refund_id: '66666666-6666-4666-8666-666666666666', gateway_payment_id: 'pay_B', amount_paise: 1200, idempotency_key: 'b', reason: 'r' },
  ];
  const { db, calls } = fakeDb({ claim_refunds: () => claims, record_refund_result: () => ({}) });
  const gateway = fakeGateway({
    createRefund: (pid) => Promise.reject(pid === 'pay_A' ? new GatewayError(400, 'BAD_REQUEST_ERROR', 'fully refunded') : new GatewayError(503, 'SERVER_ERROR', 'down')),
  });
  const summary = await processRefunds({ db, gateway });
  assertEquals(summary, { claimed: 2, submitted: 0, failed: 1, retry_later: 1 });
  const recorded = calls.filter((c) => c.fn === 'record_refund_result');
  assertEquals(recorded.length, 1);
  assertEquals(recorded[0].args.p_status, 'failed');
});

Deno.test('push dispatch: skips users without devices and revokes invalid tokens', async () => {
  const { db, calls } = fakeDb({
    claim_push_notifications: () => [
      { notification_id: 'n1', title: 't', body: 'b', data: { booking_id: 'x' }, tokens: [] },
      { notification_id: 'n2', title: 't', body: 'b', data: {}, tokens: ['good', 'stale'] },
      { notification_id: 'n3', title: 't', body: 'b', data: {}, tokens: ['flaky'] },
    ],
    complete_push_notification: () => null,
  });
  const sender: PushSender = {
    send: (t) => Promise.resolve(t === 'good' ? 'sent' : t === 'stale' ? 'invalid_token' : 'retry'),
  };
  const summary = await dispatchNotifications({ db, sender });
  assertEquals(summary, { claimed: 3, sent: 1, skipped: 1, failed: 0, retry: 1 });
  const done = calls.filter((c) => c.fn === 'complete_push_notification');
  assertEquals(done.map((c) => c.args.p_status), ['skipped', 'sent', 'pending']);
  assertEquals(done[1].args.p_invalid_tokens, ['stale']);
});
