import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import 'report_sheet.dart';

/// What the customer needs to know about a station, shown below the slot
/// picker: on a trip, where it is on the route and what stopping costs;
/// near me, the driving distance; then points (with how fresh their status
/// is), hours, charging price and rules. Missing data says "unavailable"
/// rather than guessing. The booking fee, refund policy and station phone
/// are left out: the fee is shown on the payment page and the phone only
/// after booking, so customers book in the app instead of calling.
class StationInfo extends ConsumerWidget {
  const StationInfo({super.key, required this.detail});
  final StationDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final s = detail.summary;
    final now = DateTime.now();
    final search = ref.watch(searchProvider);
    // The card from the active search, which carries the route position.
    final fromSearch = search.result?.value?.stations.where((x) => x.id == s.id).firstOrNull;
    final onTrip = search.isTrip && fromSearch?.alongRouteKm != null && search.trip!.plan != null;
    final driving = search.isNearby ? search.driving[s.id] : null;

    final sections = <Widget>[
      if (onTrip) _TripCard(station: fromSearch!, trip: search.trip!),
      if (!s.bookable) _UnavailableCard(detail: detail),
      if (detail.closures.isNotEmpty)
        SectionCard(
          title: l(K.upcomingClosures),
          child: Column(children: [
            for (final c in detail.closures)
              InfoLine(
                icon: Icons.event_busy_rounded,
                label: c.kind == BlockedPeriodKind.maintenance ? l(K.closureMaintenance) : l(K.closureGeneral),
                value: '${f.dateTime(c.startsAt)} – ${f.dateTime(c.endsAt)}',
              ),
          ]),
        ),
      SectionCard(
        title: l(K.chargingPoints),
        trailing: Text(l(K.pointsAvailable, {'a': s.points.available, 'n': s.points.total}), style: t.textTheme.labelMedium),
        child: Column(children: [
          for (final p in detail.points) _PointTile(point: p, now: now),
          const SizedBox(height: 4),
          Text(s.points.telemetry ? l(K.statusTelemetryNote) : l(K.statusManualNote), style: t.textTheme.bodySmall),
        ]),
      ),
      SectionCard(
        title: l(K.openingHours),
        child: _HoursList(summary: s),
      ),
      SectionCard(
        title: l(K.feesTitle),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InfoLine(icon: Icons.bolt_rounded, label: l(K.chargingCost), value: l(K.chargingCostBody)),
          if (s.paymentMethods.isNotEmpty)
            InfoLine(icon: Icons.payments_outlined, label: l(K.payAtStationWith), value: s.paymentMethods.map((m) => m.label).join(', ')),
        ]),
      ),
      SectionCard(title: l(K.bookingRules), child: _RulesList(policy: detail.policy)),
      if (s.amenities.isNotEmpty || s.parkingSpaces > 0)
        SectionCard(
          title: l(K.facilities),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            if (s.parkingSpaces > 0) Pill(l(K.parkingSpaces, {'n': s.parkingSpaces}), icon: Icons.local_parking_rounded),
            for (final a in s.amenities) Pill(a.label, icon: Icons.check_circle_outline_rounded),
          ]),
        ),
      if (detail.description != null && detail.description!.trim().isNotEmpty)
        SectionCard(title: l(K.stationInstructions), child: Text(detail.description!, style: t.textTheme.bodyMedium?.copyWith(height: 1.5))),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => showStationReportSheet(context, ref, s.id),
          icon: const Icon(Icons.flag_outlined),
          label: Text(l(K.reportStationInfo)),
        ),
      ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l(K.aboutStation), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(s.fullAddress, style: t.textTheme.bodyMedium),
      if (s.operatorName != null) Text(l(K.operatedBy, {'name': s.operatorName}), style: t.textTheme.bodySmall),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, children: [
        StationStatusPill(s),
        if (s.distanceKm != null && !onTrip) Pill(l(K.distanceAway, {'d': f.distance(s.distanceKm!)}), icon: Icons.near_me_rounded, tone: StatusTone.info),
        if (driving != null)
          Pill(l(K.drivingDistance, {'d': f.distance(driving.distanceKm), 'time': f.duration(Duration(minutes: driving.durationMinutes))}),
              icon: Icons.directions_car_rounded, tone: StatusTone.info),
        if (s.isDemo) Pill(l(K.demoStation), tone: StatusTone.warning),
      ]),
      const SizedBox(height: 10),
      ConnectorChips(s.connectorTypes, maxPowerKw: s.maxPowerKw),
      if (!onTrip) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => openDirections(context, s.latitude, s.longitude),
          icon: const Icon(Icons.directions_rounded),
          label: Text(l(K.directions)),
        ),
      ],
      const SizedBox(height: 16),
      for (final w in sections) Padding(padding: const EdgeInsets.only(bottom: 12), child: w),
    ]);
  }
}

class _UnavailableCard extends StatelessWidget {
  const _UnavailableCard({required this.detail});
  final StationDetail detail;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final s = detail.summary;
    final (title, body) = switch (s.unavailableReason) {
      UnavailableReason.temporarilyClosed => (
          l(K.stationClosedTitle),
          s.closedUntil != null ? l(K.stationClosedUntil, {'when': f.dateTime(s.closedUntil!)}) : l(K.stationClosedBody),
        ),
      UnavailableReason.noBookablePoints => (l(K.noBookablePointsTitle), l(K.noBookablePointsBody)),
      _ => (l(K.stationNotAcceptingTitle), l(K.stationNotAcceptingBody)),
    };
    return Card(
      color: StatusTone.warning.colors(Theme.of(context).colorScheme).$1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.info_outline_rounded),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
          ]),
          const SizedBox(height: 6),
          Text(body),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => context.push('/alternatives?exclude=${s.id}&lat=${s.latitude}&lng=${s.longitude}'),
            icon: const Icon(Icons.alt_route_rounded),
            label: Text(l(K.seeAlternatives)),
          ),
        ]),
      ),
    );
  }
}

class _PointTile extends StatelessWidget {
  const _PointTile({required this.point, required this.now});
  final PointInfo point;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final p = point;
    final (statusText, tone, icon) = !p.bookable
        ? (pointReason(l, p.unavailableReason), StatusTone.danger, Icons.build_circle_outlined)
        : switch (p.status) {
            PointStatus.available => (l(K.pointAvailable), StatusTone.success, Icons.check_circle_rounded),
            PointStatus.inUse => (l(K.pointInUse), StatusTone.info, Icons.timelapse_rounded),
            _ => (l(K.pointUnavailable), StatusTone.warning, Icons.build_circle_outlined),
          };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: t.colorScheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
          child: Icon(p.currentType == CurrentType.dc ? Icons.flash_on_rounded : Icons.power_rounded, color: t.colorScheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.label, style: t.textTheme.titleSmall),
            Text('${p.currentType.label} · ${f.power(p.maxPowerKw)} · ${p.connectors.map((c) => c.type.label).join(', ')}', style: t.textTheme.bodySmall),
            if (p.vehicleTypes.isNotEmpty) Text(l(K.suitsVehicles, {'v': p.vehicleTypes.map((v) => v.label).join(', ')}), style: t.textTheme.bodySmall),
            if (p.restrictionsNote != null && p.restrictionsNote!.isNotEmpty)
              Text(p.restrictionsNote!, style: t.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Pill(statusText, icon: icon, tone: tone, dense: true),
              if (p.statusUpdatedAt != null)
                Text(p.telemetry ? l(K.liveStatus, {'when': f.ago(p.statusUpdatedAt!, now)}) : l(K.reportedStatus, {'when': f.ago(p.statusUpdatedAt!, now)}),
                    style: t.textTheme.labelSmall),
            ]),
          ]),
        ),
      ]),
    );
  }
}

String pointReason(L l, String? reason) => switch (reason) {
      'maintenance' => l(K.pointMaintenance),
      'out_of_service' => l(K.pointOutOfService),
      'booking_disabled' => l(K.pointNoBookings),
      _ => l(K.pointUnavailable),
    };

class _RulesList extends StatelessWidget {
  const _RulesList({required this.policy});
  final SlotPolicy policy;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final p = policy;
    return Column(children: [
      InfoLine(icon: Icons.timelapse_rounded, label: l(K.ruleDuration), value: l(K.ruleDurationValue, {'min': f.duration(Duration(minutes: p.minBookingMinutes)), 'max': f.duration(Duration(minutes: p.maxBookingMinutes)), 'step': p.slotMinutes})),
      InfoLine(icon: Icons.event_rounded, label: l(K.ruleWindow), value: l(K.ruleWindowValue, {'mins': p.minAdvanceMinutes, 'days': p.maxAdvanceDays})),
      InfoLine(
        icon: Icons.login_rounded,
        label: l(K.ruleArrival),
        value: l(K.ruleArrivalValue, {'before': p.reportBeforeMinutes, 'grace': p.arrivalGraceMinutes}),
      ),
      InfoLine(icon: Icons.person_off_outlined, label: l(K.ruleNoShow), value: p.autoNoShow ? l(K.ruleNoShowAuto, {'grace': p.arrivalGraceMinutes}) : l(K.ruleNoShowManual)),
      InfoLine(icon: Icons.more_time_rounded, label: l(K.ruleExtension), value: l(K.ruleExtensionValue)),
      if (p.bufferMinutes > 0) InfoLine(icon: Icons.space_bar_rounded, label: l(K.ruleBuffer), value: l(K.ruleBufferValue, {'mins': p.bufferMinutes})),
    ]);
  }
}

/// Along My Route: the extra distance and time of stopping at a station,
/// from the route through it. Keyed by station; the trip comes from search.
final detourProvider = FutureProvider.autoDispose.family<Detour, String>((ref, stationId) async {
  final search = ref.read(searchProvider);
  final trip = search.trip!;
  final station = search.result!.value!.stations.firstWhere((x) => x.id == stationId);
  return ref.read(retailRepositoryProvider).detour(trip.from, trip.to, trip.plan!, station.latitude, station.longitude);
});

class _TripCard extends ConsumerWidget {
  const _TripCard({required this.station, required this.trip});
  final StationSummary station;
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final s = station;
    final off = s.offRouteKm ?? 0;
    final detour = ref.watch(detourProvider(s.id));
    return SectionCard(
      title: l(K.onYourTrip),
      trailing: off <= onRouteKm
          ? Pill(l(K.onRoute), icon: Icons.check_circle_outline_rounded, tone: StatusTone.success, dense: true)
          : Pill(l(K.needsDetour), icon: Icons.turn_right_rounded, tone: StatusTone.warning, dense: true),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InfoLine(
          icon: Icons.route_rounded,
          label: l(K.alongTripLabel),
          value: l(K.alongTripValue, {'d': f.distance(s.alongRouteKm!), 'from': trip.from.label}),
        ),
        InfoLine(icon: Icons.straighten_rounded, label: l(K.fromRouteLabel), value: off <= onRouteKm ? l(K.onRoute) : f.distance(off)),
        InfoLine(
          icon: Icons.turn_right_rounded,
          label: l(K.detourLabel),
          value: detour.when(
            loading: () => l(K.detourLoading),
            error: (_, _) => l(K.detourUnavailable, {'d': f.distance(off * 2)}),
            data: (d) => d.extraKm < 0.1 ? l(K.detourNone) : l(K.detourValue, {'d': f.distance(d.extraKm), 'time': f.duration(Duration(minutes: d.extraMinutes))}),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(
            onPressed: () => openDirections(context, s.latitude, s.longitude),
            icon: const Icon(Icons.directions_rounded),
            label: Text(l(K.directionsToStation)),
          ),
          OutlinedButton.icon(
            onPressed: () => openDirectionsVia(context, s.latitude, s.longitude, trip.to.latitude, trip.to.longitude),
            icon: const Icon(Icons.flag_rounded),
            label: Text(l(K.continueToDestination, {'to': trip.to.label})),
          ),
        ]),
        const SizedBox(height: 4),
        Text(l(K.tripDistanceNote), style: t.textTheme.bodySmall),
      ]),
    );
  }
}

/// Weekly hours, or "unavailable" when the station has not listed them.
class _HoursList extends StatelessWidget {
  const _HoursList({required this.summary});
  final StationSummary summary;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final s = summary;
    if (s.hours.isEmpty) return Text(l(K.hoursUnknown), style: t.textTheme.bodyMedium);
    if (s.is24x7) return Text(l(K.open24h), style: t.textTheme.bodyMedium);
    // 2024-01-01 was a Monday, so day 1..7 maps onto that week.
    String day(int d) => f.weekdayShort(DateTime.utc(2024, 1, d));
    final byDay = <int, List<HoursRange>>{};
    for (final h in s.hours) {
      byDay.putIfAbsent(h.day, () => []).add(h);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var d = 1; d <= 7; d++)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(children: [
            SizedBox(width: 56, child: Text(day(d), style: t.textTheme.labelLarge)),
            Expanded(
              child: Text(
                byDay[d] == null
                    ? l(K.closed)
                    : byDay[d]!.map((h) => h.opens == 0 && h.closes == 1440 ? l(K.open24h) : '${f.minutesOfDay(h.opens)} – ${f.minutesOfDay(h.closes)}').join(', '),
                style: t.textTheme.bodyMedium,
              ),
            ),
          ]),
        ),
    ]);
  }
}
