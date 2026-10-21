import 'package:admin_panel/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';

Future<void> _pumpShell(WidgetTester tester, PlatformAccess access) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      platformAccessProvider.overrideWith((_) async => access),
      unreadNotificationsProvider.overrideWith((_) async => 0),
    ],
    child: const MaterialApp(home: AdminShell(location: '/', child: Text('page body'))),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('compliance reviewer sees review screens but not finance or admin management', (tester) async {
    await _pumpShell(
      tester,
      const PlatformAccess(isStaff: true, role: PlatformRole.complianceReviewer, permissions: {
        PlatformPermission.applicationsReview,
        PlatformPermission.businessesRead,
      }),
    );
    expect(find.text('Applications'), findsOneWidget);
    expect(find.text('Stations'), findsOneWidget);
    expect(find.text('Finance'), findsNothing);
    expect(find.text('Admins'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('page body'), findsOneWidget);
  });

  testWidgets('super admin sees every section', (tester) async {
    await _pumpShell(tester, const PlatformAccess(isStaff: true, role: PlatformRole.superAdmin));
    for (final label in ['Dashboard', 'Applications', 'Stations', 'Bookings', 'Finance', 'Admins', 'Settings', 'Audit log']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('a signed-in user who is not platform staff gets no navigation', (tester) async {
    await _pumpShell(tester, PlatformAccess.none);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('page body'), findsNothing);
    expect(find.text('Sign out'), findsOneWidget);
  });
}
