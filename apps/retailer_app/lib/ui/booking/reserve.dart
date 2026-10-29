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
import 'flow_widgets.dart';

/// Reserves the chosen time once the number is verified and goes straight
/// to the payment page, which shows the fee and the summary. The server
/// assigns the point and re-checks the slot; the idempotency key means a
/// retry never books twice. A free booking is confirmed straight away.
/// Returns false when the hold failed (the reason is shown in a sheet).
Future<bool> reserveDraft(BuildContext context, WidgetRef ref) async {
  final d = ref.read(bookingFlowProvider);
  if (d == null) return false;
  final repo = ref.read(retailRepositoryProvider);
  final flow = ref.read(bookingFlowProvider.notifier);
  try {
    final BookingTerms? terms = await ref.read(termsProvider.future).then<BookingTerms?>((t) => t).catchError((_) => null);
    if (terms != null) {
      await repo.recordConsents(version: terms.termsVersion, terms: d.termsAccepted, marketing: d.marketingOptIn).catchError((_) {});
    }
    final b = await repo.createHold(
      stationId: d.stationId,
      connector: d.connector,
      start: d.start,
      end: d.end,
      idempotencyKey: d.idempotencyKey,
      vehicleLabel: d.vehicleLabel.isEmpty ? null : d.vehicleLabel,
    );
    flow.attachBooking(b.id);
    ref.invalidate(myBookingsProvider);
    if (!context.mounted) return true;
    if (b.status == BookingStatus.confirmed) {
      flow.clear();
      context.go('/book/done/${b.id}');
    } else {
      context.go('/book/pay/${b.id}');
    }
    return true;
  } catch (e) {
    final f = failureOf(e);
    if (f.code == 'slot_unavailable' || f.code == 'station_full') {
      // The key is tied to this attempt; a new time needs a new one.
      flow.releaseHold();
      ref.invalidate(slotsProvider);
    }
    if (context.mounted) await _showHoldFailure(context, f, d);
    return false;
  }
}

/// Booking-hold errors explained with the next step that makes sense.
Future<void> _showHoldFailure(BuildContext context, AppFailure failure, BookingDraft d) {
  final l = context.l;
  final (String, VoidCallback)? next = switch (failure.code) {
    'slot_unavailable' || 'station_full' || 'too_soon' || 'slot_misaligned' || 'outside_operating_hours' || 'blocked_period' =>
      (l(K.chooseAnotherTime), () => context.go('/station/${d.stationId}')),
    'too_many_pending_holds' || 'overlapping_booking' => (l(K.myBookings), () => context.go('/bookings')),
    'station_not_bookable' || 'point_not_bookable' =>
      (l(K.seeAlternatives), () => context.push('/alternatives?exclude=${d.stationId}&lat=${d.latitude}&lng=${d.longitude}')),
    _ => null,
  };
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FlowNotice(text: localizedFailureMessage(l, failure), tone: StatusTone.danger, icon: Icons.error_outline_rounded),
        const SizedBox(height: 12),
        if (next != null)
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              next.$2();
            },
            child: Text(next.$1),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l(K.dismiss))),
      ]),
    ),
  );
}
