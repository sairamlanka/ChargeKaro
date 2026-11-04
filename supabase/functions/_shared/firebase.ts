// Verifies Firebase Authentication ID tokens (RS256, Google's public keys).
// https://firebase.google.com/docs/auth/admin/verify-id-tokens#verify_id_tokens_using_a_third-party_jwt_library
import { createRemoteJWKSet, type JWTVerifyGetKey, jwtVerify } from 'npm:jose@5.9.6';
import { HttpError } from './http.ts';

const GOOGLE_JWKS = 'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
let remote: JWTVerifyGetKey | null = null;

export interface FirebasePhone {
  uid: string;
  phone: string;
}

/** Returns the verified phone number (E.164) in [token], or throws 401. */
export async function verifyFirebasePhoneToken(
  token: string,
  projectId: string,
  keys: JWTVerifyGetKey = (remote ??= createRemoteJWKSet(new URL(GOOGLE_JWKS))),
): Promise<FirebasePhone> {
  if (!token) throw new HttpError(401, 'firebase_token_missing');
  try {
    const { payload } = await jwtVerify(token, keys, {
      issuer: `https://securetoken.google.com/${projectId}`,
      audience: projectId,
      algorithms: ['RS256'],
    });
    const phone = typeof payload.phone_number === 'string' ? payload.phone_number : '';
    const provider = (payload.firebase as { sign_in_provider?: string } | undefined)?.sign_in_provider;
    if (!payload.sub || !/^\+\d{8,15}$/.test(phone) || provider !== 'phone') {
      throw new HttpError(401, 'firebase_token_not_phone');
    }
    // A token is good for an hour; for signing in, insist on a fresh code.
    const authTime = typeof payload.auth_time === 'number' ? payload.auth_time : 0;
    if (Date.now() / 1000 - authTime > 10 * 60) throw new HttpError(401, 'firebase_token_stale');
    return { uid: payload.sub, phone };
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw new HttpError(401, 'firebase_token_invalid');
  }
}
