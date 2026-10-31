// Scheduled (every minute) with header x-cron-secret: queues booking
// reminders, then sends queued customer SMS/email. Channels without provider
// secrets are marked skipped. Booking status never depends on delivery.
import { errorResponse, json } from '../_shared/http.ts';
import { serviceDb } from '../_shared/db.ts';
import { requireCronSecret } from '../_shared/cron.ts';
import { dispatchCustomerMessages, sendersFromEnv } from '../_shared/messaging.ts';
import { withLogging } from '../_shared/log.ts';

Deno.serve(withLogging('dispatch-customer-messages', async (req) => {
  try {
    requireCronSecret(req);
    return json(await dispatchCustomerMessages({ db: serviceDb(), senders: sendersFromEnv() }));
  } catch (err) {
    return errorResponse(err);
  }
}, { okLevel: 'debug' }));
