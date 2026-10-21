import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';

import 'pages/application_detail_page.dart';
import 'pages/applications_page.dart';
import 'pages/audit_page.dart';
import 'pages/bookings_page.dart';
import 'pages/dashboard_page.dart';
import 'pages/finance_page.dart';
import 'pages/login_page.dart';
import 'pages/notifications_page.dart';
import 'pages/settings_page.dart';
import 'pages/staff_page.dart';
import 'pages/stations_page.dart';
import 'shell.dart';

/// Re-runs router redirects when the auth session changes.
class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Stream<Object?> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }
  late final StreamSubscription<Object?> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  final listenable = _AuthListenable(auth.changes);
  ref.onDispose(listenable.dispose);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: listenable,
    redirect: (context, state) {
      final signedIn = auth.currentUser != null;
      final atLogin = state.matchedLocation == '/login';
      if (!signedIn) return atLogin ? null : '/login';
      if (atLogin) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      ShellRoute(
        builder: (context, state, child) => AdminShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const DashboardPage()),
          GoRoute(path: '/applications', builder: (_, _) => const ApplicationsPage()),
          GoRoute(path: '/applications/:id', builder: (_, s) => ApplicationDetailPage(id: s.pathParameters['id']!)),
          GoRoute(path: '/stations', builder: (_, _) => const StationsPage()),
          GoRoute(path: '/bookings', builder: (_, _) => const BookingsPage()),
          GoRoute(path: '/finance', builder: (_, _) => const FinancePage()),
          GoRoute(path: '/staff', builder: (_, _) => const StaffPage()),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
          GoRoute(path: '/audit', builder: (_, _) => const AuditPage()),
          GoRoute(path: '/notifications', builder: (_, _) => const NotificationsPage()),
        ],
      ),
    ],
  );
});

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: 'ChargeKaro Admin',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: ref.watch(routerProvider),
        debugShowCheckedModeBanner: false,
      );
}
