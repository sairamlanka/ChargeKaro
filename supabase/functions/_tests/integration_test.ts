// End-to-end: Edge Function handlers against the real database functions
// (service_role), with only Razorpay faked. Skipped unless TEST_DATABASE_URL
// points at a database prepared by scripts/db-reset-test.sh.
import { assertEquals } from 'jsr:@std/assert@1.0.13';
import pg from 'npm:pg@8.16.3';
import { createOrder, handleWebhook, processRefunds, verifyPayment } from '../_shared/payments.ts';
import { hmacSha256Hex, type PaymentGateway, type RazorpayPayment } from '../_shared/razorpay.ts';
import { type DbError, fromDbError } from '../_shared/http.ts';
import type { Db } from '../_shared/db.ts';

const url = Deno.env.get('TEST_DATABASE_URL');
const KEY_SECRET = 'it_key_secret';
const WEBHOOK_SECRET = 'it_webhook_secret';

function pgDb(pool: pg.Pool): Db {
  return {
    async rpc<T>(fn: string, args: Record<string, unknown> = {}) {
      const client = await pool.connect();
      try {
        await client.query('begin');
        await client.query('set local role service_role');
        const keys = Object.keys(args);
        const call = `public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')})`;
        const { rows: [meta] } = await client.query(`select proretset from pg_proc where proname = $1 and pronamespace = 'public'::regnamespace`, [fn]);
        const sql = meta.proretset
          ? `select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) as v from ${call} r`
          : `select to_jsonb(${call}) as v`;
        const { rows } = await client.query(sql, keys.map((k) => (args[k] !== null && typeof args[k] === 'object' && !Array.isArray(args[k]) ? JSON.stringify(args[k]) : args[k])));
        await client.query('commit');
        return rows[0].v as T;
      } catch (e) {
        await client.query('rollback');
        const err = e as { code?: string; message: string; detail?: string };
        throw fromDbError({ code: err.code, message: err.message, details: err.detail } as DbError);
      } finally {
        client.release();
      }
    },
    async orderOwner(orderId: string) {
      const { rows } = await pool.query(
        `select o.booking_id, b.customer_id from public.payment_orders o join public.bookings b on b.id = o.booking_id where o.gateway_order_id = $1`,
        [orderId],
      );
      return rows[0] ?? null;
    },
  };
}

function fakeRazorpay(): PaymentGateway & { payments: Map<string, RazorpayPayment> } {
  const payments = new Map<string, RazorpayPayment>();
  let n = 0;
  return {
    keyId: 'rzp_test_it',
    payments,
    createOrder: (i) => Promise.resolve({ id: `order_IT${Date.now()}${n++}`, amount: i.amount, currency: i.currency, receipt: i.receipt, status: 'created' }),
    fetchPayment: (id) => Promise.resolve(payments.get(id)!),
    listRefunds: () => Promise.resolve([]),
    createRefund: (pid, i) => Promise.resolve({ id: `rfnd_IT${n++}`, payment_id: pid, amount: i.amount, status: 'processed', notes: i.notes, created_at: 0 }),
  };
}

Deno.test({
  name: 'integration: hold → order → verify → webhook duplicate → cancel → refund',
  ignore: !url,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const pool = new pg.Pool({ connectionString: url });
    try {
      const db = pgDb(pool);
      const gateway = fakeRazorpay();
      const q = (text: string, params: unknown[] = []) => pool.query(text, params).then((r: pg.QueryResult) => r.rows);

      // Fixture: an approved station owned by a fresh owner, booking fee INR 12.
      await q(`update public.platform_settings set value = '1200' where key = 'booking_fee_paise'`);
      const [owner] = await q(`insert into auth.users (email) values ('it-owner-' || gen_random_uuid() || '@t.io') returning id`);
      const [customer] = await q(`insert into auth.users (email) values ('it-cust-' || gen_random_uuid() || '@t.io') returning id`);
      const [biz] = await q(`insert into public.businesses (owner_id, legal_name, owner_full_name, contact_phone, contact_email, business_type, status)
                             values ($1, 'IT Energy', 'Owner', '+919812345678', 'o@t.io', 'llp', 'active') returning id`, [owner.id]);
      await q(`insert into public.business_members (business_id, user_id, role) values ($1, $2, 'owner')`, [biz.id, owner.id]);
      const [station] = await q(`insert into public.stations (business_id, name, address_line1, city, district, state, postal_code, latitude, longitude,
                                   contact_phone, status, approved_at) values ($1, 'IT Station', '1 Road', 'Pune', 'Pune', 'Maharashtra', '411001',
                                   18.52, 73.85, '+919812345679', 'active', now()) returning id`, [biz.id]);
      await q(`insert into public.station_operating_hours (station_id, day_of_week, opens_minute, closes_minute) select $1, d, 0, 1440 from generate_series(1,7) d`, [station.id]);
      const [point] = await q(`insert into public.charging_points (station_id, code, current_type, max_power_kw) values ($1, 'IT1', 'dc', 50) returning id`, [station.id]);

      // Customer holds a slot tomorrow 10:00 IST.
      const start = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), new Date().getUTCDate() + 1, 4, 30));
      const client = await pool.connect();
      await client.query('begin');
      await client.query('set local role authenticated');
      await client.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: customer.id })]);
      const { rows: [{ b }] } = await client.query(`select public.create_booking_hold($1, $2, $3, $4) as b`,
        [point.id, start.toISOString(), new Date(start.getTime() + 30 * 60000).toISOString(), `it-${crypto.randomUUID()}`]);
      await client.query('commit');
      client.release();
      assertEquals(b.status, 'payment_pending');

      // Order creation uses the DB amount.
      const order = await createOrder({ db, gateway }, customer.id, b.id);
      assertEquals(order.amount_paise, 1200);

      // Checkout returns; verify records it.
      const pay: RazorpayPayment = { id: 'pay_IT' + Date.now(), order_id: order.order_id, amount: 1200, currency: 'INR', status: 'captured', method: 'upi', fee: 28, tax: 4, created_at: Math.floor(Date.now() / 1000) };
      gateway.payments.set(pay.id, pay);
      const signature = await hmacSha256Hex(KEY_SECRET, `${order.order_id}|${pay.id}`);
      const verified = await verifyPayment({ db, gateway, keySecret: KEY_SECRET }, customer.id, {
        razorpay_order_id: order.order_id, razorpay_payment_id: pay.id, razorpay_signature: signature,
      });
      assertEquals(verified.result, 'confirmed');

      // The same payment's webhook, delivered twice.
      const raw = JSON.stringify({ event: 'payment.captured', created_at: pay.created_at, payload: { payment: { entity: pay } } });
      const headers = new Headers({ 'x-razorpay-signature': await hmacSha256Hex(WEBHOOK_SECRET, raw), 'x-razorpay-event-id': `evt_${pay.id}` });
      assertEquals((await handleWebhook({ db, webhookSecret: WEBHOOK_SECRET }, raw, headers)).status, 'processed');
      assertEquals((await handleWebhook({ db, webhookSecret: WEBHOOK_SECRET }, raw, headers)).status, 'duplicate');
      const [{ n }] = await q(`select count(*)::int n from public.ledger_entries where booking_id = $1 and entry_type = 'booking_fee_collected'`, [b.id]);
      assertEquals(n, 1);

      // Station cancels: policy refund is requested, then the worker submits it.
      const oc = await pool.connect();
      await oc.query('begin');
      await oc.query('set local role authenticated');
      await oc.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: owner.id })]);
      await oc.query(`select public.cancel_booking($1, 'Charger fault')`, [b.id]);
      await oc.query('commit');
      oc.release();
      const summary = await processRefunds({ db, gateway });
      assertEquals(summary.submitted >= 1, true);
      const [booking] = await q(`select status, payment_status from public.bookings where id = $1`, [b.id]);
      assertEquals(booking, { status: 'cancelled', payment_status: 'refunded' });
      const [{ refunded }] = await q(`select -sum(amount_paise)::int refunded from public.ledger_entries where booking_id = $1 and entry_type = 'booking_fee_refunded'`, [b.id]);
      assertEquals(refunded, 1200);
    } finally {
      await pool.query(`update public.platform_settings set value = '1200' where key = 'booking_fee_paise'`);
      await pool.end();
    }
  },
});
