import 'package:shared_models/shared_models.dart';

import '../failure.dart';
import 'base.dart';

/// Platform administration. Every method is permission-checked again in the
/// database; the Admin Panel only hides what the caller cannot use.
class AdminRepository extends Repository {
  AdminRepository(super.client);

  Future<DashboardMetrics> dashboard({
    required DateTime from,
    required DateTime to,
    String? state,
    String? city,
    String? businessId,
    String? stationId,
  }) async =>
      DashboardMetrics.fromJson(await rpc<Object?>('get_admin_dashboard', {
        'p_from': Repository.date(from),
        'p_to': Repository.date(to),
        'p_state': state,
        'p_city': city,
        'p_business_id': businessId,
        'p_station_id': stationId,
      }));

  // ---- Businesses and stations ---------------------------------------------------

  Future<List<Business>> businesses({String? search, BusinessStatus? status}) {
    var q = client.from('businesses').select();
    if (status != null) q = q.eq('status', status.wire);
    final s = search?.trim();
    if (s != null && s.isNotEmpty) {
      final safe = s.replaceAll(RegExp(r'[%,()*]'), ' ');
      q = q.or('legal_name.ilike.%$safe%,display_name.ilike.%$safe%,contact_email.ilike.%$safe%');
    }
    return rows(q.order('created_at', ascending: false).limit(200), Business.fromJson);
  }

  Future<List<Station>> stations({String? businessId, StationStatus? status, String? state, String? city, String? search}) {
    var q = client.from('stations').select();
    if (businessId != null) q = q.eq('business_id', businessId);
    if (status != null) q = q.eq('status', status.wire);
    if (state != null) q = q.eq('state', state);
    if (city != null) q = q.ilike('city', city);
    final s = search?.trim();
    if (s != null && s.isNotEmpty) q = q.ilike('name', '%${s.replaceAll(RegExp(r'[%,()*]'), ' ')}%');
    return rows(q.order('created_at', ascending: false).limit(300), Station.fromJson);
  }

  Future<Map<String, dynamic>> suspendStation(String stationId, String reason, {required bool cancelFutureBookings}) =>
      rpc<Map<String, dynamic>>('suspend_station',
          {'p_station_id': stationId, 'p_reason': reason, 'p_cancel_future_bookings': cancelFutureBookings});

  Future<void> reactivateStation(String stationId, String note) =>
      rpc<void>('reactivate_station', {'p_station_id': stationId, 'p_note': note});

  Future<Map<String, dynamic>> deactivateStation(String stationId, String reason) =>
      rpc<Map<String, dynamic>>('deactivate_station', {'p_station_id': stationId, 'p_reason': reason});

  // ---- Platform staff -------------------------------------------------------------

  Future<List<StaffMember>> staff() => rows(
        client
            .from('platform_staff')
            .select('*, profiles!platform_staff_user_id_fkey(full_name, email), '
                'platform_staff_permission_overrides!platform_staff_permission_overrides_user_id_fkey(permission, granted)')
            .order('created_at'),
        StaffMember.fromJson,
      );

  Future<String?> findUserIdByEmail(String email) async {
    final r = await guard(() => client.from('profiles').select('id').eq('email', email.trim().toLowerCase()).maybeSingle());
    return r?['id'] as String?;
  }

  Future<void> grantRole(String userId, PlatformRole role) =>
      rpc<void>('grant_platform_role', {'p_user_id': userId, 'p_role': role.wire});

  Future<void> revokeRole(String userId, String reason) =>
      rpc<void>('revoke_platform_role', {'p_user_id': userId, 'p_reason': reason});

  /// [granted] null removes the override so the role default applies.
  Future<void> setPermissionOverride(String userId, String permission, bool? granted) => rpc<void>(
      'set_platform_permission_override', {'p_user_id': userId, 'p_permission': permission, 'p_granted': granted});

  Future<List<Map<String, dynamic>>> permissions() =>
      guard(() => client.from('platform_permissions').select().order('code'));

  // ---- Settings and audit -------------------------------------------------------------

  Future<List<Map<String, dynamic>>> settings() => guard(() => client.from('platform_settings').select().order('key'));

  Future<void> updateSetting(String key, Object value, String reason) =>
      rpc<void>('update_platform_setting', {'p_key': key, 'p_value': value, 'p_reason': reason});

  Future<List<AuditEntry>> audit({String? entityType, String? entityId, String? action, int limit = 100, int offset = 0}) {
    var q = client.from('audit_logs').select();
    if (entityType != null) q = q.eq('entity_type', entityType);
    if (entityId != null) q = q.eq('entity_id', entityId);
    if (action != null && action.isNotEmpty) q = q.ilike('action', '%${action.replaceAll(RegExp(r'[%,()*]'), ' ')}%');
    return rows(q.order('occurred_at', ascending: false).range(offset, offset + limit - 1), AuditEntry.fromJson);
  }
}
