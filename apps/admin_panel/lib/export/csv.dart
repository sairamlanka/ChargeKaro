import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

/// RFC 4180 CSV. Cells that could be read as a formula by a spreadsheet are
/// prefixed with an apostrophe so exported text can never execute.
String toCsv(List<List<Object?>> rows) => rows.map((r) => r.map(_cell).join(',')).join('\r\n');

String _cell(Object? v) {
  var s = switch (v) {
    null => '',
    Money m => (m.paise / 100).toStringAsFixed(2),
    DateTime d => d.toIso8601String(),
    _ => v.toString(),
  };
  if (v is String && s.isNotEmpty && '=+-@\t\r'.contains(s[0])) s = "'$s";
  return RegExp(r'[",\r\n]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Profit and loss per period, amounts in rupees.
String profitAndLossCsv(List<FinancialPoint> points) => toCsv([
      ['Period start', 'Collected (INR)', 'Refunds (INR)', 'Gateway fees (INR)', 'Net revenue (INR)', 'Expenses (INR)', 'Estimated profit (INR)'],
      for (final p in points)
        [_date(p.bucketStart), p.gross, p.refunds, p.processingFees, p.netRevenue, p.operatingExpenses, p.estimatedProfit],
    ]);

String bookingRevenueCsv(List<BookingRevenueRow> rows) => toCsv([
      ['Booking', 'Customer', 'Station', 'City', 'Business', 'Slot (IST)', 'Paid at (IST)', 'Booking status', 'Fee status',
        'Collected (INR)', 'Refunded (INR)', 'Gateway fees (INR)', 'Net (INR)'],
      for (final r in rows)
        [
          r.reference, r.customerName, r.stationName, r.city, r.businessName, Fmt.slot(r.slotStart, r.slotEnd),
          r.paidAt == null ? null : Fmt.dateTime(r.paidAt!), r.status.label, r.paymentStatus.label,
          r.gross, r.refunds, r.fees, r.net,
        ],
    ]);

String expensesCsv(List<Expense> list) => toCsv([
      ['Date', 'Category', 'Description', 'Vendor', 'Invoice', 'Amount (INR)', 'Status', 'Recurring', 'Note'],
      for (final e in list)
        [
          _date(e.expenseDate), e.categoryName, e.description, e.vendor, e.invoiceNumber, e.amount, e.status.label,
          e.isRecurring ? (e.recurrence ?? 'yes') : '', e.voidReason ?? e.decisionNote,
        ],
    ]);
