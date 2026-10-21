// Firebase Cloud Messaging (HTTP v1) sender using a service account held only
// in Edge Function secrets. Access tokens are minted with an RS256 JWT.

import type { Db } from './db.ts';
import { log } from './log.ts';

export interface PushSender {
  send(token: string, message: { title: string; body: string; data: Record<string, string> }): Promise<'sent' | 'invalid_token' | 'retry'>;
}

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

const b64url = (data: Uint8Array | string) =>
  btoa(typeof data === 'string' ? data : String.fromCharCode(...data)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');

async function signJwt(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`)));
  return `${header}.${claims}.${b64url(sig)}`;
}

export class FcmSender implements PushSender {
  private token: { value: string; expires: number } | null = null;
  private sa: ServiceAccount;

  constructor(serviceAccountJson: string, private fetchImpl: typeof fetch = fetch) {
    this.sa = JSON.parse(serviceAccountJson);
  }

  private async accessToken(): Promise<string> {
    if (this.token && this.token.expires > Date.now() + 60_000) return this.token.value;
    const res = await this.fetchImpl('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: await signJwt(this.sa) }),
    });
    if (!res.ok) throw new Error(`FCM auth failed: ${res.status}`);
    const data = await res.json();
    this.token = { value: data.access_token, expires: Date.now() + data.expires_in * 1000 };
    return this.token.value;
  }

  async send(token: string, message: { title: string; body: string; data: Record<string, string> }) {
    const res = await this.fetchImpl(`https://fcm.googleapis.com/v1/projects/${this.sa.project_id}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${await this.accessToken()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: message.title, body: message.body },
          data: message.data,
          android: { priority: 'high', notification: { channel_id: 'chargekaro_default' } },
          apns: { payload: { aps: { sound: 'default' } } },
        },
      }),
    });
    if (res.ok) return 'sent' as const;
    const err = await res.json().catch(() => ({}));
    const code: string = err?.error?.details?.find?.((d: { errorCode?: string }) => d.errorCode)?.errorCode ?? err?.error?.status ?? '';
    if (res.status === 404 || code === 'UNREGISTERED' || code === 'INVALID_ARGUMENT') return 'invalid_token' as const;
    return 'retry' as const;
  }
}

interface ClaimedNotification {
  notification_id: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  tokens: string[];
}

/** Sends claimed notifications. Each is attempted once per claim; retries are bounded in SQL. */
export async function dispatchNotifications(deps: { db: Db; sender: PushSender }, limit = 100) {
  const claimed = await deps.db.rpc<ClaimedNotification[]>('claim_push_notifications', { p_limit: limit });
  const summary = { claimed: claimed.length, sent: 0, skipped: 0, failed: 0, retry: 0 };
  for (const n of claimed) {
    if (n.tokens.length === 0) {
      await deps.db.rpc('complete_push_notification', { p_notification_id: n.notification_id, p_status: 'skipped', p_error: 'no_device_tokens', p_invalid_tokens: [] });
      summary.skipped++;
      continue;
    }
    // FCM data values must be strings.
    const data = Object.fromEntries(Object.entries({ ...n.data, notification_id: n.notification_id }).map(([k, v]) => [k, String(v)]));
    const results = await Promise.all(n.tokens.map(async (t) => {
      try {
        return [t, await deps.sender.send(t, { title: n.title, body: n.body, data })] as const;
      } catch {
        return [t, 'retry'] as const;
      }
    }));
    const invalid = results.filter(([, r]) => r === 'invalid_token').map(([t]) => t);
    const anySent = results.some(([, r]) => r === 'sent');
    const anyRetry = results.some(([, r]) => r === 'retry');
    const status = anySent ? 'sent' : anyRetry ? 'pending' : 'failed';
    await deps.db.rpc('complete_push_notification', {
      p_notification_id: n.notification_id,
      p_status: status,
      p_error: anySent ? null : anyRetry ? 'transient_error' : 'all_tokens_invalid',
      p_invalid_tokens: invalid,
    });
    if (status === 'sent') summary.sent++;
    else if (status === 'pending') summary.retry++;
    else summary.failed++;
  }
  if (summary.claimed) log('info', 'push.dispatched', summary);
  return summary;
}
