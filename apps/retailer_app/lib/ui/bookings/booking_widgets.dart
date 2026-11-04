import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/format.dart';
import '../common/widgets.dart';

/// The booking's check-in QR. Reuses the code this device was last given
/// while it is valid; otherwise asks the server, which revokes any older
/// code (another phone, a screenshot) so only one works at a time.
class BookingQrNotifier extends AsyncNotifier<BookingQr> {
  BookingQrNotifier(this.bookingId);
  final String bookingId;

  @override
  Future<BookingQr> build() async {
    final cached = ref.read(localStoreProvider).bookingQr(bookingId);
    if (cached != null && !cached.expiredAt(DateTime.now())) return cached;
    return _issue();
  }

  Future<BookingQr> _issue() async {
    final qr = await ref.read(retailRepositoryProvider).issueBookingQr(bookingId);
    await ref.read(localStoreProvider).saveBookingQr(qr);
    return qr;
  }

  /// New code on request (lost, rejected or shared code).
  Future<void> renew() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_issue);
  }
}

final bookingQrProvider =
    AsyncNotifierProvider.autoDispose.family<BookingQrNotifier, BookingQr, String>(BookingQrNotifier.new);

(String, StatusTone, IconData) phaseLook(L l, CustomerPhase p) => switch (p) {
      CustomerPhase.pendingPayment => (l(K.phasePendingPayment), StatusTone.warning, Icons.hourglass_top_rounded),
      CustomerPhase.paymentProcessing => (l(K.phaseProcessing), StatusTone.info, Icons.sync_rounded),
      CustomerPhase.paymentFailed => (l(K.phasePaymentFailed), StatusTone.danger, Icons.error_outline_rounded),
      CustomerPhase.confirmed => (l(K.phaseConfirmed), StatusTone.success, Icons.check_circle_rounded),
      CustomerPhase.checkedIn => (l(K.phaseCheckedIn), StatusTone.success, Icons.bolt_rounded),
      CustomerPhase.completed => (l(K.phaseCompleted), StatusTone.neutral, Icons.done_all_rounded),
      CustomerPhase.cancelled => (l(K.phaseCancelled), StatusTone.neutral, Icons.cancel_outlined),
      CustomerPhase.refundPending => (l(K.phaseRefundPending), StatusTone.info, Icons.currency_rupee_rounded),
      CustomerPhase.refunded => (l(K.phaseRefunded), StatusTone.neutral, Icons.currency_rupee_rounded),
      CustomerPhase.expired => (l(K.phaseExpired), StatusTone.neutral, Icons.timer_off_outlined),
      CustomerPhase.paidSlotLost => (l(K.phaseSlotLost), StatusTone.warning, Icons.report_gmailerrorred_rounded),
      CustomerPhase.missed => (l(K.phaseMissed), StatusTone.danger, Icons.person_off_outlined),
    };

class PhasePill extends StatelessWidget {
  const PhasePill(this.phase, {super.key, this.dense = false});
  final CustomerPhase phase;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final (label, tone, icon) = phaseLook(context.l, phase);
    return Pill(label, icon: icon, tone: tone, dense: dense);
  }
}

/// Large booking reference with copy.
class ReferenceBlock extends StatelessWidget {
  const ReferenceBlock(this.reference, {super.key, this.light = false});
  final String reference;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    final color = light ? Colors.white : t.colorScheme.onSurface;
    return Semantics(
      label: l(K.referenceSpoken, {'ref': reference.split('').join(' ')}),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l(K.reference), style: t.textTheme.labelSmall?.copyWith(color: color.withValues(alpha: 0.7))),
          SelectableText(reference, style: t.textTheme.headlineSmall?.copyWith(color: color, fontWeight: FontWeight.w800, letterSpacing: 2)),
        ]),
        IconButton(
          tooltip: l(K.copy),
          color: color,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: reference));
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l(K.copied))));
          },
          icon: const Icon(Icons.copy_rounded),
        ),
      ]),
    );
  }
}

/// The check-in QR with its expiry. Falls back to the reference.
class BookingQrCard extends ConsumerWidget {
  const BookingQrCard({super.key, required this.booking});
  final CustomerBooking booking;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final qr = ref.watch(bookingQrProvider(booking.id));
    final closed = qr.error is AppFailure && (qr.error! as AppFailure).code == 'qr_expired';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(l(K.showAtStation), style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          PhasePill(booking.phaseAt(DateTime.now()), dense: true),
          const SizedBox(height: 12),
          SizedBox(
            width: 200,
            height: 200,
            child: qr.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.qr_code_2_rounded, size: 64),
                  Text(closed ? l(K.qrClosed) : l(K.qrUnavailable), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
                  if (!closed) TextButton(onPressed: () => ref.invalidate(bookingQrProvider(booking.id)), child: Text(l(K.tryAgain))),
                ]),
              ),
              data: (code) => Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: Semantics(
                  label: l(K.qrSemantics),
                  child: QrImageView(data: code.payload, version: QrVersions.auto, backgroundColor: Colors.white),
                ),
              ),
            ),
          ),
          if (qr.value case final code?) ...[
            const SizedBox(height: 8),
            Text(l(K.qrValidUntil, {'time': f.time(code.expiresAt)}), style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            Text(l(K.qrOnlyLatest), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          ReferenceBlock(booking.reference),
          Text(l(K.qrFallback), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
          if (!closed && !qr.isLoading)
            TextButton.icon(
              icon: const Icon(Icons.autorenew_rounded),
              label: Text(l(K.qrNewCode)),
              onPressed: () async {
                if (await confirm(context, title: l(K.qrNewCodeQ), message: l(K.qrNewCodeBody), confirmLabel: l(K.qrNewCode))) {
                  await ref.read(bookingQrProvider(booking.id).notifier).renew();
                }
              },
            ),
        ]),
      ),
    );
  }
}

/// Arrival window with a plain-language state: too early, open, closing
/// soon, or missed.
class ArrivalCard extends StatelessWidget {
  const ArrivalCard({super.key, required this.booking, required this.now});
  final CustomerBooking booking;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final b = booking;
    final (text, tone) = now.isBefore(b.arrivalOpensAt)
        ? (l(K.arrivalOpensAt, {'time': f.time(b.arrivalOpensAt)}), StatusTone.info)
        : now.isBefore(b.arrivalClosesAt)
            ? (l(K.arrivalOpenNow, {'time': f.time(b.arrivalClosesAt)}), StatusTone.success)
            : (b.policy.autoNoShow ? l(K.arrivalMissedAuto) : l(K.arrivalMissedManual), StatusTone.danger);
    return SectionCard(
      title: l(K.arrivalTitle),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InfoLine(
          icon: Icons.flag_rounded,
          label: l(K.reportByLabel),
          value: l(K.reportByValue, {'time': f.time(b.reportBy), 'mins': b.policy.reportBeforeMinutes}),
          emphasize: true,
        ),
        InfoLine(icon: Icons.timer_outlined, label: l(K.pointHeldUntil), value: f.time(b.arrivalClosesAt)),
        const SizedBox(height: 6),
        Pill(text, tone: tone, icon: Icons.directions_walk_rounded),
        const SizedBox(height: 10),
        Text(
          l(K.arrivalRuleNotice, {'before': b.policy.reportBeforeMinutes, 'grace': b.policy.arrivalGraceMinutes}),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
        ),
        const SizedBox(height: 6),
        Text(l(K.arrivalSteps), style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5)),
      ]),
    );
  }
}

/// Where the confirmation was sent and whether it got there.
class DeliveryStatus extends StatelessWidget {
  const DeliveryStatus({super.key, required this.messages});
  final List<MessageInfo> messages;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (messages.isEmpty) return Text(l(K.noMessagesYet), style: Theme.of(context).textTheme.bodySmall);
    // Latest message per channel.
    final byChannel = <String, MessageInfo>{};
    for (final m in messages) {
      final cur = byChannel[m.channel];
      if (cur == null || (m.updatedAt != null && cur.updatedAt != null && m.updatedAt!.isAfter(cur.updatedAt!))) byChannel[m.channel] = m;
    }
    return Column(children: [
      for (final e in byChannel.entries)
        InfoLine(
          icon: switch (e.key) {
            'email' => Icons.alternate_email_rounded,
            'whatsapp' => Icons.chat_rounded,
            _ => Icons.sms_outlined,
          },
          label: switch (e.key) {
            'email' => l(K.channelEmail),
            'whatsapp' => l(K.channelWhatsapp),
            _ => l(K.channelSms),
          },
          value: switch (e.value.status) {
            MessageDelivery.sent => l(K.deliverySent),
            MessageDelivery.pending => l(K.deliveryPending),
            MessageDelivery.failed => l(K.deliveryFailed),
            MessageDelivery.skipped => l(K.deliverySkipped),
          },
        ),
    ]);
  }
}

String refundStatusLabel(L l, RefundStatus s) => switch (s) {
      RefundStatus.processed => l(K.refundProcessed),
      RefundStatus.failed => l(K.refundFailed),
      RefundStatus.requested || RefundStatus.processing => l(K.refundInProgress),
    };

/// One row in My Bookings.
class BookingTile extends StatelessWidget {
  const BookingTile({super.key, required this.booking, required this.onTap, required this.now, this.onBookAgain});
  final CustomerBooking booking;
  final VoidCallback onTap;
  final DateTime now;

  /// Shown as a "Book again" button on finished bookings.
  final VoidCallback? onBookAgain;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final b = booking;
    return Pressable(
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 54,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(color: t.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(14)),
                child: Column(children: [
                  Text(f.weekdayShort(f.ist(b.startAt)), style: t.textTheme.labelSmall),
                  Text('${f.ist(b.startAt).day}', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.stationName, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  Text('${f.timeRange(b.startAt, b.endAt)} · ${b.pointCode}', style: t.textTheme.bodySmall),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    PhasePill(b.phaseAt(now), dense: true),
                    Text(b.reference, style: t.textTheme.labelSmall),
                  ]),
                  if (onBookAgain != null) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: onBookAgain,
                      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.replay_rounded, size: 18),
                      label: Text(l(K.bookAgain)),
                    ),
                  ],
                ]),
              ),
              const Icon(Icons.chevron_right_rounded),
            ]),
          ),
        ),
      ),
    );
  }
}
