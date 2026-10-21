// Booking-fee payment handlers. Pure functions over injected ports (Db,
// PaymentGateway) so the full flow is unit-tested without network access.
//
// Trust rules
//   * The amount always comes from the database (set when the hold was made).
//   * A client-reported success is never trusted: the checkout signature is
//     verified AND the payment is re-fetched from Razorpay before recording.
//   * Webhooks are verified with the webhook secret and de-duplicated by
//     event id; recording functions are idempotent per gateway payment id.

import type { Db } from './db.ts';
import { HttpError } from './http.ts';
import { log } from './log.ts';
import { GatewayError, type PaymentGateway, type RazorpayPayment, verifyPaymentSignature, verifyWebhookSignature } from './razorpay.ts';

const ORDER_ID = /^order_[A-Za-z0-9]{6,40}$/;
const PAYMENT_ID = /^pay_[A-Za-z0-9]{6,40}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface PreparedOrder {
  booking_id: string;
  amount_paise: number;
  currency: string;
  receipt: string;
  hold_expires_at: string;
  existing_gateway_order_id: string | null;
}

export async function createOrder(deps: { db: Db; gateway: PaymentGateway }, userId: string, bookingId: unknown) {
  if (typeof bookingId !== 'string' || !UUID.test(bookingId)) {
    throw new HttpError(400, 'invalid_booking_id');
  }
  const prepared = await deps.db.rpc<PreparedOrder>('prepare_payment_order', {
    p_booking_id: bookingId,
    p_customer_id: userId,
  });
  const response = (orderId: string) => ({
    order_id: orderId,
    key_id: deps.gateway.keyId,
    amount_paise: prepared.amount_paise,
    currency: prepared.currency,
    booking_id: bookingId,
    hold_expires_at: prepared.hold_expires_at,
  });
  if (prepared.existing_gateway_order_id) {
    return response(prepared.existing_gateway_order_id);
  }
  const order = await deps.gateway.createOrder({
    amount: prepared.amount_paise,
    currency: prepared.currency,
    receipt: prepared.receipt,
    notes: { booking_id: bookingId },
  });
  if (order.amount !== prepared.amount_paise || order.currency !== prepared.currency) {
    log('error', 'payment.order_amount_mismatch', { booking_id: bookingId, order_id: order.id });
    throw new HttpError(502, 'gateway_mismatch', 'Payment could not be started. Please try again.');
  }
  await deps.db.rpc('record_payment_order', {
    p_booking_id: bookingId,
    p_gateway_order_id: order.id,
    p_amount_paise: order.amount,
    p_currency: order.currency,
    p_receipt: prepared.receipt,
  });
  log('info', 'payment.order_created', { booking_id: bookingId, order_id: order.id });
  return response(order.id);
}

function toPaymentStatus(p: RazorpayPayment): 'captured' | 'authorized' | 'failed' | null {
  switch (p.status) {
    case 'captured':
    case 'refunded': // A refunded payment was captured first; refunds are recorded separately.
      return 'captured';
    case 'authorized':
      return 'authorized';
    case 'failed':
      return 'failed';
    default:
      return null;
  }
}

export function recordPayment(db: Db, p: RazorpayPayment) {
  const status = toPaymentStatus(p);
  if (!status) return Promise.resolve({ result: 'pending' });
  return db.rpc<{ result: string; reason?: string }>('record_gateway_payment', {
    p_gateway_order_id: p.order_id,
    p_gateway_payment_id: p.id,
    p_amount_paise: p.amount,
    p_currency: p.currency,
    p_status: status,
    p_method: p.method ?? null,
    p_fee_paise: p.fee ?? null,
    p_fee_tax_paise: p.tax ?? null,
    p_error_code: p.error_code ?? null,
    p_error_description: p.error_description ?? null,
    p_event_at: new Date((p.created_at ?? Date.now() / 1000) * 1000).toISOString(),
  });
}

export async function verifyPayment(
  deps: { db: Db; gateway: PaymentGateway; keySecret: string },
  userId: string,
  body: { razorpay_order_id?: unknown; razorpay_payment_id?: unknown; razorpay_signature?: unknown },
) {
  const orderId = body.razorpay_order_id;
  const paymentId = body.razorpay_payment_id;
  const signature = body.razorpay_signature;
  if (typeof orderId !== 'string' || !ORDER_ID.test(orderId) || typeof paymentId !== 'string' || !PAYMENT_ID.test(paymentId) ||
    typeof signature !== 'string') {
    throw new HttpError(400, 'invalid_request');
  }
  const owner = await deps.db.orderOwner(orderId);
  if (!owner || owner.customer_id !== userId) {
    throw new HttpError(404, 'payment_order_not_found');
  }
  if (!(await verifyPaymentSignature(orderId, paymentId, signature, deps.keySecret))) {
    log('warn', 'payment.invalid_signature', { order_id: orderId, payment_id: paymentId });
    throw new HttpError(400, 'invalid_signature', 'Payment could not be verified');
  }
  // Authoritative state from the gateway, not from the client.
  const payment = await deps.gateway.fetchPayment(paymentId);
  if (payment.order_id !== orderId) {
    log('warn', 'payment.order_mismatch', { order_id: orderId, payment_id: paymentId });
    throw new HttpError(400, 'invalid_request', 'Payment does not belong to this order');
  }
  const res = await recordPayment(deps.db, payment);
  log('info', 'payment.verified', { order_id: orderId, payment_id: paymentId, result: res.result });
  return { booking_id: owner.booking_id, result: res.result };
}

// ---------------------------------------------------------------------------
// Webhooks
// ---------------------------------------------------------------------------

interface WebhookEvent {
  event: string;
  created_at?: number;
  payload?: {
    payment?: { entity: RazorpayPayment };
    refund?: { entity: { id: string; payment_id: string; amount: number; status: string; notes?: Record<string, string> | [] } };
  };
}

/** Keeps only the fields needed for reconciliation; drops customer contact data. */
function sanitize(e: WebhookEvent) {
  const p = e.payload?.payment?.entity;
  const r = e.payload?.refund?.entity;
  return {
    event: e.event,
    created_at: e.created_at,
    payment: p && { id: p.id, order_id: p.order_id, amount: p.amount, currency: p.currency, status: p.status, method: p.method, fee: p.fee, tax: p.tax, error_code: p.error_code },
    refund: r && { id: r.id, payment_id: r.payment_id, amount: r.amount, status: r.status },
  };
}

export async function handleWebhook(
  deps: { db: Db; webhookSecret: string },
  rawBody: string,
  headers: Headers,
): Promise<{ status: string }> {
  if (!(await verifyWebhookSignature(rawBody, headers.get('x-razorpay-signature'), deps.webhookSecret))) {
    log('warn', 'webhook.invalid_signature', {});
    throw new HttpError(400, 'invalid_signature');
  }
  let event: WebhookEvent;
  try {
    event = JSON.parse(rawBody);
  } catch {
    throw new HttpError(400, 'invalid_json');
  }
  if (typeof event?.event !== 'string') throw new HttpError(400, 'invalid_event');

  const eventId = headers.get('x-razorpay-event-id') ??
    `${event.event}:${event.payload?.payment?.entity?.id ?? event.payload?.refund?.entity?.id ?? ''}:${event.created_at ?? ''}`;
  const isNew = await deps.db.rpc<boolean>('record_webhook_event', {
    p_event_id: eventId,
    p_event_type: event.event,
    p_payload: sanitize(event),
  });
  if (!isNew) {
    log('info', 'webhook.duplicate', { event_id: eventId, type: event.event });
    return { status: 'duplicate' };
  }

  try {
    const status = await dispatchWebhook(deps.db, event);
    await deps.db.rpc('complete_webhook_event', { p_event_id: eventId, p_status: status, p_error: null });
    log('info', 'webhook.processed', { event_id: eventId, type: event.event, status });
    return { status };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await deps.db.rpc('complete_webhook_event', { p_event_id: eventId, p_status: 'failed', p_error: message }).catch(() => {});
    log('error', 'webhook.failed', { event_id: eventId, type: event.event, error: message });
    throw err; // non-2xx makes Razorpay retry
  }
}

async function dispatchWebhook(db: Db, event: WebhookEvent): Promise<'processed' | 'ignored'> {
  switch (event.event) {
    case 'payment.captured':
    case 'payment.failed':
    case 'payment.authorized':
    case 'order.paid': {
      const p = event.payload?.payment?.entity;
      if (!p?.order_id) return 'ignored';
      try {
        await recordPayment(db, p);
      } catch (err) {
        // Orders not created by this platform (e.g. other products on the account).
        if (err instanceof HttpError && err.code === 'payment_order_not_found') return 'ignored';
        throw err;
      }
      return 'processed';
    }
    case 'refund.created':
    case 'refund.processed':
    case 'refund.failed': {
      const r = event.payload?.refund?.entity;
      if (!r) return 'ignored';
      const notes = Array.isArray(r.notes) ? {} : (r.notes ?? {});
      const refundId = typeof notes.refund_id === 'string' && UUID.test(notes.refund_id) ? notes.refund_id : null;
      try {
        await db.rpc('record_refund_result', {
          p_refund_id: refundId,
          p_gateway_refund_id: r.id,
          p_gateway_payment_id: r.payment_id,
          p_amount_paise: r.amount,
          p_status: event.event === 'refund.processed' ? 'processed' : event.event === 'refund.failed' ? 'failed' : 'processing',
          p_failure_reason: event.event === 'refund.failed' ? 'Gateway reported refund failure' : null,
          p_event_at: new Date((event.created_at ?? Date.now() / 1000) * 1000).toISOString(),
        });
      } catch (err) {
        if (err instanceof HttpError && err.code === 'payment_not_found') return 'ignored';
        throw err;
      }
      return 'processed';
    }
    default:
      return 'ignored';
  }
}

// ---------------------------------------------------------------------------
// Refund worker
// ---------------------------------------------------------------------------

interface ClaimedRefund {
  refund_id: string;
  gateway_payment_id: string;
  amount_paise: number;
  idempotency_key: string;
  reason: string;
}

export async function processRefunds(deps: { db: Db; gateway: PaymentGateway }, limit = 20) {
  const claimed = await deps.db.rpc<ClaimedRefund[]>('claim_refunds', { p_limit: limit });
  const summary = { claimed: claimed.length, submitted: 0, failed: 0, retry_later: 0 };
  for (const r of claimed) {
    try {
      // A previous attempt may have reached Razorpay before crashing: reuse it.
      const existing = (await deps.gateway.listRefunds(r.gateway_payment_id)).find((x) =>
        !Array.isArray(x.notes) && x.notes?.refund_id === r.refund_id
      );
      const refund = existing ?? await deps.gateway.createRefund(r.gateway_payment_id, {
        amount: r.amount_paise,
        receipt: r.refund_id.replaceAll('-', '').slice(0, 40),
        notes: { refund_id: r.refund_id },
      });
      await deps.db.rpc('record_refund_result', {
        p_refund_id: r.refund_id,
        p_gateway_refund_id: refund.id,
        p_gateway_payment_id: r.gateway_payment_id,
        p_amount_paise: refund.amount,
        p_status: refund.status === 'processed' ? 'processed' : refund.status === 'failed' ? 'failed' : 'processing',
        p_failure_reason: refund.status === 'failed' ? 'Gateway reported refund failure' : null,
        p_event_at: new Date().toISOString(),
      });
      summary.submitted++;
    } catch (err) {
      if (err instanceof GatewayError && err.status >= 400 && err.status < 500) {
        // Permanent rejection (e.g. already fully refunded): record and alert finance.
        await deps.db.rpc('record_refund_result', {
          p_refund_id: r.refund_id,
          p_gateway_refund_id: null,
          p_gateway_payment_id: r.gateway_payment_id,
          p_amount_paise: r.amount_paise,
          p_status: 'failed',
          p_failure_reason: `${err.code}: ${err.message}`.slice(0, 500),
          p_event_at: new Date().toISOString(),
        });
        summary.failed++;
      } else {
        // Network / 5xx: leave it 'processing'; claim_refunds re-offers it later.
        log('warn', 'refund.retry_later', { refund_id: r.refund_id, error: err instanceof Error ? err.message : String(err) });
        summary.retry_later++;
      }
    }
  }
  return summary;
}
