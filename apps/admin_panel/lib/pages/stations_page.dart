import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../shell.dart';

typedef _Args = ({StationStatus? status, String search});

final _stationsProvider = FutureProvider.autoDispose.family<List<Station>, _Args>(
  (ref, a) => ref.watch(adminRepositoryProvider).stations(status: a.status, search: a.search),
);

final _changeRequestsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(onboardingRepositoryProvider).pendingChangeRequests(),
);

class StationsPage extends ConsumerStatefulWidget {
  const StationsPage({super.key});

  @override
  ConsumerState<StationsPage> createState() => _StationsPageState();
}

class _StationsPageState extends ConsumerState<StationsPage> {
  StationStatus? _status;
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final args = (status: _status, search: _search);
    final data = ref.watch(_stationsProvider(args));
    final changes = ref.watch(_changeRequestsProvider);
    void refresh() {
      ref.invalidate(_stationsProvider(args));
      ref.invalidate(_changeRequestsProvider);
    }

    return PageFrame(
      title: 'Stations',
      actions: [
        SizedBox(
          width: 240,
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Station name'),
            onSubmitted: (v) => setState(() => _search = v),
          ),
        ),
        DropdownButton<StationStatus?>(
          value: _status,
          hint: const Text('Any status'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Any status')),
            for (final s in StationStatus.values) DropdownMenuItem(value: s, child: Text(s.label)),
          ],
          onChanged: (v) => setState(() => _status = v),
        ),
        IconButton(tooltip: 'Refresh', onPressed: refresh, icon: const Icon(Icons.refresh)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AsyncView(
          value: changes,
          onRetry: () => ref.invalidate(_changeRequestsProvider),
          builder: (list) => list.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: SectionCard(
                    title: 'Pending change requests (${list.length})',
                    child: Column(children: [for (final c in list) _ChangeRequestTile(c, onDone: refresh)]),
                  ),
                ),
        ),
        AsyncView(
          value: data,
          onRetry: refresh,
          builder: (list) => list.isEmpty
              ? const EmptyState(icon: Icons.ev_station_outlined, title: 'No stations match')
              : Card(
                  child: Column(children: [
                    for (final s in list) ...[
                      _StationTile(s, onChanged: refresh),
                      if (s != list.last) const Divider(height: 1),
                    ],
                  ]),
                ),
        ),
      ]),
    );
  }
}

class _ChangeRequestTile extends ConsumerWidget {
  const _ChangeRequestTile(this.c, {required this.onDone});
  final Map<String, dynamic> c;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = StationChangeRequest.fromJson(c);
    final station = (c['stations'] as Map?)?['name'] as String? ?? 'Station';
    final repo = ref.read(onboardingRepositoryProvider);
    final allowed = can(ref, PlatformPermission.stationsManage);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('$station · requested ${Fmt.relative(req.createdAt)}'),
      subtitle: Text([
        for (final e in req.changes.entries) '${e.key}: ${e.value}',
        if (req.note != null) 'Note: ${req.note}',
      ].join('\n')),
      isThreeLine: true,
      trailing: !allowed
          ? null
          : Wrap(spacing: 4, children: [
              IconButton(
                tooltip: 'Approve and apply',
                icon: const Icon(Icons.check),
                onPressed: () async {
                  final note = await confirmWithReason(context,
                      title: 'Apply change',
                      message: 'The station details are updated immediately. Verify new addresses or coordinates first.',
                      confirmLabel: 'Approve',
                      reasonLabel: 'Note',
                      minReasonLength: 2);
                  if (note == null || !context.mounted) return;
                  if (await runAction(context, () => repo.decideChange(req.id, approve: true, note: note), success: 'Change applied.')) onDone();
                },
              ),
              IconButton(
                tooltip: 'Decline',
                icon: const Icon(Icons.close),
                onPressed: () async {
                  final note = await confirmWithReason(context,
                      title: 'Decline change', message: 'The business is told why.', confirmLabel: 'Decline', reasonLabel: 'Reason');
                  if (note == null || !context.mounted) return;
                  if (await runAction(context, () => repo.decideChange(req.id, approve: false, note: note), success: 'Change declined.')) onDone();
                },
              ),
            ]),
    );
  }
}

class _StationTile extends ConsumerWidget {
  const _StationTile(this.s, {required this.onChanged});
  final Station s;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admin = ref.read(adminRepositoryProvider);
    final canSuspend = can(ref, PlatformPermission.stationsSuspend);
    final canManage = can(ref, PlatformPermission.stationsManage);

    Future<void> suspend() async {
      var cancel = false;
      final reason = await showDialog<String>(
        context: context,
        builder: (context) {
          final c = TextEditingController();
          return StatefulBuilder(
            builder: (context, set) => AlertDialog(
              title: Text('Suspend ${s.name}'),
              content: SizedBox(
                width: 460,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('The station stops taking bookings. The business is notified with your reason.'),
                  const SizedBox(height: 12),
                  TextField(controller: c, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Reason'), onChanged: (_) => set(() {})),
                  CheckboxListTile(
                    value: cancel,
                    onChanged: (v) => set(() => cancel = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Also cancel future bookings'),
                    subtitle: const Text('Customers are notified; paid booking fees are refunded per the refund policy.'),
                  ),
                ]),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                  onPressed: c.text.trim().length < 5 ? null : () => Navigator.pop(context, c.text.trim()),
                  child: const Text('Suspend'),
                ),
              ],
            ),
          );
        },
      );
      if (reason == null || !context.mounted) return;
      if (await runAction(context, () => admin.suspendStation(s.id, reason, cancelFutureBookings: cancel), success: 'Station suspended.')) {
        onChanged();
      }
    }

    Future<void> withReason(String title, String message, String label, Future<void> Function(String) f, String done,
        {bool destructive = false}) async {
      final reason = await confirmWithReason(context,
          title: title, message: message, confirmLabel: label, reasonLabel: 'Reason', destructive: destructive);
      if (reason == null || !context.mounted) return;
      if (await runAction(context, () => f(reason), success: done)) onChanged();
    }

    return ListTile(
      title: Row(children: [
        Flexible(child: Text(s.name, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 8),
        StatusChip.station(s.status),
        if (s.deactivationRequestedAt != null) ...[
          const SizedBox(width: 8),
          const StatusChip('Deactivation requested', tone: StatusTone.warning),
        ],
      ]),
      subtitle: Text([
        '${s.city}, ${s.state}',
        if (s.statusReason != null) s.statusReason!,
        if (s.approvedAt != null) 'approved ${Fmt.date(s.approvedAt!)}',
      ].join(' · ')),
      trailing: PopupMenuButton<String>(
        itemBuilder: (_) => [
          if (canSuspend && (s.status == StationStatus.active || s.status == StationStatus.temporarilyClosed))
            const PopupMenuItem(value: 'suspend', child: Text('Suspend')),
          if (canSuspend && s.status == StationStatus.suspended) const PopupMenuItem(value: 'reactivate', child: Text('Reactivate')),
          if (canManage && s.status != StationStatus.deactivated && s.status != StationStatus.draft)
            const PopupMenuItem(value: 'deactivate', child: Text('Deactivate permanently')),
        ],
        onSelected: (v) => switch (v) {
          'suspend' => suspend(),
          'reactivate' => withReason('Reactivate ${s.name}', 'The station can take bookings again.', 'Reactivate',
              (r) => admin.reactivateStation(s.id, r), 'Station reactivated.'),
          'deactivate' => withReason(
              'Deactivate ${s.name}',
              'This is permanent. Future bookings are cancelled and the station is removed from search.',
              'Deactivate',
              (r) => admin.deactivateStation(s.id, r),
              'Station deactivated.',
              destructive: true),
          _ => Future<void>.value(),
        },
      ),
    );
  }
}
