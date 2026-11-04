import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../checkin/checkin_state.dart';
import '../../state.dart';
import 'checkin_widgets.dart';
import 'sync_queue_page.dart';

/// Offline-assisted check-in. Only bookings in this staff member's last
/// downloaded list can be recorded, and only as PENDING SYNC: the server
/// decides when the event syncs. No customer details are shown here.
class OfflineCheckinPage extends ConsumerStatefulWidget {
  const OfflineCheckinPage({super.key});

  @override
  ConsumerState<OfflineCheckinPage> createState() => _OfflineCheckinPageState();
}

class _OfflineCheckinPageState extends ConsumerState<OfflineCheckinPage> {
  final _ref = TextEditingController();
  String? _error;
  OfflineCheckinEvent? _recorded;
  bool _busy = false;

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    if (_busy) return;
    final station = ref.read(currentStationProvider);
    final queue = ref.read(offlineQueueProvider.notifier);
    final store = queue.store;
    if (station == null || store == null) return;
    final cache = store.cacheFor(station.id);
    final problem = OfflineCheckinRules.problem(
      cache: cache,
      stationId: station.id,
      staffId: store.staffId,
      reference: _ref.text,
      now: DateTime.now(),
      queued: store.events(),
    );
    if (problem != null) return setState(() => _error = problem);
    final b = OfflineCheckinRules.find(cache!, _ref.text)!;
    final ok = await confirm(
      context,
      title: 'Record offline check-in?',
      message: 'Booking ${b.reference}, ${Fmt.slot(b.startAt, b.endAt)}${b.pointCode == null ? '' : ', point ${b.pointCode}'}.\n\n'
          'This is provisional. It is sent to ChargeKaro when the internet is back, and may still be rejected '
          '(for example if the booking was cancelled meanwhile).',
      confirmLabel: 'Record check-in',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final event = await queue.record(b);
      setState(() {
        _recorded = event;
        _error = null;
        _ref.clear();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final station = ref.watch(currentStationProvider);
    final online = ref.watch(onlineProvider).value ?? true;
    ref.watch(offlineQueueProvider);
    final store = ref.read(offlineQueueProvider.notifier).store;
    final cache = station == null ? null : store?.cacheFor(station.id);
    final pending = ref.watch(pendingSyncCountProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Offline check-in')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (online)
          const RejectionPanel(
            message: 'You are online. Use QR or manual check-in for an immediate, verified check-in. '
                'Offline check-in is for when the internet is down.',
            alreadyCheckedIn: true,
          ),
        const SizedBox(height: 12),
        _CacheStatus(cache: cache),
        const SizedBox(height: 16),
        TextField(
          controller: _ref,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [LengthLimitingTextInputFormatter(16)],
          decoration: const InputDecoration(labelText: 'Booking reference', hintText: 'CK…', prefixIcon: Icon(Icons.confirmation_number_outlined)),
          onSubmitted: (_) => _record(),
        ),
        if (_error != null) ...[const SizedBox(height: 10), RejectionPanel(message: _error!)],
        const SizedBox(height: 16),
        GradientButton(label: 'Check in offline', icon: Icons.cloud_off_rounded, busy: _busy, onPressed: cache == null ? null : _record),
        if (_recorded != null) ...[
          const SizedBox(height: 20),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(AppTheme.fieldRadius)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const VerificationChip(VerificationStatus.pendingSync),
                const SizedBox(height: 8),
                Text('${_recorded!.reference} recorded at ${Fmt.time(_recorded!.offlineAt)}', style: t.textTheme.titleMedium),
                const SizedBox(height: 4),
                const Text('Not verified yet. Customer details appear after the server accepts it. Do not start charging '
                    'unless your station policy allows it before verification.'),
              ]),
            ),
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.sync_rounded)),
          label: const Text('Sync queue'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SyncQueuePage())),
        ),
      ]),
    );
  }
}

class _CacheStatus extends StatelessWidget {
  const _CacheStatus({required this.cache});
  final OfflineCache? cache;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = cache;
    final stale = c != null && DateTime.now().isAfter(c.validUntil);
    final text = c == null
        ? 'No offline booking list on this phone. Open Check-in while online to download it.'
        : stale
            ? 'Offline list from ${Fmt.dateTime(c.generatedAt)} is out of date. Reconnect to refresh it.'
            : 'Offline list: ${c.bookings.length} bookings, downloaded ${Fmt.dateTime(c.generatedAt)}.';
    return Row(children: [
      Icon(c == null || stale ? Icons.warning_amber_rounded : Icons.offline_pin_rounded,
          color: c == null || stale ? t.colorScheme.error : t.colorScheme.primary),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ]);
  }
}
