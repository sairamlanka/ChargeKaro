// Scheduled (every minute) with header x-cron-secret: pushes stored
// notifications through FCM. Records stay visible in-app even if push fails.
import { errorResponse, json } from '../_shared/http.ts';
import { serviceDb } from '../_shared/db.ts';
import { requireEnv } from '../_shared/env.ts';
import { requireCronSecret } from '../_shared/cron.ts';
import { dispatchNotifications, FcmSender } from '../_shared/fcm.ts';

Deno.serve(async (req) => {
  try {
    requireCronSecret(req);
    const sender = new FcmSender(requireEnv('FCM_SERVICE_ACCOUNT_JSON'));
    return json(await dispatchNotifications({ db: serviceDb(), sender }));
  } catch (err) {
    return errorResponse(err);
  }
});
