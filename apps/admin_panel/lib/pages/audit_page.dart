import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../shell.dart';

typedef _Args = ({String? entityType, String action, int page});

final _auditProvider = FutureProvider.autoDispose.family<List<AuditEntry>, _Args>(
  (ref, a) => ref.watch(adminRepositoryProvider).audit(entityType: a.entityType, action: a.action, limit: 100, offset: a.page * 100),
);

const _entityTypes = [
  'platform_settings', 'platform_staff', 'businesses', 'stations', 'station_applications', 'station_documents',
  'bookings', 'refunds', 'platform_expenses', 'charging_points',
];

/// Append-only audit trail. Sensitive fields are redacted when written.
class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});

  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
  String? _entity;
  String _action = '';
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final args = (entityType: _entity, action: _action, page: _page);
    return RequiresPermission(
      PlatformPermission.auditRead,
      child: PageFrame(
        title: 'Audit log',
        scroll: false,
        actions: [
          DropdownButton<String?>(
            value: _entity,
            hint: const Text('Any entity'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Any entity')),
              for (final e in _entityTypes) DropdownMenuItem(value: e, child: Text(e)),
            ],
            onChanged: (v) => setState(() {
              _entity = v;
              _page = 0;
            }),
          ),
          SizedBox(
            width: 200,
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Action'),
              onSubmitted: (v) => setState(() {
                _action = v;
                _page = 0;
              }),
            ),
          ),
          IconButton(onPressed: _page == 0 ? null : () => setState(() => _page--), icon: const Icon(Icons.chevron_left)),
          Text('Page ${_page + 1}'),
          IconButton(onPressed: () => setState(() => _page++), icon: const Icon(Icons.chevron_right)),
        ],
        child: AsyncView(
          value: ref.watch(_auditProvider(args)),
          onRetry: () => ref.invalidate(_auditProvider(args)),
          builder: (list) => list.isEmpty
              ? const EmptyState(icon: Icons.history, title: 'No entries')
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = list[i];
                    return ExpansionTile(
                      title: Text('${e.action} · ${e.entityType}'),
                      subtitle: Text([Fmt.dateTime(e.occurredAt), e.actorKind, if (e.actorId != null) e.actorId!, if (e.reason != null) 'reason: ${e.reason}'].join(' · ')),
                      children: [
                        if (e.before != null || e.after != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(
                              const JsonEncoder.withIndent('  ').convert({'entity_id': e.entityId, 'before': e.before, 'after': e.after}),
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}
