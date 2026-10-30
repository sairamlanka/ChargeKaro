import 'package:flutter/material.dart';

/// How long the logo stays on screen when an app opens.
const splashDuration = Duration(seconds: 3);

/// Full-screen ChargeKaro logo on white, shown while an app starts.
///
/// Works without a [MaterialApp] above it so it can be the very first frame.
class LogoSplash extends StatelessWidget {
  const LogoSplash({super.key});

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: Colors.white,
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.8,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Image.asset(
                  'assets/chargekaro_logo.jpg',
                  package: 'shared_ui',
                  semanticLabel: 'ChargeKaro. Find, book, charge.',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
      );
}

/// Shows [LogoSplash] until [minDuration] has passed and [load] has finished,
/// then fades to the widget [load] returns. Startup work runs behind the logo,
/// so the wait is never longer than the slower of the two.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.load, this.minDuration = splashDuration});

  final Future<Widget> Function() load;
  final Duration minDuration;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  Widget? _app;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final results = await Future.wait([widget.load(), Future<Object?>.delayed(widget.minDuration)]);
    if (mounted) setState(() => _app = results.first as Widget);
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _app ?? const LogoSplash(),
        ),
      );
}
