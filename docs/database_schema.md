# Database schema

Postgres (Supabase). Source of truth: `supabase/migrations/`, applied in order.
Times are `timestamptz` (UTC); reporting uses IST days. Money is `bigint` paise.

| Migration | Tables |
|---|---|
| `000100_foundation` | `platform_settings`, `audit_logs` (append-only) |
| `000200_identity_and_roles` | `profiles`, `platform_permissions`, `platform_role_permissions`, `platform_staff`, `platform_staff_permission_overrides` |
| `000300_businesses_and_stations` | `businesses`, `business_members`, `stations`, `station_assignments`, `station_photos`, `charging_points`, `charging_connectors`, `station_operating_hours`, `station_booking_policies`, `blocked_periods`, `station_change_requests` |
| `000350_notifications` | `notifications`, `device_tokens` |
| `000400_onboarding` | `document_types`, `station_applications`, `application_events` (append-only), `station_documents`, `document_reviews` (append-only) |
| `000500_bookings` | `bookings`, `booking_events` (append-only), `check_ins`, `booking_support_notes` |
| `000600_payments_and_finance` | `payment_orders`, `payments`, `refunds`, `payment_webhook_events`, `ledger_entries` (append-only), `expense_categories`, `platform_expenses`, `expense_attachments` |
| `000700_maintenance_reports_jobs` | `maintenance_reports`, `maintenance_photos`; report and scheduled-job functions |
| `000800_rls_and_grants` | RLS policies, column grants, function execute grants |
| `000900_storage_realtime_cron` | Storage buckets and policies, Realtime publication, `pg_cron` schedules |
| `001000_client_batch_writes` | Atomic hours/connector replacement RPCs |

## Key constraints

* `bookings_no_overlap`: an exclusion constraint (`gist`, `charging_point_id`
  with `=`, the buffered `occupancy` range with `&&`) over bookings in
  `payment_pending`, `confirmed`, `arrived` or `in_progress`.
  This is what makes double booking impossible, including under concurrency.
* Bookings have a unique `(customer_id, idempotency_key)` so retries return the same row.
* `ledger_entries` has a unique source key per event; `payment_webhook_events`
  is unique per gateway event id.
* Check constraints on money (non-negative paise) and text/number ranges;
  RPCs additionally validate coordinates (India bounds), slot alignment,
  operating hours and advance-booking limits.

## Status machines

| Entity | States |
|---|---|
| Business | `pending_verification` → `active`; `suspended`, `deactivated` |
| Station | `draft` → `active` (on application approval) ↔ `temporarily_closed`; `suspended` ↔ `active`; `deactivated` (final) |
| Application | `draft` → `submitted` → `under_review` → `additional_information_required` → `submitted` …; → `approved` / `rejected` (resubmittable); `suspended` |
| Booking | `payment_pending` → `confirmed` → `arrived` → `in_progress` → `completed`; or `cancelled`, `expired`, `no_show` |
| Payment | `authorized`, `captured`, `failed` |
| Refund | `requested` → `processing` → `processed` / `failed` |
| Expense | `submitted` → `approved` / `rejected`; `approved` → `void` |

Transitions happen only through RPCs; guard triggers reject direct writes.

## Storage buckets

| Bucket | Public | Limit | Path |
|---|---|---|---|
| `station-documents` | no | 25 MB, PDF/JPEG/PNG/WebP | `{business}/{station or "business"}/{random}.ext` |
| `station-media` | yes | 5 MB, images | `{business}/{station}/{random}.ext` |
| `maintenance-photos` | no | 10 MB, images | `{business}/{station}/{random}.ext` |
| `expense-receipts` | no | 10 MB, PDF/images | `{year}/{random}.ext` |

## Realtime

Published tables: `booking_events`, `notifications`, `charging_points`,
`station_applications`, `maintenance_reports`. RLS applies to subscriptions.
