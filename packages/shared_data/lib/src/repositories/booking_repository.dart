import 'dart:async';

import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../failure.dart';
import 'base.dart';

/// Bookings as seen by station staff and platform admins. Customer-only
/// operations (creating holds, paying) live in the Retailer App and the
/// payments Edge Functions.
class BookingRepository extends Repository {
  BookingRepository(super.client);

  /// Bookings whose slot overlaps [from, to). Customer details are masked
  /// by the server until a booking is checked in.
  Future<List<Booking>> forStation(String stationId, DateTime from, DateTime to, {Set<BookingStatus>? statuses}) async {
    final rows = await rpc<List<dynamic>>('get_station_bookings', {
      'p_station_id': stationId,
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
      'p_statuses': statuses?.map((s) => s.wire).toList(),
    });
    return rows.map(Booking.fromJson).toList();
  }

  /// Admin search: by reference prefix, station, status or date window.
  Future<List<Booking>> search({
    String? reference,
    String? stationId,
    BookingStatus? status,
    BookingPaymentStatus? paymentStatus,
    DateTime? from,
    DateTime? to,
    CheckinFilter? checkin,
    int limit = 50,
    int offset = 0,
  }) async {
    final rows = await rpc<List<dynamic>>('admin_search_bookings', {
      'p_checkin': checkin?.wire,
      'p_reference': reference,
      'p_station_id': stationId,
      'p_status': status?.wire,
      'p_payment_status': paymentStatus?.wire,
      'p_from': from?.toUtc().toIso8601String(),
      'p_to': to?.toUtc().toIso8601String(),
      'p_limit': limit,
      'p_offset': offset,
    });
    return rows.map(Booking.fromJson).toList();
  }

  /// Admin: checked-in vs not-checked-in counts for the same filters as
  /// [search] (see 20261103000300_admin_checkin_stats.sql).
  Future<CheckinStats> checkinStats({
    String? stationId,
    BookingStatus? status,
    BookingPaymentStatus? paymentStatus,
    DateTime? from,
    DateTime? to,
  }) async =>
      CheckinStats.fromJson(await rpc<Object?>('admin_booking_checkin_stats', {
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
        'p_station_id': stationId,
        'p_status': status?.wire,
        'p_payment_status': paymentStatus?.wire,
      }));

  /// Admin: who checked a booking in, how and when, plus its check-in log.
  Future<BookingCheckinDetail> checkinDetail(String bookingId) async =>
      BookingCheckinDetail.fromJson(await rpc<Object?>('admin_get_booking_checkin', {'p_booking_id': bookingId}));

  Future<Booking> byId(String id) async => Booking.fromJson(await rpc<Object?>('get_station_booking', {'p_booking_id': id}));

  Future<List<BookingEvent>> events(String bookingId) => rows(
        client.from('booking_events').select().eq('booking_id', bookingId).order('created_at'),
        BookingEvent.fromJson,
      );

  // --- Check-in (see supabase/migrations/20261103000100_checkin.sql) ------
  // Rejections come back as CheckinResult.rejected, not as exceptions, so
  // the server's audit row is kept. Network and auth problems still throw
  // AppFailure.

  /// Step 1 of QR check-in: validates the scanned payload for [stationId].
  Future<CheckinResult> verifyQr(String stationId, String payload, {String? deviceId}) async => CheckinResult.fromJson(
      await rpc<Object?>('verify_booking_qr', {'p_station_id': stationId, 'p_payload': payload, 'p_device_id': deviceId}));

  /// Booking ID or registered mobile number, this station only. Results
  /// carry no customer details.
  Future<CheckinResult> searchForCheckIn(String stationId, String query, {String? deviceId}) async => CheckinResult.fromJson(
      await rpc<Object?>('search_bookings_for_checkin', {'p_station_id': stationId, 'p_query': query, 'p_device_id': deviceId}));

  Future<CheckinResult> forCheckIn(String stationId, String bookingId) async => CheckinResult.fromJson(
      await rpc<Object?>('get_booking_for_checkin', {'p_station_id': stationId, 'p_booking_id': bookingId}));

  /// QR confirm or manual check-in. Reuse [idempotencyKey] when retrying the
  /// same tap (timeouts); make a new one for each new action.
  Future<CheckinResult> checkIn({
    required String stationId,
    required String bookingId,
    required CheckinMethod method,
    required String idempotencyKey,
    String? qrPayload,
    ManualCheckinReason? reason,
    String? reasonNote,
    String? deviceId,
    String? overrideReason,
  }) async =>
      CheckinResult.fromJson(await rpc<Object?>('checkin_booking', {
        'p_station_id': stationId,
        'p_booking_id': bookingId,
        'p_method': method.wire,
        'p_idempotency_key': idempotencyKey,
        'p_qr_payload': qrPayload,
        'p_reason_code': reason?.wire,
        'p_reason_note': reasonNote,
        'p_device_id': deviceId,
        'p_override_reason': overrideReason,
      }));

  Future<CheckinResult> startCharging(String bookingId, {required String idempotencyKey, String? deviceId}) async =>
      CheckinResult.fromJson(await rpc<Object?>(
          'start_charging', {'p_booking_id': bookingId, 'p_idempotency_key': idempotencyKey, 'p_device_id': deviceId}));

  Future<CheckinResult> completeCharging(String bookingId, {required String idempotencyKey, String? deviceId}) async =>
      CheckinResult.fromJson(await rpc<Object?>(
          'complete_charging', {'p_booking_id': bookingId, 'p_idempotency_key': idempotencyKey, 'p_device_id': deviceId}));

  /// Today's checkable bookings for offline use (no customer data).
  Future<OfflineCache> offlineCache(String stationId, {String? deviceId}) async {
    final json = await rpc<Map<String, dynamic>>('get_offline_checkin_cache', {'p_station_id': stationId, 'p_device_id': deviceId});
    final result = CheckinResult.fromJson(json);
    if (result.rejected) throw AppFailure(FailureKind.forbidden, result.code ?? 'not_authorized', result.displayMessage);
    return OfflineCache.fromJson(json, staffId: uid);
  }

  /// Sends queued offline events; returns each one with its server verdict.
  Future<List<OfflineCheckinEvent>> syncOffline(List<OfflineCheckinEvent> events) async {
    if (events.isEmpty) return const [];
    final json = await rpc<Map<String, dynamic>>('sync_offline_checkins', {
      'p_events': [for (final e in events) e.toSyncJson()],
    });
    final byId = {for (final r in (json['results'] as List).cast<Map<String, dynamic>>()) r['event_id']: r};
    final now = DateTime.now();
    return [
      for (final e in events)
        if (byId[e.eventId] case final r?)
          e.copyWith(
            state: r['result'] == 'accepted' ? OfflineEventState.accepted : OfflineEventState.rejected,
            code: r['code'] as String?,
            message: r['message'] as String?,
            syncedAt: now,
            attempts: e.attempts + 1,
          )
        else
          e.copyWith(attempts: e.attempts + 1),
    ];
  }

  Future<List<CheckinLogEntry>> checkinHistory(String stationId, {int limit = 100}) async =>
      (await rpc<List<dynamic>>('get_checkin_history', {'p_station_id': stationId, 'p_limit': limit}))
          .map(CheckinLogEntry.fromJson)
          .toList();

  /// Records a no-show (managers, after the arrival window).
  Future<Booking> markNoShow(String bookingId) async =>
      Booking.fromJson(await rpc<Object?>('update_booking_progress', {'p_booking_id': bookingId, 'p_status': BookingStatus.noShow.wire}));

  Future<Booking> cancel(String bookingId, String reason) async =>
      Booking.fromJson(await rpc<Object?>('cancel_booking', {'p_booking_id': bookingId, 'p_reason': reason}));

  Future<Map<String, dynamic>> adminOverride(String bookingId, BookingStatus status,
          {required String reason, bool refund = false}) =>
      rpc<Map<String, dynamic>>('admin_override_booking',
          {'p_booking_id': bookingId, 'p_status': status.wire, 'p_reason': reason, 'p_refund': refund});

  Future<List<Map<String, dynamic>>> supportNotes(String bookingId) => guard(() => client
      .from('booking_support_notes')
      .select('id, note, created_at, profiles(full_name)')
      .eq('booking_id', bookingId)
      .order('created_at'));

  Future<void> addSupportNote(String bookingId, String note) =>
      rpc<void>('add_booking_support_note', {'p_booking_id': bookingId, 'p_note': note});

  /// Emits whenever a booking at [stationId] changes. Payloads are not
  /// trusted for state: listeners re-fetch through RLS.
  Stream<void> stationChanges(String stationId) {
    late final RealtimeChannel channel;
    final controller = StreamController<void>.broadcast(
      onCancel: () => client.removeChannel(channel),
    );
    channel = client
        .channel('booking-events-$stationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'booking_events',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'station_id', value: stationId),
          callback: (_) => controller.add(null),
        )
        .subscribe();
    return controller.stream;
  }
}
