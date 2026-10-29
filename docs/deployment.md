# Deployment

Nothing in this repository has been deployed. These are the steps for the
platform owner once a Supabase project, Razorpay account, Firebase project and
Google Maps key exist.

## 1. Supabase project

```bash
supabase login
supabase link --project-ref <project-ref>
supabase db push                 # applies supabase/migrations (NOT seed.sql)
```

Enable the `pg_cron` and `pg_net` extensions in the dashboard before pushing,
so the migration schedules `run_booking_jobs` (every minute) and
`run_compliance_jobs` (daily, 03:00 IST).

Auth settings:

* Email confirmations on; site URL = Admin Panel URL.
* Redirect URLs: Admin Panel origin and `in.chargekaro.business://auth-callback`.
* Consider enabling MFA for platform staff.
* Customer app: enable the Phone provider with an SMS provider (Twilio,
  MessageBird, Vonage or Textlocal), keep phone sign-ups on, and set the OTP
  rate limits. Add the customer web origin to the redirect URLs.
* Optional: set the `retail_app_status` platform setting to
  `{"min_build": 2, "maintenance": false, "message": null}` to force updates or
  show a maintenance notice in the customer app.

## 2. First super admin

1. Invite the owner's email from Authentication → Users.
2. In the SQL editor (runs as `postgres`):

   ```sql
   select public.bootstrap_super_admin('owner@example.com');
   ```

   It refuses once an active super admin exists. Further admins are granted
   from the Admin Panel (Admins page).

## 3. Edge Functions

```bash
supabase secrets set \
  RAZORPAY_KEY_ID=rzp_test_... \
  RAZORPAY_KEY_SECRET=... \
  RAZORPAY_WEBHOOK_SECRET=... \
  CRON_SECRET=$(openssl rand -hex 32) \
  FCM_SERVICE_ACCOUNT_JSON="$(cat service-account.json)" \
  CORS_ALLOWED_ORIGIN=https://book.example.com \
  TWILIO_ACCOUNT_SID=... TWILIO_AUTH_TOKEN=... TWILIO_FROM_NUMBER=+91... \
  RESEND_API_KEY=... EMAIL_FROM="ChargeKaro <bookings@example.com>"

supabase functions deploy payments-create-order payments-verify razorpay-webhook \
  process-refunds dispatch-notifications geocode-area route-plan dispatch-customer-messages
```

Route search and place search in the customer app use free OpenStreetMap
services and need no key to start: `route-plan` calls the public OSRM demo
server and `geocode-area` the public Photon server. Both public servers are
for light use only. Before launch, either set `ORS_API_KEY` (free
openrouteservice key, about 2,000 routes a day) or run OSRM yourself with the
India extract and set `OSRM_URL`; `PHOTON_URL` points place search at a
self-hosted Photon in the same way.

The default search distances are platform settings, changed without an app
release: `update public.platform_settings set value = '8' where key =
'route_corridor_km'` (0.5 to 25 km) or `'nearby_radius_km'` (0.5 to 50 km).

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are
provided to functions automatically by Supabase. JWT verification settings
per function are in `supabase/config.toml` (webhook and scheduled functions
verify their own signature/secret instead).

## 4. Schedule the Edge Functions

Store the secret in Vault and schedule with `pg_cron` + `pg_net`:

```sql
select vault.create_secret('<same CRON_SECRET>', 'cron_secret');

select cron.schedule('chargekaro-dispatch-notifications', '* * * * *', $$
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/dispatch-notifications',
    headers := jsonb_build_object('x-cron-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{}'::jsonb);
$$);

select cron.schedule('chargekaro-dispatch-customer-messages', '* * * * *', $$
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/dispatch-customer-messages',
    headers := jsonb_build_object('x-cron-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{}'::jsonb);
$$);

select cron.schedule('chargekaro-process-refunds', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/process-refunds',
    headers := jsonb_build_object('x-cron-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{}'::jsonb);
$$);
```

## 5. Razorpay

* Dashboard → Webhooks → URL `https://<project-ref>.supabase.co/functions/v1/razorpay-webhook`,
  secret = `RAZORPAY_WEBHOOK_SECRET`, events: `payment.authorized`,
  `payment.captured`, `payment.failed`, `order.paid`, `refund.created`,
  `refund.processed`, `refund.failed`.
* Enable auto-capture for payments.
* Run the whole flow in **test mode** first. Do not enable Route or split
  settlements; they are intentionally unsupported.

## 6. Admin Panel (Flutter Web)

```bash
cd apps/admin_panel
flutter build web --release --dart-define-from-file=../../env/production.json
```

Host `build/web` on any static host (Firebase Hosting, Netlify, Cloudflare
Pages, S3+CloudFront) with an SPA fallback to `index.html` and HTTPS.

## 7. Customer app (Flutter)

```bash
cd apps/retailer_app
flutter build web --release --dart-define-from-file=../../env/production.json \
  --dart-define=APP_BUILD=1 --dart-define=SUPPORT_EMAIL=help@example.com \
  --dart-define=SUPPORT_PHONE=+91... --dart-define=MAP_TILE_URL=https://...
```

Host `build/web` like the Admin Panel and set `CORS_ALLOWED_ORIGIN` to its
origin. Android (`in.chargekaro.app`) and iOS builds follow setup.md; the app
needs location permission only for "Use my current location".

## 8. Business App

See setup.md §5–7 for Maps, Firebase and signing. Then build an App Bundle
for Play Console and an archive from Xcode for App Store Connect.

## 9. FCM token note

The Business App registers the FCM registration token (`getToken`) because
the `dispatch-notifications` function sends through the FCM HTTP v1 API, which
targets registration tokens. `firebase_messaging` 17 marks `getToken`
deprecated in favour of installation-id based direct send; migrate both sides
together if adopting that API.
