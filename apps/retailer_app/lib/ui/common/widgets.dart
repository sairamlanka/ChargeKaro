import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import 'format.dart';

/// Opens turn-by-turn directions in the device's maps app (no API key needed).
Future<void> openDirections(BuildContext context, double lat, double lng) async {
  final messenger = ScaffoldMessenger.of(context);
  final msg = context.l(K.directionsFailed);
  final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok) messenger.showSnackBar(SnackBar(content: Text(msg)));
}

/// Directions to [stopLat]/[stopLng], then on to the trip's destination, so
/// the driver can resume the journey after charging.
Future<void> openDirectionsVia(BuildContext context, double stopLat, double stopLng, double destLat, double destLng) async {
  final messenger = ScaffoldMessenger.of(context);
  final msg = context.l(K.directionsFailed);
  final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$destLat,$destLng&waypoints=$stopLat,$stopLng');
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok) messenger.showSnackBar(SnackBar(content: Text(msg)));
}

Future<void> callPhone(BuildContext context, String phone) async {
  final messenger = ScaffoldMessenger.of(context);
  final msg = context.l(K.callFailed, {'phone': phone});
  final ok = await launchUrl(Uri.parse('tel:$phone')).catchError((_) => false);
  if (!ok) messenger.showSnackBar(SnackBar(content: Text(msg)));
}

/// A small icon + text pill. Meaning is always in the text.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.icon, this.tone = StatusTone.neutral, this.dense = false});
  final String label;
  final IconData? icon;
  final StatusTone tone;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = tone.colors(Theme.of(context).colorScheme);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: dense ? 3 : 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: dense ? 13 : 15, color: fg), const SizedBox(width: 4)],
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600, fontSize: dense ? 11.5 : null)),
        ),
      ]),
    );
  }
}

/// Station availability in words, with a tone. Never presented as live
/// unless the station reports telemetry.
class StationStatusPill extends StatelessWidget {
  const StationStatusPill(this.s, {super.key});
  final StationSummary s;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (!s.bookable) {
      return switch (s.unavailableReason) {
        UnavailableReason.temporarilyClosed => Pill(l(K.statusTempClosed), icon: Icons.do_not_disturb_on_outlined, tone: StatusTone.warning),
        UnavailableReason.noBookablePoints => Pill(l(K.statusNoBookablePoints), icon: Icons.build_circle_outlined, tone: StatusTone.warning),
        _ => Pill(l(K.statusNotAccepting), icon: Icons.block_rounded, tone: StatusTone.danger),
      };
    }
    if (!s.open.openNow) return Pill(l(K.statusClosedNow), icon: Icons.nightlight_round, tone: StatusTone.neutral);
    if (s.points.available > 0) return Pill(l(K.statusOpen), icon: Icons.bolt_rounded, tone: StatusTone.success);
    return Pill(l(K.statusBusy), icon: Icons.timelapse_rounded, tone: StatusTone.info);
  }
}

/// "2 of 3 points available · reported 5 min ago".
class PointCountsLine extends StatelessWidget {
  const PointCountsLine(this.p, {super.key, this.now});
  final PointCounts p;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final when = p.updatedAt == null ? null : f.ago(p.updatedAt!, now ?? DateTime.now());
    final stale = p.updatedAt != null && (now ?? DateTime.now()).difference(p.updatedAt!) > const Duration(hours: 6);
    return Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Icon(Icons.ev_station_rounded, size: 16, color: t.colorScheme.primary),
      Text(l(K.pointsAvailable, {'a': p.available, 'n': p.total}), style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
      if (p.unavailable > 0) Text('· ${l(K.pointsUnavailable, {'n': p.unavailable})}', style: t.textTheme.bodySmall),
      if (when != null)
        Text(
          p.telemetry ? '· ${l(K.liveStatus, {'when': when})}' : '· ${l(K.reportedStatus, {'when': when})}',
          style: t.textTheme.bodySmall?.copyWith(color: stale ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
        ),
    ]);
  }
}

class ConnectorChips extends StatelessWidget {
  const ConnectorChips(this.types, {super.key, this.maxPowerKw});
  final List<ConnectorType> types;
  final double? maxPowerKw;

  @override
  Widget build(BuildContext context) {
    final f = RFmt(context.l);
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final c in types) Pill(c.label, icon: Icons.electrical_services_rounded, dense: true),
      if (maxPowerKw != null) Pill(context.l(K.upToPower, {'p': f.power(maxPowerKw!)}), icon: Icons.speed_rounded, dense: true, tone: StatusTone.info),
    ]);
  }
}

/// The search-result card for one station.
class StationCard extends StatelessWidget {
  const StationCard({super.key, required this.station, required this.onOpen, this.compact = false, this.driving, this.arriveAt});
  final StationSummary station;
  final VoidCallback onOpen;
  final bool compact;

  /// Near Me: distance by road, when the routing service gave one.
  final DrivingDistance? driving;

  /// Along My Route: when the driver should get there, leaving now.
  final DateTime? arriveAt;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final s = station;
    final now = DateTime.now();
    final next = s.nextAvailable;
    return Pressable(
      child: Card(
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _StationAvatar(s),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.name, style: t.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(s.shortAddress, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                if (s.alongRouteKm != null) ...[
                  // Route search: where on the trip, and the detour off it.
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(f.distance(s.alongRouteKm!), style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w800)),
                    Text(l(K.fromStart), style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    if (s.offRouteKm != null && s.offRouteKm! > onRouteKm)
                      Text(l(K.offRoute, {'d': f.distance(s.offRouteKm!)}), style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ] else if (s.distanceKm != null) ...[
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(f.distance(s.distanceKm!), style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w800)),
                    Text(l(K.straightLine), style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    if (driving != null)
                      Text(
                        l(K.drivingDistance, {'d': f.distance(driving!.distanceKm), 'time': f.duration(Duration(minutes: driving!.durationMinutes))}),
                        style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                  ]),
                ],
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: [
                StationStatusPill(s),
                // Along My Route: right on the road, or a detour (there and
                // back, so about twice the distance from the route).
                if (s.offRouteKm != null)
                  s.offRouteKm! <= onRouteKm
                      ? Pill(l(K.onRoute), icon: Icons.check_circle_outline_rounded, tone: StatusTone.success, dense: true)
                      : Pill(l(K.detourAbout, {'d': f.distance(s.offRouteKm! * 2)}), icon: Icons.turn_right_rounded, tone: StatusTone.warning, dense: true),
                if (arriveAt != null) Pill(l(K.reachAbout, {'time': f.time(arriveAt!)}), icon: Icons.schedule_rounded, tone: StatusTone.info, dense: true),
                if (arriveAt != null && !s.open.openNow && s.openAt(arriveAt!))
                  Pill(l(K.openWhenYouReach), icon: Icons.lock_clock_rounded, tone: StatusTone.success, dense: true),
                if (s.isDemo) Pill(l(K.demoStation), tone: StatusTone.warning, dense: true),
              ]),
              const SizedBox(height: 10),
              ConnectorChips(s.connectorTypes, maxPowerKw: s.maxPowerKw),
              if (!compact) ...[
                const SizedBox(height: 10),
                PointCountsLine(s.points, now: now),
              ],
              const Divider(height: 22),
              Row(children: [
                Expanded(
                  child: next != null && s.bookable
                      ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l(K.nextFreeSlot), style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                          Text(f.whenStarts(next.startAt, now), style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        ])
                      : Text(s.bookable ? l(K.noFreeSlot48h) : l(K.notBookableNow), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
              ]),
              if (!compact) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => openDirections(context, s.latitude, s.longitude),
                      icon: const Icon(Icons.directions_rounded, size: 18),
                      label: Text(l(K.directions)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onOpen,
                      icon: Icon(s.bookable ? Icons.event_available_rounded : Icons.info_outline_rounded, size: 18),
                      label: Text(s.bookable ? l(K.viewSlots) : l(K.details)),
                    ),
                  ),
                ]),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _StationAvatar extends StatelessWidget {
  const _StationAvatar(this.s);
  final StationSummary s;

  @override
  Widget build(BuildContext context) => Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          gradient: s.bookable ? Brand.gradient : null,
          color: s.bookable ? null : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(Icons.ev_station_rounded, color: s.bookable ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant),
      );
}

/// Shows a slim animated banner when the device goes offline, and briefly
/// when it comes back.
class ConnectivityBanner extends ConsumerStatefulWidget {
  const ConnectivityBanner({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ConnectivityBanner> createState() => _ConnectivityBannerState();
}

class _ConnectivityBannerState extends ConsumerState<ConnectivityBanner> {
  bool _showRestored = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(onlineProvider, (prev, next) {
      if (prev?.value == false && next.value == true) {
        setState(() => _showRestored = true);
        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _showRestored = false);
        });
      }
    });
    final online = ref.watch(onlineProvider).value ?? true;
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final show = !online || _showRestored;
    return Column(children: [
      AnimatedSize(
        duration: Motion.medium,
        curve: Motion.emphasized,
        child: show
            ? Material(
                color: online ? const Color(0xFF1B8A3A) : scheme.inverseSurface,
                child: SafeArea(
                  bottom: false,
                  child: Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(children: [
                        Icon(online ? Icons.wifi_rounded : Icons.wifi_off_rounded, size: 18, color: Colors.white),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(online ? l(K.backOnline) : l(K.offlineBanner),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                      ]),
                    ),
                  ),
                ),
              )
            : const SizedBox(width: double.infinity),
      ),
      Expanded(child: MediaQuery.removePadding(context: context, removeTop: show, child: widget.child)),
    ]);
  }
}

/// Booking-flow progress: Slot → Details → Verify → Pay.
class StepProgress extends StatelessWidget {
  const StepProgress({super.key, required this.step, this.total = 4});
  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final labels = [l(K.stepSlot), l(K.stepDetails), l(K.stepVerify), l(K.stepPay)];
    return Semantics(
      label: l(K.stepOf, {'n': step + 1, 'total': total, 'name': labels[step]}),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          GradientProgressBar(value: (step + 1) / total, height: 6),
          const SizedBox(height: 6),
          Text(l(K.stepOf, {'n': step + 1, 'total': total, 'name': labels[step]}),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// Label/value line used across summary and detail screens.
class InfoLine extends StatelessWidget {
  const InfoLine({super.key, required this.icon, required this.label, required this.value, this.trailing, this.emphasize = false});
  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: t.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            SelectableText(value, style: emphasize ? t.textTheme.titleMedium : t.textTheme.bodyLarge),
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

/// A "mm:ss left to pay" countdown that rebuilds every second.
class HoldCountdown extends StatefulWidget {
  const HoldCountdown({super.key, required this.expiresAt, this.onExpired});
  final DateTime expiresAt;
  final VoidCallback? onExpired;

  @override
  State<HoldCountdown> createState() => _HoldCountdownState();
}

class _HoldCountdownState extends State<HoldCountdown> {
  Timer? _t;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (!_fired && DateTime.now().isAfter(widget.expiresAt)) {
        _fired = true;
        widget.onExpired?.call();
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final left = widget.expiresAt.difference(DateTime.now());
    final low = left.inSeconds < 120;
    return Pill(
      left.isNegative ? l(K.holdExpiredShort) : l(K.holdLeft, {'t': RFmt(l).countdown(left)}),
      icon: Icons.timer_outlined,
      tone: left.isNegative ? StatusTone.danger : (low ? StatusTone.warning : StatusTone.info),
    );
  }
}

/// The booking-fee refund rules in words. Says clearly when the platform
/// has not confirmed the policy yet; never invents amounts or timelines.
class RefundPolicyText extends StatelessWidget {
  const RefundPolicyText({super.key, required this.policy, required this.fee, this.cancelUntilMinutes});
  final RefundPolicy policy;
  final Money fee;
  final int? cancelUntilMinutes;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    final f = RFmt(l);
    final lines = <String>[
      if (fee.isZero) l(K.policyNoFee),
      if (!fee.isZero && policy.customerCancellationRefundable)
        l(K.policyCustomerRefund, {'fee': f.money(fee), 'mins': policy.customerCutoffMinutes})
      else if (!fee.isZero)
        l(K.policyCustomerNoRefund, {'fee': f.money(fee)}),
      if (!fee.isZero && policy.stationCancellationRefundable) l(K.policyStationRefund),
      if (!fee.isZero && policy.lateSlotLostRefundable) l(K.policyLatePayment),
      if (cancelUntilMinutes != null)
        cancelUntilMinutes == 0 ? l(K.policyCancelUntilStart) : l(K.policyCancelUntil, {'mins': cancelUntilMinutes}),
      l(K.policyChargingPaidAtStation),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final line in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 7), child: Icon(Icons.circle, size: 6, color: t.colorScheme.primary)),
            const SizedBox(width: 10),
            Expanded(child: Text(line, style: t.textTheme.bodyMedium?.copyWith(height: 1.45))),
          ]),
        ),
      if (!policy.confirmed)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Pill(l(K.policyProvisional), icon: Icons.info_outline_rounded, tone: StatusTone.warning),
        ),
    ]);
  }
}

/// Bottom action area that stays above the keyboard and system bars.
class BottomBar extends StatelessWidget {
  const BottomBar({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        elevation: 8,
        shadowColor: Colors.black26,
        child: SafeArea(top: false, child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 12), child: child)),
      );
}

/// Centred, width-limited scroll body used by most screens.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 32), this.controller});
  final List<Widget> children;
  final EdgeInsets padding;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(controller: controller, padding: padding, children: children),
        ),
      );
}

/// The animated brand background sized by its content, for use inside
/// scroll views (AuroraBackground itself needs a bounded height).
class AuroraHero extends StatelessWidget {
  const AuroraHero({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(children: [
        const Positioned.fill(child: AuroraBackground(child: SizedBox.shrink())),
        SizedBox(width: double.infinity, child: child),
      ]);
}

/// Station page (slot picker first), opened on the day of its next free slot.
String slotsRoute(StationSummary s) {
  final next = s.nextAvailable;
  if (next == null) return '/station/${s.id}';
  final d = RFmt.istDate(next.startAt);
  return '/station/${s.id}?date=${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
