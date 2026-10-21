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
  CORS_ALLOWED_ORIGIN=https://book.example.com

supabase functions deploy payments-create-order payments-verify razorpay-webhook process-refunds dispatch-notifications
```

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

## 7. Business App

See setup.md §5–7 for Maps, Firebase and signing. Then build an App Bundle
for Play Console and an archive from Xcode for App Store Connect.

## 8. FCM token note

The Business App registers the FCM registration token (`getToken`) because
the `dispatch-notifications` function sends through the FCM HTTP v1 API, which
targets registration tokens. `firebase_messaging` 17 marks `getToken`
deprecated in favour of installation-id based direct send; migrate both sides
together if adopting that API.
