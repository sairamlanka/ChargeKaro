import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { rpc, sql, one, as, rejectsWith, closePool, createUser, createStaff, approvedStation, hold, setFee, ist } from './lib/db.mjs';

after(async () => {
  await setFee(0);
  await closePool();
});
before(() => setFee(1200));

// Each run books its money into a random historical month so totals are
// isolated from other tests and from previous runs on the same database.
const year = 1990 + Math.floor(Math.random() * 30);
const month = 1 + Math.floor(Math.random() * 12);
const pad = (n) => String(n).padStart(2, '0');
const day = (d) => `${year}-${pad(month)}-${pad(d)}`;
const at = (d, hh = 12) => new Date(`${day(d)}T${pad(hh)}:00:00+05:30`).toISOString();
const monthEnd = new Date(Date.UTC(year, month, 0)).getUTCDate();

let station;
let finance;
let recorder;

let slot = 0;
async function paidBooking({ capturedOn, fee = 28, tax = 4, amount = 1200 }) {
  const customer = await createUser('customer');
  slot += 1;
  const b = await hold(customer, station.pointIds[0], ist(1, 6 + slot), 30);
  const order = `order_${randomUUID().slice(0, 18)}`;
  await rpc('service', 'record_payment_order', [b.id, order, 1200, 'INR', b.reference]);
  const pay = `pay_${randomUUID().slice(0, 18)}`;
  await rpc('service', 'record_gateway_payment', [order, pay, amount, 'INR', 'captured', 'upi', fee, tax, null, null, capturedOn]);
  return { booking: b, order, pay };
}

describe('financial reporting', () => {
  before(async () => {
    station = await approvedStation({ points: ['P1', 'P2', 'P3', 'P4'] });
    finance = await createStaff('admin', { 'finance.read': true, 'finance.expenses.approve': true });
    recorder = await createStaff('admin', { 'finance.read': true, 'finance.expenses.write': true });
  });

  test('summary separates collections, refunds, fees, expenses and profit', async () => {
    // Three captured payments in the month.
    const p1 = await paidBooking({ capturedOn: at(3) });
    await paidBooking({ capturedOn: at(10), fee: 30, tax: 5 });
    await paidBooking({ capturedOn: at(20), fee: null, tax: null });
    // One failed payment: never counted as collected.
    const customer = await createUser('customer');
    const fb = await hold(customer, station.pointIds[1], ist(2, 9), 30);
    const fo = `order_${randomUUID().slice(0, 18)}`;
    await rpc('service', 'record_payment_order', [fb.id, fo, 1200, 'INR', fb.reference]);
    await rpc('service', 'record_gateway_payment', [fo, `pay_${randomUUID().slice(0, 18)}`, 1200, 'INR', 'failed', 'card', null, null, 'X', 'declined', at(11)]);
    // An unpaid hold that expires: never counted either.
    await hold(await createUser('customer'), station.pointIds[2], ist(2, 9), 30);

    // Refund one payment in full.
    const refundId = await rpc('service', 'issue_refund', [p1.booking.id, 1200, 'Charger fault refund', `k-${randomUUID()}`]).catch(() => null);
    assert.equal(refundId, null, 'service role is not a staff user; refunds need a finance admin');
    const refunder = await createStaff('admin', { 'finance.refunds.issue': true });
    const rid = await rpc(refunder.id, 'issue_refund', [p1.booking.id, 1200, 'Charger fault refund', `k-${randomUUID()}`]);
    await rpc('service', 'record_refund_result', [rid, `rfnd_${randomUUID().slice(0, 12)}`, p1.pay, 1200, 'processed', null, at(15)]);

    // Expenses: approved, rejected, voided-after-approval, still-submitted.
    const cat = await one(`select id from public.expense_categories where code = 'cloud_hosting'`);
    const e1 = await rpc(recorder.id, 'record_expense', [cat.id, 'Supabase Pro plan', 'Supabase', 200000, day(5), true, 'monthly', 'INV-1']);
    const e2 = await rpc(recorder.id, 'record_expense', [cat.id, 'Duplicate invoice', 'Supabase', 200000, day(5), false, null, null]);
    const e3 = await rpc(recorder.id, 'record_expense', [cat.id, 'Maps credits', 'Google', 50000, day(6), false, null, null]);
    await rpc(recorder.id, 'record_expense', [cat.id, 'Awaiting approval', 'Vendor', 99999, day(7), false, null, null]);
    await rejectsWith(rpc(recorder.id, 'decide_expense', [e1, true, null]), { status: 403 });
    await rpc(finance.id, 'decide_expense', [e1, true, null]);
    await rpc(finance.id, 'decide_expense', [e2, false, 'Duplicate']);
    await rpc(finance.id, 'decide_expense', [e3, true, null]);
    await rpc(finance.id, 'void_expense', [e3, 'Recorded in wrong month']);

    const s = await rpc(finance.id, 'get_financial_summary', [day(1), day(monthEnd)]);
    assert.equal(s.gross_booking_fee_collections_paise, 3600);
    assert.equal(s.successful_payments, 3);
    assert.equal(s.failed_payments, 1);
    assert.equal(s.refunds_paise, 1200);
    assert.equal(s.refund_count, 1);
    assert.equal(s.payment_processing_fees_paise, 28 + 30);
    assert.equal(s.payment_processing_fee_tax_paise, 4 + 5);
    assert.equal(s.net_booking_fee_revenue_paise, 3600 - 1200 - 58);
    assert.equal(s.operating_expenses_paise, 200000);
    assert.equal(s.estimated_operating_profit_paise, 3600 - 1200 - 58 - 200000);
    assert.deepEqual(s.expenses_by_category, [{ category: 'Cloud hosting', amount_paise: 200000 }]);

    // Daily series adds up to the same totals.
    const series = await as(finance.id, (q) => q(`select * from public.get_financial_timeseries($1, $2, 'day')`, [day(1), day(monthEnd)]));
    assert.equal(series.length, monthEnd);
    assert.equal(series.reduce((a, r) => a + r.gross_paise, 0), 3600);
    assert.equal(series.reduce((a, r) => a + r.estimated_profit_paise, 0), s.estimated_operating_profit_paise);
    const monthly = await as(finance.id, (q) => q(`select * from public.get_financial_timeseries($1, $2, 'month')`, [day(1), day(monthEnd)]));
    assert.equal(monthly.length, 1);
    assert.equal(monthly[0].net_revenue_paise, s.net_booking_fee_revenue_paise);
  });

  test('approved expenses cannot be edited; voids post reversals', async () => {
    const cat = await one(`select id from public.expense_categories where code = 'marketing'`);
    const e = await rpc(recorder.id, 'record_expense', [cat.id, 'Flyers', 'Printer', 1000, day(9), false, null, null]);
    await rpc(finance.id, 'decide_expense', [e, true, null]);
    await rejectsWith(rpc(recorder.id, 'update_submitted_expense', [e, cat.id, 'Flyers', 'Printer', 1, day(9), false, null, null]),
      { status: 409, code: 'expense_locked' });
    await rejectsWith(as(finance.id, (q) => q(`update public.platform_expenses set amount_paise = 1 where id = $1`, [e])), { sqlstate: '42501' });
  });

  test('finance data is invisible without finance.read', async () => {
    const admin = await createStaff('admin');
    await rejectsWith(rpc(admin.id, 'get_financial_summary', [day(1), day(monthEnd)]), { status: 403 });
    const rows = await as(admin.id, (q) => q(`select count(*)::int n from public.ledger_entries`));
    assert.equal(rows[0].n, 0);
    const pay = await as(admin.id, (q) => q(`select count(*)::int n from public.payments`));
    assert.equal(pay[0].n, 0);
    const dash = await rpc(admin.id, 'get_admin_dashboard', [day(1), day(monthEnd), null, null, null, null]);
    assert.equal(dash.finance, null);
    const owner = station.owner;
    await rejectsWith(rpc(owner.id, 'get_financial_summary', [day(1), day(monthEnd)]), { status: 403 });
  });

  test('business reports never include charging revenue', async () => {
    const report = await rpc(station.owner.id, 'get_business_report', [station.businessId, day(1), day(monthEnd), null]);
    const text = JSON.stringify(report);
    assert.ok(!/revenue_paise|amount_paise|fee_paise/.test(text));
    assert.ok(report.notes.some((n) => /not recorded by the platform/.test(n)));
  });

  test('the commission setting exists, is off, and is not exposed to businesses', async () => {
    const s = await one(`select value from public.platform_settings where key = 'business_commission_enabled'`);
    assert.equal(s.value, false);
    const seen = await as(station.owner.id, (q) => q(`select key from public.platform_settings`));
    assert.ok(!seen.some((r) => r.key === 'business_commission_enabled'));
    assert.ok(seen.some((r) => r.key === 'booking_fee_paise'));
  });
});
