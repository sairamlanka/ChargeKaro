import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../data/trip_planner.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import '../station/estimate.dart';

/// Where to charge on the chosen route: the stations from the route search
/// (with its filters and distance from the route), the battery when leaving
/// and the vehicle's range.
class TripPlannerScreen extends ConsumerStatefulWidget {
  const TripPlannerScreen({super.key});

  @override
  ConsumerState<TripPlannerScreen> createState() => _TripPlannerScreenState();
}

class _TripPlannerScreenState extends ConsumerState<TripPlannerScreen> {
  double _startPercent = 80;
  TextEditingController? _range;

  @override
  void dispose() {
    _range?.dispose();
    super.dispose();
  }

  void _saveRange(String text) {
    final v = double.tryParse(text.trim());
    final vehicle = ref.read(vehicleProvider);
    if (vehicle == null || v == null || v < 20 || v > 1500) return;
    ref.read(vehicleProvider.notifier).set(vehicle.copyWith(rangeKm: v));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final s = ref.watch(searchProvider);
    final vehicle = ref.watch(vehicleProvider);
    final plan = s.isTrip ? s.trip?.plan : null;

    Widget body;
    if (plan == null) {
      body = FallbackView(icon: Icons.alt_route_rounded, title: l(K.tripPlanTitle), message: l(K.tripNoRoute));
    } else if (vehicle == null) {
      body = FallbackView(
        icon: Icons.battery_unknown_rounded,
        title: l(K.tripPlanTitle),
        message: l(K.tripNeedVehicle),
        actions: [FallbackAction(l(K.estimateSetVehicle), () => editVehicle(context, ref), primary: true)],
      );
    } else {
      _range ??= TextEditingController(text: vehicle.fullRangeKm.round().toString());
      final result = planChargingStops(
        distanceKm: plan.distanceKm,
        stations: s.visible(DateTime.now()),
        vehicle: vehicle,
        startPercent: _startPercent.round(),
      );
      body = ListView(padding: const EdgeInsets.all(16), children: [
        Text(l(K.tripSummary, {'from': s.trip!.from.fromDevice ? l(K.yourLocation) : s.trip!.from.label, 'to': s.trip!.to.label}),
            style: t.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
        Text(l(K.routeLength, {'km': plan.distanceKm.toStringAsFixed(0), 'time': f.duration(Duration(minutes: plan.durationMinutes))}),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        Text(l(K.tripChargeNow, {'pct': _startPercent.round()}), style: t.textTheme.bodyMedium),
        Slider(
          value: _startPercent,
          min: 15,
          max: 100,
          divisions: 17,
          label: '${_startPercent.round()}%',
          onChanged: (v) => setState(() => _startPercent = v),
        ),
        TextField(
          controller: _range,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: l(K.tripRange), helperText: l(K.tripRangeHint), helperMaxLines: 2, prefixIcon: const Icon(Icons.route_rounded)),
          onChanged: (v) {
            _saveRange(v);
            setState(() {});
          },
        ),
        const SizedBox(height: 16),
        _Summary(result: result),
        for (final (i, stop) in result.stops.indexed) _StopCard(n: i + 1, stop: stop),
        const SizedBox(height: 8),
        Text(l(K.tripNote), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]);
    }
    return Scaffold(appBar: AppBar(title: Text(l(K.tripPlanTitle))), body: SafeArea(child: body));
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.result});
  final TripPlan result;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final (text, tone, icon) = !result.reachable
        ? (l(K.tripStuck, {'km': result.stuckAtKm!.toStringAsFixed(0)}), StatusTone.warning, Icons.battery_alert_rounded)
        : result.stops.isEmpty
            ? (l(K.tripNoStops, {'pct': result.arrivePercent}), StatusTone.success, Icons.check_circle_rounded)
            : (
                l(K.tripPlanSummary, {
                  'n': result.stops.length,
                  'time': f.duration(Duration(minutes: result.chargeMinutes)),
                  'pct': result.arrivePercent,
                }),
                StatusTone.info,
                Icons.ev_station_rounded,
              );
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: Pill(text, icon: icon, tone: tone));
  }
}

class _StopCard extends StatelessWidget {
  const _StopCard({required this.n, required this.stop});
  final int n;
  final TripStop stop;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final s = stop.station;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l(K.tripStopN, {'n': n, 'km': stop.atKm.toStringAsFixed(0)}), style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
          const SizedBox(height: 4),
          Text(s.name, style: t.textTheme.titleMedium),
          Text(s.city, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          if (s.offRouteKm != null && s.offRouteKm! > onRouteKm)
            Text(l(K.offRoute, {'d': f.distance(s.offRouteKm!)}), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Row(children: [
            Icon(Icons.battery_charging_full_rounded, size: 18, color: t.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l(K.tripStopCharge, {
                'from': stop.arrivePercent,
                'to': stop.leavePercent,
                'time': f.duration(Duration(minutes: stop.chargeMinutes)),
              })),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(onPressed: () => context.push('/station/${s.id}'), child: Text(l(K.tripOpenStation))),
          ),
        ]),
      ),
    );
  }
}
