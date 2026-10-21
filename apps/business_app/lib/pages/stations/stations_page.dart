import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../state.dart';
import '../../widgets/station_card.dart';

class StationsPage extends ConsumerWidget {
  const StationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOwner = ref.watch(currentAccessProvider)?.isOwner ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Stations')),
      floatingActionButton: isOwner
          ? FloatingActionButton.extended(
              onPressed: () => context.go('/stations/new'),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add station'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(stationsProvider),
        child: AsyncView(
          value: ref.watch(stationsProvider),
          onRetry: () => ref.invalidate(stationsProvider),
          builder: (list) => list.isEmpty
              ? ListView(children: const [
                  EmptyState(
                    icon: Icons.ev_station_rounded,
                    title: 'No stations yet',
                    message: 'Add your first station to start taking bookings.',
                  ),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 2),
                  itemBuilder: (context, i) {
                    return Entrance(index: i, child: StationCard(list[i], showAddress: true));
                  },
                ),
        ),
      ),
    );
  }
}
