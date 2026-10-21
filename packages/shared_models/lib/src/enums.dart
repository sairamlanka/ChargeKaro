/// Domain enums. Each value carries the exact wire value used by PostgreSQL
/// (`lower_snake_case`) and a display label. Unknown wire values map to a
/// safe fallback instead of throwing, so a newer backend never crashes an
/// older app.
library;

/// Shared behaviour for enums that round-trip to the database.
mixin WireEnum on Enum {
  String get wire;
  String get label;
}

T _parse<T extends WireEnum>(List<T> values, String? wire, T fallback) {
  for (final v in values) {
    if (v.wire == wire) return v;
  }
  return fallback;
}

enum PlatformRole with WireEnum {
  superAdmin('super_admin', 'Super admin'),
  admin('admin', 'Admin'),
  complianceReviewer('compliance_reviewer', 'Compliance reviewer');

  const PlatformRole(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static PlatformRole? tryParse(String? wire) {
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}

enum BusinessMemberRole with WireEnum {
  owner('owner', 'Owner'),
  stationManager('station_manager', 'Station manager'),
  stationStaff('station_staff', 'Station staff');

  const BusinessMemberRole(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static BusinessMemberRole parse(String? wire) => _parse(values, wire, stationStaff);
}

/// Permissions a business member can hold on assigned stations.
/// Owners implicitly hold all of them.
enum BusinessPermission with WireEnum {
  stationEdit('station.edit', 'Edit station details'),
  availabilityEdit('availability.edit', 'Manage hours, slots and closures'),
  pointsManage('points.manage', 'Add and edit charging points'),
  pointsStatus('points.status', 'Update charging point status'),
  bookingsView('bookings.view', 'View bookings'),
  bookingsCheckin('bookings.checkin', 'Check customers in'),
  bookingsManage('bookings.manage', 'Cancel bookings and record no-shows'),
  maintenanceReport('maintenance.report', 'Report faults'),
  maintenanceManage('maintenance.manage', 'Resolve faults'),
  documentsManage('documents.manage', 'Manage compliance documents'),
  reportsView('reports.view', 'View reports');

  const BusinessPermission(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static BusinessPermission? tryParse(String? wire) {
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}

enum BusinessType with WireEnum {
  individual('individual', 'Individual'),
  soleProprietorship('sole_proprietorship', 'Sole proprietorship'),
  partnership('partnership', 'Partnership'),
  llp('llp', 'LLP'),
  privateLimited('private_limited', 'Private limited company'),
  publicLimited('public_limited', 'Public limited company'),
  cooperative('cooperative', 'Cooperative'),
  government('government', 'Government body'),
  trustOrSociety('trust_or_society', 'Trust or society'),
  other('other', 'Other');

  const BusinessType(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static BusinessType parse(String? wire) => _parse(values, wire, other);
}

enum BusinessStatus with WireEnum {
  pendingVerification('pending_verification', 'Pending verification'),
  active('active', 'Active'),
  suspended('suspended', 'Suspended'),
  deactivated('deactivated', 'Deactivated');

  const BusinessStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static BusinessStatus parse(String? wire) => _parse(values, wire, pendingVerification);
}

enum StationStatus with WireEnum {
  draft('draft', 'Draft'),
  active('active', 'Active'),
  temporarilyClosed('temporarily_closed', 'Temporarily closed'),
  suspended('suspended', 'Suspended'),
  deactivated('deactivated', 'Deactivated');

  const StationStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static StationStatus parse(String? wire) => _parse(values, wire, draft);
}

enum ApplicationStatus with WireEnum {
  draft('draft', 'Draft'),
  submitted('submitted', 'Submitted'),
  underReview('under_review', 'Under review'),
  additionalInformationRequired('additional_information_required', 'Information requested'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected'),
  suspended('suspended', 'Suspended');

  const ApplicationStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static ApplicationStatus parse(String? wire) => _parse(values, wire, draft);

  /// Whether the business owner may (re)submit from this state. The server
  /// enforces this; the UI uses it to show the submit action.
  bool get ownerCanSubmit => this == draft || this == additionalInformationRequired || this == rejected;

  bool get awaitingReview => this == submitted || this == underReview;
}

enum DocumentScope with WireEnum {
  business('business', 'Business'),
  station('station', 'Station');

  const DocumentScope(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static DocumentScope parse(String? wire) => _parse(values, wire, station);
}

enum DocumentStatus with WireEnum {
  pendingReview('pending_review', 'Pending review'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected'),
  correctionRequired('correction_required', 'Correction required'),
  expired('expired', 'Expired'),
  superseded('superseded', 'Superseded');

  const DocumentStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static DocumentStatus parse(String? wire) => _parse(values, wire, pendingReview);

  bool get needsAction => this == rejected || this == correctionRequired || this == expired;
}

enum CurrentType with WireEnum {
  ac('ac', 'AC'),
  dc('dc', 'DC');

  const CurrentType(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static CurrentType parse(String? wire) => _parse(values, wire, ac);
}

enum ConnectorType with WireEnum {
  ccs2('ccs2', 'CCS2'),
  chademo('chademo', 'CHAdeMO'),
  type2Ac('type2_ac', 'Type 2 (AC)'),
  type1Ac('type1_ac', 'Type 1 (AC)'),
  gbT('gb_t', 'GB/T'),
  bharatAc001('bharat_ac001', 'Bharat AC-001'),
  bharatDc001('bharat_dc001', 'Bharat DC-001'),
  type6Lev('type6_lev', 'Type 6 (LEV)'),
  threePinSocket('three_pin_socket', '3-pin socket'),
  other('other', 'Other');

  const ConnectorType(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static ConnectorType parse(String? wire) => _parse(values, wire, other);
}

/// Hardware operational status. "Booked" is not a value here: reservations
/// are separate, so a booking never hides a maintenance state.
enum PointStatus with WireEnum {
  available('available', 'Available'),
  inUse('in_use', 'In use'),
  maintenance('maintenance', 'Maintenance'),
  outOfService('out_of_service', 'Out of service'),
  disabled('disabled', 'Disabled');

  const PointStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static PointStatus parse(String? wire) => _parse(values, wire, outOfService);

  bool get acceptsBookings => this == available || this == inUse;
}

enum StatusSource with WireEnum {
  manual('manual', 'Manually reported'),
  telemetry('telemetry', 'Charger telemetry');

  const StatusSource(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static StatusSource parse(String? wire) => _parse(values, wire, manual);
}

enum TelemetryCapability with WireEnum {
  none('none', 'No live integration'),
  unknown('unknown', 'Unknown'),
  ocpp16('ocpp_1_6', 'OCPP 1.6'),
  ocpp201('ocpp_2_0_1', 'OCPP 2.0.1'),
  other('other', 'Other protocol');

  const TelemetryCapability(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static TelemetryCapability parse(String? wire) => _parse(values, wire, unknown);
}

enum BookingStatus with WireEnum {
  paymentPending('payment_pending', 'Payment pending'),
  confirmed('confirmed', 'Confirmed'),
  arrived('arrived', 'Arrived'),
  inProgress('in_progress', 'Charging'),
  completed('completed', 'Completed'),
  cancelled('cancelled', 'Cancelled'),
  expired('expired', 'Expired'),
  noShow('no_show', 'No-show');

  const BookingStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static BookingStatus parse(String? wire) => _parse(values, wire, expired);

  /// Mirrors private.is_valid_booking_transition in the database.
  static const Map<BookingStatus, Set<BookingStatus>> transitions = {
    paymentPending: {confirmed, expired, cancelled},
    confirmed: {arrived, cancelled, noShow},
    arrived: {inProgress, completed},
    inProgress: {completed},
    expired: {confirmed},
    completed: {},
    cancelled: {},
    noShow: {},
  };

  bool canTransitionTo(BookingStatus next) => transitions[this]!.contains(next);

  /// Statuses that hold the slot (the exclusion constraint's set).
  bool get holdsSlot => this == paymentPending || this == confirmed || this == arrived || this == inProgress;

  bool get isTerminal => transitions[this]!.isEmpty;
}

enum BookingPaymentStatus with WireEnum {
  notRequired('not_required', 'No fee'),
  pending('pending', 'Awaiting payment'),
  paid('paid', 'Paid'),
  failed('failed', 'Payment failed'),
  abandoned('abandoned', 'Not paid'),
  refundPending('refund_pending', 'Refund pending'),
  refunded('refunded', 'Refunded');

  const BookingPaymentStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static BookingPaymentStatus parse(String? wire) => _parse(values, wire, pending);

  bool get settled => this == paid || this == notRequired;
}

enum ActorKind with WireEnum {
  customer('customer', 'Customer'),
  business('business', 'Station'),
  platform('platform', 'Platform'),
  system('system', 'System');

  const ActorKind(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static ActorKind parse(String? wire) => _parse(values, wire, system);
}

enum BlockedPeriodKind with WireEnum {
  maintenance('maintenance', 'Maintenance'),
  temporaryClosure('temporary_closure', 'Temporary closure'),
  other('other', 'Other');

  const BlockedPeriodKind(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static BlockedPeriodKind parse(String? wire) => _parse(values, wire, other);
}

enum MaintenanceSeverity with WireEnum {
  low('low', 'Low'),
  medium('medium', 'Medium'),
  high('high', 'High'),
  critical('critical', 'Critical');

  const MaintenanceSeverity(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static MaintenanceSeverity parse(String? wire) => _parse(values, wire, medium);
}

enum MaintenanceStatus with WireEnum {
  open('open', 'Open'),
  inProgress('in_progress', 'In progress'),
  resolved('resolved', 'Resolved'),
  cancelled('cancelled', 'Cancelled');

  const MaintenanceStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static MaintenanceStatus parse(String? wire) => _parse(values, wire, open);
}

enum ExpenseStatus with WireEnum {
  submitted('submitted', 'Awaiting approval'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected'),
  voided('void', 'Void');

  const ExpenseStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static ExpenseStatus parse(String? wire) => _parse(values, wire, submitted);
}

enum RefundStatus with WireEnum {
  requested('requested', 'Requested'),
  processing('processing', 'Processing'),
  processed('processed', 'Processed'),
  failed('failed', 'Failed');

  const RefundStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static RefundStatus parse(String? wire) => _parse(values, wire, requested);
}

enum GatewayPaymentStatus with WireEnum {
  authorized('authorized', 'Authorized'),
  captured('captured', 'Captured'),
  failed('failed', 'Failed');

  const GatewayPaymentStatus(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static GatewayPaymentStatus parse(String? wire) => _parse(values, wire, failed);
}

enum NotificationCategory with WireEnum {
  booking('booking', 'Bookings'),
  application('application', 'Applications'),
  compliance('compliance', 'Compliance'),
  maintenance('maintenance', 'Maintenance'),
  station('station', 'Stations'),
  announcement('announcement', 'Announcements'),
  system('system', 'System');

  const NotificationCategory(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static NotificationCategory parse(String? wire) => _parse(values, wire, system);
}

/// Station amenities accepted by the database check constraint.
enum Amenity with WireEnum {
  restroom('restroom', 'Restroom'),
  drinkingWater('drinking_water', 'Drinking water'),
  cafe('cafe', 'Café'),
  restaurant('restaurant', 'Restaurant'),
  wifi('wifi', 'Wi-Fi'),
  waitingLounge('waiting_lounge', 'Waiting lounge'),
  shopping('shopping', 'Shopping'),
  coveredParking('covered_parking', 'Covered parking'),
  cctv('cctv', 'CCTV'),
  wheelchairAccessible('wheelchair_accessible', 'Wheelchair accessible'),
  airPump('air_pump', 'Air pump'),
  atm('atm', 'ATM'),
  open24x7('open_24x7', 'Open 24×7');

  const Amenity(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static Amenity? tryParse(String? wire) {
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}

/// How customers can pay the station for charging. Informational only:
/// the platform never collects charging fees.
enum StationPaymentMethod with WireEnum {
  cash('cash', 'Cash'),
  upi('upi', 'UPI'),
  debitCard('debit_card', 'Debit card'),
  creditCard('credit_card', 'Credit card'),
  rfidCard('rfid_card', 'RFID card'),
  operatorApp('operator_app', 'Operator app'),
  wallet('wallet', 'Wallet');

  const StationPaymentMethod(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static StationPaymentMethod? tryParse(String? wire) {
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}

enum VehicleCategory with WireEnum {
  twoWheeler('two_wheeler', '2-wheeler'),
  threeWheeler('three_wheeler', '3-wheeler'),
  fourWheeler('four_wheeler', '4-wheeler'),
  commercial('commercial', 'Commercial'),
  bus('bus', 'Bus');

  const VehicleCategory(this.wire, this.label);
  @override
  final String wire;
  @override
  final String label;

  static VehicleCategory? tryParse(String? wire) {
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}
