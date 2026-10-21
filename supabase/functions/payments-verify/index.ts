// POST { razorpay_order_id, razorpay_payment_id, razorpay_signature } with the
// customer's JWT, after Razorpay Checkout returns. Verifies the signature,
// re-fetches the payment from Razorpay and records it idempotently. The
// webhook records the same payment independently, so either path is enough.
import { corsHeaders, errorResponse, HttpError, json, readJson } from '../_shared/http.ts';
import { requireUserId, serviceDb } from '../_shared/db.ts';
import { requireEnv } from '../_shared/env.ts';
import { GatewayError, RazorpayClient } from '../_shared/razorpay.ts';
import { verifyPayment } from '../_shared/payments.ts';
import { log } from '../_shared/log.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const userId = await requireUserId(req);
    const body = await readJson<Record<string, unknown>>(req);
    const keySecret = requireEnv('RAZORPAY_KEY_SECRET');
    const gateway = new RazorpayClient(requireEnv('RAZORPAY_KEY_ID'), keySecret);
    return json(await verifyPayment({ db: serviceDb(), gateway, keySecret }, userId, body));
  } catch (err) {
    if (err instanceof GatewayError) {
      log('error', 'payment.gateway_error', { status: err.status, code: err.code });
      return json({ error: 'payment_gateway_unavailable', message: 'We could not confirm the payment yet. It will update automatically.' }, 502);
    }
    if (!(err instanceof HttpError)) log('error', 'payment.verify_failed', { error: String(err) });
    return errorResponse(err);
  }
});
