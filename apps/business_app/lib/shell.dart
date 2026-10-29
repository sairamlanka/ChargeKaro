import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import 'push.dart';
import 'state.dart';

/// Bottom navigation. Tabs a member cannot use are hidden; the database
/// still enforces every permission.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  void initState() {
    super.initState();
    Push.register(ref.read(notificationRepositoryProvider)).catchError((Object e) => debugPrint('Push registration failed: $e'));
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(currentAccessProvider);
    final canBookings = access?.can(BusinessPermission.bookingsView) ?? false;
    final canCheckIn = access?.can(BusinessPermission.bookingsCheckin) ?? false;
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;

    final tabs = <(int, NavigationDestination)>[
      (0, const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home')),
      if (canBookings)
        (1, const NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month_rounded), label: 'Bookings')),
      if (canCheckIn) (2, const NavigationDestination(icon: _ScanTabIcon(), selectedIcon: _ScanTabIcon(selected: true), label: 'Check in')),
      (3, const NavigationDestination(icon: Icon(Icons.ev_station_outlined), selectedIcon: Icon(Icons.ev_station_rounded), label: 'Stations')),
      (
        4,
        NavigationDestination(
          icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.grid_view_rounded)),
          label: 'More',
        )
      ),
    ];
    final selected = tabs.indexWhere((t) => t.$1 == widget.shell.currentIndex);
    return Scaffold(
      body: widget.shell,
      bottomNavigationBar: NavigationBar(
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: selected < 0 ? 0 : selected,
        destinations: [for (final t in tabs) t.$2],
        onDestinationSelected: (i) => widget.shell.goBranch(tabs[i].$1, initialLocation: tabs[i].$1 == widget.shell.currentIndex),
      ),
    );
  }
}

/// The check-in tab gets the brand gradient so the most frequent staff
/// action is the easiest to find.
class _ScanTabIcon extends StatelessWidget {
  const _ScanTabIcon({this.selected = false});
  final bool selected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: Motion.medium,
        curve: Motion.curve,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(selected ? 14 : 12),
          boxShadow: selected ? [BoxShadow(color: Brand.green.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))] : const [],
        ),
        child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 20),
      );
}
