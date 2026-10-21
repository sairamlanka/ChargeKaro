import 'package:business_app/pages/auth/auth_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_data/shared_data.dart';

class _MockAuth extends Mock implements AuthRepository {}

Widget _app(AuthRepository auth) {
  final router = GoRouter(initialLocation: '/login', routes: [
    GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
    GoRoute(path: '/forgot', builder: (_, _) => const Text('forgot screen')),
    GoRoute(path: '/register', builder: (_, _) => const Text('register screen')),
    GoRoute(path: '/verify', builder: (_, s) => Text('verify ${s.uri.queryParameters['email']}')),
  ]);
  return ProviderScope(
    overrides: [authRepositoryProvider.overrideWithValue(auth)],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  late _MockAuth auth;
  setUp(() => auth = _MockAuth());

  testWidgets('blocks submission until email and password are valid', (tester) async {
    await tester.pumpWidget(_app(auth));
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.text('Enter your password'), findsOneWidget);
    verifyNever(() => auth.signIn(any(), any()));

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'not-an-email');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'x');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    verifyNever(() => auth.signIn(any(), any()));
  });

  testWidgets('signs in with the entered credentials', (tester) async {
    when(() => auth.signIn(any(), any())).thenAnswer((_) async {});
    await tester.pumpWidget(_app(auth));

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'owner@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'Secret#123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    verify(() => auth.signIn('owner@example.com', 'Secret#123')).called(1);
  });

  testWidgets('shows the plain-language failure message', (tester) async {
    when(() => auth.signIn(any(), any())).thenThrow(
      const AppFailure(FailureKind.unauthenticated, 'invalid_credentials', 'Email or password is incorrect.'),
    );
    await tester.pumpWidget(_app(auth));

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'owner@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Email or password is incorrect.'), findsOneWidget);
  });

  testWidgets('unconfirmed email routes to verification', (tester) async {
    when(() => auth.signIn(any(), any())).thenThrow(
      const AppFailure(FailureKind.unauthenticated, 'email_not_confirmed', 'Please confirm your email first.'),
    );
    await tester.pumpWidget(_app(auth));

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'new@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'Secret#123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('verify new@example.com'), findsOneWidget);
  });
}
