import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'repositories/admin_repository.dart';
import 'repositories/auth_repository.dart';
import 'repositories/booking_repository.dart';
import 'repositories/finance_repository.dart';
import 'repositories/notification_repository.dart';
import 'repositories/onboarding_repository.dart';
import 'repositories/station_repository.dart';

/// Overridden in main() once Supabase is initialised, and in tests with fakes.
final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnvironment());

final supabaseClientProvider = Provider<SupabaseClient>(
  (ref) => throw UnimplementedError('supabaseClientProvider must be overridden after Supabase.initialize'),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(supabaseClientProvider), redirectUrl: ref.watch(appConfigProvider).authRedirectUrl),
);
final stationRepositoryProvider = Provider<StationRepository>((ref) => StationRepository(ref.watch(supabaseClientProvider)));
final onboardingRepositoryProvider =
    Provider<OnboardingRepository>((ref) => OnboardingRepository(ref.watch(supabaseClientProvider)));
final bookingRepositoryProvider = Provider<BookingRepository>((ref) => BookingRepository(ref.watch(supabaseClientProvider)));
final notificationRepositoryProvider =
    Provider<NotificationRepository>((ref) => NotificationRepository(ref.watch(supabaseClientProvider)));
final adminRepositoryProvider = Provider<AdminRepository>((ref) => AdminRepository(ref.watch(supabaseClientProvider)));
final financeRepositoryProvider = Provider<FinanceRepository>((ref) => FinanceRepository(ref.watch(supabaseClientProvider)));

/// The signed-in user's id, or null. Changes on sign-in, sign-out and token
/// refresh for a different user.
final sessionUserIdProvider = StreamProvider<String?>((ref) async* {
  final auth = ref.watch(authRepositoryProvider);
  yield auth.currentUser?.id;
  await for (final state in auth.changes) {
    yield state.session?.user.id;
  }
});

/// Platform role and permissions from the database. Only used to shape the
/// UI; every action is re-authorised by the backend.
final platformAccessProvider = FutureProvider<PlatformAccess>((ref) async {
  final userId = ref.watch(sessionUserIdProvider).value;
  if (userId == null) return PlatformAccess.none;
  return ref.watch(authRepositoryProvider).platformAccess();
});

/// Businesses the signed-in user belongs to, with role and station scope.
final businessAccessProvider = FutureProvider<List<BusinessAccess>>((ref) async {
  final userId = ref.watch(sessionUserIdProvider).value;
  if (userId == null) return const [];
  return ref.watch(authRepositoryProvider).businessAccess();
});

final unreadNotificationsProvider = FutureProvider<int>((ref) async {
  final userId = ref.watch(sessionUserIdProvider).value;
  if (userId == null) return 0;
  final list = await ref.watch(notificationRepositoryProvider).list(unreadOnly: true, limit: 100);
  return list.length;
});
