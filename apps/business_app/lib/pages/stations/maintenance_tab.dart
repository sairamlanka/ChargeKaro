import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../state.dart';

final _reportsProvider = FutureProvider.autoDispose.family<List<MaintenanceReport>, String>(
    (ref, id) => ref.watch(stationRepositoryProvider).maintenance(id));

class MaintenanceTab extends ConsumerWidget {
  const MaintenanceTab({super.key, required this.station});
  final Station station;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(currentAccessProvider);
    final canReport = access?.can(BusinessPermission.maintenanceReport, stationId: station.id) ?? false;
    final canManage = access?.can(BusinessPermission.maintenanceManage, stationId: station.id) ?? false;
    final points = ref.watch(pointsProvider(station.id)).value ?? const [];
    void refresh() {
      ref.invalidate(_reportsProvider(station.id));
      ref.invalidate(pointsProvider(station.id));
    }

    return Scaffold(
      floatingActionButton: canReport
          ? FloatingActionButton.extended(
              heroTag: 'report-issue',
              icon: const Icon(Icons.build_outlined),
              label: const Text('Report issue'),
              onPressed: () async {
                if (await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _ReportSheet(station: station, points: points)) ==
                    true) {
                  refresh();
                }
              },
            )
          : null,
      body: AsyncView(
        value: ref.watch(_reportsProvider(station.id)),
        onRetry: refresh,
        builder: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.build_circle_outlined, title: 'No issues reported')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final r = list[i];
                  final point = points.where((p) => p.id == r.chargingPointId).firstOrNull;
                  final open = r.status == MaintenanceStatus.open || r.status == MaintenanceStatus.inProgress;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(r.title, style: Theme.of(context).textTheme.titleSmall)),
                          StatusChip.maintenance(r.status),
                        ]),
                        Text('${r.severity.label} · ${point?.code ?? 'Station'} · ${Fmt.dateTime(r.reportedAt)}'),
                        const SizedBox(height: 4),
                        Text(r.description),
                        if (r.resolutionNotes != null) Text('Resolution: ${r.resolutionNotes}'),
                        if (canManage && open)
                          Wrap(spacing: 8, children: [
                            if (r.status == MaintenanceStatus.open)
                              TextButton(
                                onPressed: () async {
                                  if (await runAction(context, () => ref.read(stationRepositoryProvider).updateIssue(r.id, MaintenanceStatus.inProgress))) refresh();
                                },
                                child: const Text('Start work'),
                              ),
                            TextButton(onPressed: () => _resolve(context, ref, r, refresh), child: const Text('Resolve')),
                          ]),
                      ]),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _resolve(BuildContext context, WidgetRef ref, MaintenanceReport r, VoidCallback refresh) async {
    final notes = await confirmWithReason(context,
        title: 'Resolve issue', message: r.title, confirmLabel: 'Resolve', reasonLabel: 'What was done');
    if (notes == null || !context.mounted) return;
    var restore = false;
    if (r.markedPointUnavailable) {
      restore = await confirm(context,
          title: 'Make the point available again?', message: 'It was marked unavailable when this was reported.', confirmLabel: 'Yes, available');
    }
    if (!context.mounted) return;
    if (await runAction(context,
        () => ref.read(stationRepositoryProvider).updateIssue(r.id, MaintenanceStatus.resolved, resolutionNotes: notes, restorePoint: restore),
        success: 'Issue resolved.')) {
      refresh();
    }
  }
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.station, required this.points});
  final Station station;
  final List<ChargingPoint> points;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  String? _point;
  MaintenanceSeverity _severity = MaintenanceSeverity.medium;
  bool _unavailable = true;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _title.text.trim().length >= 3 && _description.text.trim().length >= 5;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Report an issue', style: Theme.of(context).textTheme.titleLarge),
          DropdownButtonFormField<String?>(
            initialValue: _point,
            decoration: const InputDecoration(labelText: 'Where'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Station (general)')),
              for (final p in widget.points) DropdownMenuItem(value: p.id, child: Text(p.code)),
            ],
            onChanged: (v) => setState(() => _point = v),
          ),
          const SizedBox(height: 8),
          TextField(controller: _title, decoration: const InputDecoration(labelText: 'Short title'), onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          TextField(controller: _description, decoration: const InputDecoration(labelText: 'What is wrong'), maxLines: 3, onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          SegmentedButton<MaintenanceSeverity>(
            segments: [for (final s in MaintenanceSeverity.values) ButtonSegment(value: s, label: Text(s.label))],
            selected: {_severity},
            onSelectionChanged: (s) => setState(() => _severity = s.first),
          ),
          if (_point != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _unavailable,
              onChanged: (v) => setState(() => _unavailable = v),
              title: const Text('Mark this point under maintenance'),
              subtitle: const Text('Stops new bookings. Existing bookings are not cancelled automatically.'),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: !valid
                ? null
                : () async {
                    final ok = await runAction(
                      context,
                      () => ref.read(stationRepositoryProvider).reportIssue(
                            stationId: widget.station.id,
                            chargingPointId: _point,
                            title: _title.text.trim(),
                            description: _description.text.trim(),
                            severity: _severity,
                            markUnavailable: _point != null && _unavailable,
                          ),
                      success: 'Issue reported.',
                    );
                    if (ok && context.mounted) Navigator.pop(context, true);
                  },
            child: const Text('Report'),
          ),
        ]),
      ),
    );
  }
}
