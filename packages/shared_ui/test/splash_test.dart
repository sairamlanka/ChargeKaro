import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/shared_ui.dart';

const _home = MaterialApp(home: Text('home'));

void main() {
  testWidgets('logo stays for 3 seconds even when startup is instant', (tester) async {
    await tester.pumpWidget(SplashGate(load: () async => _home, shown: Future.value()));
    expect(find.byType(LogoSplash), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.text('home'), findsNothing);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.byType(LogoSplash), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('logo stays until slow startup finishes', (tester) async {
    final loaded = Completer<Widget>();
    await tester.pumpWidget(SplashGate(load: () => loaded.future, shown: Future.value()));

    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(LogoSplash), findsOneWidget);

    loaded.complete(_home);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a failed startup shows the error and can retry', (tester) async {
    var calls = 0;
    await tester.pumpWidget(SplashGate(load: () async {
      if (++calls == 1) throw StateError('no network');
      return _home;
    }, shown: Future.value()));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isA<StateError>());
    expect(find.text('ChargeKaro could not start'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('3 seconds count from when the logo is shown, not from startup', (tester) async {
    final shown = Completer<void>();
    await tester.pumpWidget(SplashGate(load: () async => _home, shown: shown.future));

    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(LogoSplash), findsOneWidget);

    shown.complete();
    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.text('home'), findsNothing);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('logo asset is bundled', (tester) async {
    await tester.pumpWidget(const LogoSplash());
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).keyName, 'packages/shared_ui/assets/chargekaro_logo.jpg');
    expect(tester.takeException(), isNull);
  });
}
