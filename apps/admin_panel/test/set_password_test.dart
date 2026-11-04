import 'package:admin_panel/pages/set_password_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeAuth extends AuthRepository {
  _FakeAuth(super.client);
  final saved = <String>[];
  @override
  Future<void> updatePassword(String password) async => saved.add(password);
}

void main() {
  // Made outside the test's fake clock so its refresh timer is not counted.
  final client = SupabaseClient('http://localhost', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false));
  tearDownAll(client.dispose);
  testWidgets('new password must be valid and typed twice; saving goes home', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final auth = _FakeAuth(client);
    var done = false;
    final router = GoRouter(initialLocation: '/set-password', routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('home page')),
      GoRoute(path: '/set-password', builder: (_, _) => SetPasswordPage(fromResetLink: true, onDone: () => done = true)),
    ]);
    await t.pumpWidget(ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
      child: MaterialApp.router(routerConfig: router),
    ));
    await t.pumpAndSettle();
    expect(find.text('Choose a new password'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget, reason: 'a reset link cannot be skipped');

    await t.enterText(find.widgetWithText(TextFormField, 'New password'), 'Charge#Karo2026');
    await t.enterText(find.widgetWithText(TextFormField, 'Confirm new password'), 'Charge#Karo2027');
    await t.tap(find.text('Save password'));
    await t.pumpAndSettle();
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(auth.saved, isEmpty);

    await t.enterText(find.widgetWithText(TextFormField, 'Confirm new password'), 'Charge#Karo2026');
    await t.tap(find.text('Save password'));
    await t.pumpAndSettle();
    expect(auth.saved, ['Charge#Karo2026']);
    expect(done, isTrue);
    expect(find.text('home page'), findsOneWidget);
    await t.pump(const Duration(seconds: 6)); // let the snackbar time out
  });
}
