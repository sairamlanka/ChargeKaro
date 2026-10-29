import 'package:admin_panel/export/csv.dart';
import 'package:admin_panel/pages/finance_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';

class _Repo extends Mock implements FinanceRepository {}

final _summary = FinancialSummary.fromJson({
  'gross_booking_fee_collections_paise': 3600,
  'successful_payments': 3,
  'failed_payments': 1,
  'refunds_paise': 1200,
  'refund_count': 1,
  'pending_refunds_paise': 0,
  'payment_processing_fees_paise': 58,
  'payment_processing_fee_tax_paise': 9,
  'net_booking_fee_revenue_paise': 2342,
  'operating_expenses_paise': 200000,
  'estimated_operating_profit_paise': 2342 - 200000,
  'expenses_by_category': [
    {'category': 'Cloud hosting', 'amount_paise': 200000},
  ],
});

Map<String, Object?> _booking(String ref, {int refunds = 0}) => {
      'booking_id': 'b-$ref',
      'reference': ref,
      'station_id': 's1',
      'station_name': 'MG Road Hub',
      'city': 'Bengaluru',
      'business_name': 'Volt Co',
      'customer_display_name': 'Asha K.',
      'slot_start': '2026-10-20T04:30:00Z',
      'slot_end': '2026-10-20T05:00:00Z',
      'status': 'completed',
      'payment_status': refunds > 0 ? 'refunded' : 'paid',
      'paid_at': '2026-10-19T10:00:00Z',
      'gross_paise': 1200,
      'refunds_paise': refunds,
      'fees_paise': 28,
      'net_paise': 1200 - refunds - 28,
    };

void main() {
  late _Repo repo;

  setUp(() {
    repo = _Repo();
    when(() => repo.summary(any(), any())).thenAnswer((_) async => _summary);
    when(() => repo.timeseries(any(), any(), bucket: any(named: 'bucket'))).thenAnswer((_) async => [
          for (var d = 1; d <= 3; d++)
            FinancialPoint.fromJson({
              'bucket_start': '2026-10-0$d',
              'gross_paise': 1200,
              'refunds_paise': d == 1 ? 1200 : 0,
              'processing_fees_paise': 20,
              'operating_expenses_paise': d == 2 ? 200000 : 0,
              'net_revenue_paise': d == 1 ? -20 : 1180,
              'estimated_profit_paise': d == 1 ? -20 : (d == 2 ? 1180 - 200000 : 1180),
            }),
        ]);
    when(() => repo.revenueByStation(any(), any())).thenAnswer((_) async => [
          StationRevenue.fromJson({
            'station_id': 's1',
            'station_name': 'MG Road Hub',
            'city': 'Bengaluru',
            'business_name': 'Volt Co',
            'is_demo': false,
            'paid_bookings': 3,
            'gross_paise': 3600,
            'refunds_paise': 1200,
            'fees_paise': 58,
            'net_paise': 2342,
          }),
        ]);
    when(() => repo.bookingRevenue(any(), any(),
        stationId: any(named: 'stationId'), search: any(named: 'search'), limit: any(named: 'limit'), offset: any(named: 'offset'))).thenAnswer(
      (_) async => BookingRevenueReport.fromJson({
        'total_count': 2,
        'totals': {'paid_bookings': 2, 'gross_paise': 2400, 'refunds_paise': 1200, 'fees_paise': 56, 'net_paise': 1144},
        'rows': [_booking('CKAAAA1111'), _booking('CKBBBB2222', refunds: 1200)],
      }),
    );
    when(() => repo.expenses(from: any(named: 'from'), to: any(named: 'to'))).thenAnswer((_) async => [
          Expense.fromJson({
            'id': 'e1',
            'category_id': 'c1',
            'expense_categories': {'name': 'Cloud hosting'},
            'description': 'Supabase Pro plan',
            'vendor': 'Supabase',
            'amount_paise': 200000,
            'expense_date': '2026-10-02',
            'is_recurring': true,
            'recurrence': 'monthly',
            'status': 'approved',
            'recorded_by': 'u1',
            'created_at': '2026-10-02T05:00:00Z',
          }),
          Expense.fromJson({
            'id': 'e2',
            'category_id': 'c1',
            'expense_categories': {'name': 'Cloud hosting'},
            'description': 'Extra storage',
            'amount_paise': 50000,
            'expense_date': '2026-10-03',
            'is_recurring': false,
            'status': 'submitted',
            'recorded_by': 'u2',
            'created_at': '2026-10-03T05:00:00Z',
          }),
        ]);
    when(() => repo.categories()).thenAnswer((_) async => [
          ExpenseCategory.fromJson({'id': 'c1', 'code': 'cloud_hosting', 'name': 'Cloud hosting'}),
        ]);
    when(() => repo.payments()).thenAnswer((_) async => []);
    when(() => repo.refunds()).thenAnswer((_) async => []);
  });

  Future<void> pump(WidgetTester tester, Set<String> permissions) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        financeRepositoryProvider.overrideWithValue(repo),
        platformAccessProvider.overrideWith((_) async => PlatformAccess(isStaff: true, role: PlatformRole.admin, permissions: permissions)),
      ],
      child: const MaterialApp(home: Scaffold(body: FinancePage())),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('overview shows revenue, expenses, profit and top stations', (tester) async {
    await pump(tester, {PlatformPermission.financeRead});
    for (final tab in FinancePage.tabs) {
      expect(find.widgetWithText(Tab, tab), findsOneWidget);
    }
    expect(find.text('Revenue vs expenses'), findsOneWidget);
    expect(find.text('Top stations by revenue'), findsOneWidget);
    expect(find.text('MG Road Hub'), findsOneWidget);
    expect(find.text('Profit and loss'), findsOneWidget);
    expect(find.text('-₹1,976.58'), findsWidgets, reason: 'estimated profit is a loss');
  });

  testWidgets('booking revenue lists who paid at which station', (tester) async {
    await pump(tester, {PlatformPermission.financeRead});
    await tester.tap(find.widgetWithText(Tab, 'Booking revenue'));
    await tester.pumpAndSettle();
    expect(find.text('Revenue by station'), findsOneWidget);
    expect(find.text('CKAAAA1111'), findsOneWidget);
    expect(find.text('CKBBBB2222'), findsOneWidget);
    expect(find.text('2 bookings'), findsOneWidget);
    expect(find.text('Export CSV'), findsOneWidget);
  });

  testWidgets('expenses: approvers can approve and manage categories; readers cannot', (tester) async {
    await pump(tester, {PlatformPermission.financeRead});
    await tester.tap(find.widgetWithText(Tab, 'Expenses'));
    await tester.pumpAndSettle();
    expect(find.text('Supabase Pro plan'), findsOneWidget);
    expect(find.text('Record expense'), findsNothing);
    expect(find.byTooltip('Approve'), findsNothing);
    expect(find.text('Categories'), findsNothing);
  });

  testWidgets('expenses: writer can edit an expense awaiting approval', (tester) async {
    await pump(tester, {PlatformPermission.financeRead, PlatformPermission.financeExpensesWrite, PlatformPermission.financeExpensesApprove});
    await tester.tap(find.widgetWithText(Tab, 'Expenses'));
    await tester.pumpAndSettle();
    expect(find.text('Record expense'), findsOneWidget);
    expect(find.text('Categories'), findsOneWidget);
    expect(find.byTooltip('Approve'), findsOneWidget);
    expect(find.byTooltip('Void (posts a reversal)'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit expense'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Extra storage'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '500.00'), findsOneWidget);
  });

  testWidgets('reports show profit over time and the P&L table', (tester) async {
    await pump(tester, {PlatformPermission.financeRead});
    await tester.tap(find.widgetWithText(Tab, 'Reports'));
    await tester.pumpAndSettle();
    expect(find.text('Profit over time'), findsOneWidget);
    expect(find.text('Profit & loss CSV'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget, reason: 'one profitable day');
    expect(find.text('Total'), findsOneWidget);
  });

  group('CSV export', () {
    test('quotes, escapes and neutralises formulas', () {
      expect(toCsv([
        ['a,b', 'say "hi"', '=SUM(A1)', null, const Money(123456)],
      ]), '"a,b","say ""hi""",\'=SUM(A1),,1234.56');
    });

    test('booking revenue rows', () {
      final csv = bookingRevenueCsv([BookingRevenueRow.fromJson(_booking('CKAAAA1111', refunds: 1200))]);
      final lines = csv.split('\r\n');
      expect(lines, hasLength(2));
      expect(lines[1], startsWith('CKAAAA1111,Asha K.,MG Road Hub,Bengaluru,Volt Co,'));
      expect(lines[1], endsWith(',Completed,Refunded,12.00,12.00,0.28,-0.28'));
    });
  });
}
