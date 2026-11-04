import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../state.dart';

final _historyProvider = FutureProvider.autoDispose.family<List<CheckinLogEntry>, String>(
    (ref, stationId) => ref.watch(bookingRepositoryProvider).checkinHistory(stationId));

/// Check-in activity at the current station. Managers and owners see
/// everyone's entries; staff see their own.
class CheckinHistoryPage extends ConsumerWidget {
  const CheckinHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final station = ref.watch(currentStationProvider);
    if (station == null) return const Scaffold(body: EmptyState(icon: Icons.ev_station_outlined, title: 'No station selected'));
    final data = ref.watch(_historyProvider(station.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Check-in history')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_historyProvider(station.id)),
        builder: (rows) => rows.isEmpty
            ? const EmptyState(icon: Icons.history_rounded, title: 'No check-ins yet')
            : RefreshIndicator(
                onRefresh: () => ref.refresh(_historyProvider(station.id).future),
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(r.accepted ? Icons.check_circle_rounded : Icons.cancel_rounded,
                          color: r.accepted ? Colors.green.shade700 : Theme.of(context).colorScheme.error),
                      title: Text([r.title, ?r.reference].join(' · ')),
                      subtitle: Text([
                        Fmt.dateTime(r.serverAt),
                        if (r.method != null) r.method!.label,
                        if (!r.isMine && r.staffName != null) r.staffName!,
                        if (r.reason != null) r.reason!,
                        if (!r.accepted && r.rejectionMessage != null) r.rejectionMessage!,
                        if (r.offlineAt != null) 'Recorded offline ${Fmt.time(r.offlineAt!)}',
                      ].join(' · ')),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
