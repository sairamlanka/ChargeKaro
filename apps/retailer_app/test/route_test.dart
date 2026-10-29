import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_data/shared_data.dart';
import 'package:retailer_app/data/local_store.dart';
import 'package:retailer_app/data/location_service.dart';
import 'package:retailer_app/data/models.dart';
import 'package:retailer_app/state/place_suggestions.dart';
import 'package:retailer_app/state/providers.dart';
import 'package:retailer_app/state/search.dart';
import 'package:retailer_app/ui/explore/area_search_screen.dart';
import 'package:retailer_app/ui/explore/explore_screen.dart';
import 'package:retailer_app/ui/explore/route_search_screen.dart';
import 'package:retailer_app/ui/station/slots_screen.dart';

import 'support.dart';

const _gachibowli = TripPlace(label: 'Gachibowli', latitude: 17.44, longitude: 78.35);
const _vijayawada = AreaMatch(label: 'Vijayawada', secondary: 'Andhra Pradesh', latitude: 16.51, longitude: 80.65, fromProvider: true);

final _plan = RoutePlan.fromJson({
  'distance_km': 274.6,
  'duration_minutes': 290,
  'path': [
    [17.44, 78.35],
    [17.0, 79.5],
    [16.51, 80.65],
  ],
});

final _plan2 = RoutePlan.fromJson({
  'distance_km': 301.2,
  'duration_minutes': 330,
  'path': [
    [17.44, 78.35],
    [17.3, 79.9],
    [16.51, 80.65],
  ],
});

Map<String, Object?> _onRoute({String id = 'st1', String name = 'Banjara EV Hub', double off = 1.2, double along = 42, int available = 1}) => {
      ...stationJson(id: id),
      'name': name,
      'distance_km': null,
      'off_route_km': off,
      'along_route_km': along,
      'points': {'total': 2, 'available': available, 'in_use': 2 - available, 'unavailable': 0},
    };

SearchResult _along({String id = 'st1', double off = 1.2, double along = 42}) => SearchResult.fromJson({
      'in_service_area': true,
      'corridor_km': 5,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'stations': [_onRoute(id: id, off: off, along: along)],
    });

SearchResult _nearby() => SearchResult.fromJson({
      'in_service_area': true,
      'radius_km': 5,
      'stations': [
        {...stationJson(id: 'near1'), 'name': 'Madhapur Charge Point', 'distance_km': 0.8},
      ],
    });

void main() {
  setUpAll(() {
    registerFallbackValue(_gachibowli);
    registerFallbackValue(_plan);
    registerFallbackValue(<StationSummary>[]);
    registerFallbackValue(DateTime.utc(2000));
  });

  late LocalStore store;
  setUp(() async => store = await LocalStore.memory());

  GoRouter router() => GoRouter(routes: [
        GoRoute(path: '/', builder: (_, _) => const ExploreScreen()),
        GoRoute(path: '/route-search', builder: (_, _) => const RouteSearchScreen()),
        GoRoute(path: '/pick-location', builder: (_, _) => const AreaSearchScreen()),
        GoRoute(path: '/station/:id', builder: (_, s) => SlotsScreen(stationId: s.pathParameters['id']!)),
      ]);

  Future<void> saveTrip({double? corridorKm}) => store.saveSearch(SavedSearch(
        label: 'Vijayawada',
        latitude: 17.44,
        longitude: 78.35,
        radiusKm: 5,
        fromDevice: false,
        from: _gachibowli,
        to: TripPlace.fromArea(_vijayawada),
        corridorKm: corridorKm,
      ));

  group('Along My Route', () {
    testWidgets('source and destination list stations along the route, in trip order', (t) async {
      usePhone(t);
      final repo = mockRepo();
      when(() => repo.searchAreas('Gachibowli', near: any(named: 'near'))).thenAnswer(
        (_) async => const AreaSearchOutcome([AreaMatch(label: 'Gachibowli', secondary: 'Hyderabad', latitude: 17.44, longitude: 78.35)], providerAvailable: true),
      );
      when(() => repo.searchAreas('Vijayawada', near: any(named: 'near'))).thenAnswer((_) async => const AreaSearchOutcome([_vijayawada], providerAvailable: true));
      when(() => repo.planRoutes(any(), any())).thenAnswer((_) async => [_plan]);
      when(() => repo.searchAlongRoute(any(), any())).thenAnswer((_) async => _along());
      await t.pumpWidget(harness(store: store, router: router(), overrides: [retailRepositoryProvider.overrideWithValue(repo)]));
      await settle(t);

      expect(find.text('Along My Route'), findsOneWidget);
      expect(find.text('Near Me'), findsOneWidget);
      await t.tap(find.text('Where are you going?'));
      await settle(t);
      expect(find.text('Plan your trip'), findsOneWidget);
      // Live location is the other mode, not an option here.
      expect(find.text('Use my current location'), findsNothing);
      expect(find.text('Find Stations Along Route'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextField, 'From'), 'Gachibowli');
      await settle(t, const Duration(milliseconds: 100), 8);
      await t.tap(find.text('Gachibowli').last);
      await settle(t);
      // Destinations are ranked near the start.
      await t.enterText(find.widgetWithText(TextField, 'To'), 'Vijayawada');
      await settle(t, const Duration(milliseconds: 100), 8);
      final near = verify(() => repo.searchAreas('Vijayawada', near: captureAny(named: 'near'))).captured.single as TripPlace;
      expect(near.label, 'Gachibowli');
      await t.tap(find.text('Vijayawada').last);
      await settle(t);

      // Back on Explore with the route's stations; the corridor is the
      // server's default until the customer picks one.
      final ends = verify(() => repo.planRoutes(captureAny(), captureAny())).captured;
      expect((ends[0] as TripPlace).label, 'Gachibowli');
      expect((ends[1] as TripPlace).label, 'Vijayawada');
      verify(() => repo.searchAlongRoute(_plan, null)).called(1);
      expect(find.text('Along My Route'), findsWidgets);
      expect(find.text('Gachibowli to Vijayawada'), findsWidgets);
      expect(find.textContaining('275 km, about 4 h 50 min'), findsOneWidget);
      expect(find.textContaining('Within 5 km of the route'), findsOneWidget);
      expect(find.text('Banjara EV Hub'), findsOneWidget);
      expect(find.text('42 km'), findsOneWidget);
      expect(find.text('from start'), findsOneWidget);
      expect(find.text('1.2 km off route'), findsOneWidget);
      expect(find.text('Detour about 2.4 km'), findsOneWidget);
      // One route only: no route choice.
      expect(find.text('Choose a route'), findsNothing);

      // A wider distance re-uses the route instead of planning it again.
      await tapVisible(t, find.text('10 km'));
      await settle(t);
      verify(() => repo.searchAlongRoute(_plan, 10)).called(1);
      verifyNever(() => repo.planRoutes(any(), any()));
    });

    testWidgets('another offered route searches that route instead', (t) async {
      usePhone(t);
      final repo = mockRepo();
      when(() => repo.planRoutes(any(), any())).thenAnswer((_) async => [_plan, _plan2]);
      when(() => repo.searchAlongRoute(_plan, any())).thenAnswer((_) async => _along(id: 'a'));
      when(() => repo.searchAlongRoute(_plan2, any())).thenAnswer((_) async => SearchResult.fromJson({
            'in_service_area': true,
            'corridor_km': 5,
            'stations': [_onRoute(id: 'b', name: 'Miryalaguda Fast Charge', off: 0.2, along: 140)],
          }));
      await saveTrip();
      await t.pumpWidget(harness(store: store, router: router(), overrides: [retailRepositoryProvider.overrideWithValue(repo)]));
      await settle(t);
      expect(find.text('Choose a route'), findsOneWidget);
      expect(find.text('Banjara EV Hub'), findsOneWidget);

      await tapVisible(t, find.textContaining('Route 2'));
      await settle(t);
      verify(() => repo.searchAlongRoute(_plan2, null)).called(1);
      verify(() => repo.planRoutes(any(), any())).called(1);
      expect(find.text('Miryalaguda Fast Charge'), findsOneWidget);
      expect(find.text('Banjara EV Hub'), findsNothing);
      expect(find.textContaining('301 km'), findsWidgets);
      expect(find.text('On route'), findsOneWidget);
    });

    testWidgets('a station on the trip shows its detour and directions on to the destination', (t) async {
      usePhone(t);
      final repo = mockRepo();
      when(() => repo.planRoutes(any(), any())).thenAnswer((_) async => [_plan]);
      when(() => repo.searchAlongRoute(any(), any())).thenAnswer((_) async => _along(off: 3, along: 120));
      when(() => repo.detour(any(), any(), any(), any(), any())).thenAnswer((_) async => const Detour(extraKm: 6.4, extraMinutes: 9));
      when(() => repo.station('st1', lat: any(named: 'lat'), lng: any(named: 'lng'))).thenAnswer((_) async => StationDetail.fromJson(stationJson()));
      when(() => repo.slots('st1', any())).thenAnswer((_) async => SlotGrid.fromJson(gridJson(DateTime.now().toUtc().add(const Duration(hours: 1)), ['available'])));
      await saveTrip();
      await t.pumpWidget(harness(store: store, router: router(), overrides: [retailRepositoryProvider.overrideWithValue(repo)]));
      await settle(t);
      await t.tap(find.text('Banjara EV Hub'));
      await settle(t);

      final trip = find.text('On your trip', skipOffstage: false);
      await t.scrollUntilVisible(trip, 300, scrollable: find.byType(Scrollable).first);
      await settle(t);
      expect(find.text('120 km from Gachibowli'), findsOneWidget);
      expect(find.text('+6.4 km, about +9 min'), findsOneWidget);
      await t.scrollUntilVisible(find.text('Then continue to Vijayawada'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Directions to station'), findsOneWidget);
      final args = verify(() => repo.detour(captureAny(), captureAny(), captureAny(), any(), any())).captured;
      expect((args[0] as TripPlace).label, 'Gachibowli');
      expect((args[1] as TripPlace).label, 'Vijayawada');
      expect(args[2], same(_plan));
    });

    testWidgets('a route that cannot be planned explains itself and offers another trip', (t) async {
      usePhone(t);
      final repo = mockRepo();
      when(() => repo.searchAreas(any(), near: any(named: 'near'))).thenAnswer(
        (i) async => AreaSearchOutcome([
          i.positionalArguments.first == 'Gachibowli'
              ? const AreaMatch(label: 'Gachibowli', secondary: 'Hyderabad', latitude: 17.44, longitude: 78.35)
              : _vijayawada,
        ], providerAvailable: true),
      );
      when(() => repo.planRoutes(any(), any())).thenThrow(const AppFailure(FailureKind.notFound, 'no_route', 'No route'));
      await t.pumpWidget(harness(store: store, router: router(), overrides: [retailRepositoryProvider.overrideWithValue(repo)]));
      await settle(t);
      await t.tap(find.text('Where are you going?'));
      await settle(t);
      await t.enterText(find.widgetWithText(TextField, 'From'), 'Gachibowli');
      await settle(t, const Duration(milliseconds: 100), 8);
      await t.tap(find.text('Gachibowli').last);
      await settle(t);
      await t.enterText(find.widgetWithText(TextField, 'To'), 'Vijayawada');
      await settle(t, const Duration(milliseconds: 100), 8);
      await t.tap(find.text('Vijayawada').last);
      await settle(t);
      expect(find.text('No driving route found'), findsOneWidget);
      expect(find.text('Change route'), findsOneWidget);
      verifyNever(() => repo.searchAlongRoute(any(), any()));
    });

    testWidgets('the last trip is restored on launch', (t) async {
      usePhone(t);
      final repo = mockRepo();
      when(() => repo.planRoutes(any(), any())).thenAnswer((_) async => [_plan]);
      when(() => repo.searchAlongRoute(any(), any())).thenAnswer((_) async => _along());
      await saveTrip(corridorKm: 2);
      await t.pumpWidget(harness(store: store, router: router(), overrides: [retailRepositoryProvider.overrideWithValue(repo)]));
      await settle(t);
      expect(find.text('Gachibowli to Vijayawada'), findsWidgets);
      verify(() => repo.searchAlongRoute(_plan, 2)).called(1);
    });

    test('best stops: free points first, then on the route, then the smallest detour', () {
      final r = SearchResult.fromJson({
        'in_service_area': true,
        'corridor_km': 5,
        'stations': [
          _onRoute(id: 'early-detour', off: 3.5, along: 10),
          _onRoute(id: 'late-on-route', off: 0.1, along: 200),
          _onRoute(id: 'full', off: 0, along: 5, available: 0),
          _onRoute(id: 'small-detour', off: 1.2, along: 150),
          _onRoute(id: 'early-detour', off: 3.5, along: 10),
        ],
      });
      final s = SearchState(trip: const Trip(from: _gachibowli, to: _gachibowli), result: AsyncValue.data(r));
      expect(s.visible(DateTime.now()).map((x) => x.id), ['late-on-route', 'small-detour', 'early-detour', 'full']);
      expect(s.copyWith(sort: SortOrder.nearest).visible(DateTime.now()).map((x) => x.id), ['full', 'early-detour', 'small-detour', 'late-on-route']);
    });
  });

  test('on a trip, a station is listed when it is open on arrival, not just now', () {
    final now = DateTime.now();
    Map<String, Object?> window(DateTime t) {
      final ist = t.toUtc().add(const Duration(hours: 5, minutes: 30));
      final m = ist.hour * 60 + ist.minute;
      return {'day': ist.weekday, 'opens': (m - 20).clamp(0, 1439), 'closes': (m + 20).clamp(1, 1440)};
    }
    final later = now.add(const Duration(hours: 5));
    final plan = RoutePlan.fromJson({'distance_km': 600, 'duration_minutes': 600, 'path': [[17.4, 78.4], [16.5, 80.6]]});
    final r = SearchResult.fromJson({
      'in_service_area': true,
      'corridor_km': 5,
      'stations': [
        {..._onRoute(id: 'opens-later', along: 300), 'open': {'open_now': false}, 'hours': [window(later)]},
        {..._onRoute(id: 'closes-soon', along: 300), 'open': {'open_now': true}, 'hours': [window(now)]},
      ],
    });
    final s = SearchState(trip: Trip(from: _gachibowli, to: _gachibowli, routes: [plan]), result: AsyncValue.data(r));
    final opens = r.stations.first;
    expect(s.arrival(opens, now)!.difference(now).inMinutes, 300);
    expect(s.visible(now).map((x) => x.id), ['opens-later']);
    // Near Me keeps "open now".
    final near = SearchState(mode: SearchMode.nearby, origin: const SearchOrigin(label: 'x', latitude: 17.4, longitude: 78.4, fromDevice: false), result: AsyncValue.data(r));
    expect(near.visible(now).map((x) => x.id), ['closes-soon']);
  });

  group('Near Me', () {
    testWidgets('one search at a time: switching clears the other mode\'s results', (t) async {
      usePhone(t);
      final repo = mockRepo();
      when(() => repo.planRoutes(any(), any())).thenAnswer((_) async => [_plan]);
      when(() => repo.searchAlongRoute(any(), any())).thenAnswer((_) async => _along(id: 'route1'));
      when(() => repo.searchStations(any(), any(), any())).thenAnswer((_) async => _nearby());
      when(() => repo.drivingDistances(any(), any(), any())).thenAnswer((_) async => {'near1': const DrivingDistance(distanceKm: 1.4, durationMinutes: 6)});
      await saveTrip();
      await t.pumpWidget(harness(store: store, router: router(), overrides: [
        retailRepositoryProvider.overrideWithValue(repo),
        locationServiceProvider.overrideWithValue(FakeLocation(LocationFound(17.45, 78.39, accuracyMeters: 20, timestamp: DateTime.now()))),
      ]));
      await settle(t);
      expect(find.text('Banjara EV Hub'), findsOneWidget);

      // Near Me: only nearby stations, no route.
      await t.tap(find.text('Near Me'));
      await settle(t);
      verify(() => repo.searchStations(17.45, 78.39, 5)).called(1);
      expect(find.text('Near you'), findsOneWidget);
      expect(find.text('Madhapur Charge Point'), findsOneWidget);
      expect(find.text('Banjara EV Hub'), findsNothing);
      expect(find.text('Where are you going?'), findsNothing);
      // Straight-line distance and the driving distance by road.
      expect(find.textContaining('800 m'), findsWidgets);
      expect(find.textContaining('1.4 km drive'), findsOneWidget);
      expect(find.text('Update my location'), findsOneWidget);

      // Back to the route: the same trip, searched again without planning
      // the route again, and no nearby stations left over.
      await t.tap(find.text('Along My Route').first);
      await settle(t);
      expect(find.text('Banjara EV Hub'), findsOneWidget);
      expect(find.text('Madhapur Charge Point'), findsNothing);
      verify(() => repo.planRoutes(any(), any())).called(1);
      verify(() => repo.searchAlongRoute(_plan, null)).called(2);
    });

    testWidgets('without location, a place can be chosen by hand', (t) async {
      usePhone(t);
      final repo = mockRepo();
      when(() => repo.searchAreas(any(), near: any(named: 'near'))).thenAnswer(
        (_) async => const AreaSearchOutcome([AreaMatch(label: 'Madhapur', secondary: 'Hyderabad', latitude: 17.448, longitude: 78.391)], providerAvailable: true),
      );
      when(() => repo.searchStations(any(), any(), any())).thenAnswer((_) async => _nearby());
      await t.pumpWidget(harness(store: store, router: router(), overrides: [
        retailRepositoryProvider.overrideWithValue(repo),
        locationServiceProvider.overrideWithValue(FakeLocation(const LocationFailed(LocationProblem.denied))),
      ]));
      await settle(t);
      await t.tap(find.text('Near Me'));
      await settle(t);
      expect(find.text('Location not allowed'), findsOneWidget);
      await tapVisible(t, find.text('Choose a location instead').last);
      await settle(t);
      expect(find.text('Choose a location'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Madhapur');
      await settle(t, const Duration(milliseconds: 100), 8);
      await t.tap(find.widgetWithText(ListTile, 'Madhapur'));
      await settle(t);
      verify(() => repo.searchStations(17.448, 78.391, null)).called(1);
      expect(find.text('Near Madhapur'), findsOneWidget);
      expect(find.text('Near Me'), findsWidgets);
      expect(find.text('Madhapur Charge Point'), findsOneWidget);
    });

    testWidgets('no stations nearby offers a wider radius', (t) async {
      usePhone(t);
      final repo = mockRepo();
      when(() => repo.searchStations(any(), any(), any())).thenAnswer((_) async => SearchResult.fromJson({'in_service_area': true, 'radius_km': 5, 'stations': []}));
      await t.pumpWidget(harness(store: store, router: router(), overrides: [
        retailRepositoryProvider.overrideWithValue(repo),
        locationServiceProvider.overrideWithValue(FakeLocation(LocationFound(17.45, 78.39, accuracyMeters: 20, timestamp: DateTime.now()))),
      ]));
      await settle(t);
      await t.tap(find.text('Near Me'));
      await settle(t);
      await tapVisible(t, find.text('10 km').last);
      await settle(t);
      verify(() => repo.searchStations(17.45, 78.39, 10)).called(1);
    });
  });

  group('place suggestions', () {
    test('earlier answers and recent places show at once; the server is asked once per query', () async {
      final repo = mockRepo();
      const gachibowli = AreaMatch(label: 'Gachibowli', secondary: 'Hyderabad, Telangana', latitude: 17.44, longitude: 78.35, fromProvider: true);
      const gandhinagar = AreaMatch(label: 'Gandhinagar', secondary: 'Gujarat', latitude: 23.22, longitude: 72.65, fromProvider: true);
      when(() => repo.searchAreas('ga', near: any(named: 'near'))).thenAnswer((_) async => const AreaSearchOutcome([gachibowli, gandhinagar], providerAvailable: true));
      final s = PlaceSuggestions(repo, store);
      expect(s.instant('ga'), isNull);
      await s.fetch('ga');
      // Typing on narrows the earlier answer without waiting.
      expect(s.instant('gach')!.map((m) => m.label), ['Gachibowli']);
      expect(s.instant('Ga')!.length, 2);
      expect(s.isCached('GA '), isTrue);
      await s.fetch('ga');
      verify(() => repo.searchAreas('ga', near: any(named: 'near'))).called(1);

      // Places picked before come back first, even in a new session.
      const kphb = AreaMatch(label: 'KPHB Colony', secondary: 'Kukatpally, Hyderabad', latitude: 17.49, longitude: 78.39, fromProvider: true);
      await s.remember(kphb);
      final fresh = PlaceSuggestions(repo, store);
      expect(fresh.recent().single.label, 'KPHB Colony');
      expect(fresh.instant('kuka')!.single.label, 'KPHB Colony');
      expect(fresh.instant('zzz'), isNull);
    });

    test('an answer without the map search is not kept', () async {
      final repo = mockRepo();
      when(() => repo.searchAreas(any(), near: any(named: 'near'))).thenAnswer((_) async => const AreaSearchOutcome([], providerAvailable: false));
      final s = PlaceSuggestions(repo, store);
      await s.fetch('gachi');
      await s.fetch('gachi');
      verify(() => repo.searchAreas('gachi', near: any(named: 'near'))).called(2);
    });
  });

  test('saved trips survive a round trip through storage', () async {
    final s = SavedSearch(label: 'x', latitude: 1, longitude: 2, radiusKm: 5, fromDevice: false, from: _gachibowli, to: TripPlace.fromArea(_vijayawada), corridorKm: 2);
    await store.saveSearch(s);
    final back = store.lastSearch()!;
    expect(back.isTrip, isTrue);
    expect(back.from, _gachibowli);
    expect(back.to!.label, 'Vijayawada');
    expect(back.corridorKm, 2);
  });
}
