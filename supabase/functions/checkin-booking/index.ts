// POST with the staff member's JWT. See _shared/checkin.ts and docs/checkin.md.
import { corsHeaders, errorResponse, HttpError, json, readJson } from '../_shared/http.ts';
import { handleCheckin, userRpc } from '../_shared/checkin.ts';
import { log, withLogging } from '../_shared/log.ts';

Deno.serve(withLogging('checkin-booking', async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const db = userRpc(req);
    return json(await handleCheckin(db, 'checkin-booking', await readJson<Record<string, unknown>>(req)));
  } catch (err) {
    if (!(err instanceof HttpError)) log('error', 'checkin.failed', { route: 'checkin-booking', error: String(err) });
    return errorResponse(err);
  }
}));
