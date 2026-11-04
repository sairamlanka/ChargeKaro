import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';

import 'push.dart';

/// The business the user is working in. Most users belong to one; owners of
/// several can switch from the More tab.
class SelectedBusiness extends Notifier<String?> {
  // Cleared whenever a different account signs in, so nothing chosen by the
  // previous account carries over.
  @override
  String? build() {
    ref.watch(sessionUserIdProvider);
    return null;
  }

  void select(String id) => state = id;
}

final selectedBusinessIdProvider = NotifierProvider<SelectedBusiness, String?>(SelectedBusiness.new);

final currentAccessProvider = Provider<BusinessAccess?>((ref) {
  // While the list reloads for a newly signed-in account, show nothing rather
  // than the previous account's businesses.
  final access = ref.watch(businessAccessProvider);
  if (access.isReloading) return null;
  final list = access.value ?? const [];
  if (list.isEmpty) return null;
  final id = ref.watch(selectedBusinessIdProvider);
  return list.firstWhere((a) => a.businessId == id, orElse: () => list.first);
});

final stationsProvider = FutureProvider.autoDispose<List<Station>>((ref) async {
  ref.watch(sessionUserIdProvider);
  final access = ref.watch(currentAccessProvider);
  if (access == null) return const [];
  return ref.watch(stationRepositoryProvider).stations(access.businessId);
});

/// Station used by Bookings and Check-in. Defaults to the first active one.
class SelectedStation extends Notifier<String?> {
  @override
  String? build() {
    ref.watch(sessionUserIdProvider);
    return null;
  }

  void select(String id) => state = id;
}

final selectedStationIdProvider = NotifierProvider<SelectedStation, String?>(SelectedStation.new);

final currentStationProvider = Provider<Station?>((ref) {
  final stations = ref.watch(stationsProvider);
  if (stations.isReloading) return null;
  final list = stations.value ?? const [];
  if (list.isEmpty) return null;
  final id = ref.watch(selectedStationIdProvider);
  return list.where((s) => s.id == id).firstOrNull ??
      list.where((s) => s.status == StationStatus.active).firstOrNull ??
      list.first;
});

final stationProvider = FutureProvider.autoDispose.family<Station, String>((ref, id) => ref.watch(stationRepositoryProvider).station(id));
final pointsProvider =
    FutureProvider.autoDispose.family<List<ChargingPoint>, String>((ref, id) => ref.watch(stationRepositoryProvider).points(id));
final hoursProvider =
    FutureProvider.autoDispose.family<List<OperatingHours>, String>((ref, id) => ref.watch(stationRepositoryProvider).hours(id));
final policyProvider =
    FutureProvider.autoDispose.family<BookingPolicy, String>((ref, id) => ref.watch(stationRepositoryProvider).policy(id));
final applicationProvider = FutureProvider.autoDispose.family<StationApplication?, String>(
    (ref, stationId) => ref.watch(onboardingRepositoryProvider).applicationForStation(stationId));

Future<void> signOut(AuthRepository auth, NotificationRepository notifications) async {
  await Push.unregister(notifications);
  await auth.signOut();
}
