import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../state.dart';

/// Team by role (see supabase/migrations/20261103000200_team_requests.sql):
/// * Owner: adds managers and staff directly (creates their login with a
///   temporary password), removes members, approves or declines requests.
/// * Station manager: sees staff at their stations, requests a new staff
///   member or a removal; the owner decides.
/// * Station staff: no Team page.
final teamMembersProvider = FutureProvider.autoDispose<List<BusinessMember>>((ref) {
  final a = ref.watch(currentAccessProvider);
  if (a == null) return const <BusinessMember>[];
  return ref.watch(teamRepositoryProvider).members(a.businessId);
});

final teamRequestsProvider = FutureProvider.autoDispose<List<MemberRequest>>((ref) {
  final a = ref.watch(currentAccessProvider);
  if (a == null || a.role == BusinessMemberRole.stationStaff) return const <MemberRequest>[];
  return ref.watch(teamRepositoryProvider).requests(a.businessId);
});

/// Requests waiting for the owner; drives the badge on the More tab.
final pendingTeamRequestsProvider = Provider.autoDispose<int>((ref) {
  final a = ref.watch(currentAccessProvider);
  if (a == null || !a.isOwner) return 0;
  return (ref.watch(teamRequestsProvider).value ?? const []).where((r) => r.pending).length;
});

class TeamPage extends ConsumerWidget {
  const TeamPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(currentAccessProvider);
    final stations = ref.watch(stationsProvider).value ?? const <Station>[];
    final isOwner = access?.isOwner ?? false;
    final isManager = access?.role == BusinessMemberRole.stationManager;
    final members = ref.watch(teamMembersProvider);
    final requests = ref.watch(teamRequestsProvider).value ?? const <MemberRequest>[];
    final pending = requests.where((r) => r.pending).toList();
    final past = requests.where((r) => !r.pending).take(20).toList();

    void refresh() {
      ref.invalidate(teamMembersProvider);
      ref.invalidate(teamRequestsProvider);
    }

    String stationNames(List<String> ids) {
      final names = stations.where((s) => ids.contains(s.id)).map((s) => s.name).toList();
      return names.isEmpty ? 'no stations' : names.join(', ');
    }

    final t = Theme.of(context);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Text(text, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      floatingActionButton: (isOwner || isManager)
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.person_add_alt),
              label: Text(isOwner ? 'Add member' : 'Request staff'),
              onPressed: () async {
                final mine = isOwner ? stations : stations.where((s) => access!.stationIds.contains(s.id)).toList();
                final done = await showModalBottomSheet<bool>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => isOwner ? _AddMemberSheet(stations: mine) : _RequestStaffSheet(stations: mine),
                );
                if (done == true) refresh();
              },
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => refresh(),
        child: AsyncView(
          value: members,
          onRetry: refresh,
          builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            if (isOwner && pending.isNotEmpty) ...[
              heading('Requests waiting for you'),
              for (final r in pending) _RequestCard(request: r, stationNames: stationNames, ownerView: true, onChanged: refresh),
            ],
            if (isManager && pending.isNotEmpty) ...[
              heading('Your requests'),
              for (final r in pending) _RequestCard(request: r, stationNames: stationNames, ownerView: false, onChanged: refresh),
            ],
            heading(isOwner ? 'Members' : 'Your team'),
            if (list.isEmpty)
              const EmptyState(icon: Icons.groups_rounded, title: 'No members yet', message: 'Add your station managers and staff here.'),
            for (final m in list)
              _MemberTile(
                member: m,
                stationNames: stationNames,
                isOwner: isOwner,
                canRequestRemoval: isManager && m.role == BusinessMemberRole.stationStaff,
                removalPending: requests.any((r) => r.pending && r.kind == MemberRequestKind.remove && r.memberId == m.id),
                stations: stations,
                onChanged: refresh,
              ),
            if (past.isNotEmpty)
              ExpansionTile(
                title: const Text('Past requests'),
                children: [
                  for (final r in past) _RequestCard(request: r, stationNames: stationNames, ownerView: isOwner, onChanged: refresh),
                ],
              ),
          ]),
        ),
      ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({
    required this.member,
    required this.stationNames,
    required this.isOwner,
    required this.canRequestRemoval,
    required this.removalPending,
    required this.stations,
    required this.onChanged,
  });

  final BusinessMember member;
  final String Function(List<String>) stationNames;
  final bool isOwner;
  final bool canRequestRemoval;
  final bool removalPending;
  final List<Station> stations;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = member;
    final me = ref.watch(currentAccessProvider)?.memberId == m.id;
    return ListTile(
      leading: CircleAvatar(child: Text(m.displayName.characters.first.toUpperCase())),
      title: Text(me ? '${m.displayName} (you)' : m.displayName),
      subtitle: Text([
        if (m.email != null && m.email != m.displayName) m.email!,
        m.role.label,
        if (m.role != BusinessMemberRole.owner) stationNames(m.stationIds),
      ].join(' · ')),
      isThreeLine: m.role != BusinessMemberRole.owner,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (removalPending) const StatusChip('Removal requested', tone: StatusTone.warning),
        if (isOwner && m.role != BusinessMemberRole.owner) ...[
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final done = await showModalBottomSheet<bool>(
                  context: context, isScrollControlled: true, builder: (_) => _EditMemberSheet(stations: stations, member: m));
              if (done == true) onChanged();
            },
          ),
          IconButton(
            tooltip: 'Delete member',
            icon: const Icon(Icons.person_remove_outlined),
            onPressed: () async {
              final ok = await confirm(context,
                  title: 'Delete ${m.displayName}?',
                  message: 'Use this when someone leaves. They lose access immediately and are removed from your team. '
                      'If their login was created here, it is closed and their name, email and phone are deleted. '
                      'Past bookings and check-ins they handled stay in your records.',
                  confirmLabel: 'Delete',
                  destructive: true);
              if (!ok || !context.mounted) return;
              if (await runAction(context, () => ref.read(teamRepositoryProvider).remove(m.id), success: '${m.displayName} was removed.')) {
                onChanged();
              }
            },
          ),
        ],
        if (canRequestRemoval && !removalPending && !me)
          IconButton(
            tooltip: 'Ask owner to remove',
            icon: const Icon(Icons.person_remove_outlined),
            onPressed: () async {
              final reason = await confirmWithReason(context,
                  title: 'Ask to remove ${m.displayName}?',
                  message: 'The owner gets your request and decides. ${m.displayName} keeps access until then.',
                  confirmLabel: 'Send request',
                  reasonLabel: 'Reason (for example: left the job)',
                  minReasonLength: 3);
              if (reason == null || !context.mounted) return;
              if (await runAction(context, () => ref.read(teamRepositoryProvider).requestRemoval(m.id, reason: reason),
                  success: 'Request sent to the owner.')) {
                onChanged();
              }
            },
          ),
      ]),
    );
  }
}

class _RequestCard extends ConsumerWidget {
  const _RequestCard({required this.request, required this.stationNames, required this.ownerView, required this.onChanged});
  final MemberRequest request;
  final String Function(List<String>) stationNames;
  final bool ownerView;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    final t = Theme.of(context);
    final repo = ref.read(teamRepositoryProvider);
    final add = r.kind == MemberRequestKind.add;
    final tone = switch (r.status) {
      MemberRequestStatus.pending => StatusTone.warning,
      MemberRequestStatus.approved => StatusTone.success,
      MemberRequestStatus.rejected => StatusTone.danger,
      MemberRequestStatus.cancelled => StatusTone.neutral,
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(add ? Icons.person_add_alt_1_rounded : Icons.person_remove_rounded, color: add ? Brand.green : t.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(add ? 'Add ${r.personName} as staff' : 'Remove ${r.personName}', style: t.textTheme.titleSmall),
            ),
            StatusChip(r.status.label, tone: tone),
          ]),
          const SizedBox(height: 6),
          Text(
            [
              if (ownerView) 'Asked by ${r.requestedByName ?? 'a manager'}',
              Fmt.dateOnly(r.createdAt),
              if (add && r.email != null) r.email!,
              if (add) stationNames(r.stationIds),
              if (r.reason != null) 'Reason: ${r.reason}',
              if (r.decisionNote != null) 'Owner note: ${r.decisionNote}',
            ].join(' · '),
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          if (r.pending) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, alignment: WrapAlignment.end, children: [
              if (ownerView) ...[
                OutlinedButton(
                  onPressed: () async {
                    final note = await confirmWithReason(context,
                        title: 'Decline this request?',
                        message: 'The manager is told it was declined.',
                        confirmLabel: 'Decline',
                        reasonLabel: 'Note for the manager',
                        minReasonLength: 0);
                    if (note == null || !context.mounted) return;
                    if (await runAction(context, () => repo.reject(r.id, note: note), success: 'Request declined.')) onChanged();
                  },
                  child: const Text('Decline'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (add) {
                      final password = await showDialog<String>(context: context, builder: (_) => _TempPasswordDialog(name: r.personName));
                      if (password == null || !context.mounted) return;
                      MemberCreated? created;
                      final ok = await runAction(context, () async => created = await repo.approveAdd(r.id, tempPassword: password));
                      if (ok && context.mounted) {
                        onChanged();
                        await showLoginDetails(context, email: r.email ?? '', password: password, loginCreated: created?.loginCreated ?? false);
                      }
                    } else {
                      final ok = await confirm(context,
                          title: 'Remove ${r.personName}?',
                          message: 'They lose access immediately. If their login was created here, it is closed and their personal details are deleted.',
                          confirmLabel: 'Remove',
                          destructive: true);
                      if (!ok || !context.mounted) return;
                      if (await runAction(context, () => repo.approveRemoval(r.id), success: '${r.personName} was removed.')) onChanged();
                    }
                  },
                  child: const Text('Approve'),
                ),
              ] else
                TextButton(
                  onPressed: () async {
                    if (await runAction(context, () => repo.cancel(r.id), success: 'Request cancelled.')) onChanged();
                  },
                  child: const Text('Cancel request'),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Owner: add a member directly
// ---------------------------------------------------------------------------

String generateTempPassword() {
  const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const lower = 'abcdefghijkmnpqrstuvwxyz';
  const digits = '23456789';
  final rnd = Random.secure();
  String pick(String s, int n) => List.generate(n, (_) => s[rnd.nextInt(s.length)]).join();
  return '${pick(upper, 1)}${pick(lower, 5)}${pick(digits, 4)}${pick(upper, 1)}${pick(lower, 1)}';
}

/// Shows the login the owner should pass on to the new member.
Future<void> showLoginDetails(BuildContext context, {required String email, required String password, required bool loginCreated}) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Member added'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (loginCreated) ...[
            const Text('Share these sign-in details with them. They will be asked to set their own password the first time they sign in.'),
            const SizedBox(height: 12),
            SelectableText('Email: $email\nTemporary password: $password', style: Theme.of(context).textTheme.titleSmall),
          ] else
            Text('$email already had a ChargeKaro login, so they sign in to the Business app with their own password.'),
        ]),
        actions: [
          if (loginCreated)
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: 'ChargeKaro Business\nEmail: $email\nTemporary password: $password')),
              child: const Text('Copy'),
            ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ],
      ),
    );

class _TempPasswordField extends StatefulWidget {
  const _TempPasswordField({required this.controller});
  final TextEditingController controller;

  @override
  State<_TempPasswordField> createState() => _TempPasswordFieldState();
}

class _TempPasswordFieldState extends State<_TempPasswordField> {
  @override
  Widget build(BuildContext context) => TextFormField(
        controller: widget.controller,
        decoration: InputDecoration(
          labelText: 'Temporary password',
          helperText: 'Only used if they do not have a ChargeKaro login yet',
          suffixIcon: IconButton(
            tooltip: 'New password',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => setState(() => widget.controller.text = generateTempPassword()),
          ),
        ),
        validator: Validators.password,
      );
}

class _TempPasswordDialog extends StatefulWidget {
  const _TempPasswordDialog({required this.name});
  final String name;

  @override
  State<_TempPasswordDialog> createState() => _TempPasswordDialogState();
}

class _TempPasswordDialogState extends State<_TempPasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController(text: generateTempPassword());

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Add ${widget.name}'),
        content: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('A login is created with this temporary password. You will see it again on the next screen to share.'),
            const SizedBox(height: 12),
            _TempPasswordField(controller: _password),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (_form.currentState!.validate()) Navigator.pop(context, _password.text);
            },
            child: const Text('Approve'),
          ),
        ],
      );
}

Set<BusinessPermission> defaultPermissions(BusinessMemberRole r) => r == BusinessMemberRole.stationManager
    ? {
        BusinessPermission.stationEdit, BusinessPermission.availabilityEdit, BusinessPermission.pointsManage, BusinessPermission.pointsStatus,
        BusinessPermission.bookingsView, BusinessPermission.bookingsCheckin, BusinessPermission.bookingsManage,
        BusinessPermission.maintenanceReport, BusinessPermission.maintenanceManage, BusinessPermission.reportsView,
      }
    : {BusinessPermission.bookingsView, BusinessPermission.bookingsCheckin, BusinessPermission.pointsStatus, BusinessPermission.maintenanceReport};

/// Permissions staff can never hold (database constraint business_members_staff_limits).
const _staffForbidden = {BusinessPermission.documentsManage, BusinessPermission.availabilityEdit, BusinessPermission.stationEdit};

class _RoleStationsPermissions extends StatelessWidget {
  const _RoleStationsPermissions({
    required this.stations,
    required this.role,
    required this.selected,
    required this.perms,
    required this.onRole,
    required this.onStations,
    required this.onPerms,
  });

  final List<Station> stations;
  final BusinessMemberRole role;
  final Set<String> selected;
  final Set<BusinessPermission> perms;
  final ValueChanged<BusinessMemberRole> onRole;
  final ValueChanged<Set<String>> onStations;
  final ValueChanged<Set<BusinessPermission>> onPerms;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 12),
      SegmentedButton<BusinessMemberRole>(
        segments: const [
          ButtonSegment(value: BusinessMemberRole.stationManager, label: Text('Manager')),
          ButtonSegment(value: BusinessMemberRole.stationStaff, label: Text('Staff')),
        ],
        selected: {role},
        onSelectionChanged: (s) => onRole(s.first),
      ),
      const SizedBox(height: 4),
      Text(
        role == BusinessMemberRole.stationManager
            ? 'Managers run their stations and can ask you to add or remove staff.'
            : 'Staff see bookings and check customers in at their stations.',
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 12),
      Text('Stations', style: t.textTheme.titleSmall),
      for (final s in stations)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: selected.contains(s.id),
          title: Text(s.name),
          onChanged: (v) => onStations(v == true ? {...selected, s.id} : ({...selected}..remove(s.id))),
        ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('Permissions', style: t.textTheme.titleSmall),
        subtitle: const Text('Defaults suit most teams'),
        children: [
          for (final p in BusinessPermission.values)
            if (!(role == BusinessMemberRole.stationStaff && _staffForbidden.contains(p)))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: perms.contains(p),
                title: Text(p.label),
                onChanged: (v) => onPerms(v == true ? {...perms, p} : ({...perms}..remove(p))),
              ),
        ],
      ),
    ]);
  }
}

class _AddMemberSheet extends ConsumerStatefulWidget {
  const _AddMemberSheet({required this.stations});
  final List<Station> stations;

  @override
  ConsumerState<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends ConsumerState<_AddMemberSheet> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController(text: generateTempPassword());
  BusinessMemberRole _role = BusinessMemberRole.stationStaff;
  Set<String> _stations = {};
  Set<BusinessPermission> _perms = defaultPermissions(BusinessMemberRole.stationStaff);

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        builder: (context, scroll) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: Form(
            key: _form,
            child: ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
              Text('Add a team member', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('We create their Business app login. You share the email and temporary password with them.'),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name'),
                textCapitalization: TextCapitalization.words,
                validator: Validators.all([Validators.required(), Validators.length(max: 120)]),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email (used to sign in)'),
                keyboardType: TextInputType.emailAddress,
                validator: Validators.email,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _phone,
                decoration: const InputDecoration(labelText: 'Mobile (optional)'),
                keyboardType: TextInputType.phone,
                validator: Validators.optional(Validators.phone),
              ),
              const SizedBox(height: 10),
              _TempPasswordField(controller: _password),
              _RoleStationsPermissions(
                stations: widget.stations,
                role: _role,
                selected: _stations,
                perms: _perms,
                onRole: (r) => setState(() {
                  _role = r;
                  _perms = defaultPermissions(r);
                }),
                onStations: (s) => setState(() => _stations = s),
                onPerms: (p) => setState(() => _perms = p),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _stations.isEmpty
                    ? null
                    : () async {
                        if (!_form.currentState!.validate()) return;
                        final businessId = ref.read(currentAccessProvider)!.businessId;
                        MemberCreated? created;
                        final ok = await runAction(context, () async {
                          created = await ref.read(teamRepositoryProvider).create(
                                businessId: businessId,
                                email: _email.text,
                                fullName: _name.text,
                                phone: Validators.normalizePhone(_phone.text),
                                role: _role,
                                permissions: _perms,
                                stationIds: _stations.toList(),
                                tempPassword: _password.text,
                              );
                        });
                        if (!ok || !context.mounted) return;
                        await showLoginDetails(context,
                            email: _email.text.trim().toLowerCase(), password: _password.text, loginCreated: created?.loginCreated ?? false);
                        if (context.mounted) Navigator.pop(context, true);
                      },
                child: Text(_stations.isEmpty ? 'Pick at least one station' : 'Add member'),
              ),
            ]),
          ),
        ),
      );
}

class _EditMemberSheet extends ConsumerStatefulWidget {
  const _EditMemberSheet({required this.stations, required this.member});
  final List<Station> stations;
  final BusinessMember member;

  @override
  ConsumerState<_EditMemberSheet> createState() => _EditMemberSheetState();
}

class _EditMemberSheetState extends ConsumerState<_EditMemberSheet> {
  late BusinessMemberRole _role = widget.member.role;
  late Set<String> _stations = {...widget.member.stationIds};
  late Set<BusinessPermission> _perms = widget.member.permissions;

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (context, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
          Text('Edit ${widget.member.displayName}', style: Theme.of(context).textTheme.titleLarge),
          _RoleStationsPermissions(
            stations: widget.stations,
            role: _role,
            selected: _stations,
            perms: _perms,
            onRole: (r) => setState(() {
              _role = r;
              _perms = defaultPermissions(r);
            }),
            onStations: (s) => setState(() => _stations = s),
            onPerms: (p) => setState(() => _perms = p),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _stations.isEmpty
                ? null
                : () async {
                    final perms = _role == BusinessMemberRole.stationStaff ? _perms.difference(_staffForbidden) : _perms;
                    final ok = await runAction(
                      context,
                      () => ref.read(teamRepositoryProvider).update(widget.member.id, _role, permissions: perms, stationIds: _stations.toList()),
                      success: 'Member updated.',
                    );
                    if (ok && context.mounted) Navigator.pop(context, true);
                  },
            child: const Text('Save'),
          ),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Station manager: request a new staff member
// ---------------------------------------------------------------------------

class _RequestStaffSheet extends ConsumerStatefulWidget {
  const _RequestStaffSheet({required this.stations});
  final List<Station> stations;

  @override
  ConsumerState<_RequestStaffSheet> createState() => _RequestStaffSheetState();
}

class _RequestStaffSheetState extends ConsumerState<_RequestStaffSheet> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  late Set<String> _stations = widget.stations.length == 1 ? {widget.stations.first.id} : {};

  @override
  void dispose() {
    for (final c in [_name, _email, _phone]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (context, scroll) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: Form(
            key: _form,
            child: ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
              Text('Request a new staff member', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('The business owner approves the request and creates their login.'),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name'),
                textCapitalization: TextCapitalization.words,
                validator: Validators.all([Validators.required(), Validators.length(max: 120)]),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email (used to sign in)'),
                keyboardType: TextInputType.emailAddress,
                validator: Validators.email,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _phone,
                decoration: const InputDecoration(labelText: 'Mobile (optional)'),
                keyboardType: TextInputType.phone,
                validator: Validators.optional(Validators.phone),
              ),
              const SizedBox(height: 12),
              Text('Stations', style: Theme.of(context).textTheme.titleSmall),
              for (final s in widget.stations)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _stations.contains(s.id),
                  title: Text(s.name),
                  onChanged: (v) => setState(() => _stations = v == true ? {..._stations, s.id} : ({..._stations}..remove(s.id))),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _stations.isEmpty
                    ? null
                    : () async {
                        if (!_form.currentState!.validate()) return;
                        final ok = await runAction(
                          context,
                          () => ref.read(teamRepositoryProvider).requestAdd(
                                businessId: ref.read(currentAccessProvider)!.businessId,
                                email: _email.text,
                                fullName: _name.text,
                                phone: Validators.normalizePhone(_phone.text),
                                stationIds: _stations.toList(),
                              ),
                          success: 'Request sent to the owner.',
                        );
                        if (ok && context.mounted) Navigator.pop(context, true);
                      },
                child: const Text('Send request'),
              ),
            ]),
          ),
        ),
      );
}
