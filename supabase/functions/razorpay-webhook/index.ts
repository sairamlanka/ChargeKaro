// Razorpay webhook endpoint (configure in the Razorpay dashboard with the
// RAZORPAY_WEBHOOK_SECRET). Subscribed events: payment.authorized,
// payment.captured, payment.failed, order.paid, refund.created,
// refund.processed, refund.failed.
import { errorResponse, HttpError, json } from '../_shared/http.ts';
import { serviceDb } from '../_shared/db.ts';
import { requireEnv } from '../_shared/env.ts';
import { handleWebhook } from '../_shared/payments.ts';
import { withLogging } from '../_shared/log.ts';

Deno.serve(withLogging('razorpay-webhook', async (req) => {
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const raw = await req.text(); // exact bytes are needed for the signature
    if (raw.length > 512 * 1024) throw new HttpError(413, 'payload_too_large');
    return json(await handleWebhook({ db: serviceDb(), webhookSecret: requireEnv('RAZORPAY_WEBHOOK_SECRET') }, raw, req.headers));
  } catch (err) {
    return errorResponse(err);
  }
}));
