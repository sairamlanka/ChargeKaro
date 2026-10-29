import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/location_service.dart';
import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/map_view.dart';
import '../common/widgets.dart';
import 'filter_sheet.dart';

/// Home and search results in one place: plan a trip (stations along the
/// route) or use the current location (stations nearby), then browse them
/// as a list or on a map. No sign-in is ever asked for here.
class ExploreScreen extends ConsumerWidget {
  const ExploreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(searchProvider);
    final hasResults = search.active;
    if (hasResults && search.view == ViewMode.map && search.result?.value != null && search.result!.value!.inServiceArea) {
      final anchor = search.anchor!;
      return Scaffold(
        body: Column(children: [
          const _Hero(compact: true),
          const _ResultsToolbar(),
          Expanded(
            child: StationsMap(
              stations: search.visible(DateTime.now()),
              driving: search.driving,
              centerLat: anchor.latitude,
              centerLng: anchor.longitude,
              radiusKm: search.rangeKm,
              route: search.trip?.plan?.path,
              showUserDot: search.isNearby,
              onOpen: (s) => context.push(slotsRoute(s)),
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
            const SliverToBoxAdapter(child: _NextBookingBanner()),
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
    final trip = search.trip;
    final fromLabel = trip == null ? '' : (trip.from.fromDevice ? l(K.yourLocation) : trip.from.label);
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
                Entrance(index: 2, child: _ModeTabs(mode: search.mode, onChanged: ref.read(searchProvider.notifier).setMode)),
                const SizedBox(height: 10),
                Entrance(
                  index: 3,
                  child: AnimatedSwitcher(
                    duration: Motion.fast,
                    child: search.mode == SearchMode.route
                        ? Semantics(
                            key: const ValueKey('route'),
                            button: true,
                            label: trip == null ? l(K.tripSearchHint) : l(K.tripSummary, {'from': fromLabel, 'to': trip.to.label}),
                            excludeSemantics: true,
                            child: Material(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              elevation: 6,
                              shadowColor: Colors.black38,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () => context.push('/route-search'),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  child: Row(children: [
                                    const Icon(Icons.alt_route_rounded, color: Brand.greenDeep),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: trip == null
                                          ? Text(
                                              l(K.tripSearchHint),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: t.textTheme.bodyLarge?.copyWith(color: Colors.blueGrey.shade400),
                                            )
                                          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                              Text(fromLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: Colors.blueGrey.shade600)),
                                              Text(trip.to.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge?.copyWith(color: Brand.ink)),
                                            ]),
                                    ),
                                  ]),
                                ),
                              ),
                            ),
                          )
                        : Column(key: const ValueKey('nearby'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Brand.greenDeep,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: locating ? null : () => ref.read(searchProvider.notifier).useCurrentLocation(),
                              icon: locating
                                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                  : Icon(search.origin?.fromDevice == true ? Icons.refresh_rounded : Icons.my_location_rounded),
                              label: Text(locating
                                  ? l(K.locating)
                                  : (search.origin?.fromDevice == true ? l(K.updateMyLocation) : l(K.findNearbyStations))),
                            ),
                            TextButton.icon(
                              style: TextButton.styleFrom(foregroundColor: Colors.white),
                              onPressed: () => context.push('/pick-location'),
                              icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
                              label: Text(search.origin != null && !search.origin!.fromDevice
                                  ? l(K.nearPlaceChange, {'place': search.origin!.label})
                                  : l(K.chooseLocationInstead)),
                            ),
                          ]),
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

/// Source & destination, or live location: one search at a time.
class _ModeTabs extends StatelessWidget {
  const _ModeTabs({required this.mode, required this.onChanged});
  final SearchMode mode;
  final ValueChanged<SearchMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    Widget tab(SearchMode m, IconData icon, String label) {
      final selected = m == mode;
      return Expanded(
        child: Semantics(
          selected: selected,
          button: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onChanged(m),
            child: AnimatedContainer(
              duration: Motion.fast,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              decoration: BoxDecoration(
                color: selected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 18, color: selected ? Brand.greenDeep : Colors.white),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.labelLarge?.copyWith(color: selected ? Brand.greenDeep : Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        tab(SearchMode.route, Icons.alt_route_rounded, l(K.modeRoute)),
        const SizedBox(width: 4),
        tab(SearchMode.nearby, Icons.my_location_rounded, l(K.modeLive)),
      ]),
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
                  FallbackAction(l(K.chooseLocationInstead), () => context.push('/pick-location'), icon: Icons.edit_location_alt_outlined),
                  FallbackAction(l(K.searchByRoute), () {
                    notifier.setMode(SearchMode.route);
                    context.push('/route-search');
                  }, icon: Icons.alt_route_rounded),
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
    final origin = s.isNearby ? s.origin : null;
    final trip = s.isTrip ? s.trip : null;
    final loc = origin?.location;
    final now = DateTime.now();
    final String title;
    final String subtitle;
    if (trip != null) {
      final plan = trip.plan;
      title = l(K.tripSummary, {'from': trip.from.fromDevice ? l(K.yourLocation) : trip.from.label, 'to': trip.to.label});
      subtitle = [
        if (plan != null) l(K.routeLength, {'km': plan.distanceKm.toStringAsFixed(0), 'time': f.duration(Duration(minutes: plan.durationMinutes))}),
        l(K.withinOfRoute, {'km': _km(s.rangeKm)}),
      ].join(' · ');
    } else {
      title = origin!.fromDevice ? l(K.nearYou) : l(K.nearPlace, {'place': origin.label});
      subtitle = l(K.withinRadius, {'km': _km(s.rangeKm)});
    }
    final routes = trip?.routes ?? const <RoutePlan>[];
    final result = s.result?.value;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // The search mode stays visible so route results are never
            // mistaken for nearby ones.
            Pill(
              trip != null ? l(K.modeRoute) : l(K.modeLive),
              icon: trip != null ? Icons.alt_route_rounded : Icons.my_location_rounded,
              tone: StatusTone.info,
              dense: true,
            ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(title, style: t.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Text(subtitle, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
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
            if (routes.length > 1) ...[
              const SizedBox(height: 10),
              Text(l(K.chooseRoute), style: t.textTheme.labelLarge),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final (i, r) in routes.indexed)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        avatar: const Icon(Icons.alt_route_rounded, size: 16),
                        label: Text(l(K.routeOption, {
                          'n': i + 1,
                          'km': r.distanceKm.toStringAsFixed(0),
                          'time': f.duration(Duration(minutes: r.durationMinutes)),
                        })),
                        selected: trip!.selected == i,
                        onSelected: (_) => n.selectRoute(i),
                      ),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final r in s.rangeOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(l(K.radiusKm, {'km': _km(r)})),
                      selected: s.rangeKm == r,
                      onSelected: (_) => n.setRange(r),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: _SortMenu(sort: s.effectiveSort, onChanged: n.setSort, onTrip: trip != null),
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
            if (result != null && result.truncated)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Pill(l(K.moreStationsNote, {'n': result.stations.length, 'total': result.totalFound}), icon: Icons.info_outline_rounded),
              ),
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

/// "5 km", or "0.5 km" for the smallest settings.
String _km(double km) => km == km.roundToDouble() ? km.toStringAsFixed(0) : km.toStringAsFixed(1);

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.onChanged, required this.onTrip});
  final SortOrder sort;
  final ValueChanged<SortOrder> onChanged;
  final bool onTrip;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    String label(SortOrder s) => switch (s) {
          SortOrder.bestStop => l(K.sortBestStop),
          SortOrder.nearest => onTrip ? l(K.sortAlongRoute) : l(K.sortNearest),
          SortOrder.earliestSlot => l(K.sortEarliest),
          SortOrder.lowestFee => l(K.sortLowestFee),
          SortOrder.mostAvailable => l(K.sortMostAvailable),
        };
    return PopupMenuButton<SortOrder>(
      tooltip: l(K.sortBy),
      initialValue: sort,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final s in SortOrder.values)
          if (onTrip || s != SortOrder.bestStop) PopupMenuItem(value: s, child: Text(label(s))),
      ],
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
    final onTrip = s.isTrip;
    // Look somewhere else: a different trip, or plan one after a nearby search.
    final elsewhere = FallbackAction(onTrip ? l(K.changeRoute) : l(K.searchByRoute), () {
      n.setMode(SearchMode.route);
      context.push('/route-search');
    }, icon: Icons.alt_route_rounded);
    final bigger = s.rangeOptions.where((r) => r > s.rangeKm).toList();
    final widen = bigger.isEmpty
        ? null
        : FallbackAction(l(K.widenTo, {'km': _km(bigger.first)}), () => n.setRange(bigger.first), icon: Icons.zoom_out_map_rounded, primary: true);

    if (result == null || (result.isLoading && !result.hasValue)) {
      return box(const SizedBox(height: 420, child: SlowLoading()));
    }
    if (result.hasError && !result.hasValue) {
      return box(FailureView(error: result.error!, onRetry: n.refresh, compact: true, extra: [elsewhere]));
    }
    final data = result.value!;
    if (!data.inServiceArea) {
      return box(FallbackView(
        compact: true,
        icon: Icons.public_off_rounded,
        title: l(K.outsideAreaTitle),
        message: l(K.outsideAreaBody),
        actions: [FallbackAction(elsewhere.label, elsewhere.onPressed, icon: elsewhere.icon, primary: true)],
      ));
    }
    if (data.stations.isEmpty) {
      return box(FallbackView(
        compact: true,
        icon: Icons.ev_station_outlined,
        title: onTrip ? l(K.noRouteStationsTitle, {'km': _km(s.rangeKm)}) : l(K.noStationsTitle, {'km': _km(s.rangeKm)}),
        message: onTrip ? l(K.noRouteStationsBody) : l(K.noStationsBody),
        actions: [?widen, elsewhere],
      ));
    }
    final visible = s.visible(DateTime.now());
    if (visible.isEmpty && !data.stations.any((x) => s.isOpenFor(x, DateTime.now()))) {
      return box(FallbackView(
        compact: true,
        icon: Icons.nightlight_round,
        title: l(K.noOpenStationsTitle),
        message: l(K.noOpenStationsBody),
        actions: [?widen, elsewhere],
      ));
    }
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
                  child: Entrance(index: i, child: StationCard(station: st, driving: s.driving[st.id], arriveAt: s.arrival(st, DateTime.now()), onOpen: () => context.push(slotsRoute(st)))),
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

/// A signed-in customer's next booking stays at the top of home, above the
/// station list, with the time to reach the station.
class _NextBookingBanner extends ConsumerWidget {
  const _NextBookingBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = ref.watch(nextBookingProvider);
    if (next == null) return const SizedBox.shrink();
    final l = context.l;
    final f = RFmt(l);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Entrance(
            child: _ActionCard(
              icon: Icons.event_available_rounded,
              title: l(K.upcomingBooking),
              subtitle: '${next.stationName} · ${f.slot(next.startAt, next.endAt)}\n'
                  '${l(K.reportByLabel)}: ${l(K.reportByValue, {'time': f.time(next.reportBy), 'mins': next.policy.reportBeforeMinutes})}',
              onTap: () => context.push('/booking/${next.id}'),
            ),
          ),
        ),
      ),
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
          subtitle: '${next.stationName} · ${f.slot(next.startAt, next.endAt)}\n'
              '${l(K.reportByLabel)}: ${l(K.reportByValue, {'time': f.time(next.reportBy), 'mins': next.policy.reportBeforeMinutes})}',
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
                      Text(subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
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
