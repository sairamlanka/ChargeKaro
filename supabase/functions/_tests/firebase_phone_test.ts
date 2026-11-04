import { assertEquals, assertRejects } from 'jsr:@std/assert@1.0.13';
import { exportJWK, generateKeyPair, SignJWT } from 'npm:jose@5.9.6';
import { createLocalJWKSet } from 'npm:jose@5.9.6';
import { verifyFirebasePhoneToken } from '../_shared/firebase.ts';
import { type AuthPort, handle } from '../firebase-phone-auth/handler.ts';
import { HttpError } from '../_shared/http.ts';

const project = 'ev-charging-platform-9af0c';
const { publicKey, privateKey } = await generateKeyPair('RS256');
const jwk = { ...(await exportJWK(publicKey)), kid: 'k1', alg: 'RS256' };
const keys = createLocalJWKSet({ keys: [jwk] });

function token(claims: Record<string, unknown> = {}, opts: { aud?: string; iss?: string } = {}) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ phone_number: '+919876543210', auth_time: now, firebase: { sign_in_provider: 'phone' }, ...claims })
    .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
    .setSubject('fb-uid-1')
    .setIssuer(opts.iss ?? `https://securetoken.google.com/${project}`)
    .setAudience(opts.aud ?? project)
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(privateKey);
}

async function code(p: Promise<unknown>): Promise<string> {
  const e = await assertRejects(() => p, HttpError);
  return (e as HttpError).code;
}

Deno.test('a fresh Firebase phone token gives the verified number', async () => {
  const r = await verifyFirebasePhoneToken(await token(), project, keys);
  assertEquals(r, { uid: 'fb-uid-1', phone: '+919876543210' });
});

Deno.test('wrong project, non-phone, stale or forged tokens are refused', async () => {
  assertEquals(await code(verifyFirebasePhoneToken(await token({}, { aud: 'other' }), project, keys)), 'firebase_token_invalid');
  assertEquals(await code(verifyFirebasePhoneToken(await token({ firebase: { sign_in_provider: 'password' } }), project, keys)), 'firebase_token_not_phone');
  const old = Math.floor(Date.now() / 1000) - 3600;
  assertEquals(await code(verifyFirebasePhoneToken(await token({ auth_time: old }), project, keys)), 'firebase_token_stale');
  const other = await generateKeyPair('RS256');
  const forged = await new SignJWT({ phone_number: '+919876543210', auth_time: Math.floor(Date.now() / 1000), firebase: { sign_in_provider: 'phone' } })
    .setProtectedHeader({ alg: 'RS256', kid: 'k1' }).setSubject('x').setIssuer(`https://securetoken.google.com/${project}`)
    .setAudience(project).setIssuedAt().setExpirationTime('1h').sign(other.privateKey);
  assertEquals(await code(verifyFirebasePhoneToken(forged, project, keys)), 'firebase_token_invalid');
  assertEquals(await code(verifyFirebasePhoneToken('', project, keys)), 'firebase_token_missing');
});

function fakePort(existing: Record<string, string> = {}, caller = 'u-me') {
  const calls: string[] = [];
  const passwords: Record<string, string> = {};
  const port: AuthPort = {
    verify: () => Promise.resolve({ uid: 'fb', phone: '+919876543210' }),
    userIdForPhone: (p) => Promise.resolve(existing[p] ?? null),
    createUser: (p, pw) => {
      calls.push(`create ${p}`);
      existing[p] = 'u-new';
      passwords['u-new'] = pw;
      return Promise.resolve('u-new');
    },
    setPassword: (id, pw) => {
      calls.push(`password ${id}`);
      passwords[id] = pw;
      return Promise.resolve();
    },
    signIn: (p, pw) => {
      const id = existing[p];
      if (passwords[id] !== pw) throw new Error('bad password');
      return Promise.resolve({ access_token: `at-${id}`, refresh_token: `rt-${id}`, user_id: id });
    },
    caller: () => Promise.resolve(caller),
    setPhone: (id, p) => {
      calls.push(`phone ${id} ${p}`);
      return Promise.resolve();
    },
  };
  return { port, calls };
}

Deno.test('sign-in creates a login once, then reuses it with a fresh password', async () => {
  const { port, calls } = fakePort();
  const first = await handle({ firebase_token: 't' }, port) as { refresh_token: string };
  assertEquals(first.refresh_token, 'rt-u-new');
  const again = await handle({ action: 'sign_in', firebase_token: 't' }, port) as { user_id: string };
  assertEquals(again.user_id, 'u-new');
  assertEquals(calls, ['create +919876543210', 'password u-new']);
});

Deno.test('changing to a number owned by someone else is refused', async () => {
  const taken = fakePort({ '+919876543210': 'u-other' });
  assertEquals(await code(handle({ action: 'change_phone', firebase_token: 't' }, taken.port)), 'phone_in_use');
  const free = fakePort();
  assertEquals(await handle({ action: 'change_phone', firebase_token: 't' }, free.port), { phone: '+919876543210' });
  assertEquals(free.calls, ['phone u-me +919876543210']);
});
