import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { rpc, sql, one, as, rejectsWith, closePool, createUser, createStaff, createBusiness } from './lib/db.mjs';

after(closePool);

const unique = () => `Testpur ${randomUUID().slice(0, 6)}`;

describe('location lists', () => {
  test('states, districts and cities are seeded and readable without sign-in', async () => {
    const rows = await as('anon', (q) =>
      q(`select c.name from public.location_cities c
           join public.location_districts d on d.id = c.district_id
           join public.location_states s on s.id = d.state_id
          where s.name = 'Telangana' and d.name = 'Hyderabad'`),
    );
    assert.ok(rows.some((r) => r.name === 'Hyderabad'));
    const counts = await one(`select (select count(*) from public.location_states) s,
                                     (select count(*) from public.location_districts) d`);
    assert.equal(counts.s, 36);
    assert.ok(counts.d > 700);
  });

  test('clients cannot write the lists directly', async () => {
    const user = await createUser('owner');
    await assert.rejects(as(user.id, (q) => q(`insert into public.location_states (name) values ('Nowhere')`)));
  });
});

describe('location requests', () => {
  let owner;
  let admin;
  let reviewer;
  before(async () => {
    owner = await createUser('owner');
    admin = await createStaff('admin');
    reviewer = await createStaff('compliance_reviewer');
  });

  test('a value already in the list is not requested', async () => {
    const r = await rpc(owner.id, 'request_location', ['city', 'telangana', 'Hyderabad', 'hyderabad', null]);
    assert.equal(r.status, 'exists');
  });

  test('request, de-duplicate, approve adds the city and notifies the requester', async () => {
    const city = unique();
    const first = await rpc(owner.id, 'request_location', ['city', 'Telangana', 'Hyderabad', `  ${city} `, 'station form']);
    assert.equal(first.status, 'pending');
    const again = await rpc(owner.id, 'request_location', ['city', 'Telangana', 'Hyderabad', city.toUpperCase(), null]);
    assert.equal(again.request_id, first.request_id);

    const staffNote = await one(`select count(*) n from public.notifications where recipient_id = $1 and type = 'location.requested'`, [admin.id]);
    assert.ok(staffNote.n >= 1);

    // Only staff with locations.manage can decide; the owner sees only their own request.
    await rejectsWith(rpc(reviewer.id, 'decide_location_request', [first.request_id, true, null, null, null, null]), { status: 403 });
    const mine = await as(owner.id, (q) => q(`select id from public.location_requests`));
    assert.deepEqual(mine.map((r) => r.id), [first.request_id]);

    await rpc(admin.id, 'decide_location_request', [first.request_id, true, null, null, null, null]);
    const added = await one(
      `select c.name from public.location_cities c join public.location_districts d on d.id = c.district_id
        where d.name = 'Hyderabad' and lower(c.name) = lower($1)`,
      [city],
    );
    assert.equal(added.name, city);
    const n = await one(`select title from public.notifications where recipient_id = $1 and type = 'location.approved'`, [owner.id]);
    assert.equal(n.title, 'Location added');
    await rejectsWith(rpc(admin.id, 'decide_location_request', [first.request_id, false, 'no', null, null, null]), {
      code: 'location_request_decided',
    });
  });

  test('approving a city in a new district adds both, with the admin correcting the spelling', async () => {
    const district = unique();
    const r = await rpc(owner.id, 'request_location', ['city', 'Telangana', district, 'Smalltwon', null]);
    await rpc(admin.id, 'decide_location_request', [r.request_id, true, null, null, null, 'Smalltown']);
    const row = await one(
      `select c.name from public.location_cities c join public.location_districts d on d.id = c.district_id
        where d.name = $1`,
      [district],
    );
    assert.equal(row.name, 'Smalltown');
  });

  test('rejecting needs a reason and leaves the list unchanged', async () => {
    const district = unique();
    const r = await rpc(owner.id, 'request_location', ['district', 'Telangana', district, null, null]);
    await rejectsWith(rpc(admin.id, 'decide_location_request', [r.request_id, false, null, null, null, null]), {
      code: 'reason_required',
    });
    await rpc(admin.id, 'decide_location_request', [r.request_id, false, 'Not a district', null, null, null]);
    const rows = await sql(`select 1 from public.location_districts where name = $1`, [district]);
    assert.equal(rows.length, 0);
  });

  test('business registration keeps the district', async () => {
    const user = await createUser('owner');
    const id = await rpc(user.id, 'create_business', [
      'Dist Test Pvt Ltd', null, 'Owner Name', '+919812345670', user.email, 'private_limited',
      null, null, null, null, 'Hyderabad', 'Telangana', null, 'Hyderabad',
    ]);
    const b = await one(`select registered_district from public.businesses where id = $1`, [id]);
    assert.equal(b.registered_district, 'Hyderabad');
    assert.ok(await createBusiness(await createUser('owner')));
  });
});
