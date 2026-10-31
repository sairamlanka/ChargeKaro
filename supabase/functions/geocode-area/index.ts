// POST { query, near? } from the Retail App (guests included; the publishable
// key is enough). Returns place candidates from Photon, a free OpenStreetMap
// geocoder; `near` ({latitude, longitude}) ranks places close to it first.
// PHOTON_URL points at a self-hosted Photon instead of the public server.
import { corsHeaders, errorResponse, HttpError, json, readJson } from '../_shared/http.ts';
import { defaultPhotonUrl, geocodeArea, PlaceCache } from '../_shared/geocode.ts';
import { log, withLogging } from '../_shared/log.ts';

// Kept while this function instance stays warm, so a place many customers
// type ("gachibowli") is answered without calling Photon again.
const cache = new PlaceCache();

Deno.serve(withLogging('geocode-area', async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const body = await readJson<{ query?: unknown; near?: { latitude?: unknown; longitude?: unknown } }>(req);
    const near = body.near ? { latitude: Number(body.near.latitude), longitude: Number(body.near.longitude) } : undefined;
    const key = PlaceCache.key(body.query, near);
    const hit = cache.get(key);
    if (hit) return json(hit);
    const result = await geocodeArea(body.query, Deno.env.get('PHOTON_URL') || defaultPhotonUrl, undefined, near);
    cache.set(key, result);
    return json(result);
  } catch (err) {
    if (!(err instanceof HttpError)) log('error', 'geocode.failed', { error: String(err) });
    return errorResponse(err);
  }
}));
