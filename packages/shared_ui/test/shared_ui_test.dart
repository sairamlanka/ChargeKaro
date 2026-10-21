import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

Widget _app(Widget child) => MaterialApp(theme: AppTheme.light(), home: Scaffold(body: child));

void main() {
  test('IST formatting is independent of the device zone', () {
    final utc = DateTime.utc(2026, 3, 1, 18, 45); // 00:15 IST next day
    expect(Fmt.date(utc), '2 Mar 2026');
    expect(Fmt.time(utc), '12:15 AM');
    expect(Fmt.fromIst(2026, 3, 2, 0, 15), utc);
    expect(Fmt.fileSize(1536), '2 KB');
  });

  testWidgets('status chips always carry text', (tester) async {
    await tester.pumpWidget(_app(Column(children: [
      StatusChip.booking(BookingStatus.noShow),
      StatusChip.application(ApplicationStatus.additionalInformationRequired),
      StatusChip.point(PointStatus.maintenance),
    ])));
    expect(find.text('No-show'), findsOneWidget);
    expect(find.text('Information requested'), findsOneWidget);
    expect(find.text('Maintenance'), findsOneWidget);
  });

  testWidgets('reason dialog requires a reason before confirming', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(_app(Builder(
      builder: (context) => TextButton(
        onPressed: () async => result = await confirmWithReason(context,
            title: 'Suspend station', message: 'Bookings will stop.', confirmLabel: 'Suspend', reasonLabel: 'Reason'),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final button = find.widgetWithText(FilledButton, 'Suspend');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Safety inspection failed');
    await tester.pump();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(result, 'Safety inspection failed');
  });

  testWidgets('money text marks negatives', (tester) async {
    await tester.pumpWidget(_app(const MoneyText(Money(-1200))));
    expect(find.textContaining('12.00'), findsOneWidget);
  });
}
