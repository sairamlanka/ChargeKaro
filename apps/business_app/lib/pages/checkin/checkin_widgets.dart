import 'package:flutter/material.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Booking facts staff may see before check-in: reference, slot, charger
/// and status. Never customer details.
class BookingSummaryCard extends StatelessWidget {
  const BookingSummaryCard({super.key, required this.booking});
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = booking;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(AppTheme.fieldRadius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(b.reference, style: t.textTheme.titleLarge?.copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        InfoLine(Icons.schedule_rounded, Fmt.slot(b.startAt, b.endAt)),
        if (b.chargingPointCode != null) InfoLine(Icons.ev_station_rounded, 'Point ${b.chargingPointCode}'),
        if (b.compatibility != null && b.compatibility!.summary.isNotEmpty) InfoLine(Icons.electrical_services_rounded, b.compatibility!.summary),
        if (!b.customerRevealed && b.vehicleHint != null) InfoLine(Icons.directions_car_rounded, 'Vehicle ${b.vehicleHint}'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          StatusChip.booking(b.status),
          StatusChip.payment(b.paymentStatus),
          VerificationChip(b.verificationStatus),
        ]),
      ]),
    );
  }
}

/// Verified (server) vs provisional (offline) check-in, always in words.
class VerificationChip extends StatelessWidget {
  const VerificationChip(this.status, {super.key});
  final VerificationStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
        VerificationStatus.verified => const StatusChip('Verified', tone: StatusTone.success, icon: Icons.verified_rounded),
        VerificationStatus.pendingSync => const StatusChip('Pending sync', tone: StatusTone.warning, icon: Icons.cloud_upload_outlined),
        VerificationStatus.rejected => const StatusChip('Rejected', tone: StatusTone.danger, icon: Icons.block_rounded),
        VerificationStatus.notCheckedIn => const StatusChip('Not checked in', icon: Icons.hourglass_empty_rounded),
      };
}

/// Customer details, shown only after the server has checked the booking in.
class CustomerDetailsCard extends StatelessWidget {
  const CustomerDetailsCard({super.key, required this.booking});
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final b = booking;
    if (!b.customerRevealed) {
      return Text('Customer details are shown after check-in.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant));
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppTheme.fieldRadius),
        border: Border.all(color: t.colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Customer', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
        const SizedBox(height: 6),
        InfoLine(Icons.person_rounded, b.customerDisplayName ?? 'Customer'),
        if (b.customerPhone != null)
          Row(children: [
            Expanded(child: InfoLine(Icons.phone_rounded, b.customerPhone!)),
            IconButton(
              tooltip: 'Call customer',
              icon: const Icon(Icons.call_rounded),
              onPressed: () => launchUrl(Uri(scheme: 'tel', path: b.customerPhone)),
            ),
          ]),
        if (b.vehicleLabel != null) InfoLine(Icons.directions_car_rounded, b.vehicleLabel!),
      ]),
    );
  }
}

class InfoLine extends StatelessWidget {
  const InfoLine(this.icon, this.text, {super.key});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ]),
      );
}

/// Red panel explaining why a check-in was refused, with next steps.
class RejectionPanel extends StatelessWidget {
  const RejectionPanel({super.key, required this.message, this.alreadyCheckedIn = false});
  final String message;
  final bool alreadyCheckedIn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = alreadyCheckedIn ? t.colorScheme.tertiary : t.colorScheme.error;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(AppTheme.fieldRadius)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(alreadyCheckedIn ? Icons.how_to_reg_rounded : Icons.error_outline_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: t.textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w600))),
        ]),
      ),
    );
  }
}

/// Banner shown on check-in screens while the device is offline.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.pending = 0});
  final int pending;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Material(
        color: t.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            Icon(Icons.cloud_off_rounded, color: t.colorScheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'You are offline. QR and manual check-in need internet. Offline check-ins stay provisional until they sync.',
                style: TextStyle(color: t.colorScheme.onErrorContainer),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
