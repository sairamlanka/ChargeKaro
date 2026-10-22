import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import 'report_sheet.dart';

class StationScreen extends ConsumerWidget {
  const StationScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final value = ref.watch(stationProvider(id));
    ref.listen(stationProvider(id), (_, next) {
      final d = next.value;
      if (d != null && d.isPublic) ref.read(recentStationsProvider.notifier).add(d.summary);
    });
    return value.when(
      skipLoadingOnRefresh: true,
      loading: () => Scaffold(appBar: AppBar(), body: const SlowLoading()),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: Text(l(K.stationDetails))),
        body: FailureView(
          error: e,
          title: l(K.stationUnavailableTitle),
          onRetry: () => ref.invalidate(stationProvider(id)),
          extra: [FallbackAction(l(K.backToResults), () => context.pop(), icon: Icons.arrow_back_rounded)],
        ),
      ),
      data: (d) => _StationView(detail: d),
    );
  }
}

class _StationView extends ConsumerWidget {
  const _StationView({required this.detail});
  final StationDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final s = detail.summary;
    final now = DateTime.now();

    if (!detail.isPublic) {
      return Scaffold(
        appBar: AppBar(title: Text(s.name)),
        body: FallbackView(
          icon: Icons.block_rounded,
          title: l(K.stationNotAcceptingTitle),
          message: l(K.stationNotAcceptingBody),
          tone: StatusTone.warning,
          actions: [
            FallbackAction(l(K.seeAlternatives), () => context.push('/alternatives?exclude=${s.id}'), icon: Icons.alt_route_rounded, primary: true),
            FallbackAction(l(K.backToResults), () => context.pop(), icon: Icons.arrow_back_rounded),
          ],
        ),
      );
    }

    final sections = <Widget>[
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
      SectionCard(title: l(K.openingHours), child: _HoursTable(hours: s.hours, now: now)),
      SectionCard(
        title: l(K.feesTitle),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InfoLine(icon: Icons.receipt_long_rounded, label: l(K.bookingFee), value: s.bookingFee.isZero ? l(K.free) : l(K.feeInclTaxes, {'fee': f.money(s.bookingFee)}), emphasize: true),
          InfoLine(icon: Icons.bolt_rounded, label: l(K.chargingCost), value: l(K.chargingCostBody)),
          if (s.paymentMethods.isNotEmpty)
            InfoLine(icon: Icons.payments_outlined, label: l(K.payAtStationWith), value: s.paymentMethods.map((m) => m.label).join(', ')),
        ]),
      ),
      SectionCard(title: l(K.bookingRules), child: _RulesList(policy: detail.policy)),
      SectionCard(
        title: l(K.cancellationRefunds),
        child: RefundPolicyText(policy: detail.refundPolicy, fee: s.bookingFee, cancelUntilMinutes: detail.policy.cancelUntilMinutes),
      ),
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
      SectionCard(
        title: l(K.contactSupport),
        child: Column(children: [
          if (detail.contactPhone != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.call_rounded),
              title: Text(l(K.callStation)),
              subtitle: Text(detail.contactPhone!),
              onTap: () => callPhone(context, detail.contactPhone!),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.flag_outlined),
            title: Text(l(K.reportStationInfo)),
            subtitle: Text(l(K.reportStationInfoHint)),
            onTap: () => showStationReportSheet(context, ref, s.id),
          ),
        ]),
      ),
    ];

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(stationProvider(s.id)),
        child: CustomScrollView(slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 250,
            foregroundColor: Colors.white,
            backgroundColor: Brand.night,
            title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              titlePadding: EdgeInsets.zero,
              title: const SizedBox.shrink(),
              background: AuroraBackground(
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 56, 20, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text(s.name, style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800), maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (s.operatorName != null)
                        Text(l(K.operatedBy, {'name': s.operatorName}), style: t.textTheme.bodySmall?.copyWith(color: Colors.white70)),
                      const SizedBox(height: 6),
                      Text(s.fullAddress, style: t.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.9)), maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 10),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        StationStatusPill(s),
                        if (s.distanceKm != null) Pill(l(K.distanceAway, {'d': f.distance(s.distanceKm!)}), icon: Icons.near_me_rounded, tone: StatusTone.info),
                        if (s.isDemo) Pill(l(K.demoStation), tone: StatusTone.warning),
                      ]),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => openDirections(context, s.latitude, s.longitude),
                          icon: const Icon(Icons.directions_rounded),
                          label: Text(l(K.directions)),
                        ),
                      ),
                      if (detail.contactPhone != null) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => callPhone(context, detail.contactPhone!),
                            icon: const Icon(Icons.call_rounded),
                            label: Text(l(K.call)),
                          ),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 12),
                    ConnectorChips(s.connectorTypes, maxPowerKw: s.maxPowerKw),
                    const SizedBox(height: 16),
                    for (final (i, w) in sections.indexed) Padding(padding: const EdgeInsets.only(bottom: 12), child: Entrance(index: i, child: w)),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
      bottomNavigationBar: BottomBar(
        child: Row(children: [
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.nextAvailable != null && s.bookable ? l(K.nextFreeSlot) : l(K.bookingFee), style: t.textTheme.labelSmall),
              Text(
                s.nextAvailable != null && s.bookable ? f.whenStarts(s.nextAvailable!.startAt, now) : (s.bookingFee.isZero ? l(K.free) : f.money(s.bookingFee)),
                style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ]),
          ),
          SizedBox(
            width: 200,
            child: s.bookable
                ? GradientButton(label: l(K.chooseSlot), icon: Icons.arrow_forward_rounded, onPressed: () => context.push(slotsRoute(s)))
                : OutlinedButton.icon(
                    onPressed: () => context.push('/alternatives?exclude=${s.id}&lat=${s.latitude}&lng=${s.longitude}'),
                    icon: const Icon(Icons.alt_route_rounded),
                    label: Text(l(K.seeAlternatives)),
                  ),
          ),
        ]),
      ),
    );
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

class _HoursTable extends StatelessWidget {
  const _HoursTable({required this.hours, required this.now});
  final List<HoursRange> hours;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    if (hours.isEmpty) return Text(l(K.hoursUnknown));
    final today = Fmt.toIst(now).weekday;
    return Column(children: [
      for (var d = 1; d <= 7; d++)
        Builder(builder: (context) {
          final ranges = hours.where((h) => h.day == d).toList();
          final isToday = d == today;
          final style = isToday ? t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: t.colorScheme.primary) : t.textTheme.bodyMedium;
          final dayName = f.weekdayShort(DateTime.utc(2024, 1, d)); // 1 Jan 2024 was a Monday
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 90, child: Text(isToday ? '$dayName (${l(K.today)})' : dayName, style: style)),
              Expanded(
                child: Text(
                  ranges.isEmpty
                      ? l(K.closed)
                      : ranges.map((r) => r.opens == 0 && r.closes == 1440 ? l(K.open24h) : '${f.minutesOfDay(r.opens)} – ${f.minutesOfDay(r.closes)}').join(', '),
                  style: style,
                  textAlign: TextAlign.end,
                ),
              ),
            ]),
          );
        }),
      const SizedBox(height: 6),
      Align(alignment: Alignment.centerLeft, child: Text(l(K.timesInIst), style: t.textTheme.bodySmall)),
    ]);
  }
}

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
        value: l(K.ruleArrivalValue, {'early': p.earlyCheckinMinutes, 'grace': p.arrivalGraceMinutes}),
      ),
      InfoLine(icon: Icons.person_off_outlined, label: l(K.ruleNoShow), value: p.autoNoShow ? l(K.ruleNoShowAuto, {'grace': p.arrivalGraceMinutes}) : l(K.ruleNoShowManual)),
      InfoLine(icon: Icons.more_time_rounded, label: l(K.ruleExtension), value: l(K.ruleExtensionValue)),
      if (p.bufferMinutes > 0) InfoLine(icon: Icons.space_bar_rounded, label: l(K.ruleBuffer), value: l(K.ruleBufferValue, {'mins': p.bufferMinutes})),
    ]);
  }
}
