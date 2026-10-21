import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

class _Destination {
  const _Destination(this.path, this.label, this.icon, this.permission);
  final String path;
  final String label;
  final IconData icon;

  /// Null means any active platform staff member.
  final String? permission;
}

const _destinations = [
  _Destination('/', 'Dashboard', Icons.dashboard_outlined, null),
  _Destination('/applications', 'Applications', Icons.assignment_outlined, PlatformPermission.applicationsReview),
  _Destination('/stations', 'Stations', Icons.ev_station_outlined, PlatformPermission.businessesRead),
  _Destination('/bookings', 'Bookings', Icons.event_note_outlined, PlatformPermission.bookingsReadAll),
  _Destination('/finance', 'Finance', Icons.account_balance_outlined, PlatformPermission.financeRead),
  _Destination('/staff', 'Admins', Icons.admin_panel_settings_outlined, PlatformPermission.adminsManage),
  _Destination('/settings', 'Settings', Icons.tune, PlatformPermission.settingsManage),
  _Destination('/audit', 'Audit log', Icons.history, PlatformPermission.auditRead),
  _Destination('/notifications', 'Notifications', Icons.notifications_outlined, null),
];

/// Sidebar layout. Navigation is filtered by the caller's permissions from
/// the database; pages and RPCs re-check on their own.
class AdminShell extends ConsumerWidget {
  const AdminShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(platformAccessProvider);
    return access.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: ErrorState(failure: AppFailure.from(e), onRetry: () => ref.invalidate(platformAccessProvider))),
      data: (a) {
        if (!a.isStaff) return const _NoAccess();
        final items = _destinations.where((d) => d.permission == null || a.can(d.permission!)).toList();
        final current = items.lastIndexWhere((d) => d.path == '/' ? location == '/' : location.startsWith(d.path));
        final wide = MediaQuery.sizeOf(context).width >= 1000;
        final unread = ref.watch(unreadNotificationsProvider).value ?? 0;

        Widget icon(_Destination d) => d.path == '/notifications' && unread > 0
            ? Badge(label: Text('$unread'), child: Icon(d.icon))
            : Icon(d.icon);

        final rail = NavigationRail(
          extended: wide,
          selectedIndex: current < 0 ? null : current,
          onDestinationSelected: (i) => context.go(items[i].path),
          leading: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: wide ? Text('ChargeKaro Admin', style: Theme.of(context).textTheme.titleMedium) : const Icon(Icons.bolt),
          ),
          trailing: Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (wide) Text(a.role?.label ?? '', style: Theme.of(context).textTheme.labelMedium),
                  IconButton(
                    tooltip: 'Sign out',
                    icon: const Icon(Icons.logout),
                    onPressed: () => ref.read(authRepositoryProvider).signOut(),
                  ),
                ]),
              ),
            ),
          ),
          destinations: [for (final d in items) NavigationRailDestination(icon: icon(d), label: Text(d.label))],
        );
        return Scaffold(
          body: SafeArea(
            child: Row(children: [
              rail,
              const VerticalDivider(width: 1),
              Expanded(child: child),
            ]),
          ),
        );
      },
    );
  }
}

class _NoAccess extends ConsumerWidget {
  const _NoAccess();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: EmptyState(
          icon: Icons.lock_outline,
          title: 'No admin access',
          message: 'This account is not an active platform staff member. Access is granted by a super admin; '
              'it cannot be requested from here.',
          action: OutlinedButton(onPressed: () => ref.read(authRepositoryProvider).signOut(), child: const Text('Sign out')),
        ),
      );
}

/// Standard page frame: title, optional actions and a body.
class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.title, required this.child, this.actions = const [], this.scroll = true});

  final String title;
  final Widget child;
  final List<Widget> actions;
  final bool scroll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 8,
            spacing: 8,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ),
        ),
        Expanded(
          child: scroll
              ? SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), child: child)
              : Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 0), child: child),
        ),
      ],
    );
  }
}

/// Wraps content that needs a permission the caller lacks.
class RequiresPermission extends ConsumerWidget {
  const RequiresPermission(this.permission, {super.key, required this.child});

  final String permission;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ok = ref.watch(platformAccessProvider).value?.can(permission) ?? false;
    if (ok) return child;
    return const EmptyState(
      icon: Icons.lock_outline,
      title: 'Not available for your role',
      message: 'Ask a super admin if you need this permission.',
    );
  }
}

bool can(WidgetRef ref, String permission) => ref.watch(platformAccessProvider).value?.can(permission) ?? false;
