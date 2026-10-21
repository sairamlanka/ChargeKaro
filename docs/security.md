# Security model

## Principles

1. **The database is the authority.** Every rule that matters (who may do what,
   booking overlap, payment state, ledger correctness) is enforced in Postgres,
   not in the apps. Client UI filtering is convenience only.
2. **Roles come from tables, never from the client.** Platform roles live in
   `platform_staff`; business roles in `business_members` and
   `station_assignments`. Both are read via `auth.uid()`. JWT claims and user
   metadata are never trusted for authorization.
3. **Clients hold only the publishable key.** `AppConfig.looksPrivileged`
   refuses to start an app configured with an `sb_secret_...` key or a JWT whose
   role is `service_role`.
4. **No open admin sign-up.** The first super admin is created once with
   `bootstrap_super_admin(email)`, which only `service_role` may execute and
   which refuses if an active super admin exists. Further staff are granted by a
   super admin through `grant_platform_role`. Signing up through the apps can
   never produce platform access.

## Enforcement layers

| Layer | What it does |
|---|---|
| RLS | Enabled on every `public` table. `anon` has no table access. Policies scope rows to the caller's businesses/stations or platform permissions. |
| Column grants | Sensitive columns (for example `bookings.qr_token`) are not selectable by clients; clients use `get_my_booking_qr`. |
| `SECURITY DEFINER` RPCs | All privileged state changes. `search_path = ''`, explicit permission checks, validation, audit entry. Execute revoked from `public`/`anon`. |
| Guard triggers | Block direct client writes to workflow columns (status, approval, payment fields) so they can only change through RPCs. |
| Append-only triggers | `audit_logs`, `ledger_entries`, `application_events`, `booking_events`, `document_reviews` reject update/delete. |
| Service-role-only functions | Payment, refund, webhook, notification-claim and scheduled-job functions are executable only by `service_role` (Edge Functions). |
| Storage policies | Private buckets for documents, maintenance photos and receipts, path-scoped by business id; read through 5-minute signed URLs. Only station media is public. |

## Platform permissions

Roles have default permissions (`platform_role_permissions`) and a super admin
can grant or deny individual permissions per person
(`platform_staff_permission_overrides`). Every change is audited.
`SUPER_ADMIN` implicitly holds all permissions.

## Payments

* The booking fee amount is read from `platform_settings` in the database,
  never from the request.
* Razorpay signatures (checkout and webhook) are verified with constant-time
  comparison; the payment is then re-fetched from Razorpay before recording.
* Webhook events are stored by event id and processed idempotently.
* Refunds use idempotency keys; the ledger has a unique key per source event.
* The platform never collects or routes charging fees. No Razorpay Route,
  split settlement or charging-payment code exists.

## Scheduled endpoints

`process-refunds` and `dispatch-notifications` require the `x-cron-secret`
header (constant-time compared to `CRON_SECRET`).

## Secrets handling

* Never commit: service-role key, Razorpay key secret / webhook secret,
  `CRON_SECRET`, FCM service account, keystores, `google-services.json`,
  `GoogleService-Info.plist`, Maps keys. `.gitignore` covers all of these.
* Edge Function secrets are set with `supabase secrets set` (see deployment.md).
* GitHub Actions uses placeholders for build checks; real values belong in
  repository/environment secrets used only by deployment jobs.

## Not claimed

The platform does not claim compliance with any regulation (for example CEA
guidelines, DPDP Act) and does not control chargers remotely. Document review
records what an admin checked; it is not a certification.

## Pre-launch checklist

- [ ] Rotate all demo passwords; do not run `seed.sql` in production
- [ ] Bootstrap exactly one super admin; enable MFA for staff in Supabase Auth
- [ ] Restrict Maps keys to app ids; restrict Auth redirect URLs
- [ ] Set `CORS_ALLOWED_ORIGIN` to the single web origin that calls the payment functions (a Retailer web app, if any)
- [ ] Confirm the refund policy and set `policy_confirmed_for_production = true`
- [ ] Switch Razorpay to live keys only after a full test-mode run
- [ ] Review Storage bucket size/mime limits
- [ ] Enable Point-in-Time Recovery / backups on the Supabase project
