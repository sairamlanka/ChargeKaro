import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state.dart';
import 'availability_tab.dart';
import 'documents_tab.dart';
import 'maintenance_tab.dart';
import 'points_tab.dart';

class StationDetailPage extends ConsumerWidget {
  const StationDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final station = ref.watch(stationProvider(id));
    final access = ref.watch(currentAccessProvider);
    final canEdit = access?.can(BusinessPermission.stationEdit, stationId: id) ?? false;
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(station.value?.name ?? 'Station'),
          actions: [
            if (canEdit) IconButton(tooltip: 'Edit details', icon: const Icon(Icons.edit_outlined), onPressed: () => context.go('/stations/$id/edit')),
          ],
          bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: 'Overview'),
            Tab(text: 'Charging points'),
            Tab(text: 'Availability'),
            Tab(text: 'Documents'),
            Tab(text: 'Maintenance'),
          ]),
        ),
        body: AsyncView(
          value: station,
          onRetry: () => ref.invalidate(stationProvider(id)),
          builder: (s) => TabBarView(children: [
            _Overview(s),
            PointsTab(station: s),
            AvailabilityTab(station: s),
            DocumentsTab(station: s),
            MaintenanceTab(station: s),
          ]),
        ),
      ),
    );
  }
}

class _Overview extends ConsumerWidget {
  const _Overview(this.s);
  final Station s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(applicationProvider(s.id));
    final access = ref.watch(currentAccessProvider);
    final isOwner = access?.isOwner ?? false;
    final canEdit = access?.can(BusinessPermission.stationEdit, stationId: s.id) ?? false;
    final changes = ref.watch(_changesProvider(s.id));
    void refresh() {
      ref.invalidate(stationProvider(s.id));
      ref.invalidate(applicationProvider(s.id));
      ref.invalidate(_changesProvider(s.id));
      ref.invalidate(stationsProvider);
    }

    return RefreshIndicator(
      onRefresh: () async => refresh(),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        AsyncView(
          value: app,
          builder: (a) => a == null ? const SizedBox.shrink() : _ApplicationCard(station: s, app: a, canSubmit: isOwner, onChanged: refresh),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Status',
          trailing: StatusChip.station(s.status),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (s.statusReason != null) Text(s.statusReason!),
            if (s.closedUntil != null) Text('Closed until ${Fmt.dateTime(s.closedUntil!)}'),
            if (s.deactivationRequestedAt != null) const Text('Deactivation requested. ChargeKaro will confirm.'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (canEdit && s.status == StationStatus.active)
                OutlinedButton.icon(icon: const Icon(Icons.pause_circle_outline), label: const Text('Close temporarily'), onPressed: () => _close(context, ref, refresh)),
              if (canEdit && s.status == StationStatus.temporarilyClosed)
                FilledButton.icon(
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Reopen now'),
                  onPressed: () async {
                    if (await runAction(context, () => ref.read(stationRepositoryProvider).reopen(s.id), success: 'Station reopened.')) refresh();
                  },
                ),
              if (isOwner && s.isApproved && s.status != StationStatus.deactivated && s.deactivationRequestedAt == null)
                TextButton(
                  onPressed: () async {
                    final reason = await confirmWithReason(context,
                        title: 'Request deactivation',
                        message: 'ChargeKaro reviews the request. Existing bookings stay until it is confirmed.',
                        confirmLabel: 'Send request',
                        reasonLabel: 'Reason',
                        destructive: true);
                    if (reason == null || !context.mounted) return;
                    if (await runAction(context, () => ref.read(stationRepositoryProvider).requestDeactivation(s.id, reason), success: 'Request sent.')) {
                      refresh();
                    }
                  },
                  child: const Text('Request deactivation'),
                ),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Details',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.fullAddress),
            TextButton.icon(
              icon: const Icon(Icons.directions),
              label: const Text('Open in Google Maps'),
              onPressed: () => launchUrl(s.mapsUri, mode: LaunchMode.externalApplication),
            ),
            KeyValue('Phone', s.contactPhone),
            KeyValue('Emergency', [s.emergencyContactName, s.emergencyContactPhone].whereType<String>().join(' · ')),
            KeyValue('Parking', '${s.parkingSpaces} spaces'),
            KeyValue('Amenities', s.amenities.map((a) => a.label).join(', ')),
            KeyValue('Payment at station', s.acceptedPaymentMethods.map((p) => p.label).join(', ')),
          ]),
        ),
        const SizedBox(height: 16),
        AsyncView(
          value: changes,
          builder: (list) => list.isEmpty
              ? const SizedBox.shrink()
              : SectionCard(
                  title: 'Change requests',
                  child: Column(children: [
                    for (final c in list)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(c.changes.keys.join(', ')),
                        subtitle: Text([Fmt.date(c.createdAt), if (c.reviewNote != null) c.reviewNote!].join(' · ')),
                        trailing: StatusChip(c.status,
                            tone: switch (c.status) { 'approved' => StatusTone.success, 'rejected' => StatusTone.danger, _ => StatusTone.info }),
                      ),
                  ]),
                ),
        ),
      ]),
    );
  }

  Future<void> _close(BuildContext context, WidgetRef ref, VoidCallback refresh) async {
    final until = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 90)),
      helpText: 'Closed until (reopens at the start of this day)',
    );
    if (until == null || !context.mounted) return;
    final reason = await confirmWithReason(context,
        title: 'Close until ${Fmt.dateOnly(until)}',
        message: 'New bookings stop. If confirmed bookings fall in this period you will be asked whether to cancel them.',
        confirmLabel: 'Close station',
        reasonLabel: 'Reason shown to customers');
    if (reason == null || !context.mounted) return;
    final repo = ref.read(stationRepositoryProvider);
    final untilUtc = Fmt.fromIst(until.year, until.month, until.day);
    try {
      await repo.closeTemporarily(s.id, until: untilUtc, reason: reason);
      refresh();
    } on AppFailure catch (f) {
      if (f.code != 'bookings_conflict' || !context.mounted) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(f.message)));
        return;
      }
      final cancel = await confirm(context,
          title: 'Cancel affected bookings?',
          message: '${f.detail ?? 'Some confirmed bookings'} fall in this period. Cancelling notifies customers; their booking fee is refunded under the platform refund policy.',
          confirmLabel: 'Cancel them and close',
          destructive: true);
      if (!cancel || !context.mounted) return;
      if (await runAction(context, () => repo.closeTemporarily(s.id, until: untilUtc, reason: reason, cancelConflicting: true), success: 'Station closed.')) {
        refresh();
      }
    }
  }
}

final _changesProvider = FutureProvider.autoDispose.family<List<StationChangeRequest>, String>(
    (ref, id) => ref.watch(stationRepositoryProvider).changeRequests(id));

/// Onboarding progress and the submit action.
class _ApplicationCard extends ConsumerWidget {
  const _ApplicationCard({required this.station, required this.app, required this.canSubmit, required this.onChanged});
  final Station station;
  final StationApplication app;
  final bool canSubmit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (app.status == ApplicationStatus.approved && station.isApproved) return const SizedBox.shrink();
    final points = ref.watch(pointsProvider(station.id)).value ?? const [];
    final hours = ref.watch(hoursProvider(station.id)).value ?? const [];
    final checklist = ref.watch(_checklistProvider(app.id)).value ?? const [];
    final docsReady = checklist.isNotEmpty && !checklist.any((c) => c.blocksSubmission);
    final steps = [
      ('Station details', true),
      ('At least one charging point', points.isNotEmpty),
      ('Operating hours', hours.isNotEmpty),
      ('Required documents uploaded', docsReady),
    ];
    final ready = steps.every((s) => s.$2);
    return SectionCard(
      title: 'Onboarding',
      trailing: StatusChip.application(app.status),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (app.latestFeedback != null && app.status != ApplicationStatus.submitted)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(AppTheme.fieldRadius)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.forum_outlined, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('Reviewer feedback: ${app.latestFeedback}')),
            ]),
          ),
        if (app.status.ownerCanSubmit) ...[
          Row(children: [
            Expanded(child: Text(ready ? 'Ready to submit' : 'Finish these steps to go live', style: Theme.of(context).textTheme.titleSmall)),
            Text('${steps.where((s) => s.$2).length} of ${steps.length}', style: Theme.of(context).textTheme.labelLarge),
          ]),
          const SizedBox(height: 10),
          GradientProgressBar(value: steps.where((s) => s.$2).length / steps.length, semanticsLabel: 'Onboarding progress'),
          const SizedBox(height: 8),
          for (final (i, (label, done)) in steps.indexed)
            Entrance(
              index: i,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: AnimatedSwitcher(
                  duration: Motion.medium,
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: done
                      ? Icon(Icons.check_circle_rounded, key: const ValueKey(true), color: Theme.of(context).colorScheme.primary)
                      : Icon(Icons.radio_button_unchecked_rounded, key: const ValueKey(false), color: Theme.of(context).colorScheme.outline),
                ),
                title: Text(
                  label,
                  style: TextStyle(
                    decoration: done ? TextDecoration.lineThrough : null,
                    color: done ? Theme.of(context).colorScheme.onSurfaceVariant : null,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (canSubmit)
            GradientButton(
              icon: Icons.send_rounded,
              onPressed: !ready || !app.canResubmit
                  ? null
                  : () async {
                      final ok = await confirm(context,
                          title: 'Submit for review',
                          message: 'ChargeKaro checks your documents and location. You will be notified of the decision.',
                          confirmLabel: 'Submit');
                      if (!ok || !context.mounted) return;
                      if (await runAction(context, () => ref.read(onboardingRepositoryProvider).submit(app.id), success: 'Submitted for review.')) {
                        onChanged();
                      }
                    },
              label: app.status == ApplicationStatus.draft ? 'Submit for review' : 'Resubmit',
            ),
          if (app.status == ApplicationStatus.rejected && !app.resubmissionAllowed) const Text('This application cannot be resubmitted.'),
        ] else if (app.status.awaitingReview)
          Row(children: [
            const PulseDot(size: 9),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('In review. A ChargeKaro reviewer is checking your documents and location. You can still add charging points.'),
            ),
          ]),
      ]),
    );
  }
}

final _checklistProvider = FutureProvider.autoDispose.family<List<ChecklistItem>, String>(
    (ref, id) => ref.watch(onboardingRepositoryProvider).checklist(id));
