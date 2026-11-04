import { assertEquals, assertRejects, assertThrows } from 'jsr:@std/assert@1.0.13';
import { handleCheckin, type UserRpc, userRpc } from '../_shared/checkin.ts';
import { HttpError } from '../_shared/http.ts';

const station = '6f1c0f7e-6f43-4d3c-9d8e-1a2b3c4d5e6f';
const booking = '0b7a4c2e-1111-4222-8333-944455556666';

function fake() {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const db: UserRpc = {
    rpc<T>(fn: string, args: Record<string, unknown> = {}) {
      calls.push({ fn, args });
      return Promise.resolve({ result: 'ok' } as T);
    },
  };
  return { db, calls };
}

Deno.test('verify-booking-qr forwards only station, payload and device', async () => {
  const { db, calls } = fake();
  await handleCheckin(db, 'verify-booking-qr', { station_id: station, qr: 'CKB2:abc', device_id: 'd1', staff_id: 'x' });
  assertEquals(calls, [{ fn: 'verify_booking_qr', args: { p_station_id: station, p_payload: 'CKB2:abc', p_device_id: 'd1' } }]);
});

Deno.test('checkin-booking validates method, ids and reason fields', async () => {
  const { db, calls } = fake();
  await assertRejects(() => handleCheckin(db, 'checkin-booking', { station_id: station, booking_id: booking, method: 'offline' }), HttpError);
  await assertRejects(() => handleCheckin(db, 'checkin-booking', { station_id: "1' or 1=1", booking_id: booking, method: 'manual' }), HttpError);
  await assertRejects(() => handleCheckin(db, 'checkin-booking', { station_id: station, booking_id: booking, method: 'qr', idempotency_key: 'k-12345678' }), HttpError);
  await assertRejects(() => handleCheckin(db, 'checkin-booking', { station_id: station, booking_id: booking, method: 'manual', idempotency_key: 'k-12345678' }), HttpError);
  await handleCheckin(db, 'checkin-booking', {
    station_id: station, booking_id: booking, method: 'manual', idempotency_key: 'k-12345678', reason_code: 'qr_damaged',
    payment_status: 'paid',
  });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].fn, 'checkin_booking');
  assertEquals(calls[0].args.p_reason_code, 'qr_damaged');
  assertEquals('payment_status' in calls[0].args, false, 'client payment status is never forwarded');
});

Deno.test('sync-offline-checkins requires 1 to 50 events', async () => {
  const { db, calls } = fake();
  await assertRejects(() => handleCheckin(db, 'sync-offline-checkins', { events: [] }), HttpError);
  await assertRejects(() => handleCheckin(db, 'sync-offline-checkins', { events: Array(51).fill({}) }), HttpError);
  await handleCheckin(db, 'sync-offline-checkins', { events: [{ event_id: 'e' }] });
  assertEquals(calls[0].fn, 'sync_offline_checkins');
});

Deno.test('charging routes map to their RPCs', async () => {
  const { db, calls } = fake();
  await handleCheckin(db, 'start-charging', { booking_id: booking, idempotency_key: 'k-12345678' });
  await handleCheckin(db, 'complete-charging', { booking_id: booking, idempotency_key: 'k-12345678' });
  assertEquals(calls.map((c) => c.fn), ['start_charging', 'complete_charging']);
});

Deno.test('requests without a bearer token are rejected before any database call', () => {
  const err = assertThrows(() => userRpc(new Request('http://x', { method: 'POST' })), HttpError);
  assertEquals(err.status, 401);
});
