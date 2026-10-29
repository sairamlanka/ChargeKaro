import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// The booking a customer is putting together. Saved on the device after
/// every step so it survives the app closing; the slot is only reserved once
/// a server-side hold exists ([bookingId]).
@immutable
class BookingDraft {
  const BookingDraft({
    required this.stationId,
    required this.stationName,
    required this.stationAddress,
    required this.latitude,
    required this.longitude,
    required this.connector,
    required this.connectorLabel,
    required this.start,
    required this.end,
    required this.displayedFeePaise,
    required this.idempotencyKey,
    required this.updatedAt,
    this.fullName = '',
    this.phone = '',
    this.email = '',
    this.vehicleLabel = '',
    this.termsAccepted = false,
    this.marketingOptIn = false,
    this.bookingId,
  });

  factory BookingDraft.fromJson(Map<String, dynamic> j) => BookingDraft(
        stationId: j['station_id'] as String,
        stationName: j['station_name'] as String,
        stationAddress: j['station_address'] as String? ?? '',
        latitude: (j['lat'] as num?)?.toDouble() ?? 0,
        longitude: (j['lng'] as num?)?.toDouble() ?? 0,
        connector: j['connector'] as String?,
        connectorLabel: j['connector_label'] as String? ?? '',
        start: DateTime.parse(j['start'] as String).toUtc(),
        end: DateTime.parse(j['end'] as String).toUtc(),
        displayedFeePaise: j['fee'] as int? ?? 0,
        fullName: j['name'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        email: j['email'] as String? ?? '',
        vehicleLabel: j['vehicle'] as String? ?? '',
        termsAccepted: j['terms'] as bool? ?? false,
        marketingOptIn: j['marketing'] as bool? ?? false,
        idempotencyKey: j['key'] as String,
        bookingId: j['booking_id'] as String?,
        updatedAt: DateTime.parse(j['updated_at'] as String),
      );

  final String stationId;
  final String stationName;
  final String stationAddress;
  final double latitude;
  final double longitude;
  /// Connector the customer needs (wire value), or null for any. The
  /// charging point itself is assigned by the server when the hold is made.
  final String? connector;
  final String connectorLabel;
  final DateTime start;
  final DateTime end;

  /// The fee shown when the slot was chosen; compared with the server's
  /// amount before payment so a change is never silent.
  final int displayedFeePaise;
  final String fullName;
  final String phone;
  final String email;
  final String vehicleLabel;
  final bool termsAccepted;
  final bool marketingOptIn;

  /// Sent with create_booking_hold so a retried request never makes a
  /// second booking. Renewed whenever the slot changes.
  final String idempotencyKey;
  final String? bookingId;
  final DateTime updatedAt;

  Duration get duration => end.difference(start);
  bool get hasContact => fullName.trim().length >= 2 && phone.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'station_id': stationId,
        'station_name': stationName,
        'station_address': stationAddress,
        'lat': latitude,
        'lng': longitude,
        'connector': connector,
        'connector_label': connectorLabel,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'fee': displayedFeePaise,
        'name': fullName,
        'phone': phone,
        'email': email,
        'vehicle': vehicleLabel,
        'terms': termsAccepted,
        'marketing': marketingOptIn,
        'key': idempotencyKey,
        'booking_id': bookingId,
        'updated_at': updatedAt.toIso8601String(),
      };

  BookingDraft copyWith({
    String? fullName,
    String? phone,
    String? email,
    String? vehicleLabel,
    bool? termsAccepted,
    bool? marketingOptIn,
    int? displayedFeePaise,
    String? Function()? bookingId,
    String? idempotencyKey,
  }) =>
      BookingDraft(
        stationId: stationId,
        stationName: stationName,
        stationAddress: stationAddress,
        latitude: latitude,
        longitude: longitude,
        connector: connector,
        connectorLabel: connectorLabel,
        start: start,
        end: end,
        displayedFeePaise: displayedFeePaise ?? this.displayedFeePaise,
        fullName: fullName ?? this.fullName,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        vehicleLabel: vehicleLabel ?? this.vehicleLabel,
        termsAccepted: termsAccepted ?? this.termsAccepted,
        marketingOptIn: marketingOptIn ?? this.marketingOptIn,
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        bookingId: bookingId == null ? this.bookingId : bookingId(),
        updatedAt: DateTime.now(),
      );
}

String newIdempotencyKey() {
  final r = Random.secure();
  return 'rt-${List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

final bookingFlowProvider = NotifierProvider<BookingFlowController, BookingDraft?>(BookingFlowController.new);

class BookingFlowController extends Notifier<BookingDraft?> {
  @override
  BookingDraft? build() {
    final raw = ref.read(localStoreProvider).draft();
    if (raw == null) return null;
    try {
      // Drafts from before station-level booking named a point; start over.
      if (raw.containsKey('point_id')) {
        unawaited(ref.read(localStoreProvider).saveDraft(null));
        return null;
      }
      final d = BookingDraft.fromJson(raw);
      final now = DateTime.now();
      // A draft without a hold is only useful while its slot is ahead.
      if (d.bookingId == null && (d.start.isBefore(now) || now.difference(d.updatedAt) > const Duration(days: 1))) {
        unawaited(ref.read(localStoreProvider).saveDraft(null));
        return null;
      }
      if (now.difference(d.updatedAt) > const Duration(days: 2)) {
        unawaited(ref.read(localStoreProvider).saveDraft(null));
        return null;
      }
      return d;
    } catch (_) {
      return null;
    }
  }

  void _set(BookingDraft? d) {
    state = d;
    unawaited(ref.read(localStoreProvider).saveDraft(d?.toJson()));
  }

  /// Starts (or restarts) a booking for a slot. Contact details already
  /// typed in are kept; any earlier hold is forgotten (it expires by itself).
  void selectSlot({
    required String stationId,
    required String stationName,
    required String stationAddress,
    required double latitude,
    required double longitude,
    required String? connector,
    required String connectorLabel,
    required DateTime start,
    required DateTime end,
    required int feePaise,
  }) {
    final old = state;
    _set(BookingDraft(
      stationId: stationId,
      stationName: stationName,
      stationAddress: stationAddress,
      latitude: latitude,
      longitude: longitude,
      connector: connector,
      connectorLabel: connectorLabel,
      start: start.toUtc(),
      end: end.toUtc(),
      displayedFeePaise: feePaise,
      fullName: old?.fullName ?? '',
      phone: old?.phone ?? '',
      email: old?.email ?? '',
      vehicleLabel: old?.vehicleLabel ?? '',
      termsAccepted: false,
      marketingOptIn: old?.marketingOptIn ?? false,
      idempotencyKey: newIdempotencyKey(),
      updatedAt: DateTime.now(),
    ));
  }

  void setContact({required String fullName, required String phone, required String email, required String vehicleLabel}) {
    final d = state;
    if (d == null) return;
    _set(d.copyWith(fullName: fullName.trim(), phone: phone, email: email.trim(), vehicleLabel: vehicleLabel.trim()));
  }

  void setConsents({required bool terms, required bool marketing}) {
    final d = state;
    if (d == null) return;
    _set(d.copyWith(termsAccepted: terms, marketingOptIn: marketing));
  }

  void acceptFee(int paise) {
    final d = state;
    if (d == null) return;
    _set(d.copyWith(displayedFeePaise: paise));
  }

  void attachBooking(String id) {
    final d = state;
    if (d == null) return;
    _set(d.copyWith(bookingId: () => id));
  }

  /// The hold ended (expired, cancelled or lost): a new attempt needs a new key.
  void releaseHold() {
    final d = state;
    if (d == null) return;
    _set(d.copyWith(bookingId: () => null, idempotencyKey: newIdempotencyKey()));
  }

  void clear() => _set(null);
}
