import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/shared_ui.dart';

const _home = MaterialApp(home: Text('home'));

void main() {
  testWidgets('logo stays for 3 seconds even when startup is instant', (tester) async {
    await tester.pumpWidget(SplashGate(load: () async => _home));
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
    await tester.pumpWidget(SplashGate(load: () => loaded.future));

    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(LogoSplash), findsOneWidget);

    loaded.complete(_home);
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
