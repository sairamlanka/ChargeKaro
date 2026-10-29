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
      expect(b.arrivalClosesAt, DateTime.utc(2026, 10, 22, 10, 5));
      expect(b.reportBy, DateTime.utc(2026, 10, 22, 9, 55));
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

  group('station as one grid', () {
    final from = DateTime.utc(2026, 10, 23, 3, 30); // 9:00 IST
    const a = 'available', x = 'booked';

    test('three points take three cars; a fourth sees Full', () {
      // At 9:00 two points are booked, one is free.
      final grid = SlotGrid.fromJson(gridJson(from, const [], slot: 15, points: [
        [x, x, a, a],
        [x, x, a, a],
        [a, a, a, a],
      ]));
      final cells = grid.stationCells(30);
      expect(cells.first.free, 1);
      expect(cells.first.total, 3);
      expect(cells.first.canBook, isTrue);
      final full = SlotGrid.fromJson(gridJson(from, const [], slot: 15, points: [
        [x, x, a, a],
        [x, x, a, a],
        [x, x, a, a],
      ])).stationCells(30);
      expect(full.first.canBook, isFalse);
      expect(full.first.full, isTrue);
      expect(full[2].free, 3);
    });

    test('a 45-minute and a 30-minute booking need different free runs', () {
      // P1 free 9:00-9:45, P2 free 9:00-9:30 only.
      final grid = SlotGrid.fromJson(gridJson(from, const [], slot: 15, points: [
        [a, a, a, x],
        [a, a, x, x],
      ]));
      expect(grid.stationCells(30).first.free, 2);
      expect(grid.stationCells(45).first.free, 1);
      expect(grid.stationCells(60).first.free, 0);
      // Free to start, just not for an hour: "shorter only", not "Full".
      expect(grid.stationCells(60).first.full, isFalse);
      expect(grid.stationCells(60).first.tooLong, isTrue);
    });

    test('a length that runs past the last cell of the day is "shorter only"', () {
      final grid = SlotGrid.fromJson(gridJson(from, const [], slot: 15, points: [
        [a, a, a, a],
      ]));
      final cells = grid.stationCells(30);
      expect(cells[2].canBook, isTrue);
      expect(cells[3].canBook, isFalse);
      expect(cells[3].tooLong, isTrue);
      expect(cells[3].full, isFalse);
    });

    test('the connector choice narrows the points', () {
      final grid = SlotGrid.fromJson(gridJson(from, const [], slot: 15, connectors: ['ccs2', 'type2_ac'], points: [
        [x, x, a, a],
        [a, a, a, a],
      ]));
      expect(grid.connectorTypes.map((c) => c.wire), containsAll(['ccs2', 'type2_ac']));
      expect(grid.stationCells(30).first.free, 1);
      expect(grid.stationCells(30, connector: 'ccs2').first.canBook, isFalse);
      expect(grid.stationCells(30, connector: 'type2_ac').first.free, 1);
    });
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
      connector: 'ccs2',
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
    expect(back.connector, 'ccs2');
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
