import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../checkin/checkin_state.dart';
import 'checkin_widgets.dart';

/// Server-verified arrival: customer details are revealed here. Charging
/// is started separately and explicitly.
class CheckinSuccessPage extends ConsumerStatefulWidget {
  const CheckinSuccessPage({super.key, required this.booking});
  final Booking booking;

  @override
  ConsumerState<CheckinSuccessPage> createState() => _CheckinSuccessPageState();
}

class _CheckinSuccessPageState extends ConsumerState<CheckinSuccessPage> {
  late Booking _b = widget.booking;
  final _startKey = randomId();
  bool _busy = false;

  Future<void> _startCharging() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final device = await ref.read(deviceIdProvider.future);
      final r = await ref.read(bookingRepositoryProvider).startCharging(_b.id, idempotencyKey: _startKey, deviceId: device);
      if (!mounted) return;
      if (r.accepted) {
        setState(() => _b = r.booking ?? _b);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Charging started.')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.displayMessage)));
      }
    } on AppFailure catch (f) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(f.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Checked in'), automaticallyImplyLeading: false),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Center(child: SuccessCheck(size: 96)),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text('Arrival verified', textAlign: TextAlign.center, style: t.textTheme.headlineSmall),
          ),
          const SizedBox(height: 4),
          Text(
            'Checked in by ${_b.checkinMethod?.label.toLowerCase() ?? 'staff'} · ${_b.checkedInAt == null ? '' : Fmt.time(_b.checkedInAt!)}',
            textAlign: TextAlign.center,
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          CustomerDetailsCard(booking: _b),
          const SizedBox(height: 12),
          BookingSummaryCard(booking: _b),
          const SizedBox(height: 20),
          if (_b.status == BookingStatus.arrived)
            GradientButton(label: 'Start charging', icon: Icons.bolt_rounded, busy: _busy, onPressed: _startCharging),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Next driver'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ]),
      ),
    );
  }
}
