import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../state.dart';

typedef _Detail = ({Booking booking, List<BookingEvent> events, BookingPolicy policy});

final _detailProvider = FutureProvider.autoDispose.family<_Detail, String>((ref, id) async {
  final repo = ref.watch(bookingRepositoryProvider);
  final b = await repo.byId(id);
  final results = await Future.wait<Object>([repo.events(id), ref.watch(stationRepositoryProvider).policy(b.stationId)]);
  return (booking: b, events: results[0] as List<BookingEvent>, policy: results[1] as BookingPolicy);
});

/// Booking actions for staff. Every transition is validated by the database
/// (state machine, check-in window, grace period).
class BookingDetailPage extends ConsumerWidget {
  const BookingDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_detailProvider(id));
    void refresh() => ref.invalidate(_detailProvider(id));
    return Scaffold(
      appBar: AppBar(title: Text(data.value?.booking.reference ?? 'Booking')),
      body: AsyncView(
        value: data,
        onRetry: refresh,
        builder: (d) {
          final b = d.booking;
          final access = ref.watch(currentAccessProvider);
          final canCheckIn = access?.can(BusinessPermission.bookingsCheckin, stationId: b.stationId) ?? false;
          final canManage = access?.can(BusinessPermission.bookingsManage, stationId: b.stationId) ?? false;
          final now = DateTime.now();
          final repo = ref.read(bookingRepositoryProvider);
          Future<void> act(Future<void> Function() f, String done) async {
            if (await runAction(context, f, success: done)) refresh();
          }

          return ListView(padding: const EdgeInsets.all(16), children: [
            Wrap(spacing: 8, children: [StatusChip.booking(b.status), StatusChip.payment(b.paymentStatus)]),
            const SizedBox(height: 12),
            KeyValue('Slot', Fmt.slot(b.startAt, b.endAt)),
            KeyValue('Charging point', b.chargingPointCode),
            KeyValue('Customer', b.customerDisplayName),
            KeyValue('Vehicle', b.vehicleLabel),
            KeyValue('Booking fee', '${b.bookingFee.format()} (paid to ChargeKaro)'),
            const KeyValue('Charging fee', 'Collected by your station directly'),
            if (b.cancellationReason != null) KeyValue('Cancelled', '${b.cancellationActor?.label ?? ''}: ${b.cancellationReason}'),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (canCheckIn && b.status == BookingStatus.confirmed)
                FilledButton.icon(
                  icon: const Icon(Icons.how_to_reg),
                  label: const Text('Check in'),
                  onPressed: b.checkInWindowContains(now, earlyMinutes: d.policy.earlyCheckinMinutes, graceMinutes: d.policy.arrivalGraceMinutes)
                      ? () => act(() => repo.checkIn(b.stationId, b.reference, viaQr: false), 'Checked in.')
                      : null,
                ),
              if (canCheckIn && b.status == BookingStatus.arrived)
                FilledButton.icon(
                  icon: const Icon(Icons.bolt),
                  label: const Text('Charging started'),
                  onPressed: () => act(() => repo.updateProgress(b.id, BookingStatus.inProgress), 'Marked as charging.'),
                ),
              if (canCheckIn && (b.status == BookingStatus.arrived || b.status == BookingStatus.inProgress))
                OutlinedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Complete'),
                  onPressed: () => act(() => repo.updateProgress(b.id, BookingStatus.completed), 'Booking completed.'),
                ),
              if (canManage && b.status == BookingStatus.confirmed)
                OutlinedButton(
                  onPressed: b.noShowAllowedAt(now, d.policy.arrivalGraceMinutes)
                      ? () async {
                          if (await confirm(context,
                                  title: 'Mark as no-show?',
                                  message: 'The customer did not arrive within the grace period. The booking fee is not refunded.',
                                  confirmLabel: 'Mark no-show') &&
                              context.mounted) {
                            await act(() => repo.updateProgress(b.id, BookingStatus.noShow), 'Marked as no-show.');
                          }
                        }
                      : null,
                  child: const Text('No-show'),
                ),
              if (canManage && (b.status == BookingStatus.confirmed || b.status == BookingStatus.paymentPending))
                TextButton(
                  onPressed: () async {
                    final reason = await confirmWithReason(context,
                        title: 'Cancel booking',
                        message: 'The customer is notified. Because the station cancelled, the booking fee is refunded under the platform policy.',
                        confirmLabel: 'Cancel booking',
                        reasonLabel: 'Reason shown to the customer',
                        destructive: true);
                    if (reason != null && context.mounted) await act(() => repo.cancel(b.id, reason), 'Booking cancelled.');
                  },
                  child: const Text('Cancel booking'),
                ),
            ]),
            if (b.status == BookingStatus.confirmed && !b.checkInWindowContains(now, earlyMinutes: d.policy.earlyCheckinMinutes, graceMinutes: d.policy.arrivalGraceMinutes))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(now.isBefore(b.startAt)
                    ? 'Check-in opens ${d.policy.earlyCheckinMinutes} min before the slot.'
                    : 'The arrival grace period has passed.'),
              ),
            const SizedBox(height: 24),
            Text('History', style: Theme.of(context).textTheme.titleMedium),
            for (final e in d.events)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(e.summary),
                subtitle: Text([Fmt.dateTime(e.createdAt), e.actor.label, if (e.note != null) e.note!].join(' · ')),
              ),
          ]);
        },
      ),
    );
  }
}
