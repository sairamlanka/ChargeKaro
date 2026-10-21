import 'package:meta/meta.dart';

import 'enums.dart';
import 'json.dart';

@immutable
class AppNotification {
  const AppNotification({
    required this.id,
    required this.category,
    required this.type,
    required this.title,
    required this.body,
    required this.data,
    required this.createdAt,
    this.readAt,
  });

  factory AppNotification.fromJson(Object? json) {
    final j = Json.of(json);
    return AppNotification(
      id: j.str('id'),
      category: NotificationCategory.parse(j.strOrNull('category')),
      type: j.str('type'),
      title: j.str('title'),
      body: j.str('body'),
      data: j.objectOrNull('data')?.map ?? const {},
      readAt: j.dateTimeOrNull('read_at'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final String id;
  final NotificationCategory category;
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isRead => readAt != null;
  String? get bookingId => data['booking_id'] as String?;
  String? get stationId => data['station_id'] as String?;
  String? get applicationId => data['application_id'] as String?;
}

@immutable
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.occurredAt,
    required this.actorKind,
    required this.action,
    required this.entityType,
    this.actorId,
    this.entityId,
    this.reason,
    this.before,
    this.after,
  });

  factory AuditEntry.fromJson(Object? json) {
    final j = Json.of(json);
    return AuditEntry(
      id: j.integer('id'),
      occurredAt: j.dateTime('occurred_at'),
      actorId: j.strOrNull('actor_id'),
      actorKind: j.str('actor_kind'),
      action: j.str('action'),
      entityType: j.str('entity_type'),
      entityId: j.strOrNull('entity_id'),
      reason: j.strOrNull('reason'),
      before: j.objectOrNull('before_data')?.map,
      after: j.objectOrNull('after_data')?.map,
    );
  }

  final int id;
  final DateTime occurredAt;
  final String? actorId;
  final String actorKind;
  final String action;
  final String entityType;
  final String? entityId;
  final String? reason;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;
}

@immutable
class StaffMember {
  const StaffMember({
    required this.userId,
    required this.role,
    required this.isActive,
    this.fullName,
    this.email,
    this.overrides = const {},
  });

  factory StaffMember.fromJson(Object? json) {
    final j = Json.of(json);
    final p = j.objectOrNull('profiles');
    return StaffMember(
      userId: j.str('user_id'),
      role: PlatformRole.tryParse(j.strOrNull('role')) ?? PlatformRole.complianceReviewer,
      isActive: j.boolean('is_active', true),
      fullName: p?.strOrNull('full_name'),
      email: p?.strOrNull('email'),
      overrides: {
        for (final o in j.objects('platform_staff_permission_overrides')) o.str('permission'): o.boolean('granted'),
      },
    );
  }

  final String userId;
  final PlatformRole role;
  final bool isActive;
  final String? fullName;
  final String? email;
  final Map<String, bool> overrides;
}

/// get_admin_dashboard(). Every value is a count of real rows.
@immutable
class DashboardMetrics {
  const DashboardMetrics(this.raw);

  factory DashboardMetrics.fromJson(Object? json) => DashboardMetrics(Json.of(json).map);

  final Map<String, dynamic> raw;

  int metric(String group, String key) {
    final g = raw[group];
    if (g is Map && g[key] is num) return (g[key] as num).toInt();
    return 0;
  }

  Map<String, dynamic>? get finance => raw['finance'] is Map ? Json.of(raw['finance']).map : null;
  String? get financeFilteredNote => raw['finance_filtered_note'] as String?;
}

/// get_business_report(). Operational data only, never charging revenue.
@immutable
class BusinessReport {
  const BusinessReport(this.raw);

  factory BusinessReport.fromJson(Object? json) => BusinessReport(Json.of(json).map);

  final Map<String, dynamic> raw;

  int total(String key) => (Json.of(raw['totals'])[key] as num?)?.toInt() ?? 0;

  List<({DateTime date, int bookings})> series(String key, String dateKey) => Json(raw)
      .objects(key)
      .map((e) => (date: e.dateOrNull(dateKey)!, bookings: e.integer('bookings')))
      .toList();

  List<({int hour, int bookings})> get peakHours =>
      Json(raw).objects('peak_hours').map((e) => (hour: e.integer('hour'), bookings: e.integer('bookings'))).toList();

  List<Map<String, dynamic>> get byStation => Json(raw).objects('by_station').map((e) => e.map).toList();

  List<Map<String, dynamic>> get byChargingPoint => Json(raw).objects('by_charging_point').map((e) => e.map).toList();

  List<String> get notes => Json(raw).strings('notes');

  /// Utilisation of a point: reserved minutes / operating minutes, 0–1.
  static double utilisation(Map<String, dynamic> point) {
    final reserved = (point['reserved_minutes'] as num?)?.toDouble() ?? 0;
    final operating = (point['operating_minutes'] as num?)?.toDouble() ?? 0;
    if (operating <= 0) return 0;
    return (reserved / operating).clamp(0, 1).toDouble();
  }
}
