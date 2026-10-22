import 'package:flutter_test/flutter_test.dart';
import 'package:retailer_app/data/models.dart';
import 'package:retailer_app/state/booking_flow.dart';
import 'package:retailer_app/state/search.dart';
import 'package:shared_models/shared_models.dart';

import 'support.dart';

void main() {
  final now = DateTime.now().toUtc();

  group('customer phase comes only from server state', () {
    CustomerPhase phase(Map<String, Object?> j) => CustomerBooking.fromJson(j).phaseAt(now);

    test('pending, processing, failed', () {
      expect(phase(bookingJson(status: 'payment_pending', paymentStatus: 'pending')), CustomerPhase.pendingPayment);
      expect(phase(bookingJson(status: 'payment_pending', paymentStatus: 'pending', payment: {'status': 'authorized'})), CustomerPhase.paymentProcessing);
      expect(phase(bookingJson(status: 'payment_pending', paymentStatus: 'failed')), CustomerPhase.paymentFailed);
    });

    test('confirmed and after', () {
      expect(phase(bookingJson()), CustomerPhase.confirmed);
      expect(phase(bookingJson(status: 'in_progress')), CustomerPhase.checkedIn);
      expect(phase(bookingJson(status: 'completed')), CustomerPhase.completed);
      expect(phase(bookingJson(status: 'no_show')), CustomerPhase.missed);
    });

    test('cancellations, refunds and late payments', () {
      expect(phase(bookingJson(status: 'expired', paymentStatus: 'abandoned')), CustomerPhase.expired);
      expect(phase(bookingJson(status: 'expired', paymentStatus: 'paid')), CustomerPhase.paidSlotLost);
      expect(phase(bookingJson(status: 'cancelled', paymentStatus: 'paid', cancellationActor: 'customer')), CustomerPhase.cancelled);
      expect(phase(bookingJson(status: 'cancelled', paymentStatus: 'refund_pending', cancellationActor: 'business')), CustomerPhase.refundPending);
      expect(phase(bookingJson(status: 'cancelled', paymentStatus: 'refunded', cancellationActor: 'business')), CustomerPhase.refunded);
    });

    test('arrival window follows the station policy', () {
      final b = CustomerBooking.fromJson(bookingJson(start: DateTime.utc(2026, 10, 22, 10)));
      expect(b.arrivalOpensAt, DateTime.utc(2026, 10, 22, 9, 45));
      expect(b.arrivalClosesAt, DateTime.utc(2026, 10, 22, 10, 15));
    });
  });

  test('a booking length fits only over contiguous free cells', () {
    final from = DateTime.utc(2026, 10, 23, 4, 30);
    final grid = SlotGrid.fromJson(gridJson(from, ['available', 'available', 'booked', 'available']));
    final p = grid.points.single;
    expect(p.fits(from, 60, 30), isTrue);
    expect(p.fits(from, 90, 30), isFalse);
    expect(p.fits(from.add(const Duration(minutes: 90)), 60, 30), isFalse);
    expect(p.fits(from.add(const Duration(minutes: 60)), 30, 30), isFalse);
  });

  test('station parsing is lenient and keeps the uniform fee', () {
    final d = StationDetail.fromJson(stationJson());
    expect(d.summary.bookingFee, const Money(1200));
    expect(d.summary.is24x7, isTrue);
    expect(d.points.single.connectors.single.type, ConnectorType.ccs2);
    expect(d.refundPolicy.confirmed, isFalse);
    final hidden = StationDetail.fromJson({'id': 'x', 'public': false, 'name': 'Old'});
    expect(hidden.isPublic, isFalse);
    expect(hidden.summary.bookable, isFalse);
  });

  test('masking', () {
    expect(maskPhone('+919876543210'), '+91 98•••••210');
    expect(maskEmail('ravi@example.com'), 'ra•••@example.com');
  });

  test('a draft survives the app closing', () {
    final d = BookingDraft(
      stationId: 'st1',
      stationName: 'Hub',
      stationAddress: 'Road',
      latitude: 17,
      longitude: 78,
      pointId: 'p1',
      pointLabel: 'A1',
      connectorLabel: 'CCS2',
      start: DateTime.utc(2026, 10, 23, 5),
      end: DateTime.utc(2026, 10, 23, 6),
      displayedFeePaise: 1200,
      idempotencyKey: newIdempotencyKey(),
      updatedAt: DateTime.now(),
      fullName: 'Ravi',
      phone: '+919876543210',
    );
    final back = BookingDraft.fromJson(d.toJson());
    expect(back.idempotencyKey, d.idempotencyKey);
    expect(back.start, d.start);
    expect(back.hasContact, isTrue);
    expect(newIdempotencyKey(), isNot(newIdempotencyKey()));
  });

  test('filters', () {
    final s = StationSummary.fromJson(stationJson());
    expect(const SearchFilters().matches(s, DateTime.now()), isTrue);
    expect(const SearchFilters(connectors: {ConnectorType.chademo}).matches(s, DateTime.now()), isFalse);
    expect(const SearchFilters(minPowerKw: 50).matches(s, DateTime.now()), isTrue);
    expect(const SearchFilters(minPowerKw: 100).matches(s, DateTime.now()), isFalse);
  });
}
