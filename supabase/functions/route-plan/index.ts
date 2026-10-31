// The customer app's routing calls (guests included), all on free
// OpenStreetMap routing: OSRM (OSRM_URL, public demo server by default) or
// openrouteservice when ORS_API_KEY is set. See _shared/routing.ts.
//
// POST { from, to }        -> the route plus up to two alternatives
//                             (Along My Route).
// POST { from, to, via }   -> the same trip through a station, to measure
//                             the detour.
// POST { from, destinations: [{latitude, longitude}, ...] }
//                          -> driving distance to each (Near Me; at most 25).
import { corsHeaders, errorResponse, HttpError, json, readJson } from '../_shared/http.ts';
import { drivingDistances, planRoute, readPoint } from '../_shared/routing.ts';
import { log, withLogging } from '../_shared/log.ts';

Deno.serve(withLogging('route-plan', async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const body = await readJson<{ from?: unknown; to?: unknown; via?: unknown; destinations?: unknown }>(req);
    const config = { osrmUrl: Deno.env.get('OSRM_URL'), orsApiKey: Deno.env.get('ORS_API_KEY') };
    const from = readPoint(body.from, 'start');
    if (body.destinations !== undefined) {
      if (!Array.isArray(body.destinations)) throw new HttpError(422, 'invalid_location', 'destinations must be a list');
      const destinations = body.destinations.map((d) => readPoint(d, 'station location'));
      return json({ distances: await drivingDistances(from, destinations, config) });
    }
    const to = readPoint(body.to, 'destination');
    const via = body.via === undefined || body.via === null ? undefined : readPoint(body.via, 'station location');
    return json(await planRoute(from, to, config, undefined, via));
  } catch (err) {
    if (!(err instanceof HttpError)) log('error', 'route.failed', { error: String(err) });
    else if (err.status >= 500) log('warn', 'route.unavailable', { code: err.code });
    return errorResponse(err);
  }
}));
