import { assert, assertEquals, assertRejects, assertStringIncludes, assertThrows } from 'jsr:@std/assert@1.0.13';
import { drivingDistances, planRoute, readPoint, simplify } from '../_shared/routing.ts';
import { HttpError } from '../_shared/http.ts';

const gachibowli = { latitude: 17.44, longitude: 78.35 };
const charminar = { latitude: 17.3616, longitude: 78.4747 };

const respond = (body: unknown, status = 200) => () => Promise.resolve(new Response(JSON.stringify(body), { status }));

Deno.test('OSRM route is converted to [lat, lng] with distance and duration', async () => {
  let requested = '';
  const fake = (u: string) => {
    requested = u;
    return respond({
      code: 'Ok',
      routes: [{ distance: 18456, duration: 2710, geometry: { coordinates: [[78.35, 17.44], [78.4, 17.41], [78.4747, 17.3616]] } }],
    })();
  };
  const r = await planRoute(gachibowli, charminar, { osrmUrl: 'https://osrm.example' }, fake);
  assertStringIncludes(requested, 'https://osrm.example/route/v1/driving/78.35,17.44;78.4747,17.3616?overview=full&geometries=geojson&alternatives=true');
  const first = { distance_km: 18.5, duration_minutes: 45, path: [[17.44, 78.35], [17.41, 78.4], [17.3616, 78.4747]] as [number, number][] };
  assertEquals(r, { ...first, routes: [first], provider: 'osrm' });
});

Deno.test('alternative routes are returned, at most three, best first', async () => {
  const line = (d: number) => ({ distance: d, duration: d / 10, geometry: { coordinates: [[78.35, 17.44], [78.4747, 17.3616]] } });
  const r = await planRoute(gachibowli, charminar, {}, respond({ code: 'Ok', routes: [line(20000), line(22000), line(25000), line(30000)] }));
  assertEquals(r.routes.map((x) => x.distance_km), [20, 22, 25]);
  assertEquals(r.distance_km, 20);
});

Deno.test('a trip through a station goes start, station, destination, with no alternatives', async () => {
  let requested = '';
  const fake = (u: string) => {
    requested = u;
    return respond({ code: 'Ok', routes: [{ distance: 21000, duration: 3000, geometry: { coordinates: [[78.35, 17.44], [78.44, 17.41], [78.4747, 17.3616]] } }] })();
  };
  const r = await planRoute(gachibowli, charminar, {}, fake, { latitude: 17.41, longitude: 78.44 });
  assertStringIncludes(requested, '/route/v1/driving/78.35,17.44;78.44,17.41;78.4747,17.3616?');
  assertStringIncludes(requested, 'alternatives=false');
  assertEquals(r.distance_km, 21);
  assertEquals(r.duration_minutes, 50);
});

Deno.test('driving distances to many stations come from one table call', async () => {
  let requested = '';
  const fake = (u: string) => {
    requested = u;
    return respond({ code: 'Ok', distances: [[0, 2500, null, 12049]], durations: [[0, 400, null, 1500]] })();
  };
  const stops = [{ latitude: 17.45, longitude: 78.36 }, { latitude: 17.5, longitude: 78.1 }, { latitude: 17.4, longitude: 78.44 }];
  const r = await drivingDistances(gachibowli, stops, { osrmUrl: 'https://osrm.example' }, fake);
  assertStringIncludes(requested, 'https://osrm.example/table/v1/driving/78.35,17.44;78.36,17.45;78.1,17.5;78.44,17.4?sources=0&annotations=distance%2Cduration');
  assertEquals(r, [{ distance_km: 2.5, duration_minutes: 7 }, null, { distance_km: 12, duration_minutes: 25 }]);
  assertEquals(await drivingDistances(gachibowli, [], {}, respond({})), []);
  const tooMany = Array.from({ length: 26 }, () => stops[0]);
  assertEquals(((await assertRejects(() => drivingDistances(gachibowli, tooMany, {}, respond({})), HttpError)) as HttpError).code, 'too_many_destinations');
  assertEquals(((await assertRejects(() => drivingDistances(gachibowli, stops, {}, respond({ code: 'TooBig' }, 400)), HttpError)) as HttpError).code, 'routing_unavailable');
  let auth = '';
  const ors = (_u: string, init?: RequestInit) => {
    auth = new Headers(init?.headers).get('Authorization') ?? '';
    return respond({ distances: [[0, 1000, 2000, 3000]], durations: [[0, 60, 120, 180]] })();
  };
  const viaOrs = await drivingDistances(gachibowli, stops, { orsApiKey: 'k' }, ors);
  assertEquals(auth, 'k');
  assertEquals(viaOrs.map((d) => d?.distance_km), [1, 2, 3]);
});

Deno.test('openrouteservice is used when its key is set', async () => {
  let auth = '';
  let sent = '';
  const fake = (u: string, init?: RequestInit) => {
    assertStringIncludes(u, 'api.openrouteservice.org/v2/directions/driving-car/geojson');
    auth = new Headers(init?.headers).get('Authorization') ?? '';
    sent = String(init?.body);
    return respond({ features: [{ geometry: { coordinates: [[78.35, 17.44], [78.4747, 17.3616]] }, properties: { summary: { distance: 20000, duration: 3000 } } }] })();
  };
  const r = await planRoute(gachibowli, charminar, { orsApiKey: 'ors-key', osrmUrl: 'https://ignored.example' }, fake);
  assertEquals(auth, 'ors-key');
  assertEquals(JSON.parse(sent), {
    coordinates: [[78.35, 17.44], [78.4747, 17.3616]],
    alternative_routes: { target_count: 3, weight_factor: 1.4, share_factor: 0.6 },
  });
  assertEquals(r.provider, 'openrouteservice');
  assertEquals(r.distance_km, 20);
  assertEquals(r.duration_minutes, 50);
});

Deno.test('no route, provider failures and bad input map to clear errors', async () => {
  const code = async (p: Promise<unknown>) => ((await assertRejects(() => p, HttpError)) as HttpError).code;
  assertEquals(await code(planRoute(gachibowli, charminar, {}, respond({ code: 'NoRoute', routes: [] }, 400))), 'no_route');
  assertEquals(await code(planRoute(gachibowli, charminar, {}, respond({ code: 'Ok', routes: [] }))), 'routing_unavailable');
  assertEquals(await code(planRoute(gachibowli, charminar, {}, respond('busy', 429))), 'routing_unavailable');
  assertEquals(await code(planRoute(gachibowli, charminar, {}, () => Promise.reject(new Error('offline')))), 'routing_unavailable');
  assertEquals(await code(planRoute(gachibowli, charminar, { orsApiKey: 'k' }, respond({ error: { code: 2010 } }, 404))), 'no_route');
  assertEquals(await code(planRoute(gachibowli, gachibowli, {}, respond({}))), 'route_too_short');
  assertEquals(await code(planRoute(gachibowli, { latitude: 51.5, longitude: -0.12 }, {}, respond({}))), 'route_too_long');
  assertEquals(readPoint({ latitude: '17.4', longitude: 78.3 }, 'start'), { latitude: 17.4, longitude: 78.3 });
  for (const bad of [null, {}, { latitude: 91, longitude: 0 }, { latitude: 'x', longitude: 1 }]) {
    assertThrows(() => readPoint(bad, 'start'), HttpError, 'A valid start is required');
  }
});

Deno.test('simplify keeps the shape and the end points, and caps the point count', () => {
  // A straight road sampled every ~11 m collapses to its ends...
  const straight: [number, number][] = Array.from({ length: 1000 }, (_, i) => [17 + i * 0.0001, 78]);
  assertEquals(simplify(straight), [[17, 78], [17.0999, 78]]);
  // ...but a bend of ~1 km is kept.
  const bend: [number, number][] = [[17, 78], [17.05, 78.01], [17.1, 78]];
  assertEquals(simplify(bend), bend);
  // A long zig-zag is thinned to the cap.
  const zigzag: [number, number][] = Array.from({ length: 5000 }, (_, i) => [17 + i * 0.001, 78 + (i % 2) * 0.01]);
  const thin = simplify(zigzag, 600);
  assert(thin.length <= 600 && thin.length >= 2);
  assertEquals(thin[0], zigzag[0]);
  assertEquals(thin.at(-1), [21.999, 78.01]);
});
