// Driving routes from free OpenStreetMap routing engines.
//
// * OSRM (default): the public demo server at router.project-osrm.org works
//   with no account but is meant for light use only. For production, run
//   your own OSRM with the India extract and set OSRM_URL to it.
// * openrouteservice: used instead when ORS_API_KEY is set (free key from
//   openrouteservice.org, about 2,000 routes a day).
//
// The line is simplified before it is returned so the app can send it to
// search_stations_along_route (at most 2000 points; this sends at most 1200).
//
// Three calls share this module (all through the route-plan function):
// * planRoute: the route from A to B, with up to two alternatives.
// * planRoute with `via`: the same trip through a station, to measure the
//   detour.
// * drivingDistances: driving distance from one point to many stations
//   (Near Me), from the engine's table / matrix service.

import { HttpError } from './http.ts';

export interface LatLng {
  latitude: number;
  longitude: number;
}

export interface RouteOption {
  distance_km: number;
  duration_minutes: number;
  /** [[lat, lng], ...] from start to destination. */
  path: [number, number][];
}

/** The first route is the engine's pick; the top-level fields repeat it. */
export interface RoutePlan extends RouteOption {
  routes: RouteOption[];
  provider: 'osrm' | 'openrouteservice';
}

export interface DrivingDistance {
  distance_km: number;
  duration_minutes: number;
}

type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export const defaultOsrmUrl = 'https://router.project-osrm.org';
// 1200 points keeps a 1,500 km trip within about 250 m of the road, so even
// the narrowest corridor (1 km in the app) is measured fairly.
export const maxPathPoints = 1200;
export const maxAlternatives = 3;
export const maxDestinations = 25;

export interface RoutingConfig {
  osrmUrl?: string;
  orsApiKey?: string;
}

export function readPoint(v: unknown, name: string): LatLng {
  // deno-lint-ignore no-explicit-any
  const o = v as any;
  const latitude = Number(o?.latitude);
  const longitude = Number(o?.longitude);
  if (
    o == null || !Number.isFinite(latitude) || !Number.isFinite(longitude) ||
    latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180
  ) {
    throw new HttpError(422, 'invalid_location', `A valid ${name} is required`);
  }
  return { latitude, longitude };
}

/** Rough great-circle distance, used to reject trips that are not a drive. */
export function straightKm(a: LatLng, b: LatLng): number {
  const r = Math.PI / 180;
  const h = Math.sin((b.latitude - a.latitude) * r / 2) ** 2 +
    Math.cos(a.latitude * r) * Math.cos(b.latitude * r) * Math.sin((b.longitude - a.longitude) * r / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.sqrt(h));
}

export async function planRoute(
  from: LatLng,
  to: LatLng,
  config: RoutingConfig,
  fetchFn: Fetch = (u, i) => fetch(u, i),
  via?: LatLng,
): Promise<RoutePlan> {
  if (straightKm(from, to) < 0.2) throw new HttpError(422, 'route_too_short', 'Start and destination are the same place');
  if (straightKm(from, to) > 3500) throw new HttpError(422, 'route_too_long', 'This trip is too long to plan');
  const stops = via ? [from, via, to] : [from, to];
  const raw = config.orsApiKey
    ? await viaOpenRouteService(stops, config.orsApiKey, fetchFn)
    : await viaOsrm(stops, config.osrmUrl || defaultOsrmUrl, fetchFn);
  const routes = raw.routes.slice(0, maxAlternatives).map((r) => ({
    distance_km: km(r.meters),
    duration_minutes: Math.max(1, Math.round(r.seconds / 60)),
    path: simplify(r.lngLat.map(([lng, lat]) => [lat, lng] as [number, number])),
  }));
  return { ...routes[0], routes, provider: raw.provider };
}

/** Driving distance from [from] to each destination, null where unroutable. */
export async function drivingDistances(
  from: LatLng,
  destinations: LatLng[],
  config: RoutingConfig,
  fetchFn: Fetch = (u, i) => fetch(u, i),
): Promise<(DrivingDistance | null)[]> {
  if (destinations.length === 0) return [];
  if (destinations.length > maxDestinations) throw new HttpError(422, 'too_many_destinations', `At most ${maxDestinations} stations at a time`);
  const all = [from, ...destinations];
  let meters: (number | null)[];
  let seconds: (number | null)[];
  if (config.orsApiKey) {
    const res = await call(fetchFn, 'https://api.openrouteservice.org/v2/matrix/driving-car', {
      method: 'POST',
      headers: { Authorization: config.orsApiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ locations: all.map((p) => [p.longitude, p.latitude]), sources: [0], metrics: ['distance', 'duration'] }),
    });
    // deno-lint-ignore no-explicit-any
    const body: any = await res.json().catch(() => null);
    if (!res.ok || !Array.isArray(body?.distances?.[0])) throw unavailable();
    meters = body.distances[0].slice(1);
    seconds = body.durations?.[0]?.slice(1) ?? [];
  } else {
    const coords = all.map((p) => `${p.longitude},${p.latitude}`).join(';');
    const url = new URL(`/table/v1/driving/${coords}`, config.osrmUrl || defaultOsrmUrl);
    url.searchParams.set('sources', '0');
    url.searchParams.set('annotations', 'distance,duration');
    const res = await call(fetchFn, url.toString(), { headers: { 'User-Agent': userAgent } });
    // deno-lint-ignore no-explicit-any
    const body: any = await res.json().catch(() => null);
    if (!res.ok || body?.code !== 'Ok' || !Array.isArray(body.distances?.[0])) throw unavailable();
    meters = body.distances[0].slice(1);
    seconds = body.durations?.[0]?.slice(1) ?? [];
  }
  return destinations.map((_, i) => {
    const m = meters[i];
    const s = seconds[i];
    if (m == null || !Number.isFinite(Number(m))) return null;
    return { distance_km: km(Number(m)), duration_minutes: Math.max(1, Math.round(Number(s ?? 0) / 60)) };
  });
}

const km = (meters: number) => Math.round(meters / 100) / 10;
const userAgent = 'ChargeKaro/1.0 (EV charging slot booking)';

interface RawRoutes {
  routes: { meters: number; seconds: number; lngLat: [number, number][] }[];
  provider: RoutePlan['provider'];
}

const unavailable = () => new HttpError(502, 'routing_unavailable', 'Route search is temporarily unavailable');
const noRoute = () => new HttpError(404, 'no_route', 'No driving route was found between these places');

async function call(fetchFn: Fetch, url: string, init?: RequestInit): Promise<Response> {
  try {
    return await fetchFn(url, init);
  } catch {
    throw unavailable();
  }
}

async function viaOsrm(stops: LatLng[], baseUrl: string, fetchFn: Fetch): Promise<RawRoutes> {
  const coords = stops.map((p) => `${p.longitude},${p.latitude}`).join(';');
  const url = new URL(`/route/v1/driving/${coords}`, baseUrl);
  url.searchParams.set('overview', 'full');
  url.searchParams.set('geometries', 'geojson');
  // OSRM only offers alternatives for a plain A-to-B trip.
  url.searchParams.set('alternatives', stops.length === 2 ? 'true' : 'false');
  url.searchParams.set('steps', 'false');
  const res = await call(fetchFn, url.toString(), { headers: { 'User-Agent': userAgent } });
  // deno-lint-ignore no-explicit-any
  const body: any = await res.json().catch(() => null);
  if (body?.code === 'NoRoute' || body?.code === 'NoSegment') throw noRoute();
  if (!res.ok || body?.code !== 'Ok' || !body.routes?.length) throw unavailable();
  return {
    // deno-lint-ignore no-explicit-any
    routes: body.routes.map((r: any) => ({ meters: Number(r.distance), seconds: Number(r.duration), lngLat: checkLine(r.geometry?.coordinates) })),
    provider: 'osrm',
  };
}

async function viaOpenRouteService(stops: LatLng[], apiKey: string, fetchFn: Fetch): Promise<RawRoutes> {
  const res = await call(fetchFn, 'https://api.openrouteservice.org/v2/directions/driving-car/geojson', {
    method: 'POST',
    headers: { Authorization: apiKey, 'Content-Type': 'application/json', Accept: 'application/geo+json' },
    body: JSON.stringify({
      coordinates: stops.map((p) => [p.longitude, p.latitude]),
      ...(stops.length === 2 ? { alternative_routes: { target_count: maxAlternatives, weight_factor: 1.4, share_factor: 0.6 } } : {}),
    }),
  });
  // deno-lint-ignore no-explicit-any
  const body: any = await res.json().catch(() => null);
  // 2009 / 2010: no route found / point not near a road.
  if (body?.error?.code === 2009 || body?.error?.code === 2010) throw noRoute();
  if (!res.ok || !body?.features?.length) throw unavailable();
  return {
    // deno-lint-ignore no-explicit-any
    routes: body.features.map((f: any) => ({
      meters: Number(f.properties?.summary?.distance ?? 0),
      seconds: Number(f.properties?.summary?.duration ?? 0),
      lngLat: checkLine(f.geometry?.coordinates),
    })),
    provider: 'openrouteservice',
  };
}

function checkLine(coords: unknown): [number, number][] {
  if (!Array.isArray(coords) || coords.length < 2) throw unavailable();
  const line = coords.map((c) => [Number(c?.[0]), Number(c?.[1])] as [number, number]);
  if (line.some(([x, y]) => !Number.isFinite(x) || !Number.isFinite(y))) throw unavailable();
  return line;
}

/**
 * Douglas-Peucker on a local flat projection, tightening the tolerance until
 * the line fits in [maxPoints]. 30 m keeps the line on the road at map zoom
 * levels and is far below the smallest station corridor (0.5 km).
 */
export function simplify(path: [number, number][], maxPoints = maxPathPoints): [number, number][] {
  if (path.length <= 2) return path.map(round);
  let tolerance = 0.03;
  let out = douglasPeucker(path, tolerance);
  while (out.length > maxPoints) {
    tolerance *= 2;
    out = douglasPeucker(path, tolerance);
  }
  return out.map(round);
}

const round = ([lat, lng]: [number, number]): [number, number] => [Math.round(lat * 1e5) / 1e5, Math.round(lng * 1e5) / 1e5];

function douglasPeucker(path: [number, number][], toleranceKm: number): [number, number][] {
  const kx = 111.32 * Math.cos((path[0][0] * Math.PI) / 180);
  const ky = 110.574;
  const xy = path.map(([lat, lng]) => [lng * kx, lat * ky]);
  const keep = new Uint8Array(path.length);
  keep[0] = keep[path.length - 1] = 1;
  const stack: [number, number][] = [[0, path.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop()!;
    let worst = -1;
    let worstD = 0;
    const [ax, ay] = xy[a];
    const [bx, by] = xy[b];
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    for (let i = a + 1; i < b; i++) {
      const [px, py] = xy[i];
      const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2));
      const d = Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
      if (d > worstD) {
        worstD = d;
        worst = i;
      }
    }
    if (worst > 0 && worstD > toleranceKm) {
      keep[worst] = 1;
      stack.push([a, worst], [worst, b]);
    }
  }
  return path.filter((_, i) => keep[i]);
}
