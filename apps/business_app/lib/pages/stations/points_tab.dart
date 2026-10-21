import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../state.dart';

/// Charging points. Operational status is reported by staff (status_source =
/// manual); the app never claims live charger telemetry.
class PointsTab extends ConsumerWidget {
  const PointsTab({super.key, required this.station});
  final Station station;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(currentAccessProvider);
    final canManage = access?.can(BusinessPermission.pointsManage, stationId: station.id) ?? false;
    final canStatus = access?.can(BusinessPermission.pointsStatus, stationId: station.id) ?? false;
    void refresh() => ref.invalidate(pointsProvider(station.id));

    return Scaffold(
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              heroTag: 'add-point',
              icon: const Icon(Icons.add),
              label: const Text('Add point'),
              onPressed: () async {
                if (await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => PointEditor(stationId: station.id)) ==
                    true) {
                  refresh();
                }
              },
            )
          : null,
      body: AsyncView(
        value: ref.watch(pointsProvider(station.id)),
        onRetry: refresh,
        builder: (points) => points.isEmpty
            ? const EmptyState(icon: Icons.power_outlined, title: 'No charging points', message: 'Add each charger or socket customers can book.')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: points.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final p = points[i];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text('${p.code}${p.name == null ? '' : ' · ${p.name}'}', style: Theme.of(context).textTheme.titleMedium)),
                          StatusChip.point(p.operationalStatus),
                        ]),
                        const SizedBox(height: 4),
                        Text('${p.currentType.label} · ${p.maxPowerKw.toStringAsFixed(1)} kW · ${p.connectors.map((c) => c.type.label).join(', ')}'),
                        Text('For ${p.vehicleCompatibility.map((v) => v.label).join(', ')}'),
                        Text(
                          '${p.bookingEnabled ? 'Bookable' : 'Not bookable'} · status ${p.statusSource.label.toLowerCase()}, updated ${Fmt.relative(p.statusUpdatedAt)}'
                          '${p.statusNote == null ? '' : ' · ${p.statusNote}'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Wrap(spacing: 8, children: [
                          if (canStatus) TextButton(onPressed: () => _status(context, ref, p, refresh), child: const Text('Update status')),
                          if (canManage)
                            TextButton(
                              onPressed: () async {
                                final saved = await showModalBottomSheet<bool>(
                                    context: context, isScrollControlled: true, builder: (_) => PointEditor(stationId: station.id, point: p));
                                if (saved == true) refresh();
                              },
                              child: const Text('Edit'),
                            ),
                          if (canManage)
                            TextButton(
                              onPressed: () async {
                                final ok = await confirm(context,
                                    title: 'Remove ${p.code}?',
                                    message: 'The point stops taking bookings and is hidden. Its booking history is kept.',
                                    confirmLabel: 'Remove',
                                    destructive: true);
                                if (!ok || !context.mounted) return;
                                if (await runAction(context, () => ref.read(stationRepositoryProvider).archivePoint(p.id))) refresh();
                              },
                              child: const Text('Remove'),
                            ),
                        ]),
                      ]),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _status(BuildContext context, WidgetRef ref, ChargingPoint p, VoidCallback refresh) async {
    final note = TextEditingController(text: p.statusNote);
    var status = p.operationalStatus;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Status of ${p.code}', style: Theme.of(context).textTheme.titleLarge),
            const Text('What staff can see right now. Customers see this when booking.'),
            RadioGroup<PointStatus>(
              groupValue: status,
              onChanged: (v) => set(() => status = v ?? status),
              child: Column(children: [
                for (final s in PointStatus.values) RadioListTile<PointStatus>(value: s, title: Text(s.label)),
              ]),
            ),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)')),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ]),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    Map<String, dynamic>? result;
    final saved = await runAction(context, () async {
      result = await ref.read(stationRepositoryProvider).setPointStatus(p.id, status, note: note.text.trim().isEmpty ? null : note.text.trim());
    });
    if (!saved || !context.mounted) return;
    refresh();
    final upcoming = (result?['upcoming_bookings'] as num?)?.toInt() ?? 0;
    if (!status.acceptsBookings && upcoming > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('$upcoming upcoming booking(s) on ${p.code}. Contact those customers or block the time in Availability.'),
      ));
    }
  }
}

class PointEditor extends ConsumerStatefulWidget {
  const PointEditor({super.key, required this.stationId, this.point});
  final String stationId;
  final ChargingPoint? point;

  @override
  ConsumerState<PointEditor> createState() => _PointEditorState();
}

class _PointEditorState extends ConsumerState<PointEditor> {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.point?.code);
  late final _name = TextEditingController(text: widget.point?.name);
  late final _power = TextEditingController(text: widget.point?.maxPowerKw.toString());
  late final _restrictions = TextEditingController(text: widget.point?.restrictionsNote);
  late CurrentType _current = widget.point?.currentType ?? CurrentType.ac;
  late Set<VehicleCategory> _vehicles = widget.point?.vehicleCompatibility ?? {VehicleCategory.fourWheeler};
  late List<ConnectorType> _connectors = widget.point?.connectors.map((c) => c.type).toList() ?? [ConnectorType.type2Ac];
  late bool _bookable = widget.point?.bookingEnabled ?? true;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_code, _name, _power, _restrictions]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _connectors.isEmpty || _vehicles.isEmpty) return;
    setState(() => _busy = true);
    final repo = ref.read(stationRepositoryProvider);
    final fields = <String, Object?>{
      'code': _code.text.trim().toUpperCase(),
      'name': _name.text.trim().isEmpty ? null : _name.text.trim(),
      'current_type': _current.wire,
      'max_power_kw': double.parse(_power.text.trim()),
      'vehicle_compatibility': _vehicles.map((v) => v.wire).toList(),
      'booking_enabled': _bookable,
      'restrictions_note': _restrictions.text.trim().isEmpty ? null : _restrictions.text.trim(),
    };
    final connectors = [for (final c in _connectors) <String, Object?>{'connector_type': c.wire}];
    final ok = await runAction(context, () async {
      if (widget.point == null) {
        await repo.createPoint(widget.stationId, fields, connectors);
      } else {
        await repo.updatePoint(widget.point!.id, fields);
        await repo.setConnectors(widget.point!.id, connectors);
      }
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        builder: (context, scroll) => Form(
          key: _form,
          child: ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
            Text(widget.point == null ? 'Add charging point' : 'Edit ${widget.point!.code}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextFormField(controller: _code, decoration: const InputDecoration(labelText: 'Code (as labelled on the charger)'), validator: Validators.pointCode),
            const SizedBox(height: 12),
            TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Name (optional)')),
            const SizedBox(height: 12),
            SegmentedButton<CurrentType>(
              segments: [for (final c in CurrentType.values) ButtonSegment(value: c, label: Text(c.label))],
              selected: {_current},
              onSelectionChanged: (s) => setState(() => _current = s.first),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _power,
              decoration: const InputDecoration(labelText: 'Maximum power (kW)'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: Validators.decimalRange(0.5, 1000, field: 'Power'),
            ),
            const SizedBox(height: 12),
            Text('Vehicles', style: Theme.of(context).textTheme.titleSmall),
            Wrap(spacing: 8, children: [
              for (final v in VehicleCategory.values)
                FilterChip(label: Text(v.label), selected: _vehicles.contains(v), onSelected: (s) => setState(() => s ? _vehicles = {..._vehicles, v} : _vehicles = {..._vehicles}..remove(v))),
            ]),
            const SizedBox(height: 12),
            Text('Connectors', style: Theme.of(context).textTheme.titleSmall),
            for (var i = 0; i < _connectors.length; i++)
              Row(children: [
                Expanded(
                  child: DropdownButton<ConnectorType>(
                    isExpanded: true,
                    value: _connectors[i],
                    items: [for (final c in ConnectorType.values) DropdownMenuItem(value: c, child: Text(c.label))],
                    onChanged: (v) => setState(() => _connectors[i] = v ?? _connectors[i]),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove connector',
                  onPressed: _connectors.length == 1 ? null : () => setState(() => _connectors.removeAt(i)),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ]),
            if (_connectors.length < 8)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add connector'),
                  onPressed: () => setState(() => _connectors = [..._connectors, ConnectorType.ccs2]),
                ),
              ),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: _bookable, onChanged: (v) => setState(() => _bookable = v), title: const Text('Customers can book this point')),
            TextFormField(controller: _restrictions, decoration: const InputDecoration(labelText: 'Restrictions (optional)', hintText: 'e.g. Fleet vehicles only after 8 pm')),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ]),
        ),
      ),
    );
  }
}
