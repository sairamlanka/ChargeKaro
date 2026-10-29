// Place search through Photon, a free OpenStreetMap geocoder
// (https://photon.komoot.io, or a self-hosted copy via PHOTON_URL). No key is
// needed. The app merges these results with the search_areas RPC, which works
// without any provider.

import { HttpError } from './http.ts';

export interface AreaResult {
  label: string;
  secondary: string;
  latitude: number;
  longitude: number;
  source: 'osm';
  precise: boolean;
}

type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export const defaultPhotonUrl = 'https://photon.komoot.io';

// Results are limited to India, the service area (same bounds as the RPCs).
const indiaBbox = '68.0,6.0,97.5,37.6';

// Kinds of OSM object that are an exact spot rather than an area.
const preciseTypes = new Set(['house', 'street']);

export async function geocodeArea(
  query: unknown,
  baseUrl: string = defaultPhotonUrl,
  fetchFn: Fetch = (u, i) => fetch(u, i),
  near?: { latitude: number; longitude: number },
): Promise<{ results: AreaResult[] }> {
  const q = typeof query === 'string' ? query.trim() : '';
  if (q.length < 2 || q.length > 120) throw new HttpError(422, 'query_too_short', 'Type 2 to 120 characters');

  const url = new URL('/api/', baseUrl);
  url.searchParams.set('q', q);
  url.searchParams.set('limit', '8');
  url.searchParams.set('bbox', indiaBbox);
  if (near && Number.isFinite(near.latitude) && Number.isFinite(near.longitude)) {
    url.searchParams.set('lat', String(near.latitude));
    url.searchParams.set('lon', String(near.longitude));
  }
  let res: Response;
  try {
    // The public Photon server asks callers to identify themselves.
    res = await fetchFn(url.toString(), { headers: { 'User-Agent': 'ChargeKaro/1.0 (EV charging slot booking)' } });
  } catch {
    throw new HttpError(502, 'geocoding_unavailable', 'Place search is temporarily unavailable');
  }
  if (!res.ok) throw new HttpError(502, 'geocoding_unavailable', 'Place search is temporarily unavailable');
  // deno-lint-ignore no-explicit-any
  const body: any = await res.json().catch(() => null);
  if (!body || !Array.isArray(body.features)) throw new HttpError(502, 'geocoding_unavailable', 'Place search is temporarily unavailable');

  const seen = new Set<string>();
  const results: AreaResult[] = [];
  for (const f of body.features) {
    const p = f?.properties ?? {};
    if (p.countrycode && String(p.countrycode).toUpperCase() !== 'IN') continue;
    const [lng, lat] = Array.isArray(f?.geometry?.coordinates) ? f.geometry.coordinates.map(Number) : [NaN, NaN];
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
    const street = [p.housenumber, p.street].filter(Boolean).join(' ');
    const label = String(p.name ?? (street || p.city || p.district || p.county || q));
    const secondary = [street !== label ? street : null, p.district, p.city, p.state, p.postcode]
      .filter((s) => s && s !== label)
      .filter((s, i, a) => a.indexOf(s) === i)
      .join(', ');
    const key = `${label.toLowerCase()}|${secondary.toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    results.push({ label, secondary, latitude: lat, longitude: lng, source: 'osm', precise: preciseTypes.has(String(p.type)) });
    if (results.length === 6) break;
  }
  return { results };
}

/** Recent answers by query (and `near`, to about 10 km), oldest dropped first. */
export class PlaceCache {
  constructor(private readonly maxEntries = 500, private readonly ttlMs = 6 * 60 * 60 * 1000, private readonly now = () => Date.now()) {}

  private readonly entries = new Map<string, { at: number; value: { results: AreaResult[] } }>();

  static key(query: unknown, near?: { latitude: number; longitude: number }): string {
    const q = typeof query === 'string' ? query.trim().toLowerCase() : '';
    const n = near && Number.isFinite(near.latitude) && Number.isFinite(near.longitude)
      ? `${near.latitude.toFixed(1)},${near.longitude.toFixed(1)}`
      : '';
    return `${q}|${n}`;
  }

  get(key: string): { results: AreaResult[] } | undefined {
    const e = this.entries.get(key);
    if (!e) return undefined;
    if (this.now() - e.at > this.ttlMs) {
      this.entries.delete(key);
      return undefined;
    }
    return e.value;
  }

  set(key: string, value: { results: AreaResult[] }): void {
    this.entries.delete(key);
    this.entries.set(key, { at: this.now(), value });
    while (this.entries.size > this.maxEntries) this.entries.delete(this.entries.keys().next().value!);
  }
}
