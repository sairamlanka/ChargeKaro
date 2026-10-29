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
  ui/explore             home, route search (From / To), filters, list and map
  ui/station             station page (slot grid first, details below), alternatives, report
  ui/booking             details, OTP, reserve, payment, confirmation
  ui/bookings            My Bookings, booking details, cancel, Find My Booking
  ui/profile             profile, change number, delete account, help
```

## Flow

1. **Explore**: two separate searches, one at a time. The chosen mode stays
   visible above the results, and switching modes clears the other mode's
   results so route stations are never shown as nearby ones (the trip or
   place itself is kept, so switching back searches again without retyping).
   * **Along My Route**: the customer enters From and To, each a place found
     through the `geocode-area` function, and taps "Find Stations Along
     Route". The `route-plan` function gets the driving route (up to three
     alternatives, "Route 1 / 2 / 3" chips) from free OpenStreetMap routing,
     the map draws it, and `search_stations_along_route` lists stations
     within the `route_corridor_km` platform setting (5 km by default; 1, 2,
     5 and 10 km one tap away) of the selected route, each once, in the order
     the driver reaches them. Picking another route searches that route.
     Cards show how far along the trip the station is, how far off the road,
     and "On route" (within 0.5 km) or "Detour about ..." (an estimate, twice
     the distance off the road). "Best stops" (default sort) puts free points
     first, then on-route stations, then the smallest detour, then trip
     order. The station page adds an "On your trip" card: distance from the
     start, distance from the route, the exact extra distance and time from
     `route-plan` with `via` (or the estimate if routing fails), "Directions
     to station" and "Then continue to <destination>" (directions through
     the station to the destination). The last trip is restored on launch.
   * **Near Me**: "Find Nearby Stations" asks for location, then searches
     the `nearby_radius_km` setting (5 km by default; 2, 10, 25 and 50 km one
     tap away). Cards show the straight-line distance and, for the 25
     nearest, the driving distance and time from `route-plan` (left out if
     routing fails). Permission denied, location off or timed out explain
     why and offer to retry, "Choose a location instead" (a place picked by
     hand, searched the same way), or the route search.
   The empty state offers a wider distance. When more stations match than
   are returned, the list says so. Only stations that are open right now
   are listed. Availability is the station's reported status with its
   update time; missing data shows as unavailable, never guessed. Sort by
   distance, earliest slot, fee or availability; filter by connector, power,
   vehicle, amenities, available now, free today and bookable only.
2. **Station page** (`/station/:id`, "View slots"): the slot picker comes
   first. The customer picks a date, an optional connector, a length
   (30, 45, 60 ... minutes on the station's 15-minute grid) and a start
   time. They do not pick a charging point. Each time shows how many
   compatible points are free ("2 of 3 free") or "Full" when every point is
   taken; every state has a colour, an icon and a word. The grid refreshes
   every minute and says if the chosen time was taken meanwhile. Below the
   grid: address, directions, points, charging cost and payment methods at
   the station, opening hours ("Hours not listed" when the station has none),
   booking rules, facilities and instructions. The booking fee, the refund
   policy and the station phone are not shown here; the phone appears only
   after booking.
3. **Details**: name and mobile required, email and vehicle optional, terms
   consent required, marketing consent optional and unticked.
4. **Verify**: Supabase phone OTP (resend after 30 s, at most 5 an hour).
   Skipped when this device already verified the same number. Right after
   it the app records consent and calls `create_station_booking_hold` with
   an idempotency key so retries never double book; the server assigns the
   point. Hold errors (full, overlapping, misaligned) open a sheet with the
   next step. A free booking is confirmed straight away.
5. **Pay**: the first place the fee is shown, with the booking summary and
   the arrival rules. `payments-create-order` then Razorpay. Success is
   never trusted from the client: the app calls `payments-verify` and then
   polls the booking until the server (or the webhook) confirms it.
   Cancelled, failed, unavailable, timed-out, hold-ended and
   paid-but-slot-lost cases each have their own screen with the next step.
6. **Confirmed**: reference, assigned point, QR, the time to reach the
   station (5 minutes before the start by default) and how long the point is
   held (5 minutes after it, then a no-show), directions, call the station,
   and the SMS and email delivery status. "Go to home" returns to Explore,
   which now shows the next booking at the top.

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
