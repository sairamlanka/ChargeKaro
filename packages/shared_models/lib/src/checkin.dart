import 'package:meta/meta.dart';

import 'booking.dart';
import 'enums.dart';
import 'json.dart';

/// How a booking was checked in. `reference` is the pre-2026-11 typed code.
enum CheckinMethod with WireEnum {
  qr('qr', 'QR code'),
  manual('manual', 'Manual'),
  offline('offline', 'Offline'),
  reference('reference', 'Booking reference');

  const CheckinMethod(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static CheckinMethod? tryParse(String? wire) => values.where((v) => v.wire == wire).firstOrNull;
}

/// Server-side check-in verification. [pendingSync] only ever exists on the
/// device, for offline check-ins the server has not accepted yet.
enum VerificationStatus with WireEnum {
  notCheckedIn('not_checked_in', 'Not checked in'),
  verified('verified', 'Verified'),
  pendingSync('pending_sync', 'Pending sync'),
  rejected('rejected', 'Rejected');

  const VerificationStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static VerificationStatus parse(String? wire) => values.where((v) => v.wire == wire).firstOrNull ?? notCheckedIn;
}

/// Mandatory reason for a manual check-in (mirrors private.manual_reason_label).
enum ManualCheckinReason with WireEnum {
  qrNotWorking('qr_not_working', 'QR code not working'),
  phoneUnavailable('phone_unavailable', 'Customer phone unavailable'),
  appUnavailable('app_unavailable', 'Customer app unavailable'),
  scannerMalfunction('scanner_malfunction', 'Camera/scanner malfunction'),
  connectivityIssue('connectivity_issue', 'Internet connectivity issue'),
  qrDamaged('qr_damaged', 'QR damaged or unreadable'),
  cannotAccessBooking('cannot_access_booking', 'Customer unable to access booking'),
  other('other', 'Other');

  const ManualCheckinReason(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  bool get needsNote => this == other;

  /// Null when the reason is acceptable; otherwise what to tell the user.
  static String? validate(ManualCheckinReason? reason, String note) {
    if (reason == null) return 'Choose a reason for manual check-in.';
    if (reason.needsNote && note.trim().length < 5) return 'Describe the reason in a few words.';
    return null;
  }
}

/// Charger details staff may see before check-in (no customer data).
@immutable
class ChargerCompatibility {
  const ChargerCompatibility({this.currentType, this.maxPowerKw, this.connectors = const []});

  factory ChargerCompatibility.fromJson(Object? json) {
    final j = Json.of(json);
    return ChargerCompatibility(
      currentType: j.strOrNull('current_type'),
      maxPowerKw: j['max_power_kw'] == null ? null : j.number('max_power_kw'),
      connectors: j.strings('connectors'),
    );
  }

  final String? currentType;
  final double? maxPowerKw;
  final List<String> connectors;

  String get summary => [
        if (currentType != null) currentType!.toUpperCase(),
        if (maxPowerKw != null) '${maxPowerKw! % 1 == 0 ? maxPowerKw!.toInt() : maxPowerKw} kW',
        if (connectors.isNotEmpty) connectors.map((c) => c.replaceAll('_', ' ').toUpperCase()).join(', '),
      ].join(' · ');
}

/// Answer from a check-in RPC. Rejections are data, not exceptions, so the
/// server's audit row survives; [message] is safe to show staff.
@immutable
class CheckinResult {
  const CheckinResult({
    required this.result,
    this.code,
    this.message,
    this.eligible = false,
    this.overrideAllowed = false,
    this.replayed = false,
    this.booking,
    this.bookings = const [],
  });

  factory CheckinResult.fromJson(Object? json) {
    final j = Json.of(json);
    return CheckinResult(
      result: j.str('result'),
      code: j.strOrNull('code'),
      message: j.strOrNull('message'),
      eligible: j.boolOrNull('eligible') ?? false,
      overrideAllowed: j.boolOrNull('override_allowed') ?? false,
      replayed: j.boolOrNull('replayed') ?? false,
      booking: j['booking'] == null ? null : Booking.fromJson(j['booking']),
      bookings: j['bookings'] is List ? (j['bookings'] as List).map(Booking.fromJson).toList() : const [],
    );
  }

  /// accepted | rejected | verified (QR/booking validated, not yet checked in) | ok (search)
  final String result;
  final String? code;
  final String? message;
  final bool eligible;
  final bool overrideAllowed;
  final bool replayed;
  final Booking? booking;
  final List<Booking> bookings;

  bool get accepted => result == 'accepted';
  bool get rejected => result == 'rejected';
  bool get alreadyCheckedIn => code == 'already_checked_in' || code == 'checked_in_by_other';
  String get displayMessage => message ?? 'This booking cannot be checked in.';
}

/// One booking in the offline cache: ids, slot and charger only.
@immutable
class OfflineBooking {
  const OfflineBooking({
    required this.id,
    required this.reference,
    required this.stationId,
    required this.startAt,
    required this.endAt,
    required this.status,
    required this.opensAt,
    required this.closesAt,
    this.pointCode,
    this.currentType,
  });

  factory OfflineBooking.fromJson(Object? json) {
    final j = Json.of(json);
    return OfflineBooking(
      id: j.str('id'),
      reference: j.str('reference'),
      stationId: j.str('station_id'),
      startAt: j.dateTime('start_at'),
      endAt: j.dateTime('end_at'),
      status: BookingStatus.parse(j.strOrNull('status')),
      opensAt: j.dateTime('checkin_opens_at'),
      closesAt: j.dateTime('checkin_closes_at'),
      pointCode: j.strOrNull('charging_point_code'),
      currentType: j.strOrNull('current_type'),
    );
  }

  final String id;
  final String reference;
  final String stationId;
  final DateTime startAt;
  final DateTime endAt;
  final BookingStatus status;
  final DateTime opensAt;
  final DateTime closesAt;
  final String? pointCode;
  final String? currentType;

  Map<String, dynamic> toJson() => {
        'id': id,
        'reference': reference,
        'station_id': stationId,
        'start_at': startAt.toUtc().toIso8601String(),
        'end_at': endAt.toUtc().toIso8601String(),
        'status': status.wire,
        'checkin_opens_at': opensAt.toUtc().toIso8601String(),
        'checkin_closes_at': closesAt.toUtc().toIso8601String(),
        'charging_point_code': pointCode,
        'current_type': currentType,
      };
}

/// Snapshot of a station's checkable bookings for offline use. Belongs to
/// the staff member who downloaded it.
@immutable
class OfflineCache {
  const OfflineCache({
    required this.stationId,
    required this.staffId,
    required this.generatedAt,
    required this.validUntil,
    required this.bookings,
  });

  factory OfflineCache.fromJson(Object? json, {String? staffId}) {
    final j = Json.of(json);
    return OfflineCache(
      stationId: j.str('station_id'),
      staffId: staffId ?? j.str('staff_id'),
      generatedAt: j.dateTime('generated_at'),
      validUntil: j.dateTime('valid_until'),
      bookings: j['bookings'] is List ? (j['bookings'] as List).map(OfflineBooking.fromJson).toList() : const [],
    );
  }

  final String stationId;
  final String staffId;
  final DateTime generatedAt;
  final DateTime validUntil;
  final List<OfflineBooking> bookings;

  Map<String, dynamic> toJson() => {
        'station_id': stationId,
        'staff_id': staffId,
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'valid_until': validUntil.toUtc().toIso8601String(),
        'bookings': [for (final b in bookings) b.toJson()],
      };
}

enum OfflineEventState { pendingSync, accepted, rejected }

/// A check-in recorded without a connection. Provisional until the server
/// accepts it; never shown as verified before that.
@immutable
class OfflineCheckinEvent {
  const OfflineCheckinEvent({
    required this.eventId,
    required this.bookingId,
    required this.reference,
    required this.stationId,
    required this.staffId,
    required this.offlineAt,
    required this.deviceId,
    this.state = OfflineEventState.pendingSync,
    this.code,
    this.message,
    this.syncedAt,
    this.attempts = 0,
  });

  factory OfflineCheckinEvent.fromJson(Object? json) {
    final j = Json.of(json);
    return OfflineCheckinEvent(
      eventId: j.str('event_id'),
      bookingId: j.str('booking_id'),
      reference: j.str('reference'),
      stationId: j.str('station_id'),
      staffId: j.str('staff_id'),
      offlineAt: j.dateTime('offline_at'),
      deviceId: j.str('device_id'),
      state: OfflineEventState.values.byName(j.strOrNull('state') ?? 'pendingSync'),
      code: j.strOrNull('code'),
      message: j.strOrNull('message'),
      syncedAt: j.dateTimeOrNull('synced_at'),
      attempts: j.intOrNull('attempts') ?? 0,
    );
  }

  final String eventId;
  final String bookingId;
  final String reference;
  final String stationId;
  final String staffId;

  /// Device clock at check-in. Informational only: the server decides.
  final DateTime offlineAt;
  final String deviceId;
  final OfflineEventState state;
  final String? code;
  final String? message;
  final DateTime? syncedAt;
  final int attempts;

  bool get pending => state == OfflineEventState.pendingSync;

  OfflineCheckinEvent copyWith({OfflineEventState? state, String? code, String? message, DateTime? syncedAt, int? attempts}) =>
      OfflineCheckinEvent(
        eventId: eventId,
        bookingId: bookingId,
        reference: reference,
        stationId: stationId,
        staffId: staffId,
        offlineAt: offlineAt,
        deviceId: deviceId,
        state: state ?? this.state,
        code: code ?? this.code,
        message: message ?? this.message,
        syncedAt: syncedAt ?? this.syncedAt,
        attempts: attempts ?? this.attempts,
      );

  /// What the sync RPC receives (no reference or staff id: the server derives
  /// identity from the session).
  Map<String, dynamic> toSyncJson() => {
        'event_id': eventId,
        'booking_id': bookingId,
        'station_id': stationId,
        'offline_at': offlineAt.toUtc().toIso8601String(),
        'device_id': deviceId,
      };

  Map<String, dynamic> toJson() => {
        ...toSyncJson(),
        'reference': reference,
        'staff_id': staffId,
        'state': state.name,
        'code': code,
        'message': message,
        'synced_at': syncedAt?.toUtc().toIso8601String(),
        'attempts': attempts,
      };
}

/// Local checks before recording an offline check-in. They only stop
/// obviously wrong entries; the server validates everything again on sync.
abstract final class OfflineCheckinRules {
  /// Null when [reference] may be checked in offline at [now]; else a
  /// message for staff.
  static String? problem({
    required OfflineCache? cache,
    required String stationId,
    required String staffId,
    required String reference,
    required DateTime now,
    required Iterable<OfflineCheckinEvent> queued,
  }) {
    if (cache == null || cache.stationId != stationId || cache.staffId != staffId) {
      return 'No offline booking list for this station. Download it while online.';
    }
    if (now.isAfter(cache.validUntil)) return 'The offline booking list is out of date. Reconnect to refresh it.';
    final ref = reference.trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    final b = cache.bookings.where((b) => b.reference == ref).firstOrNull;
    if (b == null) return 'This booking is not in the offline list for this station.';
    if (b.status != BookingStatus.confirmed) return 'This booking was ${b.status.label.toLowerCase()} when the list was downloaded.';
    if (queued.any((e) => e.bookingId == b.id && e.state != OfflineEventState.rejected)) {
      return 'This booking is already checked in on this device.';
    }
    if (now.isBefore(b.opensAt)) return 'Check-in for this booking has not opened yet.';
    if (now.isAfter(b.closesAt)) return 'The arrival window for this booking has closed.';
    return null;
  }

  static OfflineBooking? find(OfflineCache cache, String reference) {
    final ref = reference.trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    return cache.bookings.where((b) => b.reference == ref).firstOrNull;
  }
}

/// One row of the check-in history.
@immutable
class CheckinLogEntry {
  const CheckinLogEntry({
    required this.id,
    required this.action,
    required this.result,
    required this.serverAt,
    this.reference,
    this.method,
    this.reason,
    this.rejectionMessage,
    this.staffName,
    this.isMine = false,
    this.managerOverride = false,
    this.offlineAt,
  });

  factory CheckinLogEntry.fromJson(Object? json) {
    final j = Json.of(json);
    return CheckinLogEntry(
      id: j.str('id'),
      action: j.str('action'),
      result: j.str('result'),
      serverAt: j.dateTime('server_at'),
      reference: j.strOrNull('reference'),
      method: CheckinMethod.tryParse(j.strOrNull('method')),
      reason: j.strOrNull('reason'),
      rejectionMessage: j.strOrNull('rejection_message'),
      staffName: j.strOrNull('staff_name'),
      isMine: j.boolOrNull('is_mine') ?? false,
      managerOverride: j.boolOrNull('manager_override') ?? false,
      offlineAt: j.dateTimeOrNull('offline_at'),
    );
  }

  final String id;
  final String action;
  final String result;
  final DateTime serverAt;
  final String? reference;
  final CheckinMethod? method;
  final String? reason;
  final String? rejectionMessage;
  final String? staffName;
  final bool isMine;
  final bool managerOverride;
  final DateTime? offlineAt;

  bool get accepted => result == 'accepted';

  String get title => switch (action) {
        'qr_verify' => 'QR scanned',
        'checkin' => 'Checked in',
        'override' => 'Checked in (manager override)',
        'offline_sync' => 'Offline check-in synced',
        'start_charging' => 'Charging started',
        'complete_charging' => 'Charging completed',
        _ => action,
      };
}
