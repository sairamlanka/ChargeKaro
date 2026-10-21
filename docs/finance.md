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
