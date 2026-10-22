import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/location_service.dart';
import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/map_view.dart';
import '../common/widgets.dart';
import 'filter_sheet.dart';

/// Home and search results in one place: search by area or current
/// location, then browse nearby stations as a list or on a map. No sign-in
/// is ever asked for here.
class ExploreScreen extends ConsumerWidget {
  const ExploreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(searchProvider);
    final hasResults = search.origin != null;
    if (hasResults && search.view == ViewMode.map && search.result?.value != null && search.result!.value!.inServiceArea) {
      return Scaffold(
        body: Column(children: [
          const _Hero(compact: true),
          const _ResultsToolbar(),
          Expanded(
            child: StationsMap(
              stations: search.visible(DateTime.now()),
              centerLat: search.origin!.latitude,
              centerLng: search.origin!.longitude,
              radiusKm: search.radiusKm,
              showUserDot: search.origin!.fromDevice,
              onOpen: (s) => context.push('/station/${s.id}'),
              onShowList: () => ref.read(searchProvider.notifier).setView(ViewMode.list),
            ),
          ),
        ]),
      );
    }
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          if (hasResults) await ref.read(searchProvider.notifier).refresh();
          ref.invalidate(myBookingsProvider);
        },
        child: CustomScrollView(slivers: [
          const SliverToBoxAdapter(child: _Hero()),
          if (search.locationProblem != null) SliverToBoxAdapter(child: _LocationProblemCard(problem: search.locationProblem!)),
          if (hasResults) ...[
            const SliverToBoxAdapter(child: _ResultsToolbar()),
            const _ResultsList(),
          ] else
            const SliverToBoxAdapter(child: _StartSections()),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ]),
      ),
    );
  }
}

class _Hero extends ConsumerWidget {
  const _Hero({this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final t = Theme.of(context);
    final search = ref.watch(searchProvider);
    final locating = search.locating == LocatingState.locating;
    return AuroraHero(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, compact ? 8 : 16, 16, compact ? 12 : 22),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!compact) ...[
                  Row(children: [
                    const ChargeLogo(size: 34),
                    const SizedBox(width: 6),
                    Text('ChargeKaro', style: t.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                    const Spacer(),
                    IconButton(
                      tooltip: l(K.findMyBooking),
                      onPressed: () => context.push('/find-booking'),
                      icon: const Icon(Icons.confirmation_number_outlined, color: Colors.white),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Entrance(
                    child: Text(l(K.heroTitle), style: t.textTheme.headlineMedium?.copyWith(color: Colors.white, height: 1.15)),
                  ),
                  const SizedBox(height: 6),
                  Entrance(index: 1, child: Text(l(K.heroSubtitle), style: t.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85)))),
                  const SizedBox(height: 18),
                ],
                Entrance(
                  index: 2,
                  child: Semantics(
                    button: true,
                    label: l(K.searchAreaHint),
                    excludeSemantics: true,
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      elevation: 6,
                      shadowColor: Colors.black38,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => context.push('/area-search'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Row(children: [
                            const Icon(Icons.search_rounded, color: Brand.greenDeep),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                search.origin != null && !search.origin!.fromDevice ? search.origin!.label : l(K.searchAreaHint),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.textTheme.bodyLarge?.copyWith(
                                  color: search.origin != null && !search.origin!.fromDevice ? Brand.ink : Colors.blueGrey.shade400,
                                ),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Entrance(
                  index: 3,
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
                        backgroundColor: search.origin?.fromDevice == true ? Colors.white.withValues(alpha: 0.16) : null,
                      ),
                      onPressed: locating ? null : () => ref.read(searchProvider.notifier).useCurrentLocation(),
                      icon: locating
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.my_location_rounded),
                      label: Text(locating ? l(K.locating) : l(K.useMyLocation)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationProblemCard extends ConsumerWidget {
  const _LocationProblemCard({required this.problem});
  final LocationProblem problem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final loc = ref.read(locationServiceProvider);
    final notifier = ref.read(searchProvider.notifier);
    final (icon, title, body, actions) = switch (problem) {
      LocationProblem.servicesOff => (
          Icons.location_disabled_rounded,
          l(K.locOffTitle),
          l(K.locOffBody),
          [FallbackAction(l(K.turnOnLocation), () => loc.openLocationSettings(), icon: Icons.settings_rounded, primary: true)],
        ),
      LocationProblem.denied => (
          Icons.location_off_rounded,
          l(K.locDeniedTitle),
          l(K.locDeniedBody),
          [FallbackAction(l(K.allowLocation), notifier.useCurrentLocation, icon: Icons.my_location_rounded, primary: true)],
        ),
      LocationProblem.deniedForever => (
          Icons.location_off_rounded,
          l(K.locBlockedTitle),
          l(K.locBlockedBody),
          [FallbackAction(l(K.openSettings), () => loc.openAppSettings(), icon: Icons.settings_rounded, primary: true)],
        ),
      LocationProblem.timeout || LocationProblem.unavailable => (
          Icons.gps_not_fixed_rounded,
          l(K.locUnknownTitle),
          l(K.locUnknownBody),
          [FallbackAction(l(K.tryAgain), notifier.useCurrentLocation, icon: Icons.refresh_rounded, primary: true)],
        ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Card(
            child: Stack(children: [
              FallbackView(
                compact: true,
                icon: icon,
                title: title,
                message: body,
                tone: StatusTone.warning,
                actions: [
                  ...actions,
                  FallbackAction(l(K.searchByAreaInstead), () => context.push('/area-search'), icon: Icons.search_rounded),
                ],
              ),
              Positioned(
                right: 4,
                top: 4,
                child: IconButton(tooltip: l(K.dismiss), onPressed: notifier.dismissLocationProblem, icon: const Icon(Icons.close_rounded)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ResultsToolbar extends ConsumerWidget {
  const _ResultsToolbar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final s = ref.watch(searchProvider);
    final n = ref.read(searchProvider.notifier);
    final origin = s.origin!;
    final loc = origin.location;
    final now = DateTime.now();
    final title = origin.fromDevice ? l(K.nearYou) : l(K.nearPlace, {'place': origin.label});
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(title, style: t.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Text(l(K.withinRadius, {'km': s.radiusKm.toStringAsFixed(0)}), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ]),
              ),
              IconButton(tooltip: l(K.refresh), onPressed: n.refresh, icon: const Icon(Icons.refresh_rounded)),
              SegmentedButton<ViewMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: ViewMode.list, icon: const Icon(Icons.view_agenda_outlined), tooltip: l(K.listView)),
                  ButtonSegment(value: ViewMode.map, icon: const Icon(Icons.map_outlined), tooltip: l(K.mapView)),
                ],
                selected: {s.view},
                onSelectionChanged: (v) => n.setView(v.first),
              ),
            ]),
            if (loc != null && (loc.isApproximate || loc.lastKnown || loc.isStale(now)))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Pill(
                  loc.lastKnown || loc.isStale(now)
                      ? l(K.locStale, {'when': f.ago(loc.timestamp, now)})
                      : l(K.locApproximate, {'m': loc.accuracyMeters.round()}),
                  icon: Icons.gps_not_fixed_rounded,
                  tone: StatusTone.warning,
                ),
              ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final r in SearchState.radiusOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(l(K.radiusKm, {'km': r.toStringAsFixed(0)})),
                      selected: s.radiusKm == r,
                      onSelected: (_) => n.setRadius(r),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _SortMenu(sort: s.sort, onChanged: n.setSort),
              ),
              const SizedBox(width: 8),
              Badge(
                isLabelVisible: s.filters.count > 0,
                label: Text('${s.filters.count}'),
                child: OutlinedButton.icon(
                  onPressed: () => showFilterSheet(context, ref),
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: Text(l(K.filters)),
                ),
              ),
            ]),
            if (!s.filters.isEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                ...activeFilterLabels(l, s.filters).map((x) => Chip(label: Text(x), visualDensity: VisualDensity.compact)),
                ActionChip(avatar: const Icon(Icons.clear_rounded, size: 16), label: Text(l(K.clearFilters)), onPressed: n.clearFilters),
              ]),
            ],
            if (s.refreshFailed && s.result?.value != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Pill(l(K.refreshFailed, {'when': f.ago(s.result!.value!.generatedAt, now)}), icon: Icons.cloud_off_rounded, tone: StatusTone.warning),
              ),
          ]),
        ),
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.onChanged});
  final SortOrder sort;
  final ValueChanged<SortOrder> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    String label(SortOrder s) => switch (s) {
          SortOrder.nearest => l(K.sortNearest),
          SortOrder.earliestSlot => l(K.sortEarliest),
          SortOrder.lowestFee => l(K.sortLowestFee),
          SortOrder.mostAvailable => l(K.sortMostAvailable),
        };
    return PopupMenuButton<SortOrder>(
      tooltip: l(K.sortBy),
      initialValue: sort,
      onSelected: onChanged,
      itemBuilder: (_) => [for (final s in SortOrder.values) PopupMenuItem(value: s, child: Text(label(s)))],
      child: InputDecorator(
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          prefixIcon: const Icon(Icons.sort_rounded),
          labelText: l(K.sortBy),
          isDense: true,
        ),
        child: Text(label(sort), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _ResultsList extends ConsumerWidget {
  const _ResultsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final s = ref.watch(searchProvider);
    final n = ref.read(searchProvider.notifier);
    final result = s.result;
    Widget box(Widget child) => SliverToBoxAdapter(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child)));

    if (result == null || (result.isLoading && !result.hasValue)) {
      return box(const SizedBox(height: 420, child: SlowLoading()));
    }
    if (result.hasError && !result.hasValue) {
      return box(FailureView(error: result.error!, onRetry: n.refresh, compact: true, extra: [
        FallbackAction(l(K.searchAnotherArea), () => context.push('/area-search'), icon: Icons.search_rounded),
      ]));
    }
    final data = result.value!;
    if (!data.inServiceArea) {
      return box(FallbackView(
        compact: true,
        icon: Icons.public_off_rounded,
        title: l(K.outsideAreaTitle),
        message: l(K.outsideAreaBody),
        actions: [FallbackAction(l(K.searchAnotherArea), () => context.push('/area-search'), icon: Icons.search_rounded, primary: true)],
      ));
    }
    if (data.stations.isEmpty) {
      final bigger = SearchState.radiusOptions.where((r) => r > s.radiusKm).toList();
      return box(FallbackView(
        compact: true,
        icon: Icons.ev_station_outlined,
        title: l(K.noStationsTitle, {'km': s.radiusKm.toStringAsFixed(0)}),
        message: l(K.noStationsBody),
        actions: [
          if (bigger.isNotEmpty)
            FallbackAction(l(K.widenTo, {'km': bigger.first.toStringAsFixed(0)}), () => n.setRadius(bigger.first), icon: Icons.zoom_out_map_rounded, primary: true),
          FallbackAction(l(K.searchAnotherArea), () => context.push('/area-search'), icon: Icons.search_rounded),
        ],
      ));
    }
    final visible = s.visible(DateTime.now());
    if (visible.isEmpty) {
      return box(FallbackView(
        compact: true,
        icon: Icons.filter_alt_off_rounded,
        title: l(K.noFilterMatchTitle),
        message: l(K.noFilterMatchBody, {'n': data.stations.length}),
        actions: [FallbackAction(l(K.clearFilters), n.clearFilters, icon: Icons.clear_all_rounded, primary: true)],
      ));
    }
    final noneBookable = visible.every((x) => !x.bookable);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList.list(children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 10),
                child: Text(l(K.resultsCount, {'n': visible.length}), style: Theme.of(context).textTheme.labelLarge),
              ),
              if (noneBookable)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: Text(l(K.noneBookableTitle)),
                      subtitle: Text(l(K.noneBookableBody)),
                    ),
                  ),
                ),
              for (final (i, st) in visible.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Entrance(index: i, child: StationCard(station: st, onOpen: () => context.push('/station/${st.id}'))),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l(K.availabilityDisclaimer), style: Theme.of(context).textTheme.bodySmall),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Shown before the first search: unfinished and upcoming bookings, recently
/// viewed stations, and how booking works.
class _StartSections extends ConsumerWidget {
  const _StartSections();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final now = DateTime.now();
    final recent = ref.watch(recentStationsProvider);
    final next = ref.watch(nextBookingProvider);
    final draft = ref.watch(bookingFlowProvider);
    final children = <Widget>[
      if (draft != null && draft.start.isAfter(now))
        _ActionCard(
          icon: Icons.pending_actions_rounded,
          title: l(K.continueBookingTitle),
          subtitle: '${draft.stationName} · ${f.slot(draft.start, draft.end)}',
          onTap: () => context.push(draft.bookingId != null ? '/book/pay/${draft.bookingId}' : (draft.hasContact ? '/book/review' : '/book/details')),
          trailing: TextButton(onPressed: () => ref.read(bookingFlowProvider.notifier).clear(), child: Text(l(K.discard))),
        ),
      if (next != null)
        _ActionCard(
          icon: Icons.event_available_rounded,
          title: l(K.upcomingBooking),
          subtitle: '${next.stationName} · ${f.slot(next.startAt, next.endAt)}',
          onTap: () => context.push('/booking/${next.id}'),
        ),
      if (recent.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Row(children: [
            Expanded(child: Text(l(K.recentlyViewed), style: t.textTheme.titleMedium)),
            TextButton(onPressed: () => ref.read(recentStationsProvider.notifier).clear(), child: Text(l(K.clear))),
          ]),
        ),
        for (final r in recent.take(5))
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.history_rounded)),
              title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(r.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/station/${r.id}'),
            ),
          ),
      ],
      Padding(padding: const EdgeInsets.fromLTRB(4, 18, 4, 8), child: Text(l(K.howItWorks), style: t.textTheme.titleMedium)),
      _HowStep(n: 1, icon: Icons.travel_explore_rounded, title: l(K.how1Title), body: l(K.how1Body)),
      _HowStep(n: 2, icon: Icons.event_available_rounded, title: l(K.how2Title), body: l(K.how2Body)),
      _HowStep(n: 3, icon: Icons.verified_user_outlined, title: l(K.how3Title), body: l(K.how3Body)),
      const SizedBox(height: 12),
      _ActionCard(
        icon: Icons.confirmation_number_outlined,
        title: l(K.findMyBooking),
        subtitle: l(K.findMyBookingHint),
        onTap: () => context.push('/find-booking'),
      ),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: staggered(children)),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.title, required this.subtitle, required this.onTap, this.trailing});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Pressable(
          child: Card(
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(gradient: Brand.gradient, borderRadius: BorderRadius.circular(14)),
                    child: Icon(icon, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                  trailing ?? const Icon(Icons.chevron_right_rounded),
                ]),
              ),
            ),
          ),
        ),
      );
}

class _HowStep extends StatelessWidget {
  const _HowStep({required this.n, required this.icon, required this.title, required this.body});
  final int n;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: t.colorScheme.primary.withValues(alpha: 0.12),
          child: Icon(icon, size: 18, color: t.colorScheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleSmall),
            Text(body, style: t.textTheme.bodySmall?.copyWith(height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}
