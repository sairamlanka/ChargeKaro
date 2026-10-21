// Test helpers: run SQL as a specific Supabase role/user, and build fixtures.
//
// Tests run against a database prepared by scripts/db-reset-test.sh (plain
// Postgres + shim) or a local Supabase stack (supabase start). Set
// TEST_DATABASE_URL to point at it.

import pg from 'pg';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

// Return bigint/numeric as JS values that are easy to assert on.
pg.types.setTypeParser(20, (v) => Number(v)); // int8
pg.types.setTypeParser(1700, (v) => Number(v)); // numeric

export const pool = new pg.Pool({
  connectionString: process.env.TEST_DATABASE_URL ?? 'postgres://postgres@localhost:54322/chargekaro_test',
  max: 30,
});

export async function closePool() {
  await pool.end();
}

/** Runs a query as the database owner (bypasses RLS, like a migration). */
export async function sql(text, params = []) {
  const res = await pool.query(text, params);
  return res.rows;
}

export async function one(text, params = []) {
  const rows = await sql(text, params);
  return rows[0];
}

/**
 * Runs fn(query) in a transaction as `authenticated` with the given user id
 * in the JWT claims (what PostgREST does for a signed-in request), or as
 * `anon` / `service_role`. Commits on success, rolls back on error.
 */
export async function as(who, fn) {
  const client = await pool.connect();
  try {
    await client.query('begin');
    if (who === 'anon') {
      await client.query('set local role anon');
      await client.query(`select set_config('request.jwt.claims', '{"role":"anon"}', true)`);
    } else if (who === 'service') {
      await client.query('set local role service_role');
      await client.query(`select set_config('request.jwt.claims', '{"role":"service_role"}', true)`);
    } else {
      await client.query('set local role authenticated');
      await client.query(`select set_config('request.jwt.claims', $1, true)`, [
        JSON.stringify({ sub: who, role: 'authenticated' }),
      ]);
    }
    const query = async (text, params = []) => (await client.query(text, params)).rows;
    const result = await fn(query);
    await client.query('commit');
    return result;
  } catch (err) {
    await client.query('rollback').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

/** Shorthand: call an RPC as a user and return the first column of the first row. */
export async function rpc(who, fn, args = []) {
  const placeholders = args.map((_, i) => `$${i + 1}`).join(', ');
  return as(who, async (q) => {
    const rows = await q(`select public.${fn}(${placeholders}) as result`, args);
    return rows[0]?.result;
  });
}

/** Asserts that a promise rejects with a PostgREST-style error code. */
export async function rejectsWith(promise, { status, code, sqlstate }) {
  try {
    await promise;
  } catch (err) {
    if (status) assert.equal(err.code, `PT${status}`, `expected PT${status}, got ${err.code}: ${err.message}`);
    if (code) assert.equal(err.message, code, `expected ${code}, got ${err.message} (${err.detail ?? ''})`);
    if (sqlstate) assert.equal(err.code, sqlstate, `expected ${sqlstate}, got ${err.code}: ${err.message}`);
    return err;
  }
  assert.fail(`expected rejection${code ? ` ${code}` : ''}${status ? ` (${status})` : ''}`);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

export async function createUser(label = 'user') {
  const id = randomUUID();
  const email = `${label}-${id.slice(0, 8)}@test.local`;
  await sql(`insert into auth.users (id, email, raw_user_meta_data) values ($1, $2, $3)`, [
    id,
    email,
    { full_name: `${label[0].toUpperCase()}${label.slice(1)} Tester` },
  ]);
  return { id, email };
}

export async function createStaff(role, overrides = {}) {
  const user = await createUser(role.replace('_', ''));
  await sql(`insert into public.platform_staff (user_id, role) values ($1, $2)`, [user.id, role]);
  for (const [permission, granted] of Object.entries(overrides)) {
    await sql(
      `insert into public.platform_staff_permission_overrides (user_id, permission, granted) values ($1, $2, $3)`,
      [user.id, permission, granted],
    );
  }
  return user;
}

let phoneCounter = 1000;
export const nextPhone = () => `+9198${String(10000000 + phoneCounter++).slice(-8)}`;

/** Creates a business through the real RPC as its owner. */
export async function createBusiness(owner, name = 'Test Charging') {
  return rpc(owner.id, 'create_business', [
    `${name} Pvt Ltd`,
    name,
    'Owner Name',
    nextPhone(),
    owner.email,
    'private_limited',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
  ]);
}

export const stationInput = (overrides = {}) => ({
  name: 'Test Station',
  address_line1: '1 MG Road',
  city: 'Bengaluru',
  district: 'Bengaluru Urban',
  state: 'Karnataka',
  postal_code: '560001',
  latitude: 12.9716,
  longitude: 77.5946,
  contact_phone: nextPhone(),
  ...overrides,
});

/** Inserts a draft station as the owner (exercises RLS + guard trigger). */
export async function createStation(owner, businessId, overrides = {}) {
  const s = stationInput(overrides);
  return as(owner.id, async (q) => {
    const rows = await q(
      `insert into public.stations (business_id, name, address_line1, city, district, state, postal_code,
                                    latitude, longitude, contact_phone)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) returning id`,
      [businessId, s.name, s.address_line1, s.city, s.district, s.state, s.postal_code, s.latitude, s.longitude, s.contact_phone],
    );
    return rows[0].id;
  });
}

export async function addPoint(who, stationId, code = 'P1', extra = {}) {
  return as(who.id ?? who, async (q) => {
    const rows = await q(
      `insert into public.charging_points (station_id, code, current_type, max_power_kw)
       values ($1, $2, $3, $4) returning id`,
      [stationId, code, extra.current_type ?? 'dc', extra.max_power_kw ?? 30],
    );
    return rows[0].id;
  });
}

/** Opening hours as the owner. Default: open all day, every day. */
export async function setHours(who, stationId, opens = 0, closes = 1440, pointId = null) {
  await as(who.id ?? who, async (q) => {
    for (let d = 1; d <= 7; d++) {
      await q(
        `insert into public.station_operating_hours (station_id, charging_point_id, day_of_week, opens_minute, closes_minute)
         values ($1, $2, $3, $4, $5)`,
        [stationId, pointId, d, opens, closes],
      );
    }
  });
}

/** Uploads every required document record as the owner. */
export async function uploadRequiredDocs(owner, businessId, stationId) {
  const types = await sql(`select id, code, scope, requires_expiry_date from public.document_types where is_required and is_active`);
  const ids = [];
  for (const t of types) {
    const folder = t.scope === 'station' ? stationId : 'business';
    const id = await as(owner.id, async (q) => {
      const rows = await q(
        `insert into public.station_documents (business_id, station_id, document_type_id, storage_path, file_name,
                                               mime_type, size_bytes, expires_on)
         values ($1, $2, $3, $4, $5, 'application/pdf', 2048, $6) returning id`,
        [
          businessId,
          t.scope === 'station' ? stationId : null,
          t.id,
          `${businessId}/${folder}/${randomUUID()}.pdf`,
          `${t.code}.pdf`,
          t.requires_expiry_date ? '2030-01-01' : null,
        ],
      );
      return rows[0].id;
    });
    ids.push(id);
  }
  return ids;
}

/**
 * Full happy path: owner registers, adds a station with one point and hours,
 * uploads documents, submits; a reviewer approves everything.
 * Returns ids plus the actors used.
 */
export async function approvedStation({ owner, admin, points = ['P1'], hours = [0, 1440], policy = {} } = {}) {
  owner ??= await createUser('owner');
  admin ??= await createStaff('admin');
  const businessId = await createBusiness(owner);
  const stationId = await createStation(owner, businessId);
  const pointIds = [];
  for (const code of points) pointIds.push(await addPoint(owner, stationId, code));
  await setHours(owner, stationId, hours[0], hours[1]);
  const docIds = await uploadRequiredDocs(owner, businessId, stationId);
  const app = await one(`select id from public.station_applications where station_id = $1`, [stationId]);
  await rpc(owner.id, 'submit_station_application', [app.id]);
  await rpc(admin.id, 'start_application_review', [app.id]);
  for (const d of docIds) await rpc(admin.id, 'review_document', [d, 'approved', null]);
  await rpc(admin.id, 'approve_station_application', [app.id, 'ok']);
  const policyDefaults = { min_advance_minutes: 0, early_checkin_minutes: 60, ...policy };
  const sets = Object.keys(policyDefaults).map((k, i) => `${k} = $${i + 2}`).join(', ');
  await sql(`update public.station_booking_policies set ${sets} where station_id = $1`, [stationId, ...Object.values(policyDefaults)]);
  return { owner, admin, businessId, stationId, pointIds, applicationId: app.id };
}

/** Next slot start (aligned to `slot` minutes) at least `minAhead` minutes from now. */
export function slotStart(minAhead = 60, slot = 30, dayOffset = 0) {
  const ms = slot * 60 * 1000;
  const t = Date.now() + minAhead * 60 * 1000 + dayOffset * 86400000;
  return new Date(Math.ceil(t / ms) * ms);
}

export const addMinutes = (d, m) => new Date(d.getTime() + m * 60000);

let keyCounter = 0;
export const idemKey = () => `key-${randomUUID()}-${keyCounter++}`;

export async function hold(customer, pointId, start, minutes = 30, key = idemKey()) {
  return rpc(customer.id, 'create_booking_hold', [pointId, start.toISOString(), addMinutes(start, minutes).toISOString(), key, null]);
}

export async function setFee(paise) {
  await sql(`update public.platform_settings set value = to_jsonb($1::bigint) where key = 'booking_fee_paise'`, [paise]);
}

/** A wall-clock time in Asia/Kolkata (UTC+05:30, no DST) `dayOffset` days from today. */
export function ist(dayOffset, hh, mm = 0) {
  const nowIst = new Date(Date.now() + 330 * 60000);
  const d = Date.UTC(nowIst.getUTCFullYear(), nowIst.getUTCMonth(), nowIst.getUTCDate() + dayOffset, hh, mm);
  return new Date(d - 330 * 60000);
}

/**
 * Inserts a confirmed booking directly (as the database owner) so tests can
 * place bookings in the past or near now, which the booking RPC rightly refuses.
 */
export async function insertBooking({ customer, stationId, pointId, start, minutes = 30, status = 'confirmed', paymentStatus = 'not_required', fee = 0 }) {
  const end = addMinutes(start, minutes);
  return one(
    `insert into public.bookings (customer_id, station_id, charging_point_id, period, occupancy, status, payment_status,
                                  booking_fee_paise, hold_expires_at, confirmed_at, customer_display_name)
     values ($1, $2, $3, tstzrange($4, $5), tstzrange($4, $5), $6::public.booking_status, $7::public.booking_payment_status, $8,
             case when $6::text = 'payment_pending' then now() + interval '10 minutes' end,
             case when $6::text = 'confirmed' then now() end, 'Test C.')
     returning id, reference, qr_token`,
    [customer.id, stationId, pointId, start.toISOString(), end.toISOString(), status, paymentStatus, fee],
  );
}

/** Like rpc(), for functions returning a table row type: returns it as an object. */
export async function rpcRow(who, fn, args = []) {
  const placeholders = args.map((_, i) => `$${i + 1}`).join(', ');
  return as(who, async (q) => (await q(`select to_jsonb(r) as result from public.${fn}(${placeholders}) r`, args))[0]?.result);
}
