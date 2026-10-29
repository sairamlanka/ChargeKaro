import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_models/shared_models.dart';

import '../../l10n/l10n.dart';
import '../../state/search.dart';

const _powerSteps = <double?>[null, 7, 22, 50];

List<String> activeFilterLabels(L l, SearchFilters f) => [
      for (final c in f.connectors) c.label,
      if (f.minPowerKw != null) l(K.filterPowerAtLeast, {'kw': f.minPowerKw!.toStringAsFixed(0)}),
      if (f.availableNow) l(K.filterAvailableNow),
      if (f.openNow) l(K.filterOpenNow),
      if (f.freeToday) l(K.filterFreeToday),
      if (f.bookableOnly) l(K.filterBookableOnly),
      if (f.vehicle != null) f.vehicle!.label,
      for (final a in f.amenities) a.label,
    ];

Future<void> showFilterSheet(BuildContext context, WidgetRef ref) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _FilterSheet(initial: ref.read(searchProvider).filters, onApply: ref.read(searchProvider.notifier).setFilters),
    );

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial, required this.onApply});
  final SearchFilters initial;
  final ValueChanged<SearchFilters> onApply;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late SearchFilters f = widget.initial;

  static const _connectors = [
    ConnectorType.ccs2,
    ConnectorType.type2Ac,
    ConnectorType.chademo,
    ConnectorType.bharatAc001,
    ConnectorType.bharatDc001,
    ConnectorType.gbT,
    ConnectorType.type6Lev,
    ConnectorType.threePinSocket,
  ];
  static const _amenities = [Amenity.restroom, Amenity.cafe, Amenity.coveredParking, Amenity.wheelchairAccessible, Amenity.wifi, Amenity.cctv];
  static const _vehicles = [VehicleCategory.twoWheeler, VehicleCategory.threeWheeler, VehicleCategory.fourWheeler];

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    Widget section(String title) => Padding(padding: const EdgeInsets.fromLTRB(0, 18, 0, 8), child: Text(title, style: t.textTheme.titleSmall));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(children: [
        Expanded(
          child: ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), children: [
            Row(children: [
              Expanded(child: Text(l(K.filters), style: t.textTheme.titleLarge)),
              TextButton(onPressed: () => setState(() => f = const SearchFilters()), child: Text(l(K.clearFilters))),
            ]),
            section(l(K.filterAvailability)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(l(K.filterAvailableNow)), subtitle: Text(l(K.filterAvailableNowHint)), value: f.availableNow, onChanged: (v) => setState(() => f = f.copyWith(availableNow: v))),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(l(K.filterFreeToday)), value: f.freeToday, onChanged: (v) => setState(() => f = f.copyWith(freeToday: v))),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(l(K.filterOpenNow)), value: f.openNow, onChanged: (v) => setState(() => f = f.copyWith(openNow: v))),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(l(K.filterBookableOnly)), value: f.bookableOnly, onChanged: (v) => setState(() => f = f.copyWith(bookableOnly: v))),
            section(l(K.filterConnector)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in _connectors)
                FilterChip(
                  label: Text(c.label),
                  selected: f.connectors.contains(c),
                  onSelected: (v) => setState(() => f = f.copyWith(connectors: v ? {...f.connectors, c} : ({...f.connectors}..remove(c)))),
                ),
            ]),
            section(l(K.filterPower)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in _powerSteps)
                ChoiceChip(
                  label: Text(p == null ? l(K.any) : l(K.filterPowerAtLeast, {'kw': p.toStringAsFixed(0)})),
                  selected: f.minPowerKw == p,
                  onSelected: (_) => setState(() => f = f.copyWith(minPowerKw: () => p)),
                ),
            ]),
            section(l(K.filterVehicle)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(label: Text(l(K.any)), selected: f.vehicle == null, onSelected: (_) => setState(() => f = f.copyWith(vehicle: () => null))),
              for (final v in _vehicles)
                ChoiceChip(label: Text(v.label), selected: f.vehicle == v, onSelected: (_) => setState(() => f = f.copyWith(vehicle: () => v))),
            ]),
            section(l(K.filterFacilities)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final a in _amenities)
                FilterChip(
                  label: Text(a.label),
                  selected: f.amenities.contains(a),
                  onSelected: (v) => setState(() => f = f.copyWith(amenities: v ? {...f.amenities, a} : ({...f.amenities}..remove(a)))),
                ),
            ]),
            const SizedBox(height: 8),
            Text(l(K.feeUniformNote), style: t.textTheme.bodySmall),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  widget.onApply(f);
                  Navigator.of(context).pop();
                },
                child: Text(l(K.showResults)),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
