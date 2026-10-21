// HTTP helpers shared by all functions: JSON responses, CORS, and mapping of
// database errors (PostgREST PTxyz codes) to safe client messages.

export const corsHeaders: Record<string, string> = {
  'Access-Control-Allow-Origin': Deno.env.get('CORS_ALLOWED_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

/** Shape of an error returned by supabase-js for an RPC call. */
export interface DbError {
  code?: string;
  message: string;
  details?: string | null;
}

/** Converts a database error into an HttpError with a client-safe message. */
export function fromDbError(err: DbError): HttpError {
  const match = /^PT(\d{3})$/.exec(err.code ?? '');
  if (match) {
    return new HttpError(Number(match[1]), err.message, err.details ?? err.message);
  }
  return new HttpError(500, 'internal_error', 'Something went wrong. Please try again.');
}

export function errorResponse(err: unknown): Response {
  if (err instanceof HttpError) {
    return json({ error: err.code, message: err.message }, err.status);
  }
  return json({ error: 'internal_error', message: 'Something went wrong. Please try again.' }, 500);
}

/** Constant-time string comparison for secrets and signatures. */
export function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

export async function readJson<T>(req: Request): Promise<T> {
  try {
    return await req.json() as T;
  } catch {
    throw new HttpError(400, 'invalid_json', 'Request body must be JSON');
  }
}
