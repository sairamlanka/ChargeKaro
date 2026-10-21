import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';

/// App-bar control to pick the station that Bookings and Check-in use.
class StationSwitcher extends ConsumerWidget {
  const StationSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stations = ref.watch(stationsProvider).value ?? const [];
    final current = ref.watch(currentStationProvider);
    if (current == null) return const Text('No station');
    if (stations.length < 2) return Text(current.name, overflow: TextOverflow.ellipsis);
    return PopupMenuButton<String>(
      tooltip: 'Switch station',
      onSelected: ref.read(selectedStationIdProvider.notifier).select,
      itemBuilder: (_) => [for (final s in stations) CheckedPopupMenuItem(value: s.id, checked: s.id == current.id, child: Text(s.name))],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(current.name, overflow: TextOverflow.ellipsis)),
        const Icon(Icons.arrow_drop_down),
      ]),
    );
  }
}
