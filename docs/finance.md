# Finance and reporting

## What the platform earns

The platform's only income is the **booking fee** a customer pays to reserve
a slot (default INR 12, `platform_settings.booking_fee_paise = 1200`).
Charging itself is paid by the customer **directly to the station**; the
platform never collects, holds or routes charging money.

`business_commission_enabled` is `false` and no commission logic exists.

## Money representation

All amounts are integer **paise** (`bigint`, suffix `_paise`), currency INR.
No floating point is used for money anywhere (database, Edge Functions or
Dart `Money` type).

## Ledger

`ledger_entries` is append-only and every entry has a unique source key, so
retries and duplicate webhooks cannot double-count.

| Entry type | Sign | Written when |
|---|---|---|
| `booking_fee_collected` | + | A payment is captured |
| `booking_fee_refunded` | − | A refund is processed by Razorpay |
| `gateway_fee` | − | Razorpay reports its fee (excluding tax) |
| `gateway_fee_tax` | − | Tax on the gateway fee |
| `operating_expense` | − | An expense is approved |
| `operating_expense_reversal` | + | An approved expense is voided |

## Report definitions (`get_financial_summary`)

| Field | Definition |
|---|---|
| Gross booking-fee collections | Sum of captured booking-fee payments |
| Refunds | Sum of processed refunds (pending refunds shown separately) |
| Payment processing fees | Gateway fee + tax on it |
| Net booking-fee revenue | Gross − refunds − processing fees |
| Operating expenses | Approved platform expenses (by category) |
| Estimated operating profit | Net revenue − operating expenses |

"Estimated" because taxes on income, depreciation and anything not recorded as
an expense are not included. Periods use IST calendar days.

## Admin Panel → Finance

| Tab | What it shows |
|---|---|
| Overview | Fees collected, refunds, gateway fees, net revenue, expenses and estimated profit for the selected range; revenue vs expenses chart (daily / weekly / monthly); profit and loss statement; top stations; expenses by category |
| Booking revenue | Revenue per station (`get_revenue_by_station`) and every booking that paid a fee in the range (`get_booking_revenue`): customer, booking ID, station, slot, amount collected, refunded and gateway fee. Search, station filter, CSV export |
| Expenses | Record, edit (while awaiting approval), approve, reject and void expenses; filter by status and category; manage categories (`save_expense_category`: add, rename, archive); CSV export |
| Reports | Profit over time (per period or running total), revenue vs expenses, P&L table with totals, P&L CSV export |
| Payments / Refunds | Raw gateway records |

Per-booking and per-station figures are read from the same ledger as the
summary, so for any range they add up to the summary totals (covered by
`supabase/tests/finance_reports.test.mjs`). A booking appears in a range when
it has ledger money in that range (a fee captured, a refund processed or a
gateway fee posted). Categories are never deleted, only archived, because
expenses refer to them; changes are audited. Category changes need
`finance.expenses.approve` or `settings.manage`.

## Expenses

Expenses are recorded by staff with `finance.expenses.write`, can carry receipt
files, and move `submitted → approved/rejected` (approval needs
`finance.expenses.approve`); approved expenses can be
voided (with a reason) but never deleted. Every step is audited.

## Refund policy (needs a business decision)

The shipped policy is a **placeholder** and is marked
`policy_confirmed_for_production = false`:

| Case | Default |
|---|---|
| Customer cancels | Fee kept |
| Station cancels | Fee refunded |
| Late payment loses the slot | Fee refunded automatically |
| Duplicate / amount-mismatch payment | Refunded automatically |

Admins with `finance.refunds.issue` can also issue a manual refund with a reason. The
platform owner must confirm or change this policy before launch (Admin Panel →
Settings).

## What is not shown

No figures are invented. Dashboards show zero/empty states until real
payments exist. Demo businesses are flagged `is_demo` and counted separately
on the admin dashboard; the local seed creates no payments or expenses.
