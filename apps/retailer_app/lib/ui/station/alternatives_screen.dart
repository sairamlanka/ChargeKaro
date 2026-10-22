import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../common/fallback.dart';
import '../common/widgets.dart';

typedef AlternativesQuery = ({String? exclude, double? lat, double? lng});

/// Bookable stations near a point, soonest free slot first. Used when a
/// station is closed, full, or a booking could not be completed.
final alternativesProvider = FutureProvider.autoDispose.family<List<StationSummary>, AlternativesQuery>((ref, q) async {
  final repo = ref.watch(retailRepositoryProvider);
  var lat = q.lat;
  var lng = q.lng;
  if ((lat == null || lng == null) && q.exclude != null) {
    final s = await repo.station(q.exclude!);
    if (s.isPublic) {
      lat = s.summary.latitude;
      lng = s.summary.longitude;
    }
  }
  if (lat == null || lng == null) {
    final o = ref.read(searchProvider).origin;
    lat = o?.latitude;
    lng = o?.longitude;
  }
  if (lat == null || lng == null) return const [];
  final r = await repo.searchStations(lat, lng, 15);
  final far = DateTime.utc(9999);
  return r.stations.where((s) => s.id != q.exclude && s.bookable).toList()
    ..sort((a, b) {
      final c = (a.nextAvailable?.startAt ?? far).compareTo(b.nextAvailable?.startAt ?? far);
      return c != 0 ? c : (a.distanceKm ?? 0).compareTo(b.distanceKm ?? 0);
    });
});

class AlternativesScreen extends ConsumerWidget {
  const AlternativesScreen({super.key, required this.query});
  final AlternativesQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final value = ref.watch(alternativesProvider(query));
    return Scaffold(
      appBar: AppBar(title: Text(l(K.alternativesTitle))),
      body: value.when(
        loading: () => const SingleChildScrollView(physics: NeverScrollableScrollPhysics(), padding: EdgeInsets.all(16), child: SkeletonList(count: 4, itemHeight: 120)),
        error: (e, _) => FailureView(error: e, onRetry: () => ref.invalidate(alternativesProvider(query))),
        data: (list) => list.isEmpty
            ? FallbackView(
                icon: Icons.search_off_rounded,
                title: l(K.noAlternativesTitle),
                message: l(K.noAlternativesBody),
                actions: [
                  FallbackAction(l(K.searchAnotherArea), () => context.push('/area-search'), icon: Icons.search_rounded, primary: true),
                  FallbackAction(l(K.backToExplore), () => context.go('/'), icon: Icons.explore_outlined),
                ],
              )
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(alternativesProvider(query)),
                child: PageBody(children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(l(K.alternativesIntro), style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  for (final (i, s) in list.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Entrance(index: i, child: StationCard(station: s, onOpen: () => context.push('/station/${s.id}'))),
                    ),
                ]),
              ),
      ),
    );
  }
}
