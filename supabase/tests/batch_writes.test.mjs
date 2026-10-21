// Atomic replace RPCs used by the Business App editors (migration 1000).
import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { rpc, sql, rejectsWith, closePool, createUser, createBusiness, createStation, addPoint, setHours } from './lib/db.mjs';

after(closePool);

let owner;
let stationId;
let pointId;

before(async () => {
  owner = await createUser('owner');
  const businessId = await createBusiness(owner);
  stationId = await createStation(owner, businessId);
  pointId = await addPoint(owner, stationId);
  await setHours(owner, stationId, 360, 1320);
});

const hoursOf = (id) =>
  sql(`select day_of_week, opens_minute, closes_minute from public.station_operating_hours
       where station_id = $1 and charging_point_id is null order by day_of_week, opens_minute`, [id]);

test('owner replaces station hours atomically', async () => {
  const n = await rpc(owner.id, 'set_station_operating_hours', [stationId, null, JSON.stringify([
    { day_of_week: 1, opens_minute: 480, closes_minute: 720 },
    { day_of_week: 1, opens_minute: 780, closes_minute: 1200 },
    { day_of_week: 6, opens_minute: 600, closes_minute: 960 },
  ])]);
  assert.equal(n, 3);
  assert.deepEqual((await hoursOf(stationId)).map((r) => [r.day_of_week, r.opens_minute, r.closes_minute]), [
    [1, 480, 720], [1, 780, 1200], [6, 600, 960],
  ]);
});

test('an overlapping set is rejected and the previous hours stay', async () => {
  const before = await hoursOf(stationId);
  await rejectsWith(rpc(owner.id, 'set_station_operating_hours', [stationId, null, JSON.stringify([
    { day_of_week: 2, opens_minute: 480, closes_minute: 720 },
    { day_of_week: 2, opens_minute: 600, closes_minute: 900 },
  ])]), { sqlstate: '23P01' });
  assert.deepEqual(await hoursOf(stationId), before);
});

test('another business cannot replace these hours', async () => {
  const other = await createUser('owner');
  await createBusiness(other);
  const before = await hoursOf(stationId);
  await rejectsWith(rpc(other.id, 'set_station_operating_hours', [stationId, null, JSON.stringify([
    { day_of_week: 3, opens_minute: 0, closes_minute: 1440 },
  ])]), { sqlstate: '42501' });
  assert.deepEqual(await hoursOf(stationId), before);
});

test('connectors are replaced and numbered in order', async () => {
  const n = await rpc(owner.id, 'set_charging_point_connectors', [pointId, JSON.stringify([
    { connector_type: 'ccs2', max_power_kw: 60 },
    { connector_type: 'type2_ac' },
  ])]);
  assert.equal(n, 2);
  const rows = await sql(`select connector_number, connector_type, max_power_kw from public.charging_connectors
                          where charging_point_id = $1 order by 1`, [pointId]);
  assert.deepEqual(rows.map((r) => [r.connector_number, r.connector_type, r.max_power_kw === null ? null : Number(r.max_power_kw)]),
    [[1, 'ccs2', 60], [2, 'type2_ac', null]]);
});

test('an empty connector list is refused', async () => {
  await rejectsWith(rpc(owner.id, 'set_charging_point_connectors', [pointId, '[]']), { status: 422 });
});
