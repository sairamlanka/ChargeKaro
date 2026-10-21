import 'package:flutter/material.dart';
import 'package:shared_models/shared_models.dart';

import 'theme.dart';

/// A text label on a tinted background. The label always carries the
/// meaning; colour only reinforces it.
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, this.tone = StatusTone.neutral, this.icon});

  StatusChip.station(StationStatus s, {Key? key}) : this(s.label, key: key, tone: stationTone(s));
  StatusChip.application(ApplicationStatus s, {Key? key}) : this(s.label, key: key, tone: applicationTone(s));
  StatusChip.document(DocumentStatus s, {Key? key}) : this(s.label, key: key, tone: documentTone(s));
  StatusChip.booking(BookingStatus s, {Key? key}) : this(s.label, key: key, tone: bookingTone(s));
  StatusChip.payment(BookingPaymentStatus s, {Key? key}) : this(s.label, key: key, tone: paymentTone(s));
  StatusChip.point(PointStatus s, {Key? key}) : this(s.label, key: key, tone: pointTone(s));
  StatusChip.business(BusinessStatus s, {Key? key}) : this(s.label, key: key, tone: businessTone(s));
  StatusChip.maintenance(MaintenanceStatus s, {Key? key}) : this(s.label, key: key, tone: maintenanceTone(s));
  StatusChip.expense(ExpenseStatus s, {Key? key}) : this(s.label, key: key, tone: expenseTone(s));
  StatusChip.refund(RefundStatus s, {Key? key}) : this(s.label, key: key, tone: refundTone(s));

  final String label;
  final StatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = tone.colors(Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)]
          else
            ...[Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)), const SizedBox(width: 6)],
          Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  static StatusTone stationTone(StationStatus s) => switch (s) {
        StationStatus.draft => StatusTone.neutral,
        StationStatus.active => StatusTone.success,
        StationStatus.temporarilyClosed => StatusTone.warning,
        StationStatus.suspended || StationStatus.deactivated => StatusTone.danger,
      };

  static StatusTone applicationTone(ApplicationStatus s) => switch (s) {
        ApplicationStatus.draft => StatusTone.neutral,
        ApplicationStatus.submitted || ApplicationStatus.underReview => StatusTone.info,
        ApplicationStatus.additionalInformationRequired => StatusTone.warning,
        ApplicationStatus.approved => StatusTone.success,
        ApplicationStatus.rejected || ApplicationStatus.suspended => StatusTone.danger,
      };

  static StatusTone documentTone(DocumentStatus s) => switch (s) {
        DocumentStatus.pendingReview => StatusTone.info,
        DocumentStatus.approved => StatusTone.success,
        DocumentStatus.correctionRequired => StatusTone.warning,
        DocumentStatus.rejected || DocumentStatus.expired => StatusTone.danger,
        DocumentStatus.superseded => StatusTone.neutral,
      };

  static StatusTone bookingTone(BookingStatus s) => switch (s) {
        BookingStatus.paymentPending => StatusTone.warning,
        BookingStatus.confirmed => StatusTone.info,
        BookingStatus.arrived || BookingStatus.inProgress || BookingStatus.completed => StatusTone.success,
        BookingStatus.cancelled || BookingStatus.expired => StatusTone.neutral,
        BookingStatus.noShow => StatusTone.danger,
      };

  static StatusTone paymentTone(BookingPaymentStatus s) => switch (s) {
        BookingPaymentStatus.paid || BookingPaymentStatus.notRequired => StatusTone.success,
        BookingPaymentStatus.pending || BookingPaymentStatus.refundPending => StatusTone.warning,
        BookingPaymentStatus.failed => StatusTone.danger,
        BookingPaymentStatus.abandoned || BookingPaymentStatus.refunded => StatusTone.neutral,
      };

  static StatusTone pointTone(PointStatus s) => switch (s) {
        PointStatus.available => StatusTone.success,
        PointStatus.inUse => StatusTone.info,
        PointStatus.maintenance => StatusTone.warning,
        PointStatus.outOfService || PointStatus.disabled => StatusTone.danger,
      };

  static StatusTone businessTone(BusinessStatus s) => switch (s.wire) {
        'active' => StatusTone.success,
        'pending_verification' => StatusTone.info,
        _ => StatusTone.danger,
      };

  static StatusTone maintenanceTone(MaintenanceStatus s) => switch (s.wire) {
        'open' => StatusTone.danger,
        'in_progress' => StatusTone.warning,
        'resolved' => StatusTone.success,
        _ => StatusTone.neutral,
      };

  static StatusTone expenseTone(ExpenseStatus s) => switch (s.wire) {
        'approved' => StatusTone.success,
        'submitted' => StatusTone.info,
        'rejected' => StatusTone.danger,
        _ => StatusTone.neutral,
      };

  static StatusTone refundTone(RefundStatus s) => switch (s.wire) {
        'processed' => StatusTone.success,
        'failed' => StatusTone.danger,
        _ => StatusTone.warning,
      };
}
