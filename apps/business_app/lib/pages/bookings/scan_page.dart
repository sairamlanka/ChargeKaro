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
        _snack('${booking.reference} checked in.');
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
                    Center(
                      child: Container(
                        width: 240,
                        height: 240,
                        decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                    if (_busy) const ColoredBox(color: Colors.black38, child: Center(child: CircularProgressIndicator())),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _manual,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Booking reference', hintText: 'CK…'),
                      onSubmitted: (v) => _handle(v, viaQr: false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _busy ? null : () => _handle(_manual.text, viaQr: false), child: const Text('Find')),
                ]),
              ),
            ]),
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.booking});
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final ok = b.status == BookingStatus.confirmed && b.paymentStatus.settled;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(b.reference, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [StatusChip.booking(b.status), StatusChip.payment(b.paymentStatus)]),
        const SizedBox(height: 8),
        KeyValue('Slot', Fmt.slot(b.startAt, b.endAt)),
        KeyValue('Point', b.chargingPointCode),
        KeyValue('Customer', b.customerDisplayName),
        KeyValue('Vehicle', b.vehicleLabel),
        const SizedBox(height: 12),
        if (!ok) Text('This booking cannot be checked in (${b.status.label.toLowerCase()}).', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        FilledButton(onPressed: ok ? () => Navigator.pop(context, true) : null, child: const Text('Check in')),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      ]),
    );
  }
}
