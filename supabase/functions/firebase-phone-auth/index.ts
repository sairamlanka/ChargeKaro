import { createClient } from 'npm:@supabase/supabase-js@2.117.3';
import { corsHeaders, errorResponse, HttpError, json, readJson } from '../_shared/http.ts';
import { requireUserId, serviceDb } from '../_shared/db.ts';
import { requireEnv } from '../_shared/env.ts';
import { verifyFirebasePhoneToken } from '../_shared/firebase.ts';
import { log, withLogging } from '../_shared/log.ts';
import { type AuthPort, handle } from './handler.ts';

function port(req: Request): AuthPort {
  const url = requireEnv('SUPABASE_URL');
  const opts = { auth: { persistSession: false, autoRefreshToken: false } };
  const admin = createClient(url, requireEnv('SUPABASE_SERVICE_ROLE_KEY'), opts);
  const db = serviceDb();
  const projectId = requireEnv('FIREBASE_PROJECT_ID');
  const fail = (what: string, error: { message: string }) => {
    log('error', `firebase_phone.${what}_failed`, { error: error.message });
    return new HttpError(502, 'sign_in_unavailable', 'Sign-in is not available right now. Please try again.');
  };
  return {
    verify: (token) => verifyFirebasePhoneToken(token, projectId),
    userIdForPhone: (phone) => db.rpc<string | null>('auth_user_id_for_phone', { p_phone: phone }),
    async createUser(phone, password) {
      const { data, error } = await admin.auth.admin.createUser({ phone, password, phone_confirm: true });
      if (error || !data.user) throw fail('create_user', error ?? { message: 'no user' });
      return data.user.id;
    },
    async setPassword(userId, password) {
      const { error } = await admin.auth.admin.updateUserById(userId, { password, phone_confirm: true });
      if (error) throw fail('set_password', error);
    },
    async signIn(phone, password) {
      const anon = createClient(url, requireEnv('SUPABASE_ANON_KEY'), opts);
      const { data, error } = await anon.auth.signInWithPassword({ phone, password });
      if (error || !data.session) throw fail('sign_in', error ?? { message: 'no session' });
      return {
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
        expires_in: data.session.expires_in,
        user_id: data.session.user.id,
      };
    },
    caller: () => requireUserId(req),
    async setPhone(userId, phone) {
      const { error } = await admin.auth.admin.updateUserById(userId, { phone, phone_confirm: true });
      if (error) throw fail('set_phone', error);
    },
  };
}

Deno.serve(withLogging('firebase-phone-auth', async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    return json(await handle(await readJson<Record<string, unknown>>(req), port(req)));
  } catch (err) {
    return errorResponse(err);
  }
}));
