import { assert, assertEquals, assertRejects, assertStringIncludes } from 'jsr:@std/assert@1.0.13';
import { type ClaimedMessage, dispatchCustomerMessages, type MessageSender, PermanentSendError, renderMessage, sendersFromEnv } from '../_shared/messaging.ts';
import { geocodeArea } from '../_shared/geocode.ts';
import { HttpError } from '../_shared/http.ts';
import type { Db } from '../_shared/db.ts';

const payload = {
  reference: 'CKABCDEFGH12',
  station_name: 'Green Volt Koramangala',
  station_address: '80 Feet Road, Bengaluru',
  latitude: 12.93,
  longitude: 77.62,
  point_code: 'DC1',
  start_local: 'Thu 23 Oct 2026, 10:00 AM',
  end_local: '10:30 AM',
  duration_minutes: 30,
  amount_paise: 1200,
  payment_reference: 'pay_123',
};

const msg = (over: Partial<ClaimedMessage> = {}): ClaimedMessage => ({
  id: crypto.randomUUID(),
  channel: 'sms',
  template: 'booking_confirmed',
  destination: '+919800000001',
  payload,
  ...over,
});

function fakeDb(claimed: ClaimedMessage[]) {
  const completed: Record<string, unknown>[] = [];
  const db: Db = {
    rpc<T>(fn: string, args: Record<string, unknown> = {}) {
      if (fn === 'enqueue_booking_reminders') return Promise.resolve(2 as T);
      if (fn === 'claim_customer_messages') return Promise.resolve(claimed as T);
      if (fn === 'complete_customer_message') completed.push(args);
      return Promise.resolve(null as T);
    },
    orderOwner: () => Promise.resolve(null),
  };
  return { db, completed };
}

Deno.test('confirmation text carries reference, slot, amount and directions; html is escaped', () => {
  const sms = renderMessage(msg());
  assertStringIncludes(sms.text, 'CKABCDEFGH12');
  assertStringIncludes(sms.text, '₹12.00');
  assert(sms.text.split('\n').length <= 4, 'SMS stays short');
  const email = renderMessage(msg({ channel: 'email', destination: 'a@b.co', payload: { ...payload, station_name: '<b>X</b>' } }));
  assertStringIncludes(email.text, 'google.com/maps');
  assert(!email.html.includes('<b>X</b>'));
  assertEquals(email.subject, 'Booking confirmed: CKABCDEFGH12');
});

Deno.test('unconfigured channels are skipped, never reported as sent', async () => {
  const { db, completed } = fakeDb([msg(), msg({ channel: 'email', destination: 'a@b.co' })]);
  const summary = await dispatchCustomerMessages({ db, senders: [] });
  assertEquals(summary, { reminders_queued: 2, claimed: 2, sent: 0, skipped: 2, failed: 0, retry: 0 });
  assert(completed.every((c) => c.p_status === 'skipped' && c.p_error === 'channel_not_configured'));
});

Deno.test('sent, permanent and transient outcomes are recorded distinctly', async () => {
  const a = msg();
  const b = msg();
  const c = msg();
  let call = 0;
  const sender: MessageSender = {
    channel: 'sms',
    send: () => {
      call++;
      if (call === 1) return Promise.resolve('SM1');
      if (call === 2) return Promise.reject(new PermanentSendError('twilio_21211'));
      return Promise.reject(new Error('timeout'));
    },
  };
  const { db, completed } = fakeDb([a, b, c]);
  const summary = await dispatchCustomerMessages({ db, senders: [sender] });
  assertEquals([summary.sent, summary.failed, summary.retry], [1, 1, 1]);
  assertEquals(completed.map((x) => x.p_status), ['sent', 'skipped', 'failed']);
  assertEquals(completed[0].p_provider_message_id, 'SM1');
});

Deno.test('senders are built only from complete provider secrets', () => {
  assertEquals(sendersFromEnv(() => undefined).length, 0);
  const env: Record<string, string> = { TWILIO_ACCOUNT_SID: 'AC1', TWILIO_AUTH_TOKEN: 't', RESEND_API_KEY: 'k', EMAIL_FROM: 'x@y.z' };
  assertEquals(sendersFromEnv((n) => env[n]).map((s) => s.channel), ['email']);
});

Deno.test('geocoding validates input, reports missing key, and maps provider results', async () => {
  await assertRejects(() => geocodeArea('a', 'k'), HttpError, 'Type 2 to 120 characters');
  const e = await assertRejects(() => geocodeArea('Gachibowli', undefined), HttpError);
  assertEquals((e as HttpError).code, 'geocoding_not_configured');
  let requested = '';
  const fake = (u: string) => {
    requested = u;
    return Promise.resolve(new Response(JSON.stringify({
      status: 'OK',
      results: [{ formatted_address: 'Gachibowli, Hyderabad, Telangana, India', geometry: { location: { lat: 17.44, lng: 78.35 }, location_type: 'APPROXIMATE' } }],
    })));
  };
  const r = await geocodeArea('Gachibowli', 'key123', fake);
  assertStringIncludes(requested, 'components=country%3AIN');
  assertEquals(r.results, [{ label: 'Gachibowli', secondary: 'Hyderabad, Telangana, India', latitude: 17.44, longitude: 78.35, source: 'google', precise: false }]);
  const none = await geocodeArea('zzzz', 'k', () => Promise.resolve(new Response(JSON.stringify({ status: 'ZERO_RESULTS', results: [] }))));
  assertEquals(none.results, []);
  await assertRejects(() => geocodeArea('x y', 'k', () => Promise.resolve(new Response('{}', { status: 500 }))), HttpError);
});
