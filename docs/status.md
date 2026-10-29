# Deliverables status

Last updated 2026-10-21. Legend:

* **Done**: implemented and verified by automated tests and/or running the app against real data.
* **Needs credentials**: code complete; cannot run end-to-end until the platform owner supplies keys.
* **Partial**: implemented with known gaps listed.
* **Planned**: not built yet.

| Area | Deliverable | Status | Notes |
|---|---|---|---|
| Backend | Schema, constraints, status machines | Done | 11 migrations; 105 DB tests |
| Backend | RLS, column grants, role model (7 roles + overrides) | Done | Isolation and escalation tests |
| Backend | No double booking | Done | Exclusion constraint; 20-way concurrency test |
| Backend | Onboarding workflow, document review, change requests | Done | |
| Backend | Booking holds, expiry, check-in (QR + reference), no-show jobs | Done | |
| Backend | Audit log, append-only history tables | Done | Immutable even to service role |
| Backend | Storage buckets and policies | Done (SQL) | Policies tested in SQL; real uploads not exercised (no Storage server here) |
| Backend | Realtime publication | Done (SQL) | Not exercised live |
| Backend | Scheduled jobs (`pg_cron`) | Done | Function logic tested; schedules apply on hosted Supabase |
| Payments | Razorpay order / verify / webhook / refunds | Needs credentials | Fully tested with a fake gateway; needs Razorpay test keys for a live run |
| Payments | Ledger, idempotency, duplicate/late/mismatch handling | Done | |
| Payments | Refund policy | Partial | Placeholder policy, `policy_confirmed_for_production = false`; needs owner decision |
| Finance | Summary, timeseries, expenses with approval/void | Done | Separates gross, refunds, processing fees, net, expenses, estimated profit |
| Finance | Commission | Planned (off) | Setting exists and is `false`; no logic by design |
| Notifications | In-app notifications | Done | |
| Notifications | FCM push dispatch | Needs credentials | Firebase project + service account |
| Admin Panel | Login, dashboard, applications & review, stations, bookings, finance, admins, settings, audit, notifications | Done | Browser-verified on seeded data; full review flow run through the UI |
| Admin Panel | Hosting | Planned | Static hosting of `build/web` |
| Business App | Auth (sign-up, verify, reset), business setup | Partial | Screens and logic done; email flows need a running Supabase Auth |
| Business App | Stations, points, connectors, hours, policies, blocked periods | Done | Rendered against seeded data |
| Business App | Documents and photos upload | Partial | Code complete; uploads need Supabase Storage to test |
| Business App | Bookings, live updates, QR scanner, manual check-in | Partial | Lists verified on data; camera scan and Realtime need a device / Supabase |
| Business App | Maintenance, team, reports, notifications, account | Done | |
| Business App | Google Maps picker | Needs credentials | Falls back to lat/lng fields without a key |
| Business App | Android / iOS builds | Planned | Not built here (no Android SDK / Xcode); signing config ready |
| Retailer App | Backend | Done | Discovery, slot grid, bookings, consents, reports, message outbox; DB and Edge Function tests |
| Retailer App | Discovery, slots, booking, payment, My Bookings, cancellation, profile, account deletion | Done | Widget tests on a mocked backend; web build screenshotted against a local fake backend, not yet against Supabase |
| Retailer App | English + Telugu | Done | Telugu strings machine-quality; have a native speaker review before launch |
| Retailer App | Phone OTP, SMS and email confirmations | Needs credentials | SMS provider in Supabase Auth; Twilio and Resend secrets for `dispatch-customer-messages` |
| Retailer App | Two searches: Along My Route (From / To, alternative routes, stations along the selected route with detour) and Near Me (device location or a chosen place, straight-line and driving distance) | Done | Free OpenStreetMap services (OSRM routing, Photon places), no key needed for testing; public servers are light-use only, so set `ORS_API_KEY` or self-host OSRM before launch |
| Retailer App | WhatsApp confirmations | Planned | Channel reserved in the outbox; no sender yet |
| Retailer App | Booking-fee refund policy | Placeholder | Server policy drives the app; owner decision pending |
| Retailer App | Android / iOS builds | Planned | Not built here; ids `in.chargekaro.app` |
| Quality | CI (DB, Deno, Flutter analyze/test/build, PostgREST integration) | Done (not yet run on GitHub) | Needs a GitHub repository |
| Docs | Architecture, setup, schema, API, security, finance, deployment, testing | Done | |
| Compliance | Regulatory compliance claims | Not claimed | Document review is a record, not certification |

## What the owner needs to provide

1. A GitHub repository (to push this code and run CI).
2. A Supabase project (URL, publishable key; service-role key stays in Supabase secrets).
3. Razorpay test keys and webhook secret, later live keys.
4. A Google Maps API key restricted to the app ids.
5. A Firebase project (Android/iOS config files, service account for push).
6. A decision on the booking-fee refund policy.
7. For the customer app: an SMS provider for OTP (Supabase Auth), Twilio and
   Resend accounts for confirmations, a production routing choice (free
   openrouteservice key or self-hosted OSRM), a map tile provider, and
   support email/phone.
