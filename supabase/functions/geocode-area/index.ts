// POST { query } from the Retail App (guests included; the publishable key is
// enough). Returns area candidates from the Google Geocoding API, or 503
// geocoding_not_configured so the app falls back to station localities.
import { corsHeaders, errorResponse, HttpError, json, readJson } from '../_shared/http.ts';
import { geocodeArea } from '../_shared/geocode.ts';
import { log } from '../_shared/log.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const body = await readJson<{ query?: unknown }>(req);
    return json(await geocodeArea(body.query, Deno.env.get('GOOGLE_MAPS_SERVER_KEY')));
  } catch (err) {
    if (!(err instanceof HttpError)) log('error', 'geocode.failed', { error: String(err) });
    return errorResponse(err);
  }
});
