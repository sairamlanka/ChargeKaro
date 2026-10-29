# ChargeKaro (customer app)

Flutter app (Android, iOS, web) for EV drivers to find a charging station,
see live slot availability, book a slot for the ₹12 booking fee, pay with
Razorpay and show a QR code at the station. Charging itself is paid at the
station.

Guests can browse everything. A mobile number verified by OTP is needed only
to book or to see bookings; that creates or reuses one account per number.

## Run

```bash
cd apps/retailer_app
flutter run -d chrome \
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_...
```

Or `--dart-define-from-file=../../env/development.json`. Without a usable URL
and key the app shows a setup screen instead of crashing.

| Define | Required | Purpose |
| --- | --- | --- |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | yes | Project URL and **publishable** key. Never the service-role key. |
| `APP_BUILD` | no (1) | Build number compared with `retail_app_status.min_build` to force an update. |
| `SUPPORT_EMAIL`, `SUPPORT_PHONE` | no | Shown in Help. Hidden when empty. |
| `MAP_TILE_URL`, `MAP_TILE_ATTRIBUTION` | no | Map tiles. Defaults to OpenStreetMap, which is fine for development only; use a tile provider with a production licence. |

## Layout

```
lib/
  main.dart              config, Supabase init, local store, ProviderScope
  app.dart               routes, maintenance / forced-update gate
  data/                  models, RetailRepository (RPCs + Edge Functions),
                         location service, local store, Razorpay checkout
                         (mobile SDK / web checkout.js)
  state/                 Riverpod providers, search state, booking draft
  l10n/                  K keys, English and Telugu strings
  ui/explore             home, area search, filters, list and map
  ui/station             station details, slot grid, alternatives, report
  ui/booking             details, OTP, review, payment, confirmation
  ui/bookings            My Bookings, booking details, cancel, Find My Booking
  ui/profile             profile, change number, delete account, help
```

## Flow

1. **Explore**: current location (permission denied, off, or timed out all
   fall back to area search), or an area name through the `geocode-area`
   function. Default radius 5 km; 2, 10, 25 and 50 km are one tap away and
   the empty state offers to widen. Sort by distance, earliest slot, fee or
   availability; filter by connector, power, vehicle, amenities, open now,
   available now, free today and bookable only.
2. **Station**: details, points, opening hours, closures and live status.
   Closed, unverified or full stations show why and link to alternatives.
3. **Slots**: `get_station_slots` for up to 30 days ahead. Every state has a colour,
   an icon and a word, and each cell has a spoken label. The grid refreshes
   every minute and says if the chosen time was taken meanwhile.
4. **Details**: name and mobile required, email and vehicle optional, terms
   consent required, marketing consent optional and unticked.
5. **Verify**: Supabase phone OTP (resend after 30 s, at most 5 an hour).
   Skipped when this device already verified the same number.
6. **Review**: re-checks the slot and fee (`check_slot_availability`), records consent,
   `create_booking_hold` with an idempotency key so retries never double
   book. A free booking is confirmed straight away.
7. **Pay**: `payments-create-order` then Razorpay. Success is never trusted
   from the client: the app calls `payments-verify` and then polls the
   booking until the server (or the webhook) confirms it. Cancelled, failed,
   unavailable, timed-out, hold-ended and paid-but-slot-lost cases each have
   their own screen with the next step.
8. **Confirmed**: reference, QR, arrival window, directions, and the SMS and
   email delivery status.

Booking phases shown to the customer are derived only from server state
(`CustomerBooking.phaseAt`).

## Refund policy

The cancellation screen shows what `preview_cancellation` returns, so the
app follows whatever the server policy is. The policy itself is still a
placeholder until the owner decides it (`refund_policy.policy_confirmed_for_production`).

## Tests

```bash
flutter analyze
flutter test
```

`test/flow_test.dart` drives the real screens against a mocked repository:
guest explore with location denied, Telugu, slot legend and explanations,
choosing a time, hold expiry, cancelled checkout and a verified payment.
`test/l10n_test.dart` checks that every key exists in both languages with
matching placeholders.
