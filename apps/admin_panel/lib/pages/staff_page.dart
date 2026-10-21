import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../shell.dart';

final _staffProvider = FutureProvider.autoDispose<List<StaffMember>>((ref) => ref.watch(adminRepositoryProvider).staff());
final _permissionsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) => ref.watch(adminRepositoryProvider).permissions());

/// Platform staff management. Granting needs an existing account: people
/// sign up normally, then a super admin promotes them here. There is no
/// public admin registration.
class StaffPage extends ConsumerWidget {
  const StaffPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionUserIdProvider).value;
    return RequiresPermission(
      PlatformPermission.adminsManage,
      child: PageFrame(
        title: 'Platform admins',
        actions: [
          FilledButton.icon(
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Grant access'),
            onPressed: () async {
              if (await showDialog<bool>(context: context, builder: (_) => const _GrantDialog()) == true) ref.invalidate(_staffProvider);
            },
          ),
        ],
        child: AsyncView(
          value: ref.watch(_staffProvider),
          onRetry: () => ref.invalidate(_staffProvider),
          builder: (list) => Card(
            child: Column(children: [
              for (final s in list)
                ListTile(
                  title: Text(s.fullName ?? s.email ?? s.userId),
                  subtitle: Text([
                    s.email ?? '',
                    s.role.label,
                    if (s.overrides.isNotEmpty)
                      s.overrides.entries.map((e) => '${e.value ? '+' : '−'}${e.key}').join(' '),
                  ].where((t) => t.isNotEmpty).join(' · ')),
                  trailing: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    StatusChip(s.isActive ? 'Active' : 'Revoked', tone: s.isActive ? StatusTone.success : StatusTone.neutral),
                    if (s.userId != me && s.isActive) ...[
                      IconButton(
                        tooltip: 'Permission overrides',
                        icon: const Icon(Icons.tune),
                        onPressed: () async {
                          await showDialog<void>(context: context, builder: (_) => _OverridesDialog(member: s));
                          ref.invalidate(_staffProvider);
                        },
                      ),
                      IconButton(
                        tooltip: 'Revoke access',
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed: () async {
                          final reason = await confirmWithReason(context,
                              title: 'Revoke platform access',
                              message: '${s.email ?? 'This user'} loses admin access immediately.',
                              confirmLabel: 'Revoke',
                              reasonLabel: 'Reason',
                              destructive: true);
                          if (reason == null || !context.mounted) return;
                          if (await runAction(context, () => ref.read(adminRepositoryProvider).revokeRole(s.userId, reason))) {
                            ref.invalidate(_staffProvider);
                          }
                        },
                      ),
                    ],
                  ]),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _GrantDialog extends ConsumerStatefulWidget {
  const _GrantDialog();

  @override
  ConsumerState<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends ConsumerState<_GrantDialog> {
  final _email = TextEditingController();
  PlatformRole _role = PlatformRole.complianceReviewer;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roles = PlatformRole.values.where((r) => r != PlatformRole.superAdmin).toList();
    return AlertDialog(
      title: const Text('Grant platform access'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('The person must already have a ChargeKaro account. Super admin cannot be granted from the app.'),
          const SizedBox(height: 12),
          TextField(controller: _email, decoration: const InputDecoration(labelText: 'Account email'), onChanged: (_) => setState(() {})),
          const SizedBox(height: 12),
          DropdownButtonFormField<PlatformRole>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Role'),
            items: [for (final r in roles) DropdownMenuItem(value: r, child: Text(r.label))],
            onChanged: (v) => setState(() => _role = v ?? _role),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: Validators.email(_email.text) != null
              ? null
              : () async {
                  final repo = ref.read(adminRepositoryProvider);
                  final ok = await runAction(context, () async {
                    final id = await repo.findUserIdByEmail(_email.text);
                    if (id == null) {
                      throw const AppFailure(FailureKind.notFound, 'user_not_found', 'No account exists with that email. Ask them to sign up first.');
                    }
                    await repo.grantRole(id, _role);
                  }, success: 'Access granted.');
                  if (ok && context.mounted) Navigator.pop(context, true);
                },
          child: const Text('Grant'),
        ),
      ],
    );
  }
}

class _OverridesDialog extends ConsumerStatefulWidget {
  const _OverridesDialog({required this.member});
  final StaffMember member;

  @override
  ConsumerState<_OverridesDialog> createState() => _OverridesDialogState();
}

class _OverridesDialogState extends ConsumerState<_OverridesDialog> {
  late final Map<String, bool> _overrides = {...widget.member.overrides};

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(_permissionsProvider);
    return AlertDialog(
      title: Text('Overrides for ${widget.member.email ?? ''}'),
      content: SizedBox(
        width: 520,
        height: 480,
        child: AsyncView(
          value: perms,
          builder: (list) => ListView(children: [
            const Text('Role defaults apply unless overridden. Each change is audited.'),
            for (final p in list)
              ListTile(
                dense: true,
                title: Text(p['code'] as String),
                subtitle: Text((p['description'] as String?) ?? ''),
                trailing: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Default')),
                    ButtonSegment(value: 1, label: Text('Allow')),
                    ButtonSegment(value: -1, label: Text('Deny')),
                  ],
                  selected: {switch (_overrides[p['code']]) { true => 1, false => -1, null => 0 }},
                  onSelectionChanged: (s) async {
                    final v = s.first;
                    final code = p['code'] as String;
                    final granted = v == 0 ? null : v == 1;
                    if (await runAction(context, () => ref.read(adminRepositoryProvider).setPermissionOverride(widget.member.userId, code, granted))) {
                      setState(() => granted == null ? _overrides.remove(code) : _overrides[code] = granted);
                    }
                  },
                ),
              ),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
