// Scheduled (every few minutes) with header x-cron-secret: submits requested
// refunds to Razorpay. Safe to run concurrently; claims use SKIP LOCKED.
import { errorResponse, json } from '../_shared/http.ts';
import { serviceDb } from '../_shared/db.ts';
import { requireEnv } from '../_shared/env.ts';
import { requireCronSecret } from '../_shared/cron.ts';
import { RazorpayClient } from '../_shared/razorpay.ts';
import { processRefunds } from '../_shared/payments.ts';

Deno.serve(async (req) => {
  try {
    requireCronSecret(req);
    const gateway = new RazorpayClient(requireEnv('RAZORPAY_KEY_ID'), requireEnv('RAZORPAY_KEY_SECRET'));
    return json(await processRefunds({ db: serviceDb(), gateway }));
  } catch (err) {
    return errorResponse(err);
  }
});
