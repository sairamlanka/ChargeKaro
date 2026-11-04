// Booking check-in endpoints. Thin wrappers over the check-in RPCs in
// 20261103000100_checkin.sql: every call runs as the signed-in staff member
// (their JWT is forwarded), so station permissions, row locks, idempotency
// and the audit trail all live in one place in the database. Nothing here
// trusts a client-supplied staff id, payment status or customer detail.

import { createClient } from 'npm:@supabase/supabase-js@2.117.3';
import { type DbError, fromDbError, HttpError } from './http.ts';
import { requireEnv } from './env.ts';

/** RPC port running with the caller's identity (never the service role). */
export interface UserRpc {
  rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T>;
}

export function userRpc(req: Request): UserRpc {
  const auth = req.headers.get('Authorization');
  if (!auth?.startsWith('Bearer ') || auth.length < 20) throw new HttpError(401, 'not_authenticated');
  const client = createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_ANON_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: auth } },
  });
  return {
    async rpc<T>(fn: string, args: Record<string, unknown> = {}) {
      const { data, error } = await client.rpc(fn, args);
      if (error) {
        // PostgREST answers 401 for an expired or invalid JWT.
        if (error.code === 'PGRST301' || /JWT/i.test(error.message)) throw new HttpError(401, 'not_authenticated');
        throw fromDbError(error as DbError);
      }
      return data as T;
    },
  };
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function str(v: unknown, field: string, { max = 200, optional = false } = {}): string | null {
  if (v === undefined || v === null || v === '') {
    if (optional) return null;
    throw new HttpError(422, 'invalid_request', `${field} is required`);
  }
  if (typeof v !== 'string' || v.length > max) throw new HttpError(422, 'invalid_request', `${field} is invalid`);
  return v;
}

function id(v: unknown, field: string): string {
  const s = str(v, field)!;
  if (!uuid.test(s)) throw new HttpError(422, 'invalid_request', `${field} must be a UUID`);
  return s;
}

export type CheckinRoute = 'verify-booking-qr' | 'checkin-booking' | 'sync-offline-checkins' | 'start-charging' | 'complete-charging';

/** Validates the request body and calls the matching RPC. */
export async function handleCheckin(db: UserRpc, route: CheckinRoute, body: Record<string, unknown>): Promise<unknown> {
  switch (route) {
    case 'verify-booking-qr':
      return await db.rpc('verify_booking_qr', {
        p_station_id: id(body.station_id, 'station_id'),
        p_payload: str(body.qr, 'qr', { max: 100 }),
        p_device_id: str(body.device_id, 'device_id', { max: 100, optional: true }),
      });
    case 'checkin-booking': {
      const method = str(body.method, 'method');
      if (method !== 'qr' && method !== 'manual') throw new HttpError(422, 'invalid_request', 'method must be qr or manual');
      return await db.rpc('checkin_booking', {
        p_station_id: id(body.station_id, 'station_id'),
        p_booking_id: id(body.booking_id, 'booking_id'),
        p_method: method,
        p_idempotency_key: str(body.idempotency_key, 'idempotency_key', { max: 80 }),
        p_qr_payload: str(body.qr, 'qr', { max: 100, optional: method !== 'qr' }),
        p_reason_code: str(body.reason_code, 'reason_code', { max: 40, optional: method !== 'manual' }),
        p_reason_note: str(body.reason_note, 'reason_note', { max: 300, optional: true }),
        p_device_id: str(body.device_id, 'device_id', { max: 100, optional: true }),
        p_override_reason: str(body.override_reason, 'override_reason', { max: 300, optional: true }),
      });
    }
    case 'sync-offline-checkins': {
      const events = body.events;
      if (!Array.isArray(events) || events.length === 0 || events.length > 50) {
        throw new HttpError(422, 'invalid_request', 'events must hold 1 to 50 items');
      }
      return await db.rpc('sync_offline_checkins', { p_events: events });
    }
    case 'start-charging':
    case 'complete-charging':
      return await db.rpc(route === 'start-charging' ? 'start_charging' : 'complete_charging', {
        p_booking_id: id(body.booking_id, 'booking_id'),
        p_idempotency_key: str(body.idempotency_key, 'idempotency_key', { max: 80 }),
        p_device_id: str(body.device_id, 'device_id', { max: 100, optional: true }),
      });
  }
}
