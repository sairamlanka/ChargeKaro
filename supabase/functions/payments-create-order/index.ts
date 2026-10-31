// POST { booking_id } with the customer's JWT.
// Creates (or reuses) a Razorpay order for the booking fee of a payment-pending
// booking. The amount is read from the database, never from the request.
import { corsHeaders, errorResponse, HttpError, json, readJson } from '../_shared/http.ts';
import { requireUserId, serviceDb } from '../_shared/db.ts';
import { requireEnv } from '../_shared/env.ts';
import { GatewayError, RazorpayClient } from '../_shared/razorpay.ts';
import { createOrder } from '../_shared/payments.ts';
import { log, withLogging } from '../_shared/log.ts';

Deno.serve(withLogging('payments-create-order', async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const userId = await requireUserId(req);
    const body = await readJson<{ booking_id?: unknown }>(req);
    const gateway = new RazorpayClient(requireEnv('RAZORPAY_KEY_ID'), requireEnv('RAZORPAY_KEY_SECRET'));
    return json(await createOrder({ db: serviceDb(), gateway }, userId, body.booking_id));
  } catch (err) {
    if (err instanceof GatewayError) {
      log('error', 'payment.gateway_error', { status: err.status, code: err.code });
      return json({ error: 'payment_gateway_unavailable', message: 'Payment could not be started. Please try again.' }, 502);
    }
    if (!(err instanceof HttpError)) log('error', 'payment.create_order_failed', { error: String(err) });
    return errorResponse(err);
  }
}));
