import 'dart:async';

import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// Everything the Retail App asks of the backend. Guests can call the
/// discovery methods with the publishable key; the rest need the customer
/// session created by phone OTP. All authorisation happens server-side.
class RetailRepository extends Repository {
  RetailRepository(super.client, {this.timeout = const Duration(seconds: 20)});

  final Duration timeout;

  Future<T> _rpc<T>(String fn, [Map<String, dynamic>? params]) => rpc<T>(fn, params).timeout(
        timeout,
        onTimeout: () => throw const AppFailure(FailureKind.network, 'timeout', 'This is taking too long. Check your connection and try again.'),
      );

  /// Discovery calls work without an account. If the server rejects the
  /// request as unauthenticated, a stale session on this device is the usual
  /// cause: drop it and try once more as a guest. If there is no session,
  /// the app's own key was rejected, which is a setup problem, not something
  /// the customer can fix by signing in.
  Future<T> _public<T>(String fn, [Map<String, dynamic>? params]) async {
    try {
      return await _rpc<T>(fn, params);
    } on AppFailure catch (f) {
      if (f.kind != FailureKind.unauthenticated) rethrow;
      if (client.auth.currentSession != null) {
        await client.auth.signOut(scope: SignOutScope.local).catchError((_) {});
        return _rpc<T>(fn, params);
      }
      throw AppFailure(FailureKind.server, 'api_key_rejected', 'The server did not accept this app.', detail: f.code);
    }
  }

  bool get signedIn => client.auth.currentUser != null;
  String? get userId => client.auth.currentUser?.id;
  String? get sessionPhone {
    final p = client.auth.currentUser?.phone;
    if (p == null || p.isEmpty) return null;
    return p.startsWith('+') ? p : '+$p';
  }

  Stream<AuthState> get authChanges => client.auth.onAuthStateChange;

  // -------------------------------------------------------------------------
  // Discovery (guests)
  // -------------------------------------------------------------------------

  /// Near Me: stations within [radiusKm] (null: the platform default).
  Future<SearchResult> searchStations(double lat, double lng, double? radiusKm) async => SearchResult.fromJson(
        await _public<Object?>('search_stations', {'p_latitude': lat, 'p_longitude': lng, 'p_radius_km': radiusKm, 'p_limit': 60}),
      );

  /// Driving routes between two places, the engine's pick first, then up to
  /// two alternatives (route-plan function, free OpenStreetMap routing).
  /// Fails with no_route, route_too_short, route_too_long or
  /// routing_unavailable.
  Future<List<RoutePlan>> planRoutes(TripPlace from, TripPlace to) async => RoutePlan.listFromJson(await _invoke('route-plan', {
        'from': _point(from.latitude, from.longitude),
        'to': _point(to.latitude, to.longitude),
      }));

  /// Extra distance and time for stopping at a station on [route].
  Future<Detour> detour(TripPlace from, TripPlace to, RoutePlan route, double lat, double lng) async {
    final via = RoutePlan.fromJson(await _invoke('route-plan', {
      'from': _point(from.latitude, from.longitude),
      'to': _point(to.latitude, to.longitude),
      'via': _point(lat, lng),
    }));
    return Detour(
      extraKm: (via.distanceKm - route.distanceKm).clamp(0, double.infinity).toDouble(),
      extraMinutes: (via.durationMinutes - route.durationMinutes).clamp(0, 1 << 20),
    );
  }

  /// Near Me: driving distance to each station (at most 25), by station id.
  /// Stations the engine could not route to are left out.
  Future<Map<String, DrivingDistance>> drivingDistances(double lat, double lng, List<StationSummary> stations) async {
    final some = stations.take(25).toList();
    if (some.isEmpty) return const {};
    final r = await _invoke('route-plan', {
      'from': _point(lat, lng),
      'destinations': [for (final s in some) _point(s.latitude, s.longitude)],
    });
    final list = r['distances'] as List? ?? const [];
    return {
      for (final (i, s) in some.indexed)
        if (i < list.length && DrivingDistance.fromJson(list[i]) != null) s.id: DrivingDistance.fromJson(list[i])!,
    };
  }

  static Map<String, double> _point(double lat, double lng) => {'latitude': lat, 'longitude': lng};

  /// Along My Route: stations within [corridorKm] of the route (null: the
  /// platform default), in the order they are reached.
  Future<SearchResult> searchAlongRoute(RoutePlan route, double? corridorKm) async => SearchResult.fromJson(
        await _public<Object?>('search_stations_along_route', {'p_path': route.pathJson, 'p_corridor_km': corridorKm, 'p_limit': 100}),
      );

  Future<StationDetail> station(String id, {double? lat, double? lng}) async =>
      StationDetail.fromJson(await _public<Object?>('get_public_station', {'p_station_id': id, 'p_latitude': lat, 'p_longitude': lng}));

  Future<SlotGrid> slots(String stationId, DateTime localDate) async =>
      SlotGrid.fromJson(await _public<Object?>('get_station_slots', {'p_station_id': stationId, 'p_date': Repository.date(localDate)}));

  /// Whether any compatible point at the station is free for the period.
  Future<SlotCheck> checkSlot(String stationId, DateTime start, DateTime end, {String? connector}) async =>
      SlotCheck.fromJson(await _public<Object?>('check_station_availability', {
        'p_station_id': stationId,
        'p_start_at': start.toUtc().toIso8601String(),
        'p_end_at': end.toUtc().toIso8601String(),
        'p_connector_type': connector,
      }));

  Future<BookingTerms> terms() async => BookingTerms.fromJson(await _public<Object?>('get_booking_terms'));

  /// Place search: OpenStreetMap places (geocode-area function, ranked
  /// near [near] when given) and localities that have stations, merged and
  /// de-duplicated. Either source may fail alone.
  Future<AreaSearchOutcome> searchAreas(String query, {TripPlace? near}) async {
    final q = query.trim();
    final provider = _invoke('geocode-area', {
      'query': q,
      if (near != null) 'near': {'latitude': near.latitude, 'longitude': near.longitude},
    }).then<List<AreaMatch>?>(
      (r) => (r['results'] as List? ?? const []).map((e) => AreaMatch.fromJson(Json.of(e))).toList(),
      onError: (_) => null,
    );
    final local = _public<List<dynamic>?>('search_areas', {'p_query': q, 'p_limit': 8})
        .then<List<AreaMatch>?>((r) => (r ?? const []).map((e) => AreaMatch.fromJson(Json.of(e))).toList(), onError: (_) => null);
    final results = await Future.wait([provider, local]);
    // With the place search down, an empty list would wrongly say the place
    // does not exist.
    if (results[0] == null && (results[1] == null || results[1]!.isEmpty)) {
      throw const AppFailure(FailureKind.network, 'area_search_failed', 'Area search is unavailable right now. Please try again.');
    }
    final seen = <String>{};
    final merged = <AreaMatch>[];
    for (final m in [...?results[0], ...?results[1]]) {
      final key = '${m.label.toLowerCase()}|${m.latitude.toStringAsFixed(2)}|${m.longitude.toStringAsFixed(2)}';
      if (seen.add(key)) merged.add(m);
    }
    return AreaSearchOutcome(merged, providerAvailable: results[0] != null);
  }

  Future<String> reportStation(String stationId, String kind, String message) async {
    final r = await _rpc<Map<String, dynamic>>('submit_customer_report', {'p_kind': kind, 'p_message': message, 'p_station_id': stationId});
    return r['reference'] as String;
  }

  // -------------------------------------------------------------------------
  // Phone verification (creates or links the customer account)
  // -------------------------------------------------------------------------

  Future<void> sendOtp(String phone) => guard(() => client.auth.signInWithOtp(phone: phone, shouldCreateUser: true));

  Future<void> verifyOtp(String phone, String code) =>
      guard(() => client.auth.verifyOTP(phone: phone, token: code.trim(), type: OtpType.sms));

  /// Local development only: the last code the dev SMS hook received for
  /// this number (supabase/dev/dev_otp.sql). Null when the hook isn't set up,
  /// which is always the case on a hosted project.
  Future<String?> devOtpCode(String phone) async {
    try {
      return await _rpc<String?>('dev_otp_code', {'p_phone': phone});
    } catch (_) {
      return null;
    }
  }

  /// Local development only: records a simulated payment outcome for a
  /// held booking through the same server path as a real payment
  /// (supabase/dev/dev_payments.sql). Does not exist on a hosted project.
  Future<void> devMockPayment(String bookingId, {required bool success}) =>
      _rpc<dynamic>('dev_mock_payment', {'p_booking_id': bookingId, 'p_outcome': success ? 'success' : 'failure'});

  /// Starts a mobile-number change; confirm with [confirmPhoneChange].
  Future<void> changePhone(String phone) => guard(() => client.auth.updateUser(UserAttributes(phone: phone)));

  Future<void> confirmPhoneChange(String phone, String code) =>
      guard(() => client.auth.verifyOTP(phone: phone, token: code.trim(), type: OtpType.phoneChange));

  Future<void> signOut() => guard(() => client.auth.signOut());

  // -------------------------------------------------------------------------
  // Profile and consents
  // -------------------------------------------------------------------------

  Future<CustomerProfile?> profile() => maybeRow(
        client.from('profiles').select('id, full_name, phone, email, receipt_email, notification_prefs, locale').eq('id', uid).maybeSingle(),
        CustomerProfile.fromJson,
      );

  Future<void> updateProfile({String? fullName, String? receiptEmail, bool clearReceiptEmail = false, Map<String, bool>? prefs, String? locale}) {
    final patch = <String, dynamic>{
      if (fullName != null) 'full_name': fullName.trim(),
      if (receiptEmail != null) 'receipt_email': receiptEmail.trim().toLowerCase(),
      if (clearReceiptEmail) 'receipt_email': null,
      'notification_prefs': ?prefs,
      'locale': ?locale,
    };
    if (patch.isEmpty) return Future.value();
    return guard(() async => client.from('profiles').update(patch).eq('id', uid));
  }

  Future<void> recordConsents({required String version, required bool terms, required bool marketing}) => guard(() async {
        await client.from('customer_consents').insert([
          if (terms) {'kind': 'booking_terms', 'version': version, 'granted': true},
          if (terms) {'kind': 'privacy_notice', 'version': version, 'granted': true},
          {'kind': 'marketing', 'version': version, 'granted': marketing},
        ]);
      });

  // -------------------------------------------------------------------------
  // Booking and payment
  // -------------------------------------------------------------------------

  /// Reserves the slot for the payment window. Retrying with the same
  /// [idempotencyKey] returns the same booking instead of a second one.
  /// The server assigns a free compatible point at the station.
  Future<CustomerBooking> createHold({
    required String stationId,
    required DateTime start,
    required DateTime end,
    required String idempotencyKey,
    String? connector,
    String? vehicleLabel,
  }) async {
    final hold = await _rpc<Map<String, dynamic>>('create_station_booking_hold', {
      'p_station_id': stationId,
      'p_start_at': start.toUtc().toIso8601String(),
      'p_end_at': end.toUtc().toIso8601String(),
      'p_idempotency_key': idempotencyKey,
      'p_connector_type': connector,
      'p_vehicle_label': vehicleLabel,
    });
    return booking(hold['id'] as String);
  }

  Future<OrderInfo> createOrder(String bookingId) async => OrderInfo.fromJson(await _invoke('payments-create-order', {'booking_id': bookingId}));

  /// Returns the server's verdict: confirmed, revived, duplicate, slot_lost,
  /// refund_initiated, failed_recorded...
  Future<String> verifyPayment({required String orderId, required String paymentId, required String signature}) async {
    final r = await _invoke('payments-verify', {'razorpay_order_id': orderId, 'razorpay_payment_id': paymentId, 'razorpay_signature': signature});
    return r['result']?.toString() ?? 'unknown';
  }

  Future<List<CustomerBooking>> myBookings() async {
    final list = await _rpc<List<dynamic>?>('get_my_bookings', {'p_limit': 200});
    return (list ?? const []).map(CustomerBooking.fromJson).toList();
  }

  Future<CustomerBooking> booking(String id) async => CustomerBooking.fromJson(await _rpc<Object?>('get_my_booking', {'p_booking_id': id}));

  Future<CustomerBooking> bookingByReference(String reference) async =>
      CustomerBooking.fromJson(await _rpc<Object?>('get_my_booking', {'p_booking_id': null, 'p_reference': reference}));

  Future<String> bookingQr(String id) async => (await _rpc<Map<String, dynamic>>('get_my_booking_qr', {'p_booking_id': id}))['qr_payload'] as String;

  Future<CancellationPreview> previewCancellation(String id) async =>
      CancellationPreview.fromJson(await _rpc<Object?>('preview_cancellation', {'p_booking_id': id}));

  Future<void> cancel(String id) => _rpc<Object?>('cancel_booking', {'p_booking_id': id, 'p_reason': null});

  Future<void> resendEmail(String id, {String? email}) => _rpc<Object?>('resend_booking_email', {'p_booking_id': id, 'p_email': email});

  Future<String> reportBookingIssue(String bookingId, String kind, String? message) async {
    final r = await _rpc<Map<String, dynamic>>('submit_customer_report', {'p_kind': kind, 'p_message': message, 'p_booking_id': bookingId});
    return r['reference'] as String;
  }

  Future<DeletionCheck> deletionCheck() async => DeletionCheck.fromJson(await _rpc<Object?>('get_account_deletion_check'));

  Future<void> requestDeletion(String? reason) => _rpc<Object?>('request_account_deletion', {'p_reason': reason});

  // -------------------------------------------------------------------------

  /// Calls an Edge Function and maps its `{error, message}` body to AppFailure.
  Future<Map<String, dynamic>> _invoke(String fn, Map<String, dynamic> body) async {
    try {
      final res = await client.functions.invoke(fn, body: body).timeout(timeout);
      final data = res.data;
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on FunctionException catch (e) {
      final details = e.details;
      final code = details is Map ? details['error']?.toString() ?? 'function_error' : 'function_error';
      final message = details is Map ? details['message']?.toString() : null;
      throw AppFailure(_kindFor(e.status), code, AppFailure.messages[code] ?? message ?? 'The request could not be completed.');
    } on TimeoutException {
      throw const AppFailure(FailureKind.network, 'timeout', 'This is taking too long. Check your connection and try again.');
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  static FailureKind _kindFor(int status) => switch (status) {
        401 => FailureKind.unauthenticated,
        403 => FailureKind.forbidden,
        404 => FailureKind.notFound,
        409 => FailureKind.conflict,
        422 => FailureKind.validation,
        0 => FailureKind.network,
        _ => FailureKind.server,
      };
}
