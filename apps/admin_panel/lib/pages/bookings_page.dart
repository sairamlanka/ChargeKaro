import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../shell.dart';

typedef _Args = ({String reference, BookingStatus? status, BookingPaymentStatus? payment});

final _bookingsProvider = FutureProvider.autoDispose.family<List<Booking>, _Args>(
  (ref, a) => ref.watch(bookingRepositoryProvider).search(reference: a.reference, status: a.status, paymentStatus: a.payment),
);

class BookingsPage extends ConsumerStatefulWidget {
  const BookingsPage({super.key});

  @override
  ConsumerState<BookingsPage> createState() => _BookingsPageState();
}

class _BookingsPageState extends ConsumerState<BookingsPage> {
  String _reference = '';
  BookingStatus? _status;
  BookingPaymentStatus? _payment;

  @override
  Widget build(BuildContext context) {
    final args = (reference: _reference, status: _status, payment: _payment);
    final data = ref.watch(_bookingsProvider(args));
    return PageFrame(
      title: 'Bookings',
      scroll: false,
      actions: [
        SizedBox(
          width: 220,
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Reference, e.g. CK7Q…'),
            onSubmitted: (v) => setState(() => _reference = v),
          ),
        ),
        DropdownButton<BookingStatus?>(
          value: _status,
          hint: const Text('Any status'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Any status')),
            for (final s in BookingStatus.values) DropdownMenuItem(value: s, child: Text(s.label)),
          ],
          onChanged: (v) => setState(() => _status = v),
        ),
        DropdownButton<BookingPaymentStatus?>(
          value: _payment,
          hint: const Text('Any fee status'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Any fee status')),
            for (final s in BookingPaymentStatus.values) DropdownMenuItem(value: s, child: Text(s.label)),
          ],
          onChanged: (v) => setState(() => _payment = v),
        ),
      ],
      child: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_bookingsProvider(args)),
        builder: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.event_busy, title: 'No bookings found')
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final b = list[i];
                  return ListTile(
                    title: Text('${b.reference} · ${b.stationName ?? ''} ${b.chargingPointCode ?? ''}'),
                    subtitle: Text('${Fmt.slot(b.startAt, b.endAt)} · fee ${b.bookingFee.format()}'),
                    trailing: Wrap(spacing: 6, children: [StatusChip.booking(b.status), StatusChip.payment(b.paymentStatus)]),
                    onTap: () async {
                      await showDialog<void>(context: context, builder: (_) => BookingDetailDialog(bookingId: b.id));
                      ref.invalidate(_bookingsProvider(args));
                    },
                  );
                },
              ),
      ),
    );
  }
}

typedef _Detail = ({Booking booking, List<BookingEvent> events, List<Map<String, dynamic>> notes, List<RefundRecord> refunds});

final _detailProvider = FutureProvider.autoDispose.family<_Detail, String>((ref, id) async {
  final repo = ref.watch(bookingRepositoryProvider);
  final access = await ref.watch(platformAccessProvider.future);
  final results = await Future.wait<Object>([
    repo.byId(id),
    repo.events(id),
    repo.supportNotes(id),
    if (access.can(PlatformPermission.financeRead)) ref.watch(financeRepositoryProvider).refunds(bookingId: id) else Future.value(<RefundRecord>[]),
  ]);
  return (
    booking: results[0] as Booking,
    events: results[1] as List<BookingEvent>,
    notes: results[2] as List<Map<String, dynamic>>,
    refunds: results[3] as List<RefundRecord>,
  );
});

class BookingDetailDialog extends ConsumerWidget {
  const BookingDetailDialog({super.key, required this.bookingId});
  final String bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_detailProvider(bookingId));
    void refresh() => ref.invalidate(_detailProvider(bookingId));
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: AsyncView(
          value: data,
          onRetry: refresh,
          builder: (d) {
            final b = d.booking;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('Booking ${b.reference}', style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ]),
                Wrap(spacing: 6, children: [StatusChip.booking(b.status), StatusChip.payment(b.paymentStatus)]),
                const SizedBox(height: 12),
                KeyValue('Station', '${b.stationName ?? ''} · point ${b.chargingPointCode ?? ''}'),
                KeyValue('Slot', Fmt.slot(b.startAt, b.endAt)),
                KeyValue('Customer', b.customerDisplayName),
                KeyValue('Vehicle', b.vehicleLabel),
                KeyValue('Booking fee', b.bookingFee.format()),
                if (b.cancellationReason != null) KeyValue('Cancellation', '${b.cancellationActor?.label ?? ''}: ${b.cancellationReason}'),
                if (b.refundEligible != null) KeyValue('Refund eligible', b.refundEligible! ? 'Yes' : 'No'),
                const SizedBox(height: 12),
                _Actions(b, onDone: refresh),
                const SizedBox(height: 16),
                Text('History', style: Theme.of(context).textTheme.titleMedium),
                for (final e in d.events)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.summary),
                    subtitle: Text([Fmt.dateTime(e.createdAt), e.actor.label, if (e.note != null) e.note!].join(' · ')),
                  ),
                if (d.refunds.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Refunds', style: Theme.of(context).textTheme.titleMedium),
                  for (final r in d.refunds)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${r.amount.format()} · ${r.reason}'),
                      subtitle: Text([Fmt.dateTime(r.createdAt), if (r.isAutomatic) 'automatic', if (r.failureReason != null) r.failureReason!].join(' · ')),
                      trailing: StatusChip.refund(r.status),
                    ),
                ],
                const SizedBox(height: 12),
                Text('Support notes (internal)', style: Theme.of(context).textTheme.titleMedium),
                for (final n in d.notes)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(n['note'] as String),
                    subtitle: Text('${(n['profiles'] as Map?)?['full_name'] ?? 'Staff'} · ${Fmt.dateTime(DateTime.parse(n['created_at'] as String))}'),
                  ),
                if (can(ref, PlatformPermission.bookingsSupportNotes)) _AddNote(bookingId: b.id, onDone: refresh),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions(this.b, {required this.onDone});
  final Booking b;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets = {BookingStatus.cancelled, BookingStatus.completed, BookingStatus.noShow, BookingStatus.confirmed}..remove(b.status);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (can(ref, PlatformPermission.bookingsOverride))
        PopupMenuButton<BookingStatus>(
          itemBuilder: (_) => [for (final t in targets) PopupMenuItem(value: t, child: Text('Set to ${t.label}'))],
          onSelected: (t) => _override(context, ref, t),
          child: const Chip(avatar: Icon(Icons.gavel, size: 18), label: Text('Override status')),
        ),
      if (can(ref, PlatformPermission.financeRefundsIssue) && b.paymentStatus == BookingPaymentStatus.paid)
        ActionChip(avatar: const Icon(Icons.undo, size: 18), label: const Text('Refund booking fee'), onPressed: () => _refund(context, ref)),
    ]);
  }

  Future<void> _override(BuildContext context, WidgetRef ref, BookingStatus target) async {
    var refund = false;
    final reason = await showDialog<String>(
      context: context,
      builder: (context) {
        final c = TextEditingController();
        return StatefulBuilder(
          builder: (context, set) => AlertDialog(
            title: Text('Override to ${target.label}'),
            content: SizedBox(
              width: 440,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Overrides bypass normal rules and are recorded in the audit log with your reason.'),
                const SizedBox(height: 12),
                TextField(controller: c, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Reason'), onChanged: (_) => set(() {})),
                if (b.paymentStatus == BookingPaymentStatus.paid && target == BookingStatus.cancelled)
                  CheckboxListTile(
                    value: refund,
                    onChanged: (v) => set(() => refund = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Refund the booking fee in full'),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: c.text.trim().length < 5 ? null : () => Navigator.pop(context, c.text.trim()), child: const Text('Override')),
            ],
          ),
        );
      },
    );
    if (reason == null || !context.mounted) return;
    if (await runAction(context, () => ref.read(bookingRepositoryProvider).adminOverride(b.id, target, reason: reason, refund: refund),
        success: 'Booking updated.')) {
      onDone();
    }
  }

  Future<void> _refund(BuildContext context, WidgetRef ref) async {
    final key = FinanceRepository.newIdempotencyKey();
    final amount = TextEditingController(text: (b.bookingFee.paise / 100).toStringAsFixed(2));
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) {
          final parsed = Money.tryParseRupees(amount.text);
          final valid = parsed != null && parsed.paise > 0 && parsed.paise <= b.bookingFee.paise && reason.text.trim().length >= 5;
          return AlertDialog(
            title: const Text('Refund booking fee'),
            content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Up to ${b.bookingFee.format()} minus anything already refunded. Sent to Razorpay by the refund worker.'),
                const SizedBox(height: 12),
                TextField(
                  controller: amount,
                  decoration: const InputDecoration(labelText: 'Amount (₹)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  onChanged: (_) => set(() {}),
                ),
                const SizedBox(height: 12),
                TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason'), onChanged: (_) => set(() {})),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: valid ? () => Navigator.pop(context, true) : null, child: const Text('Issue refund')),
            ],
          );
        },
      ),
    );
    if (ok != true || !context.mounted) return;
    final money = Money.tryParseRupees(amount.text)!;
    if (await runAction(context, () => ref.read(financeRepositoryProvider).issueRefund(b.id, money, reason.text.trim(), key),
        success: 'Refund requested.')) {
      onDone();
    }
  }
}

class _AddNote extends ConsumerStatefulWidget {
  const _AddNote({required this.bookingId, required this.onDone});
  final String bookingId;
  final VoidCallback onDone;

  @override
  ConsumerState<_AddNote> createState() => _AddNoteState();
}

class _AddNoteState extends ConsumerState<_AddNote> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: TextField(controller: _c, decoration: const InputDecoration(hintText: 'Add an internal note'))),
        const SizedBox(width: 8),
        IconButton.filled(
          icon: const Icon(Icons.send),
          onPressed: () async {
            if (_c.text.trim().isEmpty) return;
            if (await runAction(context, () => ref.read(bookingRepositoryProvider).addSupportNote(widget.bookingId, _c.text.trim()))) {
              _c.clear();
              widget.onDone();
            }
          },
        ),
      ]);
}
