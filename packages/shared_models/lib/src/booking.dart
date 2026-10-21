import 'package:meta/meta.dart';

import 'enums.dart';
import 'json.dart';
import 'money.dart';
import 'station.dart';

/// A reservation. Booking status and booking-fee payment status are separate.
/// The charging fee paid at the station is not part of the platform and never
/// appears here.
@immutable
class Booking {
  const Booking({
    required this.id,
    required this.reference,
    required this.stationId,
    required this.chargingPointId,
    required this.startAt,
    required this.endAt,
    required this.status,
    required this.paymentStatus,
    required this.bookingFee,
    this.customerDisplayName,
    this.vehicleLabel,
    this.holdExpiresAt,
    this.checkedInAt,
    this.chargingStartedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancellationActor,
    this.cancellationReason,
    this.refundEligible,
    this.noShowAt,
    this.createdAt,
    this.stationName,
    this.chargingPointCode,
  });

  /// Accepts table rows (with `period`) and RPC projections (with start_at/end_at).
  factory Booking.fromJson(Object? json) {
    final j = Json.of(json);
    final DateTime start;
    final DateTime end;
    if (j['period'] is String) {
      final r = TstzRange.parse(j.str('period'));
      start = r.start;
      end = r.end;
    } else {
      start = j.dateTime('start_at');
      end = j.dateTime('end_at');
    }
    final station = j.objectOrNull('stations');
    final point = j.objectOrNull('charging_points');
    return Booking(
      id: j.str('id'),
      reference: j.str('reference'),
      stationId: j.str('station_id'),
      chargingPointId: j.str('charging_point_id'),
      startAt: start,
      endAt: end,
      status: BookingStatus.parse(j.strOrNull('status')),
      paymentStatus: BookingPaymentStatus.parse(j.strOrNull('payment_status')),
      bookingFee: Money(j.integer('booking_fee_paise', 0)),
      customerDisplayName: j.strOrNull('customer_display_name'),
      vehicleLabel: j.strOrNull('vehicle_label'),
      holdExpiresAt: j.dateTimeOrNull('hold_expires_at'),
      checkedInAt: j.dateTimeOrNull('checked_in_at'),
      chargingStartedAt: j.dateTimeOrNull('charging_started_at'),
      completedAt: j.dateTimeOrNull('completed_at'),
      cancelledAt: j.dateTimeOrNull('cancelled_at'),
      cancellationActor: j['cancellation_actor'] == null ? null : ActorKind.parse(j.strOrNull('cancellation_actor')),
      cancellationReason: j.strOrNull('cancellation_reason'),
      refundEligible: j.boolOrNull('refund_eligible'),
      noShowAt: j.dateTimeOrNull('no_show_at'),
      createdAt: j.dateTimeOrNull('created_at'),
      stationName: j.strOrNull('station_name') ?? station?.strOrNull('name'),
      chargingPointCode: j.strOrNull('charging_point_code') ?? point?.strOrNull('code'),
    );
  }

  /// Columns clients may select (qr_token is deliberately not readable).
  static const selectColumns =
      'id, reference, station_id, charging_point_id, period, status, payment_status, booking_fee_paise, currency, '
      'hold_expires_at, customer_display_name, vehicle_label, confirmed_at, cancelled_at, cancellation_actor, '
      'cancellation_reason, refund_eligible, checked_in_at, charging_started_at, completed_at, no_show_at, created_at';

  final String id;
  final String reference;
  final String stationId;
  final String chargingPointId;
  final DateTime startAt;
  final DateTime endAt;
  final BookingStatus status;
  final BookingPaymentStatus paymentStatus;
  final Money bookingFee;
  final String? customerDisplayName;
  final String? vehicleLabel;
  final DateTime? holdExpiresAt;
  final DateTime? checkedInAt;
  final DateTime? chargingStartedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final ActorKind? cancellationActor;
  final String? cancellationReason;
  final bool? refundEligible;
  final DateTime? noShowAt;
  final DateTime? createdAt;
  final String? stationName;
  final String? chargingPointCode;

  Duration get duration => endAt.difference(startAt);

  /// Whether staff may record a no-show now (server re-checks with policy).
  bool noShowAllowedAt(DateTime now, int graceMinutes) =>
      status == BookingStatus.confirmed && now.isAfter(startAt.add(Duration(minutes: graceMinutes)));

  /// Check-in window [start − early, start + grace] (server re-checks).
  bool checkInWindowContains(DateTime now, {required int earlyMinutes, required int graceMinutes}) =>
      !now.isBefore(startAt.subtract(Duration(minutes: earlyMinutes))) &&
      !now.isAfter(startAt.add(Duration(minutes: graceMinutes)));
}

@immutable
class BookingEvent {
  const BookingEvent({
    required this.id,
    required this.toStatus,
    required this.toPaymentStatus,
    required this.actor,
    required this.createdAt,
    this.fromStatus,
    this.fromPaymentStatus,
    this.note,
  });

  factory BookingEvent.fromJson(Object? json) {
    final j = Json.of(json);
    return BookingEvent(
      id: j.integer('id'),
      fromStatus: j['from_status'] == null ? null : BookingStatus.parse(j.strOrNull('from_status')),
      toStatus: BookingStatus.parse(j.strOrNull('to_status')),
      fromPaymentStatus: j['from_payment_status'] == null ? null : BookingPaymentStatus.parse(j.strOrNull('from_payment_status')),
      toPaymentStatus: BookingPaymentStatus.parse(j.strOrNull('to_payment_status')),
      actor: ActorKind.parse(j.strOrNull('actor')),
      note: j.strOrNull('note'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final int id;
  final BookingStatus? fromStatus;
  final BookingStatus toStatus;
  final BookingPaymentStatus? fromPaymentStatus;
  final BookingPaymentStatus toPaymentStatus;
  final ActorKind actor;
  final String? note;
  final DateTime createdAt;

  String get summary {
    if (fromStatus == null) return 'Created as ${toStatus.label.toLowerCase()}';
    if (fromStatus != toStatus) return '${fromStatus!.label} → ${toStatus.label}';
    return 'Payment: ${fromPaymentStatus?.label ?? '-'} → ${toPaymentStatus.label}';
  }
}

/// Booking QR payloads are `CKB1:<opaque token>`; references are `CK` + 10
/// Crockford base32 characters. Neither contains personal data.
abstract final class BookingCode {
  static final _reference = RegExp(r'^CK[0-9A-HJKMNP-TV-Z]{10}$');
  static final _qr = RegExp(r'^CKB1:[A-Za-z0-9_-]{16,64}$');

  static bool isReference(String input) => _reference.hasMatch(input.trim().toUpperCase());
  static bool isQrPayload(String input) => _qr.hasMatch(input.trim());

  /// Normalises scanned or typed input; returns null if it can't be a booking code.
  static String? normalize(String input) {
    final t = input.trim();
    if (isQrPayload(t)) return t;
    final upper = t.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    return isReference(upper) ? upper : null;
  }
}
