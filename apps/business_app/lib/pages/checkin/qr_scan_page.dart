import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../checkin/checkin_state.dart';
import '../../state.dart';
import 'checkin_widgets.dart';
import 'confirm_arrival_page.dart';
import 'manual_checkin_page.dart';
import 'offline_checkin_page.dart';

/// QR check-in. The QR holds an opaque token only; the server validates it
/// for this station and returns limited booking data. Nothing is checked in
/// until staff confirm on the next screen.
class QrScanPage extends ConsumerStatefulWidget {
  const QrScanPage({super.key});

  @override
  ConsumerState<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends ConsumerState<QrScanPage> with WidgetsBindingObserver {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _busy = false;
  CheckinResult? _rejection;
  String? _networkError;
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanner.dispose();
    super.dispose();
  }

  // Release the camera while the app is in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && !_busy) {
      _scanner.start();
    } else if (s == AppLifecycleState.paused || s == AppLifecycleState.inactive) {
      _scanner.stop();
    }
  }

  Future<void> _handle(String raw) async {
    if (_busy) return;
    final station = ref.read(currentStationProvider);
    if (station == null) return;
    final payload = raw.trim();
    setState(() {
      _busy = true;
      _rejection = null;
      _networkError = null;
    });
    await _scanner.stop();
    var restart = false;
    try {
      if (!BookingCode.isQrPayload(payload)) {
        _failures++;
        setState(() => _rejection = const CheckinResult(result: 'rejected', code: 'invalid_qr', message: 'This is not a ChargeKaro booking QR code.'));
        return;
      }
      final device = await ref.read(deviceIdProvider.future);
      final v = await ref.read(bookingRepositoryProvider).verifyQr(station.id, payload, deviceId: device);
      if (!mounted) return;
      if (v.rejected || v.booking == null) {
        _failures++;
        setState(() => _rejection = v);
        return;
      }
      _failures = 0;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ConfirmArrivalPage(stationId: station.id, preview: v, method: CheckinMethod.qr, qrPayload: payload),
      ));
      restart = true;
    } on AppFailure catch (f) {
      setState(() => _networkError = f.kind == FailureKind.network ? 'No connection. Use offline check-in, or try again.' : f.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        // After a rejection the camera stays paused until "Scan again", so
        // the same bad code is not read over and over.
        if (restart) await _scanner.start();
      }
    }
  }

  Future<void> _scanAgain() async {
    setState(() {
      _rejection = null;
      _networkError = null;
    });
    await _scanner.start();
  }

  void _open(Widget page) => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final station = ref.watch(currentStationProvider);
    final online = ref.watch(onlineProvider).value ?? true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR'),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _scanner,
            builder: (context, s, _) => s.torchState == TorchState.unavailable
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: s.torchState == TorchState.on ? 'Turn flashlight off' : 'Turn flashlight on',
                    icon: Icon(s.torchState == TorchState.on ? Icons.flash_on_rounded : Icons.flash_off_rounded),
                    onPressed: _scanner.toggleTorch,
                  ),
          ),
        ],
      ),
      body: station == null
          ? const EmptyState(icon: Icons.ev_station_outlined, title: 'No station selected')
          : Column(children: [
              if (!online) const OfflineBanner(),
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  MobileScanner(
                    controller: _scanner,
                    onDetect: (capture) {
                      final value = capture.barcodes.firstOrNull?.rawValue;
                      if (value != null) _handle(value);
                    },
                    errorBuilder: (context, error) => EmptyState(
                      icon: Icons.no_photography_outlined,
                      title: error.errorCode == MobileScannerErrorCode.permissionDenied ? 'Camera permission needed' : 'Camera unavailable',
                      message: error.errorCode == MobileScannerErrorCode.permissionDenied
                          ? 'Allow camera access in Settings, or use manual check-in.'
                          : 'The camera could not start. Use manual check-in instead.',
                      action: FilledButton.icon(
                        icon: const Icon(Icons.keyboard_rounded),
                        label: const Text('Manual check-in'),
                        onPressed: () => _open(const ManualCheckinPage()),
                      ),
                    ),
                  ),
                  _ScanOverlay(busy: _busy),
                ]),
              ),
              _BottomPanel(
                rejection: _rejection,
                networkError: _networkError,
                failures: _failures,
                onRetry: _scanAgain,
                onManual: () => _open(const ManualCheckinPage()),
                onOffline: () => _open(const OfflineCheckinPage()),
              ),
            ]),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.rejection,
    required this.networkError,
    required this.failures,
    required this.onRetry,
    required this.onManual,
    required this.onOffline,
  });

  final CheckinResult? rejection;
  final String? networkError;
  final int failures;
  final VoidCallback onRetry;
  final VoidCallback onManual;
  final VoidCallback onOffline;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stopped = rejection != null || networkError != null;
    return Container(
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerLowest,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, -4))],
      ),
      padding: const EdgeInsets.all(16),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (rejection != null) ...[
            RejectionPanel(message: rejection!.displayMessage, alreadyCheckedIn: rejection!.alreadyCheckedIn),
            const SizedBox(height: 10),
          ],
          if (networkError != null) ...[
            RejectionPanel(message: networkError!),
            const SizedBox(height: 10),
          ],
          if (failures >= 3)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('Scanning keeps failing? Use manual check-in with the booking ID or mobile number.', style: t.textTheme.bodySmall),
            ),
          Row(children: [
            if (stopped) ...[
              Expanded(child: FilledButton.tonalIcon(icon: const Icon(Icons.refresh_rounded), label: const Text('Scan again'), onPressed: onRetry)),
              const SizedBox(width: 8),
            ],
            Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.keyboard_rounded), label: const Text('Manual'), onPressed: onManual)),
            if (networkError != null) ...[
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.cloud_off_rounded), label: const Text('Offline'), onPressed: onOffline)),
            ],
          ]),
        ]),
      ),
    );
  }
}

/// Dimmed surround with a clear window, animated corner brackets and a
/// sweeping scan line.
class _ScanOverlay extends StatefulWidget {
  const _ScanOverlay({required this.busy});
  final bool busy;

  @override
  State<_ScanOverlay> createState() => _ScanOverlayState();
}

class _ScanOverlayState extends State<_ScanOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Motion.reduced(context) && !_c.isAnimating) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final side = (box.biggest.shortestSide * 0.68).clamp(180.0, 300.0);
        return Stack(fit: StackFit.expand, children: [
          ExcludeSemantics(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(painter: _ScanPainter(side: side, t: Curves.easeInOut.transform(_c.value), busy: widget.busy)),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.82),
            child: AnimatedSwitcher(
              duration: Motion.fast,
              child: Container(
                key: ValueKey(widget.busy),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (widget.busy) ...[
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.busy ? 'Finding booking…' : 'Point at the driver\'s QR code',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ]),
              ),
            ),
          ),
        ]);
      });
}

class _ScanPainter extends CustomPainter {
  _ScanPainter({required this.side, required this.t, required this.busy});
  final double side;
  final double t;
  final bool busy;

  @override
  void paint(Canvas canvas, Size size) {
    final window = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    final rr = RRect.fromRectAndRadius(window, const Radius.circular(24));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(rr)),
      Paint()..color = Colors.black.withValues(alpha: busy ? 0.65 : 0.5),
    );
    final corner = Paint()
      ..color = Brand.mint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const len = 34.0;
    final l = window.left, r = window.right, tp = window.top, b = window.bottom;
    for (final p in [
      Path()..moveTo(l, tp + len)..lineTo(l, tp + 12)..quadraticBezierTo(l, tp, l + 12, tp)..lineTo(l + len, tp),
      Path()..moveTo(r - len, tp)..lineTo(r - 12, tp)..quadraticBezierTo(r, tp, r, tp + 12)..lineTo(r, tp + len),
      Path()..moveTo(l, b - len)..lineTo(l, b - 12)..quadraticBezierTo(l, b, l + 12, b)..lineTo(l + len, b),
      Path()..moveTo(r - len, b)..lineTo(r - 12, b)..quadraticBezierTo(r, b, r, b - 12)..lineTo(r, b - len),
    ]) {
      canvas.drawPath(p, corner);
    }
    if (!busy) {
      final y = window.top + 16 + (window.height - 32) * t;
      final line = Rect.fromLTWH(window.left + 18, y - 1.5, window.width - 36, 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(line, const Radius.circular(2)),
        Paint()..shader = const LinearGradient(colors: [Color(0x003DDC97), Brand.mint, Color(0x003DDC97)]).createShader(line),
      );
      final glow = Rect.fromLTWH(window.left + 18, y - 24, window.width - 36, 24);
      canvas.drawRect(
        glow,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Brand.mint.withValues(alpha: 0.25), Brand.mint.withValues(alpha: 0)],
          ).createShader(glow),
      );
    }
  }

  @override
  bool shouldRepaint(_ScanPainter old) => old.t != t || old.busy != busy || old.side != side;
}
