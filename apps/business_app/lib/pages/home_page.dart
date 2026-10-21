import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../state.dart';
import '../widgets/station_card.dart';

final _todayProvider = FutureProvider.autoDispose<List<Booking>>((ref) async {
  final station = ref.watch(currentStationProvider);
  final access = ref.watch(currentAccessProvider);
  if (station == null || access == null || !access.can(BusinessPermission.bookingsView, stationId: station.id)) return const [];
  final nowIst = Fmt.toIst(DateTime.now());
  final from = Fmt.fromIst(nowIst.year, nowIst.month, nowIst.day);
  return ref.watch(bookingRepositoryProvider).forStation(station.id, from, from.add(const Duration(days: 1)));
});

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(currentAccessProvider);
    final stations = ref.watch(stationsProvider);
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;
    if (access == null) return const Scaffold(body: Center(child: ChargeLogo(size: 56)));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(children: [
          const ChargeLogo(size: 30, animate: false),
          const SizedBox(width: 8),
          Expanded(child: Text(access.businessName, overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => context.go('/more/notifications'),
            icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_none_rounded)),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(businessAccessProvider);
          ref.invalidate(stationsProvider);
          ref.invalidate(_todayProvider);
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          _AccountBanner(access),
          AsyncView(
            value: stations,
            onRetry: () => ref.invalidate(stationsProvider),
            builder: (list) => list.isEmpty
                ? _FirstStation(canAdd: access.isOwner)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: staggered([
                      if (access.can(BusinessPermission.bookingsView)) const _Today() else _Greeting(name: access.businessName),
                      const SizedBox(height: 20),
                      _QuickActions(access),
                      const SizedBox(height: 24),
                      Row(children: [
                        Expanded(child: Text('Your stations', style: Theme.of(context).textTheme.titleLarge)),
                        if (access.isOwner)
                          TextButton.icon(
                            onPressed: () => context.go('/stations/new'),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add'),
                          ),
                      ]),
                      const SizedBox(height: 8),
                      for (final s in list) StationCard(s),
                    ]),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => HeroHeader(eyebrow: Fmt.greeting(), title: name, subtitle: Fmt.weekday(DateTime.now()));
}

class _AccountBanner extends StatelessWidget {
  const _AccountBanner(this.access);
  final BusinessAccess access;

  @override
  Widget build(BuildContext context) {
    final (tone, icon, text) = switch (access.businessStatus) {
      BusinessStatus.pendingVerification => (
          StatusTone.info,
          Icons.verified_outlined,
          'Your business is verified when its first station is approved. Add a station and submit it for review.'
        ),
      BusinessStatus.suspended => (
          StatusTone.danger,
          Icons.pause_circle_outline_rounded,
          'Your business is suspended${access.businessStatusReason == null ? '' : ': ${access.businessStatusReason}'}. Bookings are paused. Contact ChargeKaro support.'
        ),
      BusinessStatus.deactivated => (StatusTone.danger, Icons.block_rounded, 'This business account is deactivated.'),
      BusinessStatus.active => (StatusTone.neutral, Icons.check, ''),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    final (bg, fg) = tone.colors(Theme.of(context).colorScheme);
    return Entrance(
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppTheme.radius)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: fg),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(color: fg, height: 1.4))),
        ]),
      ),
    );
  }
}

class _FirstStation extends StatelessWidget {
  const _FirstStation({required this.canAdd});
  final bool canAdd;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.ev_station_rounded,
        title: canAdd ? 'Add your first station' : 'No stations assigned',
        message: canAdd
            ? 'Four quick steps: location, charging points, opening hours and documents. Then submit it for review.'
            : 'Ask the business owner to assign you to a station.',
        action: canAdd
            ? GradientButton(label: 'Add a station', icon: Icons.add_rounded, onPressed: () => context.go('/stations/new'))
            : null,
      );
}

class _Today extends ConsumerWidget {
  const _Today();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final station = ref.watch(currentStationProvider);
    final today = ref.watch(_todayProvider);
    final canScan = ref.watch(currentAccessProvider)?.can(BusinessPermission.bookingsCheckin, stationId: station?.id) ?? false;
    final list = today.value ?? const <Booking>[];
    final upcoming = list.where((b) => b.status == BookingStatus.confirmed && b.endAt.isAfter(DateTime.now())).toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    final checkedIn = list.where((b) => b.status == BookingStatus.arrived || b.status == BookingStatus.inProgress).length;
    final done = list.where((b) => b.status == BookingStatus.completed).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      HeroHeader(
        eyebrow: '${Fmt.greeting()} · ${Fmt.weekday(DateTime.now())}',
        title: station?.name ?? 'Today',
        subtitle: today.isLoading && !today.hasValue
            ? 'Loading today\'s bookings…'
            : (list.isEmpty ? 'No bookings yet today' : '${list.length} booking${list.length == 1 ? '' : 's'} today'),
        trailing: canScan
            ? Tooltip(
                message: 'Scan a booking QR',
                child: Pressable(
                  child: Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => context.go('/scan'),
                      child: const Padding(padding: EdgeInsets.all(14), child: Icon(Icons.qr_code_scanner_rounded, color: Brand.greenDeep)),
                    ),
                  ),
                ),
              )
            : null,
        child: today.hasError
            ? TextButton(
                onPressed: () => ref.invalidate(_todayProvider),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Could not load bookings. Tap to retry.'),
              )
            : Row(children: [
                Expanded(child: HeroStat(label: 'Upcoming', count: upcoming.length, icon: Icons.schedule_rounded)),
                const SizedBox(width: 10),
                Expanded(child: HeroStat(label: 'Checked in', count: checkedIn, icon: Icons.bolt_rounded)),
                const SizedBox(width: 10),
                Expanded(child: HeroStat(label: 'Done', count: done, icon: Icons.check_circle_outline_rounded)),
              ]),
      ),
      if (upcoming.isNotEmpty) ...[const SizedBox(height: 14), _UpNext(upcoming.first)],
    ]);
  }
}

class _UpNext extends StatelessWidget {
  const _UpNext(this.b);
  final Booking b;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final soon = b.startAt.difference(DateTime.now()).inMinutes <= 15;
    return Pressable(
      child: Card(
        child: InkWell(
          onTap: () => context.go('/bookings/${b.id}'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(
                width: 56,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(color: t.colorScheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
                child: Column(children: [
                  Text(Fmt.time(b.startAt).split(' ').first, style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w800)),
                  Text(Fmt.time(b.startAt).split(' ').last, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.primary)),
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (soon) ...[PulseDot(color: t.colorScheme.tertiary, size: 7), const SizedBox(width: 2)],
                    Text('Up next ${Fmt.until(b.startAt)}', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                  const SizedBox(height: 2),
                  Text(b.customerDisplayName ?? b.reference, style: t.textTheme.titleMedium),
                  Text(
                    [b.reference, if (b.chargingPointCode != null) 'Point ${b.chargingPointCode}', ?b.vehicleLabel].join(' · '),
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: t.colorScheme.outline),
            ]),
          ),
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions(this.access);
  final BusinessAccess access;

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, String, Color)>[
      if (access.can(BusinessPermission.bookingsCheckin)) (Icons.qr_code_scanner_rounded, 'Check in', '/scan', Brand.green),
      if (access.can(BusinessPermission.bookingsView)) (Icons.calendar_month_rounded, 'Bookings', '/bookings', Brand.ocean),
      (Icons.ev_station_rounded, 'Stations', '/stations', const Color(0xFF7C3AED)),
      (Icons.insights_rounded, 'Reports', '/more/reports', Brand.amber),
    ];
    final t = Theme.of(context);
    return Row(children: [
      for (final (icon, label, path, color) in items)
        Expanded(
          child: Pressable(
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => context.go(path),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(icon, color: color),
                  ),
                  const SizedBox(height: 6),
                  Text(label, style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}
