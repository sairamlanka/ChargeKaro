import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui/shared_ui.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  testWidgets('count-up always lands on the exact figure', (tester) async {
    await tester.pumpWidget(_app(const CountUp(1234)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('1234'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('1234'), findsOneWidget);
  });

  testWidgets('count-up shows the final figure immediately with reduced motion', (tester) async {
    await tester.pumpWidget(_app(const CountUp(42), reduced: true));
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('entrance reveals its child and leaves no pending work', (tester) async {
    await tester.pumpWidget(_app(const Entrance(index: 3, child: Text('hello'))));
    final opacity = tester.widget<Opacity>(find.ancestor(of: find.text('hello'), matching: find.byType(Opacity)).first);
    expect(opacity.opacity, 0);
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(find.ancestor(of: find.text('hello'), matching: find.byType(Opacity)).first).opacity, 1);
    await tester.pumpWidget(const SizedBox()); // disposing mid-way must not leave timers behind
  });

  testWidgets('gradient button ignores taps while busy or disabled', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(GradientButton(label: 'Go', busy: true, onPressed: () => taps++), reduced: true));
    await tester.tap(find.byType(GradientButton));
    await tester.pumpWidget(_app(GradientButton(label: 'Go', onPressed: () => taps++), reduced: true));
    await tester.tap(find.text('Go'));
    expect(taps, 1);
  });

  testWidgets('fade indexed stack keeps every tab mounted', (tester) async {
    Widget stack(int i) => _app(FadeIndexedStack(index: i, children: const [_Counter(key: ValueKey('a')), Text('b')]), reduced: true);
    await tester.pumpWidget(stack(0));
    await tester.tap(find.text('0'));
    await tester.pump();
    await tester.pumpWidget(stack(1));
    await tester.pumpWidget(stack(0));
    expect(find.text('1'), findsOneWidget); // state survived the switch
  });
}

class _Counter extends StatefulWidget {
  const _Counter({super.key});
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;
  @override
  Widget build(BuildContext context) => TextButton(onPressed: () => setState(() => n++), child: Text('$n'));
}
