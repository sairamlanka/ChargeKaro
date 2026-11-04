import 'package:flutter_test/flutter_test.dart';
import 'package:retailer_app/data/models.dart';
import 'package:retailer_app/data/trip_planner.dart';

import 'support.dart';

StationSummary _at(String id, double km, {double off = 0, double kw = 60}) =>
    StationSummary.fromJson({...stationJson(id: id), 'along_route_km': km, 'off_route_km': off, 'max_power_kw': kw});

void main() {
  // 40 kWh car, 300 km on a full battery, charges to 80%.
  const car = VehicleProfile(batteryKwh: 40, rangeKm: 300);

  test('a short trip needs no stop and says what is left', () {
    final p = planChargingStops(distanceKm: 120, stations: [_at('a', 60)], vehicle: car, startPercent: 80);
    expect(p.reachable, isTrue);
    expect(p.stops, isEmpty);
    expect(p.arrivePercent, 40);
  });

  test('stops at the furthest reachable station and charges only what is needed', () {
    // From 80% with a 10% reserve the car reaches 210 km.
    final p = planChargingStops(
      distanceKm: 400,
      stations: [_at('near', 50), _at('mid', 150), _at('far', 200), _at('beyond', 260)],
      vehicle: car,
      startPercent: 80,
    );
    expect(p.reachable, isTrue);
    expect(p.stops.map((s) => s.station.id), ['far']);
    final stop = p.stops.single;
    expect(stop.arrivePercent, 13);
    // 200 km left needs 67% plus the 10% reserve.
    expect(stop.leavePercent, 77);
    expect(stop.chargeMinutes, greaterThan(0));
    expect(p.arrivePercent, inInclusiveRange(9, 11));
  });

  test('a detour counts both ways; a gap in stations is reported', () {
    final p = planChargingStops(distanceKm: 500, stations: [_at('detour', 205, off: 8), _at('on', 190)], vehicle: car, startPercent: 80);
    expect(p.stops.first.station.id, 'on', reason: '205 km + 8 km off the route is out of reach');

    final gap = planChargingStops(distanceKm: 800, stations: [_at('only', 180)], vehicle: car, startPercent: 80);
    expect(gap.reachable, isFalse);
    expect(gap.stops.single.station.id, 'only');
    expect(gap.stuckAtKm, closeTo(180 + 210, 1));
  });

  test('range is guessed from the battery until set', () {
    expect(const VehicleProfile(batteryKwh: 3).fullRangeKm, 90);
    expect(const VehicleProfile(batteryKwh: 40).fullRangeKm, 260);
    final saved = VehicleProfile.fromJson(const VehicleProfile(batteryKwh: 40).copyWith(rangeKm: 320).toJson());
    expect(saved.fullRangeKm, 320);
  });
}
