import 'package:meta/meta.dart';

import 'enums.dart';
import 'json.dart';

@immutable
class StationApplication {
  const StationApplication({
    required this.id,
    required this.stationId,
    required this.businessId,
    required this.status,
    required this.revision,
    required this.resubmissionAllowed,
    required this.createdAt,
    this.submittedAt,
    this.reviewerId,
    this.reviewStartedAt,
    this.decidedAt,
    this.latestFeedback,
    this.stationName,
    this.businessName,
    this.city,
    this.state,
  });

  factory StationApplication.fromJson(Object? json) {
    final j = Json.of(json);
    final station = j.objectOrNull('stations');
    final business = j.objectOrNull('businesses');
    return StationApplication(
      id: j.str('id'),
      stationId: j.str('station_id'),
      businessId: j.str('business_id'),
      status: ApplicationStatus.parse(j.strOrNull('status')),
      revision: j.integer('revision', 0),
      submittedAt: j.dateTimeOrNull('submitted_at'),
      reviewerId: j.strOrNull('reviewer_id'),
      reviewStartedAt: j.dateTimeOrNull('review_started_at'),
      decidedAt: j.dateTimeOrNull('decided_at'),
      latestFeedback: j.strOrNull('latest_feedback'),
      resubmissionAllowed: j.boolean('resubmission_allowed', true),
      createdAt: j.dateTime('created_at'),
      stationName: station?.strOrNull('name'),
      city: station?.strOrNull('city'),
      state: station?.strOrNull('state'),
      businessName: business?.strOrNull('display_name') ?? business?.strOrNull('legal_name'),
    );
  }

  final String id;
  final String stationId;
  final String businessId;
  final ApplicationStatus status;
  final int revision;
  final DateTime? submittedAt;
  final String? reviewerId;
  final DateTime? reviewStartedAt;
  final DateTime? decidedAt;
  final String? latestFeedback;
  final bool resubmissionAllowed;
  final DateTime createdAt;
  final String? stationName;
  final String? businessName;
  final String? city;
  final String? state;

  bool get canResubmit => status.ownerCanSubmit && (status != ApplicationStatus.rejected || resubmissionAllowed);
}

@immutable
class ApplicationEvent {
  const ApplicationEvent({required this.id, required this.toStatus, required this.createdAt, this.fromStatus, this.note});

  factory ApplicationEvent.fromJson(Object? json) {
    final j = Json.of(json);
    return ApplicationEvent(
      id: j.integer('id'),
      fromStatus: j['from_status'] == null ? null : ApplicationStatus.parse(j.strOrNull('from_status')),
      toStatus: ApplicationStatus.parse(j.strOrNull('to_status')),
      note: j.strOrNull('note'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final int id;
  final ApplicationStatus? fromStatus;
  final ApplicationStatus toStatus;
  final String? note;
  final DateTime createdAt;
}

@immutable
class DocumentType {
  const DocumentType({
    required this.id,
    required this.code,
    required this.name,
    required this.scope,
    required this.isRequired,
    required this.allowedMimeTypes,
    required this.maxSizeBytes,
    required this.requiresExpiryDate,
    required this.isActive,
    required this.expirySuspendsStation,
    this.description,
    this.reminderDaysBefore = const [30, 7],
    this.sortOrder = 0,
  });

  factory DocumentType.fromJson(Object? json) {
    final j = Json.of(json);
    return DocumentType(
      id: j.str('id'),
      code: j.str('code'),
      name: j.str('name'),
      description: j.strOrNull('description'),
      scope: DocumentScope.parse(j.strOrNull('scope')),
      isRequired: j.boolean('is_required'),
      allowedMimeTypes: j.strings('allowed_mime_types'),
      maxSizeBytes: j.integer('max_size_bytes', 10485760),
      requiresExpiryDate: j.boolean('requires_expiry_date'),
      reminderDaysBefore: j.strings('reminder_days_before').map(int.parse).toList(),
      expirySuspendsStation: j.boolean('expiry_suspends_station'),
      isActive: j.boolean('is_active', true),
      sortOrder: j.integer('sort_order', 0),
    );
  }

  final String id;
  final String code;
  final String name;
  final String? description;
  final DocumentScope scope;
  final bool isRequired;
  final List<String> allowedMimeTypes;
  final int maxSizeBytes;
  final bool requiresExpiryDate;
  final List<int> reminderDaysBefore;
  final bool expirySuspendsStation;
  final bool isActive;
  final int sortOrder;
}

@immutable
class StationDocument {
  const StationDocument({
    required this.id,
    required this.businessId,
    required this.documentTypeId,
    required this.storagePath,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.status,
    required this.createdAt,
    this.stationId,
    this.expiresOn,
    this.reviewNote,
    this.reviewedAt,
    this.documentTypeName,
  });

  factory StationDocument.fromJson(Object? json) {
    final j = Json.of(json);
    return StationDocument(
      id: j.str('id'),
      businessId: j.str('business_id'),
      stationId: j.strOrNull('station_id'),
      documentTypeId: j.str('document_type_id'),
      storagePath: j.str('storage_path'),
      fileName: j.str('file_name'),
      mimeType: j.str('mime_type'),
      sizeBytes: j.integer('size_bytes'),
      status: DocumentStatus.parse(j.strOrNull('status')),
      expiresOn: j.dateOrNull('expires_on'),
      reviewNote: j.strOrNull('review_note'),
      reviewedAt: j.dateTimeOrNull('reviewed_at'),
      createdAt: j.dateTime('created_at'),
      documentTypeName: j.objectOrNull('document_types')?.strOrNull('name'),
    );
  }

  final String id;
  final String businessId;
  final String? stationId;
  final String documentTypeId;
  final String storagePath;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final DocumentStatus status;
  final DateTime? expiresOn;
  final String? reviewNote;
  final DateTime? reviewedAt;
  final DateTime createdAt;
  final String? documentTypeName;

  bool get isImage => mimeType.startsWith('image/');
}

/// One row of application_document_checklist().
@immutable
class ChecklistItem {
  const ChecklistItem({
    required this.documentTypeId,
    required this.code,
    required this.name,
    required this.scope,
    required this.isRequired,
    this.documentId,
    this.documentStatus,
    this.expiresOn,
  });

  factory ChecklistItem.fromJson(Object? json) {
    final j = Json.of(json);
    return ChecklistItem(
      documentTypeId: j.str('document_type_id'),
      code: j.str('code'),
      name: j.str('name'),
      scope: DocumentScope.parse(j.strOrNull('scope')),
      isRequired: j.boolean('is_required'),
      documentId: j.strOrNull('document_id'),
      documentStatus: j['document_status'] == null ? null : DocumentStatus.parse(j.strOrNull('document_status')),
      expiresOn: j.dateOrNull('expires_on'),
    );
  }

  final String documentTypeId;
  final String code;
  final String name;
  final DocumentScope scope;
  final bool isRequired;
  final String? documentId;
  final DocumentStatus? documentStatus;
  final DateTime? expiresOn;

  /// Mirrors the submit check in submit_station_application().
  bool get blocksSubmission =>
      isRequired && (documentId == null || (documentStatus?.needsAction ?? true));

  bool get blocksApproval => isRequired && documentStatus != DocumentStatus.approved;
}

@immutable
class StationChangeRequest {
  const StationChangeRequest({
    required this.id,
    required this.stationId,
    required this.changes,
    required this.status,
    required this.createdAt,
    this.note,
    this.reviewNote,
  });

  factory StationChangeRequest.fromJson(Object? json) {
    final j = Json.of(json);
    return StationChangeRequest(
      id: j.str('id'),
      stationId: j.str('station_id'),
      changes: Json.of(j['changes']).map,
      note: j.strOrNull('note'),
      status: j.str('status'),
      reviewNote: j.strOrNull('review_note'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final String id;
  final String stationId;
  final Map<String, dynamic> changes;
  final String? note;
  final String status;
  final String? reviewNote;
  final DateTime createdAt;
}
