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

/// Shows [LogoSplash] until the logo has been on screen for [minDuration] and
/// [load] has finished, then fades to the widget [load] returns. Startup work
/// runs behind the logo, so the wait is never longer than the slower of the two.
/// If [load] fails, shows the error with a retry button instead of hanging.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.load, this.minDuration = splashDuration, this.shown});

  final Future<Widget> Function() load;
  final Duration minDuration;

  /// Completes once the logo is actually on screen; [minDuration] counts from
  /// then. Defaults to the first rasterized frame (widget tests never report
  /// one, so they pass their own).
  final Future<void>? shown;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  Widget? _app;
  Object? _error;
  late final Future<void> _logoShown;

  @override
  void initState() {
    super.initState();
    // Count from the first rasterized frame, not from main() or the first built
    // frame: on slow devices the frame reaches the screen seconds after it is
    // built, which would otherwise eat the logo's time.
    final shown = widget.shown ?? WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    _logoShown = shown.then((_) => Future<void>.delayed(widget.minDuration));
    _start();
  }

  Future<void> _start() async {
    try {
      final app = await widget.load();
      await _logoShown;
      if (mounted) setState(() => _app = app);
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: st, library: 'shared_ui', context: ErrorDescription('while starting the app')));
      await _logoShown;
      if (mounted) setState(() => _error = e);
    }
  }

  void _retry() {
    setState(() => _error = null);
    _start();
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _app ?? (_error != null ? _StartupFailed(error: _error!, onRetry: _retry) : const LogoSplash()),
        ),
      );
}

class _StartupFailed extends StatelessWidget {
  const _StartupFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('ChargeKaro could not start', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  Text('$error', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: onRetry, child: const Text('Try again')),
                ],
              ),
            ),
          ),
        ),
      );
}
