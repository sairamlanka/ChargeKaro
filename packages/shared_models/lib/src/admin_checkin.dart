import 'package:meta/meta.dart';

import 'checkin.dart';
import 'json.dart';

/// Booking check-in filter for the admin search (server: p_checkin).
enum CheckinFilter {
  checkedIn('checked_in', 'Checked in'),
  notCheckedIn('not_checked_in', 'Not checked in');

  const CheckinFilter(this.wire, this.label);
  final String wire;
  final String label;
}

/// Counts from admin_booking_checkin_stats
/// (20261103000300_admin_checkin_stats.sql).
///
/// [notCheckedIn] covers only bookings that were due for check-in:
/// [awaiting] (confirmed, slot not over yet) plus [missed] (no-shows and
/// anything that ended without a check-in). Unpaid/expired holds and
/// cancellations before arrival are in [notDue].
@immutable
class CheckinStats {
  const CheckinStats({
    this.total = 0,
    this.checkedIn = 0,
    this.notCheckedIn = 0,
    this.notDue = 0,
    this.awaiting = 0,
    this.missed = 0,
    this.cancelled = 0,
    this.byMethod = const {},
  });

  factory CheckinStats.fromJson(Object? json) {
    final j = Json.of(json);
    final m = j.objectOrNull('by_method');
    return CheckinStats(
      total: j.integer('total', 0),
      checkedIn: j.integer('checked_in', 0),
      notCheckedIn: j.integer('not_checked_in', 0),
      notDue: j.integer('not_due', 0),
      awaiting: j.integer('awaiting', 0),
      missed: j.integer('missed', 0),
      cancelled: j.integer('cancelled', 0),
      byMethod: {
        if (m != null)
          for (final method in CheckinMethod.values) method: m.integer(method.wire, 0),
      },
    );
  }

  final int total;
  final int checkedIn;
  final int notCheckedIn;
  final int notDue;
  final int awaiting;
  final int missed;
  final int cancelled;
  final Map<CheckinMethod, int> byMethod;

  /// Share of due bookings that were checked in, 0–1.
  double get checkInRate => checkedIn + notCheckedIn == 0 ? 0 : checkedIn / (checkedIn + notCheckedIn);

  /// "QR 4 · Manual 1", leaving out methods with no check-ins.
  String get methodSummary =>
      [for (final e in byMethod.entries) if (e.value > 0) '${e.key.label} ${e.value}'].join(' · ');
}

/// Check-in details for one booking, from admin_get_booking_checkin.
@immutable
class BookingCheckinDetail {
  const BookingCheckinDetail({
    required this.checkedIn,
    this.verificationStatus = VerificationStatus.notCheckedIn,
    this.method,
    this.checkedInAt,
    this.checkedInByName,
    this.reason,
    this.deviceId,
    this.logs = const [],
  });

  factory BookingCheckinDetail.fromJson(Object? json) {
    final j = Json.of(json);
    return BookingCheckinDetail(
      checkedIn: j.strOrNull('state') == 'checked_in',
      verificationStatus: VerificationStatus.parse(j.strOrNull('verification_status')),
      method: CheckinMethod.tryParse(j.strOrNull('method')),
      checkedInAt: j.dateTimeOrNull('checked_in_at'),
      checkedInByName: j.strOrNull('checked_in_by_name'),
      reason: j.strOrNull('reason_label') ?? j.strOrNull('reason'),
      deviceId: j.strOrNull('device_id'),
      logs: j['logs'] is List ? (j['logs'] as List).map(CheckinLogEntry.fromJson).toList() : const [],
    );
  }

  final bool checkedIn;
  final VerificationStatus verificationStatus;
  final CheckinMethod? method;
  final DateTime? checkedInAt;
  final String? checkedInByName;
  final String? reason;
  final String? deviceId;
  final List<CheckinLogEntry> logs;
}
