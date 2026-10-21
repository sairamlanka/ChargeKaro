import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../state.dart';

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
    if (access == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: Text(access.businessName)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(businessAccessProvider);
          ref.invalidate(stationsProvider);
          ref.invalidate(_todayProvider);
        },
        child: ListView(padding: const EdgeInsets.all(16), children: [
          _AccountBanner(access),
          AsyncView(
            value: stations,
            onRetry: () => ref.invalidate(stationsProvider),
            builder: (list) => list.isEmpty
                ? _FirstStation(canAdd: access.isOwner)
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (access.can(BusinessPermission.bookingsView)) const _Today(),
                    const SizedBox(height: 16),
                    Text('Stations', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final s in list) _StationCard(s),
                  ]),
          ),
        ]),
      ),
    );
  }
}

class _AccountBanner extends StatelessWidget {
  const _AccountBanner(this.access);
  final BusinessAccess access;

  @override
  Widget build(BuildContext context) {
    final (tone, text) = switch (access.businessStatus) {
      BusinessStatus.pendingVerification => (
          StatusTone.info,
          'Your business is verified when its first station is approved. Add a station and submit it for review.'
        ),
      BusinessStatus.suspended => (
          StatusTone.danger,
          'Your business is suspended${access.businessStatusReason == null ? '' : ': ${access.businessStatusReason}'}. Bookings are paused. Contact ChargeKaro support.'
        ),
      BusinessStatus.deactivated => (StatusTone.danger, 'This business account is deactivated.'),
      BusinessStatus.active => (StatusTone.neutral, ''),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    final (bg, fg) = tone.colors(Theme.of(context).colorScheme);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Text(text, style: TextStyle(color: fg)),
    );
  }
}

class _FirstStation extends StatelessWidget {
  const _FirstStation({required this.canAdd});
  final bool canAdd;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.ev_station_outlined,
        title: canAdd ? 'Add your first station' : 'No stations assigned',
        message: canAdd
            ? 'Enter the address and location, add charging points and hours, upload documents, then submit for review.'
            : 'Ask the business owner to assign you to a station.',
        action: canAdd ? FilledButton(onPressed: () => context.go('/stations/new'), child: const Text('Add station')) : null,
      );
}

class _Today extends ConsumerWidget {
  const _Today();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final station = ref.watch(currentStationProvider);
    final today = ref.watch(_todayProvider);
    return SectionCard(
      title: 'Today at ${station?.name ?? ''}',
      trailing: IconButton(tooltip: 'Scan a booking QR', icon: const Icon(Icons.qr_code_scanner), onPressed: () => context.go('/scan')),
      child: AsyncView(
        value: today,
        onRetry: () => ref.invalidate(_todayProvider),
        builder: (list) {
          final active = list.where((b) => b.status.holdsSlot).toList();
          final upcoming = active.where((b) => b.status == BookingStatus.confirmed && b.endAt.isAfter(DateTime.now())).toList();
          final checkedIn = list.where((b) => b.status == BookingStatus.arrived || b.status == BookingStatus.inProgress).length;
          final noShows = list.where((b) => b.status == BookingStatus.noShow).length;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: _Stat('Upcoming', '${upcoming.length}')),
              Expanded(child: _Stat('Checked in', '$checkedIn')),
              Expanded(child: _Stat('No-shows', '$noShows')),
            ]),
            if (upcoming.isNotEmpty) ...[
              const Divider(),
              Text('Next: ${upcoming.first.reference} at ${Fmt.time(upcoming.first.startAt)} on ${upcoming.first.chargingPointCode ?? ''}'),
            ],
            if (list.isEmpty) const Text('No bookings today.'),
          ]);
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(children: [
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _StationCard extends ConsumerWidget {
  const _StationCard(this.s);
  final Station s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(applicationProvider(s.id)).value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          title: Text(s.name),
          subtitle: Text('${s.city} · ${app == null || app.status == ApplicationStatus.approved ? s.status.label : 'Application: ${app.status.label}'}'),
          trailing: app != null && app.status != ApplicationStatus.approved ? StatusChip.application(app.status) : StatusChip.station(s.status),
          onTap: () => context.go('/stations/${s.id}'),
        ),
      ),
    );
  }
}
