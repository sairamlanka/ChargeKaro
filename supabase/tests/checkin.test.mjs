// Secure booking check-in: QR, manual, offline sync, overrides, charging,
// idempotency, concurrency, privacy and audit (20261103000100_checkin.sql).
import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import {
  as, rpc, sql, one, rejectsWith, closePool, createUser, approvedStation, idemKey, setFee, ist, insertBooking, nextPhone,
} from './lib/db.mjs';

after(closePool);
before(() => setFee(0));

const minute = 60000;
const soon = () => new Date(Math.floor(Date.now() / minute) * minute + 5 * minute);

/** A station with an owner, an assigned pump boy, a manager and a customer booking starting in 5 minutes. */
async function setup({ policy = {}, start = soon(), minutes = 30, status, paymentStatus, phone } = {}) {
  const owner = await createUser('owner');
  const station = await approvedStation({ owner, points: ['A', 'B'], policy });
  const staff = await createUser('staff');
  const manager = await createUser('manager');
  await rpc(owner.id, 'add_business_member', [station.businessId, staff.email, 'station_staff', null, [station.stationId]]);
  await rpc(owner.id, 'add_business_member', [station.businessId, manager.email, 'station_manager', null, [station.stationId]]);
  const customer = await createUser('customer');
  if (phone) await sql(`update public.profiles set phone = $2, full_name = 'Asha Kumari' where id = $1`, [customer.id, phone]);
  const booking = await insertBooking({ customer, stationId: station.stationId, pointId: station.pointIds[0], start, minutes, status, paymentStatus });
  return { ...station, owner, staff, manager, customer, booking };
}

// Fixtures insert bookings "now"; real bookings exist before the driver
// arrives. Bypasses the immutability trigger for the test only.
const backdate = (bookingId, hours = 48) => sql(
  `begin; set local session_replication_role = replica;
   update public.bookings set created_at = now() - interval '${hours} hours' where id = '${bookingId}'; commit;`);

const qrFor = async (customer, bookingId) => (await rpc(customer.id, 'get_my_booking_qr', [bookingId])).qr_payload;
const manual = (who, s, reason = 'qr_not_working', extra = {}) =>
  rpc(who.id, 'checkin_booking', [s.stationId, s.booking.id, 'manual', extra.key ?? idemKey(), null, reason, extra.note ?? null,
                                   extra.device ?? 'device-1', extra.override ?? null]);
const logs = (bookingId) => sql(`select * from public.booking_checkin_logs where booking_id = $1 order by created_at`, [bookingId]);

describe('QR codes', () => {
  test('a valid QR verifies with minimal data, then checks in once', async () => {
    const s = await setup();
    const qr = await qrFor(s.customer, s.booking.id);
    assert.match(qr, /^CKB2:[A-Za-z0-9_-]{43}$/);
    const v = await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, qr, 'dev-1']);
    assert.equal(v.result, 'verified');
    assert.equal(v.eligible, true);
    assert.equal(v.booking.customer_display_name, null);
    assert.equal(v.booking.customer_phone, null);
    assert.equal(v.booking.customer_revealed, false);
    const r = await rpc(s.staff.id, 'checkin_booking', [s.stationId, s.booking.id, 'qr', idemKey(), qr]);
    assert.equal(r.result, 'accepted');
    assert.equal(r.booking.customer_revealed, true);
    assert.equal(r.booking.customer_display_name, 'Customer Tester');
    const b = await one(`select status, verification_status, checkin_method, checked_in_by from public.bookings where id = $1`, [s.booking.id]);
    assert.deepEqual(b, { status: 'arrived', verification_status: 'verified', checkin_method: 'qr', checked_in_by: s.staff.id });
  });

  test('only a hash is stored and only one code is live per booking', async () => {
    const s = await setup();
    const first = await qrFor(s.customer, s.booking.id);
    const second = await qrFor(s.customer, s.booking.id);
    assert.notEqual(first, second);
    const live = await sql(`select token_hash from public.booking_qr_tokens where booking_id = $1 and revoked_at is null and consumed_at is null`, [s.booking.id]);
    assert.equal(live.length, 1);
    assert.equal(live[0].token_hash.length, 32, 'sha-256 digest');
    const stored = await sql(`select encode(token_hash, 'escape') t from public.booking_qr_tokens where booking_id = $1`, [s.booking.id]);
    assert.ok(stored.every((r) => !r.t.includes(first.slice(5))), 'raw token never stored');
    const old = await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, first]);
    assert.equal(old.code, 'qr_revoked', 'a screenshot of a replaced code no longer works');
    assert.equal((await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, second])).result, 'verified');
  });

  test('invalid, corrupted and legacy payloads are rejected', async () => {
    const s = await setup();
    for (const [payload, code] of [
      ['hello', 'invalid_qr'],
      ['CKB2:short', 'invalid_qr'],
      [`CKB2:${'A'.repeat(43)}`, 'invalid_qr'],
      ["CKB2:'; drop table public.bookings; --", 'invalid_qr'],
      ['CKB1:QbxapCDUY2rcs52hRgNCsA', 'qr_outdated'],
    ]) {
      const r = await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, payload]);
      assert.equal(r.result, 'rejected');
      assert.equal(r.code, code, payload);
    }
    assert.ok(await one(`select 1 from public.bookings limit 1`), 'bookings intact');
  });

  test('QR reused after check-in, and QR from another station', async () => {
    const s = await setup();
    const qr = await qrFor(s.customer, s.booking.id);
    await rpc(s.staff.id, 'checkin_booking', [s.stationId, s.booking.id, 'qr', idemKey(), qr]);
    assert.equal((await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, qr])).code, 'already_checked_in');

    const other = await setup();
    const otherQr = await qrFor(other.customer, other.booking.id);
    const wrong = await rpc(s.owner.id, 'verify_booking_qr', [s.stationId, otherQr]);
    assert.equal(wrong.code, 'wrong_station');
    assert.equal(wrong.booking, undefined, 'nothing about the other booking leaks');
  });

  test('QR scanned by unauthorized staff or a customer reveals nothing', async () => {
    const s = await setup();
    const qr = await qrFor(s.customer, s.booking.id);
    const stranger = await createUser('stranger');
    assert.equal((await rpc(stranger.id, 'verify_booking_qr', [s.stationId, qr])).code, 'not_authorized');
    assert.equal((await rpc(s.customer.id, 'verify_booking_qr', [s.stationId, qr])).code, 'not_authorized');
    assert.equal((await rpc(s.customer.id, 'checkin_booking', [s.stationId, s.booking.id, 'qr', idemKey(), qr])).code, 'not_authorized');
    await rejectsWith(rpc('anon', 'verify_booking_qr', [s.stationId, qr]), { sqlstate: '42501' });
  });

  test('a QR for one booking cannot check in another booking', async () => {
    const s = await setup();
    const second = await insertBooking({ customer: s.customer, stationId: s.stationId, pointId: s.pointIds[1], start: soon() });
    const qr = await qrFor(s.customer, s.booking.id);
    const r = await rpc(s.staff.id, 'checkin_booking', [s.stationId, second.id, 'qr', idemKey(), qr]);
    assert.equal(r.code, 'invalid_qr');
  });

  test('cancelling a booking revokes its QR; cancelled bookings get no new QR', async () => {
    const s = await setup();
    const qr = await qrFor(s.customer, s.booking.id);
    await rpc(s.customer.id, 'cancel_booking', [s.booking.id, 'Changed plans']);
    assert.equal((await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, qr])).code, 'booking_cancelled');
    await rejectsWith(rpc(s.customer.id, 'get_my_booking_qr', [s.booking.id]), { status: 409, code: 'qr_not_available' });
  });

  test('QR expires when the arrival window closes', async () => {
    const s = await setup({ start: new Date(Date.now() - 20 * minute), minutes: 60, policy: { arrival_grace_minutes: 10 } });
    await rejectsWith(rpc(s.customer.id, 'get_my_booking_qr', [s.booking.id]), { status: 409, code: 'qr_expired' });
  });

  test('repeated failed scans are rate limited (brute force)', async () => {
    const s = await setup();
    for (let i = 0; i < 15; i++) await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, `CKB2:${randomUUID().replaceAll('-', '').padEnd(43, 'x')}`]);
    const qr = await qrFor(s.customer, s.booking.id);
    assert.equal((await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, qr])).code, 'rate_limited');
  });

  test('audit rows never contain the raw token', async () => {
    const s = await setup();
    const qr = await qrFor(s.customer, s.booking.id);
    await rpc(s.staff.id, 'verify_booking_qr', [s.stationId, qr, 'dev-1']);
    await rpc(s.staff.id, 'checkin_booking', [s.stationId, s.booking.id, 'qr', idemKey(), qr, null, null, 'dev-1']);
    const rows = await logs(s.booking.id);
    assert.deepEqual(rows.map((r) => r.action), ['qr_verify', 'checkin']);
    assert.ok(rows.every((r) => !JSON.stringify(r).includes(qr.slice(5))));
    assert.equal(rows[1].device_id, 'dev-1');
  });
});

describe('manual check-in', () => {
  test('requires a reason; Other requires a note', async () => {
    const s = await setup();
    assert.equal((await manual(s.staff, s, null)).code, 'reason_required');
    assert.equal((await manual(s.staff, s, 'made_up')).code, 'reason_required');
    assert.equal((await manual(s.staff, s, 'other')).code, 'reason_note_required');
    const ok = await manual(s.staff, s, 'other', { note: 'Customer phone battery dead' });
    assert.equal(ok.result, 'accepted');
    const b = await one(`select checkin_method, checkin_reason from public.bookings where id = $1`, [s.booking.id]);
    assert.deepEqual(b, { checkin_method: 'manual', checkin_reason: 'Other: Customer phone battery dead' });
  });

  test('search by booking ID or mobile number returns no customer details', async () => {
    const phone = nextPhone();
    const s = await setup({ phone });
    const local = phone.slice(3);
    for (const q of [s.booking.reference, s.booking.reference.toLowerCase(), local, `0${local}`, `91${local}`, phone, `+91 ${local.slice(0, 5)} ${local.slice(5)}`]) {
      const r = await rpc(s.staff.id, 'search_bookings_for_checkin', [s.stationId, q]);
      assert.equal(r.bookings.length, 1, q);
      const hit = r.bookings[0];
      assert.equal(hit.reference, s.booking.reference);
      assert.equal(hit.customer_display_name, null);
      assert.equal(hit.customer_phone, null);
    }
    assert.deepEqual((await rpc(s.staff.id, 'search_bookings_for_checkin', [s.stationId, '9000000001'])).bookings, []);
    assert.equal((await rpc(s.staff.id, 'search_bookings_for_checkin', [s.stationId, 'abc'])).code, 'invalid_query');
    const searchLogs = await sql(`select metadata from public.booking_checkin_logs where staff_id = $1 and action = 'search'`, [s.staff.id]);
    assert.ok(searchLogs.every((l) => !JSON.stringify(l).includes(local)), 'phone numbers are not logged');
  });

  test('a customer with bookings at several stations: search shows only this station', async () => {
    const phone = nextPhone();
    const s = await setup({ phone });
    const second = await insertBooking({ customer: s.customer, stationId: s.stationId, pointId: s.pointIds[1], start: soon(), minutes: 30 });
    const other = await approvedStation();
    await insertBooking({ customer: s.customer, stationId: other.stationId, pointId: other.pointIds[0], start: soon() });
    const r = await rpc(s.staff.id, 'search_bookings_for_checkin', [s.stationId, phone]);
    assert.deepEqual(r.bookings.map((b) => b.id).sort(), [s.booking.id, second.id].sort());
  });

  test('search is rate limited against enumeration', async () => {
    const s = await setup();
    for (let i = 0; i < 20; i++) await rpc(s.staff.id, 'search_bookings_for_checkin', [s.stationId, `90000000${String(i).padStart(2, '0')}`]);
    assert.equal((await rpc(s.staff.id, 'search_bookings_for_checkin', [s.stationId, s.booking.reference])).code, 'rate_limited');
  });

  test('outside the window: pump boy is refused, manager can override with a reason', async () => {
    const s = await setup({ start: new Date(Date.now() - 20 * minute), minutes: 60, policy: { arrival_grace_minutes: 10 } });
    const r = await manual(s.staff, s);
    assert.equal(r.code, 'too_late');
    assert.equal(r.override_allowed, false);
    assert.equal((await manual(s.staff, s, 'qr_not_working', { override: 'Traffic jam on NH65' })).code, 'override_not_allowed');
    assert.equal((await manual(s.manager, s, 'qr_not_working', { override: 'x' })).code, 'override_reason_required');
    const ok = await manual(s.manager, s, 'qr_not_working', { override: 'Traffic jam on NH65' });
    assert.equal(ok.result, 'accepted');
    const log = (await logs(s.booking.id)).find((l) => l.action === 'override');
    assert.equal(log.manager_id, s.manager.id);
    assert.equal(log.from_status, 'confirmed');
    assert.equal(log.to_status, 'arrived');
    assert.equal(log.metadata.overridden_problem, 'too_late');
  });

  test('payment problems can never be overridden', async () => {
    const s = await setup({ status: 'confirmed', paymentStatus: 'refund_pending' });
    const r = await manual(s.manager, s, 'qr_not_working', { override: 'Customer insists they paid' });
    assert.equal(r.code, 'payment_reversed');
    const failed = await setup({ status: 'payment_pending', paymentStatus: 'failed' });
    assert.equal((await manual(failed.owner, failed)).code, 'payment_pending');
  });

  test('a no-show can be reversed by a manager override while the slot is free', async () => {
    const s = await setup({ start: new Date(Date.now() - 20 * minute), minutes: 60, policy: { arrival_grace_minutes: 10 } });
    await sql(`select public.run_booking_jobs()`);
    assert.equal((await one(`select status from public.bookings where id = $1`, [s.booking.id])).status, 'no_show');
    assert.equal((await manual(s.staff, s)).code, 'marked_no_show');
    const ok = await manual(s.owner, s, 'cannot_access_booking', { override: 'Arrived late, disputed no-show' });
    assert.equal(ok.booking.status, 'arrived');
  });

  test('completed and expired bookings cannot be checked in', async () => {
    const s = await setup({ status: 'expired', paymentStatus: 'abandoned' });
    assert.equal((await manual(s.owner, s, 'qr_not_working', { override: 'Please let them in' })).code, 'booking_expired');
  });
});

describe('idempotency and concurrency', () => {
  test('a retried request with the same key returns the original result once', async () => {
    const s = await setup();
    const key = idemKey();
    const first = await manual(s.staff, s, 'qr_not_working', { key });
    const second = await manual(s.staff, s, 'qr_not_working', { key });
    assert.equal(first.result, 'accepted');
    assert.equal(second.result, 'accepted');
    assert.equal(second.replayed, true);
    assert.equal((await logs(s.booking.id)).filter((l) => l.action === 'checkin').length, 1, 'one audit row');
    const msgs = await sql(`select count(*)::int n from public.notifications where dedupe_key like $1`, [`booking.checked_in.customer:${s.booking.id}%`]);
    assert.equal(msgs[0].n, 1, 'one customer notification');
  });

  test('two staff checking in the same booking at once: exactly one succeeds', async () => {
    const s = await setup();
    const results = await Promise.all([manual(s.staff, s), manual(s.manager, s), manual(s.owner, s)]);
    assert.equal(results.filter((r) => r.result === 'accepted').length, 1);
    assert.ok(results.filter((r) => r.result === 'rejected').every((r) => ['already_checked_in', 'checked_in_by_other'].includes(r.code)));
    assert.equal((await sql(`select count(*)::int n from public.check_ins where booking_id = $1`, [s.booking.id]))[0].n, 1);
  });

  test('charging cannot start twice or before arrival', async () => {
    const s = await setup();
    assert.equal((await rpc(s.staff.id, 'start_charging', [s.booking.id, idemKey()])).code, 'not_arrived');
    await manual(s.staff, s);
    const [a, b] = await Promise.all([rpc(s.staff.id, 'start_charging', [s.booking.id, idemKey()]),
                                      rpc(s.manager.id, 'start_charging', [s.booking.id, idemKey()])]);
    assert.deepEqual([a.result, b.result].sort(), ['accepted', 'rejected']);
    assert.equal((await rpc(s.staff.id, 'complete_charging', [s.booking.id, idemKey()])).booking.status, 'completed');
    assert.equal((await rpc(s.staff.id, 'complete_charging', [s.booking.id, idemKey()])).code, 'booking_completed');
  });
});

describe('offline sync', () => {
  const event = (s, extra = {}) => ({
    event_id: randomUUID(), booking_id: s.booking.id, station_id: s.stationId,
    offline_at: new Date().toISOString(), device_id: 'tablet-7', ...extra,
  });

  test('cache holds no customer data; an accepted event is verified server-side', async () => {
    const s = await setup();
    const cache = await rpc(s.staff.id, 'get_offline_checkin_cache', [s.stationId, 'tablet-7']);
    const row = cache.bookings.find((b) => b.id === s.booking.id);
    assert.ok(row);
    assert.deepEqual(Object.keys(row).filter((k) => /name|phone|email|vehicle|customer/.test(k)), []);
    const e = event(s);
    const res = await rpc(s.staff.id, 'sync_offline_checkins', [JSON.stringify([e])]);
    assert.equal(res.results[0].result, 'accepted');
    const log = (await logs(s.booking.id)).find((l) => l.action === 'offline_sync');
    assert.equal(log.sync_status, 'accepted');
    assert.equal(new Date(log.offline_timestamp).toISOString(), e.offline_at);
    assert.equal(log.device_id, 'tablet-7');
    assert.equal((await one(`select checkin_method from public.bookings where id = $1`, [s.booking.id])).checkin_method, 'offline');
  });

  test('syncing the same event twice is idempotent', async () => {
    const s = await setup();
    const e = event(s);
    const [a, b] = await Promise.all([rpc(s.staff.id, 'sync_offline_checkins', [JSON.stringify([e])]),
                                      rpc(s.staff.id, 'sync_offline_checkins', [JSON.stringify([e])])]);
    assert.deepEqual([a.results[0].result, b.results[0].result], ['accepted', 'accepted']);
    assert.equal((await logs(s.booking.id)).filter((l) => l.action === 'offline_sync').length, 1);
  });

  test('conflicts are rejected, never silently applied', async () => {
    const cancelled = await setup();
    await rpc(cancelled.customer.id, 'cancel_booking', [cancelled.booking.id, 'Plans changed']);
    const byOther = await setup();
    await manual(byOther.manager, byOther);
    const otherStation = await setup();
    const elsewhere = await setup();
    const clock = await setup();
    const old = await setup({ start: new Date(Date.now() - 30 * 3600000), minutes: 30 });
    await backdate(old.booking.id);
    const reversed = await setup({ status: 'confirmed', paymentStatus: 'refunded' });

    const res = await rpc(cancelled.staff.id, 'sync_offline_checkins', [JSON.stringify([
      event(cancelled),
      { ...event(otherStation), station_id: cancelled.stationId },
      event(elsewhere),
      event(cancelled, { booking_id: 'not-a-uuid' }),
    ])]);
    assert.deepEqual(res.results.map((r) => r.code), ['booking_cancelled', 'booking_not_found', 'not_authorized', 'invalid_request']);
    assert.equal((await rpc(byOther.staff.id, 'sync_offline_checkins', [JSON.stringify([event(byOther)])])).results[0].code, 'checked_in_by_other');
    const future = new Date(Date.now() + 60 * minute).toISOString();
    assert.equal((await rpc(clock.staff.id, 'sync_offline_checkins', [JSON.stringify([event(clock, { offline_at: future })])])).results[0].code, 'clock_invalid');
    const longAgo = new Date(Date.now() - 30 * 3600000 + 2 * minute).toISOString();
    assert.equal((await rpc(old.staff.id, 'sync_offline_checkins', [JSON.stringify([event(old, { offline_at: longAgo })])])).results[0].code, 'sync_too_late');
    assert.equal((await rpc(reversed.staff.id, 'sync_offline_checkins', [JSON.stringify([event(reversed)])])).results[0].code, 'payment_reversed');
    assert.equal((await one(`select status from public.bookings where id = $1`, [cancelled.booking.id])).status, 'cancelled');
  });

  test('a no-show recorded before sync is flagged for a manager', async () => {
    const s = await setup({ start: new Date(Date.now() - 20 * minute), minutes: 60, policy: { arrival_grace_minutes: 10 } });
    const arrivedAt = new Date(Date.now() - 15 * minute).toISOString();
    await backdate(s.booking.id);
    await sql(`select public.run_booking_jobs()`);
    const r = await rpc(s.staff.id, 'sync_offline_checkins', [JSON.stringify([event(s, { offline_at: arrivedAt })])]);
    assert.equal(r.results[0].code, 'no_show_conflict');
    assert.equal((await one(`select status from public.bookings where id = $1`, [s.booking.id])).status, 'no_show');
  });

  test('staff whose access was revoked cannot sync', async () => {
    const s = await setup();
    const member = await one(`select id from public.business_members where user_id = $1`, [s.staff.id]);
    await rpc(s.owner.id, 'revoke_business_member', [member.id]);
    const r = await rpc(s.staff.id, 'sync_offline_checkins', [JSON.stringify([event(s)])]);
    assert.equal(r.results[0].code, 'not_authorized');
  });

  test('two staff members sync offline check-ins for the same booking', async () => {
    const s = await setup();
    const [a, b] = await Promise.all([rpc(s.staff.id, 'sync_offline_checkins', [JSON.stringify([event(s)])]),
                                      rpc(s.manager.id, 'sync_offline_checkins', [JSON.stringify([event(s)])])]);
    const results = [a.results[0], b.results[0]];
    assert.equal(results.filter((r) => r.result === 'accepted').length, 1);
    assert.equal(results.find((r) => r.result === 'rejected').code, 'checked_in_by_other');
  });
});

describe('privacy and table access', () => {
  test('staff cannot read customer columns or write bookings, tokens or logs directly', async () => {
    const s = await setup();
    await rejectsWith(as(s.staff.id, (q) => q(`select customer_display_name from public.bookings`)), { sqlstate: '42501' });
    await rejectsWith(as(s.staff.id, (q) => q(`select vehicle_label from public.bookings`)), { sqlstate: '42501' });
    await rejectsWith(as(s.staff.id, (q) => q(`update public.bookings set payment_status = 'paid' where id = $1`, [s.booking.id])), { sqlstate: '42501' });
    await rejectsWith(as(s.staff.id, (q) => q(`update public.bookings set station_id = station_id where id = $1`, [s.booking.id])), { sqlstate: '42501' });
    await rejectsWith(as(s.staff.id, (q) => q(`update public.bookings set checked_in_at = now() where id = $1`, [s.booking.id])), { sqlstate: '42501' });
    await rejectsWith(as(s.staff.id, (q) => q(`select * from public.booking_qr_tokens`)), { sqlstate: '42501' });
    await rejectsWith(as(s.staff.id, (q) => q(`insert into public.booking_checkin_logs (action, result) values ('checkin', 'accepted')`)), { sqlstate: '42501' });
    await manual(s.staff, s);
    await rejectsWith(sql(`update public.booking_checkin_logs set result = 'rejected' where booking_id = $1`, [s.booking.id]), { status: 403, code: 'immutable_record' });
  });

  test('station lists mask customers until arrival; staff see only their own log entries', async () => {
    const s = await setup();
    const list = await rpc(s.staff.id, 'get_station_bookings', [s.stationId, ist(-1, 0).toISOString(), ist(2, 0).toISOString()]);
    const before = list.find((b) => b.id === s.booking.id);
    assert.equal(before.customer_display_name, null);
    assert.equal(before.vehicle_label, null);
    await manual(s.manager, s);
    const after = await rpc(s.staff.id, 'get_station_booking', [s.booking.id]);
    assert.equal(after.customer_display_name, 'Customer Tester');
    assert.equal((await rpc(s.staff.id, 'get_checkin_history', [s.stationId])).length, 0, 'pump boy sees only own entries');
    assert.ok((await rpc(s.manager.id, 'get_checkin_history', [s.stationId])).length >= 1);
    const other = await approvedStation();
    await rejectsWith(rpc(other.owner.id, 'get_station_booking', [s.booking.id]), { status: 404 });
  });
});

describe('notifications', () => {
  test('arrival, charging and completion notify the customer once each; no-show too', async () => {
    const s = await setup();
    await manual(s.staff, s);
    await rpc(s.staff.id, 'start_charging', [s.booking.id, idemKey()]);
    await rpc(s.staff.id, 'complete_charging', [s.booking.id, idemKey()]);
    const types = (await sql(`select type from public.notifications where recipient_id = $1 order by created_at`, [s.customer.id])).map((r) => r.type);
    assert.deepEqual(types.filter((t) => t !== 'booking.confirmed'), ['booking.checked_in', 'booking.charging_started', 'booking.completed']);

    const ns = await setup({ start: new Date(Date.now() - 20 * minute), minutes: 60, policy: { arrival_grace_minutes: 10 } });
    await sql(`select public.run_booking_jobs()`);
    await sql(`select public.run_booking_jobs()`);
    const n = await sql(`select count(*)::int n from public.notifications where recipient_id = $1 and type = 'booking.no_show'`, [ns.customer.id]);
    assert.equal(n[0].n, 1);
  });

  test('business notifications carry the reference, not the customer name', async () => {
    const s = await setup();
    await manual(s.staff, s);
    const n = await sql(`select body from public.notifications where recipient_id = $1 and type = 'booking.checked_in'`, [s.owner.id]);
    assert.ok(n[0].body.includes(s.booking.reference));
    assert.ok(!n[0].body.includes('Test'));
  });
});

describe('arrival window', () => {
  test('boundaries are inclusive and follow the station policy', async () => {
    const s = await setup({ policy: { early_checkin_minutes: 15, arrival_grace_minutes: 10 } });
    const w = await one(`select w.opens_at, w.closes_at from public.bookings b, private.checkin_window(b) w where b.id = $1`, [s.booking.id]);
    const b = await one(`select * from public.bookings where id = $1`, [s.booking.id]);
    const problem = async (at) => (await one(`select private.checkin_problem(b, $2) p from public.bookings b where b.id = $1`, [b.id, at])).p;
    assert.equal(await problem(w.opens_at), null);
    assert.equal(await problem(w.closes_at), null);
    assert.equal(await problem(new Date(w.opens_at.getTime() - 1000)), 'too_early');
    assert.equal(await problem(new Date(w.closes_at.getTime() + 1000)), 'too_late');
  });

  test('the platform can switch the late cut-off to slot end + grace', async () => {
    const s = await setup({ start: new Date(Date.now() - 20 * minute), minutes: 60, policy: { arrival_grace_minutes: 10 } });
    try {
      await sql(`update public.platform_settings set value = jsonb_set(value, '{late_window_basis}', '"end"') where key = 'checkin_settings'`);
      assert.equal((await manual(s.staff, s)).result, 'accepted');
    } finally {
      await sql(`update public.platform_settings set value = jsonb_set(value, '{late_window_basis}', '"start"') where key = 'checkin_settings'`);
    }
  });

  test('phone normalisation', async () => {
    const cases = {
      '9876543210': '+919876543210', '09876543210': '+919876543210', '919876543210': '+919876543210',
      '+91 98765-43210': '+919876543210', '+14155550123': '+14155550123', '0014155550123': '+14155550123',
      '12345': null, '5876543210': null, 'abc': null, '+91abc': null,
    };
    for (const [input, expected] of Object.entries(cases)) {
      assert.equal((await one(`select private.normalize_phone($1) p`, [input])).p, expected, input);
    }
  });
});
