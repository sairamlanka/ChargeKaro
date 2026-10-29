// Customer SMS and email for booking events (confirmation, cancellation,
// reminders, refunds). Messages are queued in public.customer_messages by the
// database; this module renders and sends them. Delivery never changes a
// booking. A channel without provider credentials is marked "skipped", never
// "sent", so the app can say plainly that no message went out.

import type { Db } from './db.ts';
import { log } from './log.ts';

export type Channel = 'sms' | 'email' | 'whatsapp';

export interface OutgoingMessage {
  to: string;
  subject: string;
  text: string;
  html: string;
}

/** Thrown for errors that will not succeed on retry (bad number, rejected address). */
export class PermanentSendError extends Error {}

export interface MessageSender {
  readonly channel: Channel;
  /** Returns the provider's message id. Throws PermanentSendError or any other error (retried). */
  send(message: OutgoingMessage): Promise<string>;
}

export interface ClaimedMessage {
  id: string;
  channel: Channel;
  template: string;
  destination: string;
  payload: Record<string, unknown>;
}

const SUPPORT = 'Need help? Reply to this message or call the station.';

function rupees(paise: unknown): string {
  const p = typeof paise === 'number' ? paise : Number(paise ?? 0);
  return `₹${(p / 100).toFixed(2)}`;
}

function mapsLink(p: Record<string, unknown>): string {
  return `https://www.google.com/maps/dir/?api=1&destination=${p.latitude},${p.longitude}`;
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

/** Renders a queued message. SMS text stays short; email carries full details. */
export function renderMessage(m: ClaimedMessage): OutgoingMessage {
  const p = m.payload;
  const ref = String(p.reference ?? '');
  const station = String(p.station_name ?? '');
  const when = `${p.start_local}–${p.end_local}`;
  let subject: string;
  let lines: string[];
  switch (m.template) {
    case 'booking_confirmed':
      subject = `Booking confirmed: ${ref}`;
      lines = [
        `ChargeKaro booking ${ref} is confirmed.`,
        `${station}, point ${p.point_code}`,
        `${when} (${p.duration_minutes} min)`,
        Number(p.amount_paise) > 0 ? `Booking fee paid: ${rupees(p.amount_paise)}${p.payment_reference ? ` (ref ${p.payment_reference})` : ''}` : 'No booking fee charged.',
        `Directions: ${mapsLink(p)}`,
        'Show this reference at the station. Charging is paid at the station.',
      ];
      break;
    case 'booking_cancelled':
      subject = `Booking cancelled: ${ref}`;
      lines = [
        `ChargeKaro booking ${ref} at ${station} (${when}) is cancelled.`,
        p.cancellation_reason ? `Reason: ${p.cancellation_reason}` : '',
        p.refund_eligible === true ? `A refund of ${rupees(p.amount_paise)} has been initiated.` : '',
      ];
      break;
    case 'booking_reminder':
      subject = `Reminder: ${station} at ${p.start_local}`;
      lines = [`Reminder: your ChargeKaro slot ${ref} at ${station} starts ${p.start_local}.`, `Directions: ${mapsLink(p)}`];
      break;
    case 'slot_lost':
      subject = `Payment received, slot no longer available: ${ref}`;
      lines = [
        `Your payment for ChargeKaro booking ${ref} arrived after the slot was released, so the booking is not confirmed.`,
        'Any refund due under the booking policy is processed automatically. You do not need to pay again.',
      ];
      break;
    case 'refund_initiated':
      subject = `Refund initiated: ${ref}`;
      lines = [`A refund for ChargeKaro booking ${ref} has been initiated. Banks usually take a few working days to credit it.`];
      break;
    case 'refund_processed':
      subject = `Refund processed: ${ref}`;
      lines = [`The refund for ChargeKaro booking ${ref} has been processed by our payment provider.`];
      break;
    default:
      throw new PermanentSendError(`unknown_template:${m.template}`);
  }
  lines = lines.filter((l) => l !== '');
  const text = m.channel === 'sms' ? lines.slice(0, 4).join('\n') : [...lines, '', SUPPORT].join('\n');
  const html = `<div style="font-family:sans-serif;line-height:1.5">${
    [...lines, SUPPORT].map((l) => `<p>${escapeHtml(l)}</p>`).join('')
  }<p style="color:#64748b;font-size:12px">${escapeHtml(String(p.station_address ?? ''))}</p></div>`;
  return { to: m.destination, subject, text, html };
}

/** Twilio Programmable SMS. For India, sender ids and DLT templates must be registered with Twilio first. */
export class TwilioSmsSender implements MessageSender {
  readonly channel = 'sms' as const;
  constructor(private accountSid: string, private authToken: string, private from: string) {}

  async send(m: OutgoingMessage): Promise<string> {
    const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${this.accountSid}/Messages.json`, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${btoa(`${this.accountSid}:${this.authToken}`)}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({ To: m.to, From: this.from, Body: m.text }),
    });
    const body = await res.json().catch(() => ({}));
    if (res.ok) return String(body.sid ?? '');
    if (res.status === 400) throw new PermanentSendError(`twilio_${body.code ?? 400}`);
    throw new Error(`twilio_${res.status}`);
  }
}

/** Resend transactional email. */
export class ResendEmailSender implements MessageSender {
  readonly channel = 'email' as const;
  constructor(private apiKey: string, private from: string) {}

  async send(m: OutgoingMessage): Promise<string> {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: this.from, to: [m.to], subject: m.subject, text: m.text, html: m.html }),
    });
    const body = await res.json().catch(() => ({}));
    if (res.ok) return String(body.id ?? '');
    if (res.status === 400 || res.status === 422) throw new PermanentSendError(`resend_${res.status}`);
    throw new Error(`resend_${res.status}`);
  }
}

/** Builds senders from whatever provider secrets are present. */
export function sendersFromEnv(env: (name: string) => string | undefined = (n) => Deno.env.get(n)): MessageSender[] {
  const out: MessageSender[] = [];
  const sid = env('TWILIO_ACCOUNT_SID');
  const token = env('TWILIO_AUTH_TOKEN');
  const from = env('TWILIO_FROM_NUMBER');
  if (sid && token && from) out.push(new TwilioSmsSender(sid, token, from));
  const key = env('RESEND_API_KEY');
  const emailFrom = env('EMAIL_FROM');
  if (key && emailFrom) out.push(new ResendEmailSender(key, emailFrom));
  return out;
}

export async function dispatchCustomerMessages(deps: { db: Db; senders: MessageSender[] }, limit = 50) {
  const reminders = await deps.db.rpc<number>('enqueue_booking_reminders');
  const claimed = await deps.db.rpc<ClaimedMessage[]>('claim_customer_messages', { p_limit: limit });
  const summary = { reminders_queued: reminders ?? 0, claimed: claimed.length, sent: 0, skipped: 0, failed: 0, retry: 0 };
  for (const m of claimed) {
    const sender = deps.senders.find((s) => s.channel === m.channel);
    if (!sender) {
      await deps.db.rpc('complete_customer_message', { p_id: m.id, p_status: 'skipped', p_error: 'channel_not_configured' });
      summary.skipped++;
      continue;
    }
    try {
      const providerId = await sender.send(renderMessage(m));
      await deps.db.rpc('complete_customer_message', { p_id: m.id, p_status: 'sent', p_provider_message_id: providerId });
      summary.sent++;
    } catch (err) {
      const permanent = err instanceof PermanentSendError;
      await deps.db.rpc('complete_customer_message', {
        p_id: m.id,
        // "failed" is retried by the database up to its attempt limit; permanent errors skip retries.
        p_status: permanent ? 'skipped' : 'failed',
        p_error: permanent ? `rejected:${err.message}` : 'transient_error',
      });
      if (permanent) summary.failed++;
      else summary.retry++;
    }
  }
  if (summary.claimed || summary.reminders_queued) log('info', 'customer_messages.dispatched', summary);
  return summary;
}
