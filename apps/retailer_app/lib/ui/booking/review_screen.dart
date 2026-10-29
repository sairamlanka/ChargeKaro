import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../../state/providers.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import 'flow_widgets.dart';

/// Re-checks the slot and the fee on the server for the current draft.
final _slotCheckProvider = FutureProvider.autoDispose<SlotCheck?>((ref) async {
  final d = ref.watch(bookingFlowProvider.select((d) => d == null ? null : (d.pointId, d.start, d.end)));
  if (d == null) return null;
  return ref.watch(retailRepositoryProvider).checkSlot(d.$1, d.$2, d.$3);
});

/// Step 4: everything about the booking on one screen before any money
/// moves. The slot is reserved only when the customer taps the button.
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  bool _busy = false;
  AppFailureView? _failure;

  Future<void> _reserve(BookingDraft d, BookingTerms? terms) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    final repo = ref.read(retailRepositoryProvider);
    final flow = ref.read(bookingFlowProvider.notifier);
    try {
      if (terms != null) {
        await repo.recordConsents(version: terms.termsVersion, terms: d.termsAccepted, marketing: d.marketingOptIn).catchError((_) {});
      }
      final b = await repo.createHold(
        pointId: d.pointId,
        start: d.start,
        end: d.end,
        idempotencyKey: d.idempotencyKey,
        vehicleLabel: d.vehicleLabel.isEmpty ? null : d.vehicleLabel,
      );
      flow.attachBooking(b.id);
      ref.invalidate(myBookingsProvider);
      if (!mounted) return;
      if (b.status == BookingStatus.confirmed) {
        flow.clear();
        context.go('/book/done/${b.id}');
      } else {
        context.pushReplacement('/book/pay/${b.id}');
      }
    } catch (e) {
      final f = failureOf(e);
      if (f.code == 'slot_unavailable') {
        // The key is tied to this attempt; a new slot needs a new one.
        flow.releaseHold();
        ref.invalidate(_slotCheckProvider);
      }
      if (mounted) setState(() => _failure = AppFailureView(f));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final draft = ref.watch(bookingFlowProvider);
    if (draft == null) return const NoDraftView();
    final repo = ref.watch(retailRepositoryProvider);
    if (!repo.signedIn) return const NoDraftView();
    final check = ref.watch(_slotCheckProvider);
    final terms = ref.watch(termsProvider).value;
    final station = ref.watch(stationProvider(draft.stationId)).value;
    final serverFee = check.value?.fee;
    final feeChanged = serverFee != null && serverFee.paise != draft.displayedFeePaise;
    final slotGone = check.value != null && !check.value!.available;
    final fee = serverFee ?? Money(draft.displayedFeePaise);

    final canReserve = check.hasValue && !slotGone && !feeChanged && !_busy;

    return Scaffold(
      appBar: AppBar(title: Text(l(K.reviewBooking))),
      body: Column(children: [
        const StepProgress(step: 3),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(_slotCheckProvider),
            child: PageBody(children: [
              if (check.isLoading) FlowNotice(text: l(K.checkingSlot), icon: Icons.sync_rounded),
              if (check.hasError)
                FlowNotice(
                  text: l(K.checkSlotFailed),
                  tone: StatusTone.warning,
                  icon: Icons.wifi_off_rounded,
                  action: TextButton(onPressed: () => ref.invalidate(_slotCheckProvider), child: Text(l(K.tryAgain))),
                ),
              if (slotGone)
                FlowNotice(
                  text: l(K.slotGoneBody),
                  tone: StatusTone.danger,
                  icon: Icons.event_busy_rounded,
                  action: Wrap(spacing: 8, children: [
                    TextButton(onPressed: () => context.go('/station/${draft.stationId}/slots'), child: Text(l(K.chooseAnotherTime))),
                    TextButton(onPressed: () => context.push('/alternatives?exclude=${draft.stationId}&lat=${draft.latitude}&lng=${draft.longitude}'), child: Text(l(K.seeAlternatives))),
                  ]),
                ),
              if (feeChanged)
                FlowNotice(
                  text: l(K.feeChangedBody, {'old': Money(draft.displayedFeePaise).format(), 'new': serverFee.format()}),
                  tone: StatusTone.warning,
                  icon: Icons.price_change_outlined,
                  action: FilledButton.tonal(
                    onPressed: () => ref.read(bookingFlowProvider.notifier).acceptFee(serverFee.paise),
                    child: Text(l(K.acceptNewFee)),
                  ),
                ),
              if (_failure != null) _failure!.build(context, draft),
              SectionCard(
                title: l(K.stationLabel),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(draft.stationName, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  if (draft.stationAddress.isNotEmpty) Text(draft.stationAddress, style: t.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  InfoLine(icon: Icons.power_rounded, label: l(K.chargingPoint), value: draft.pointLabel),
                  if (draft.connectorLabel.isNotEmpty) InfoLine(icon: Icons.cable_rounded, label: l(K.connector), value: draft.connectorLabel),
                ]),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: l(K.whenLabel),
                child: Column(children: [
                  InfoLine(icon: Icons.event_rounded, label: l(K.date), value: f.dayLong(draft.start)),
                  InfoLine(icon: Icons.schedule_rounded, label: l(K.time), value: '${f.timeRange(draft.start, draft.end)} ${l(K.istSuffix)}', emphasize: true),
                  InfoLine(icon: Icons.timelapse_rounded, label: l(K.duration), value: f.duration(draft.duration)),
                  if (station != null)
                    InfoLine(
                      icon: Icons.login_rounded,
                      label: l(K.arrivalWindow),
                      value: f.timeRange(
                        draft.start.subtract(Duration(minutes: station.policy.earlyCheckinMinutes)),
                        draft.start.add(Duration(minutes: station.policy.arrivalGraceMinutes)),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: l(K.contactLabel),
                trailing: TextButton(onPressed: () => context.go('/book/details'), child: Text(l(K.edit))),
                child: Column(children: [
                  InfoLine(icon: Icons.person_outline_rounded, label: l(K.fullName), value: draft.fullName),
                  InfoLine(icon: Icons.phone_iphone_rounded, label: l(K.mobileNumber), value: '${maskPhone(draft.phone)} ✓'),
                  if (draft.email.isNotEmpty) InfoLine(icon: Icons.alternate_email_rounded, label: l(K.email), value: draft.email),
                  if (draft.vehicleLabel.isNotEmpty) InfoLine(icon: Icons.electric_car_outlined, label: l(K.vehicle), value: draft.vehicleLabel),
                ]),
              ),
              const SizedBox(height: 12),
              SectionCard(title: l(K.priceTitle), child: PriceBreakdown(fee: fee)),
              const SizedBox(height: 12),
              SectionCard(
                title: l(K.cancellationRefunds),
                child: RefundPolicyText(
                  policy: station?.refundPolicy ?? terms?.refundPolicy ?? const RefundPolicy(customerCancellationRefundable: false, customerCutoffMinutes: 0, stationCancellationRefundable: true, lateSlotLostRefundable: true, confirmed: false),
                  fee: fee,
                  cancelUntilMinutes: station?.policy.cancelUntilMinutes,
                ),
              ),
              const SizedBox(height: 12),
              if (!fee.isZero) FlowNotice(text: l(K.holdExplain, {'mins': station?.holdMinutes ?? terms?.holdMinutes ?? 10}), icon: Icons.timer_outlined),
            ]),
          ),
        ),
      ]),
      bottomNavigationBar: BottomBar(
        child: GradientButton(
          label: fee.isZero ? l(K.confirmBooking) : l(K.reserveAndPay, {'fee': fee.format()}),
          icon: fee.isZero ? Icons.check_rounded : Icons.lock_rounded,
          busy: _busy,
          onPressed: canReserve ? () => _reserve(draft, terms) : null,
        ),
      ),
    );
  }
}

/// Booking-hold errors explained with the next step that makes sense.
class AppFailureView {
  AppFailureView(this.failure);
  final AppFailure failure;

  Widget build(BuildContext context, BookingDraft d) {
    final l = context.l;
    final msg = localizedFailureMessage(l, failure);
    final Widget? action = switch (failure.code) {
      'slot_unavailable' || 'too_soon' || 'outside_operating_hours' || 'blocked_period' => TextButton(
          onPressed: () => context.go('/station/${d.stationId}/slots'),
          child: Text(l(K.chooseAnotherTime)),
        ),
      'too_many_pending_holds' => TextButton(onPressed: () => context.go('/bookings'), child: Text(l(K.myBookings))),
      'station_not_bookable' || 'point_not_bookable' => TextButton(
          onPressed: () => context.push('/alternatives?exclude=${d.stationId}&lat=${d.latitude}&lng=${d.longitude}'),
          child: Text(l(K.seeAlternatives)),
        ),
      _ => null,
    };
    return FlowNotice(text: msg, tone: StatusTone.danger, icon: Icons.error_outline_rounded, action: action);
  }
}
