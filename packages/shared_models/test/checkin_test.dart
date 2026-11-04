import 'package:shared_models/shared_models.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 3, 10);

  OfflineBooking ob({String ref = 'CK7Q2M9XKD4P', BookingStatus status = BookingStatus.confirmed, int startInMin = 5}) {
    final start = now.add(Duration(minutes: startInMin));
    return OfflineBooking(
      id: 'b-$ref',
      reference: ref,
      stationId: 's1',
      startAt: start,
      endAt: start.add(const Duration(minutes: 30)),
      status: status,
      opensAt: start.subtract(const Duration(minutes: 15)),
      closesAt: start.add(const Duration(minutes: 5)),
      pointCode: 'A',
    );
  }

  OfflineCache cache(List<OfflineBooking> b, {DateTime? validUntil, String staff = 'u1'}) => OfflineCache(
        stationId: 's1',
        staffId: staff,
        generatedAt: now.subtract(const Duration(hours: 1)),
        validUntil: validUntil ?? now.add(const Duration(hours: 11)),
        bookings: b,
      );

  String? problem(OfflineCache? c, String ref, {List<OfflineCheckinEvent> queued = const [], DateTime? at, String staff = 'u1'}) =>
      OfflineCheckinRules.problem(cache: c, stationId: 's1', staffId: staff, reference: ref, now: at ?? now, queued: queued);

  group('offline check-in rules', () {
    test('a cached, confirmed booking inside its window is allowed (reference normalised)', () {
      expect(problem(cache([ob()]), ' ck7q-2m9x kd4p '), isNull);
    });

    test('no cache, another staff member\'s cache, or an outdated cache is refused', () {
      expect(problem(null, 'CK7Q2M9XKD4P'), contains('Download'));
      expect(problem(cache([ob()], staff: 'u2'), 'CK7Q2M9XKD4P'), contains('Download'));
      expect(problem(cache([ob()], validUntil: now.subtract(const Duration(minutes: 1))), 'CK7Q2M9XKD4P'), contains('out of date'));
    });

    test('bookings absent from the cache or not confirmed are refused', () {
      expect(problem(cache([ob()]), 'CK0000000000'), contains('not in the offline list'));
      expect(problem(cache([ob(status: BookingStatus.cancelled)]), 'CK7Q2M9XKD4P'), contains('cancelled'));
    });

    test('the window is enforced at both ends, inclusively', () {
      final b = ob();
      final c = cache([b]);
      expect(problem(c, b.reference, at: b.opensAt), isNull);
      expect(problem(c, b.reference, at: b.closesAt), isNull);
      expect(problem(c, b.reference, at: b.opensAt.subtract(const Duration(seconds: 1))), contains('not opened'));
      expect(problem(c, b.reference, at: b.closesAt.add(const Duration(seconds: 1))), contains('closed'));
    });

    test('the same booking cannot be queued twice, unless the first was rejected', () {
      final b = ob();
      OfflineCheckinEvent e(OfflineEventState s) => OfflineCheckinEvent(
          eventId: 'e', bookingId: b.id, reference: b.reference, stationId: 's1', staffId: 'u1', offlineAt: now, deviceId: 'd', state: s);
      expect(problem(cache([b]), b.reference, queued: [e(OfflineEventState.pendingSync)]), contains('already'));
      expect(problem(cache([b]), b.reference, queued: [e(OfflineEventState.accepted)]), contains('already'));
      expect(problem(cache([b]), b.reference, queued: [e(OfflineEventState.rejected)]), isNull);
    });
  });

  group('offline events and cache', () {
    test('round-trip through local storage JSON', () {
      final c = cache([ob()]);
      final back = OfflineCache.fromJson(c.toJson());
      expect(back.bookings.single.reference, 'CK7Q2M9XKD4P');
      expect(back.staffId, 'u1');
      final e = OfflineCheckinEvent(
          eventId: 'e1', bookingId: 'b1', reference: 'CK7Q2M9XKD4P', stationId: 's1', staffId: 'u1', offlineAt: now, deviceId: 'd1');
      final again = OfflineCheckinEvent.fromJson(e.toJson());
      expect(again.pending, isTrue);
      expect(again.offlineAt, now);
    });

    test('the sync payload carries no reference, staff id or customer data', () {
      final e = OfflineCheckinEvent(
          eventId: 'e1', bookingId: 'b1', reference: 'CK7Q2M9XKD4P', stationId: 's1', staffId: 'u1', offlineAt: now, deviceId: 'd1');
      expect(e.toSyncJson().keys, unorderedEquals(['event_id', 'booking_id', 'station_id', 'offline_at', 'device_id']));
    });

    test('cache JSON holds no personal fields', () {
      final keys = cache([ob()]).toJson()['bookings'][0].keys as Iterable<String>;
      expect(keys.where((k) => RegExp('name|phone|email|vehicle|customer').hasMatch(k)), isEmpty);
    });
  });

  group('manual reasons', () {
    test('a reason is mandatory and Other needs a note', () {
      expect(ManualCheckinReason.validate(null, ''), isNotNull);
      expect(ManualCheckinReason.validate(ManualCheckinReason.other, 'abc'), isNotNull);
      expect(ManualCheckinReason.validate(ManualCheckinReason.other, 'Phone battery dead'), isNull);
      expect(ManualCheckinReason.validate(ManualCheckinReason.qrDamaged, ''), isNull);
      expect(ManualCheckinReason.values.map((r) => r.wire), contains('cannot_access_booking'));
    });
  });

  group('check-in results', () {
    final masked = {
      'id': 'b1', 'reference': 'CK7Q2M9XKD4P', 'station_id': 's1', 'charging_point_id': 'p1',
      'start_at': '2026-11-03T10:05:00Z', 'end_at': '2026-11-03T10:35:00Z', 'status': 'confirmed', 'payment_status': 'paid',
      'verification_status': 'not_checked_in', 'customer_revealed': false, 'customer_display_name': null, 'vehicle_hint': '•••• 1234',
      'compatibility': {'current_type': 'dc', 'max_power_kw': 60, 'connectors': ['ccs2']},
    };

    test('a verified preview keeps the customer hidden', () {
      final r = CheckinResult.fromJson({'result': 'verified', 'eligible': true, 'booking': masked});
      expect(r.accepted, isFalse);
      expect(r.booking!.customerRevealed, isFalse);
      expect(r.booking!.staffTitle, 'CK7Q2M9XKD4P');
      expect(r.booking!.compatibility!.summary, 'DC · 60 kW · CCS2');
    });

    test('an accepted check-in reveals the customer', () {
      final r = CheckinResult.fromJson({
        'result': 'accepted',
        'booking': {...masked, 'status': 'arrived', 'verification_status': 'verified', 'checkin_method': 'qr',
                    'customer_revealed': true, 'customer_display_name': 'Asha Kumari', 'customer_phone': '+919800000001'},
      });
      expect(r.accepted, isTrue);
      expect(r.booking!.staffTitle, 'Asha Kumari');
      expect(r.booking!.verificationStatus, VerificationStatus.verified);
      expect(r.booking!.checkinMethod, CheckinMethod.qr);
    });

    test('rejections carry a code and a safe message', () {
      final r = CheckinResult.fromJson({'result': 'rejected', 'code': 'checked_in_by_other', 'message': 'Another staff member already checked in this booking.'});
      expect(r.rejected, isTrue);
      expect(r.alreadyCheckedIn, isTrue);
      expect(r.displayMessage, contains('Another staff'));
    });

    test('the server-computed window wins over local policy', () {
      final b = Booking.fromJson({...masked, 'checkin_opens_at': '2026-11-03T09:50:00Z', 'checkin_closes_at': '2026-11-03T10:10:00Z'});
      expect(b.checkInWindowContains(DateTime.utc(2026, 11, 3, 10, 10), earlyMinutes: 0, graceMinutes: 0), isTrue);
      expect(b.checkInWindowContains(DateTime.utc(2026, 11, 3, 10, 10, 1), earlyMinutes: 60, graceMinutes: 60), isFalse);
    });
  });

  group('booking codes', () {
    test('accepts the hashed-token QR format and recognises legacy codes', () {
      const v2 = 'CKB2:iG4TKvN8trvnVp6Og-dgPFEI9K_O68nGG_WTMo_OVTI';
      expect(BookingCode.isQrPayload(v2), isTrue);
      expect(BookingCode.isQrPayload('CKB1:QbxapCDUY2rcs52hRgNCsA'), isTrue);
      expect(BookingCode.isQrPayload('CKB3:QbxapCDUY2rcs52hRgNCsA'), isFalse);
      expect(BookingCode.isQrPayload("CKB2:'; drop table bookings;--"), isFalse);
    });
  });
}
