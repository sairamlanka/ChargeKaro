import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shell.dart';

class _Review {
  const _Review(this.app, this.station, this.business, this.points, this.hours, this.checklist, this.documents, this.events);
  final StationApplication app;
  final Station station;
  final Business business;
  final List<ChargingPoint> points;
  final List<OperatingHours> hours;
  final List<ChecklistItem> checklist;
  final List<StationDocument> documents;
  final List<ApplicationEvent> events;
}

final _reviewProvider = FutureProvider.autoDispose.family<_Review, String>((ref, id) async {
  final onboarding = ref.watch(onboardingRepositoryProvider);
  final stations = ref.watch(stationRepositoryProvider);
  final app = await onboarding.application(id);
  final results = await Future.wait<Object>([
    stations.station(app.stationId),
    stations.business(app.businessId),
    stations.points(app.stationId),
    stations.hours(app.stationId),
    onboarding.checklist(id),
    onboarding.documents(app.businessId, stationId: app.stationId),
    onboarding.events(id),
  ]);
  return _Review(
    app,
    results[0] as Station,
    results[1] as Business,
    results[2] as List<ChargingPoint>,
    results[3] as List<OperatingHours>,
    results[4] as List<ChecklistItem>,
    results[5] as List<StationDocument>,
    results[6] as List<ApplicationEvent>,
  );
});

class ApplicationDetailPage extends ConsumerWidget {
  const ApplicationDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_reviewProvider(id));
    return PageFrame(
      title: data.value?.station.name ?? 'Application',
      actions: [
        TextButton.icon(onPressed: () => context.go('/applications'), icon: const Icon(Icons.arrow_back), label: const Text('Queue')),
      ],
      child: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_reviewProvider(id)),
        builder: (r) => _ReviewBody(r, refresh: () => ref.invalidate(_reviewProvider(id))),
      ),
    );
  }
}

class _ReviewBody extends ConsumerWidget {
  const _ReviewBody(this.r, {required this.refresh});
  final _Review r;
  final VoidCallback refresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = r.station;
    final b = r.business;
    final wide = MediaQuery.sizeOf(context).width > 1200;
    final left = Column(children: [
      _Actions(r, refresh: refresh),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Business',
        trailing: b.isDemo ? const DemoBadge() : StatusChip.business(b.status),
        child: Column(children: [
          KeyValue('Legal name', b.legalName),
          KeyValue('Type', b.businessType.label),
          KeyValue('Owner', b.ownerFullName),
          KeyValue('Phone', b.contactPhone),
          KeyValue('Email', b.contactEmail),
          KeyValue('Registration no.', b.registrationNumber),
          KeyValue('GSTIN', b.gstin),
          KeyValue('Registered address', [b.registeredAddressLine1, b.registeredAddressLine2, b.registeredCity, b.registeredState, b.registeredPostalCode].whereType<String>().join(', ')),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Station',
        trailing: StatusChip.station(s.status),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          KeyValue('Address', [s.addressLine1, s.addressLine2, s.landmark, s.city, s.district, s.state, s.postalCode].whereType<String>().join(', ')),
          KeyValue('Coordinates', '${s.latitude.toStringAsFixed(6)}, ${s.longitude.toStringAsFixed(6)}'),
          KeyValue('Contact', s.contactPhone),
          KeyValue('Emergency contact', [s.emergencyContactName, s.emergencyContactPhone].whereType<String>().join(' · ')),
          KeyValue('Parking spaces', '${s.parkingSpaces}'),
          KeyValue('Amenities', s.amenities.map((a) => a.label).join(', ')),
          KeyValue('Payment at station', s.acceptedPaymentMethods.map((p) => p.label).join(', ')),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => launchUrl(s.mapsUri, webOnlyWindowName: '_blank'),
              icon: const Icon(Icons.map_outlined),
              label: const Text('Check location on Google Maps'),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Charging points (${r.points.length})',
        child: Column(children: [
          if (r.points.isEmpty) const Text('No charging points added.'),
          for (final p in r.points)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${p.code}${p.name == null ? '' : ' · ${p.name}'}'),
              subtitle: Text('${p.currentType.label} · ${p.maxPowerKw.toStringAsFixed(1)} kW · '
                  '${p.connectors.map((c) => c.type.label).join(', ')}'),
              trailing: StatusChip.point(p.operationalStatus),
            ),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Operating hours',
        child: r.hours.isEmpty
            ? const Text('No operating hours set.')
            : Wrap(spacing: 8, runSpacing: 8, children: [
                for (final h in r.hours.where((h) => h.chargingPointId == null)) Chip(label: Text('${h.dayName} ${h.label}')),
              ]),
      ),
    ]);
    final right = Column(children: [
      _Documents(r, refresh: refresh),
      const SizedBox(height: 16),
      _Timeline(r.events),
    ]);
    return wide
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: left),
            const SizedBox(width: 16),
            Expanded(child: right),
          ])
        : Column(children: [left, const SizedBox(height: 16), right]);
  }
}

class _Actions extends ConsumerWidget {
  const _Actions(this.r, {required this.refresh});
  final _Review r;
  final VoidCallback refresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(onboardingRepositoryProvider);
    final a = r.app;
    final blocking = r.checklist.where((c) => c.blocksApproval).toList();
    final canDecide = can(ref, PlatformPermission.applicationsDecide);
    final canAsk = can(ref, PlatformPermission.applicationsRequestInfo);

    Future<void> act(Future<void> Function() f, String done) async {
      if (await runAction(context, f, success: done)) refresh();
    }

    return SectionCard(
      title: 'Decision',
      trailing: StatusChip.application(a.status),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (a.latestFeedback != null) KeyValue('Latest feedback', a.latestFeedback),
        if (a.status == ApplicationStatus.underReview && blocking.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Approval needs every required document approved. Outstanding: ${blocking.map((c) => c.name).join(', ')}.'),
          ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (a.status == ApplicationStatus.submitted)
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start review'),
              onPressed: () => act(() => repo.startReview(a.id), 'Review started. You are the assigned reviewer.'),
            ),
          if (a.status == ApplicationStatus.underReview && canDecide)
            FilledButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('Approve'),
              onPressed: blocking.isNotEmpty
                  ? null
                  : () async {
                      final note = await confirmWithReason(context,
                          title: 'Approve station',
                          message: 'The station becomes active and can accept bookings. Its sensitive details will then '
                              'only change through reviewed change requests.',
                          confirmLabel: 'Approve',
                          reasonLabel: 'Approval note',
                          minReasonLength: 2);
                      if (note != null) await act(() => repo.approve(a.id, note: note), 'Station approved.');
                    },
            ),
          if (a.status == ApplicationStatus.underReview && canAsk)
            OutlinedButton.icon(
              icon: const Icon(Icons.help_outline),
              label: const Text('Request information'),
              onPressed: () async {
                final note = await confirmWithReason(context,
                    title: 'Request more information',
                    message: 'The business is notified and can resubmit after making changes.',
                    confirmLabel: 'Send request',
                    reasonLabel: 'What needs to change');
                if (note != null) await act(() => repo.requestInformation(a.id, note), 'Request sent to the business.');
              },
            ),
          if (a.status == ApplicationStatus.underReview && canDecide)
            OutlinedButton.icon(
              icon: const Icon(Icons.close),
              label: const Text('Reject'),
              onPressed: () => _reject(context, ref, act),
            ),
        ]),
        if (!a.status.awaitingReview && a.status != ApplicationStatus.draft)
          const Text('This application is not awaiting review.'),
        if (a.status == ApplicationStatus.draft) const Text('The business has not submitted this application yet.'),
      ]),
    );
  }

  Future<void> _reject(BuildContext context, WidgetRef ref, Future<void> Function(Future<void> Function(), String) act) async {
    var allow = true;
    final reason = await showDialog<String>(
      context: context,
      builder: (context) {
        final c = TextEditingController();
        return StatefulBuilder(
          builder: (context, set) => AlertDialog(
            title: const Text('Reject application'),
            content: SizedBox(
              width: 460,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: c,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Reason (shown to the business)'),
                  onChanged: (_) => set(() {}),
                ),
                CheckboxListTile(
                  value: allow,
                  onChanged: (v) => set(() => allow = v ?? true),
                  title: const Text('Allow the business to correct and resubmit'),
                  contentPadding: EdgeInsets.zero,
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                onPressed: c.text.trim().length < 5 ? null : () => Navigator.pop(context, c.text.trim()),
                child: const Text('Reject'),
              ),
            ],
          ),
        );
      },
    );
    if (reason != null) {
      await act(() => ref.read(onboardingRepositoryProvider).reject(r.app.id, reason, allowResubmission: allow), 'Application rejected.');
    }
  }
}

class _Documents extends ConsumerWidget {
  const _Documents(this.r, {required this.refresh});
  final _Review r;
  final VoidCallback refresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(onboardingRepositoryProvider);
    final canReview = can(ref, PlatformPermission.documentsReview) && r.app.status == ApplicationStatus.underReview;
    final docsById = {for (final d in r.documents) d.id: d};

    Future<void> review(StationDocument d, DocumentStatus decision) async {
      String? comment;
      if (decision != DocumentStatus.approved) {
        comment = await confirmWithReason(context,
            title: decision == DocumentStatus.rejected ? 'Reject document' : 'Ask for a correction',
            message: 'The business sees this comment and can upload a replacement.',
            confirmLabel: 'Save',
            reasonLabel: 'Comment');
        if (comment == null) return;
      }
      if (!context.mounted) return;
      if (await runAction(context, () => repo.reviewDocument(d.id, decision, comment: comment))) refresh();
    }

    return SectionCard(
      title: 'Documents',
      child: Column(children: [
        for (final c in r.checklist)
          Builder(builder: (context) {
            final d = c.documentId == null ? null : docsById[c.documentId];
            final t = Theme.of(context);
            // Status and actions sit under the text rather than beside it, so
            // the name keeps the full width on narrow screens.
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 16),
                  child: Icon(d == null ? Icons.description_outlined : (d.isImage ? Icons.image_outlined : Icons.picture_as_pdf_outlined)),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${c.name}${c.isRequired ? '' : ' (optional)'}', style: t.textTheme.bodyLarge),
                    Text(
                      [
                        c.scope.label,
                        if (d != null) '${d.fileName} · ${Fmt.fileSize(d.sizeBytes)}',
                        if (d?.expiresOn != null) 'expires ${Fmt.dateOnly(d!.expiresOn!)}',
                        if (d?.reviewNote != null) 'note: ${d!.reviewNote}',
                        if (d == null) 'not uploaded',
                      ].join(' · '),
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if (c.documentStatus != null) StatusChip.document(c.documentStatus!),
                      if (d != null)
                        IconButton(
                          tooltip: 'Open (link valid 5 minutes)',
                          icon: const Icon(Icons.open_in_new),
                          onPressed: () => runAction(context, () async {
                            final url = await repo.documentUrl(d.storagePath);
                            await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
                          }),
                        ),
                      if (d != null && canReview && d.status == DocumentStatus.pendingReview)
                        PopupMenuButton<DocumentStatus>(
                          tooltip: 'Review',
                          onSelected: (v) => review(d, v),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: DocumentStatus.approved, child: Text('Approve')),
                            PopupMenuItem(value: DocumentStatus.correctionRequired, child: Text('Ask for correction')),
                            PopupMenuItem(value: DocumentStatus.rejected, child: Text('Reject')),
                          ],
                        ),
                    ]),
                  ]),
                ),
              ]),
            );
          }),
        if (!canReview && r.app.status == ApplicationStatus.submitted)
          const Padding(padding: EdgeInsets.only(top: 8), child: Text('Start the review to approve or reject documents.')),
      ]),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline(this.events);
  final List<ApplicationEvent> events;

  @override
  Widget build(BuildContext context) => SectionCard(
        title: 'Timeline',
        child: Column(children: [
          for (final e in events.reversed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.circle, size: 10),
              title: Text(e.fromStatus == null ? e.toStatus.label : '${e.fromStatus!.label} → ${e.toStatus.label}'),
              subtitle: Text([Fmt.dateTime(e.createdAt), if (e.note != null) e.note!].join(' · ')),
            ),
        ]),
      );
}
