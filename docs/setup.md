# Local setup

## Prerequisites

| Tool | Version used | Needed for |
|---|---|---|
| Flutter | 3.47.x stable | Business App, Admin Panel, shared packages |
| Supabase CLI | 2.x | Local stack (`supabase start`), migrations, Edge Functions |
| Docker | any recent | Required by `supabase start` |
| Deno | 2.x | Edge Function lint, type check and tests |
| Node.js | 22+ | Database test suite (`supabase/tests`) |
| Android Studio / Xcode | current | Mobile builds |

## 1. Start the backend

```bash
supabase start            # Postgres, Auth, Storage, Realtime, Studio
supabase db reset         # applies supabase/migrations/* and supabase/seed.sql
```

The seed is **demo data only** (every business is `is_demo = true` and named
`[DEMO] ...`). Demo accounts all use the password `DemoPass#2026`:

| Email | Role |
|---|---|
| admin@chargekaro.local | super_admin |
| ops@chargekaro.local | admin (+ finance read / expenses write) |
| reviewer@chargekaro.local | compliance_reviewer |
| owner@demo-ev.local | business owner |
| staff@demo-ev.local | station staff |

Never run `seed.sql` against production.

## 2. Edge Function secrets (local)

Copy `supabase/functions/.env.example` to `supabase/functions/.env` and fill in
Razorpay **test-mode** keys, a random `CRON_SECRET`, and (optionally) an FCM
service account. Then:

```bash
supabase functions serve --env-file supabase/functions/.env
```

`.env` files are git-ignored. Never put the service-role key or Razorpay
secret anywhere under `apps/` or `packages/`.

## 3. Client configuration

Clients receive only public values, via `--dart-define-from-file`:

```bash
cp env/development.json.example env/development.json   # git-ignored
```

| Key | Meaning |
|---|---|
| `SUPABASE_URL` | Project URL (`http://127.0.0.1:54321` locally; use your LAN IP for a physical phone) |
| `SUPABASE_ANON_KEY` | Publishable/anon key. The apps refuse to start with a secret or service-role key. |
| `APP_ENV` | `development`, `staging` or `production` |
| `AUTH_REDIRECT_URL` | Email-link redirect. Business App: `in.chargekaro.business://auth-callback` |
| `MAPS_ENABLED` | `true` once a Maps key is configured (Business App) |
| `FCM_ENABLED` | `true` once Firebase is configured (Business App) |

Without valid values the apps show a "setup required" screen instead of crashing.

## 4. Run the apps

```bash
flutter pub get                                   # at the repo root (workspace)
cd apps/admin_panel && flutter run -d chrome --dart-define-from-file=../../env/development.json
cd apps/business_app && flutter run --dart-define-from-file=../../env/development.json
```

## 5. Google Maps (Business App)

Without a key the location picker falls back to latitude/longitude fields plus
an "open in Google Maps" link, so onboarding still works.

* **Android:** set `MAPS_API_KEY=...` in `apps/business_app/android/local.properties`
  (git-ignored) or as an environment variable at build time.
* **iOS:** copy `apps/business_app/ios/Flutter/Secrets.xcconfig.example` to
  `Secrets.xcconfig` (git-ignored) and set `MAPS_API_KEY`.
* Restrict the key to the app's package name / bundle id and SHA-1 in Google Cloud.
* Build with `MAPS_ENABLED=true`.

## 6. Firebase Cloud Messaging (Business App)

1. Create a Firebase project and register Android `in.chargekaro.business` and the iOS bundle id.
2. Place `google-services.json` in `apps/business_app/android/app/` and
   `GoogleService-Info.plist` in `apps/business_app/ios/Runner/` (both git-ignored).
3. Add the Google Services Gradle plugin to the Android build and enable Push
   Notifications + Background Modes in Xcode (APNs key uploaded to Firebase).
4. Build with `FCM_ENABLED=true`.
5. Server side, set `FCM_SERVICE_ACCOUNT_JSON` for `dispatch-notifications`.

Notifications are always stored and shown in-app; push is an extra channel.

## 7. Android release signing

Create `apps/business_app/android/key.properties` (git-ignored):

```properties
storePassword=...
keyPassword=...
keyAlias=upload
storeFile=/absolute/path/to/upload-keystore.jks
```

Without it, release builds fall back to debug signing (fine for local testing,
not for the Play Store).

```bash
cd apps/business_app
flutter build apk --release --dart-define-from-file=../../env/production.json
flutter build appbundle --release --dart-define-from-file=../../env/production.json
```
