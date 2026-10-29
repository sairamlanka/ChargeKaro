import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../state.dart';
import '../../widgets/station_switcher.dart';

/// QR check-in with a manual reference fallback. The QR holds an opaque
/// token only; the booking is looked up server-side and only at this
/// station.
class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  final _manual = TextEditingController();
  bool _busy = false;
  bool _useCamera = true;

  @override
  void dispose() {
    _scanner.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _handle(String raw, {required bool viaQr}) async {
    if (_busy) return;
    final station = ref.read(currentStationProvider);
    final code = BookingCode.normalize(raw);
    if (station == null) return;
    if (code == null) {
      _snack(viaQr ? 'This QR code is not a ChargeKaro booking.' : 'Enter a reference like CK7Q2M9XKD4P.');
      return;
    }
    setState(() => _busy = true);
    await _scanner.stop();
    try {
      final booking = await ref.read(bookingRepositoryProvider).lookupForCheckIn(station.id, code);
      if (!mounted) return;
      final confirmIn = await showModalBottomSheet<bool>(context: context, builder: (_) => _ConfirmSheet(booking: booking));
      if (confirmIn == true && mounted) {
        await ref.read(bookingRepositoryProvider).checkIn(station.id, code, viaQr: viaQr);
        _manual.clear();
        if (mounted) await _celebrate(booking);
      }
    } on AppFailure catch (f) {
      _snack(f.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_useCamera) await _scanner.start();
      }
    }
  }

  Future<void> _celebrate(Booking b) => showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Close',
        transitionDuration: Motion.medium,
        transitionBuilder: (context, a, _, child) => FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(CurvedAnimation(parent: a, curve: Motion.emphasized)), child: child),
        ),
        pageBuilder: (context, _, _) => _CheckedInDialog(booking: b),
      );

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final station = ref.watch(currentStationProvider);
    return Scaffold(
      appBar: AppBar(
        title: const StationSwitcher(),
        actions: [
          IconButton(
            tooltip: _useCamera ? 'Type a reference' : 'Use camera',
            icon: Icon(_useCamera ? Icons.keyboard : Icons.qr_code_scanner),
            onPressed: () async {
              setState(() => _useCamera = !_useCamera);
              _useCamera ? await _scanner.start() : await _scanner.stop();
            },
          ),
        ],
      ),
      body: station == null
          ? const EmptyState(icon: Icons.ev_station_outlined, title: 'No station selected')
          : Column(children: [
              if (_useCamera)
                Expanded(
                  child: Stack(fit: StackFit.expand, children: [
                    MobileScanner(
                      controller: _scanner,
                      onDetect: (capture) {
                        final value = capture.barcodes.firstOrNull?.rawValue;
                        if (value != null) _handle(value, viaQr: true);
                      },
                      errorBuilder: (context, error) => EmptyState(
                        icon: Icons.no_photography_outlined,
                        title: 'Camera unavailable',
                        message: error.errorCode == MobileScannerErrorCode.permissionDenied
                            ? 'Allow camera access in Settings, or type the booking reference instead.'
                            : 'Type the booking reference instead.',
                      ),
                    ),
                    _ScanOverlay(busy: _busy),
                  ]),
                ),
              if (!_useCamera)
                const Expanded(
                  child: EmptyState(
                    icon: Icons.keyboard_rounded,
                    title: 'Type the booking code',
                    message: 'It starts with CK and is shown under the QR on the driver\'s phone.',
                  ),
                ),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, -4))],
                ),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: SafeArea(
                  top: false,
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _manual,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Booking reference',
                          hintText: 'CK…',
                          prefixIcon: Icon(Icons.confirmation_number_outlined),
                        ),
                        onSubmitted: (v) => _handle(v, viaQr: false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 96,
                      child: GradientButton(label: 'Find', busy: _busy, onPressed: () => _handle(_manual.text, viaQr: false)),
                    ),
                  ]),
                ),
              ),
            ]),
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

class _CheckedInDialog extends StatelessWidget {
  const _CheckedInDialog({required this.booking});
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = booking;
    return Center(
      child: Material(
        color: t.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: 320,
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SuccessCheck(size: 96),
            const SizedBox(height: 14),
            Entrance(index: 3, child: Text('Checked in', style: t.textTheme.headlineSmall)),
            const SizedBox(height: 6),
            Entrance(
              index: 4,
              child: Text(
                [b.customerDisplayName ?? b.reference, if (b.chargingPointCode != null) 'Point ${b.chargingPointCode}'].join(' · '),
                textAlign: TextAlign.center,
                style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 4),
            Entrance(index: 5, child: Text(Fmt.slot(b.startAt, b.endAt), style: t.textTheme.bodySmall)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: GradientButton(label: 'Next driver', icon: Icons.qr_code_scanner_rounded, onPressed: () => Navigator.pop(context)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.booking});
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = booking;
    final ok = b.status == BookingStatus.confirmed && b.paymentStatus.settled;
    final name = (b.customerDisplayName ?? '').trim().isEmpty ? 'Customer' : b.customerDisplayName!.trim();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: staggered([
            Row(children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: t.colorScheme.primary.withValues(alpha: 0.12),
                child: Text(name.characters.first.toUpperCase(), style: t.textTheme.titleLarge?.copyWith(color: t.colorScheme.primary)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: t.textTheme.titleLarge),
                  Text(b.reference, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, letterSpacing: 1)),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: t.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(AppTheme.fieldRadius)),
              child: Column(children: [
                _Line(Icons.schedule_rounded, Fmt.slot(b.startAt, b.endAt)),
                if (b.chargingPointCode != null) _Line(Icons.ev_station_rounded, 'Point ${b.chargingPointCode}'),
                if (b.vehicleLabel != null) _Line(Icons.directions_car_rounded, b.vehicleLabel!),
              ]),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [StatusChip.booking(b.status), StatusChip.payment(b.paymentStatus)]),
            const SizedBox(height: 16),
            if (!ok)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('This booking cannot be checked in (${b.status.label.toLowerCase()}).', style: TextStyle(color: t.colorScheme.error)),
              ),
            GradientButton(label: 'Check in', icon: Icons.login_rounded, onPressed: ok ? () => Navigator.pop(context, true) : null),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ]),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ]),
      );
}
