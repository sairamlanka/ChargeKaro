import 'package:flutter/foundation.dart';

import 'models.dart';

/// One planned charging stop.
@immutable
class TripStop {
  const TripStop({required this.station, required this.atKm, required this.arrivePercent, required this.leavePercent, required this.chargeMinutes});
  final StationSummary station;

  /// Distance along the route where the stop is.
  final double atKm;
  final int arrivePercent;
  final int leavePercent;
  final int chargeMinutes;
}

/// The charging stops for a trip, or where the battery would run out.
@immutable
class TripPlan {
  const TripPlan({required this.stops, required this.arrivePercent, this.stuckAtKm});
  final List<TripStop> stops;

  /// Battery left at the destination; null when it can't be reached.
  final int? arrivePercent;

  /// When no station is in reach: about where along the route the reserve
  /// would be hit.
  final double? stuckAtKm;

  bool get reachable => stuckAtKm == null;
  int get chargeMinutes => stops.fold(0, (a, s) => a + s.chargeMinutes);
}

/// Plans as few stops as possible: drive as far as the battery allows while
/// keeping [reservePercent], stop at the reachable station that gets furthest
/// along the route (a detour off the route counts both ways), and charge only
/// as much as the rest of the trip needs, up to [chargeToPercent].
/// Station power is the station's best charger (7.4 kW when unknown), with
/// the same 15% allowance as the charge estimate. Pure, for tests.
TripPlan planChargingStops({
  required double distanceKm,
  required List<StationSummary> stations,
  required VehicleProfile vehicle,
  required int startPercent,
  int reservePercent = 10,
}) {
  final range = vehicle.fullRangeKm;
  final chargeTo = vehicle.toPercent.clamp(reservePercent + 5, 100);
  double pctFor(double km) => km / range * 100;
  final candidates = [
    for (final s in stations)
      if (s.alongRouteKm != null && s.alongRouteKm! > 0 && s.alongRouteKm! < distanceKm) s,
  ]..sort((a, b) => a.alongRouteKm!.compareTo(b.alongRouteKm!));

  final stops = <TripStop>[];
  var pos = 0.0;
  var pct = startPercent.toDouble();
  final used = <String>{};
  for (var i = 0; i < 25; i++) {
    final reach = (pct - reservePercent) / 100 * range;
    if (pos + reach >= distanceKm) {
      return TripPlan(stops: stops, arrivePercent: (pct - pctFor(distanceKm - pos)).floor());
    }
    StationSummary? best;
    double bestProgress = pos;
    for (final s in candidates) {
      if (used.contains(s.id) || s.alongRouteKm! <= pos) continue;
      final off = s.offRouteKm ?? 0;
      if (s.alongRouteKm! - pos + off > reach) continue;
      final progress = s.alongRouteKm! - off;
      final better = progress > bestProgress + 0.01 ||
          (best != null && (progress - bestProgress).abs() <= 0.01 && (s.maxPowerKw ?? 0) > (best.maxPowerKw ?? 0));
      if (better) {
        best = s;
        bestProgress = progress;
      }
    }
    if (best == null) return TripPlan(stops: stops, arrivePercent: null, stuckAtKm: pos + (reach < 0 ? 0 : reach));
    final off = best.offRouteKm ?? 0;
    final arrive = pct - pctFor(best.alongRouteKm! - pos + off);
    // Enough to finish (back to the route, then the rest) with the reserve.
    final needed = pctFor(off + distanceKm - best.alongRouteKm!) + reservePercent;
    final leave = needed.ceilToDouble().clamp(arrive, chargeTo.toDouble());
    if (leave <= arrive + 0.5 && stops.isNotEmpty && stops.last.station.id == best.id) break;
    final power = (best.maxPowerKw ?? 7.4) * ChargeEstimate.efficiency;
    final kwh = vehicle.batteryKwh * (leave - arrive) / 100;
    stops.add(TripStop(
      station: best,
      atKm: best.alongRouteKm!,
      arrivePercent: arrive.floor(),
      leavePercent: leave.round(),
      chargeMinutes: power <= 0 ? 0 : (kwh / power * 60).ceil(),
    ));
    used.add(best.id);
    pos = best.alongRouteKm!;
    pct = leave - pctFor(off);
  }
  return TripPlan(stops: stops, arrivePercent: null, stuckAtKm: pos);
}
