#!/usr/bin/env bash
# Recreates a plain-Postgres test database: Supabase shim + all migrations + seed.
# Usage: DATABASE_URL=postgres://postgres@localhost:54322/postgres scripts/db-reset-test.sh [--no-seed]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADMIN_URL="${DATABASE_URL:-postgres://postgres@localhost:54322/postgres}"
DB_NAME="${TEST_DB_NAME:-chargekaro_test}"
TEST_URL="${ADMIN_URL%/*}/${DB_NAME}"

psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q -c "drop database if exists ${DB_NAME} with (force)" -c "create database ${DB_NAME}"
sed "s/current_database_placeholder/${DB_NAME}/" "$ROOT/supabase/tests/support/supabase_shim.sql" \
  | psql "$TEST_URL" -v ON_ERROR_STOP=1 -q
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "applying $(basename "$f")"
  psql "$TEST_URL" -v ON_ERROR_STOP=1 -q -f "$f"
done
if [[ "${1:-}" != "--no-seed" ]]; then
  echo "applying seed.sql"
  psql "$TEST_URL" -v ON_ERROR_STOP=1 -q -f "$ROOT/supabase/seed.sql"
fi
echo "ready: $TEST_URL"
