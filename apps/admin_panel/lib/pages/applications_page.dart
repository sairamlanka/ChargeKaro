import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../shell.dart';

typedef _QueueArgs = ({String filter, String search});

const _filters = <String, Set<ApplicationStatus>>{
  'Needs review': {ApplicationStatus.submitted, ApplicationStatus.underReview},
  'Waiting on business': {ApplicationStatus.additionalInformationRequired},
  'Approved': {ApplicationStatus.approved},
  'Rejected': {ApplicationStatus.rejected},
  'All': {},
};

final _queueProvider = FutureProvider.autoDispose.family<List<StationApplication>, _QueueArgs>(
  (ref, a) => ref.watch(onboardingRepositoryProvider).queue(statuses: _filters[a.filter], search: a.search),
);

class ApplicationsPage extends ConsumerStatefulWidget {
  const ApplicationsPage({super.key});

  @override
  ConsumerState<ApplicationsPage> createState() => _ApplicationsPageState();
}

class _ApplicationsPageState extends ConsumerState<ApplicationsPage> {
  String _filter = 'Needs review';
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final args = (filter: _filter, search: _search);
    final data = ref.watch(_queueProvider(args));
    return PageFrame(
      title: 'Station applications',
      scroll: false,
      actions: [
        SizedBox(
          width: 260,
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Station, business, city'),
            onSubmitted: (v) => setState(() => _search = v),
          ),
        ),
        IconButton(tooltip: 'Refresh', onPressed: () => ref.invalidate(_queueProvider(args)), icon: const Icon(Icons.refresh)),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, children: [
          for (final f in _filters.keys)
            ChoiceChip(label: Text(f), selected: _filter == f, onSelected: (_) => setState(() => _filter = f)),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: AsyncView(
            value: data,
            onRetry: () => ref.invalidate(_queueProvider(args)),
            builder: (list) => list.isEmpty
                ? const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing here', message: 'No applications match this filter.')
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final a = list[i];
                      final waited = a.submittedAt == null ? null : DateTime.now().difference(a.submittedAt!);
                      return ListTile(
                        title: Text(a.stationName ?? 'Station'),
                        subtitle: Text([
                          a.businessName ?? '',
                          [a.city, a.state].whereType<String>().join(', '),
                          if (a.submittedAt != null) 'submitted ${Fmt.relative(a.submittedAt!)}',
                          if (a.revision > 1) 'revision ${a.revision}',
                        ].where((s) => s.isNotEmpty).join(' · ')),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (waited != null && waited.inDays >= 3 && a.status.awaitingReview)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: StatusChip('Waiting ${waited.inDays} d', tone: StatusTone.warning),
                            ),
                          StatusChip.application(a.status),
                        ]),
                        onTap: () => context.go('/applications/${a.id}'),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}
