import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../state.dart';

/// A station row with status, shared by Home and the Stations tab.
class StationCard extends ConsumerWidget {
  const StationCard(this.s, {super.key, this.showAddress = false});
  final Station s;
  final bool showAddress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final app = ref.watch(applicationProvider(s.id)).value;
    final pending = app != null && app.status != ApplicationStatus.approved;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Pressable(
        child: Card(
          child: InkWell(
            onTap: () => context.go('/stations/${s.id}'),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: s.status == StationStatus.active ? Brand.gradient : null,
                    color: s.status == StationStatus.active ? null : t.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.ev_station_rounded, color: s.status == StationStatus.active ? Colors.white : t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: t.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      [if (showAddress) s.addressLine1, s.city, if (pending) 'Application ${app.status.label.toLowerCase()}'].join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ]),
                ),
                const SizedBox(width: 8),
                pending ? StatusChip.application(app.status) : StatusChip.station(s.status),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
