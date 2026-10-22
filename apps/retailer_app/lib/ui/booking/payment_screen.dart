import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/checkout/checkout.dart';
import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../../state/providers.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import 'flow_widgets.dart';

/// What happened on the last attempt to pay, as reported by the device.
/// Only the server decides whether the booking is paid.
enum _Attempt { none, cancelled, failed, unavailable, unconfirmed }

/// Step 5: pay the booking fee while the slot is held. Every outcome is read
/// back from the server; closing the payment sheet, a failed signature check
/// or a dropped connection never shows "confirmed" by itself.
class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key, required this.bookingId});
  final String bookingId;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  CustomerBooking? _b;
  Object? _loadError;
  bool _loading = true;
  bool _paying = false;
  bool _polling = false;
  _Attempt _attempt = _Attempt.none;
  String? _attemptDetail;
  AppLifecycleListener? _life;
  Timer? _poll;
  int _pollRound = 0;

  static const _pollDelays = [2, 3, 4, 5, 8, 10, 15];

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: _reload);
    _reload();
  }

  @override
  void dispose() {
    _life?.dispose();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final b = await ref.read(retailRepositoryProvider).booking(widget.bookingId);
      if (!mounted) return;
      setState(() {
        _b = b;
        _loadError = null;
        _loading = false;
      });
      _afterLoad(b);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  void _afterLoad(CustomerBooking b) {
    final phase = b.phaseAt(DateTime.now());
    switch (phase) {
      case CustomerPhase.confirmed || CustomerPhase.checkedIn || CustomerPhase.completed:
        _poll?.cancel();
        ref.read(bookingFlowProvider.notifier).clear();
        ref.invalidate(myBookingsProvider);
        context.go('/book/done/${b.id}');
      case CustomerPhase.paymentProcessing:
        _schedulePoll();
      case CustomerPhase.pendingPayment || CustomerPhase.paymentFailed:
        if (_polling) _schedulePoll();
      default:
        _poll?.cancel();
        setState(() => _polling = false);
        ref.invalidate(myBookingsProvider);
    }
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (_pollRound >= _pollDelays.length) {
      setState(() {
        _polling = false;
        if (_attempt == _Attempt.none) _attempt = _Attempt.unconfirmed;
      });
      return;
    }
    setState(() => _polling = true);
    _poll = Timer(Duration(seconds: _pollDelays[_pollRound++]), _reload);
  }

  void _startPolling() {
    _pollRound = 0;
    _schedulePoll();
  }

  Future<void> _pay() async {
    final b = _b;
    if (b == null || _paying) return;
    setState(() {
      _paying = true;
      _attempt = _Attempt.none;
      _attemptDetail = null;
    });
    final repo = ref.read(retailRepositoryProvider);
    final draft = ref.read(bookingFlowProvider);
    final profile = ref.read(profileProvider).value;
    try {
      final order = await repo.createOrder(b.id);
      if (!mounted) return;
      final l = context.l;
      final result = await ref.read(checkoutProvider).open(CheckoutRequest(
            keyId: order.keyId,
            orderId: order.orderId,
            amountPaise: order.amount.paise,
            description: l(K.paymentDescription, {'ref': b.reference}),
            name: draft?.fullName ?? profile?.fullName,
            phone: repo.sessionPhone,
            email: (draft?.email.isNotEmpty == true ? draft!.email : profile?.contactEmail),
          ));
      if (!mounted) return;
      switch (result) {
        case CheckoutSucceeded(:final paymentId, :final orderId, :final signature):
          try {
            await repo.verifyPayment(orderId: orderId, paymentId: paymentId, signature: signature);
          } catch (_) {
            // The webhook settles it; keep checking the booking instead.
            _attempt = _Attempt.unconfirmed;
          }
          _startPolling();
          await _reload();
        case CheckoutFailed(:final description):
          setState(() {
            _attempt = _Attempt.failed;
            _attemptDetail = description;
          });
          await _reload();
        case CheckoutCancelled():
          setState(() => _attempt = _Attempt.cancelled);
          // A payment can still complete after the sheet is closed (UPI).
          _startPolling();
          await _reload();
        case CheckoutUnavailable(:final reason):
          setState(() {
            _attempt = _Attempt.unavailable;
            _attemptDetail = reason;
          });
      }
    } catch (e) {
      if (!mounted) return;
      final f = failureOf(e);
      setState(() {
        _attempt = f.code == 'hold_expired' ? _Attempt.none : _Attempt.failed;
        _attemptDetail = localizedFailureMessage(context.l, f);
      });
      await _reload();
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  void _newTime(CustomerBooking b) {
    ref.read(bookingFlowProvider.notifier).releaseHold();
    context.go('/station/${b.stationId}/slots');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (_loading) return Scaffold(appBar: AppBar(title: Text(l(K.payment))), body: const SlowLoading());
    final b = _b;
    if (b == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l(K.payment))),
        body: FailureView(
          error: _loadError ?? Exception('missing'),
          title: l(K.paymentStatusUnknownTitle),
          onRetry: () {
            setState(() => _loading = true);
            _reload();
          },
          extra: [FallbackAction(l(K.myBookings), () => context.go('/bookings'), icon: Icons.receipt_long_rounded)],
        ),
      );
    }
    final phase = b.phaseAt(DateTime.now());
    return PopScope(
      canPop: !_paying,
      child: Scaffold(
        appBar: AppBar(title: Text(l(K.payment))),
        body: Column(children: [
          const StepProgress(step: 4),
          Expanded(child: AnimatedSwitcher(duration: Motion.medium, child: KeyedSubtree(key: ValueKey(phase), child: _body(context, b, phase)))),
        ]),
      ),
    );
  }

  Widget _body(BuildContext context, CustomerBooking b, CustomerPhase phase) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    switch (phase) {
      case CustomerPhase.paymentProcessing:
        return _Waiting(
          title: l(K.paymentProcessingTitle),
          body: l(K.paymentProcessingBody),
          polling: _polling,
          onCheck: () {
            _startPolling();
            _reload();
          },
        );
      case CustomerPhase.expired:
        return FallbackView(
          icon: Icons.timer_off_outlined,
          title: l(K.holdExpiredTitle),
          message: l(K.holdExpiredBody),
          tone: StatusTone.warning,
          actions: [
            FallbackAction(l(K.chooseAnotherTime), () => _newTime(b), icon: Icons.event_rounded, primary: true),
            FallbackAction(l(K.seeAlternatives), () => context.push('/alternatives?exclude=${b.stationId}&lat=${b.latitude}&lng=${b.longitude}'), icon: Icons.alt_route_rounded),
          ],
          footer: Text(l(K.holdExpiredMoney), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
        );
      case CustomerPhase.paidSlotLost || CustomerPhase.refundPending || CustomerPhase.refunded:
        return FallbackView(
          icon: Icons.currency_rupee_rounded,
          title: l(K.slotLostTitle),
          message: l(K.slotLostBody, {'fee': b.fee.format()}),
          tone: StatusTone.warning,
          actions: [
            FallbackAction(l(K.viewBooking), () => context.go('/booking/${b.id}'), icon: Icons.receipt_long_rounded, primary: true),
            FallbackAction(l(K.seeAlternatives), () => context.push('/alternatives?exclude=${b.stationId}&lat=${b.latitude}&lng=${b.longitude}'), icon: Icons.alt_route_rounded),
          ],
        );
      case CustomerPhase.cancelled || CustomerPhase.missed:
        return FallbackView(
          icon: Icons.event_busy_rounded,
          title: l(K.bookingCancelledTitle),
          message: l(K.bookingCancelledBody),
          actions: [
            FallbackAction(l(K.viewBooking), () => context.go('/booking/${b.id}'), icon: Icons.receipt_long_rounded, primary: true),
            FallbackAction(l(K.findStation), () => context.go('/'), icon: Icons.explore_rounded),
          ],
        );
      case CustomerPhase.confirmed || CustomerPhase.checkedIn || CustomerPhase.completed:
        return const Center(child: SuccessCheck());
      case CustomerPhase.pendingPayment || CustomerPhase.paymentFailed:
        break;
    }

    final expires = b.holdExpiresAt;
    final banner = switch (_attempt) {
      _Attempt.cancelled => FlowNotice(text: l(K.paymentCancelledBody), icon: Icons.info_outline_rounded, tone: StatusTone.info),
      _Attempt.failed => FlowNotice(
          text: [l(K.paymentFailedBody), if (_attemptDetail != null && _attemptDetail!.isNotEmpty) _attemptDetail!].join('\n'),
          icon: Icons.error_outline_rounded,
          tone: StatusTone.danger,
        ),
      _Attempt.unavailable => FlowNotice(text: l(K.paymentSheetUnavailable), icon: Icons.block_rounded, tone: StatusTone.warning),
      _Attempt.unconfirmed => FlowNotice(text: l(K.paymentUnconfirmedBody), icon: Icons.sync_problem_rounded, tone: StatusTone.warning),
      _Attempt.none => b.phaseAt(DateTime.now()) == CustomerPhase.paymentFailed
          ? FlowNotice(text: l(K.paymentFailedBody), icon: Icons.error_outline_rounded, tone: StatusTone.danger)
          : null,
    };

    return RefreshIndicator(
      onRefresh: _reload,
      child: PageBody(children: [
        if (_polling)
          FlowNotice(text: l(K.checkingPayment), icon: Icons.sync_rounded)
        else
          ?banner,
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), gradient: Brand.nightGradient),
          child: Column(children: [
            Text(l(K.amountToPay), style: t.textTheme.labelLarge?.copyWith(color: Colors.white70)),
            const SizedBox(height: 4),
            Text(b.fee.format(), style: t.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(l(K.bookingFeeOnly), style: t.textTheme.bodySmall?.copyWith(color: Colors.white70), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (expires != null) HoldCountdown(expiresAt: expires, onExpired: _reload),
          ]),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: l(K.bookingSummary),
          child: Column(children: [
            InfoLine(icon: Icons.ev_station_rounded, label: l(K.stationLabel), value: b.stationName),
            InfoLine(icon: Icons.schedule_rounded, label: l(K.time), value: '${f.slot(b.startAt, b.endAt)} ${l(K.istSuffix)}'),
            InfoLine(icon: Icons.power_rounded, label: l(K.chargingPoint), value: b.pointCode),
            InfoLine(icon: Icons.tag_rounded, label: l(K.reference), value: b.reference),
          ]),
        ),
        const SizedBox(height: 16),
        if (expires != null && expires.isAfter(DateTime.now()))
          GradientButton(
            label: _attempt == _Attempt.none && b.payment == null ? l(K.payFee, {'fee': b.fee.format()}) : l(K.tryPaymentAgain),
            icon: Icons.lock_rounded,
            busy: _paying,
            onPressed: _polling ? null : _pay,
          )
        else
          FlowNotice(
            text: '${l(K.holdExpiredBody)} ${l(K.holdExpiredMoney)}',
            icon: Icons.timer_off_rounded,
            tone: StatusTone.warning,
            action: TextButton(onPressed: () => _newTime(b), child: Text(l(K.chooseAnotherTime))),
          ),
        const SizedBox(height: 8),
        Text(l(K.securePaymentNote), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(l(K.doubleChargeNote), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: _paying ? null : () => _newTime(b),
          icon: const Icon(Icons.edit_calendar_outlined),
          label: Text(l(K.chooseAnotherTime)),
        ),
      ]),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.title, required this.body, required this.polling, required this.onCheck});
  final String title;
  final String body;
  final bool polling;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ChargeLogo(size: 84),
          const SizedBox(height: 20),
          Text(title, textAlign: TextAlign.center, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          if (polling) const LinearProgressIndicator() else OutlinedButton.icon(onPressed: onCheck, icon: const Icon(Icons.refresh_rounded), label: Text(l(K.checkAgain))),
          const SizedBox(height: 12),
          TextButton(onPressed: () => context.go('/bookings'), child: Text(l(K.myBookings))),
        ]),
      ),
    );
  }
}
