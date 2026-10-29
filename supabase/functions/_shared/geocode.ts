// Area-name search through the Google Geocoding API. The server key stays in
// Edge Function secrets; the app merges these results with the
// search_areas RPC, which works without any provider.

import { HttpError } from './http.ts';

export interface AreaResult {
  label: string;
  secondary: string;
  latitude: number;
  longitude: number;
  source: 'google';
  precise: boolean;
}

type Fetch = (url: string) => Promise<Response>;

export async function geocodeArea(query: unknown, apiKey: string | undefined, fetchFn: Fetch = (u) => fetch(u)): Promise<{ results: AreaResult[] }> {
  const q = typeof query === 'string' ? query.trim() : '';
  if (q.length < 2 || q.length > 120) throw new HttpError(422, 'query_too_short', 'Type 2 to 120 characters');
  if (!apiKey) throw new HttpError(503, 'geocoding_not_configured', 'Area search by map provider is not set up');

  const url = new URL('https://maps.googleapis.com/maps/api/geocode/json');
  url.searchParams.set('address', q);
  url.searchParams.set('region', 'in');
  url.searchParams.set('components', 'country:IN');
  url.searchParams.set('key', apiKey);
  const res = await fetchFn(url.toString());
  if (!res.ok) throw new HttpError(502, 'geocoding_unavailable', 'Area search is temporarily unavailable');
  // deno-lint-ignore no-explicit-any
  const body: any = await res.json();
  if (body.status === 'ZERO_RESULTS') return { results: [] };
  if (body.status !== 'OK') throw new HttpError(502, 'geocoding_unavailable', 'Area search is temporarily unavailable');
  // deno-lint-ignore no-explicit-any
  const results: AreaResult[] = (body.results ?? []).slice(0, 6).map((r: any) => {
    const parts = String(r.formatted_address ?? '').split(',').map((s: string) => s.trim()).filter(Boolean);
    return {
      label: parts[0] ?? q,
      secondary: parts.slice(1).join(', '),
      latitude: Number(r.geometry?.location?.lat),
      longitude: Number(r.geometry?.location?.lng),
      source: 'google' as const,
      precise: r.geometry?.location_type === 'ROOFTOP' || r.geometry?.location_type === 'RANGE_INTERPOLATED',
    };
  }).filter((r: AreaResult) => Number.isFinite(r.latitude) && Number.isFinite(r.longitude));
  return { results };
}
