import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import '../station/report_sheet.dart';
import 'booking_widgets.dart';

class BookingDetailScreen extends ConsumerWidget {
  const BookingDetailScreen({super.key, required this.bookingId});
  final String bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final signedIn = ref.watch(customerIdProvider).value != null;
    if (!signedIn && !ref.watch(customerIdProvider).isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(l(K.bookingDetails))),
        body: FallbackView(
          icon: Icons.lock_outline_rounded,
          title: l(K.signInToSeeBooking),
          message: l(K.signInToSeeBookingBody),
          actions: [FallbackAction(l(K.signIn), () => context.push('/sign-in?next=/booking/$bookingId'), icon: Icons.login_rounded, primary: true)],
        ),
      );
    }
    final value = ref.watch(bookingProvider(bookingId));
    return Scaffold(
      appBar: AppBar(
        title: Text(l(K.bookingDetails)),
        actions: [IconButton(tooltip: l(K.refresh), onPressed: () => ref.invalidate(bookingProvider(bookingId)), icon: const Icon(Icons.refresh_rounded))],
      ),
      body: value.when(
        skipLoadingOnRefresh: true,
        loading: () => const SlowLoading(),
        error: (e, _) => FailureView(
          error: e,
          title: failureOf(e).kind == FailureKind.notFound ? l(K.bookingNotFoundTitle) : null,
          onRetry: () => ref.invalidate(bookingProvider(bookingId)),
          extra: [FallbackAction(l(K.myBookings), () => context.go('/bookings'), icon: Icons.receipt_long_rounded)],
        ),
        data: (b) => _Detail(booking: b),
      ),
    );
  }
}

class _Detail extends ConsumerWidget {
  const _Detail({required this.booking});
  final CustomerBooking booking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final b = booking;
    final now = DateTime.now();
    final phase = b.phaseAt(now);
    final active = phase == CustomerPhase.confirmed || phase == CustomerPhase.checkedIn;
    final upcoming = b.isUpcomingAt(now);
    final stationClosed = b.stationStatus != null && b.stationStatus != StationStatus.active;

    final cards = <Widget>[
      _Header(booking: b, phase: phase),
      if (stationClosed && upcoming)
        _Banner(
          text: l(K.stationClosedForBooking),
          tone: StatusTone.warning,
          action: TextButton(
            onPressed: () => context.push('/alternatives?exclude=${b.stationId}&lat=${b.latitude}&lng=${b.longitude}'),
            child: Text(l(K.seeAlternatives)),
          ),
        ),
      if (phase == CustomerPhase.pendingPayment || phase == CustomerPhase.paymentFailed)
        _Banner(
          text: l(K.completePaymentBody),
          tone: StatusTone.warning,
          action: FilledButton(onPressed: () => context.push('/book/pay/${b.id}'), child: Text(l(K.completePayment))),
        ),
      if (phase == CustomerPhase.paymentProcessing) _Banner(text: l(K.paymentProcessingBody), tone: StatusTone.info),
      if (phase == CustomerPhase.paidSlotLost) _Banner(text: l(K.slotLostBody, {'fee': b.fee.format()}), tone: StatusTone.warning),
      if (active && b.endAt.isAfter(now)) BookingQrCard(booking: b),
      if (phase == CustomerPhase.confirmed && b.endAt.isAfter(now)) ArrivalCard(booking: b, now: now),
      SectionCard(
        title: l(K.stationLabel),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(b.stationName, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          Text(b.stationAddress, style: t.textTheme.bodySmall),
          const SizedBox(height: 8),
          InfoLine(icon: Icons.power_rounded, label: l(K.chargingPoint), value: [b.pointCode, ?b.pointName].join(' · ')),
          if (b.connectors.isNotEmpty) InfoLine(icon: Icons.cable_rounded, label: l(K.connector), value: b.connectors.map((c) => c.label).join(', ')),
          InfoLine(icon: Icons.event_rounded, label: l(K.date), value: f.dayLong(b.startAt)),
          InfoLine(icon: Icons.schedule_rounded, label: l(K.time), value: '${f.timeRange(b.startAt, b.endAt)} ${l(K.istSuffix)}', emphasize: true),
          InfoLine(icon: Icons.timelapse_rounded, label: l(K.duration), value: f.duration(b.duration)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: () => openDirections(context, b.latitude, b.longitude), icon: const Icon(Icons.directions_rounded), label: Text(l(K.directions))),
            if (b.stationPhone != null)
              OutlinedButton.icon(onPressed: () => callPhone(context, b.stationPhone!), icon: const Icon(Icons.call_rounded), label: Text(l(K.call))),
            OutlinedButton.icon(onPressed: () => context.push('/station/${b.stationId}'), icon: const Icon(Icons.ev_station_rounded), label: Text(l(K.bookAgain))),
          ]),
        ]),
      ),
      SectionCard(
        title: l(K.paymentTitle),
        child: Column(children: [
          InfoLine(icon: Icons.receipt_rounded, label: l(K.bookingFee), value: b.fee.isZero ? l(K.free) : b.fee.format()),
          InfoLine(icon: Icons.verified_outlined, label: l(K.paymentStatus), value: _paymentLabel(l, b)),
          if (b.payment?.method != null) InfoLine(icon: Icons.credit_card_rounded, label: l(K.paymentMethod), value: b.payment!.method!.toUpperCase()),
          if (b.payment?.reference != null) InfoLine(icon: Icons.tag_rounded, label: l(K.paymentReference), value: b.payment!.reference!),
          if (b.payment?.capturedAt != null) InfoLine(icon: Icons.event_available_rounded, label: l(K.paidAt), value: f.dateTime(b.payment!.capturedAt!)),
          for (final r in b.refunds)
            InfoLine(
              icon: Icons.currency_rupee_rounded,
              label: l(K.refundOf, {'amount': r.amount.format()}),
              value: [refundStatusLabel(l, r.status), if (r.processedAt != null) f.dateTime(r.processedAt!), if (r.reference != null) r.reference!].join(' · '),
            ),
          if (b.refunds.isNotEmpty && b.refunds.any((r) => r.status != RefundStatus.processed))
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(l(K.refundTimeline), style: t.textTheme.bodySmall)),
          const SizedBox(height: 4),
          Text(l(K.chargingCostBody), style: t.textTheme.bodySmall),
        ]),
      ),
      SectionCard(
        title: l(K.notificationsTitle),
        trailing: TextButton(onPressed: () => _resendEmail(context, ref, b), child: Text(l(K.emailReceipt))),
        child: DeliveryStatus(messages: b.messages),
      ),
      if (b.events.isNotEmpty) SectionCard(title: l(K.historyTitle), child: _Timeline(events: b.events)),
      SectionCard(
        title: l(K.needHelp),
        child: Column(children: [
          if (upcoming || active)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.event_busy_rounded, color: t.colorScheme.error),
              title: Text(l(K.cancelBooking)),
              subtitle: Text(l(K.cancelBookingHint)),
              onTap: () => showCancelSheet(context, ref, b),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.report_problem_outlined),
            title: Text(l(K.reportProblem)),
            subtitle: Text(l(K.reportProblemHint)),
            onTap: () => showBookingIssueSheet(context, ref, b.id),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.help_outline_rounded),
            title: Text(l(K.helpCentre)),
            onTap: () => context.push('/help'),
          ),
        ]),
      ),
    ];

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(bookingProvider(b.id)),
      child: PageBody(children: [
        for (final (i, c) in cards.indexed) Padding(padding: const EdgeInsets.only(bottom: 12), child: Entrance(index: i, child: c)),
      ]),
    );
  }

  String _paymentLabel(L l, CustomerBooking b) => switch (b.paymentStatus) {
        BookingPaymentStatus.notRequired => l(K.payNotRequired),
        BookingPaymentStatus.pending => b.payment?.status == GatewayPaymentStatus.authorized ? l(K.phaseProcessing) : l(K.payPending),
        BookingPaymentStatus.paid => l(K.payPaid),
        BookingPaymentStatus.failed => l(K.payFailed),
        BookingPaymentStatus.abandoned => l(K.payAbandoned),
        BookingPaymentStatus.refundPending => l(K.phaseRefundPending),
        BookingPaymentStatus.refunded => l(K.phaseRefunded),
      };
}

class _Header extends StatelessWidget {
  const _Header({required this.booking, required this.phase});
  final CustomerBooking booking;
  final CustomerPhase phase;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final b = booking;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(gradient: Brand.nightGradient, borderRadius: BorderRadius.circular(24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PhasePill(phase),
        const SizedBox(height: 10),
        Text(f.whenStarts(b.startAt, DateTime.now()), style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
        Text(b.stationName, style: t.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 10),
        ReferenceBlock(b.reference, light: true),
        if (b.cancellationActor != null && b.cancelledAt != null)
          Text(
            l(K.cancelledBy, {
              'who': switch (b.cancellationActor!) {
                ActorKind.customer => l(K.actorYou),
                ActorKind.business => l(K.actorStation),
                _ => l(K.actorChargeKaro),
              },
              'when': f.dateTime(b.cancelledAt!),
            }),
            style: t.textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.tone, this.action});
  final String text;
  final StatusTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = tone.colors(Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: TextStyle(color: fg, height: 1.4)),
        if (action != null) Align(alignment: Alignment.centerRight, child: action),
      ]),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.events});
  final List<TimelineEvent> events;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final sorted = [...events]..sort((a, b) => a.at.compareTo(b.at));
    return Column(children: [
      for (final (i, e) in sorted.indexed)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 20,
              child: Column(children: [
                Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 5), decoration: BoxDecoration(color: t.colorScheme.primary, shape: BoxShape.circle)),
                if (i < sorted.length - 1) Expanded(child: Container(width: 2, color: t.colorScheme.outlineVariant)),
              ]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_eventLabel(l, e), style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  Text(f.dateTime(e.at), style: t.textTheme.bodySmall),
                ]),
              ),
            ),
          ]),
        ),
    ]);
  }

  String _eventLabel(L l, TimelineEvent e) => switch (e.status) {
        BookingStatus.paymentPending => e.paymentStatus == BookingPaymentStatus.failed ? l(K.evPaymentFailed) : l(K.evCreated),
        BookingStatus.confirmed => l(K.evConfirmed),
        BookingStatus.arrived => l(K.evArrived),
        BookingStatus.inProgress => l(K.evCharging),
        BookingStatus.completed => l(K.evCompleted),
        BookingStatus.cancelled => e.paymentStatus == BookingPaymentStatus.refunded
            ? l(K.evRefunded)
            : (e.paymentStatus == BookingPaymentStatus.refundPending ? l(K.evRefundStarted) : l(K.evCancelled)),
        BookingStatus.expired => l(K.evExpired),
        BookingStatus.noShow => l(K.evNoShow),
      };
}

Future<void> _resendEmail(BuildContext context, WidgetRef ref, CustomerBooking b) async {
  final l = context.l;
  final profile = ref.read(profileProvider).value;
  final ctrl = TextEditingController(text: profile?.contactEmail ?? '');
  final messenger = ScaffoldMessenger.of(context);
  final email = await showDialog<String>(
    context: context,
    builder: (ctx) {
      final form = GlobalKey<FormState>();
      return AlertDialog(
        title: Text(l(K.emailReceipt)),
        content: Form(
          key: form,
          child: TextFormField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(labelText: l(K.email)),
            validator: (v) => Validators.email(v) == null ? null : l(K.emailInvalid),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l(K.cancel))),
          FilledButton(onPressed: () => form.currentState!.validate() ? Navigator.pop(ctx, ctrl.text.trim()) : null, child: Text(l(K.send))),
        ],
      );
    },
  );
  ctrl.dispose();
  if (email == null) return;
  try {
    await ref.read(retailRepositoryProvider).resendEmail(b.id, email: email);
    messenger.showSnackBar(SnackBar(content: Text(l(K.emailQueued, {'email': maskEmail(email)}))));
    ref.invalidate(bookingProvider(b.id));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(localizedFailureMessage(l, failureOf(e)))));
  }
}

/// Explains what cancelling means for this booking (refund or not, per the
/// policy) before asking for confirmation.
Future<void> showCancelSheet(BuildContext context, WidgetRef ref, CustomerBooking b) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CancelSheet(booking: b),
    );

final _previewProvider = FutureProvider.autoDispose.family<CancellationPreview, String>(
  (ref, id) => ref.watch(retailRepositoryProvider).previewCancellation(id),
);

class _CancelSheet extends ConsumerStatefulWidget {
  const _CancelSheet({required this.booking});
  final CustomerBooking booking;

  @override
  ConsumerState<_CancelSheet> createState() => _CancelSheetState();
}

class _CancelSheetState extends ConsumerState<_CancelSheet> {
  bool _busy = false;
  Object? _error;
  bool _done = false;

  Future<void> _cancel() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(retailRepositoryProvider).cancel(widget.booking.id);
      ref.invalidate(bookingProvider(widget.booking.id));
      ref.invalidate(myBookingsProvider);
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    if (_done) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SuccessCheck(size: 72),
          const SizedBox(height: 12),
          Text(l(K.cancelledTitle), style: t.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(l(K.cancelledBody), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(l(K.done))),
        ]),
      );
    }
    final preview = ref.watch(_previewProvider(widget.booking.id));
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: preview.when(
        loading: () => const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => FailureView(error: e, compact: true, onRetry: () => ref.invalidate(_previewProvider(widget.booking.id))),
        data: (p) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l(K.cancelBookingQ), style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(f.slot(widget.booking.startAt, widget.booking.endAt), style: t.textTheme.bodySmall),
          const SizedBox(height: 16),
          if (!p.allowed)
            _Banner(
              tone: StatusTone.warning,
              text: switch (p.reason) {
                'cancellation_window_closed' => l(K.errCancelWindow),
                'payment_in_progress' => l(K.cancelPaymentInProgress),
                _ => l(K.errNotCancellable),
              },
            )
          else ...[
            _Banner(
              tone: p.refundEligible ? StatusTone.success : StatusTone.warning,
              text: widget.booking.fee.isZero
                  ? l(K.cancelNoFee)
                  : (p.refundEligible ? l(K.cancelRefund, {'amount': p.refundAmount.format()}) : l(K.cancelNoRefund, {'fee': widget.booking.fee.format()})),
            ),
            if (p.refundEligible && p.refundUntil != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(l(K.refundUntil, {'when': f.dateTime(p.refundUntil!)}), style: t.textTheme.bodySmall)),
            if (!p.policyConfirmed)
              Padding(padding: const EdgeInsets.only(top: 8), child: Pill(l(K.policyProvisional), icon: Icons.info_outline_rounded, tone: StatusTone.warning)),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(localizedFailureMessage(l, failureOf(_error!)), style: TextStyle(color: t.colorScheme.error)),
            ),
          const SizedBox(height: 20),
          if (p.allowed)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError, minimumSize: const Size.fromHeight(52)),
              onPressed: _busy ? null : _cancel,
              child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l(K.confirmCancel)),
            ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l(K.keepBooking))),
        ]),
      ),
    );
  }
}
