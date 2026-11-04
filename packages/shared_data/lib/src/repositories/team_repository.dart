import 'dart:async';

import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../failure.dart';
import 'base.dart';

/// Result of creating a member or approving an add request.
typedef MemberCreated = ({String? memberId, bool loginCreated});

/// Team members and manager requests (supabase/migrations/20261103000200_team_requests.sql
/// and the team-members Edge Function). The owner adds and removes directly;
/// a station manager raises requests the owner approves.
class TeamRepository extends Repository {
  TeamRepository(super.client);

  static const _timeout = Duration(seconds: 30);

  /// Owner: everyone. Manager: self + staff at their stations. Staff: self.
  Future<List<BusinessMember>> members(String businessId) async =>
      (await rpc<List<dynamic>>('list_team_members', {'p_business_id': businessId})).map(BusinessMember.fromJson).toList();

  /// Owner: all requests. Manager: their own.
  Future<List<MemberRequest>> requests(String businessId, {bool pendingOnly = false}) async =>
      (await rpc<List<dynamic>>('list_member_requests', {'p_business_id': businessId, 'p_pending_only': pendingOnly}))
          .map(MemberRequest.fromJson)
          .toList();

  // ---- Owner ------------------------------------------------------------

  /// Creates the login (when the email has none) with [tempPassword] and adds
  /// the member. When the email already has a login, the password is ignored.
  Future<MemberCreated> create({
    required String businessId,
    required String email,
    required String fullName,
    String? phone,
    required BusinessMemberRole role,
    required Set<BusinessPermission> permissions,
    required List<String> stationIds,
    required String tempPassword,
  }) async {
    final r = await _invoke({
      'action': 'create',
      'business_id': businessId,
      'email': email.trim().toLowerCase(),
      'full_name': fullName.trim(),
      'phone': phone?.trim(),
      'role': role.wire,
      'permissions': permissions.map((p) => p.wire).toList(),
      'station_ids': stationIds,
      'temp_password': tempPassword,
    });
    return (memberId: r['member_id'] as String?, loginCreated: r['login_created'] == true);
  }

  Future<MemberCreated> approveAdd(String requestId, {required String tempPassword}) async {
    final r = await _invoke({'action': 'approve', 'request_id': requestId, 'temp_password': tempPassword});
    return (memberId: r['member_id'] as String?, loginCreated: r['login_created'] == true);
  }

  /// Approves a manager's removal request: deletes the member.
  Future<void> approveRemoval(String requestId) => _invoke({'action': 'approve', 'request_id': requestId});

  Future<void> reject(String requestId, {String? note}) =>
      rpc<void>('reject_member_request', {'p_request_id': requestId, 'p_note': note});

  /// Deletes a member who left. Returns true when their login was closed too.
  Future<bool> remove(String memberId) async => (await _invoke({'action': 'remove', 'member_id': memberId}))['login_closed'] == true;

  Future<void> update(String memberId, BusinessMemberRole role,
          {required Set<BusinessPermission> permissions, required List<String> stationIds}) =>
      rpc<void>('update_business_member', {
        'p_member_id': memberId,
        'p_role': role.wire,
        'p_permissions': permissions.map((p) => p.wire).toList(),
        'p_station_ids': stationIds,
      });

  // ---- Station manager ----------------------------------------------------

  Future<void> requestAdd({
    required String businessId,
    required String email,
    required String fullName,
    String? phone,
    required List<String> stationIds,
  }) =>
      rpc<Object?>('request_team_member', {
        'p_business_id': businessId,
        'p_email': email.trim().toLowerCase(),
        'p_full_name': fullName.trim(),
        'p_phone': (phone == null || phone.trim().isEmpty) ? null : phone.trim(),
        'p_station_ids': stationIds,
      });

  Future<void> requestRemoval(String memberId, {String? reason}) =>
      rpc<Object?>('request_member_removal', {'p_member_id': memberId, 'p_reason': reason});

  Future<void> cancel(String requestId) => rpc<void>('cancel_member_request', {'p_request_id': requestId});

  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) => logged('function team-members', () async {
        try {
          final res = await client.functions.invoke('team-members', body: body).timeout(_timeout);
          final data = res.data;
          return data is Map<String, dynamic> ? data : <String, dynamic>{};
        } on FunctionException catch (e) {
          final details = e.details;
          final code = details is Map ? details['error']?.toString() ?? 'function_error' : 'function_error';
          final message = details is Map ? details['message']?.toString() : null;
          throw AppFailure(
            switch (e.status) {
              401 => FailureKind.unauthenticated,
              403 => FailureKind.forbidden,
              404 => FailureKind.notFound,
              409 => FailureKind.conflict,
              422 => FailureKind.validation,
              _ => FailureKind.server,
            },
            code,
            message ?? AppFailure.messages[code] ?? 'The request could not be completed.',
            detail: 'HTTP ${e.status}',
          );
        } on TimeoutException {
          throw const AppFailure(FailureKind.network, 'timeout', 'This is taking too long. Check your connection and try again.');
        }
      }, params: {'action': body['action']});
}
