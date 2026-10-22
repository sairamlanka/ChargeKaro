import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/l10n.dart';
import '../state/providers.dart';

/// Explore, Bookings and Profile. A rail on wide screens, a bar on phones.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final upcoming = ref.watch(nextBookingProvider) != null;
    void go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);
    final destinations = [
      (Icons.explore_outlined, Icons.explore_rounded, l(K.navExplore), false),
      (Icons.receipt_long_outlined, Icons.receipt_long_rounded, l(K.navBookings), upcoming),
      (Icons.person_outline_rounded, Icons.person_rounded, l(K.navProfile), false),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 900;
    Widget icon(IconData i, bool badge) => badge ? Badge(smallSize: 8, child: Icon(i)) : Icon(i);
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: go,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in destinations) NavigationRailDestination(icon: icon(d.$1, d.$4), selectedIcon: icon(d.$2, d.$4), label: Text(d.$3)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: shell),
        ]),
      );
    }
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: go,
        destinations: [
          for (final d in destinations) NavigationDestination(icon: icon(d.$1, d.$4), selectedIcon: icon(d.$2, d.$4), label: d.$3),
        ],
      ),
    );
  }
}
