# ChargeKaro: EV charging slot booking platform

Station owners list EV charging stations and accept slot reservations;
customers pay a small booking fee (default INR 12) to the platform and pay for
charging directly at the station. The platform never collects charging fees.

| Component | Path | Tech |
|---|---|---|
| Backend | `supabase/` | Postgres + RLS, RPCs, Storage, Realtime, `pg_cron`, Edge Functions (Deno) |
| Business App | `apps/business_app` | Flutter (Android/iOS) for owners, managers and staff |
| Admin Panel | `apps/admin_panel` | Flutter Web for platform staff |
| Retailer App | `apps/retailer_app` | Planned; backend contract ready |
| Shared packages | `packages/` | Models, validation, data layer, UI kit |

## Quick start

```bash
supabase start && supabase db reset          # backend + demo seed
cp env/development.json.example env/development.json
flutter pub get
cd apps/admin_panel && flutter run -d chrome --dart-define-from-file=../../env/development.json
```

Full instructions: [docs/setup.md](docs/setup.md).

## Documentation

* [Architecture](docs/architecture.md)
* [Database schema](docs/database_schema.md) and [API contracts](docs/api_contracts.md)
* [Security model](docs/security.md)
* [Finance and reporting](docs/finance.md)
* [Deployment](docs/deployment.md)
* [Testing](docs/testing.md)
* [Deliverables status](docs/status.md)

## Ground rules

* Never commit secrets. Clients get only the publishable key.
* Roles come from the database, never from the client.
* Money is integer paise. No Razorpay Route / split settlements.
* Seed data is demo-only and marked `[DEMO]`.
