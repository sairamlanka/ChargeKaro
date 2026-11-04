import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/format.dart';

/// How long the charge will take and what it will cost at the station, from
/// the customer's battery size and the station's chargers and prices.
class ChargeEstimateCard extends ConsumerWidget {
  const ChargeEstimateCard({super.key, required this.detail, this.minutes, this.connector});
  final StationDetail detail;
  final int? minutes;
  final String? connector;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final vehicle = ref.watch(vehicleProvider);
    final points = detail.points
        .where((p) => p.bookable && (connector == null || p.connectors.any((c) => c.type.wire == connector)))
        .toList();
    if (points.isEmpty) return const SizedBox.shrink();

    if (vehicle == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(Icons.calculate_outlined, color: t.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text(l(K.estimateAddVehicle), style: t.textTheme.bodySmall)),
            const SizedBox(width: 8),
            TextButton(onPressed: () => editVehicle(context, ref), child: Text(l(K.estimateSetVehicle))),
          ]),
        ),
      );
    }

    final power = points.map((p) => p.maxPowerKw).reduce((a, b) => a > b ? a : b);
    final prices = [for (final p in points) ?p.pricePerKwh];
    final e = ChargeEstimate.of(vehicle, powerKw: power, slotMinutes: minutes, prices: prices);
    String kwh(double v) => v.toStringAsFixed(v >= 10 ? 0 : 1);
    final costLine = e.lowCost == null
        ? l(K.estimateNoPrice)
        : e.lowCost == e.highCost
            ? l(K.estimateCost, {'amount': e.lowCost!.format(), 'price': e.lowPrice!.format()})
            : l(K.estimateCostRange, {'low': e.lowCost!.format(), 'high': e.highCost!.format()});

    return SectionCard(
      title: l(K.estimateTitle),
      trailing: TextButton(onPressed: () => editVehicle(context, ref), child: Text(l(K.change))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Line(Icons.battery_charging_full_rounded, l(K.estimateEnergy, {'kwh': kwh(e.energyKwh), 'from': vehicle.fromPercent, 'to': vehicle.toPercent})),
        _Line(Icons.timer_outlined, l(K.estimateTime, {'time': f.duration(Duration(minutes: e.fullMinutes)), 'kw': f.power(power).replaceAll(' kW', '')})),
        _Line(Icons.currency_rupee_rounded, costLine, strong: e.lowCost != null),
        if (e.slotTooShort && minutes != null)
          _Line(Icons.info_outline_rounded, l(K.estimateSlotShort, {
            'slot': f.duration(Duration(minutes: minutes!)),
            'kwh': kwh(e.slotKwh!),
            'need': f.duration(Duration(minutes: e.fullMinutes)),
            'to': vehicle.toPercent,
          }), warn: true),
        const SizedBox(height: 6),
        Text(l(K.estimateNote), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text, {this.strong = false, this.warn = false});
  final IconData icon;
  final String text;
  final bool strong;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = warn ? t.colorScheme.error : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color ?? t.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: color, fontWeight: strong ? FontWeight.w700 : null)),
        ),
      ]),
    );
  }
}

/// Battery size and the usual charge range, saved on this device.
Future<void> editVehicle(BuildContext context, WidgetRef ref) async {
  final current = ref.read(vehicleProvider);
  final result = await showModalBottomSheet<VehicleProfile>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _VehicleSheet(initial: current),
  );
  if (result == null) return;
  await ref.read(vehicleProvider.notifier).set(result);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.l(K.vehicleSaved))));
  }
}

class _VehicleSheet extends StatefulWidget {
  const _VehicleSheet({this.initial});
  final VehicleProfile? initial;

  @override
  State<_VehicleSheet> createState() => _VehicleSheetState();
}

class _VehicleSheetState extends State<_VehicleSheet> {
  late final _kwh = TextEditingController(text: widget.initial == null ? '' : _trim(widget.initial!.batteryKwh));
  late RangeValues _range = RangeValues((widget.initial?.fromPercent ?? 20).toDouble(), (widget.initial?.toPercent ?? 80).toDouble());
  String? _error;

  static String _trim(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _kwh.dispose();
    super.dispose();
  }

  void _save() {
    final v = double.tryParse(_kwh.text.trim().replaceAll(',', '.'));
    if (v == null || v < 2 || v > 250) {
      setState(() => _error = context.l(K.batteryInvalid));
      return;
    }
    Navigator.of(context).pop(VehicleProfile(batteryKwh: v, fromPercent: _range.start.round(), toPercent: _range.end.round(), rangeKm: widget.initial?.rangeKm));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l(K.myVehicle), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextField(
            controller: _kwh,
            autofocus: widget.initial == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            decoration: InputDecoration(
              labelText: l(K.batterySize),
              helperText: l(K.batteryHint),
              errorText: _error,
              prefixIcon: const Icon(Icons.battery_full_rounded),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          Text(l(K.chargeFromTo, {'from': _range.start.round(), 'to': _range.end.round()}), style: t.textTheme.bodyMedium),
          RangeSlider(
            values: _range,
            min: 0,
            max: 100,
            divisions: 20,
            labels: RangeLabels('${_range.start.round()}%', '${_range.end.round()}%'),
            onChanged: (v) => setState(() => _range = v.end - v.start < 5 ? _range : v),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: Text(l(K.save))),
        ]),
      ),
    );
  }
}
