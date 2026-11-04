# Booking check-in (QR, manual, offline)

Three ways to check a driver in, one validation path in the database:

| Method | When | Result |
| --- | --- | --- |
| QR | Primary. Staff scan the code in the driver's app. | Server-verified `arrived` |
| Manual | QR not working, phone dead, camera broken. Booking ID or registered mobile number, plus a mandatory reason. | Server-verified `arrived` |
| Offline | No internet at the station. Reference checked against the last downloaded list. | Provisional `PENDING SYNC` on the device until the server accepts it |

Migration: `supabase/migrations/20261103000100_checkin.sql`.

## 1. What existed before, and what changed

| Area | Before | Now |
| --- | --- | --- |
| QR | `bookings.qr_token`, 128-bit, **plain text**, never expires or rotates, reusable | `booking_qr_tokens`: 256-bit token, **SHA-256 hash only**, one live token per booking, expires when the arrival window closes, consumed on arrival, revoked on cancel / no-show / expiry / reissue. Payload `CKB2:<token>`. `CKB1` codes answer "outdated". |
| Check-in RPCs | `lookup_booking_for_checkin`, `check_in_booking` (raise on rejection, no audit, no idempotency) | `verify_booking_qr`, `search_bookings_for_checkin`, `get_booking_for_checkin`, `checkin_booking`, `sync_offline_checkins`, `get_offline_checkin_cache`. Old two revoked from clients. |
| Charging | `update_booking_progress(in_progress / completed)` | `start_charging`, `complete_charging` (idempotent, audited, row-locked). `update_booking_progress` now only records no-shows. |
| Audit | `booking_events` (status changes), `audit_logs` | + `booking_checkin_logs` (append-only): every verify, search, check-in, rejection, override, offline sync, cache download and charging step. No raw tokens, phone numbers or names. |
| Staff privacy | Staff could read `customer_display_name` and `vehicle_label` for every booking; notifications named the customer | Column access revoked. Lists come from `get_station_bookings` / `get_station_booking`, which mask the customer until `arrived` (and 12 h after completion). Business notifications use the reference. Admins use `admin_search_bookings` (unchanged view for them). |
| Booking columns | `checked_in_at` | + `checkin_method`, `checked_in_by`, `checkin_reason`, `verification_status`, `checkin_device_id`, `checkin_event_id` (existing check-ins backfilled as `verified`). |
| Notifications | Customer push on check-in only | Push + SMS/email outbox for arrival verified, charging started, charging completed, no-show (dedupe keys, `status_updates` preference). |

### Status names

The spec's `CHARGING` is the existing `in_progress`; `PENDING_PAYMENT` is
`payment_pending`. Payment states are unchanged (`failed`, `refund_pending`,
`refunded` already existed). Verification is a separate column
(`not_checked_in`, `verified`, `pending_sync`, `rejected`); `pending_sync` only
exists on the device.

### Decisions on rule conflicts

1. **Late cut-off.** Default stays *slot start + `arrival_grace_minutes`*
   (the existing rule; the no-show job frees the point at that moment). The
   spec's *slot end + grace* is one setting away:
   `platform_settings.checkin_settings.late_window_basis = 'end'`. Both the
   check-in and the no-show job read `private.checkin_window`, so they never
   disagree. Early arrival uses `early_checkin_minutes`. Both are per station
   (`station_booking_policies`), boundaries are inclusive, all arithmetic is in
   UTC on the stored `tstzrange`, so DST and timezone changes don't move it.
2. **Edge Functions.** The logic lives in `SECURITY DEFINER` SQL functions
   (single transaction, `SELECT … FOR UPDATE`, exclusion constraint), like
   the rest of ChargeKaro. The five requested Edge Functions are thin
   wrappers that forward the caller's JWT, so they share the exact same
   checks. The Flutter apps call the RPCs directly.
3. **Manager override.** Station managers and owners (`bookings.manage`) can
   approve *too early*, *too late* and *already marked no-show* (only if the
   point is still free). Never payment problems, cancellations, duplicates, or
   unpaid (`expired`) holds. The override is done from the manager's own
   account; the log records `staff_id = manager_id`, the reason and the
   overridden problem. A two-person "pump boy asks, manager approves on another
   phone" flow is not built. Platform admins keep `admin_override_booking`.
4. **Offline vs auto no-show.** If the no-show job runs before an offline
   check-in syncs, the event is rejected as `no_show_conflict` and a manager
   decides (manual check-in with override). Set
   `checkin_settings.offline_accept_after_no_show = true` to accept such
   events automatically when the device time was inside the window.
5. **Local storage.** The offline list contains booking id, reference, slot,
   window, point code and current type only, so it is kept in
   SharedPreferences without extra encryption (no new dependency). Nothing
   personal is cached.

## 2. API

All RPCs need a signed-in user. Rejections are returned, not raised, so the
audit row survives:

```json
{ "result": "rejected", "code": "too_late", "message": "The arrival window for this booking has closed.", "override_allowed": false }
```

Booking objects for staff (`booking`) contain: `id, reference, station_id,
station_name, station_timezone, charging_point_code, start_at, end_at,
status, payment_status, payment_settled, verification_status,
checkin_method, checked_in_at, checkin_opens_at, checkin_closes_at,
compatibility {current_type, max_power_kw, connectors}, vehicle_hint
("•••• 1234"), customer_revealed`, and only when `customer_revealed` is true:
`customer_display_name, customer_phone, vehicle_label`.

| RPC / Edge Function | Input | Output |
| --- | --- | --- |
| `get_my_booking_qr(p_booking_id)` (customer) | booking id | `{reference, qr_payload, issued_at, expires_at, checkin_opens_at, status}`; revokes the previous code. 409 `already_checked_in`, `qr_not_available`, `qr_expired`, `rate_limited` (20 per hour) |
| `verify_booking_qr(p_station_id, p_payload, p_device_id)` / `POST verify-booking-qr {station_id, qr, device_id}` | scanned text | `{result: "verified", eligible, code, message, override_allowed, booking}` or rejection (`invalid_qr, qr_outdated, qr_revoked, qr_used, qr_expired, wrong_station, not_authorized, rate_limited`, booking problems) |
| `search_bookings_for_checkin(p_station_id, p_query, p_device_id)` | `CK…` reference or mobile (`9876543210`, `09876…`, `91…`, `+91 …`, any `+<country>`) | `{result: "ok", bookings: [booking]}` for this station, slots from −12 h to +24 h; 20 searches / 10 min |
| `get_booking_for_checkin(p_station_id, p_booking_id)` | | same shape as verify |
| `checkin_booking(p_station_id, p_booking_id, p_method, p_idempotency_key, p_qr_payload, p_reason_code, p_reason_note, p_device_id, p_override_reason)` / `POST checkin-booking {station_id, booking_id, method, idempotency_key, qr?, reason_code?, reason_note?, device_id?, override_reason?}` | `method` = `qr` (needs `qr`) or `manual` (needs `reason_code`: `qr_not_working, phone_unavailable, app_unavailable, scanner_malfunction, connectivity_issue, qr_damaged, cannot_access_booking, other` + note) | `{result: "accepted", booking}` (customer revealed), `replayed: true` on a retry with the same key, or rejection |
| `get_offline_checkin_cache(p_station_id, p_device_id)` | | `{station_id, generated_at, valid_until (+12 h), bookings: [{id, reference, start_at, end_at, status, charging_point_code, current_type, checkin_opens_at, checkin_closes_at}]}` |
| `sync_offline_checkins(p_events)` / `POST sync-offline-checkins {events}` | 1–50 × `{event_id (uuid), booking_id, station_id, offline_at, device_id}` | `{results: [{event_id, result, code, message, booking?}], synced_at}`; each event independent; `event_id` is the idempotency key |
| `start_charging(p_booking_id, p_idempotency_key, p_device_id)` / `POST start-charging` | | needs `arrived`; `already_charging`, `not_arrived` |
| `complete_charging(…)` / `POST complete-charging` | | needs `in_progress`; `not_charging`, `booking_completed` |
| `get_station_bookings(p_station_id, p_from, p_to, p_statuses)`, `get_station_booking(p_booking_id)` | | masked staff booking JSON |
| `get_checkin_history(p_station_id, p_limit)` | | managers: everyone's entries; staff: their own |
| `admin_search_bookings(…)` | admin filters | needs `bookings.read_all` |

Edge Functions return HTTP 401 without a valid JWT, 422 for malformed input,
and otherwise the RPC's JSON with HTTP 200.

## 3. Edge cases and where they are tested

`supabase/tests/checkin.test.mjs` (34 tests, real Postgres), plus the updated
`bookings.test.mjs` / `security.test.mjs`, `packages/shared_models/test/checkin_test.dart`
(Dart rules) and `supabase/functions/_tests/checkin_test.ts` (wrappers).

| Scenario | Backend | DB / audit | App |
| --- | --- | --- | --- |
| Valid QR | `verified` → `accepted` | `arrived`, `verified`, token consumed, `qr_verify` + `checkin` rows | Confirm screen → success with customer details |
| Invalid / corrupted / SQL-ish QR | `invalid_qr` | rejected `qr_verify` row, no booking id | Red panel, "Scan again", Manual |
| Legacy CKB1 | `qr_outdated` | logged | Ask driver to reopen the booking |
| Screenshot / other device after reissue | `qr_revoked` | logged | same |
| QR reused after check-in | `already_checked_in` | logged | "Already checked in" (amber) |
| QR of another station | `wrong_station` | logged without booking id | nothing about that booking shown |
| Unauthorised staff / customer / anon | `not_authorized` / 42501 | logged | message |
| Brute force | `rate_limited` after 15 failed scans / 10 min | logged | message |
| QR after cancellation / no-show | `booking_cancelled` / `marked_no_show` | token revoked by trigger | message |
| Expired window | `qr_expired` (customer), `too_late` (staff) | | override for managers |
| Payment pending / failed / refunded | `payment_pending` / `payment_failed` / `payment_reversed` | never overridable | message |
| Manual without reason / Other without note | `reason_required` / `reason_note_required` | logged | form validation first |
| Phone search, several bookings, several stations | only this station's slots | `search` row with kind + count only | list of references |
| Enumeration | `rate_limited` after 20 searches / 10 min | | message |
| Manager override late arrival | `accepted` | `override` row with `manager_id`, `from_status`, `overridden_problem` | "Approve and check in" |
| Pump boy override | `override_not_allowed` | logged | hint to ask a manager |
| Double tap / timeout retry | same key → `replayed` | one audit row, one notification | button disabled while busy |
| Two staff at once | one `accepted`, others `already_checked_in` / `checked_in_by_other` | one `check_ins` row (row lock + unique) | |
| Charging twice | second `already_charging` | | |
| Offline accepted | `accepted` | `offline_sync` row with device time, server time, device id | queue shows Verified |
| Offline synced twice / concurrently | first verdict returned | one row | |
| Cancelled / refunded / other station / checked in by other while offline | `booking_cancelled` / `payment_reversed` / `booking_not_found` / `checked_in_by_other` | rejected row | queue shows Rejected + reason, never arrived |
| Device clock wrong | `clock_invalid` (future or before booking created) | | |
| Synced too late | `sync_too_late` (> 24 h) | | |
| No-show before sync | `no_show_conflict` | booking stays `no_show` | manager reviews |
| Staff revoked before sync | `not_authorized` | | |
| Logout / app data cleared / device lost before sync | events stay on device per staff id / are lost | booking follows the normal no-show rule | manager can override |
| Staff reads customer columns, edits payment / owner / station / timestamps, edits logs | 42501 / `immutable_record` | | |
| Window boundaries | open and close instants both accepted | | |
| Notifications | arrival, charging, completion, no-show once each | `notifications` + `customer_messages` with dedupe keys | push (when FCM is set up), SMS/email (when providers are set up) |

App lifecycle: the scanner releases the camera when the app is backgrounded;
a check-in that succeeded before a crash or timeout is returned again by the
idempotency key or shows as `already_checked_in`; the retailer app caches the
current QR per booking and clears it on sign-out (a reinstall simply gets a
new code, revoking the old one); bookings refresh on open and on the refresh
button.

## 4. Deployment

1. Apply the migration (from Sairam's terminal, CLI already linked):
   `npx supabase db push --linked`
2. Deploy the Edge Functions (JWT verification on):
   `npx supabase functions deploy verify-booking-qr checkin-booking sync-offline-checkins start-charging complete-charging`
   and redeploy `dispatch-customer-messages` (new SMS/email templates).
3. Rebuild the Business App (new dependencies `connectivity_plus`,
   `shared_preferences`; run `flutter pub get`) and the Retailer App.
4. Optional settings (`update_platform_setting('checkin_settings', …)`):
   `late_window_basis`, `offline_cache_max_age_hours`, `offline_sync_max_hours`,
   `offline_accept_after_no_show`, `clock_skew_minutes`,
   `search_limit_per_10_min`, `failed_verify_limit_per_10_min`,
   `qr_issue_limit_per_hour`.

Existing confirmed bookings keep working: their customers get a `CKB2` code
the first time they open the booking.

## 5. Environment variables

No new secrets. Edge Functions use the injected `SUPABASE_URL` and
`SUPABASE_ANON_KEY` (the caller's JWT is forwarded; the service role is not
used). Notifications use the existing optional provider variables
(`FCM_SERVICE_ACCOUNT_JSON` for push; `TWILIO_ACCOUNT_SID`,
`TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` for SMS; `RESEND_API_KEY`,
`EMAIL_FROM` for email); without them messages are stored and
marked `skipped`, and check-in is unaffected.

## 6. Rollback

`npx supabase db query --linked -f supabase/snippets/checkin_rollback.sql`
restores the old API for older app builds (CKB1 QR, `check_in_booking`,
`update_booking_progress` for charging, staff column access) while keeping
all new tables and audit data. Then redeploy the previous app builds. A hard
rollback (drops the new tables and columns) is at the bottom of that file,
commented out.

## 7. Changed files

- `supabase/migrations/20261103000100_checkin.sql` (new)
- `supabase/snippets/checkin_rollback.sql` (new)
- `supabase/functions/_shared/checkin.ts`, `verify-booking-qr/`, `checkin-booking/`, `sync-offline-checkins/`, `start-charging/`, `complete-charging/` (new); `_shared/messaging.ts` (templates); `config.toml` (function entries)
- `supabase/tests/checkin.test.mjs` (new); `bookings.test.mjs`, `security.test.mjs` (new API)
- `supabase/functions/_tests/checkin_test.ts` (new)
- `packages/shared_models`: `src/checkin.dart` (new), `src/booking.dart`, `shared_models.dart` (export), `test/checkin_test.dart` (new)
- `packages/shared_data`: `repositories/booking_repository.dart`; `test/integration/rest_integration_test.dart`
- `apps/business_app`: `lib/checkin/checkin_state.dart`, `lib/pages/checkin/*` (new); `lib/pages/bookings/scan_page.dart` (removed, replaced by `checkin/qr_scan_page.dart`); `booking_detail_page.dart`, `bookings_page.dart`, `home_page.dart`, `app.dart`, `pubspec.yaml`
- `apps/retailer_app`: `data/models.dart`, `data/retail_repository.dart`, `data/local_store.dart`, `ui/bookings/booking_widgets.dart`, `ui/bookings/booking_detail_screen.dart`, `ui/profile/profile_screen.dart`, `l10n/{keys,en,te}.dart`
- `docs/checkin.md`
