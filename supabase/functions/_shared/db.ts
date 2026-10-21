// Thin database port used by handlers so they can be unit-tested with a fake.
// The real implementation wraps a service-role supabase-js client and must
// only ever run inside Edge Functions.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { type DbError, fromDbError, HttpError } from './http.ts';
import { requireEnv } from './env.ts';

export interface Db {
  rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T>;
  /** Looks up which customer owns the booking behind a gateway order. */
  orderOwner(gatewayOrderId: string): Promise<{ booking_id: string; customer_id: string } | null>;
}

export function serviceDb(): Db {
  const client: SupabaseClient = createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return {
    async rpc<T>(fn: string, args: Record<string, unknown> = {}) {
      const { data, error } = await client.rpc(fn, args);
      if (error) throw fromDbError(error as DbError);
      return data as T;
    },
    async orderOwner(gatewayOrderId: string) {
      const { data, error } = await client
        .from('payment_orders')
        .select('booking_id, bookings!inner(customer_id)')
        .eq('gateway_order_id', gatewayOrderId)
        .maybeSingle();
      if (error) throw fromDbError(error as DbError);
      if (!data) return null;
      // deno-lint-ignore no-explicit-any
      const booking = (data as any).bookings;
      return { booking_id: data.booking_id as string, customer_id: booking.customer_id as string };
    },
  };
}

/** Resolves the signed-in user from the request's bearer token. */
export async function requireUserId(req: Request): Promise<string> {
  const auth = req.headers.get('Authorization');
  if (!auth?.startsWith('Bearer ')) throw new HttpError(401, 'not_authenticated');
  const client = createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_ANON_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: auth } },
  });
  const { data, error } = await client.auth.getUser(auth.slice(7));
  if (error || !data.user) throw new HttpError(401, 'not_authenticated');
  return data.user.id;
}
