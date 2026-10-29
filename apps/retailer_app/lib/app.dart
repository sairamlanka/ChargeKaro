import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import 'l10n/l10n.dart';
import 'state/providers.dart';
import 'ui/booking/confirmation_screen.dart';
import 'ui/booking/details_screen.dart';
import 'ui/booking/payment_screen.dart';
import 'ui/booking/review_screen.dart';
import 'ui/booking/verify_screen.dart';
import 'ui/bookings/booking_detail_screen.dart';
import 'ui/bookings/bookings_screen.dart';
import 'ui/common/fallback.dart';
import 'ui/common/widgets.dart';
import 'ui/explore/area_search_screen.dart';
import 'ui/explore/explore_screen.dart';
import 'ui/profile/help_screen.dart';
import 'ui/profile/profile_screen.dart';
import 'ui/shell.dart';
import 'ui/station/alternatives_screen.dart';
import 'ui/station/slots_screen.dart';
import 'ui/station/station_screen.dart';

/// Guests can open every discovery screen. Screens that need an account
/// show their own sign-in prompt instead of redirecting, so a link to a
/// booking still lands somewhere that explains what to do.
GoRouter buildRouter() => GoRouter(
      initialLocation: '/',
      errorBuilder: (context, state) => const NotFoundScreen(),
      routes: [
        StatefulShellRoute(
          builder: (context, state, shell) => HomeShell(shell: shell),
          navigatorContainerBuilder: (context, shell, children) => FadeIndexedStack(index: shell.currentIndex, children: children),
          branches: [
            StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, _) => const ExploreScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/bookings', builder: (_, _) => const BookingsScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen())]),
          ],
        ),
        GoRoute(path: '/area-search', builder: (_, _) => const AreaSearchScreen()),
        GoRoute(path: '/station/:id', builder: (_, s) => StationScreen(id: s.pathParameters['id']!)),
        GoRoute(
          path: '/station/:id/slots',
          builder: (_, s) => SlotsScreen(stationId: s.pathParameters['id']!, initialDate: DateTime.tryParse(s.uri.queryParameters['date'] ?? '')),
        ),
        GoRoute(
          path: '/alternatives',
          builder: (_, s) {
            final q = s.uri.queryParameters;
            return AlternativesScreen(query: (exclude: q['exclude'], lat: double.tryParse(q['lat'] ?? ''), lng: double.tryParse(q['lng'] ?? '')));
          },
        ),
        GoRoute(path: '/book/details', builder: (_, _) => const DetailsScreen()),
        GoRoute(path: '/book/verify', builder: (_, _) => const VerifyScreen()),
        GoRoute(path: '/book/review', builder: (_, _) => const ReviewScreen()),
        GoRoute(path: '/book/pay/:id', builder: (_, s) => PaymentScreen(bookingId: s.pathParameters['id']!)),
        GoRoute(path: '/book/done/:id', builder: (_, s) => ConfirmationScreen(bookingId: s.pathParameters['id']!)),
        GoRoute(path: '/booking/:id', builder: (_, s) => BookingDetailScreen(bookingId: s.pathParameters['id']!)),
        GoRoute(path: '/find-booking', builder: (_, _) => const FindBookingScreen()),
        GoRoute(path: '/sign-in', builder: (_, s) => SignInScreen(next: s.uri.queryParameters['next'])),
        GoRoute(path: '/profile/phone', builder: (_, _) => const ChangePhoneScreen()),
        GoRoute(path: '/profile/delete', builder: (_, _) => const DeleteAccountScreen()),
        GoRoute(path: '/help', builder: (_, s) => HelpScreen(focusTerms: s.uri.queryParameters['section'] == 'terms')),
      ],
    );

final routerProvider = Provider<GoRouter>((ref) {
  final r = buildRouter();
  ref.onDispose(r.dispose);
  return r;
});

class RetailApp extends ConsumerWidget {
  const RetailApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => context.l(K.appTitle),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      locale: locale,
      supportedLocales: L.supported,
      localizationsDelegates: const [L.delegate, GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => ConnectivityBanner(child: AppStatusGate(child: child ?? const SizedBox.shrink())),
    );
  }
}

/// Maintenance mode and forced updates, read from the server. If the
/// status cannot be loaded the app carries on; each screen handles its own
/// errors.
class AppStatusGate extends ConsumerWidget {
  const AppStatusGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final status = ref.watch(termsProvider).value?.appStatus;
    if (status == null) return child;
    if (status.maintenance) {
      return Scaffold(
        body: FallbackView(
          icon: Icons.construction_rounded,
          title: l(K.maintenanceTitle),
          message: status.message ?? l(K.maintenanceBody),
          tone: StatusTone.warning,
          actions: [FallbackAction(l(K.tryAgain), () => ref.invalidate(termsProvider), icon: Icons.refresh_rounded, primary: true)],
        ),
      );
    }
    if (status.minBuild != null && status.minBuild! > appBuildNumber) {
      return Scaffold(
        body: FallbackView(
          icon: Icons.system_update_rounded,
          title: l(K.updateRequiredTitle),
          message: status.message ?? l(K.updateRequiredBody),
          tone: StatusTone.info,
        ),
      );
    }
    return child;
  }
}

class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      appBar: AppBar(),
      body: FallbackView(
        icon: Icons.explore_off_outlined,
        title: l(K.notFoundTitle),
        message: l(K.notFoundBody),
        actions: [FallbackAction(l(K.backToExplore), () => context.go('/'), icon: Icons.explore_rounded, primary: true)],
      ),
    );
  }
}
