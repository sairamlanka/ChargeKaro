#!/usr/bin/env bash
# Runs the Dart repositories against a real PostgREST in front of the test
# database, so every select/embed/filter string the apps use is checked
# against the actual schema, grants and RLS.
#
# Needs: Postgres reachable at DATABASE_URL (admin connection), a postgrest
# binary (POSTGREST_BIN or on PATH), node, flutter.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATABASE_URL="${DATABASE_URL:-postgres://postgres@localhost:54322/postgres}"
TEST_DB_URL="${DATABASE_URL%/*}/chargekaro_test"
POSTGREST_BIN="${POSTGREST_BIN:-postgrest}"
PGRST_PORT="${PGRST_PORT:-3999}"
PROXY_PORT="${PROXY_PORT:-3998}"
JWT_SECRET="local-test-secret-not-for-production-0123456789"

"$ROOT/scripts/db-reset-test.sh"

psql "$TEST_DB_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit password 'authenticator';
  end if;
end $$;
grant anon, authenticated, service_role to authenticator;
SQL

AUTH_URL="$(echo "$TEST_DB_URL" | sed -E 's#^postgres://[^@]*@#postgres://authenticator:authenticator@#')"
PGRST_DB_URI="$AUTH_URL" PGRST_DB_SCHEMAS=public PGRST_DB_ANON_ROLE=anon PGRST_JWT_SECRET="$JWT_SECRET" \
  PGRST_SERVER_PORT="$PGRST_PORT" PGRST_DB_POOL=4 "$POSTGREST_BIN" >/tmp/postgrest.log 2>&1 &
PGRST_PID=$!

# Supabase clients call <url>/rest/v1/...; PostgREST serves at /.
node -e "
const http = require('http');
http.createServer((req, res) => {
  const path = req.url.replace(/^\/rest\/v1/, '');
  const p = http.request({ host: '127.0.0.1', port: $PGRST_PORT, path, method: req.method, headers: req.headers }, (r) => {
    res.writeHead(r.statusCode, r.headers); r.pipe(res);
  });
  p.on('error', (e) => { res.writeHead(502); res.end(String(e)); });
  req.pipe(p);
}).listen($PROXY_PORT);
" &
PROXY_PID=$!
trap 'kill $PGRST_PID $PROXY_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PROXY_PORT/rest/v1/" -o /dev/null && break
  sleep 0.2
done

id_of() { psql "$TEST_DB_URL" -Atc "select id from auth.users where email = '$1'"; }

export REST_URL="http://127.0.0.1:$PROXY_PORT"
export REST_JWT_SECRET="$JWT_SECRET"
export OWNER_ID="$(id_of owner@demo-ev.local)"
export STAFF_ID="$(id_of staff@demo-ev.local)"
export ADMIN_ID="$(id_of admin@chargekaro.local)"
export OPS_ID="$(id_of ops@chargekaro.local)"
export REVIEWER_ID="$(id_of reviewer@chargekaro.local)"

cd "$ROOT/packages/shared_data"
flutter test test/integration/
