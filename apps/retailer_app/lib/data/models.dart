import 'package:flutter/foundation.dart';
import 'package:shared_models/shared_models.dart';

/// Customer-facing projections returned by the retail RPCs
/// (supabase/migrations/20261022000100_retail_customer.sql). Parsing is
/// lenient: unknown values fall back instead of throwing.

@immutable
class HoursRange {
  const HoursRange(this.day, this.opens, this.closes);
  factory HoursRange.fromJson(Json j) => HoursRange(j.integer('day'), j.integer('opens'), j.integer('closes'));

  /// ISO weekday, 1 = Monday.
  final int day;
  final int opens;
  final int closes;
}

@immutable
class OpenState {
  const OpenState({required this.openNow, this.closesMinute, this.opensNextMinute});
  factory OpenState.fromJson(Json? j) => j == null
      ? const OpenState(openNow: false)
      : OpenState(openNow: j.boolean('open_now'), closesMinute: j.intOrNull('closes_minute'), opensNextMinute: j.intOrNull('opens_next_minute'));

  final bool openNow;
  final int? closesMinute;
  final int? opensNextMinute;
}

@immutable
class PointCounts {
  const PointCounts({required this.total, required this.available, required this.inUse, required this.unavailable, this.telemetry = false, this.updatedAt});
  factory PointCounts.fromJson(Json? j) => j == null
      ? const PointCounts(total: 0, available: 0, inUse: 0, unavailable: 0)
      : PointCounts(
          total: j.integer('total', 0),
          available: j.integer('available', 0),
          inUse: j.integer('in_use', 0),
          unavailable: j.integer('unavailable', 0),
          telemetry: j.strOrNull('status_source') == 'telemetry',
          updatedAt: j.dateTimeOrNull('status_updated_at'),
        );

  final int total;
  final int available;
  final int inUse;
  final int unavailable;

  /// False when statuses are typed in by station staff: they are then shown
  /// as "last reported", never as live.
  final bool telemetry;
  final DateTime? updatedAt;
}

@immutable
class NextSlot {
  const NextSlot(this.startAt, this.pointId, this.pointCode);
  static NextSlot? fromJson(Json? j) {
    if (j == null || j['start_at'] == null) return null;
    return NextSlot(j.dateTime('start_at'), j.str('charging_point_id'), j.strOrNull('charging_point_code') ?? '');
  }

  final DateTime startAt;
  final String pointId;
  final String pointCode;
}

/// Why a station cannot be booked. Null on a station means bookable.
enum UnavailableReason {
  temporarilyClosed('temporarily_closed'),
  notAcceptingBookings('not_accepting_bookings'),
  noBookablePoints('no_bookable_points'),
  unknown('unknown');

  const UnavailableReason(this.wire);
  final String wire;

  static UnavailableReason? parse(String? wire) {
    if (wire == null) return null;
    return values.firstWhere((v) => v.wire == wire, orElse: () => unknown);
  }
}

@immutable
class StationSummary {
  const StationSummary({
    required this.id,
    required this.name,
    required this.addressLine1,
    required this.city,
    required this.latitude,
    required this.longitude,
    required this.bookable,
    required this.points,
    required this.connectorTypes,
    required this.bookingFee,
    required this.open,
    this.operatorName,
    this.addressLine2,
    this.landmark,
    this.district,
    this.state,
    this.postalCode,
    this.distanceKm,
    this.status = StationStatus.active,
    this.closedUntil,
    this.unavailableReason,
    this.amenities = const [],
    this.paymentMethods = const [],
    this.parkingSpaces = 0,
    this.isDemo = false,
    this.currentTypes = const [],
    this.vehicleTypes = const [],
    this.maxPowerKw,
    this.hours = const [],
    this.nextAvailable,
  });

  factory StationSummary.fromJson(Object? json) {
    final j = Json.of(json);
    return StationSummary(
      id: j.str('id'),
      name: j.str('name'),
      operatorName: j.strOrNull('operator_name'),
      addressLine1: j.strOrNull('address_line1') ?? '',
      addressLine2: j.strOrNull('address_line2'),
      landmark: j.strOrNull('landmark'),
      city: j.strOrNull('city') ?? '',
      district: j.strOrNull('district'),
      state: j.strOrNull('state'),
      postalCode: j.strOrNull('postal_code'),
      latitude: j.number('latitude', 0),
      longitude: j.number('longitude', 0),
      distanceKm: j['distance_km'] == null ? null : j.number('distance_km'),
      status: StationStatus.parse(j.strOrNull('status')),
      closedUntil: j.dateTimeOrNull('closed_until'),
      bookable: j.boolean('bookable'),
      unavailableReason: UnavailableReason.parse(j.strOrNull('unavailable_reason')),
      amenities: [for (final a in j.strings('amenities')) ?Amenity.tryParse(a)],
      paymentMethods: [for (final m in j.strings('accepted_payment_methods')) ?StationPaymentMethod.tryParse(m)],
      parkingSpaces: j.integer('parking_spaces', 0),
      isDemo: j.boolean('is_demo'),
      points: PointCounts.fromJson(j.objectOrNull('points')),
      connectorTypes: j.strings('connector_types').map(ConnectorType.parse).toList(),
      currentTypes: j.strings('current_types').map(CurrentType.parse).toList(),
      vehicleTypes: [for (final v in j.strings('vehicle_types')) ?VehicleCategory.tryParse(v)],
      maxPowerKw: j['max_power_kw'] == null ? null : j.number('max_power_kw'),
      hours: j.objects('hours').map(HoursRange.fromJson).toList(),
      open: OpenState.fromJson(j.objectOrNull('open')),
      bookingFee: Money(j.integer('booking_fee_paise', 0)),
      nextAvailable: NextSlot.fromJson(j.objectOrNull('next_available')),
    );
  }

  final String id;
  final String name;
  final String? operatorName;
  final String addressLine1;
  final String? addressLine2;
  final String? landmark;
  final String city;
  final String? district;
  final String? state;
  final String? postalCode;
  final double latitude;
  final double longitude;

  /// Straight-line distance from the search centre. Never driving distance.
  final double? distanceKm;
  final StationStatus status;
  final DateTime? closedUntil;
  final bool bookable;
  final UnavailableReason? unavailableReason;
  final List<Amenity> amenities;
  final List<StationPaymentMethod> paymentMethods;
  final int parkingSpaces;
  final bool isDemo;
  final PointCounts points;
  final List<ConnectorType> connectorTypes;
  final List<CurrentType> currentTypes;
  final List<VehicleCategory> vehicleTypes;
  final double? maxPowerKw;
  final List<HoursRange> hours;
  final OpenState open;
  final Money bookingFee;
  final NextSlot? nextAvailable;

  String get shortAddress => [addressLine1, if (landmark != null && landmark!.isNotEmpty) landmark!, city].join(', ');
  String get fullAddress =>
      [addressLine1, ?addressLine2, ?landmark, city, if (postalCode != null) '${state ?? ''} $postalCode'.trim()].where((s) => s.isNotEmpty).join(', ');

  bool get is24x7 => hours.length == 7 && hours.every((h) => h.opens == 0 && h.closes == 1440);
}

@immutable
class ConnectorInfo {
  const ConnectorInfo(this.number, this.type, this.maxPowerKw);
  factory ConnectorInfo.fromJson(Json j) =>
      ConnectorInfo(j.integer('number', 1), ConnectorType.parse(j.strOrNull('type')), j['max_power_kw'] == null ? null : j.number('max_power_kw'));

  final int number;
  final ConnectorType type;
  final double? maxPowerKw;
}

@immutable
class PointInfo {
  const PointInfo({
    required this.id,
    required this.code,
    required this.currentType,
    required this.maxPowerKw,
    required this.status,
    required this.bookable,
    required this.maxBookingMinutes,
    required this.connectors,
    this.name,
    this.vehicleTypes = const [],
    this.telemetry = false,
    this.statusUpdatedAt,
    this.unavailableReason,
    this.restrictionsNote,
  });

  factory PointInfo.fromJson(Json j) => PointInfo(
        id: j.str('id'),
        code: j.str('code'),
        name: j.strOrNull('name'),
        currentType: CurrentType.parse(j.strOrNull('current_type')),
        maxPowerKw: j.number('max_power_kw', 0),
        vehicleTypes: [for (final v in j.strings('vehicle_compatibility')) ?VehicleCategory.tryParse(v)],
        status: PointStatus.parse(j.strOrNull('operational_status')),
        telemetry: j.strOrNull('status_source') == 'telemetry',
        statusUpdatedAt: j.dateTimeOrNull('status_updated_at'),
        bookable: j.boolean('bookable'),
        unavailableReason: j.strOrNull('unavailable_reason'),
        restrictionsNote: j.strOrNull('restrictions_note'),
        maxBookingMinutes: j.integer('max_booking_minutes', 120),
        connectors: j.objects('connectors').map(ConnectorInfo.fromJson).toList(),
      );

  final String id;
  final String code;
  final String? name;
  final CurrentType currentType;
  final double maxPowerKw;
  final List<VehicleCategory> vehicleTypes;
  final PointStatus status;
  final bool telemetry;
  final DateTime? statusUpdatedAt;
  final bool bookable;
  final String? unavailableReason;
  final String? restrictionsNote;
  final int maxBookingMinutes;
  final List<ConnectorInfo> connectors;

  String get label => name == null || name!.isEmpty ? code : '$code · $name';
}

@immutable
class SlotPolicy {
  const SlotPolicy({
    this.slotMinutes = 30,
    this.minBookingMinutes = 30,
    this.maxBookingMinutes = 120,
    this.minAdvanceMinutes = 15,
    this.maxAdvanceDays = 7,
    this.bufferMinutes = 0,
    this.arrivalGraceMinutes = 15,
    this.earlyCheckinMinutes = 15,
    this.cancelUntilMinutes = 0,
    this.autoNoShow = true,
  });

  factory SlotPolicy.fromJson(Json? j) => j == null
      ? const SlotPolicy()
      : SlotPolicy(
          slotMinutes: j.integer('slot_duration_minutes', 30),
          minBookingMinutes: j.integer('min_booking_minutes', 30),
          maxBookingMinutes: j.integer('max_booking_minutes', 120),
          minAdvanceMinutes: j.integer('min_advance_minutes', 15),
          maxAdvanceDays: j.integer('max_advance_days', 7),
          bufferMinutes: j.integer('buffer_minutes', 0),
          arrivalGraceMinutes: j.integer('arrival_grace_minutes', 15),
          earlyCheckinMinutes: j.integer('early_checkin_minutes', 15),
          cancelUntilMinutes: j.integer('customer_cancel_until_minutes', 0),
          autoNoShow: j.boolean('auto_no_show_enabled', true),
        );

  final int slotMinutes;
  final int minBookingMinutes;
  final int maxBookingMinutes;
  final int minAdvanceMinutes;
  final int maxAdvanceDays;
  final int bufferMinutes;
  final int arrivalGraceMinutes;
  final int earlyCheckinMinutes;
  final int cancelUntilMinutes;
  final bool autoNoShow;
}

@immutable
class RefundPolicy {
  const RefundPolicy({
    required this.customerCancellationRefundable,
    required this.customerCutoffMinutes,
    required this.stationCancellationRefundable,
    required this.lateSlotLostRefundable,
    required this.confirmed,
  });

  factory RefundPolicy.fromJson(Json? j) => j == null
      ? const RefundPolicy(customerCancellationRefundable: false, customerCutoffMinutes: 0, stationCancellationRefundable: true, lateSlotLostRefundable: true, confirmed: false)
      : RefundPolicy(
          customerCancellationRefundable: j.boolean('customer_cancellation_refundable'),
          customerCutoffMinutes: j.integer('customer_cancellation_cutoff_minutes', 0),
          stationCancellationRefundable: j.boolean('business_cancellation_refundable', true),
          lateSlotLostRefundable: j.boolean('late_payment_slot_lost_refundable', true),
          confirmed: j.boolean('policy_confirmed'),
        );

  final bool customerCancellationRefundable;
  final int customerCutoffMinutes;
  final bool stationCancellationRefundable;
  final bool lateSlotLostRefundable;

  /// False while the platform owner has not confirmed the policy for production.
  final bool confirmed;
}

@immutable
class Closure {
  const Closure(this.startsAt, this.endsAt, this.kind);
  factory Closure.fromJson(Json j) => Closure(j.dateTime('starts_at'), j.dateTime('ends_at'), BlockedPeriodKind.parse(j.strOrNull('kind')));
  final DateTime startsAt;
  final DateTime endsAt;
  final BlockedPeriodKind kind;
}

@immutable
class StationDetail {
  const StationDetail({
    required this.summary,
    required this.isPublic,
    required this.points,
    required this.policy,
    required this.refundPolicy,
    required this.holdMinutes,
    this.description,
    this.contactPhone,
    this.closures = const [],
  });

  factory StationDetail.fromJson(Object? json) {
    final j = Json.of(json);
    final isPublic = j.boolean('public', true);
    return StationDetail(
      summary: isPublic
          ? StationSummary.fromJson(json)
          : StationSummary(
              id: j.str('id'),
              name: j.strOrNull('name') ?? '',
              addressLine1: '',
              city: '',
              latitude: 0,
              longitude: 0,
              bookable: false,
              unavailableReason: UnavailableReason.notAcceptingBookings,
              points: const PointCounts(total: 0, available: 0, inUse: 0, unavailable: 0),
              connectorTypes: const [],
              bookingFee: const Money.zero(),
              open: const OpenState(openNow: false),
            ),
      isPublic: isPublic,
      description: j.strOrNull('description'),
      contactPhone: j.strOrNull('contact_phone'),
      points: j.objects('points_detail').map(PointInfo.fromJson).toList(),
      policy: SlotPolicy.fromJson(j.objectOrNull('policy')),
      closures: j.objects('closures').map(Closure.fromJson).toList(),
      refundPolicy: RefundPolicy.fromJson(j.objectOrNull('refund_policy')),
      holdMinutes: j.integer('payment_hold_minutes', 10),
    );
  }

  final StationSummary summary;
  final bool isPublic;
  final String? description;
  final String? contactPhone;
  final List<PointInfo> points;
  final SlotPolicy policy;
  final List<Closure> closures;
  final RefundPolicy refundPolicy;
  final int holdMinutes;
}

enum SlotState {
  available,
  booked,
  reserved,
  blocked,
  closed,
  unavailable,
  past,
  tooSoon,
  tooFar;

  static SlotState parse(String? wire) => switch (wire) {
        'available' => available,
        'booked' => booked,
        'reserved' => reserved,
        'blocked' => blocked,
        'closed' => closed,
        'past' => past,
        'too_soon' => tooSoon,
        'too_far' => tooFar,
        _ => unavailable,
      };
}

@immutable
class SlotCell {
  const SlotCell(this.start, this.end, this.state, this.canStart);
  factory SlotCell.fromJson(Json j) =>
      SlotCell(j.dateTime('start_at'), j.dateTime('end_at'), SlotState.parse(j.strOrNull('state')), j.boolean('can_start'));

  final DateTime start;
  final DateTime end;
  final SlotState state;
  final bool canStart;
}

@immutable
class PointSlots {
  const PointSlots(this.point, this.cells);
  final PointInfo point;
  final List<SlotCell> cells;

  /// Whether [minutes] starting at [start] is free in this grid. The server
  /// re-checks; this only stops obviously invalid choices.
  bool fits(DateTime start, int minutes, int slotMinutes) {
    final i = cells.indexWhere((c) => c.start == start);
    if (i < 0 || !cells[i].canStart) return false;
    final needed = minutes ~/ slotMinutes;
    if (i + needed > cells.length) return false;
    for (var k = i; k < i + needed; k++) {
      if (cells[k].state != SlotState.available) return false;
      if (k > i && cells[k].start != cells[k - 1].end) return false;
    }
    return true;
  }
}

@immutable
class SlotGrid {
  const SlotGrid({
    required this.stationId,
    required this.date,
    required this.slotMinutes,
    required this.minBookingMinutes,
    required this.bufferMinutes,
    required this.bookingFee,
    required this.generatedAt,
    required this.points,
    this.unavailableReason,
  });

  factory SlotGrid.fromJson(Object? json) {
    final j = Json.of(json);
    return SlotGrid(
      stationId: j.str('station_id'),
      date: j.dateOrNull('date') ?? DateTime.now(),
      slotMinutes: j.integer('slot_minutes', 30),
      minBookingMinutes: j.integer('min_booking_minutes', 30),
      bufferMinutes: j.integer('buffer_minutes', 0),
      bookingFee: Money(j.integer('booking_fee_paise', 0)),
      generatedAt: j.dateTimeOrNull('generated_at') ?? DateTime.now().toUtc(),
      unavailableReason: UnavailableReason.parse(j.strOrNull('unavailable_reason')),
      points: [for (final p in j.objects('points')) PointSlots(PointInfo.fromJson(p), p.objects('cells').map(SlotCell.fromJson).toList())],
    );
  }

  final String stationId;
  final DateTime date;
  final int slotMinutes;
  final int minBookingMinutes;
  final int bufferMinutes;
  final Money bookingFee;
  final DateTime generatedAt;
  final List<PointSlots> points;
  final UnavailableReason? unavailableReason;

  bool get hasAnyStart => points.any((p) => p.cells.any((c) => c.canStart));
}

@immutable
class SearchResult {
  const SearchResult({required this.inServiceArea, required this.radiusKm, required this.stations, required this.generatedAt});
  factory SearchResult.fromJson(Object? json) {
    final j = Json.of(json);
    return SearchResult(
      inServiceArea: j.boolean('in_service_area', true),
      radiusKm: j.number('radius_km', 5),
      stations: (j['stations'] as List? ?? const []).map(StationSummary.fromJson).toList(),
      generatedAt: j.dateTimeOrNull('generated_at') ?? DateTime.now().toUtc(),
    );
  }

  final bool inServiceArea;
  final double radiusKm;
  final List<StationSummary> stations;
  final DateTime generatedAt;
}

@immutable
class AreaMatch {
  const AreaMatch({required this.label, required this.secondary, required this.latitude, required this.longitude, this.stationCount, this.fromProvider = false});
  factory AreaMatch.fromJson(Json j) => AreaMatch(
        label: j.strOrNull('label') ?? '',
        secondary: j.strOrNull('secondary') ?? '',
        latitude: j.number('latitude', 0),
        longitude: j.number('longitude', 0),
        stationCount: j.intOrNull('station_count'),
        fromProvider: j.strOrNull('source') == 'google',
      );

  final String label;
  final String secondary;
  final double latitude;
  final double longitude;
  final int? stationCount;
  final bool fromProvider;
}

@immutable
class AreaSearchOutcome {
  const AreaSearchOutcome(this.matches, {required this.providerAvailable});
  final List<AreaMatch> matches;

  /// False when the map-provider search is not configured or failed; results
  /// then come only from localities that have stations.
  final bool providerAvailable;
}

@immutable
class AppStatus {
  const AppStatus({this.minBuild, this.maintenance = false, this.message});
  factory AppStatus.fromJson(Json? j) =>
      j == null ? const AppStatus() : AppStatus(minBuild: j.intOrNull('min_build'), maintenance: j.boolean('maintenance'), message: j.strOrNull('message'));
  final int? minBuild;
  final bool maintenance;
  final String? message;
}

@immutable
class BookingTerms {
  const BookingTerms({required this.fee, required this.holdMinutes, required this.refundPolicy, required this.termsVersion, this.appStatus = const AppStatus()});
  factory BookingTerms.fromJson(Object? json) {
    final j = Json.of(json);
    return BookingTerms(
      fee: Money(j.integer('booking_fee_paise', 0)),
      holdMinutes: j.integer('payment_hold_minutes', 10),
      refundPolicy: RefundPolicy.fromJson(j.objectOrNull('refund_policy')),
      termsVersion: j.strOrNull('terms_version') ?? 'unknown',
      appStatus: AppStatus.fromJson(j['app_status'] is Map ? j.objectOrNull('app_status') : null),
    );
  }

  final Money fee;
  final int holdMinutes;
  final RefundPolicy refundPolicy;
  final String termsVersion;
  final AppStatus appStatus;
}

@immutable
class SlotCheck {
  const SlotCheck({required this.available, required this.fee, this.reason});
  factory SlotCheck.fromJson(Object? json) {
    final j = Json.of(json);
    return SlotCheck(available: j.boolean('available'), reason: j.strOrNull('reason'), fee: Money(j.integer('booking_fee_paise', 0)));
  }
  final bool available;
  final String? reason;
  final Money fee;
}

// ---------------------------------------------------------------------------
// Customer bookings
// ---------------------------------------------------------------------------

@immutable
class PaymentInfo {
  const PaymentInfo({required this.status, this.reference, this.method, this.amount, this.capturedAt, this.failedAt, this.error});
  factory PaymentInfo.fromJson(Json j) => PaymentInfo(
        status: GatewayPaymentStatus.parse(j.strOrNull('status')),
        reference: j.strOrNull('reference'),
        method: j.strOrNull('method'),
        amount: j['amount_paise'] == null ? null : Money(j.integer('amount_paise')),
        capturedAt: j.dateTimeOrNull('captured_at'),
        failedAt: j.dateTimeOrNull('failed_at'),
        error: j.strOrNull('error'),
      );
  final GatewayPaymentStatus status;
  final String? reference;
  final String? method;
  final Money? amount;
  final DateTime? capturedAt;
  final DateTime? failedAt;
  final String? error;
}

@immutable
class RefundInfo {
  const RefundInfo({required this.status, required this.amount, required this.createdAt, this.reference, this.processedAt});
  factory RefundInfo.fromJson(Json j) => RefundInfo(
        status: RefundStatus.parse(j.strOrNull('status')),
        amount: Money(j.integer('amount_paise', 0)),
        reference: j.strOrNull('reference'),
        createdAt: j.dateTime('created_at'),
        processedAt: j.dateTimeOrNull('processed_at'),
      );
  final RefundStatus status;
  final Money amount;
  final String? reference;
  final DateTime createdAt;
  final DateTime? processedAt;
}

enum MessageDelivery { pending, sent, failed, skipped }

@immutable
class MessageInfo {
  const MessageInfo(this.channel, this.template, this.status, this.updatedAt);
  factory MessageInfo.fromJson(Json j) => MessageInfo(
        j.strOrNull('channel') ?? 'sms',
        j.strOrNull('template') ?? '',
        switch (j.strOrNull('status')) {
          'sent' => MessageDelivery.sent,
          'failed' => MessageDelivery.failed,
          'skipped' => MessageDelivery.skipped,
          _ => MessageDelivery.pending,
        },
        j.dateTimeOrNull('updated_at'),
      );
  final String channel;
  final String template;
  final MessageDelivery status;
  final DateTime? updatedAt;
}

@immutable
class TimelineEvent {
  const TimelineEvent(this.status, this.paymentStatus, this.actor, this.at);
  factory TimelineEvent.fromJson(Json j) => TimelineEvent(
        BookingStatus.parse(j.strOrNull('status')),
        BookingPaymentStatus.parse(j.strOrNull('payment_status')),
        ActorKind.parse(j.strOrNull('actor')),
        j.dateTime('at'),
      );
  final BookingStatus status;
  final BookingPaymentStatus paymentStatus;
  final ActorKind actor;
  final DateTime at;
}

/// What the customer should understand about a booking right now. Derived
/// only from server state; never from the app having returned from checkout.
enum CustomerPhase {
  pendingPayment,
  paymentProcessing,
  paymentFailed,
  confirmed,
  checkedIn,
  completed,
  cancelled,
  refundPending,
  refunded,
  expired,
  paidSlotLost,
  missed,
}

@immutable
class CustomerBooking {
  const CustomerBooking({
    required this.id,
    required this.reference,
    required this.stationId,
    required this.startAt,
    required this.endAt,
    required this.status,
    required this.paymentStatus,
    required this.fee,
    required this.stationName,
    required this.stationAddress,
    required this.latitude,
    required this.longitude,
    required this.pointCode,
    required this.policy,
    this.holdExpiresAt,
    this.createdAt,
    this.confirmedAt,
    this.cancelledAt,
    this.cancellationActor,
    this.cancellationReason,
    this.refundEligible,
    this.checkedInAt,
    this.completedAt,
    this.noShowAt,
    this.stationPhone,
    this.stationStatus,
    this.pointName,
    this.pointPowerKw,
    this.connectors = const [],
    this.customerName,
    this.payment,
    this.hasOpenOrder = false,
    this.refunds = const [],
    this.messages = const [],
    this.events = const [],
  });

  factory CustomerBooking.fromJson(Object? json) {
    final j = Json.of(json);
    final s = j.objectOrNull('station') ?? Json(const {});
    final p = j.objectOrNull('point') ?? Json(const {});
    final addr = [s.strOrNull('address_line1'), s.strOrNull('address_line2'), s.strOrNull('landmark'), s.strOrNull('city'), s.strOrNull('postal_code')]
        .whereType<String>()
        .where((x) => x.isNotEmpty)
        .join(', ');
    return CustomerBooking(
      id: j.str('id'),
      reference: j.str('reference'),
      stationId: j.str('station_id'),
      startAt: j.dateTime('start_at'),
      endAt: j.dateTime('end_at'),
      status: BookingStatus.parse(j.strOrNull('status')),
      paymentStatus: BookingPaymentStatus.parse(j.strOrNull('payment_status')),
      fee: Money(j.integer('booking_fee_paise', 0)),
      holdExpiresAt: j.dateTimeOrNull('hold_expires_at'),
      createdAt: j.dateTimeOrNull('created_at'),
      confirmedAt: j.dateTimeOrNull('confirmed_at'),
      cancelledAt: j.dateTimeOrNull('cancelled_at'),
      cancellationActor: j['cancellation_actor'] == null ? null : ActorKind.parse(j.strOrNull('cancellation_actor')),
      cancellationReason: j.strOrNull('cancellation_reason'),
      refundEligible: j.boolOrNull('refund_eligible'),
      checkedInAt: j.dateTimeOrNull('checked_in_at'),
      completedAt: j.dateTimeOrNull('completed_at'),
      noShowAt: j.dateTimeOrNull('no_show_at'),
      customerName: j.strOrNull('customer_display_name'),
      stationName: s.strOrNull('name') ?? '',
      stationAddress: addr,
      latitude: s.number('latitude', 0),
      longitude: s.number('longitude', 0),
      stationPhone: s.strOrNull('contact_phone'),
      stationStatus: s['status'] == null ? null : StationStatus.parse(s.strOrNull('status')),
      pointCode: p.strOrNull('code') ?? '',
      pointName: p.strOrNull('name'),
      pointPowerKw: p['max_power_kw'] == null ? null : p.number('max_power_kw'),
      connectors: p.strings('connectors').map(ConnectorType.parse).toList(),
      policy: SlotPolicy.fromJson(j.objectOrNull('policy')),
      payment: j['payment'] is Map ? PaymentInfo.fromJson(j.objectOrNull('payment')!) : null,
      hasOpenOrder: j.boolean('has_open_order'),
      refunds: j.objects('refunds').map(RefundInfo.fromJson).toList(),
      messages: j.objects('messages').map(MessageInfo.fromJson).toList(),
      events: j.objects('events').map(TimelineEvent.fromJson).toList(),
    );
  }

  final String id;
  final String reference;
  final String stationId;
  final DateTime startAt;
  final DateTime endAt;
  final BookingStatus status;
  final BookingPaymentStatus paymentStatus;
  final Money fee;
  final DateTime? holdExpiresAt;
  final DateTime? createdAt;
  final DateTime? confirmedAt;
  final DateTime? cancelledAt;
  final ActorKind? cancellationActor;
  final String? cancellationReason;
  final bool? refundEligible;
  final DateTime? checkedInAt;
  final DateTime? completedAt;
  final DateTime? noShowAt;
  final String? customerName;
  final String stationName;
  final String stationAddress;
  final double latitude;
  final double longitude;
  final String? stationPhone;
  final StationStatus? stationStatus;
  final String pointCode;
  final String? pointName;
  final double? pointPowerKw;
  final List<ConnectorType> connectors;
  final SlotPolicy policy;
  final PaymentInfo? payment;
  final bool hasOpenOrder;
  final List<RefundInfo> refunds;
  final List<MessageInfo> messages;
  final List<TimelineEvent> events;

  Duration get duration => endAt.difference(startAt);

  CustomerPhase phaseAt(DateTime now) {
    switch (status) {
      case BookingStatus.paymentPending:
        if (payment?.status == GatewayPaymentStatus.authorized) return CustomerPhase.paymentProcessing;
        if (paymentStatus == BookingPaymentStatus.failed) return CustomerPhase.paymentFailed;
        return CustomerPhase.pendingPayment;
      case BookingStatus.confirmed:
        return CustomerPhase.confirmed;
      case BookingStatus.arrived:
      case BookingStatus.inProgress:
        return CustomerPhase.checkedIn;
      case BookingStatus.completed:
        return CustomerPhase.completed;
      case BookingStatus.noShow:
        return CustomerPhase.missed;
      case BookingStatus.cancelled:
      case BookingStatus.expired:
        if (paymentStatus == BookingPaymentStatus.refundPending || refunds.any((r) => r.status != RefundStatus.processed)) {
          return CustomerPhase.refundPending;
        }
        if (paymentStatus == BookingPaymentStatus.refunded) return CustomerPhase.refunded;
        if (paymentStatus == BookingPaymentStatus.paid) {
          // Paid but no longer holding a slot: either kept under the policy
          // (customer cancellation) or a late payment after the hold ended.
          return status == BookingStatus.expired || cancellationActor == null ? CustomerPhase.paidSlotLost : CustomerPhase.cancelled;
        }
        return status == BookingStatus.expired ? CustomerPhase.expired : CustomerPhase.cancelled;
    }
  }

  bool isUpcomingAt(DateTime now) => endAt.isAfter(now) && (status == BookingStatus.confirmed || status == BookingStatus.paymentPending);

  /// Arrival window [start − early, start + grace] from the station policy.
  DateTime get arrivalOpensAt => startAt.subtract(Duration(minutes: policy.earlyCheckinMinutes));
  DateTime get arrivalClosesAt => startAt.add(Duration(minutes: policy.arrivalGraceMinutes));
}

@immutable
class CancellationPreview {
  const CancellationPreview({
    required this.allowed,
    required this.refundEligible,
    required this.refundAmount,
    required this.policyConfirmed,
    this.reason,
    this.paymentInProgress = false,
    this.cancelUntil,
    this.refundUntil,
  });

  factory CancellationPreview.fromJson(Object? json) {
    final j = Json.of(json);
    return CancellationPreview(
      allowed: j.boolean('allowed'),
      reason: j.strOrNull('reason'),
      refundEligible: j.boolean('refund_eligible'),
      refundAmount: Money(j.integer('refund_amount_paise', 0)),
      policyConfirmed: j.boolean('policy_confirmed'),
      paymentInProgress: j.boolean('payment_in_progress'),
      cancelUntil: j.dateTimeOrNull('cancel_until'),
      refundUntil: j.dateTimeOrNull('refund_until'),
    );
  }

  final bool allowed;
  final String? reason;
  final bool refundEligible;
  final Money refundAmount;
  final bool policyConfirmed;
  final bool paymentInProgress;
  final DateTime? cancelUntil;
  final DateTime? refundUntil;
}

@immutable
class OrderInfo {
  const OrderInfo({required this.orderId, required this.keyId, required this.amount, required this.bookingId, this.holdExpiresAt});
  factory OrderInfo.fromJson(Object? json) {
    final j = Json.of(json);
    return OrderInfo(
      orderId: j.str('order_id'),
      keyId: j.str('key_id'),
      amount: Money(j.integer('amount_paise')),
      bookingId: j.str('booking_id'),
      holdExpiresAt: j.dateTimeOrNull('hold_expires_at'),
    );
  }
  final String orderId;
  final String keyId;
  final Money amount;
  final String bookingId;
  final DateTime? holdExpiresAt;
}

@immutable
class CustomerProfile {
  const CustomerProfile({required this.id, this.fullName, this.phone, this.email, this.receiptEmail, this.prefs = const {}, this.locale});
  factory CustomerProfile.fromJson(Object? json) {
    final j = Json.of(json);
    final prefs = j['notification_prefs'];
    return CustomerProfile(
      id: j.str('id'),
      fullName: j.strOrNull('full_name'),
      phone: j.strOrNull('phone'),
      email: j.strOrNull('email'),
      receiptEmail: j.strOrNull('receipt_email'),
      prefs: prefs is Map ? prefs.map((k, v) => MapEntry(k.toString(), v == true)) : const {},
      locale: j.strOrNull('locale'),
    );
  }
  final String id;
  final String? fullName;
  final String? phone;
  final String? email;
  final String? receiptEmail;
  final Map<String, bool> prefs;
  final String? locale;

  String? get contactEmail => receiptEmail ?? email;
  bool pref(String key) => prefs[key] ?? true;
}

@immutable
class DeletionCheck {
  const DeletionCheck({required this.activeBookings, required this.pendingRefunds, required this.hasRole, this.pendingRequestAt});
  factory DeletionCheck.fromJson(Object? json) {
    final j = Json.of(json);
    final req = j['pending_request'];
    return DeletionCheck(
      activeBookings: j.integer('active_bookings', 0),
      pendingRefunds: j.integer('pending_refunds', 0),
      hasRole: j.boolean('is_business_member') || j.boolean('is_platform_staff'),
      pendingRequestAt: req is Map ? Json.of(req).dateTimeOrNull('created_at') : null,
    );
  }
  final int activeBookings;
  final int pendingRefunds;
  final bool hasRole;
  final DateTime? pendingRequestAt;

  bool get blocked => activeBookings > 0 || pendingRefunds > 0 || hasRole;
}

/// Masks a phone for display: +91 98•••••210.
String maskPhone(String? phone) {
  if (phone == null || phone.length < 6) return phone ?? '';
  final p = phone.startsWith('+91') && phone.length == 13 ? phone.substring(3) : phone;
  final prefix = phone.startsWith('+91') && phone.length == 13 ? '+91 ' : '';
  return '$prefix${p.substring(0, 2)}${'•' * (p.length - 5)}${p.substring(p.length - 3)}';
}

/// Masks an email for display: ra•••@example.com.
String maskEmail(String? email) {
  if (email == null || !email.contains('@')) return email ?? '';
  final at = email.indexOf('@');
  final name = email.substring(0, at);
  final shown = name.length <= 2 ? name.substring(0, 1) : name.substring(0, 2);
  return '$shown•••${email.substring(at)}';
}
