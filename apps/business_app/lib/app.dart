import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pages/auth/auth_pages.dart';
import 'pages/bookings/booking_detail_page.dart';
import 'pages/bookings/bookings_page.dart';
import 'pages/bookings/scan_page.dart';
import 'pages/home_page.dart';
import 'pages/more/more_pages.dart';
import 'pages/setup_business_page.dart';
import 'pages/stations/station_detail_page.dart';
import 'pages/stations/station_form_page.dart';
import 'pages/stations/stations_page.dart';
import 'shell.dart';

const _publicPaths = {'/welcome', '/login', '/register', '/verify', '/forgot'};

/// Re-evaluates redirects on auth events and when business access loads.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    _sub = ref.read(authRepositoryProvider).changes.listen((s) {
      if (s.event == AuthChangeEvent.passwordRecovery) recovering = true;
      notifyListeners();
    });
    ref.listen(businessAccessProvider, (_, _) => notifyListeners());
  }

  late final StreamSubscription<AuthState> _sub;
  bool recovering = false;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);
  final auth = ref.read(authRepositoryProvider);

  return GoRouter(
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final signedIn = auth.currentUser != null;
      if (!signedIn) return _publicPaths.contains(loc) ? null : '/welcome';
      if (refresh.recovering && loc != '/reset-password') return '/reset-password';
      if (loc == '/reset-password') return null;
      if (_publicPaths.contains(loc)) return '/home';

      final access = ref.read(businessAccessProvider);
      if (access.isLoading && !access.hasValue) return loc == '/loading' ? null : '/loading';
      if (access.hasValue && access.value!.isEmpty) return loc == '/setup' ? null : '/setup';
      if (loc == '/loading' || (loc == '/setup' && (access.value?.isNotEmpty ?? false))) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomePage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterPage()),
      GoRoute(path: '/verify', builder: (_, s) => VerifyEmailPage(email: s.uri.queryParameters['email'] ?? '')),
      GoRoute(path: '/forgot', builder: (_, _) => const ForgotPasswordPage()),
      GoRoute(
        path: '/reset-password',
        builder: (_, _) => ResetPasswordPage(onDone: () => refresh.recovering = false),
      ),
      GoRoute(path: '/loading', builder: (_, _) => const _Loading()),
      GoRoute(path: '/setup', builder: (_, _) => const SetupBusinessPage()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const HomePage())]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/bookings',
              builder: (_, _) => const BookingsPage(),
              routes: [GoRoute(path: ':id', builder: (_, s) => BookingDetailPage(id: s.pathParameters['id']!))],
            ),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/scan', builder: (_, _) => const ScanPage())]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/stations',
              builder: (_, _) => const StationsPage(),
              routes: [
                GoRoute(path: 'new', builder: (_, _) => const StationFormPage()),
                GoRoute(
                  path: ':id',
                  builder: (_, s) => StationDetailPage(id: s.pathParameters['id']!),
                  routes: [GoRoute(path: 'edit', builder: (_, s) => StationFormPage(stationId: s.pathParameters['id']))],
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/more',
              builder: (_, _) => const MorePage(),
              routes: [
                GoRoute(path: 'team', builder: (_, _) => const TeamPage()),
                GoRoute(path: 'reports', builder: (_, _) => const ReportsPage()),
                GoRoute(path: 'notifications', builder: (_, _) => const NotificationsPage()),
                GoRoute(path: 'account', builder: (_, _) => const AccountPage()),
              ],
            ),
          ]),
        ],
      ),
    ],
  );
});

class BusinessApp extends ConsumerWidget {
  const BusinessApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: 'ChargeKaro Business',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: ref.watch(routerProvider),
        debugShowCheckedModeBanner: false,
      );
}

class _Loading extends ConsumerWidget {
  const _Loading();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(businessAccessProvider);
    return Scaffold(
      body: access.hasError
          ? ErrorState(failure: AppFailure.from(access.error!), onRetry: () => ref.invalidate(businessAccessProvider))
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
