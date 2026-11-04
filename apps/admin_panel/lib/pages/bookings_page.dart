import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../shell.dart';

/// Booking slot window for the list and the check-in counts.
enum _Period {
  all('All time'),
  today('Today'),
  week('Last 7 days'),
  month('Last 30 days');

  const _Period(this.label);
  final String label;

  /// [from, to) in UTC, using IST calendar days. Null for all time.
  ({DateTime from, DateTime to})? range() {
    if (this == all) return null;
    final ist = Fmt.toIst(DateTime.now());
    final tomorrow = Fmt.fromIst(ist.year, ist.month, ist.day).add(const Duration(days: 1));
    final days = switch (this) { today => 1, week => 7, _ => 30 };
    return (from: tomorrow.subtract(Duration(days: days)), to: tomorrow);
  }
}

typedef _Args = ({
  String reference,
  BookingStatus? status,
  BookingPaymentStatus? payment,
  CheckinFilter? checkin,
  _Period period,
});

final _bookingsProvider = FutureProvider.autoDispose.family<List<Booking>, _Args>((ref, a) {
  final r = a.period.range();
  return ref.watch(bookingRepositoryProvider).search(
        reference: a.reference,
        status: a.status,
        paymentStatus: a.payment,
        checkin: a.checkin,
        from: r?.from,
        to: r?.to,
        limit: 200,
      );
});

/// Counts ignore the reference search and the check-in filter, so both
/// numbers stay visible while one of them is selected.
final _statsProvider = FutureProvider.autoDispose.family<CheckinStats, _Args>((ref, a) {
  final r = a.period.range();
  return ref.watch(bookingRepositoryProvider).checkinStats(status: a.status, paymentStatus: a.payment, from: r?.from, to: r?.to);
});

class BookingsPage extends ConsumerStatefulWidget {
  const BookingsPage({super.key});

  @override
  ConsumerState<BookingsPage> createState() => _BookingsPageState();
}

class _BookingsPageState extends ConsumerState<BookingsPage> {
  String _reference = '';
  BookingStatus? _status;
  BookingPaymentStatus? _payment;
  CheckinFilter? _checkin;
  _Period _period = _Period.all;

  @override
  Widget build(BuildContext context) {
    final args = (reference: _reference, status: _status, payment: _payment, checkin: _checkin, period: _period);
    final statsArgs = (reference: '', status: _status, payment: _payment, checkin: null, period: _period);
    final data = ref.watch(_bookingsProvider(args));
    final stats = ref.watch(_statsProvider(statsArgs));
    void refresh() {
      ref.invalidate(_bookingsProvider(args));
      ref.invalidate(_statsProvider(statsArgs));
    }

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
        DropdownButton<_Period>(
          value: _period,
          items: [for (final p in _Period.values) DropdownMenuItem(value: p, child: Text(p.label))],
          onChanged: (v) => setState(() => _period = v ?? _Period.all),
        ),
        DropdownButton<CheckinFilter?>(
          value: _checkin,
          hint: const Text('Any check-in'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Any check-in')),
            for (final c in CheckinFilter.values) DropdownMenuItem(value: c, child: Text(c.label)),
          ],
          onChanged: (v) => setState(() => _checkin = v),
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
      child: RefreshIndicator(
        onRefresh: () async => refresh(),
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: _CheckinStatsRow(
              stats: stats,
              selected: _checkin,
              onSelect: (f) => setState(() => _checkin = _checkin == f ? null : f),
              onRetry: () => ref.invalidate(_statsProvider(statsArgs)),
            ),
          ),
          ...switch (data) {
            AsyncData(:final value) when value.isEmpty => [
                const SliverFillRemaining(hasScrollBody: false, child: EmptyState(icon: Icons.event_busy, title: 'No bookings found')),
              ],
            AsyncData(:final value) => [
                SliverList.separated(
                  itemCount: value.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final b = value[i];
                    return ListTile(
                      title: Text('${b.reference} · ${b.stationName ?? ''} ${b.chargingPointCode ?? ''}'),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text([
                          '${Fmt.slot(b.startAt, b.endAt)} · fee ${b.bookingFee.format()}',
                          if (b.customerDisplayName != null) b.customerDisplayName!,
                          checkinLine(b),
                        ].join('\n')),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 4, children: [
                          CheckinChip(b),
                          StatusChip.booking(b.status),
                          StatusChip.payment(b.paymentStatus),
                        ]),
                      ]),
                      onTap: () async {
                        await showDialog<void>(context: context, builder: (_) => BookingDetailDialog(bookingId: b.id));
                        refresh();
                      },
                    );
                  },
                ),
                if (value.length >= 200)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Showing the 200 newest bookings. Narrow the filters to see others.', textAlign: TextAlign.center),
                    ),
                  ),
              ],
            _ => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: AsyncView(value: data, onRetry: () => ref.invalidate(_bookingsProvider(args)), builder: (_) => const SizedBox()),
                ),
              ],
          },
        ]),
      ),
    );
  }
}

/// "Checked in 10:32 AM by Ravi · QR code" or "Not checked in".
String checkinLine(Booking b) {
  if (b.checkedInAt == null) {
    return switch (b.status) {
      BookingStatus.confirmed => b.endAt.isAfter(DateTime.now()) ? 'Not checked in yet' : 'Not checked in (slot over)',
      BookingStatus.noShow => 'Not checked in (no-show)',
      BookingStatus.completed || BookingStatus.arrived || BookingStatus.inProgress => 'Not checked in',
      _ => 'Check-in not due',
    };
  }
  return [
    'Checked in ${Fmt.dateTime(b.checkedInAt!)}',
    if (b.checkedInByName != null) 'by ${b.checkedInByName}',
    if (b.checkinMethod != null) '· ${b.checkinMethod!.label}',
  ].join(' ');
}

class CheckinChip extends StatelessWidget {
  const CheckinChip(this.b, {super.key});
  final Booking b;

  @override
  Widget build(BuildContext context) {
    if (b.checkedInAt != null) return const StatusChip('Checked in', tone: StatusTone.success, icon: Icons.how_to_reg);
    return switch (b.status) {
      BookingStatus.confirmed when b.endAt.isAfter(DateTime.now()) =>
        const StatusChip('Not checked in', tone: StatusTone.info, icon: Icons.schedule),
      BookingStatus.confirmed || BookingStatus.noShow || BookingStatus.completed || BookingStatus.arrived || BookingStatus.inProgress =>
        const StatusChip('Not checked in', tone: StatusTone.warning, icon: Icons.person_off),
      _ => const SizedBox.shrink(),
    };
  }
}

class _CheckinStatsRow extends StatelessWidget {
  const _CheckinStatsRow({required this.stats, required this.selected, required this.onSelect, required this.onRetry});
  final AsyncValue<CheckinStats> stats;
  final CheckinFilter? selected;
  final ValueChanged<CheckinFilter> onSelect;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: switch (stats) {
        AsyncData(:final value) => LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth > 900 ? 4 : 2;
            final w = (c.maxWidth - (cols - 1) * 10) / cols;
            Widget tile(Widget child, [CheckinFilter? f]) => SizedBox(
                  width: w,
                  child: f != null && selected == f
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: t.colorScheme.primary, width: 2),
                          ),
                          child: child,
                        )
                      : child,
                );
            final pct = (value.checkInRate * 100).round();
            return Wrap(spacing: 10, runSpacing: 10, children: [
              tile(MetricTile(
                label: 'Bookings',
                count: value.total,
                caption: '${value.cancelled} cancelled · ${value.notDue - value.cancelled} unpaid/expired',
                icon: Icons.event_rounded,
                accent: Brand.ocean,
              )),
              tile(
                MetricTile(
                  label: 'Checked in',
                  count: value.checkedIn,
                  caption: value.methodSummary.isEmpty ? 'tap to list' : value.methodSummary,
                  icon: Icons.how_to_reg_rounded,
                  accent: Brand.green,
                  onTap: () => onSelect(CheckinFilter.checkedIn),
                ),
                CheckinFilter.checkedIn,
              ),
              tile(
                MetricTile(
                  label: 'Not checked in',
                  count: value.notCheckedIn,
                  caption: '${value.awaiting} still to arrive · ${value.missed} missed',
                  icon: Icons.person_off_rounded,
                  accent: Brand.amber,
                  onTap: () => onSelect(CheckinFilter.notCheckedIn),
                ),
                CheckinFilter.notCheckedIn,
              ),
              tile(MetricTile(
                label: 'Check-in rate',
                value: '$pct%',
                caption: 'of bookings due for check-in',
                icon: Icons.insights_rounded,
                accent: const Color(0xFF7C3AED),
              )),
            ]);
          }),
        AsyncError() => Row(children: [
            Expanded(child: Text('Could not load check-in counts.', style: TextStyle(color: t.colorScheme.error))),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ]),
        _ => const LinearProgressIndicator(),
      },
    );
  }
}

typedef _Detail = ({
  Booking booking,
  List<BookingEvent> events,
  List<Map<String, dynamic>> notes,
  List<RefundRecord> refunds,
  BookingCheckinDetail? checkin,
});

final _detailProvider = FutureProvider.autoDispose.family<_Detail, String>((ref, id) async {
  final repo = ref.watch(bookingRepositoryProvider);
  final access = await ref.watch(platformAccessProvider.future);
  final results = await Future.wait<Object>([
    repo.byId(id),
    repo.events(id),
    repo.supportNotes(id),
    if (access.can(PlatformPermission.financeRead)) ref.watch(financeRepositoryProvider).refunds(bookingId: id) else Future.value(<RefundRecord>[]),
    // Check-in details are extra: the rest of the dialog still works if they fail.
    repo.checkinDetail(id).then<Object>((d) => d, onError: (Object _) => false),
  ]);
  return (
    booking: results[0] as Booking,
    events: results[1] as List<BookingEvent>,
    notes: results[2] as List<Map<String, dynamic>>,
    refunds: results[3] as List<RefundRecord>,
    checkin: results[4] is BookingCheckinDetail ? results[4] as BookingCheckinDetail : null,
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
                Wrap(spacing: 6, runSpacing: 4, children: [CheckinChip(b), StatusChip.booking(b.status), StatusChip.payment(b.paymentStatus)]),
                const SizedBox(height: 12),
                KeyValue('Station', '${b.stationName ?? ''} · point ${b.chargingPointCode ?? ''}'),
                KeyValue('Slot', Fmt.slot(b.startAt, b.endAt)),
                KeyValue('Customer', b.customerDisplayName ?? '—'),
                if (b.customerPhone != null) KeyValue('Phone', b.customerPhone!),
                KeyValue('Vehicle', b.vehicleLabel ?? b.vehicleHint ?? '—'),
                if (b.compatibility != null && b.compatibility!.summary.isNotEmpty) KeyValue('Charger', b.compatibility!.summary),
                KeyValue('Booking fee', b.bookingFee.format()),
                if (b.createdAt != null) KeyValue('Booked at', Fmt.dateTime(b.createdAt!)),
                if (b.holdExpiresAt != null && b.status == BookingStatus.paymentPending) KeyValue('Hold expires', Fmt.dateTime(b.holdExpiresAt!)),
                if (b.chargingStartedAt != null) KeyValue('Charging started', Fmt.dateTime(b.chargingStartedAt!)),
                if (b.completedAt != null) KeyValue('Completed', Fmt.dateTime(b.completedAt!)),
                if (b.cancelledAt != null) KeyValue('Cancelled at', Fmt.dateTime(b.cancelledAt!)),
                if (b.noShowAt != null) KeyValue('Marked no-show', Fmt.dateTime(b.noShowAt!)),
                if (b.cancellationReason != null) KeyValue('Cancellation', '${b.cancellationActor?.label ?? ''}: ${b.cancellationReason}'),
                if (b.refundEligible != null) KeyValue('Refund eligible', b.refundEligible! ? 'Yes' : 'No'),
                const SizedBox(height: 16),
                _CheckinSection(booking: b, detail: d.checkin),
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

class _CheckinSection extends StatelessWidget {
  const _CheckinSection({required this.booking, required this.detail});
  final Booking booking;
  final BookingCheckinDetail? detail;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = detail;
    final b = booking;
    final at = d?.checkedInAt ?? b.checkedInAt;
    final method = d?.method ?? b.checkinMethod;
    return SectionCard(
      title: 'Check-in',
      trailing: CheckinChip(b),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValue('Status', at != null ? 'Checked in' : checkinLine(b)),
        KeyValue('Verification', (d?.verificationStatus ?? b.verificationStatus).label),
        if (at != null) KeyValue('Checked in at', Fmt.dateTime(at)),
        if (method != null) KeyValue('Method', method.label),
        if (d?.checkedInByName != null || b.checkedInByName != null) KeyValue('Checked in by', d?.checkedInByName ?? b.checkedInByName!),
        if (d?.reason != null) KeyValue('Manual reason', d!.reason!),
        if (d?.deviceId != null) KeyValue('Device', d!.deviceId!),
        if (b.checkinOpensAt != null && b.checkinClosesAt != null)
          KeyValue('Check-in window', '${Fmt.time(b.checkinOpensAt!)} – ${Fmt.time(b.checkinClosesAt!)}'),
        if (d == null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Check-in log unavailable (database update not applied yet?).',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          )
        else if (d.logs.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Check-in log', style: t.textTheme.titleSmall),
          for (final l in d.logs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(l.accepted ? Icons.check_circle : Icons.cancel, size: 20, color: l.accepted ? Brand.green : t.colorScheme.error),
              title: Text(l.title + (l.accepted ? '' : ' (rejected)')),
              subtitle: Text([
                Fmt.dateTime(l.serverAt),
                if (l.staffName != null) l.staffName!,
                if (l.method != null) l.method!.label,
                if (l.reason != null) l.reason!,
                if (l.rejectionMessage != null) l.rejectionMessage!,
                if (l.offlineAt != null) 'offline at ${Fmt.dateTime(l.offlineAt!)}',
              ].join(' · ')),
            ),
        ],
      ]),
    );
  }
}
