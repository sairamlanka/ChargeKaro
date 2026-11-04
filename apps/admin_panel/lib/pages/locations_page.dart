import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../shell.dart';

const _filters = <String, LocationRequestStatus?>{
  'Pending': LocationRequestStatus.pending,
  'Approved': LocationRequestStatus.approved,
  'Rejected': LocationRequestStatus.rejected,
  'All': null,
};

final _requestsProvider = FutureProvider.autoDispose.family<List<LocationRequest>, String>(
  (ref, filter) => ref.watch(locationRepositoryProvider).requests(status: _filters[filter]),
);

/// New states, districts and cities typed under "Other" in address forms.
/// Approving adds the value (and any new parent) to the dropdown lists.
class LocationsPage extends ConsumerStatefulWidget {
  const LocationsPage({super.key});

  @override
  ConsumerState<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends ConsumerState<LocationsPage> {
  String _filter = 'Pending';

  void _refresh() {
    for (final f in _filters.keys) {
      ref.invalidate(_requestsProvider(f));
    }
    // Dropdowns in this session pick up approved values.
    ref.invalidate(locationStatesProvider);
    ref.invalidate(locationDistrictsProvider);
    ref.invalidate(locationCitiesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_requestsProvider(_filter));
    return PageFrame(
      title: 'Location requests',
      scroll: false,
      actions: [IconButton(tooltip: 'Refresh', onPressed: _refresh, icon: const Icon(Icons.refresh))],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Businesses pick "Other" when their state, district or city is not in the list. '
            'Approve to add it to the dropdowns for everyone, or reject with a reason.'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          for (final f in _filters.keys)
            ChoiceChip(label: Text(f), selected: _filter == f, onSelected: (_) => setState(() => _filter = f)),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: AsyncView(
            value: data,
            onRetry: () => ref.invalidate(_requestsProvider(_filter)),
            builder: (list) => list.isEmpty
                ? EmptyState(
                    icon: Icons.location_city_rounded,
                    title: _filter == 'Pending' ? 'No requests waiting' : 'Nothing here',
                    message: _filter == 'Pending' ? 'New places typed under "Other" show up here.' : null,
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => _RequestTile(request: list[i], onDecided: _refresh),
                  ),
          ),
        ),
      ]),
    );
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({required this.request, required this.onDecided});

  final LocationRequest request;
  final VoidCallback onDecided;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    final tone = switch (r.status) {
      LocationRequestStatus.pending => StatusTone.warning,
      LocationRequestStatus.approved => StatusTone.success,
      LocationRequestStatus.rejected => StatusTone.danger,
    };
    final pending = r.status == LocationRequestStatus.pending;
    final manage = can(ref, PlatformPermission.locationsManage);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      leading: CircleAvatar(child: Icon(switch (r.kind) {
        LocationKind.state => Icons.map_outlined,
        LocationKind.district => Icons.holiday_village_outlined,
        LocationKind.city => Icons.location_city_outlined,
      })),
      title: Text('${r.kind.label}: ${r.value}'),
      subtitle: Text([
        r.path,
        [if (r.requesterName != null) 'by ${r.requesterName}', if (r.context != null) r.context!, Fmt.dateTime(r.createdAt)].join(' · '),
        if (r.decisionNote != null) 'Note: ${r.decisionNote}',
      ].join('\n')),
      isThreeLine: true,
      trailing: pending && manage
          ? Wrap(spacing: 4, children: [
              IconButton(
                tooltip: 'Reject',
                icon: const Icon(Icons.close_rounded),
                onPressed: () async {
                  if (await showDialog<bool>(context: context, builder: (_) => _RejectDialog(request: r)) == true) onDecided();
                },
              ),
              FilledButton(
                onPressed: () async {
                  if (await showDialog<bool>(context: context, builder: (_) => _ApproveDialog(request: r)) == true) onDecided();
                },
                child: const Text('Approve'),
              ),
            ])
          : StatusChip(r.status.label, tone: tone),
    );
  }
}

/// Lets the admin fix the spelling before the value goes into the list.
class _ApproveDialog extends ConsumerStatefulWidget {
  const _ApproveDialog({required this.request});
  final LocationRequest request;

  @override
  ConsumerState<_ApproveDialog> createState() => _ApproveDialogState();
}

class _ApproveDialogState extends ConsumerState<_ApproveDialog> {
  late final _state = TextEditingController(text: widget.request.stateName);
  late final _district = TextEditingController(text: widget.request.districtName ?? '');
  late final _city = TextEditingController(text: widget.request.cityName ?? '');
  final _form = GlobalKey<FormState>();
  bool _busy = false;

  @override
  void dispose() {
    _state.dispose();
    _district.dispose();
    _city.dispose();
    super.dispose();
  }

  String? _valid(String? v) {
    final t = v?.trim() ?? '';
    return t.length < 2 || t.length > 80 ? 'Use 2 to 80 characters' : null;
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.request.kind;
    return AlertDialog(
      title: Text('Add ${kind.label.toLowerCase()}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Check the spelling. Any new state or district in this address is added too.'),
            const SizedBox(height: 12),
            TextFormField(controller: _state, decoration: const InputDecoration(labelText: 'State'), validator: _valid),
            if (kind != LocationKind.state) ...[
              const SizedBox(height: 12),
              TextFormField(controller: _district, decoration: const InputDecoration(labelText: 'District'), validator: _valid),
            ],
            if (kind == LocationKind.city) ...[
              const SizedBox(height: 12),
              TextFormField(controller: _city, decoration: const InputDecoration(labelText: 'City / town'), validator: _valid),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  if (!_form.currentState!.validate()) return;
                  setState(() => _busy = true);
                  final nav = Navigator.of(context);
                  final ok = await runAction(
                    context,
                    () => ref.read(locationRepositoryProvider).decide(
                          widget.request.id,
                          approve: true,
                          state: _state.text.trim(),
                          district: kind == LocationKind.state ? null : _district.text.trim(),
                          city: kind == LocationKind.city ? _city.text.trim() : null,
                        ),
                    success: 'Added to the list',
                  );
                  if (ok) {
                    nav.pop(true);
                  } else if (mounted) {
                    setState(() => _busy = false);
                  }
                },
          child: const Text('Approve and add'),
        ),
      ],
    );
  }
}

class _RejectDialog extends ConsumerStatefulWidget {
  const _RejectDialog({required this.request});
  final LocationRequest request;

  @override
  ConsumerState<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends ConsumerState<_RejectDialog> {
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Reject "${widget.request.value}"'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: _note,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Reason (sent to the business)', hintText: 'For example: already listed as Secunderabad'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: _busy || _note.text.trim().isEmpty
                ? null
                : () async {
                    setState(() => _busy = true);
                    final nav = Navigator.of(context);
                    final ok = await runAction(
                      context,
                      () => ref.read(locationRepositoryProvider).decide(widget.request.id, approve: false, note: _note.text.trim()),
                      success: 'Request rejected',
                    );
                    if (ok) {
                      nav.pop(true);
                    } else if (mounted) {
                      setState(() => _busy = false);
                    }
                  },
            child: const Text('Reject'),
          ),
        ],
      );
}
