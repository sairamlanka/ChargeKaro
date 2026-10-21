import 'dart:typed_data';

import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../failure.dart';
import '../storage_paths.dart';
import 'base.dart';

/// Station applications, compliance documents and their review.
class OnboardingRepository extends Repository {
  OnboardingRepository(super.client);

  static const _appSelect = '*, stations(name, city, state), businesses(legal_name, display_name)';

  Future<StationApplication?> applicationForStation(String stationId) =>
      maybeRow(client.from('station_applications').select(_appSelect).eq('station_id', stationId).maybeSingle(),
          StationApplication.fromJson);

  Future<StationApplication> application(String id) =>
      row(client.from('station_applications').select(_appSelect).eq('id', id).single(), StationApplication.fromJson);

  /// Review queue, oldest submission first so nothing waits unfairly.
  Future<List<StationApplication>> queue({Set<ApplicationStatus>? statuses, String? search}) {
    var q = client.from('station_applications').select(_appSelect);
    if (statuses != null && statuses.isNotEmpty) q = q.inFilter('status', statuses.map((s) => s.wire).toList());
    return rows(q.order('submitted_at', ascending: true, nullsFirst: false).limit(200), StationApplication.fromJson).then(
      (list) {
        final s = search?.trim().toLowerCase();
        if (s == null || s.isEmpty) return list;
        return list
            .where((a) => [a.stationName, a.businessName, a.city, a.state].any((v) => (v ?? '').toLowerCase().contains(s)))
            .toList();
      },
    );
  }

  Future<List<ApplicationEvent>> events(String applicationId) => rows(
        client.from('application_events').select().eq('application_id', applicationId).order('created_at'),
        ApplicationEvent.fromJson,
      );

  Future<List<ChecklistItem>> checklist(String applicationId) async {
    final list = await rpc<List<dynamic>>('application_document_checklist', {'p_application_id': applicationId});
    return list.map(ChecklistItem.fromJson).toList();
  }

  Future<StationApplication> submit(String applicationId) => _transition('submit_station_application', applicationId);
  Future<StationApplication> startReview(String applicationId) => _transition('start_application_review', applicationId);
  Future<StationApplication> requestInformation(String applicationId, String note) =>
      _transition('request_application_information', applicationId, {'p_note': note});
  Future<StationApplication> approve(String applicationId, {String? note}) =>
      _transition('approve_station_application', applicationId, {'p_note': note});
  Future<StationApplication> reject(String applicationId, String reason, {required bool allowResubmission}) =>
      _transition('reject_station_application', applicationId, {'p_reason': reason, 'p_allow_resubmission': allowResubmission});

  Future<StationApplication> _transition(String fn, String applicationId, [Map<String, dynamic> extra = const {}]) async {
    await rpc<Object?>(fn, {'p_application_id': applicationId, ...extra});
    return application(applicationId);
  }

  // ---- Documents ----------------------------------------------------------------

  Future<List<DocumentType>> documentTypes({bool activeOnly = true}) {
    var q = client.from('document_types').select();
    if (activeOnly) q = q.eq('is_active', true);
    return rows(q.order('sort_order'), DocumentType.fromJson);
  }

  Future<void> saveDocumentType(Map<String, Object?> fields, {String? id}) => guard(() async {
        if (id == null) {
          await client.from('document_types').insert(fields);
        } else {
          await client.from('document_types').update(fields).eq('id', id);
        }
      });

  /// Business-level documents plus those of [stationId], newest first.
  Future<List<StationDocument>> documents(String businessId, {String? stationId}) {
    var q = client.from('station_documents').select('*, document_types(name)').eq('business_id', businessId);
    if (stationId != null) q = q.or('station_id.is.null,station_id.eq.$stationId');
    return rows(q.order('created_at', ascending: false), StationDocument.fromJson);
  }

  Future<List<Map<String, dynamic>>> documentReviews(String documentId) => guard(() =>
      client.from('document_reviews').select().eq('document_id', documentId).order('created_at', ascending: false));

  /// Uploads to private storage, then records the document. The database
  /// re-validates type, size, expiry and path; a failed insert removes the
  /// orphaned object.
  Future<void> uploadDocument({
    required String businessId,
    String? stationId,
    required DocumentType type,
    required Uint8List bytes,
    required String fileName,
    DateTime? issuedOn,
    DateTime? expiresOn,
  }) =>
      guard(() async {
        final mime = StoragePaths.mimeFor(fileName);
        if (!type.allowedMimeTypes.contains(mime)) {
          throw const AppFailure(FailureKind.validation, 'invalid_file_type', 'This file type is not accepted for this document.');
        }
        if (bytes.length > type.maxSizeBytes) {
          throw const AppFailure(FailureKind.validation, 'file_too_large', 'The file is too large.');
        }
        final scopedStation = type.scope == DocumentScope.station ? stationId : null;
        final path = StoragePaths.document(businessId: businessId, stationId: scopedStation, fileName: fileName);
        final bucket = client.storage.from(StoragePaths.documentsBucket);
        await bucket.uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));
        try {
          await client.from('station_documents').insert({
            'business_id': businessId,
            'station_id': scopedStation,
            'document_type_id': type.id,
            'storage_path': path,
            'file_name': fileName,
            'mime_type': mime,
            'size_bytes': bytes.length,
            if (issuedOn != null) 'issued_on': Repository.date(issuedOn),
            if (expiresOn != null) 'expires_on': Repository.date(expiresOn),
          });
        } catch (_) {
          await bucket.remove([path]).catchError((_) => <FileObject>[]);
          rethrow;
        }
      });

  /// Short-lived link for viewing a private document.
  Future<String> documentUrl(String storagePath, {Duration ttl = const Duration(minutes: 5)}) =>
      guard(() => client.storage.from(StoragePaths.documentsBucket).createSignedUrl(storagePath, ttl.inSeconds));

  Future<void> reviewDocument(String documentId, DocumentStatus decision, {String? comment}) =>
      rpc<Object?>('review_document', {'p_document_id': documentId, 'p_decision': decision.wire, 'p_comment': comment});

  // ---- Change requests (admin side) --------------------------------------------

  Future<List<Map<String, dynamic>>> pendingChangeRequests() => guard(() => client
      .from('station_change_requests')
      .select('*, stations(name, city, business_id)')
      .eq('status', 'pending')
      .order('created_at'));

  Future<void> decideChange(String requestId, {required bool approve, String? note}) =>
      rpc<void>('decide_station_change', {'p_request_id': requestId, 'p_approve': approve, 'p_note': note});
}
