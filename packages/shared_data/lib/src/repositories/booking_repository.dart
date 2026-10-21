import 'dart:async';

import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../failure.dart';
import 'base.dart';

/// Bookings as seen by station staff and platform admins. Customer-only
/// operations (creating holds, paying) live in the future Retailer App and
/// the payments Edge Functions.
class BookingRepository extends Repository {
  BookingRepository(super.client);

  static const _select = '${Booking.selectColumns}, stations(name), charging_points(code)';

  /// Bookings whose slot overlaps [from, to).
  Future<List<Booking>> forStation(String stationId, DateTime from, DateTime to, {Set<BookingStatus>? statuses}) {
    var q = client.from('bookings').select(_select).eq('station_id', stationId).overlaps('period', Repository.range(from, to));
    if (statuses != null && statuses.isNotEmpty) q = q.inFilter('status', statuses.map((s) => s.wire).toList());
    return rows(q.order('period'), Booking.fromJson);
  }

  /// Admin search: by reference prefix, station, status or date window.
  Future<List<Booking>> search({
    String? reference,
    String? stationId,
    BookingStatus? status,
    BookingPaymentStatus? paymentStatus,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    int offset = 0,
  }) {
    var q = client.from('bookings').select(_select);
    if (reference != null && reference.trim().isNotEmpty) {
      q = q.ilike('reference', '${reference.trim().toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '')}%');
    }
    if (stationId != null) q = q.eq('station_id', stationId);
    if (status != null) q = q.eq('status', status.wire);
    if (paymentStatus != null) q = q.eq('payment_status', paymentStatus.wire);
    if (from != null && to != null) q = q.overlaps('period', Repository.range(from, to));
    return rows(q.order('created_at', ascending: false).range(offset, offset + limit - 1), Booking.fromJson);
  }

  Future<Booking> byId(String id) => row(client.from('bookings').select(_select).eq('id', id).single(), Booking.fromJson);

  Future<List<BookingEvent>> events(String bookingId) => rows(
        client.from('booking_events').select().eq('booking_id', bookingId).order('created_at'),
        BookingEvent.fromJson,
      );

  /// Accepts a scanned QR payload or a typed reference.
  Future<Booking> lookupForCheckIn(String stationId, String code) async =>
      Booking.fromJson(await rpc<Object?>('lookup_booking_for_checkin', {'p_station_id': stationId, 'p_code': code}));

  Future<Booking> checkIn(String stationId, String code, {required bool viaQr}) async => Booking.fromJson(
        await rpc<Object?>('check_in_booking', {'p_station_id': stationId, 'p_code': code, 'p_method': viaQr ? 'qr' : 'reference'}),
      );

  /// charging, completed or no_show; the database validates the transition.
  Future<Booking> updateProgress(String bookingId, BookingStatus status) async =>
      Booking.fromJson(await rpc<Object?>('update_booking_progress', {'p_booking_id': bookingId, 'p_status': status.wire}));

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
