import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../checkin/checkin_state.dart';

/// Offline check-ins on this phone and the server's verdict for each.
/// Rejected events stay listed with the reason; nothing is marked arrived
/// unless the server accepted it.
class SyncQueuePage extends ConsumerWidget {
  const SyncQueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final state = ref.watch(offlineQueueProvider);
    final online = ref.watch(onlineProvider).value ?? true;
    final queue = ref.read(offlineQueueProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Sync queue'), actions: [
        IconButton(tooltip: 'Clear synced and rejected', icon: const Icon(Icons.clear_all_rounded), onPressed: queue.clearFinished),
      ]),
      body: AsyncView(
        value: state,
        builder: (s) => Column(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                child: Text(
                  s.syncing
                      ? 'Syncing…'
                      : !online
                          ? 'Offline. Events sync automatically when the internet is back.'
                          : s.lastError ?? (s.lastSync == null ? 'Ready to sync.' : 'Last synced ${Fmt.time(s.lastSync!)}.'),
                  style: t.textTheme.bodyMedium,
                ),
              ),
              FilledButton.icon(
                icon: s.syncing
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync_rounded),
                label: const Text('Sync now'),
                onPressed: s.syncing || !online ? null : queue.sync,
              ),
            ]),
          ),
          Expanded(
            child: s.events.isEmpty
                ? const EmptyState(icon: Icons.cloud_done_outlined, title: 'Nothing waiting', message: 'Offline check-ins appear here until they sync.')
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: s.events.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final e = s.events[s.events.length - 1 - i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(e.reference, style: t.textTheme.titleMedium?.copyWith(letterSpacing: 1)),
                        subtitle: Text([
                          'Recorded ${Fmt.dateTime(e.offlineAt)} (device time)',
                          if (e.syncedAt != null) 'Synced ${Fmt.time(e.syncedAt!)}',
                          if (e.state == OfflineEventState.rejected && e.message != null) e.message!,
                        ].join('\n')),
                        isThreeLine: e.state == OfflineEventState.rejected,
                        trailing: switch (e.state) {
                          OfflineEventState.pendingSync => const StatusChip('Pending sync', tone: StatusTone.warning, icon: Icons.cloud_upload_outlined),
                          OfflineEventState.accepted => const StatusChip('Verified', tone: StatusTone.success, icon: Icons.verified_rounded),
                          OfflineEventState.rejected => const StatusChip('Rejected', tone: StatusTone.danger, icon: Icons.block_rounded),
                        },
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
