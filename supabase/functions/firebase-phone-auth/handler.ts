// Firebase phone sign-in for the customer app. Firebase sends and checks the
// SMS code; this turns its ID token into a Supabase session for that phone.
//
//   POST { action: 'sign_in', firebase_token }               no Supabase JWT needed
//   POST { action: 'change_phone', firebase_token }          with the customer's JWT
//
// Sign-in finds the login with that phone (or creates one, phone confirmed),
// gives it a new random password that only this call knows, and signs in with
// it server-side. Each sign-in replaces the password, so it is never reused.
import { HttpError } from '../_shared/http.ts';
import type { FirebasePhone } from '../_shared/firebase.ts';

export interface Session {
  access_token: string;
  refresh_token: string;
  expires_in?: number;
  user_id: string;
}

export interface AuthPort {
  verify(token: string): Promise<FirebasePhone>;
  userIdForPhone(phone: string): Promise<string | null>;
  createUser(phone: string, password: string): Promise<string>;
  setPassword(userId: string, password: string): Promise<void>;
  signIn(phone: string, password: string): Promise<Session>;
  /** The Supabase user behind the request's bearer token. */
  caller(): Promise<string>;
  setPhone(userId: string, phone: string): Promise<void>;
}

export function randomPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/[^A-Za-z0-9]/g, '').slice(0, 40) + 'Aa1!';
}

export async function handle(body: Record<string, unknown>, port: AuthPort): Promise<unknown> {
  const action = typeof body.action === 'string' ? body.action : 'sign_in';
  const token = typeof body.firebase_token === 'string' ? body.firebase_token : '';
  const { phone } = await port.verify(token);

  if (action === 'sign_in') {
    const password = randomPassword();
    let userId = await port.userIdForPhone(phone);
    if (userId) {
      await port.setPassword(userId, password);
    } else {
      userId = await port.createUser(phone, password);
    }
    const session = await port.signIn(phone, password);
    return { ...session, phone };
  }

  if (action === 'change_phone') {
    const userId = await port.caller();
    const owner = await port.userIdForPhone(phone);
    if (owner && owner !== userId) throw new HttpError(409, 'phone_in_use', 'This number is already used by another account.');
    if (!owner) await port.setPhone(userId, phone);
    return { phone };
  }

  throw new HttpError(400, 'unknown_action');
}
