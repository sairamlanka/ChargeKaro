import 'dart:typed_data';

import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../failure.dart';
import '../storage_paths.dart';
import 'base.dart';

/// Businesses, stations, charging points, availability and team members,
/// as seen by a business user. RLS limits every query to what the caller's
/// membership allows.
class StationRepository extends Repository {
  StationRepository(super.client);

  static const pointColumns = '*, charging_connectors(*)';

  // ---- Business -------------------------------------------------------------

  Future<String> createBusiness({
    required String legalName,
    String? displayName,
    required String ownerFullName,
    required String contactPhone,
    required String contactEmail,
    required BusinessType businessType,
    String? registrationNumber,
    String? gstin,
    String? addressLine1,
    String? addressLine2,
    String? city,
    String? state,
    String? postalCode,
  }) =>
      rpc<String>('create_business', {
        'p_legal_name': legalName,
        'p_display_name': displayName,
        'p_owner_full_name': ownerFullName,
        'p_contact_phone': contactPhone,
        'p_contact_email': contactEmail,
        'p_business_type': businessType.wire,
        'p_registration_number': registrationNumber,
        'p_gstin': gstin,
        'p_registered_address_line1': addressLine1,
        'p_registered_address_line2': addressLine2,
        'p_registered_city': city,
        'p_registered_state': state,
        'p_registered_postal_code': postalCode,
      });

  Future<Business> business(String id) => row(client.from('businesses').select().eq('id', id).single(), Business.fromJson);

  Future<void> updateBusiness(String id, Map<String, Object?> fields) =>
      guard(() async => client.from('businesses').update(fields).eq('id', id));

  // ---- Stations -------------------------------------------------------------

  Future<List<Station>> stations(String businessId) =>
      rows(client.from('stations').select().eq('business_id', businessId).order('created_at'), Station.fromJson);

  Future<Station> station(String id) => row(client.from('stations').select().eq('id', id).single(), Station.fromJson);

  /// Inserts a draft station; the database forces status = draft and creates
  /// its booking policy and onboarding application.
  Future<Station> createStation(String businessId, Map<String, Object?> fields) => row(
        client.from('stations').insert({...fields, 'business_id': businessId}).select().single(),
        Station.fromJson,
      );

  /// Direct edit. After approval, sensitive fields are rejected by the
  /// database (sensitive_change_requires_approval): use [requestChange].
  Future<Station> updateStation(String id, Map<String, Object?> fields) =>
      row(client.from('stations').update(fields).eq('id', id).select().single(), Station.fromJson);

  Future<String> requestChange(String stationId, Map<String, Object?> changes, {String? note}) =>
      rpc<String>('request_station_change', {'p_station_id': stationId, 'p_changes': changes, 'p_note': note});

  Future<List<StationChangeRequest>> changeRequests(String stationId) => rows(
        client.from('station_change_requests').select().eq('station_id', stationId).order('created_at', ascending: false),
        StationChangeRequest.fromJson,
      );

  Future<Map<String, dynamic>> closeTemporarily(String stationId,
          {required DateTime until, required String reason, bool cancelConflicting = false}) =>
      rpc<Map<String, dynamic>>('close_station_temporarily', {
        'p_station_id': stationId,
        'p_until': until.toUtc().toIso8601String(),
        'p_reason': reason,
        'p_cancel_conflicting': cancelConflicting,
      });

  Future<void> reopen(String stationId) => rpc<void>('reopen_station', {'p_station_id': stationId});

  Future<void> requestDeactivation(String stationId, String reason) =>
      rpc<void>('request_station_deactivation', {'p_station_id': stationId, 'p_reason': reason});

  // ---- Photos ----------------------------------------------------------------

  Future<List<Map<String, dynamic>>> photos(String stationId) =>
      guard(() => client.from('station_photos').select().eq('station_id', stationId).order('sort_order'));

  Future<void> addPhoto(Station station, Uint8List bytes, String fileName, {String? caption}) => guard(() async {
        final path = StoragePaths.stationMedia(businessId: station.businessId, stationId: station.id, fileName: fileName);
        await client.storage.from(StoragePaths.mediaBucket).uploadBinary(path, bytes,
            fileOptions: FileOptions(contentType: StoragePaths.mimeFor(fileName)));
        await client.from('station_photos').insert({'station_id': station.id, 'storage_path': path, 'caption': caption});
      });

  Future<void> removePhoto(String photoId, String storagePath) => guard(() async {
        await client.from('station_photos').delete().eq('id', photoId);
        await client.storage.from(StoragePaths.mediaBucket).remove([storagePath]);
      });

  String publicMediaUrl(String path) => client.storage.from(StoragePaths.mediaBucket).getPublicUrl(path);

  // ---- Charging points ------------------------------------------------------------

  Future<List<ChargingPoint>> points(String stationId, {bool includeArchived = false}) {
    var q = client.from('charging_points').select(pointColumns).eq('station_id', stationId);
    if (!includeArchived) q = q.isFilter('archived_at', null);
    return rows(q.order('code'), ChargingPoint.fromJson);
  }

  Future<ChargingPoint> createPoint(String stationId, Map<String, Object?> fields, List<Map<String, Object?>> connectors) =>
      guard(() async {
        final created = await client.from('charging_points').insert({...fields, 'station_id': stationId}).select('id').single();
        final id = created['id'] as String;
        await setConnectors(id, connectors);
        return ChargingPoint.fromJson(await client.from('charging_points').select(pointColumns).eq('id', id).single());
      });

  Future<void> updatePoint(String pointId, Map<String, Object?> fields) =>
      guard(() async => client.from('charging_points').update(fields).eq('id', pointId));

  Future<void> setConnectors(String pointId, List<Map<String, Object?>> connectors) =>
      rpc<void>('set_charging_point_connectors', {'p_charging_point_id': pointId, 'p_connectors': connectors});

  Future<void> archivePoint(String pointId) => updatePoint(pointId, {
        'archived_at': DateTime.now().toUtc().toIso8601String(),
        'booking_enabled': false,
      });

  /// Manual operational status. Returns the affected future bookings, which
  /// staff must handle; the backend never auto-cancels them here.
  Future<Map<String, dynamic>> setPointStatus(String pointId, PointStatus status, {String? note}) =>
      rpc<Map<String, dynamic>>('set_charging_point_status',
          {'p_charging_point_id': pointId, 'p_status': status.wire, 'p_note': note});

  // ---- Availability -------------------------------------------------------------

  Future<List<OperatingHours>> hours(String stationId) => rows(
        client.from('station_operating_hours').select().eq('station_id', stationId).order('day_of_week').order('opens_minute'),
        OperatingHours.fromJson,
      );

  Future<void> replaceHours(String stationId, List<OperatingHours> hours, {String? chargingPointId}) =>
      rpc<void>('set_station_operating_hours', {
        'p_station_id': stationId,
        'p_charging_point_id': chargingPointId,
        'p_hours': [
          for (final h in hours) {'day_of_week': h.dayOfWeek, 'opens_minute': h.opensMinute, 'closes_minute': h.closesMinute},
        ],
      });

  Future<BookingPolicy> policy(String stationId) =>
      row(client.from('station_booking_policies').select().eq('station_id', stationId).single(), BookingPolicy.fromJson);

  Future<BookingPolicy> updatePolicy(BookingPolicy policy) {
    final problems = policy.validate();
    if (problems.isNotEmpty) {
      return Future.error(AppFailure(FailureKind.validation, 'invalid_policy', problems.join(' ')));
    }
    return row(
      client.from('station_booking_policies').update(policy.toUpdate()).eq('station_id', policy.stationId).select().single(),
      BookingPolicy.fromJson,
    );
  }

  Future<List<BlockedPeriod>> blockedPeriods(String stationId, {DateTime? from}) => rows(
        client
            .from('blocked_periods')
            .select()
            .eq('station_id', stationId)
            .isFilter('cancelled_at', null)
            .overlaps('period', Repository.range(from ?? DateTime.now(), DateTime.now().add(const Duration(days: 366))))
            .order('created_at', ascending: false),
        BlockedPeriod.fromJson,
      );

  Future<Map<String, dynamic>> createBlockedPeriod({
    required String stationId,
    String? chargingPointId,
    required DateTime startsAt,
    required DateTime endsAt,
    required BlockedPeriodKind kind,
    String? reason,
    bool cancelConflicting = false,
  }) =>
      rpc<Map<String, dynamic>>('create_blocked_period', {
        'p_station_id': stationId,
        'p_charging_point_id': chargingPointId,
        'p_starts_at': startsAt.toUtc().toIso8601String(),
        'p_ends_at': endsAt.toUtc().toIso8601String(),
        'p_kind': kind.wire,
        'p_reason': reason,
        'p_cancel_conflicting': cancelConflicting,
      });

  Future<void> cancelBlockedPeriod(String id) => rpc<void>('cancel_blocked_period', {'p_blocked_period_id': id});

  // ---- Maintenance -------------------------------------------------------------------

  Future<List<MaintenanceReport>> maintenance(String stationId, {bool openOnly = false}) {
    var q = client.from('maintenance_reports').select().eq('station_id', stationId);
    if (openOnly) q = q.inFilter('status', ['open', 'in_progress']);
    return rows(q.order('reported_at', ascending: false), MaintenanceReport.fromJson);
  }

  Future<String> reportIssue({
    required String stationId,
    String? chargingPointId,
    required String title,
    required String description,
    required MaintenanceSeverity severity,
    bool markUnavailable = false,
  }) =>
      rpc<String>('report_maintenance_issue', {
        'p_station_id': stationId,
        'p_charging_point_id': chargingPointId,
        'p_title': title,
        'p_description': description,
        'p_severity': severity.wire,
        'p_mark_unavailable': markUnavailable,
      });

  Future<void> updateIssue(String reportId, MaintenanceStatus status, {String? resolutionNotes, bool restorePoint = false}) =>
      rpc<void>('update_maintenance_report', {
        'p_report_id': reportId,
        'p_status': status.wire,
        'p_resolution_notes': resolutionNotes,
        'p_restore_point': restorePoint,
      });

  // ---- Team ---------------------------------------------------------------------------

  Future<List<BusinessMember>> members(String businessId) => rows(
        client
            .from('business_members')
            .select('*, profiles!business_members_user_id_fkey(full_name, email), station_assignments(station_id)')
            .eq('business_id', businessId)
            .order('created_at'),
        BusinessMember.fromJson,
      );

  Future<String> addMember(String businessId, String email, BusinessMemberRole role,
          {Set<BusinessPermission>? permissions, required List<String> stationIds}) =>
      rpc<String>('add_business_member', {
        'p_business_id': businessId,
        'p_email': email.trim().toLowerCase(),
        'p_role': role.wire,
        'p_permissions': permissions?.map((p) => p.wire).toList(),
        'p_station_ids': stationIds,
      });

  Future<void> updateMember(String memberId, BusinessMemberRole role,
          {required Set<BusinessPermission> permissions, required List<String> stationIds}) =>
      rpc<void>('update_business_member', {
        'p_member_id': memberId,
        'p_role': role.wire,
        'p_permissions': permissions.map((p) => p.wire).toList(),
        'p_station_ids': stationIds,
      });

  Future<void> revokeMember(String memberId) => rpc<void>('revoke_business_member', {'p_member_id': memberId});

  // ---- Reports --------------------------------------------------------------------------

  Future<BusinessReport> report(String businessId, DateTime from, DateTime to, {String? stationId}) async =>
      BusinessReport.fromJson(await rpc<Object?>('get_business_report', {
        'p_business_id': businessId,
        'p_from': Repository.date(from),
        'p_to': Repository.date(to),
        'p_station_id': stationId,
      }));
}
