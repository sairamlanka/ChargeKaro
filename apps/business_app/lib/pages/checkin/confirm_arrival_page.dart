import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../checkin/checkin_state.dart';
import 'checkin_success_page.dart';
import 'checkin_widgets.dart';

/// Step 2 of QR and manual check-in: the server has validated the booking
/// and returned limited details; staff confirm arrival. Manual check-in
/// needs a reason; a manager may override a closed arrival window.
class ConfirmArrivalPage extends ConsumerStatefulWidget {
  const ConfirmArrivalPage({super.key, required this.stationId, required this.preview, required this.method, this.qrPayload});

  final String stationId;
  final CheckinResult preview;
  final CheckinMethod method;
  final String? qrPayload;

  @override
  ConsumerState<ConfirmArrivalPage> createState() => _ConfirmArrivalPageState();
}

class _ConfirmArrivalPageState extends ConsumerState<ConfirmArrivalPage> {
  // One key per confirmation screen: a retry after a timeout returns the
  // first result instead of checking in twice.
  final _key = randomId();
  final _note = TextEditingController();
  final _override = TextEditingController();
  ManualCheckinReason? _reason;
  bool _busy = false;
  CheckinResult? _rejection;

  @override
  void dispose() {
    _note.dispose();
    _override.dispose();
    super.dispose();
  }

  bool get _manual => widget.method == CheckinMethod.manual;
  bool get _needsOverride => !widget.preview.eligible;

  Future<void> _confirm() async {
    if (_busy) return;
    if (_manual) {
      final problem = ManualCheckinReason.validate(_reason, _note.text);
      if (problem != null) return _snack(problem);
    }
    if (_needsOverride && _override.text.trim().length < 5) return _snack('Enter a reason for the override.');
    setState(() {
      _busy = true;
      _rejection = null;
    });
    try {
      final device = await ref.read(deviceIdProvider.future);
      final result = await ref.read(bookingRepositoryProvider).checkIn(
            stationId: widget.stationId,
            bookingId: widget.preview.booking!.id,
            method: widget.method,
            idempotencyKey: _key,
            qrPayload: widget.qrPayload,
            reason: _manual ? _reason : null,
            reasonNote: _manual && _reason == ManualCheckinReason.other ? _note.text.trim() : null,
            deviceId: device,
            overrideReason: _needsOverride ? _override.text.trim() : null,
          );
      if (!mounted) return;
      if (result.accepted) {
        await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => CheckinSuccessPage(booking: result.booking!)));
      } else {
        setState(() => _rejection = result);
      }
    } on AppFailure catch (f) {
      _snack(f.kind == FailureKind.network
          ? 'No connection. Tap Confirm again when you are back online, or use Offline check-in.'
          : f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = widget.preview;
    final b = p.booking!;
    final blocked = _needsOverride && !p.overrideAllowed;
    return Scaffold(
      appBar: AppBar(title: Text(_manual ? 'Manual check-in' : 'Confirm arrival')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          BookingSummaryCard(booking: b),
          const SizedBox(height: 16),
          if (_needsOverride) ...[
            RejectionPanel(message: p.message ?? 'This booking cannot be checked in now.', alreadyCheckedIn: p.code == 'already_checked_in'),
            const SizedBox(height: 12),
            if (p.overrideAllowed) ...[
              Text('Manager override', style: t.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('You can approve this as a manager. The reason is recorded with your name.', style: t.textTheme.bodySmall),
              const SizedBox(height: 8),
              TextField(
                controller: _override,
                maxLength: 300,
                decoration: const InputDecoration(labelText: 'Override reason', hintText: 'e.g. Customer delayed by traffic'),
              ),
            ] else if (p.code == 'too_late' || p.code == 'too_early' || p.code == 'marked_no_show')
              Text('Ask your station manager or the owner to approve this from their account.', style: t.textTheme.bodyMedium),
          ],
          if (_manual && !blocked) ...[
            const SizedBox(height: 8),
            Text('Why manual check-in?', style: t.textTheme.titleMedium),
            RadioGroup<ManualCheckinReason>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(children: [
                for (final r in ManualCheckinReason.values)
                  RadioListTile<ManualCheckinReason>(value: r, title: Text(r.label), contentPadding: EdgeInsets.zero, dense: true),
              ]),
            ),
            if (_reason == ManualCheckinReason.other)
              TextField(
                controller: _note,
                maxLength: 280,
                decoration: const InputDecoration(labelText: 'Explain briefly', hintText: 'At least a few words'),
              ),
          ],
          if (_rejection != null) ...[
            const SizedBox(height: 12),
            RejectionPanel(message: _rejection!.displayMessage, alreadyCheckedIn: _rejection!.alreadyCheckedIn),
          ],
          const SizedBox(height: 20),
          GradientButton(
            label: _needsOverride ? 'Approve and check in' : 'Confirm arrival',
            icon: Icons.how_to_reg_rounded,
            busy: _busy,
            onPressed: blocked || (_rejection?.rejected ?? false) && _rejection!.alreadyCheckedIn ? null : _confirm,
          ),
          const SizedBox(height: 8),
          Text(
            'Customer details appear after the server confirms the check-in. Charging does not start automatically.',
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}
