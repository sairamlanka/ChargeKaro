# Retailer App (planned)

The customer-facing app is not built in this phase. Its backend is ready and
tested; see [docs/api_contracts.md](../../docs/api_contracts.md#retailer-app-contract-future).

Flow: sign in → browse active stations → `get_point_busy_periods` →
`create_booking_hold` (with an idempotency key) → `payments-create-order` →
Razorpay Checkout → `payments-verify` → `get_my_booking_qr` to show the QR at
the station. Customers pay for charging directly at the station.

When building it, reuse `packages/shared_models`, `shared_validation`,
`shared_data` and `shared_ui`.
