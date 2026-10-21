import 'package:meta/meta.dart';

import 'enums.dart';
import 'json.dart';

@immutable
class Business {
  const Business({
    required this.id,
    required this.ownerId,
    required this.legalName,
    required this.ownerFullName,
    required this.contactPhone,
    required this.contactEmail,
    required this.businessType,
    required this.status,
    required this.isDemo,
    required this.createdAt,
    this.displayName,
    this.registrationNumber,
    this.gstin,
    this.registeredAddressLine1,
    this.registeredAddressLine2,
    this.registeredCity,
    this.registeredState,
    this.registeredPostalCode,
    this.statusReason,
  });

  factory Business.fromJson(Object? json) {
    final j = Json.of(json);
    return Business(
      id: j.str('id'),
      ownerId: j.str('owner_id'),
      legalName: j.str('legal_name'),
      displayName: j.strOrNull('display_name'),
      ownerFullName: j.str('owner_full_name'),
      contactPhone: j.str('contact_phone'),
      contactEmail: j.str('contact_email'),
      businessType: BusinessType.parse(j.strOrNull('business_type')),
      registrationNumber: j.strOrNull('registration_number'),
      gstin: j.strOrNull('gstin'),
      registeredAddressLine1: j.strOrNull('registered_address_line1'),
      registeredAddressLine2: j.strOrNull('registered_address_line2'),
      registeredCity: j.strOrNull('registered_city'),
      registeredState: j.strOrNull('registered_state'),
      registeredPostalCode: j.strOrNull('registered_postal_code'),
      status: BusinessStatus.parse(j.strOrNull('status')),
      statusReason: j.strOrNull('status_reason'),
      isDemo: j.boolean('is_demo'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final String id;
  final String ownerId;
  final String legalName;
  final String? displayName;
  final String ownerFullName;
  final String contactPhone;
  final String contactEmail;
  final BusinessType businessType;
  final String? registrationNumber;
  final String? gstin;
  final String? registeredAddressLine1;
  final String? registeredAddressLine2;
  final String? registeredCity;
  final String? registeredState;
  final String? registeredPostalCode;
  final BusinessStatus status;
  final String? statusReason;
  final bool isDemo;
  final DateTime createdAt;

  String get name => displayName ?? legalName;
}

@immutable
class Station {
  const Station({
    required this.id,
    required this.businessId,
    required this.name,
    required this.addressLine1,
    required this.city,
    required this.district,
    required this.state,
    required this.postalCode,
    required this.latitude,
    required this.longitude,
    required this.timezone,
    required this.contactPhone,
    required this.parkingSpaces,
    required this.amenities,
    required this.acceptedPaymentMethods,
    required this.status,
    required this.createdAt,
    this.description,
    this.logoPath,
    this.addressLine2,
    this.landmark,
    this.emergencyContactName,
    this.emergencyContactPhone,
    this.statusReason,
    this.approvedAt,
    this.closedUntil,
    this.deactivationRequestedAt,
  });

  factory Station.fromJson(Object? json) {
    final j = Json.of(json);
    return Station(
      id: j.str('id'),
      businessId: j.str('business_id'),
      name: j.str('name'),
      description: j.strOrNull('description'),
      logoPath: j.strOrNull('logo_path'),
      addressLine1: j.str('address_line1'),
      addressLine2: j.strOrNull('address_line2'),
      landmark: j.strOrNull('landmark'),
      city: j.str('city'),
      district: j.str('district'),
      state: j.str('state'),
      postalCode: j.str('postal_code'),
      latitude: j.number('latitude'),
      longitude: j.number('longitude'),
      timezone: j.strOrNull('timezone') ?? 'Asia/Kolkata',
      contactPhone: j.str('contact_phone'),
      emergencyContactName: j.strOrNull('emergency_contact_name'),
      emergencyContactPhone: j.strOrNull('emergency_contact_phone'),
      parkingSpaces: j.integer('parking_spaces', 0),
      amenities: j.strings('amenities').map(Amenity.tryParse).whereType<Amenity>().toSet(),
      acceptedPaymentMethods:
          j.strings('accepted_payment_methods').map(StationPaymentMethod.tryParse).whereType<StationPaymentMethod>().toSet(),
      status: StationStatus.parse(j.strOrNull('status')),
      statusReason: j.strOrNull('status_reason'),
      approvedAt: j.dateTimeOrNull('approved_at'),
      closedUntil: j.dateTimeOrNull('closed_until'),
      deactivationRequestedAt: j.dateTimeOrNull('deactivation_requested_at'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final String id;
  final String businessId;
  final String name;
  final String? description;
  final String? logoPath;
  final String addressLine1;
  final String? addressLine2;
  final String? landmark;
  final String city;
  final String district;
  final String state;
  final String postalCode;
  final double latitude;
  final double longitude;
  final String timezone;
  final String contactPhone;
  final String? emergencyContactName;
  final String? emergencyContactPhone;
  final int parkingSpaces;
  final Set<Amenity> amenities;
  final Set<StationPaymentMethod> acceptedPaymentMethods;
  final StationStatus status;
  final String? statusReason;
  final DateTime? approvedAt;
  final DateTime? closedUntil;
  final DateTime? deactivationRequestedAt;
  final DateTime createdAt;

  /// Approved stations need an admin-approved change request for these.
  static const sensitiveFields = {
    'name', 'address_line1', 'address_line2', 'landmark', 'city', 'district', 'state', 'postal_code',
    'country_code', 'latitude', 'longitude', 'timezone',
  };

  bool get isApproved => approvedAt != null;

  String get fullAddress => [addressLine1, addressLine2, landmark, city, district, '$state $postalCode']
      .whereType<String>()
      .where((s) => s.trim().isNotEmpty)
      .join(', ');

  /// A universal Google Maps link that opens the installed maps app.
  Uri get mapsUri => Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': '$latitude,$longitude'});

  Uri get directionsUri =>
      Uri.https('www.google.com', '/maps/dir/', {'api': '1', 'destination': '$latitude,$longitude'});
}

@immutable
class Connector {
  const Connector({required this.id, required this.number, required this.type, this.maxPowerKw});

  factory Connector.fromJson(Object? json) {
    final j = Json.of(json);
    return Connector(
      id: j.str('id'),
      number: j.integer('connector_number'),
      type: ConnectorType.parse(j.strOrNull('connector_type')),
      maxPowerKw: j['max_power_kw'] == null ? null : j.number('max_power_kw'),
    );
  }

  final String id;
  final int number;
  final ConnectorType type;
  final double? maxPowerKw;
}

@immutable
class ChargingPoint {
  const ChargingPoint({
    required this.id,
    required this.stationId,
    required this.code,
    required this.currentType,
    required this.maxPowerKw,
    required this.vehicleCompatibility,
    required this.operationalStatus,
    required this.statusSource,
    required this.statusUpdatedAt,
    required this.telemetryCapability,
    required this.bookingEnabled,
    this.name,
    this.statusNote,
    this.ocppChargePointId,
    this.maxBookingMinutesOverride,
    this.restrictionsNote,
    this.connectors = const [],
    this.archivedAt,
  });

  factory ChargingPoint.fromJson(Object? json) {
    final j = Json.of(json);
    return ChargingPoint(
      id: j.str('id'),
      stationId: j.str('station_id'),
      code: j.str('code'),
      name: j.strOrNull('name'),
      currentType: CurrentType.parse(j.strOrNull('current_type')),
      maxPowerKw: j.number('max_power_kw'),
      vehicleCompatibility:
          j.strings('vehicle_compatibility').map(VehicleCategory.tryParse).whereType<VehicleCategory>().toSet(),
      operationalStatus: PointStatus.parse(j.strOrNull('operational_status')),
      statusSource: StatusSource.parse(j.strOrNull('status_source')),
      statusNote: j.strOrNull('status_note'),
      statusUpdatedAt: j.dateTime('status_updated_at'),
      telemetryCapability: TelemetryCapability.parse(j.strOrNull('telemetry_capability')),
      ocppChargePointId: j.strOrNull('ocpp_charge_point_id'),
      bookingEnabled: j.boolean('booking_enabled', true),
      maxBookingMinutesOverride: j.intOrNull('max_booking_minutes_override'),
      restrictionsNote: j.strOrNull('restrictions_note'),
      connectors: j.objects('charging_connectors').map(Connector.fromJson).toList()
        ..sort((a, b) => a.number.compareTo(b.number)),
      archivedAt: j.dateTimeOrNull('archived_at'),
    );
  }

  final String id;
  final String stationId;
  final String code;
  final String? name;
  final CurrentType currentType;
  final double maxPowerKw;
  final Set<VehicleCategory> vehicleCompatibility;
  final PointStatus operationalStatus;
  final StatusSource statusSource;
  final String? statusNote;
  final DateTime statusUpdatedAt;
  final TelemetryCapability telemetryCapability;
  final String? ocppChargePointId;
  final bool bookingEnabled;
  final int? maxBookingMinutesOverride;
  final String? restrictionsNote;
  final List<Connector> connectors;
  final DateTime? archivedAt;

  String get displayName => name == null || name!.isEmpty ? code : '$code · $name';
}

/// A weekly opening interval in station-local minutes (0–1440).
@immutable
class OperatingHours {
  const OperatingHours({
    required this.dayOfWeek,
    required this.opensMinute,
    required this.closesMinute,
    this.id,
    this.chargingPointId,
  });

  factory OperatingHours.fromJson(Object? json) {
    final j = Json.of(json);
    return OperatingHours(
      id: j.strOrNull('id'),
      chargingPointId: j.strOrNull('charging_point_id'),
      dayOfWeek: j.integer('day_of_week'),
      opensMinute: j.integer('opens_minute'),
      closesMinute: j.integer('closes_minute'),
    );
  }

  final String? id;
  final String? chargingPointId;

  /// ISO day of week: 1 = Monday … 7 = Sunday.
  final int dayOfWeek;
  final int opensMinute;
  final int closesMinute;

  static const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String get dayName => dayNames[dayOfWeek - 1];

  static String formatMinute(int minute) {
    final h = (minute ~/ 60).toString().padLeft(2, '0');
    final m = (minute % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  String get label => '${formatMinute(opensMinute)}–${formatMinute(closesMinute)}';

  bool overlaps(OperatingHours other) =>
      dayOfWeek == other.dayOfWeek && opensMinute < other.closesMinute && other.opensMinute < closesMinute;

  Map<String, Object?> toInsert(String stationId) => {
        'station_id': stationId,
        'charging_point_id': chargingPointId,
        'day_of_week': dayOfWeek,
        'opens_minute': opensMinute,
        'closes_minute': closesMinute,
      };
}

@immutable
class BookingPolicy {
  const BookingPolicy({
    required this.stationId,
    required this.slotDurationMinutes,
    required this.minBookingMinutes,
    required this.maxBookingMinutes,
    required this.minAdvanceMinutes,
    required this.maxAdvanceDays,
    required this.bufferMinutes,
    required this.arrivalGraceMinutes,
    required this.earlyCheckinMinutes,
    required this.customerCancelUntilMinutes,
    required this.autoNoShowEnabled,
  });

  factory BookingPolicy.fromJson(Object? json) {
    final j = Json.of(json);
    return BookingPolicy(
      stationId: j.str('station_id'),
      slotDurationMinutes: j.integer('slot_duration_minutes'),
      minBookingMinutes: j.integer('min_booking_minutes'),
      maxBookingMinutes: j.integer('max_booking_minutes'),
      minAdvanceMinutes: j.integer('min_advance_minutes'),
      maxAdvanceDays: j.integer('max_advance_days'),
      bufferMinutes: j.integer('buffer_minutes'),
      arrivalGraceMinutes: j.integer('arrival_grace_minutes'),
      earlyCheckinMinutes: j.integer('early_checkin_minutes'),
      customerCancelUntilMinutes: j.integer('customer_cancel_until_minutes'),
      autoNoShowEnabled: j.boolean('auto_no_show_enabled', true),
    );
  }

  final String stationId;
  final int slotDurationMinutes;
  final int minBookingMinutes;
  final int maxBookingMinutes;
  final int minAdvanceMinutes;
  final int maxAdvanceDays;
  final int bufferMinutes;
  final int arrivalGraceMinutes;
  final int earlyCheckinMinutes;
  final int customerCancelUntilMinutes;
  final bool autoNoShowEnabled;

  /// Client-side pre-check mirroring the database constraints, so the form
  /// can explain problems before submitting. The database still decides.
  List<String> validate() {
    final errors = <String>[];
    if (slotDurationMinutes < 5 || slotDurationMinutes > 240) errors.add('Slot length must be 5–240 minutes.');
    if (maxBookingMinutes < minBookingMinutes) errors.add('Maximum booking must be at least the minimum.');
    if (slotDurationMinutes > 0 && minBookingMinutes % slotDurationMinutes != 0) {
      errors.add('Minimum booking must be a multiple of the slot length.');
    }
    if (slotDurationMinutes > 0 && maxBookingMinutes % slotDurationMinutes != 0) {
      errors.add('Maximum booking must be a multiple of the slot length.');
    }
    if (maxAdvanceDays < 1 || maxAdvanceDays > 90) errors.add('Advance window must be 1–90 days.');
    if (bufferMinutes < 0 || bufferMinutes > 120) errors.add('Buffer must be 0–120 minutes.');
    if (arrivalGraceMinutes < 0 || arrivalGraceMinutes > 120) errors.add('Grace period must be 0–120 minutes.');
    return errors;
  }

  Map<String, Object?> toUpdate() => {
        'slot_duration_minutes': slotDurationMinutes,
        'min_booking_minutes': minBookingMinutes,
        'max_booking_minutes': maxBookingMinutes,
        'min_advance_minutes': minAdvanceMinutes,
        'max_advance_days': maxAdvanceDays,
        'buffer_minutes': bufferMinutes,
        'arrival_grace_minutes': arrivalGraceMinutes,
        'early_checkin_minutes': earlyCheckinMinutes,
        'customer_cancel_until_minutes': customerCancelUntilMinutes,
        'auto_no_show_enabled': autoNoShowEnabled,
      };

  BookingPolicy copyWith({
    int? slotDurationMinutes,
    int? minBookingMinutes,
    int? maxBookingMinutes,
    int? minAdvanceMinutes,
    int? maxAdvanceDays,
    int? bufferMinutes,
    int? arrivalGraceMinutes,
    int? earlyCheckinMinutes,
    int? customerCancelUntilMinutes,
    bool? autoNoShowEnabled,
  }) =>
      BookingPolicy(
        stationId: stationId,
        slotDurationMinutes: slotDurationMinutes ?? this.slotDurationMinutes,
        minBookingMinutes: minBookingMinutes ?? this.minBookingMinutes,
        maxBookingMinutes: maxBookingMinutes ?? this.maxBookingMinutes,
        minAdvanceMinutes: minAdvanceMinutes ?? this.minAdvanceMinutes,
        maxAdvanceDays: maxAdvanceDays ?? this.maxAdvanceDays,
        bufferMinutes: bufferMinutes ?? this.bufferMinutes,
        arrivalGraceMinutes: arrivalGraceMinutes ?? this.arrivalGraceMinutes,
        earlyCheckinMinutes: earlyCheckinMinutes ?? this.earlyCheckinMinutes,
        customerCancelUntilMinutes: customerCancelUntilMinutes ?? this.customerCancelUntilMinutes,
        autoNoShowEnabled: autoNoShowEnabled ?? this.autoNoShowEnabled,
      );
}

@immutable
class BlockedPeriod {
  const BlockedPeriod({
    required this.id,
    required this.stationId,
    required this.startsAt,
    required this.endsAt,
    required this.kind,
    this.chargingPointId,
    this.reason,
    this.cancelledAt,
  });

  factory BlockedPeriod.fromJson(Object? json) {
    final j = Json.of(json);
    final range = TstzRange.parse(j.str('period'));
    return BlockedPeriod(
      id: j.str('id'),
      stationId: j.str('station_id'),
      chargingPointId: j.strOrNull('charging_point_id'),
      startsAt: range.start,
      endsAt: range.end,
      kind: BlockedPeriodKind.parse(j.strOrNull('kind')),
      reason: j.strOrNull('reason'),
      cancelledAt: j.dateTimeOrNull('cancelled_at'),
    );
  }

  final String id;
  final String stationId;
  final String? chargingPointId;
  final DateTime startsAt;
  final DateTime endsAt;
  final BlockedPeriodKind kind;
  final String? reason;
  final DateTime? cancelledAt;
}

/// Parses PostgreSQL tstzrange text such as `["2026-10-22 04:30:00+00","2026-10-22 05:30:00+00")`.
@immutable
class TstzRange {
  const TstzRange(this.start, this.end);

  factory TstzRange.parse(String text) {
    final inner = text.substring(1, text.length - 1);
    final parts = inner.split(',');
    if (parts.length != 2) throw FormatException('Invalid range: $text');
    DateTime parse(String s) {
      final cleaned = s.replaceAll('"', '').trim().replaceFirst(' ', 'T');
      // "+00" offsets need minutes for DateTime.parse.
      final normalized = RegExp(r'[+-]\d{2}$').hasMatch(cleaned) ? '$cleaned:00' : cleaned;
      return DateTime.parse(normalized).toUtc();
    }

    return TstzRange(parse(parts[0]), parse(parts[1]));
  }

  final DateTime start;
  final DateTime end;
}

@immutable
class MaintenanceReport {
  const MaintenanceReport({
    required this.id,
    required this.stationId,
    required this.title,
    required this.description,
    required this.severity,
    required this.status,
    required this.reportedAt,
    required this.markedPointUnavailable,
    this.chargingPointId,
    this.resolvedAt,
    this.resolutionNotes,
  });

  factory MaintenanceReport.fromJson(Object? json) {
    final j = Json.of(json);
    return MaintenanceReport(
      id: j.str('id'),
      stationId: j.str('station_id'),
      chargingPointId: j.strOrNull('charging_point_id'),
      title: j.str('title'),
      description: j.str('description'),
      severity: MaintenanceSeverity.parse(j.strOrNull('severity')),
      status: MaintenanceStatus.parse(j.strOrNull('status')),
      markedPointUnavailable: j.boolean('marked_point_unavailable'),
      reportedAt: j.dateTime('reported_at'),
      resolvedAt: j.dateTimeOrNull('resolved_at'),
      resolutionNotes: j.strOrNull('resolution_notes'),
    );
  }

  final String id;
  final String stationId;
  final String? chargingPointId;
  final String title;
  final String description;
  final MaintenanceSeverity severity;
  final MaintenanceStatus status;
  final bool markedPointUnavailable;
  final DateTime reportedAt;
  final DateTime? resolvedAt;
  final String? resolutionNotes;

  bool get isOpen => status == MaintenanceStatus.open || status == MaintenanceStatus.inProgress;
}

@immutable
class BusinessMember {
  const BusinessMember({
    required this.id,
    required this.userId,
    required this.role,
    required this.permissions,
    required this.active,
    this.fullName,
    this.email,
    this.stationIds = const [],
  });

  factory BusinessMember.fromJson(Object? json) {
    final j = Json.of(json);
    final profile = j.objectOrNull('profiles');
    return BusinessMember(
      id: j.str('id'),
      userId: j.str('user_id'),
      role: BusinessMemberRole.parse(j.strOrNull('role')),
      permissions: j.strings('permissions').map(BusinessPermission.tryParse).whereType<BusinessPermission>().toSet(),
      active: j.strOrNull('status') == 'active',
      fullName: profile?.strOrNull('full_name'),
      email: profile?.strOrNull('email'),
      stationIds: j.objects('station_assignments').map((a) => a.str('station_id')).toList(),
    );
  }

  final String id;
  final String userId;
  final BusinessMemberRole role;
  final Set<BusinessPermission> permissions;
  final bool active;
  final String? fullName;
  final String? email;
  final List<String> stationIds;
}
