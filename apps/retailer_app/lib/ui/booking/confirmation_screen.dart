import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../bookings/booking_widgets.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/widgets.dart';

/// Shown once the server says the booking is confirmed.
class ConfirmationScreen extends ConsumerWidget {
  const ConfirmationScreen({super.key, required this.bookingId});
  final String bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final value = ref.watch(bookingProvider(bookingId));
    return Scaffold(
      body: value.when(
        loading: () => const SlowLoading(),
        error: (e, _) => FailureView(
          error: e,
          onRetry: () => ref.invalidate(bookingProvider(bookingId)),
          extra: [FallbackAction(l(K.myBookings), () => context.go('/bookings'), icon: Icons.receipt_long_rounded)],
        ),
        data: (b) {
          // Opened from an old link for a booking that is not confirmed.
          final phase = b.phaseAt(DateTime.now());
          if (phase != CustomerPhase.confirmed && phase != CustomerPhase.checkedIn) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/booking/${b.id}');
            });
            return const SizedBox.shrink();
          }
          return _Confirmed(booking: b);
        },
      ),
    );
  }
}

class _Confirmed extends StatelessWidget {
  const _Confirmed({required this.booking});
  final CustomerBooking booking;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final b = booking;
    final hasEmail = b.messages.any((m) => m.channel == 'email');
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: AuroraHero(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
              child: Column(children: [
                const SuccessCheck(size: 96, color: Brand.mint),
                const SizedBox(height: 14),
                Entrance(
                  child: Text(l(K.bookingConfirmedTitle),
                      textAlign: TextAlign.center, style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(height: 6),
                Entrance(
                  index: 1,
                  child: Text(f.slot(b.startAt, b.endAt), textAlign: TextAlign.center, style: t.textTheme.titleMedium?.copyWith(color: Colors.white)),
                ),
                const SizedBox(height: 12),
                Entrance(index: 2, child: ReferenceBlock(b.reference, light: true)),
              ]),
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Entrance(index: 3, child: BookingQrCard(booking: b)),
                const SizedBox(height: 12),
                Entrance(
                  index: 4,
                  child: SectionCard(
                    title: b.stationName,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(b.stationAddress, style: t.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      InfoLine(icon: Icons.power_rounded, label: l(K.chargingPoint), value: b.pointCode),
                      InfoLine(icon: Icons.schedule_rounded, label: l(K.time), value: '${f.timeRange(b.startAt, b.endAt)} ${l(K.istSuffix)}'),
                      InfoLine(icon: Icons.receipt_rounded, label: l(K.bookingFeePaid), value: b.fee.isZero ? l(K.free) : b.fee.format()),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => openDirections(context, b.latitude, b.longitude),
                            icon: const Icon(Icons.directions_rounded),
                            label: Text(l(K.directions)),
                          ),
                        ),
                        if (b.stationPhone != null) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => callPhone(context, b.stationPhone!),
                              icon: const Icon(Icons.call_rounded),
                              label: Text(l(K.call)),
                            ),
                          ),
                        ],
                      ]),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Entrance(index: 5, child: ArrivalCard(booking: b, now: DateTime.now())),
                const SizedBox(height: 12),
                Entrance(
                  index: 6,
                  child: SectionCard(
                    title: l(K.confirmationSent),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      DeliveryStatus(messages: b.messages),
                      if (!hasEmail) Text(l(K.addEmailForReceipt), style: t.textTheme.bodySmall),
                      Text(l(K.whatsappSoon), style: t.textTheme.bodySmall),
                    ]),
                  ),
                ),
                const SizedBox(height: 20),
                // Signed in now, so home shows this booking at the top.
                GradientButton(label: l(K.goToHome), icon: Icons.home_rounded, onPressed: () => context.go('/')),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => context.go('/booking/${b.id}'),
                  icon: const Icon(Icons.receipt_long_rounded),
                  label: Text(l(K.viewBooking)),
                ),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
