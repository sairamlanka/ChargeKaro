# Testing

| Suite | Location | Count | Runs against |
|---|---|---|---|
| Database | `supabase/tests/*.test.mjs` | 105 | Real Postgres 16 with all migrations + a small Supabase shim |
| Edge Functions | `supabase/functions/_tests` | 17 (+1 DB-backed) | Deno, with fake gateway/DB ports; the DB-backed test runs when `TEST_DATABASE_URL` is set |
| Shared models | `packages/shared_models/test` | 15 | Dart |
| Validation | `packages/shared_validation/test` | 7 | Dart |
| Data layer | `packages/shared_data/test` | 7 | Dart |
| Data layer ↔ PostgREST | `packages/shared_data/test/integration` | 10 | Real PostgREST in front of the test DB |
| UI kit | `packages/shared_ui/test` | 4 | Flutter widget tests |
| Admin Panel | `apps/admin_panel/test` | 3 | Flutter widget tests (permission-filtered navigation) |
| Business App | `apps/business_app/test` | 7 | Flutter widget tests (login, booking codes) |

All of the above pass locally and are wired into `.github/workflows/ci.yml`.

## What the database tests cover

* RLS: anon has nothing; owners/staff see only their business/stations; staff
  cannot escalate roles; clients cannot write workflow or payment columns.
* Onboarding: submit → review → request info → resubmit → approve/reject,
  document review rules, change requests on approved stations.
* Bookings: hold creation, the exclusion constraint under concurrent inserts
  (no double booking), operating hours and blocked periods, check-in by
  reference and QR, no-show and expiry jobs.
* Payments: idempotent webhook processing, duplicate and amount-mismatch
  payments, late payment after slot loss, refunds, ledger uniqueness.
* Finance: summary/timeseries arithmetic, expense approval and void.
* Batch writes: hours/connector replacement is atomic and RLS-checked.

## Running locally

```bash
# Database (needs Postgres 16 and psql)
DATABASE_URL=postgres://postgres@localhost:54322/postgres scripts/db-reset-test.sh
(cd supabase/tests && npm ci && npm test)

# Edge Functions
cd supabase/functions && deno lint && deno check */index.ts && \
  TEST_DATABASE_URL=postgres://postgres@localhost:54322/chargekaro_test \
  deno test --allow-env --allow-net=127.0.0.1,localhost _tests/

# Flutter
flutter pub get && flutter analyze
(cd packages/shared_models && flutter test)   # etc. for each package/app

# Repositories against a real PostgREST (needs the postgrest binary)
POSTGREST_BIN=/path/to/postgrest scripts/rest-integration.sh
```

## Manual verification done during development

Both apps were built for web and driven in headless Chromium against
PostgREST + the seeded test database (Auth, Storage and Realtime servers were
not available in that environment, so sessions were injected):

* Admin Panel: dashboard, applications queue, the full review flow (start
  review → approve each document → approve application, confirmed in the DB),
  finance, admins and settings screens.
* Business App: home, station overview, charging points, availability,
  documents, bookings, reports and team screens as the demo owner.

## Not yet tested

* Real Supabase Auth emails, Storage uploads and Realtime subscriptions
  (need a running Supabase stack).
* Razorpay checkout end-to-end (needs test keys).
* FCM delivery and Google Maps rendering (need Firebase/Maps credentials).
* Android/iOS device builds (no Android SDK or Xcode in the build environment).
