import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_models/shared_models.dart';

import '../data/local_store.dart';
import '../data/location_service.dart';
import '../data/models.dart';
import 'providers.dart';

/// [bestStop] is for Along My Route only; Near Me treats it as [nearest].
enum SortOrder { bestStop, nearest, earliestSlot, lowestFee, mostAvailable }

enum ViewMode { list, map }

/// The two ways to find stations. Each has its own inputs, query and
/// results; the customer uses one at a time.
/// * route (Along My Route): source + destination, stations near the route.
/// * nearby (Near Me): the device location (or a place picked by hand when
///   location is unavailable), stations within a radius.
enum SearchMode { route, nearby }

/// Where a Near Me search is centred: the device, or a place picked by hand.
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

/// An Along My Route search. [routes] is null while the routes are being
/// worked out (or when that failed); [selected] is the one the customer is
/// looking at.
@immutable
class Trip {
  const Trip({required this.from, required this.to, this.routes, this.selected = 0});
  final TripPlace from;
  final TripPlace to;
  final List<RoutePlan>? routes;
  final int selected;

  RoutePlan? get plan => routes == null || routes!.isEmpty ? null : routes![selected.clamp(0, routes!.length - 1)];
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
    this.mode = SearchMode.route,
    this.origin,
    this.trip,
    this.radiusKm,
    this.corridorKm,
    this.sort = SortOrder.bestStop,
    this.filters = const SearchFilters(),
    this.view = ViewMode.list,
    this.result,
    this.driving = const {},
    this.locating = LocatingState.idle,
    this.locationProblem,
    this.refreshFailed = false,
  });

  /// Used only until the server reports its default (platform settings
  /// nearby_radius_km and route_corridor_km).
  static const fallbackKm = 5.0;
  static const radiusOptions = [2.0, 5.0, 10.0, 25.0, 50.0];
  static const corridorOptions = [1.0, 2.0, 5.0, 10.0];

  /// Which search is shown. Both are kept, so switching back and forth does
  /// not lose the trip or the location, but only the active one's results
  /// are ever on screen.
  final SearchMode mode;

  /// The Near Me search, if one has been made.
  final SearchOrigin? origin;

  /// The Along My Route search, if one has been made.
  final Trip? trip;

  /// Distances the customer picked; null means the server default.
  final double? radiusKm;
  final double? corridorKm;
  final SortOrder sort;
  final SearchFilters filters;
  final ViewMode view;

  /// Results of the active search. Null until it has been started.
  final AsyncValue<SearchResult>? result;

  /// Near Me: driving distance by station id, filled in after the results.
  final Map<String, DrivingDistance> driving;
  final LocatingState locating;
  final LocationProblem? locationProblem;

  /// The last refresh failed while older results are still shown.
  final bool refreshFailed;

  bool get active => mode == SearchMode.route ? trip != null : origin != null;
  bool get isTrip => mode == SearchMode.route && trip != null;
  bool get isNearby => mode == SearchMode.nearby && origin != null;

  /// The distance in use: radius (Near Me) or distance from the route.
  double get rangeKm => (isTrip ? corridorKm : radiusKm) ?? result?.value?.radiusKm ?? fallbackKm;
  List<double> get rangeOptions {
    final base = mode == SearchMode.route ? corridorOptions : radiusOptions;
    return base.contains(rangeKm) ? base : ([...base, rangeKm]..sort());
  }

  SortOrder get effectiveSort => sort == SortOrder.bestStop && mode == SearchMode.nearby ? SortOrder.nearest : sort;

  /// Where distances to a station are measured from: the search centre, or
  /// the start of the trip.
  ({double latitude, double longitude})? get anchor => isNearby
      ? (latitude: origin!.latitude, longitude: origin!.longitude)
      : isTrip
          ? (latitude: trip!.from.latitude, longitude: trip!.from.longitude)
          : null;

  /// Along My Route: when the driver should reach [s], leaving now, from
  /// the route's driving time. Null outside a trip.
  DateTime? arrival(StationSummary s, DateTime now) {
    final plan = isTrip ? trip!.plan : null;
    final along = s.alongRouteKm;
    if (plan == null || along == null || plan.distanceKm <= 0) return null;
    final share = (along / plan.distanceKm).clamp(0.0, 1.0);
    return now.add(Duration(minutes: (plan.durationMinutes * share).round()));
  }

  /// Near Me: open now. Along My Route: open when the driver gets there, so
  /// a station 300 km away that opens in two hours is still listed.
  bool isOpenFor(StationSummary s, DateTime now) {
    final at = arrival(s, now);
    return at == null ? s.open.openNow : s.openAt(at);
  }

  List<StationSummary> visible(DateTime now) {
    final all = result?.value?.stations ?? const <StationSummary>[];
    // Only stations open when the customer can get there are listed; a
    // closed station can't be charged at, so it would only add noise.
    final list = all.where((s) => isOpenFor(s, now) && filters.matches(s, now)).toList();
    // On a trip "nearest" means the first one the driver reaches.
    int byDistance(StationSummary a, StationSummary b) => (a.alongRouteKm ?? a.distanceKm ?? 1e9).compareTo(b.alongRouteKm ?? b.distanceKm ?? 1e9);
    switch (effectiveSort) {
      case SortOrder.bestStop:
        // Free points now, then on the route before a detour, then the
        // smallest detour (to the nearest km), then trip order.
        int rank(StationSummary s) => s.points.available > 0 ? 0 : 1;
        int detour(StationSummary s) => (s.offRouteKm ?? 0) <= onRouteKm ? 0 : 1 + (s.offRouteKm ?? 0).ceil();
        list.sort((a, b) {
          var c = rank(a).compareTo(rank(b));
          if (c == 0) c = detour(a).compareTo(detour(b));
          return c != 0 ? c : byDistance(a, b);
        });
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
    SearchMode? mode,
    SearchOrigin? Function()? origin,
    Trip? Function()? trip,
    double? radiusKm,
    double? corridorKm,
    SortOrder? sort,
    SearchFilters? filters,
    ViewMode? view,
    AsyncValue<SearchResult>? Function()? result,
    Map<String, DrivingDistance>? driving,
    LocatingState? locating,
    LocationProblem? Function()? locationProblem,
    bool? refreshFailed,
  }) =>
      SearchState(
        mode: mode ?? this.mode,
        origin: origin == null ? this.origin : origin(),
        trip: trip == null ? this.trip : trip(),
        radiusKm: radiusKm ?? this.radiusKm,
        corridorKm: corridorKm ?? this.corridorKm,
        sort: sort ?? this.sort,
        filters: filters ?? this.filters,
        view: view ?? this.view,
        result: result == null ? this.result : result(),
        driving: driving ?? this.driving,
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
    final corridor = SearchState.corridorOptions.contains(saved.corridorKm) ? saved.corridorKm : null;
    final radius = SearchState.radiusOptions.contains(saved.radiusKm) ? saved.radiusKm : null;
    if (saved.isTrip) {
      // Restore the last trip so returning users land on familiar results.
      final s = SearchState(trip: Trip(from: saved.from!, to: saved.to!), radiusKm: radius, corridorKm: corridor);
      Future.microtask(_run);
      return s;
    }
    if (saved.fromDevice) {
      // A device location is not re-used silently: it may be far away now,
      // so Near Me reopens and waits for a tap.
      return SearchState(mode: SearchMode.nearby, radiusKm: radius, corridorKm: corridor);
    }
    // A place picked by hand for Near Me (older versions: an area search).
    final s = SearchState(
      mode: SearchMode.nearby,
      origin: SearchOrigin(label: saved.label, latitude: saved.latitude, longitude: saved.longitude, fromDevice: false),
      radiusKm: radius,
      corridorKm: corridor,
    );
    Future.microtask(_run);
    return s;
  }

  /// Near Me: asks for the device location, then searches around it.
  Future<void> useCurrentLocation() async {
    _enter(SearchMode.nearby);
    state = state.copyWith(locating: LocatingState.locating, locationProblem: () => null);
    final outcome = await ref.read(locationServiceProvider).current();
    if (!ref.mounted) return;
    switch (outcome) {
      case LocationFound():
        state = state.copyWith(
          locating: LocatingState.idle,
          origin: () => SearchOrigin(label: '', latitude: outcome.latitude, longitude: outcome.longitude, fromDevice: true, location: outcome),
        );
        await _run();
      case LocationFailed(:final problem):
        state = state.copyWith(locating: LocatingState.idle, locationProblem: () => problem);
    }
  }

  /// Near Me with a place picked by hand, when location can't be used.
  Future<void> setArea(AreaMatch area) async {
    _enter(SearchMode.nearby);
    state = state.copyWith(
      origin: () => SearchOrigin(label: area.label, latitude: area.latitude, longitude: area.longitude, fromDevice: false),
      locationProblem: () => null,
    );
    await _run();
  }

  /// Along My Route: a new source or destination always plans the route
  /// again.
  Future<void> setTrip(TripPlace from, TripPlace to) async {
    _enter(SearchMode.route);
    state = state.copyWith(trip: () => Trip(from: from, to: to), locationProblem: () => null);
    await _run();
  }

  /// Along My Route: look at another of the offered routes.
  Future<void> selectRoute(int index) async {
    final trip = state.trip;
    if (trip == null || trip.routes == null || index == trip.selected || index < 0 || index >= trip.routes!.length) return;
    state = state.copyWith(trip: () => Trip(from: trip.from, to: trip.to, routes: trip.routes, selected: index));
    await _run();
  }

  /// Switches between the two searches. Near Me asks for the location the
  /// first time it is chosen.
  Future<void> setMode(SearchMode mode) async {
    if (mode == state.mode) return;
    _enter(mode);
    state = state.copyWith(locationProblem: () => null);
    if (mode == SearchMode.nearby && state.origin == null) return useCurrentLocation();
    if (state.active) await _run();
  }

  /// Clears the other search's results so they are never shown as this
  /// one's, and cancels its pending request.
  void _enter(SearchMode mode) {
    if (state.mode == mode) return;
    _generation++;
    state = state.copyWith(mode: mode, result: () => null, driving: const {}, refreshFailed: false);
  }

  Future<void> setRange(double km) async {
    if (km == state.rangeKm) return;
    state = state.mode == SearchMode.route ? state.copyWith(corridorKm: km) : state.copyWith(radiusKm: km);
    if (state.active) await _run();
  }

  Future<void> refresh() => _run(keepOld: true);

  void setSort(SortOrder s) => state = state.copyWith(sort: s);
  void setFilters(SearchFilters f) => state = state.copyWith(filters: f);
  void clearFilters() => state = state.copyWith(filters: const SearchFilters());
  void setView(ViewMode v) => state = state.copyWith(view: v);
  void dismissLocationProblem() => state = state.copyWith(locationProblem: () => null);

  Future<void> _run({bool keepOld = false}) async {
    final origin = state.mode == SearchMode.nearby ? state.origin : null;
    final trip = state.mode == SearchMode.route ? state.trip : null;
    if (origin == null && trip == null) return;
    final gen = ++_generation;
    final old = state.result;
    state = state.copyWith(
      result: () => keepOld && old?.value != null ? AsyncValue<SearchResult>.data(old!.value!) : const AsyncValue<SearchResult>.loading(),
      driving: keepOld ? null : const {},
      refreshFailed: false,
    );
    final repo = ref.read(retailRepositoryProvider);
    unawaited(ref.read(localStoreProvider).saveSearch(origin != null
        ? SavedSearch(label: origin.label, latitude: origin.latitude, longitude: origin.longitude, radiusKm: state.rangeKm, fromDevice: origin.fromDevice)
        : SavedSearch(
            label: trip!.to.label,
            latitude: trip.from.latitude,
            longitude: trip.from.longitude,
            radiusKm: state.radiusKm ?? SearchState.fallbackKm,
            fromDevice: false,
            from: trip.from,
            to: trip.to,
            corridorKm: state.corridorKm,
          )));
    try {
      final SearchResult r;
      if (origin != null) {
        r = await repo.searchStations(origin.latitude, origin.longitude, state.radiusKm);
      } else {
        // The routes only change with the source or destination; a refresh,
        // another route or a new distance re-uses them.
        var t = trip!;
        if (t.routes == null) {
          final routes = await repo.planRoutes(t.from, t.to);
          if (!ref.mounted || gen != _generation) return;
          t = Trip(from: t.from, to: t.to, routes: routes);
          state = state.copyWith(trip: () => t);
        }
        r = await repo.searchAlongRoute(t.plan!, state.corridorKm);
      }
      if (!ref.mounted || gen != _generation) return;
      state = state.copyWith(result: () => AsyncValue.data(r));
      if (origin != null) unawaited(_loadDriving(gen, origin, r));
    } catch (e, st) {
      if (!ref.mounted || gen != _generation) return;
      if (keepOld && old?.value != null) {
        state = state.copyWith(result: () => AsyncValue.data(old!.value!), refreshFailed: true);
      } else {
        state = state.copyWith(result: () => AsyncValue.error(e, st));
      }
    }
  }

  /// Near Me: driving distances for the nearest stations. Optional: if the
  /// routing service fails, cards keep the straight-line distance.
  Future<void> _loadDriving(int gen, SearchOrigin origin, SearchResult r) async {
    final nearest = [...r.stations]..sort((a, b) => (a.distanceKm ?? 1e9).compareTo(b.distanceKm ?? 1e9));
    try {
      final d = await ref.read(retailRepositoryProvider).drivingDistances(origin.latitude, origin.longitude, nearest);
      if (!ref.mounted || gen != _generation) return;
      state = state.copyWith(driving: d);
    } catch (_) {
      // Straight-line distance only.
    }
  }
}
