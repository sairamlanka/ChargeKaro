# API contracts

Clients talk to Supabase directly (PostgREST tables under RLS, RPCs, Storage,
Realtime) and to Edge Functions for anything that needs a secret. The Dart
repositories in `packages/shared_data/lib/src/repositories/` are the reference
client and are integration-tested against PostgREST.

## Error format

RPCs raise `private.raise_error(status, code, detail)`, which surfaces through
PostgREST as:

```json
{ "code": "PT409", "message": "slot_unavailable", "details": "..." }
```

`code` is `PT` + HTTP status, `message` is a stable machine code. Clients map
these with `AppFailure.from()` to plain-language text. Edge Functions return
`{ "error": "<code>", "message": "<text>" }` with the matching HTTP status.

## Edge Functions

| Function | Auth | Request | Response |
|---|---|---|---|
| `payments-create-order` | Customer JWT | `{ booking_id }` | `{ order_id, key_id, amount_paise, currency, booking_id, hold_expires_at }`. Amount comes from the DB. Reuses an existing order for the booking. |
| `payments-verify` | Customer JWT | `{ razorpay_order_id, razorpay_payment_id, razorpay_signature }` | `{ booking_id, result }`. Verifies the signature, re-fetches the payment, records idempotently. |
| `razorpay-webhook` | Razorpay signature (`x-razorpay-signature`) | Raw Razorpay event | `{ status }`; duplicates return `duplicate`. |
| `process-refunds` | `x-cron-secret` | none | `{ claimed, submitted, failed, retry_later }` |
| `dispatch-notifications` | `x-cron-secret` | none | `{ claimed, sent, skipped, failed, retry }` |

## RPCs callable by signed-in users

Every RPC re-checks the caller's permissions; being callable does not mean
allowed.

| Area | Functions |
|---|---|
| Access | `my_platform_access`, `my_business_access` |
| Business & team | `create_business`, `add_business_member`, `update_business_member`, `revoke_business_member` |
| Stations | `request_station_change`, `decide_station_change`, `close_station_temporarily`, `reopen_station`, `request_station_deactivation`, `suspend_station`, `reactivate_station`, `deactivate_station` |
| Points & availability | `set_charging_point_status`, `set_charging_point_connectors`, `set_station_operating_hours`, `create_blocked_period`, `cancel_blocked_period`, `get_point_busy_periods` |
| Onboarding | `submit_station_application`, `start_application_review`, `request_application_information`, `approve_station_application`, `reject_station_application`, `review_document`, `application_document_checklist` |
| Bookings | `create_booking_hold`, `cancel_booking`, `get_my_booking_qr`, `lookup_booking_for_checkin`, `check_in_booking`, `update_booking_progress`, `admin_override_booking`, `add_booking_support_note` |
| Maintenance | `report_maintenance_issue`, `update_maintenance_report` |
| Reports | `get_business_report`, `get_admin_dashboard`, `get_financial_summary`, `get_financial_timeseries` |
| Finance | `issue_refund`, `record_expense`, `update_submitted_expense`, `decide_expense`, `void_expense` |
| Platform admin | `grant_platform_role`, `revoke_platform_role`, `set_platform_permission_override`, `update_platform_setting` |
| Notifications | `mark_notifications_read`, `register_device_token`, `unregister_device_token` |

## Service-role only

`bootstrap_super_admin`, `prepare_payment_order`, `record_payment_order`,
`record_gateway_payment`, `record_webhook_event`, `complete_webhook_event`,
`claim_refunds`, `record_refund_result`, `claim_push_notifications`,
`complete_push_notification`, `run_booking_jobs`, `run_compliance_jobs`.

## Retailer App contract (future)

The customer flow is already implemented server-side and covered by tests:
browse active stations and points (signed-in read under RLS; `anon` has no
table access), `get_point_busy_periods`
for availability (time ranges only, no customer data), `create_booking_hold`
with an idempotency key, `payments-create-order` → Razorpay Checkout →
`payments-verify`, `get_my_booking_qr`, and `cancel_booking`. See
`apps/retailer_app/README.md`.
