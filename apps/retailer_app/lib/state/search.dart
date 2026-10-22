import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_models/shared_models.dart';

import '../data/local_store.dart';
import '../data/location_service.dart';
import '../data/models.dart';
import 'providers.dart';

enum SortOrder { nearest, earliestSlot, lowestFee, mostAvailable }

enum ViewMode { list, map }

/// Where the current search is centred.
@immutable
class SearchOrigin {
  const SearchOrigin({required this.label, required this.latitude, required this.longitude, required this.fromDevice, this.location});
  final String label;
  final double latitude;
  final double longitude;
  final bool fromDevice;

  /// Set when the origin came from the device: accuracy and freshness.
  final LocationFound? location;
}

@immutable
class SearchFilters {
  const SearchFilters({
    this.connectors = const {},
    this.minPowerKw,
    this.availableNow = false,
    this.openNow = false,
    this.freeToday = false,
    this.amenities = const {},
    this.vehicle,
    this.bookableOnly = false,
  });

  final Set<ConnectorType> connectors;
  final double? minPowerKw;
  final bool availableNow;
  final bool openNow;

  /// Has a bookable start today (from the station's next free slot).
  final bool freeToday;
  final Set<Amenity> amenities;
  final VehicleCategory? vehicle;
  final bool bookableOnly;

  int get count =>
      connectors.length + (minPowerKw == null ? 0 : 1) + (availableNow ? 1 : 0) + (openNow ? 1 : 0) + (freeToday ? 1 : 0) + amenities.length +
      (vehicle == null ? 0 : 1) + (bookableOnly ? 1 : 0);

  bool get isEmpty => count == 0;

  bool matches(StationSummary s, DateTime now) {
    if (connectors.isNotEmpty && !s.connectorTypes.any(connectors.contains)) return false;
    if (minPowerKw != null && (s.maxPowerKw ?? 0) < minPowerKw!) return false;
    if (availableNow && !(s.open.openNow && s.points.available > 0 && s.bookable)) return false;
    if (openNow && !s.open.openNow) return false;
    if (freeToday) {
      final next = s.nextAvailable?.startAt;
      if (next == null) return false;
      final a = next.toUtc().add(const Duration(hours: 5, minutes: 30));
      final b = now.toUtc().add(const Duration(hours: 5, minutes: 30));
      if (a.year != b.year || a.month != b.month || a.day != b.day) return false;
    }
    if (amenities.isNotEmpty && !amenities.every(s.amenities.contains)) return false;
    if (vehicle != null && s.vehicleTypes.isNotEmpty && !s.vehicleTypes.contains(vehicle)) return false;
    if (bookableOnly && !s.bookable) return false;
    return true;
  }

  SearchFilters copyWith({
    Set<ConnectorType>? connectors,
    double? Function()? minPowerKw,
    bool? availableNow,
    bool? openNow,
    bool? freeToday,
    Set<Amenity>? amenities,
    VehicleCategory? Function()? vehicle,
    bool? bookableOnly,
  }) =>
      SearchFilters(
        connectors: connectors ?? this.connectors,
        minPowerKw: minPowerKw == null ? this.minPowerKw : minPowerKw(),
        availableNow: availableNow ?? this.availableNow,
        openNow: openNow ?? this.openNow,
        freeToday: freeToday ?? this.freeToday,
        amenities: amenities ?? this.amenities,
        vehicle: vehicle == null ? this.vehicle : vehicle(),
        bookableOnly: bookableOnly ?? this.bookableOnly,
      );
}

enum LocatingState { idle, locating }

@immutable
class SearchState {
  const SearchState({
    this.origin,
    this.radiusKm = defaultRadiusKm,
    this.sort = SortOrder.nearest,
    this.filters = const SearchFilters(),
    this.view = ViewMode.list,
    this.result,
    this.locating = LocatingState.idle,
    this.locationProblem,
    this.refreshFailed = false,
  });

  static const defaultRadiusKm = 5.0;
  static const radiusOptions = [2.0, 5.0, 10.0, 25.0, 50.0];

  final SearchOrigin? origin;
  final double radiusKm;
  final SortOrder sort;
  final SearchFilters filters;
  final ViewMode view;

  /// Null until a search has been started.
  final AsyncValue<SearchResult>? result;
  final LocatingState locating;
  final LocationProblem? locationProblem;

  /// The last refresh failed while older results are still shown.
  final bool refreshFailed;

  List<StationSummary> visible(DateTime now) {
    final all = result?.value?.stations ?? const <StationSummary>[];
    final list = all.where((s) => filters.matches(s, now)).toList();
    int byDistance(StationSummary a, StationSummary b) => (a.distanceKm ?? 1e9).compareTo(b.distanceKm ?? 1e9);
    switch (sort) {
      case SortOrder.nearest:
        list.sort(byDistance);
      case SortOrder.earliestSlot:
        list.sort((a, b) {
          final x = a.nextAvailable?.startAt;
          final y = b.nextAvailable?.startAt;
          if (x == null && y == null) return byDistance(a, b);
          if (x == null) return 1;
          if (y == null) return -1;
          final c = x.compareTo(y);
          return c != 0 ? c : byDistance(a, b);
        });
      case SortOrder.lowestFee:
        list.sort((a, b) {
          final c = a.bookingFee.compareTo(b.bookingFee);
          return c != 0 ? c : byDistance(a, b);
        });
      case SortOrder.mostAvailable:
        list.sort((a, b) {
          final c = b.points.available.compareTo(a.points.available);
          return c != 0 ? c : byDistance(a, b);
        });
    }
    // Bookable stations first, keeping the chosen order within each group.
    final bookable = list.where((s) => s.bookable).toList();
    final others = list.where((s) => !s.bookable).toList();
    return [...bookable, ...others];
  }

  SearchState copyWith({
    SearchOrigin? origin,
    double? radiusKm,
    SortOrder? sort,
    SearchFilters? filters,
    ViewMode? view,
    AsyncValue<SearchResult>? result,
    LocatingState? locating,
    LocationProblem? Function()? locationProblem,
    bool? refreshFailed,
  }) =>
      SearchState(
        origin: origin ?? this.origin,
        radiusKm: radiusKm ?? this.radiusKm,
        sort: sort ?? this.sort,
        filters: filters ?? this.filters,
        view: view ?? this.view,
        result: result ?? this.result,
        locating: locating ?? this.locating,
        locationProblem: locationProblem == null ? this.locationProblem : locationProblem(),
        refreshFailed: refreshFailed ?? this.refreshFailed,
      );
}

final searchProvider = NotifierProvider<SearchController, SearchState>(SearchController.new);

class SearchController extends Notifier<SearchState> {
  int _generation = 0;

  @override
  SearchState build() {
    final saved = ref.read(localStoreProvider).lastSearch();
    if (saved == null) return const SearchState();
    // Restore the last area so returning users land on familiar results.
    // A device location is not re-used silently: it may be far away now.
    if (saved.fromDevice) return SearchState(radiusKm: saved.radiusKm);
    final s = SearchState(
      origin: SearchOrigin(label: saved.label, latitude: saved.latitude, longitude: saved.longitude, fromDevice: false),
      radiusKm: saved.radiusKm,
    );
    Future.microtask(_run);
    return s;
  }

  /// Asks for the device location, then searches around it.
  Future<void> useCurrentLocation() async {
    state = state.copyWith(locating: LocatingState.locating, locationProblem: () => null);
    final outcome = await ref.read(locationServiceProvider).current();
    if (!ref.mounted) return;
    switch (outcome) {
      case LocationFound():
        state = state.copyWith(
          locating: LocatingState.idle,
          origin: SearchOrigin(label: '', latitude: outcome.latitude, longitude: outcome.longitude, fromDevice: true, location: outcome),
        );
        await _run();
      case LocationFailed(:final problem):
        state = state.copyWith(locating: LocatingState.idle, locationProblem: () => problem);
    }
  }

  Future<void> setArea(AreaMatch area) async {
    state = state.copyWith(
      origin: SearchOrigin(label: area.label, latitude: area.latitude, longitude: area.longitude, fromDevice: false),
      locationProblem: () => null,
    );
    await _run();
  }

  Future<void> setRadius(double km) async {
    if (km == state.radiusKm) return;
    state = state.copyWith(radiusKm: km);
    if (state.origin != null) await _run();
  }

  Future<void> refresh() => _run(keepOld: true);

  void setSort(SortOrder s) => state = state.copyWith(sort: s);
  void setFilters(SearchFilters f) => state = state.copyWith(filters: f);
  void clearFilters() => state = state.copyWith(filters: const SearchFilters());
  void setView(ViewMode v) => state = state.copyWith(view: v);
  void dismissLocationProblem() => state = state.copyWith(locationProblem: () => null);

  Future<void> _run({bool keepOld = false}) async {
    final origin = state.origin;
    if (origin == null) return;
    final gen = ++_generation;
    final old = state.result;
    state = state.copyWith(
      result: keepOld && old?.value != null ? AsyncValue<SearchResult>.data(old!.value!) : const AsyncValue<SearchResult>.loading(),
      refreshFailed: false,
    );
    unawaited(ref.read(localStoreProvider).saveSearch(
          SavedSearch(label: origin.label, latitude: origin.latitude, longitude: origin.longitude, radiusKm: state.radiusKm, fromDevice: origin.fromDevice),
        ));
    try {
      final r = await ref.read(retailRepositoryProvider).searchStations(origin.latitude, origin.longitude, state.radiusKm);
      if (!ref.mounted || gen != _generation) return;
      state = state.copyWith(result: AsyncValue.data(r));
    } catch (e, st) {
      if (!ref.mounted || gen != _generation) return;
      if (keepOld && old?.value != null) {
        state = state.copyWith(result: AsyncValue.data(old!.value!), refreshFailed: true);
      } else {
        state = state.copyWith(result: AsyncValue.error(e, st));
      }
    }
  }
}
