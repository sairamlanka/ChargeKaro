import { test, describe, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { rpc, one, as, rejectsWith, closePool, createUser, createStaff, approvedStation, hold, setFee, ist } from './lib/db.mjs';

after(async () => {
  await setFee(0);
  await closePool();
});
before(() => setFee(1200));

// A random historical month keeps totals isolated from other tests and runs.
const year = 1960 + Math.floor(Math.random() * 25);
const month = 1 + Math.floor(Math.random() * 12);
const pad = (n) => String(n).padStart(2, '0');
const day = (d) => `${year}-${pad(month)}-${pad(d)}`;
const at = (d, hh = 12) => new Date(`${day(d)}T${pad(hh)}:00:00+05:30`).toISOString();
const monthEnd = new Date(Date.UTC(year, month, 0)).getUTCDate();

let slot = 0;
async function paidBooking(station, { capturedOn, fee = 28, tax = 4, customer }) {
  customer ??= await createUser('customer');
  slot += 1;
  const b = await hold(customer, station.pointIds[0], ist(1, 4 + (slot % 18), (slot % 2) * 30), 30);
  const order = `order_${randomUUID().slice(0, 18)}`;
  await rpc('service', 'record_payment_order', [b.id, order, 1200, 'INR', b.reference]);
  const pay = `pay_${randomUUID().slice(0, 18)}`;
  await rpc('service', 'record_gateway_payment', [order, pay, 1200, 'INR', 'captured', 'upi', fee, tax, null, null, capturedOn]);
  return { booking: b, pay };
}

describe('finance reports', () => {
  let a;
  let b;
  let finance;
  let first;

  before(async () => {
    a = await approvedStation({ points: ['A1'] });
    b = await approvedStation({ points: ['B1'] });
    finance = await createStaff('admin', { 'finance.read': true, 'finance.expenses.approve': true, 'finance.refunds.issue': true });
    first = await paidBooking(a, { capturedOn: at(2) });
    await paidBooking(a, { capturedOn: at(9), fee: 30, tax: 5 });
    await paidBooking(b, { capturedOn: at(15), fee: null, tax: null });
    // Refund the first booking in full.
    const rid = await rpc(finance.id, 'issue_refund', [first.booking.id, 1200, 'Station cancelled', `k-${randomUUID()}`]);
    await rpc('service', 'record_refund_result', [rid, `rfnd_${randomUUID().slice(0, 12)}`, first.pay, 1200, 'processed', null, at(16)]);
  });

  test('per-booking and per-station revenue reconcile with the summary', async () => {
    const summary = await rpc(finance.id, 'get_financial_summary', [day(1), day(monthEnd)]);
    const report = await rpc(finance.id, 'get_booking_revenue', [day(1), day(monthEnd), null, null, 50, 0]);
    assert.equal(report.total_count, 3);
    assert.equal(report.totals.paid_bookings, 3);
    assert.equal(report.totals.gross_paise, summary.gross_booking_fee_collections_paise);
    assert.equal(report.totals.refunds_paise, summary.refunds_paise);
    assert.equal(report.totals.fees_paise, summary.payment_processing_fees_paise);
    assert.equal(report.totals.net_paise, summary.net_booking_fee_revenue_paise);

    // Newest payment first; the refunded booking nets out its gateway fee.
    assert.equal(report.rows[0].station_id, b.stationId);
    const refunded = report.rows.find((r) => r.booking_id === first.booking.id);
    assert.equal(refunded.reference, first.booking.reference);
    assert.equal(refunded.gross_paise, 1200);
    assert.equal(refunded.refunds_paise, 1200);
    assert.equal(refunded.fees_paise, 28, "fee_paise already includes tax");
    assert.equal(refunded.net_paise, -28);
    assert.equal(refunded.payment_status, 'refunded');
    assert.ok(refunded.customer_display_name.length > 0);
    assert.ok(refunded.slot_start && refunded.paid_at);

    const stations = await rpc(finance.id, 'get_revenue_by_station', [day(1), day(monthEnd)]);
    assert.equal(stations.length, 2);
    assert.equal(stations[0].station_id, b.stationId, 'best earner first');
    assert.deepEqual(
      stations.map((s) => [s.paid_bookings, s.gross_paise, s.refunds_paise, s.fees_paise, s.net_paise]),
      [[1, 1200, 0, 0, 1200], [2, 2400, 1200, 58, 1142]],
    );
    assert.equal(stations.reduce((t, s) => t + s.net_paise, 0), summary.net_booking_fee_revenue_paise);
  });

  test('filters by station, search text and page', async () => {
    const onlyA = await rpc(finance.id, 'get_booking_revenue', [day(1), day(monthEnd), a.stationId, null, 50, 0]);
    assert.equal(onlyA.total_count, 2);
    assert.ok(onlyA.rows.every((r) => r.station_id === a.stationId));
    const byRef = await rpc(finance.id, 'get_booking_revenue', [day(1), day(monthEnd), null, first.booking.reference.slice(2, 8), 50, 0]);
    assert.equal(byRef.total_count, 1);
    const page = await rpc(finance.id, 'get_booking_revenue', [day(1), day(monthEnd), null, null, 1, 1]);
    assert.equal(page.total_count, 3);
    assert.equal(page.rows.length, 1);
    assert.equal(page.totals.gross_paise, 3600, 'totals cover the whole filter, not one page');
    // Wildcards in the search are treated as text, not patterns.
    const wild = await rpc(finance.id, 'get_booking_revenue', [day(1), day(monthEnd), null, '%', 50, 0]);
    assert.equal(wild.total_count, 3);
    await rejectsWith(rpc(finance.id, 'get_booking_revenue', [day(2), day(1), null, null, 50, 0]), { status: 422, code: 'invalid_range' });
    await rejectsWith(rpc(finance.id, 'get_booking_revenue', [day(1), day(2), null, null, 0, 0]), { status: 422, code: 'invalid_page' });
  });

  test('a period with no money is empty, not an error', async () => {
    const report = await rpc(finance.id, 'get_booking_revenue', ['1950-01-01', '1950-01-31', null, null, 50, 0]);
    assert.equal(report.total_count, 0);
    assert.deepEqual(report.rows, []);
    assert.equal(report.totals.net_paise, 0);
    assert.deepEqual(await rpc(finance.id, 'get_revenue_by_station', ['1950-01-01', '1950-01-31']), []);
  });

  test('revenue reports need finance.read', async () => {
    const admin = await createStaff('admin');
    await rejectsWith(rpc(admin.id, 'get_booking_revenue', [day(1), day(monthEnd), null, null, 50, 0]), { status: 403 });
    await rejectsWith(rpc(admin.id, 'get_revenue_by_station', [day(1), day(monthEnd)]), { status: 403 });
    await rejectsWith(rpc(a.owner.id, 'get_revenue_by_station', [day(1), day(monthEnd)]), { status: 403 });
    await rejectsWith(rpc('anon', 'get_revenue_by_station', [day(1), day(monthEnd)]), { sqlstate: '42501' });
  });
});

describe('expense categories', () => {
  test('finance approvers create, rename and archive categories', async () => {
    const approver = await createStaff('admin', { 'finance.read': true, 'finance.expenses.approve': true });
    const name = `Electricity ${randomUUID().slice(0, 6)}`;
    const id = await rpc(approver.id, 'save_expense_category', [null, `  ${name} `, true]);
    let row = await one(`select code, name, is_active from public.expense_categories where id = $1`, [id]);
    assert.equal(row.name, name);
    assert.match(row.code, /^electricity_[a-z0-9_]+$/);
    assert.equal(row.is_active, true);

    await rejectsWith(rpc(approver.id, 'save_expense_category', [null, name.toUpperCase(), true]), { status: 409, code: 'category_exists' });
    await rejectsWith(rpc(approver.id, 'save_expense_category', [null, 'x', true]), { status: 422, code: 'invalid_category_name' });

    await rpc(approver.id, 'save_expense_category', [id, `${name} bills`, false]);
    row = await one(`select code, name, is_active from public.expense_categories where id = $1`, [id]);
    assert.equal(row.name, `${name} bills`);
    assert.equal(row.is_active, false);
    assert.match(row.code, /^electricity_/, 'the code never changes');

    const audit = await one(`select count(*)::int n from public.audit_logs where entity_type = 'expense_categories' and entity_id = $1`, [id]);
    assert.equal(audit.n, 2);
    await rejectsWith(rpc(approver.id, 'save_expense_category', [randomUUID(), 'Missing one', true]), { status: 404 });
  });

  test('recorders and other staff cannot change categories', async () => {
    const recorder = await createStaff('admin', { 'finance.read': true, 'finance.expenses.write': true });
    await rejectsWith(rpc(recorder.id, 'save_expense_category', [null, 'Should fail', true]), { status: 403 });
    const owner = await createUser('owner');
    await rejectsWith(rpc(owner.id, 'save_expense_category', [null, 'Should fail', true]), { status: 403 });
    await rejectsWith(as(recorder.id, (q) => q(`insert into public.expense_categories (code, name) values ('nope', 'Nope')`)), { sqlstate: '42501' });
  });
});
