import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:retailer_app/data/local_store.dart';
import 'package:retailer_app/data/models.dart';
import 'package:retailer_app/data/reminders.dart';
import 'package:retailer_app/l10n/en.dart';
import 'package:retailer_app/l10n/l10n.dart';
import 'package:retailer_app/state/providers.dart';
import 'package:retailer_app/state/search.dart';
import 'package:shared_models/shared_models.dart';

import 'support.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en_IN'));
  Future<ProviderContainer> container(LocalStore store) async =>
      ProviderContainer(overrides: [localStoreProvider.overrideWithValue(store)]);

  test('favourite stations toggle and survive a restart', () async {
    final store = await LocalStore.memory();
    final c = await container(store);
    final s = StationSummary.fromJson(stationJson());
    expect(await c.read(favouriteStationsProvider.notifier).toggle(s), isTrue);
    expect(c.read(favouriteStationsProvider).single.id, 'st1');
    expect((await container(store)).read(favouriteStationsProvider).single.name, 'Banjara EV Hub');
    expect(await c.read(favouriteStationsProvider.notifier).toggle(s), isFalse);
    expect(store.favouriteStations(), isEmpty);
  });

  test('theme and text size are remembered', () async {
    final store = await LocalStore.memory();
    final c = await container(store);
    expect(c.read(appearanceProvider).themeMode, ThemeMode.system);
    await c.read(appearanceProvider.notifier).setThemeMode(ThemeMode.dark);
    await c.read(appearanceProvider.notifier).setTextScale(1.3);
    final again = (await container(store)).read(appearanceProvider);
    expect(again.themeMode, ThemeMode.dark);
    expect(again.textScale, 1.3);
  });

  test('24x7 filter matches round-the-clock hours; toilets need the amenity', () {
    final s = StationSummary.fromJson(stationJson());
    final now = DateTime.now();
    expect(const SearchFilters(amenities: {Amenity.open24x7}).matches(s, now), isTrue);
    expect(const SearchFilters(amenities: {Amenity.restroom}).matches(s, now), isFalse);
    final withToilet = StationSummary.fromJson({...stationJson(), 'amenities': ['restroom']});
    expect(const SearchFilters(amenities: {Amenity.restroom, Amenity.open24x7}).matches(withToilet, now), isTrue);
  });

  test('charge estimate: energy, time with losses, cost range and short slots', () {
    const car = VehicleProfile(batteryKwh: 40, fromPercent: 20, toPercent: 80);
    final e = ChargeEstimate.of(car, powerKw: 30, slotMinutes: 60, prices: [const Money(2000), const Money(1800)]);
    expect(e.energyKwh, closeTo(24, 0.001));
    expect(e.fullMinutes, 57); // 24 kWh at 30 kW x 0.85
    expect(e.slotTooShort, isFalse);
    expect(e.lowCost, const Money(43200));
    expect(e.highCost, const Money(48000));
    final short = ChargeEstimate.of(car, powerKw: 30, slotMinutes: 30);
    expect(short.slotTooShort, isTrue);
    expect(short.lowCost, isNull);
  });

  test('booking JSON carries reschedule and rating state; points carry price', () {
    final b = CustomerBooking.fromJson({
      ...bookingJson(),
      'reschedule_count': 1,
      'can_reschedule': false,
      'original_start_at': '2026-11-04T10:00:00Z',
      'my_rating': 4,
    });
    expect(b.rescheduleCount, 1);
    expect(b.canReschedule, isFalse);
    expect(b.originalStartAt, DateTime.utc(2026, 11, 4, 10));
    expect(b.myRating, 4);
    final d = StationDetail.fromJson({...stationJson(), 'points_detail': [{...(stationJson()['points_detail'] as List).first as Map<String, Object?>, 'price_per_kwh_paise': 1850}]});
    expect(d.points.single.pricePerKwh, const Money(1850));
    final r = StationReviews.fromJson({'average': 4.5, 'count': 2, 'stars': {'5': 1, '4': 1}, 'recent': [{'rating': 5, 'name': 'Asha', 'comment': 'Good', 'created_at': '2026-11-04T10:00:00Z'}]});
    expect(r.stars[5], 1);
    expect(r.stars[1], 0);
    expect(r.recent.single.name, 'Asha');
  });

  test('reminders: 30 min before, check-in open, 5 min before the late window closes; only future, only confirmed', () {
    final now = DateTime.utc(2026, 11, 4, 8);
    final start = now.add(const Duration(hours: 2));
    final b = CustomerBooking.fromJson({
      ...bookingJson(),
      'id': 'b1',
      'start_at': start.toIso8601String(),
      'end_at': start.add(const Duration(minutes: 30)).toIso8601String(),
      'checkin_opens_at': start.subtract(const Duration(minutes: 60)).toIso8601String(),
      'checkin_closes_at': start.add(const Duration(minutes: 5)).toIso8601String(),
    });
    const l = L(Locale('en'), en);
    final plan = planReminders([b], l, now);
    expect(plan.map((r) => r.at).toList(), [
      start.subtract(const Duration(minutes: 30)),
      start.subtract(const Duration(minutes: 60)),
      start,
    ]);
    expect(plan.first.title, 'Your charging slot starts in 30 minutes');
    expect(plan.map((r) => r.id).toSet().length, 3);
    expect(planReminders([b], l, start.subtract(const Duration(minutes: 10))).length, 1, reason: 'only the closing one is still ahead');
    final cancelled = CustomerBooking.fromJson({...bookingJson(status: 'cancelled'), 'start_at': start.toIso8601String(), 'end_at': start.add(const Duration(minutes: 30)).toIso8601String()});
    expect(planReminders([cancelled], l, now), isEmpty);
  });
}
