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

## Retailer App contract

Guests (`anon`) can call the read-only discovery RPCs; everything else needs
a signed-in customer (phone OTP). All errors come back as
`{code, message}` from `private.raise_error`.

| Call | Who | Purpose |
| --- | --- | --- |
| `search_stations(p_latitude, p_longitude, p_radius_km)` | anon | Near Me: public stations in range with distance, status and next free slot; null radius means the `nearby_radius_km` setting (default 5) |
| `search_stations_along_route(p_path, p_corridor_km, p_limit)` | anon | Along My Route: public stations within `p_corridor_km` (0.5 to 25; null means the `route_corridor_km` setting, default 5) of a route line `[[lat, lng], ...]` (2 to 2000 points), each once, in the order the driver reaches them, with `off_route_km`, `along_route_km`, next free slot and `total_found` (matches before `p_limit`, at most 100) |
| `search_areas(p_query)` | anon | Area/station name matches from the database |
| `geocode-area` (function) | anon | Place name to coordinates (Photon, free OpenStreetMap geocoder; optional `near` ranks nearby places first) |
| `route-plan` (function) | anon | OSRM or openrouteservice (both OpenStreetMap). `{from, to}`: driving route with `routes` (up to 3 alternatives, each `path`, `distance_km`, `duration_minutes`). `{from, to, via}`: the same trip through a station, for the detour. `{from, destinations}` (at most 25): `distances`, driving distance and time to each, null where unroutable. Errors: `no_route`, `route_too_short`, `route_too_long`, `routing_unavailable` |
| `get_public_station(p_station_id)` | anon | Details, points, hours, closures |
| `get_station_slots(p_station_id, p_date)` | anon | Slot grid with a state per cell; no customer data |
| `get_booking_terms()` | anon | Fee, hold length, refund policy text, terms/privacy versions, `app_status` |
| `check_station_availability(p_station_id, p_start_at, p_end_at, p_connector_type)` | anon | Free points of total for a time, and the fee, before holding |
| `create_station_booking_hold(p_station_id, p_start_at, p_end_at, p_idempotency_key, p_connector_type, p_vehicle_label)` | customer | Assigns any free compatible point (best fit) and holds it, or confirms when the fee is 0. `station_full` when every point is taken; `overlapping_booking` when the customer already has a booking then |
| `payments-create-order`, `payments-verify` (functions) | customer | Razorpay order and signature check |
| `get_my_bookings`, `get_my_booking`, `get_my_booking_qr` | customer | Own bookings only |
| `preview_cancellation`, `cancel_booking` | customer | Refund eligibility, then cancel |
| `resend_booking_email` | customer | Queue the receipt email again |
| `customer_consents` (insert) | customer | Terms, privacy and marketing consent with versions |
| `submit_customer_report` | anon | Report wrong station information |
| `get_account_deletion_check`, `request_account_deletion` | customer | Blockers, then a deletion request |

`get_booking_terms().app_status` is the `retail_app_status` platform setting,
`{"min_build": int, "maintenance": bool, "message": text}`, or null.
See `apps/retailer_app/README.md` for the screen flow.
