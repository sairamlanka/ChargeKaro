// POST with the business owner's JWT. Creates and removes team member logins.
//
//   { action: 'create', business_id, email, full_name, phone?, role, station_ids, permissions?, temp_password? }
//   { action: 'approve', request_id, temp_password? }      approve a manager's add or remove request
//   { action: 'remove', member_id }                         delete a member who left
//
// Every permission check runs in the database as the caller (owner-only RPCs
// prepare_member_account, get_member_request, approve_member_request,
// add_business_member, remove_business_member). The service role is used only
// to create a login (when the email has none) and to close a login this
// business created once its member is removed.
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.117.3';
import { corsHeaders, type DbError, errorResponse, fromDbError, HttpError, json, readJson } from '../_shared/http.ts';
import { requireEnv } from '../_shared/env.ts';
import { log, withLogging } from '../_shared/log.ts';

type Body = Record<string, unknown>;

const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '');

export function validTempPassword(p: string): boolean {
  return p.length >= 10 && /[a-z]/.test(p) && /[A-Z]/.test(p) && /[0-9]/.test(p);
}

function clients(req: Request) {
  const auth = req.headers.get('Authorization');
  if (!auth?.startsWith('Bearer ')) throw new HttpError(401, 'not_authenticated');
  const url = requireEnv('SUPABASE_URL');
  const opts = { auth: { persistSession: false, autoRefreshToken: false } };
  const asUser = createClient(url, requireEnv('SUPABASE_ANON_KEY'), { ...opts, global: { headers: { Authorization: auth } } });
  const admin = createClient(url, requireEnv('SUPABASE_SERVICE_ROLE_KEY'), opts);
  return { asUser, admin };
}

async function call<T>(client: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await client.rpc(fn, args);
  if (error) throw fromDbError(error as DbError);
  return data as T;
}

/** Creates a confirmed login unless the email already has one. */
async function ensureLogin(
  asUser: SupabaseClient,
  admin: SupabaseClient,
  businessId: string,
  email: string,
  fullName: string,
  phone: string,
  tempPassword: string,
): Promise<{ created: boolean; userId?: string }> {
  const prep = await call<{ exists: boolean }>(asUser, 'prepare_member_account', { p_business_id: businessId, p_email: email });
  if (prep.exists) return { created: false };
  if (!validTempPassword(tempPassword)) {
    throw new HttpError(422, 'weak_password',
      'Temporary password needs at least 10 characters with upper and lower case letters and a digit.');
  }
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: tempPassword,
    email_confirm: true,
    user_metadata: { full_name: fullName || undefined, must_change_password: true },
    app_metadata: { created_by_business: businessId },
  });
  if (error || !data.user) {
    // An Auth user without a profile row (rare) still blocks the email.
    if ((error as { code?: string } | null)?.code === 'email_exists') {
      throw new HttpError(409, 'email_exists', 'This email already has a ChargeKaro login. Ask them to sign in once, then add them again.');
    }
    log('error', 'team.create_user_failed', { code: (error as { code?: string } | null)?.code });
    throw new HttpError(500, 'create_user_failed', 'Could not create the login. Please try again.');
  }
  if (phone) {
    await admin.from('profiles').update({ phone }).eq('id', data.user.id);
  }
  return { created: true, userId: data.user.id };
}

/** Undo a login we just created when adding the member then fails. */
async function rollbackLogin(admin: SupabaseClient, login: { created: boolean; userId?: string }) {
  if (login.created && login.userId) await admin.auth.admin.deleteUser(login.userId);
}

/** After a member row is deleted: close the login if this business made it and nothing else uses it. */
async function closeLoginIfManaged(
  admin: SupabaseClient,
  result: { user_id: string; managed_account: boolean; other_memberships: number; is_platform_staff: boolean },
): Promise<boolean> {
  if (!result.managed_account || result.other_memberships > 0 || result.is_platform_staff) return false;
  const { error } = await admin.auth.admin.deleteUser(result.user_id, true);
  if (error) {
    log('error', 'team.close_login_failed', { user_id: result.user_id });
    return false;
  }
  await call(admin, 'scrub_member_profile', { p_user_id: result.user_id });
  return true;
}

Deno.serve(withLogging('team-members', async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    if (req.method !== 'POST') throw new HttpError(405, 'method_not_allowed');
    const body = await readJson<Body>(req);
    const { asUser, admin } = clients(req);
    switch (body.action) {
      case 'create': {
        const businessId = str(body.business_id);
        const email = str(body.email).toLowerCase();
        const role = str(body.role);
        if (!businessId || !email || !['station_manager', 'station_staff'].includes(role)) {
          throw new HttpError(422, 'invalid_input', 'Email and role are required');
        }
        const login = await ensureLogin(asUser, admin, businessId, email, str(body.full_name), str(body.phone), str(body.temp_password));
        try {
          const memberId = await call<string>(asUser, 'add_business_member', {
            p_business_id: businessId,
            p_email: email,
            p_role: role,
            p_permissions: Array.isArray(body.permissions) ? body.permissions : null,
            p_station_ids: Array.isArray(body.station_ids) ? body.station_ids : [],
          });
          return json({ member_id: memberId, login_created: login.created });
        } catch (e) {
          await rollbackLogin(admin, login);
          throw e;
        }
      }
      case 'approve': {
        const requestId = str(body.request_id);
        const r = await call<Record<string, unknown>>(asUser, 'get_member_request', { p_request_id: requestId });
        if (r.kind === 'remove') {
          const result = await call<Parameters<typeof closeLoginIfManaged>[1]>(asUser, 'remove_business_member',
            { p_member_id: r.member_id, p_request_id: requestId });
          return json({ removed: true, login_closed: await closeLoginIfManaged(admin, result) });
        }
        const login = await ensureLogin(asUser, admin, str(r.business_id), str(r.email), str(r.full_name), str(r.phone),
          str(body.temp_password));
        try {
          const res = await call<{ member_id: string }>(asUser, 'approve_member_request', { p_request_id: requestId });
          return json({ ...res, login_created: login.created });
        } catch (e) {
          await rollbackLogin(admin, login);
          throw e;
        }
      }
      case 'remove': {
        const result = await call<Parameters<typeof closeLoginIfManaged>[1]>(asUser, 'remove_business_member',
          { p_member_id: str(body.member_id), p_request_id: null });
        return json({ removed: true, login_closed: await closeLoginIfManaged(admin, result) });
      }
      default:
        throw new HttpError(422, 'invalid_action');
    }
  } catch (err) {
    if (!(err instanceof HttpError)) log('error', 'team.failed', { error: String(err) });
    return errorResponse(err);
  }
}));
