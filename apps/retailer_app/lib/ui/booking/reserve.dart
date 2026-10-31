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

/// A name the booking can be made under: two characters or more, with at
/// least one letter.
bool isValidName(String name) {
  final s = name.trim();
  return s.length >= 2 && RegExp(r"[A-Za-zఀ-౿]").hasMatch(s);
}

/// Moves on from the slot picker. A guest (or a session without a verified
/// mobile) fills in the details and verifies the number. A signed-in
/// customer skips both: their profile supplies the contact details and the
/// time is reserved straight away, unless the profile lacks a name or the
/// current terms were never accepted, in which case only those are asked.
Future<void> continueBooking(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(retailRepositoryProvider);
  final phone = repo.sessionPhone;
  if (!repo.signedIn || phone == null) {
    await context.push('/book/details');
    return;
  }
  CustomerProfile? profile;
  bool accepted;
  try {
    profile = await ref.read(profileProvider.future);
    accepted = await ref.read(termsAcceptedProvider.future);
  } catch (_) {
    // Can't tell what is on file: the details screen asks for what it needs.
    if (context.mounted) await context.push('/book/details?only=name,terms');
    return;
  }
  final name = profile?.fullName?.trim() ?? '';
  final only = [if (!isValidName(name)) 'name', if (!accepted) 'terms'];
  if (!context.mounted) return;
  if (only.isNotEmpty) {
    await context.push('/book/details?only=${only.join(',')}');
    return;
  }
  final flow = ref.read(bookingFlowProvider.notifier);
  final d = ref.read(bookingFlowProvider);
  flow.setContact(fullName: name, phone: phone, email: profile?.contactEmail ?? '', vehicleLabel: d?.vehicleLabel ?? '');
  flow.setConsents(terms: true, marketing: d?.marketingOptIn ?? false);
  // Already on record: recording again would also reset a marketing opt-in.
  await reserveDraft(context, ref, recordConsents: false);
}

/// Reserves the chosen time once the number is verified and goes straight
/// to the payment page, which shows the fee and the summary. The server
/// assigns the point and re-checks the slot; the idempotency key means a
/// retry never books twice. A free booking is confirmed straight away.
/// Returns false when the hold failed (the reason is shown in a sheet).
Future<bool> reserveDraft(BuildContext context, WidgetRef ref, {bool recordConsents = true}) async {
  final d = ref.read(bookingFlowProvider);
  if (d == null) return false;
  final repo = ref.read(retailRepositoryProvider);
  final flow = ref.read(bookingFlowProvider.notifier);
  try {
    if (recordConsents) {
      final BookingTerms? terms = await ref.read(termsProvider.future).then<BookingTerms?>((t) => t).catchError((_) => null);
      if (terms != null) {
        await repo.recordConsents(version: terms.termsVersion, terms: d.termsAccepted, marketing: d.marketingOptIn).catchError((_) {});
        ref.invalidate(termsAcceptedProvider);
      }
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
