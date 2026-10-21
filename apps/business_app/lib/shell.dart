import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';

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
      (0, const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home')),
      if (canBookings) (1, const NavigationDestination(icon: Icon(Icons.event_note_outlined), selectedIcon: Icon(Icons.event_note), label: 'Bookings')),
      if (canCheckIn) (2, const NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: 'Check in')),
      (3, const NavigationDestination(icon: Icon(Icons.ev_station_outlined), selectedIcon: Icon(Icons.ev_station), label: 'Stations')),
      (
        4,
        NavigationDestination(
          icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.menu)),
          label: 'More',
        )
      ),
    ];
    final selected = tabs.indexWhere((t) => t.$1 == widget.shell.currentIndex);
    return Scaffold(
      body: widget.shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected < 0 ? 0 : selected,
        destinations: [for (final t in tabs) t.$2],
        onDestinationSelected: (i) => widget.shell.goBranch(tabs[i].$1, initialLocation: tabs[i].$1 == widget.shell.currentIndex),
      ),
    );
  }
}
