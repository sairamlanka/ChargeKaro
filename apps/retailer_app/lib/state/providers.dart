import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';

import '../data/checkout/checkout.dart';
import '../data/local_store.dart';
import '../data/location_service.dart';
import '../data/models.dart';
import '../data/retail_repository.dart';
import 'search.dart';

/// Overridden in main() (and in tests).
final localStoreProvider = Provider<LocalStore>((ref) => throw UnimplementedError('localStoreProvider must be overridden'));

final retailRepositoryProvider = Provider<RetailRepository>((ref) => RetailRepository(ref.watch(supabaseClientProvider)));
final locationServiceProvider = Provider<LocationService>((ref) => const DeviceLocationService());
final checkoutProvider = Provider<PaymentCheckout>((ref) {
  final c = createPaymentCheckout();
  ref.onDispose(c.dispose);
  return c;
});

/// Development builds without Razorpay keys pay through a test sheet that
/// simulates success or failure on the local server
/// (supabase/dev/dev_payments.sql). Pass RAZORPAY_ENABLED=true to use the
/// real Razorpay checkout in development. Production always uses Razorpay.
final mockPaymentsProvider = Provider<bool>((ref) =>
    !const bool.fromEnvironment('RAZORPAY_ENABLED') && ref.watch(appConfigProvider).environment == 'development');

/// Build number of this app, compared with the server's minimum.
const appBuildNumber = int.fromEnvironment('APP_BUILD', defaultValue: 1);

/// True while the device reports a network connection. "Connected" does not
/// guarantee the backend is reachable; requests still time out gracefully.
final onlineProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  bool online(List<ConnectivityResult> r) => r.any((x) => x != ConnectivityResult.none);
  try {
    yield online(await c.checkConnectivity());
  } catch (_) {
    yield true;
  }
  yield* c.onConnectivityChanged.map(online);
});

/// The signed-in customer's id, or null for a guest.
final customerIdProvider = StreamProvider<String?>((ref) async* {
  final repo = ref.watch(retailRepositoryProvider);
  yield repo.userId;
  await for (final s in repo.authChanges) {
    yield s.session?.user.id;
  }
});

final profileProvider = FutureProvider<CustomerProfile?>((ref) async {
  final id = ref.watch(customerIdProvider).value;
  if (id == null) return null;
  return ref.watch(retailRepositoryProvider).profile();
});

final termsProvider = FutureProvider<BookingTerms>((ref) => ref.watch(retailRepositoryProvider).terms());

/// Whether the signed-in customer accepted the current booking terms. False
/// for a guest.
final termsAcceptedProvider = FutureProvider<bool>((ref) async {
  final id = ref.watch(customerIdProvider).value;
  if (id == null) return false;
  final terms = await ref.watch(termsProvider.future);
  return ref.watch(retailRepositoryProvider).hasAcceptedTerms(terms.termsVersion);
});

final stationProvider = FutureProvider.autoDispose.family<StationDetail, String>((ref, id) {
  // Distance is measured from the search centre (or the start of the trip),
  // read once.
  final anchor = ref.read(searchProvider).anchor;
  return ref.watch(retailRepositoryProvider).station(id, lat: anchor?.latitude, lng: anchor?.longitude);
});

typedef SlotQuery = ({String stationId, DateTime date});
final slotsProvider = FutureProvider.autoDispose.family<SlotGrid, SlotQuery>(
  (ref, q) => ref.watch(retailRepositoryProvider).slots(q.stationId, q.date),
);

final myBookingsProvider = FutureProvider<List<CustomerBooking>>((ref) async {
  final id = ref.watch(customerIdProvider).value;
  if (id == null) return const [];
  return ref.watch(retailRepositoryProvider).myBookings();
});

final bookingProvider = FutureProvider.autoDispose.family<CustomerBooking, String>(
  (ref, id) => ref.watch(retailRepositoryProvider).booking(id),
);

/// The earliest upcoming confirmed or pending booking, for the home screen.
final nextBookingProvider = Provider<CustomerBooking?>((ref) {
  final list = ref.watch(myBookingsProvider).value ?? const [];
  final now = DateTime.now();
  final upcoming = list.where((b) => b.isUpcomingAt(now)).toList()..sort((a, b) => a.startAt.compareTo(b.startAt));
  return upcoming.isEmpty ? null : upcoming.first;
});

final recentStationsProvider = NotifierProvider<RecentStationsController, List<RecentStation>>(RecentStationsController.new);

class RecentStationsController extends Notifier<List<RecentStation>> {
  @override
  List<RecentStation> build() => ref.watch(localStoreProvider).recentStations();

  Future<void> add(StationSummary s) async {
    await ref.read(localStoreProvider).addRecentStation(RecentStation(id: s.id, name: s.name, subtitle: s.shortAddress, viewedAt: DateTime.now()));
    state = ref.read(localStoreProvider).recentStations();
  }

  Future<void> clear() async {
    await ref.read(localStoreProvider).clearRecent();
    state = const [];
  }
}

final localeProvider = NotifierProvider<LocaleController, Locale>(LocaleController.new);

class LocaleController extends Notifier<Locale> {
  static const supported = [Locale('en'), Locale('te')];

  @override
  Locale build() {
    final saved = ref.watch(localStoreProvider).locale();
    if (saved != null) return Locale(saved);
    final device = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    return supported.any((l) => l.languageCode == device) ? Locale(device) : const Locale('en');
  }

  Future<void> set(Locale l) async {
    state = l;
    await ref.read(localStoreProvider).setLocale(l.languageCode);
    if (ref.read(customerIdProvider).value != null) {
      unawaited(ref.read(retailRepositoryProvider).updateProfile(locale: '${l.languageCode}-IN').catchError((_) {}));
    }
  }
}

/// Converts any error into something the UI can explain.
AppFailure failureOf(Object e) => AppFailure.from(e);
