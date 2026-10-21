import 'package:meta/meta.dart';

import 'enums.dart';
import 'json.dart';

/// What a platform staff member may do, as reported by my_platform_access().
/// Used only to shape navigation; the backend re-checks every action.
@immutable
class PlatformAccess {
  const PlatformAccess({required this.isStaff, this.role, this.permissions = const {}});

  factory PlatformAccess.fromJson(Object? json) {
    final j = Json.of(json);
    return PlatformAccess(
      isStaff: j.boolean('is_staff'),
      role: PlatformRole.tryParse(j.strOrNull('role')),
      permissions: j.strings('permissions').toSet(),
    );
  }

  static const none = PlatformAccess(isStaff: false);

  final bool isStaff;
  final PlatformRole? role;
  final Set<String> permissions;

  bool can(String permission) => isStaff && (role == PlatformRole.superAdmin || permissions.contains(permission));
}

/// Platform permission codes (mirror of public.platform_permissions).
abstract final class PlatformPermission {
  static const adminsManage = 'admins.manage';
  static const settingsManage = 'settings.manage';
  static const auditRead = 'audit.read';
  static const businessesRead = 'businesses.read';
  static const businessesManage = 'businesses.manage';
  static const applicationsReview = 'applications.review';
  static const applicationsRequestInfo = 'applications.request_info';
  static const applicationsDecide = 'applications.decide';
  static const documentsReview = 'documents.review';
  static const documentTypesManage = 'document_types.manage';
  static const stationsManage = 'stations.manage';
  static const stationsSuspend = 'stations.suspend';
  static const bookingsReadAll = 'bookings.read_all';
  static const bookingsOverride = 'bookings.override';
  static const bookingsSupportNotes = 'bookings.support_notes';
  static const reportsOperational = 'reports.operational';
  static const financeRead = 'finance.read';
  static const financeExpensesWrite = 'finance.expenses.write';
  static const financeExpensesApprove = 'finance.expenses.approve';
  static const financeRefundsIssue = 'finance.refunds.issue';
  static const notificationsBroadcast = 'notifications.broadcast';
}

/// One business the signed-in user belongs to (my_business_access()).
@immutable
class BusinessAccess {
  const BusinessAccess({
    required this.businessId,
    required this.businessName,
    required this.businessStatus,
    required this.memberId,
    required this.role,
    required this.permissions,
    required this.stationIds,
    this.businessStatusReason,
  });

  factory BusinessAccess.fromJson(Object? json) {
    final j = Json.of(json);
    return BusinessAccess(
      businessId: j.str('business_id'),
      businessName: j.str('business_name'),
      businessStatus: BusinessStatus.parse(j.strOrNull('business_status')),
      businessStatusReason: j.strOrNull('business_status_reason'),
      memberId: j.str('member_id'),
      role: BusinessMemberRole.parse(j.strOrNull('role')),
      permissions: j.strings('permissions').map(BusinessPermission.tryParse).whereType<BusinessPermission>().toSet(),
      stationIds: j.strings('station_ids'),
    );
  }

  final String businessId;
  final String businessName;
  final BusinessStatus businessStatus;
  final String? businessStatusReason;
  final String memberId;
  final BusinessMemberRole role;
  final Set<BusinessPermission> permissions;
  final List<String> stationIds;

  bool get isOwner => role == BusinessMemberRole.owner;

  bool can(BusinessPermission permission, {String? stationId}) {
    if (isOwner) return true;
    if (!permissions.contains(permission)) return false;
    return stationId == null || stationIds.contains(stationId);
  }
}
