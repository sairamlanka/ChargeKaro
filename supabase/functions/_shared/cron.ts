import { HttpError, timingSafeEqual } from './http.ts';
import { requireEnv } from './env.ts';

/** Scheduler endpoints accept only requests carrying the shared CRON_SECRET. */
export function requireCronSecret(req: Request) {
  const given = req.headers.get('x-cron-secret') ?? '';
  if (!timingSafeEqual(given, requireEnv('CRON_SECRET'))) {
    throw new HttpError(401, 'unauthorized');
  }
}
