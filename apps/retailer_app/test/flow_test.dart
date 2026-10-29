import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:retailer_app/data/checkout/checkout.dart';
import 'package:retailer_app/data/local_store.dart';
import 'package:retailer_app/data/location_service.dart';
import 'package:retailer_app/data/models.dart';
import 'package:retailer_app/state/booking_flow.dart';
import 'package:retailer_app/state/providers.dart';
import 'package:retailer_app/ui/booking/payment_screen.dart';
import 'package:retailer_app/ui/explore/explore_screen.dart';
import 'package:retailer_app/ui/station/slots_screen.dart';

import 'support.dart';

void main() {
  setUpAll(() => registerFallbackValue(DateTime.utc(2000)));

  late LocalStore store;
  setUp(() async => store = await LocalStore.memory());

  group('explore', () {
    testWidgets('guests can start without signing in, and a denied location explains itself', (t) async {
      usePhone(t);
      final repo = mockRepo();
      await t.pumpWidget(harness(store: store, overrides: [
        retailRepositoryProvider.overrideWithValue(repo),
        locationServiceProvider.overrideWithValue(FakeLocation(const LocationFailed(LocationProblem.denied))),
      ], child: const ExploreScreen()));
      await settle(t);
      expect(find.text('Find a charger near you'), findsOneWidget);
      await t.tap(find.text('Near Me').first);
      await settle(t);
      expect(find.text('Location not allowed'), findsOneWidget);
      // Denied location: retry, pick a place by hand, or search a route.
      expect(find.text('Allow location'), findsWidgets);
      expect(find.text('Choose a location instead'), findsWidgets);
      expect(find.text('Search along my route'), findsWidgets);
    });

    testWidgets('renders in Telugu', (t) async {
      usePhone(t);
      await t.pumpWidget(harness(
        store: store,
        locale: const Locale('te'),
        overrides: [retailRepositoryProvider.overrideWithValue(mockRepo())],
        child: const ExploreScreen(),
      ));
      await settle(t);
      expect(find.text('మీ దగ్గరలో ఛార్జర్ కనుగొనండి'), findsOneWidget);
    });
  });

  group('slot picker', () {
    late MockRepo repo;
    late DateTime from;

    setUp(() {
      repo = mockRepo();
      final n = DateTime.now().toUtc().add(const Duration(hours: 1));
      from = DateTime.utc(n.year, n.month, n.day, n.hour, n.minute < 30 ? 30 : 0).add(Duration(hours: n.minute < 30 ? 0 : 1));
      when(() => repo.station('st1', lat: any(named: 'lat'), lng: any(named: 'lng'))).thenAnswer((_) async => StationDetail.fromJson(stationJson()));
      when(() => repo.slots('st1', any())).thenAnswer((_) async => SlotGrid.fromJson(gridJson(from, ['booked', 'reserved', 'available', 'available', 'blocked'])));
    });

    GoRouter router() => GoRouter(initialLocation: '/s', routes: [
          GoRoute(path: '/s', builder: (_, _) => const SlotsScreen(stationId: 'st1')),
          GoRoute(path: '/book/details', builder: (_, _) => const Text('details page')),
        ]);

    testWidgets('states are labelled in words, not only colour', (t) async {
      usePhone(t);
      await t.pumpWidget(harness(store: store, overrides: [retailRepositoryProvider.overrideWithValue(repo)], router: router()));
      await settle(t);
      for (final label in ['Free', 'Full', 'Blocked', 'Unavailable']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      // No point to pick: the station assigns one.
      expect(find.textContaining('A free charging point is assigned'), findsOneWidget);
      // Tapping a full time explains why instead of doing nothing.
      await t.tap(find.bySemanticsLabel(RegExp(r', Full$')).first);
      await t.pump();
      expect(find.textContaining('Every charging point is booked at this time'), findsOneWidget);
    });

    testWidgets('choosing a free time saves the draft and continues', (t) async {
      usePhone(t);
      await t.pumpWidget(harness(store: store, overrides: [retailRepositoryProvider.overrideWithValue(repo)], router: router()));
      await settle(t);
      expect(find.text('Continue'), findsNothing);
      await t.tap(find.bySemanticsLabel(RegExp(r', 1 of 1 free$')).first);
      await t.pump();
      // Only the chosen start is marked, and it says when the booking ends.
      expect(find.textContaining('Until '), findsOneWidget);
      expect(find.text('Selected'), findsNothing);
      await t.tap(find.text('Continue'));
      await settle(t);
      expect(find.text('details page'), findsOneWidget);
      final draft = BookingDraft.fromJson(store.draft()!);
      expect(draft.connector, isNull);
      expect(draft.start, from.add(const Duration(minutes: 60)));
      expect(draft.displayedFeePaise, 1200);
    });
  });

  group('payment', () {
    late MockRepo repo;
    setUp(() {
      repo = mockRepo(userId: 'u1', phone: '+919876543210');
      when(() => repo.profile()).thenAnswer((_) async => null);
    });

    GoRouter router() => GoRouter(initialLocation: '/pay', routes: [
          GoRoute(path: '/pay', builder: (_, _) => const PaymentScreen(bookingId: 'b1')),
          GoRoute(path: '/book/done/:id', builder: (_, s) => Text('done ${s.pathParameters['id']}')),
        ]);

    testWidgets('an expired hold offers a new time instead of payment', (t) async {
      usePhone(t);
      when(() => repo.booking('b1')).thenAnswer((_) async => CustomerBooking.fromJson(bookingJson(status: 'expired', paymentStatus: 'abandoned')));
      await t.pumpWidget(harness(store: store, overrides: [retailRepositoryProvider.overrideWithValue(repo)], router: router()));
      await settle(t);
      expect(find.text('Your slot hold has ended'), findsOneWidget);
      expect(find.text('Choose another time'), findsOneWidget);
      expect(find.textContaining('Pay '), findsNothing);
    });

    testWidgets('closing the payment sheet keeps the hold and never claims success', (t) async {
      usePhone(t);
      final pending = CustomerBooking.fromJson(bookingJson(status: 'payment_pending', paymentStatus: 'pending', holdExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 9))));
      when(() => repo.booking('b1')).thenAnswer((_) async => pending);
      when(() => repo.createOrder('b1')).thenAnswer((_) async => OrderInfo.fromJson({'order_id': 'o1', 'key_id': 'rzp_test', 'amount_paise': 1200, 'booking_id': 'b1'}));
      final checkout = FakeCheckout(const CheckoutCancelled());
      await t.pumpWidget(harness(store: store, overrides: [retailRepositoryProvider.overrideWithValue(repo), checkoutProvider.overrideWithValue(checkout)], router: router()));
      await settle(t);
      expect(find.textContaining('left to pay'), findsOneWidget);
      // Pay stays disabled until the no-refund terms are accepted.
      await t.dragUntilVisible(find.text('Pay ₹12.00'), find.byType(ListView).first, const Offset(0, -200));
      expect(t.widget<GradientButton>(find.ancestor(of: find.text('Pay ₹12.00'), matching: find.byType(GradientButton))).onPressed, isNull);
      await tapVisible(t, find.byType(Checkbox));
      await t.pump();
      await tapVisible(t, find.text('Pay ₹12.00', skipOffstage: false));
      await t.pump();
      await t.pump();
      expect(checkout.opened, 1);
      await t.dragUntilVisible(find.textContaining('Please don\'t pay again'), find.byType(ListView).first, const Offset(0, 200));
      expect(find.textContaining('Please don\'t pay again'), findsOneWidget);
      // Polling gives up after about a minute; the outcome is still "not paid".
      await settle(t, const Duration(seconds: 2), 40);
      expect(find.textContaining('Payment was not completed', skipOffstage: false), findsOneWidget);
      expect(find.textContaining('done'), findsNothing);
    });

    testWidgets('development test payments: failure then success, both read back from the server', (t) async {
      usePhone(t);
      var state = 'pending';
      when(() => repo.booking('b1')).thenAnswer((_) async => CustomerBooking.fromJson(state == 'paid'
          ? bookingJson()
          : bookingJson(status: 'payment_pending', paymentStatus: state, holdExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 9)))));
      when(() => repo.devMockPayment('b1', success: any(named: 'success'))).thenAnswer((i) async {
        state = i.namedArguments[#success] == true ? 'paid' : 'failed';
      });
      await t.pumpWidget(harness(store: store, mockPayments: true, overrides: [retailRepositoryProvider.overrideWithValue(repo)], router: router()));
      await settle(t);
      await t.dragUntilVisible(find.byType(Checkbox), find.byType(ListView).first, const Offset(0, -200));
      await tapVisible(t, find.byType(Checkbox));
      await t.pump();
      await tapVisible(t, find.text('Pay ₹12.00'));
      await settle(t);
      await t.tap(find.text('Payment fails'));
      await settle(t);
      verify(() => repo.devMockPayment('b1', success: false)).called(1);
      verifyNever(() => repo.createOrder(any()));
      expect(find.textContaining('didn\'t go through', skipOffstage: false), findsWidgets);
      await t.dragUntilVisible(find.text('Try payment again'), find.byType(ListView).first, const Offset(0, -200));
      await tapVisible(t, find.text('Try payment again'));
      await settle(t);
      await t.tap(find.text('Payment succeeds'));
      await settle(t);
      expect(find.text('done b1'), findsOneWidget);
    });

    testWidgets('a successful checkout is confirmed by the server before showing success', (t) async {
      usePhone(t);
      var confirmed = false;
      when(() => repo.booking('b1')).thenAnswer((_) async => CustomerBooking.fromJson(confirmed
          ? bookingJson()
          : bookingJson(status: 'payment_pending', paymentStatus: 'pending', holdExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 9)))));
      when(() => repo.createOrder('b1')).thenAnswer((_) async => OrderInfo.fromJson({'order_id': 'o1', 'key_id': 'rzp_test', 'amount_paise': 1200, 'booking_id': 'b1'}));
      when(() => repo.verifyPayment(orderId: 'o1', paymentId: 'pay1', signature: 'sig')).thenAnswer((_) async {
        confirmed = true;
        return 'confirmed';
      });
      final checkout = FakeCheckout(const CheckoutSucceeded(paymentId: 'pay1', orderId: 'o1', signature: 'sig'));
      await t.pumpWidget(harness(store: store, overrides: [retailRepositoryProvider.overrideWithValue(repo), checkoutProvider.overrideWithValue(checkout)], router: router()));
      await settle(t);
      // Pay stays disabled until the no-refund terms are accepted.
      await t.dragUntilVisible(find.text('Pay ₹12.00'), find.byType(ListView).first, const Offset(0, -200));
      expect(t.widget<GradientButton>(find.ancestor(of: find.text('Pay ₹12.00'), matching: find.byType(GradientButton))).onPressed, isNull);
      await tapVisible(t, find.byType(Checkbox));
      await t.pump();
      await tapVisible(t, find.text('Pay ₹12.00', skipOffstage: false));
      await settle(t);
      verify(() => repo.verifyPayment(orderId: 'o1', paymentId: 'pay1', signature: 'sig')).called(1);
      expect(find.text('done b1'), findsOneWidget);
    });
  });
}
