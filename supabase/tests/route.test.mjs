import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { as, rpc, sql, rejectsWith, closePool, approvedStation, setFee } from './lib/db.mjs';

after(async () => {
  await setFee(0);
  await closePool();
});
before(() => setFee(0));

/** Puts a station somewhere unique so only the test route passes it. */
const placeStation = (stationId, lat, lng) => sql(`update public.stations set latitude = $2, longitude = $3 where id = $1`, [stationId, lat, lng]);

// pg would send a JS array as a Postgres array; the RPC takes jsonb.
const alongRoute = (path, corridor = 5, limit = 100) => rpc('anon', 'search_stations_along_route', [JSON.stringify(path), corridor, limit]);

// An L-shaped trip in western Rajasthan, far from every other test station:
// 0.5 degrees north (~55 km), then 0.5 degrees east (~50 km).
const trip = [[26.0, 71.0], [26.25, 71.0], [26.5, 71.0], [26.5, 71.25], [26.5, 71.5]];

describe('stations along a route', () => {
  test('lists stations near the line in the order the driver reaches them', async () => {
    const late = await approvedStation();
    const early = await approvedStation({ points: ['A', 'B'] });
    const corner = await approvedStation();
    const far = await approvedStation();
    const behind = await approvedStation();
    await placeStation(late.stationId, 26.52, 71.4); // east leg, ~2.2 km north of it
    await placeStation(early.stationId, 26.1, 71.01); // first leg, ~1 km east of it
    await placeStation(corner.stationId, 26.5, 71.0); // on the corner
    await placeStation(far.stationId, 26.25, 71.2); // ~20 km off the first leg
    await placeStation(behind.stationId, 25.9, 71.0); // ~11 km before the start

    const res = await alongRoute(trip, 5);
    assert.equal(res.in_service_area, true);
    assert.equal(res.corridor_km, 5);
    const ids = res.stations.map((s) => s.id);
    assert.deepEqual(ids, [early.stationId, corner.stationId, late.stationId]);

    const [a, b, c] = res.stations;
    assert.ok(a.off_route_km > 0.8 && a.off_route_km < 1.2, `off ${a.off_route_km}`);
    assert.ok(a.along_route_km > 10.5 && a.along_route_km < 11.6, `along ${a.along_route_km}`);
    assert.equal(b.off_route_km, 0);
    assert.ok(b.along_route_km > 54 && b.along_route_km < 57, `along ${b.along_route_km}`);
    assert.ok(c.off_route_km > 2 && c.off_route_km < 2.5, `off ${c.off_route_km}`);
    assert.ok(c.along_route_km > 94 && c.along_route_km < 96, `along ${c.along_route_km}`);
    assert.equal(a.distance_km, null);
    assert.equal(a.points.total, 2);
    assert.ok(a.next_available?.start_at, 'next free slot is included');

    const wide = await alongRoute(trip, 25);
    assert.ok(wide.stations.some((s) => s.id === far.stationId), 'a wider corridor reaches further');
    assert.ok(wide.stations.some((s) => s.id === behind.stationId), 'near the start counts');
    const narrow = await alongRoute(trip, 1.5);
    assert.deepEqual(narrow.stations.map((s) => s.id), [early.stationId, corner.stationId]);
    // Over the limit, the stations closest to the road are kept (in trip
    // order), not just the first ones on the trip.
    const two = await alongRoute(trip, 5, 2);
    assert.deepEqual(two.stations.map((s) => s.id), [early.stationId, corner.stationId]);
    assert.equal(two.total_found, 3);
    const one = await alongRoute(trip, 5, 1);
    assert.deepEqual(one.stations.map((s) => s.id), [corner.stationId]);
  });

  test('Chanda Nagar to Vijayawada: stations across the whole journey, far ones left out', async () => {
    // The line the route-plan function would return, simplified: Chanda
    // Nagar, Miyapur, JNTU/KPHB, then NH65 via Hayathnagar, Choutuppal,
    // Suryapet, Kodad and Nandigama to Vijayawada.
    const hydToVijayawada = [
      [17.493, 78.333], [17.496, 78.357], [17.4935, 78.391], [17.33, 78.6], [17.25, 78.9],
      [17.14, 79.62], [16.99, 79.97], [16.77, 80.29], [16.51, 80.63],
    ];
    const kphb = await approvedStation();
    const suryapet = await approvedStation();
    const kodad = await approvedStation();
    const warangal = await approvedStation();
    const guntur = await approvedStation();
    await placeStation(kphb.stationId, 17.4937, 78.3925); // on the road
    await placeStation(suryapet.stationId, 17.145, 79.625); // ~0.7 km off
    await placeStation(kodad.stationId, 17.11, 79.77); // ~3.5 km off, towards Kodad
    await placeStation(warangal.stationId, 17.97, 79.59); // ~90 km north
    await placeStation(guntur.stationId, 16.3, 80.44); // ~30 km past the end

    // Other tests' stations sit in Hyderabad too; look only at these five.
    const mine = new Set([kphb, suryapet, kodad, warangal, guntur].map((x) => x.stationId));
    const res = await alongRoute(hydToVijayawada, 5);
    const listed = res.stations.filter((s) => mine.has(s.id));
    assert.deepEqual(listed.map((s) => s.id), [kphb.stationId, suryapet.stationId, kodad.stationId], 'in journey order');
    assert.equal(new Set(res.stations.map((s) => s.id)).size, res.stations.length, 'no duplicates');
    assert.equal(res.total_found, res.stations.length);
    const [a, b, c] = listed;
    assert.ok(a.off_route_km < 0.2 && a.along_route_km > 5 && a.along_route_km < 7, JSON.stringify([a.off_route_km, a.along_route_km]));
    assert.ok(b.along_route_km > 130 && b.along_route_km < 175, `Suryapet at ${b.along_route_km} km`);
    assert.ok(c.off_route_km > 2 && c.off_route_km < 4, `Kodad ${c.off_route_km} km off`);
    // Only a corridor the customer widens reaches Guntur; Warangal never.
    const wide = await alongRoute(hydToVijayawada, 25);
    assert.ok(!wide.stations.some((s) => s.id === guntur.stationId));
    assert.ok(!wide.stations.some((s) => s.id === warangal.stationId));
  });

  test('a station near a route that doubles back is listed once; limits are reported', async () => {
    const s1 = await approvedStation();
    const s2 = await approvedStation();
    await placeStation(s1.stationId, 28.1, 70.5);
    await placeStation(s2.stationId, 28.3, 70.5);
    const outAndBack = [[28.0, 70.49], [28.4, 70.49], [28.0, 70.495]];
    const res = await alongRoute(outAndBack, 5);
    assert.deepEqual(res.stations.map((s) => s.id).sort(), [s1.stationId, s2.stationId].sort());
    const capped = await alongRoute(outAndBack, 5, 1);
    assert.equal(capped.stations.length, 1);
    assert.equal(capped.total_found, 2);
  });

  test('default distances come from platform settings', async () => {
    const s = await approvedStation();
    await placeStation(s.stationId, 28.8, 71.03); // ~3 km off the line, ~3 km from the point
    const line = [[28.7, 71.0], [28.9, 71.0]];
    try {
      assert.equal((await rpc('anon', 'search_stations_along_route', [JSON.stringify(line), null, 100])).corridor_km, 5);
      await sql(`update public.platform_settings set value = '2' where key = 'route_corridor_km'`);
      const narrow = await rpc('anon', 'search_stations_along_route', [JSON.stringify(line), null, 100]);
      assert.equal(narrow.corridor_km, 2);
      assert.equal(narrow.stations.length, 0);
      await sql(`update public.platform_settings set value = '2' where key = 'nearby_radius_km'`);
      const near = await rpc('anon', 'search_stations', [28.8, 71.0, null, 50]);
      assert.equal(near.radius_km, 2);
      assert.ok(!near.stations.some((x) => x.id === s.stationId));
      await rejectsWith(sql(`update public.platform_settings set value = '40' where key = 'route_corridor_km'`), { code: 'invalid_setting' });
    } finally {
      await sql(`update public.platform_settings set value = '5' where key in ('route_corridor_km', 'nearby_radius_km')`);
    }
  });

  test('suspended stations are left out', async () => {
    const s = await approvedStation();
    await placeStation(s.stationId, 27.5, 72.0);
    const path = [[27.4, 72.0], [27.6, 72.0]];
    assert.equal((await alongRoute(path)).stations.length, 1);
    await rpc(s.admin.id, 'suspend_station', [s.stationId, 'Compliance check', true]);
    assert.equal((await alongRoute(path)).stations.length, 0);
  });

  test('outside the service area and bad input are explained', async () => {
    const london = await alongRoute([[51.5, -0.12], [51.75, -1.25]]);
    assert.equal(london.in_service_area, false);
    assert.deepEqual(london.stations, []);
    await rejectsWith(alongRoute([[26, 71]]), { status: 422, code: 'invalid_route' });
    await rejectsWith(alongRoute([[26, 71], [126, 71]]), { status: 422, code: 'invalid_route' });
    await rejectsWith(alongRoute([[26, 71], { lat: 26.1, lng: 71 }]), { status: 422, code: 'invalid_route' });
    await rejectsWith(alongRoute(Array.from({ length: 2001 }, (_, i) => [26 + i / 10000, 71])), { status: 422, code: 'invalid_route' });
    await rejectsWith(alongRoute(trip, 40), { status: 422, code: 'invalid_corridor' });
    await rejectsWith(rpc('anon', 'search_stations_along_route', [null, 5, 60]), { status: 422, code: 'invalid_route' });
  });

  test('guests can call it but not the helper', async () => {
    await rejectsWith(as('anon', (q) => q(`select * from private.route_segments('[[0,0],[1,1]]'::jsonb)`)), { sqlstate: '42501' });
  });
});
