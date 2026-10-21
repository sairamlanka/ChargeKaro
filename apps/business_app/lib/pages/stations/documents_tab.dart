import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state.dart';

typedef _Docs = ({List<DocumentType> types, List<StationDocument> docs, StationApplication? app, List<ChecklistItem> checklist});

final _docsProvider = FutureProvider.autoDispose.family<_Docs, ({String id, String businessId})>((ref, s) async {
  final repo = ref.watch(onboardingRepositoryProvider);
  final app = await repo.applicationForStation(s.id);
  final results = await Future.wait<Object>([
    repo.documentTypes(),
    repo.documents(s.businessId, stationId: s.id),
    if (app != null) repo.checklist(app.id) else Future.value(<ChecklistItem>[]),
  ]);
  return (
    types: results[0] as List<DocumentType>,
    docs: results[1] as List<StationDocument>,
    app: app,
    checklist: results[2] as List<ChecklistItem>,
  );
});

/// Compliance documents. Files go to private storage; only this business and
/// platform reviewers can open them, through short-lived links.
class DocumentsTab extends ConsumerWidget {
  const DocumentsTab({super.key, required this.station});
  final Station station;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canManage = ref.watch(currentAccessProvider)?.can(BusinessPermission.documentsManage, stationId: station.id) ?? false;
    void refresh() {
      ref.invalidate(_docsProvider((id: station.id, businessId: station.businessId)));
      ref.invalidate(applicationProvider(station.id));
    }

    return AsyncView(
      value: ref.watch(_docsProvider((id: station.id, businessId: station.businessId))),
      onRetry: refresh,
      builder: (d) {
        final current = <String, StationDocument>{};
        for (final doc in d.docs) {
          if (doc.status == DocumentStatus.superseded) continue;
          current.putIfAbsent(doc.documentTypeId, () => doc);
        }
        return RefreshIndicator(
          onRefresh: () async => refresh(),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Text('PDF, JPG or PNG. Business documents are shared by all your stations.'),
            const SizedBox(height: 8),
            for (final t in d.types)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text('${t.name}${t.isRequired ? '' : ' (optional)'}', style: Theme.of(context).textTheme.titleSmall),
                      ),
                      if (current[t.id] != null) StatusChip.document(current[t.id]!.status) else if (t.isRequired) const StatusChip('Missing', tone: StatusTone.warning),
                    ]),
                    if (t.description != null) Text(t.description!, style: Theme.of(context).textTheme.bodySmall),
                    Text('${t.scope.label} document', style: Theme.of(context).textTheme.bodySmall),
                    if (current[t.id] case final doc?) ...[
                      const SizedBox(height: 4),
                      Text('${doc.fileName} · ${Fmt.fileSize(doc.sizeBytes)} · uploaded ${Fmt.date(doc.createdAt)}'),
                      if (doc.expiresOn != null) Text('Expires ${Fmt.dateOnly(doc.expiresOn!)}'),
                      if (doc.reviewNote != null)
                        Text('Reviewer: ${doc.reviewNote}', style: TextStyle(color: doc.status.needsAction ? Theme.of(context).colorScheme.error : null)),
                    ],
                    Wrap(spacing: 8, children: [
                      if (current[t.id] case final doc?)
                        TextButton(
                          onPressed: () => runAction(context, () async {
                            final url = await ref.read(onboardingRepositoryProvider).documentUrl(doc.storagePath);
                            await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                          }),
                          child: const Text('View'),
                        ),
                      if (canManage)
                        TextButton(
                          onPressed: () async {
                            if (await _upload(context, ref, t)) refresh();
                          },
                          child: Text(current[t.id] == null ? 'Upload' : 'Replace'),
                        ),
                    ]),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
  }

  Future<bool> _upload(BuildContext context, WidgetRef ref, DocumentType type) async {
    final exts = [
      for (final m in type.allowedMimeTypes) ...switch (m) {
        'application/pdf' => ['pdf'],
        'image/jpeg' => ['jpg', 'jpeg'],
        'image/png' => ['png'],
        'image/webp' => ['webp'],
        _ => <String>[],
      },
    ];
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: exts);
    if (file == null || !context.mounted) return false;
    DateTime? expires;
    if (type.requiresExpiryDate) {
      expires = await showDatePicker(
        context: context,
        helpText: 'Expiry date on the document',
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 365 * 30)),
      );
      if (expires == null) return false;
    }
    if (!context.mounted) return false;
    final bytes = await file.readAsBytes();
    if (!context.mounted) return false;
    return runAction(
      context,
      () => ref.read(onboardingRepositoryProvider).uploadDocument(
            businessId: station.businessId,
            stationId: station.id,
            type: type,
            bytes: bytes,
            fileName: file.name,
            expiresOn: expires,
          ),
      success: 'Uploaded. It will be checked when your application is reviewed.',
    );
  }
}
