import 'package:shared_models/shared_models.dart';
import 'package:test/test.dart';

void main() {
  group('Money', () {
    test('formats with Indian grouping', () {
      expect(const Money(1200).format(), '₹12.00');
      expect(const Money(123456789).format(), '₹12,34,567.89');
      expect(const Money(-2500).format(), '-₹25.00');
      expect(const Money(5).format(symbol: false), '0.05');
    });

    test('parses rupee input without floating point', () {
      expect(Money.tryParseRupees('12'), const Money(1200));
      expect(Money.tryParseRupees('12.5'), const Money(1250));
      expect(Money.tryParseRupees('₹1,250.75'), const Money(125075));
      expect(Money.tryParseRupees('0.1'), const Money(10));
      expect(Money.tryParseRupees('12.345'), isNull);
      expect(Money.tryParseRupees('-1'), isNull);
      expect(Money.tryParseRupees('abc'), isNull);
    });
  });

  group('enums', () {
    test('round-trip wire values and fall back safely', () {
      for (final s in BookingStatus.values) {
        expect(BookingStatus.parse(s.wire), s);
      }
      expect(BookingStatus.parse('something_new'), BookingStatus.expired);
      expect(ApplicationStatus.parse('additional_information_required'), ApplicationStatus.additionalInformationRequired);
      expect(PlatformRole.tryParse('root'), isNull);
    });

    test('booking transitions mirror the database', () {
      expect(BookingStatus.confirmed.canTransitionTo(BookingStatus.arrived), isTrue);
      expect(BookingStatus.confirmed.canTransitionTo(BookingStatus.completed), isFalse);
      expect(BookingStatus.noShow.isTerminal, isTrue);
      expect(BookingStatus.expired.canTransitionTo(BookingStatus.confirmed), isTrue, reason: 'late payment revival');
      expect(BookingStatus.values.where((s) => s.holdsSlot).toSet(),
          {BookingStatus.paymentPending, BookingStatus.confirmed, BookingStatus.arrived, BookingStatus.inProgress});
    });

    test('point status: booked is not an operational status', () {
      expect(PointStatus.values.map((e) => e.wire), isNot(contains('booked')));
      expect(PointStatus.maintenance.acceptsBookings, isFalse);
      expect(PointStatus.inUse.acceptsBookings, isTrue);
    });
  });

  group('Booking', () {
    test('parses a table row with a tstzrange period', () {
      final b = Booking.fromJson({
        'id': 'b1',
        'reference': 'CKABCDEFGH12',
        'station_id': 's1',
        'charging_point_id': 'p1',
        'period': '["2026-10-22 04:30:00+00","2026-10-22 05:30:00+00")',
        'status': 'confirmed',
        'payment_status': 'paid',
        'booking_fee_paise': 1200,
        'stations': {'name': 'Koramangala'},
        'charging_points': {'code': 'DC1'},
      });
      expect(b.startAt, DateTime.utc(2026, 10, 22, 4, 30));
      expect(b.duration, const Duration(hours: 1));
      expect(b.bookingFee, const Money(1200));
      expect(b.stationName, 'Koramangala');
      expect(b.chargingPointCode, 'DC1');
    });

    test('parses an RPC projection with start_at/end_at', () {
      final b = Booking.fromJson({
        'id': 'b1',
        'reference': 'CKABCDEFGH12',
        'station_id': 's1',
        'charging_point_id': 'p1',
        'start_at': '2026-10-22T04:30:00+00:00',
        'end_at': '2026-10-22T05:00:00+00:00',
        'status': 'arrived',
        'payment_status': 'not_required',
        'booking_fee_paise': 0,
      });
      expect(b.status, BookingStatus.arrived);
      expect(b.paymentStatus.settled, isTrue);
    });

    test('check-in and no-show windows', () {
      final b = Booking.fromJson({
        'id': 'b', 'reference': 'CK0000000000', 'station_id': 's', 'charging_point_id': 'p',
        'start_at': '2026-10-22T10:00:00Z', 'end_at': '2026-10-22T10:30:00Z',
        'status': 'confirmed', 'payment_status': 'paid', 'booking_fee_paise': 1200,
      });
      final start = DateTime.utc(2026, 10, 22, 10);
      expect(b.checkInWindowContains(start.subtract(const Duration(minutes: 16)), earlyMinutes: 15, graceMinutes: 15), isFalse);
      expect(b.checkInWindowContains(start.add(const Duration(minutes: 15)), earlyMinutes: 15, graceMinutes: 15), isTrue);
      expect(b.noShowAllowedAt(start.add(const Duration(minutes: 10)), 15), isFalse);
      expect(b.noShowAllowedAt(start.add(const Duration(minutes: 16)), 15), isTrue);
    });
  });

  group('BookingCode', () {
    test('accepts references and QR payloads only', () {
      expect(BookingCode.normalize(' ckabcdefgh12 '), 'CKABCDEFGH12');
      expect(BookingCode.normalize('CK-ABCD-EFGH-12'), 'CKABCDEFGH12');
      expect(BookingCode.normalize('CKB1:abcDEF123_-xyz789AB'), 'CKB1:abcDEF123_-xyz789AB');
      expect(BookingCode.normalize('CKABCDEFGHI2'), isNull, reason: 'I is not Crockford base32');
      expect(BookingCode.normalize('hello'), isNull);
    });
  });

  group('access', () {
    test('business permissions are scoped to assigned stations', () {
      final staff = BusinessAccess.fromJson({
        'business_id': 'b', 'business_name': 'B', 'business_status': 'active', 'member_id': 'm',
        'role': 'station_staff', 'permissions': ['bookings.view', 'bookings.checkin'], 'station_ids': ['s1'],
      });
      expect(staff.can(BusinessPermission.bookingsCheckin, stationId: 's1'), isTrue);
      expect(staff.can(BusinessPermission.bookingsCheckin, stationId: 's2'), isFalse);
      expect(staff.can(BusinessPermission.stationEdit, stationId: 's1'), isFalse);
      final owner = BusinessAccess.fromJson({
        'business_id': 'b', 'business_name': 'B', 'business_status': 'active', 'member_id': 'm',
        'role': 'owner', 'permissions': <String>[], 'station_ids': <String>[],
      });
      expect(owner.can(BusinessPermission.documentsManage, stationId: 'anything'), isTrue);
    });

    test('platform access', () {
      final su = PlatformAccess.fromJson({'is_staff': true, 'role': 'super_admin', 'permissions': <String>[]});
      expect(su.can(PlatformPermission.financeRead), isTrue);
      final admin = PlatformAccess.fromJson({'is_staff': true, 'role': 'admin', 'permissions': ['applications.review']});
      expect(admin.can(PlatformPermission.financeRead), isFalse);
      expect(PlatformAccess.fromJson({'is_staff': false}).can(PlatformPermission.applicationsReview), isFalse);
    });
  });

  group('FinancialSummary', () {
    test('parses and checks internal consistency', () {
      final s = FinancialSummary.fromJson({
        'gross_booking_fee_collections_paise': 3600,
        'successful_payments': 3,
        'failed_payments': 1,
        'refunds_paise': 1200,
        'refund_count': 1,
        'pending_refunds_paise': 0,
        'payment_processing_fees_paise': 58,
        'payment_processing_fee_tax_paise': 9,
        'net_booking_fee_revenue_paise': 2342,
        'operating_expenses_paise': 200000,
        'estimated_operating_profit_paise': -197658,
        'expenses_by_category': [
          {'category': 'Cloud hosting', 'amount_paise': 200000},
        ],
      });
      expect(s.isConsistent, isTrue);
      expect(s.expensesByCategory['Cloud hosting'], const Money(200000));
      expect(s.estimatedProfit.isNegative, isTrue);
    });
  });

  group('station models', () {
    test('operating hours overlap and labels', () {
      const a = OperatingHours(dayOfWeek: 1, opensMinute: 360, closesMinute: 720);
      const b = OperatingHours(dayOfWeek: 1, opensMinute: 720, closesMinute: 1440);
      const c = OperatingHours(dayOfWeek: 1, opensMinute: 700, closesMinute: 800);
      expect(a.overlaps(b), isFalse);
      expect(a.overlaps(c), isTrue);
      expect(b.label, '12:00–24:00');
      expect(a.dayName, 'Mon');
    });

    test('booking policy validation mirrors DB checks', () {
      const p = BookingPolicy(
        stationId: 's', slotDurationMinutes: 30, minBookingMinutes: 45, maxBookingMinutes: 30, minAdvanceMinutes: 0,
        maxAdvanceDays: 100, bufferMinutes: 0, arrivalGraceMinutes: 15, earlyCheckinMinutes: 15,
        customerCancelUntilMinutes: 0, autoNoShowEnabled: true,
      );
      final errors = p.validate();
      expect(errors, contains('Maximum booking must be at least the minimum.'));
      expect(errors, contains('Minimum booking must be a multiple of the slot length.'));
      expect(errors, contains('Advance window must be 1–90 days.'));
    });

    test('tstzrange parsing', () {
      final r = TstzRange.parse('["2026-01-01 10:00:00+05:30","2026-01-01 11:00:00+05:30")');
      expect(r.start, DateTime.utc(2026, 1, 1, 4, 30));
      expect(r.end.difference(r.start), const Duration(hours: 1));
    });
  });
}
