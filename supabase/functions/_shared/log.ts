// Structured JSON logging. Never log secrets, signatures, tokens or personal
// data: callers pass ids and codes only, and known sensitive keys are redacted.
// LOG_LEVEL (a function secret: debug, info, warn or error; default info)
// hides lines below it. View the lines in the Supabase dashboard under Edge
// Functions > <function> > Logs, or with `supabase functions serve` locally.

import { json } from './http.ts';

const SENSITIVE = /secret|signature|token|password|authorization|email|phone|contact|vpa|card/i;

type Level = 'debug' | 'info' | 'warn' | 'error';
const RANK: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

function threshold(): number {
  const name = (Deno.env.get('LOG_LEVEL') ?? 'info').toLowerCase() as Level;
  return RANK[name] ?? RANK.info;
}

function redact(value: unknown, depth = 0): unknown {
  if (depth > 4 || value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map((v) => redact(v, depth + 1));
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, SENSITIVE.test(k) ? '[redacted]' : redact(v, depth + 1)]),
  );
}

export function log(level: Level, event: string, fields: Record<string, unknown> = {}) {
  if (RANK[level] < threshold()) return;
  const line = JSON.stringify({ level, event, at: new Date().toISOString(), ...(redact(fields) as object) });
  if (level === 'error') console.error(line);
  else if (level === 'warn') console.warn(line);
  else if (level === 'debug') console.debug(line);
  else console.log(line);
}

/**
 * Wraps a function's handler so every request leaves one `request.done` line
 * with the function name, method, status, duration and, for a failure, the
 * error code from the response body: info for 2xx/3xx, warn for 4xx, error
 * for 5xx (scheduled functions pass okLevel 'debug' so a run every minute
 * does not flood the logs). An exception that escapes the handler is logged and answered 500.
 */
export function withLogging(fn: string, handler: (req: Request) => Promise<Response>, opts: { okLevel?: Level } = {}) {
  return async (req: Request): Promise<Response> => {
    if (req.method === 'OPTIONS') return handler(req);
    const started = performance.now();
    const fields: Record<string, unknown> = { fn, method: req.method };
    log('debug', 'request.start', fields);
    let res: Response;
    try {
      res = await handler(req);
    } catch (err) {
      log('error', 'request.crashed', { ...fields, ms: Math.round(performance.now() - started), error: String(err) });
      return json({ error: 'internal_error', message: 'Something went wrong. Please try again.' }, 500);
    }
    const done = { ...fields, status: res.status, ms: Math.round(performance.now() - started) };
    if (res.status < 400) {
      log(opts.okLevel ?? 'info', 'request.done', done);
    } else {
      const body = await res.clone().json().catch(() => null) as { error?: unknown } | null;
      log(res.status >= 500 ? 'error' : 'warn', 'request.done', { ...done, code: body?.error });
    }
    return res;
  };
}
