import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../state.dart';

class StationsPage extends ConsumerWidget {
  const StationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOwner = ref.watch(currentAccessProvider)?.isOwner ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Stations')),
      floatingActionButton: isOwner
          ? FloatingActionButton.extended(onPressed: () => context.go('/stations/new'), icon: const Icon(Icons.add), label: const Text('Add station'))
          : null,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(stationsProvider),
        child: AsyncView(
          value: ref.watch(stationsProvider),
          onRetry: () => ref.invalidate(stationsProvider),
          builder: (list) => list.isEmpty
              ? ListView(children: const [
                  EmptyState(icon: Icons.ev_station_outlined, title: 'No stations yet'),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = list[i];
                    return Card(
                      child: ListTile(
                        title: Text(s.name),
                        subtitle: Text('${s.addressLine1}, ${s.city}'),
                        trailing: StatusChip.station(s.status),
                        onTap: () => context.go('/stations/${s.id}'),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
