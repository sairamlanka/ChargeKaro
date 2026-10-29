import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../state.dart';

class MorePage extends ConsumerWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(currentAccessProvider);
    final all = ref.watch(businessAccessProvider).value ?? const [];
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;
    Widget item(IconData icon, Color color, String title, VoidCallback onTap, {Widget? badge}) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: color, size: 22),
          ),
          title: Text(title, style: Theme.of(context).textTheme.titleSmall),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [?badge, const Icon(Icons.chevron_right_rounded)]),
          onTap: onTap,
        );
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: staggered([
          if (access != null)
            HeroHeader(
              eyebrow: access.role.label,
              title: access.businessName,
              subtitle: access.businessStatus.label,
              trailing: all.length > 1
                  ? PopupMenuButton<String>(
                      tooltip: 'Switch business',
                      icon: const Icon(Icons.swap_horiz_rounded, color: Colors.white),
                      onSelected: ref.read(selectedBusinessIdProvider.notifier).select,
                      itemBuilder: (_) => [
                        for (final a in all) CheckedPopupMenuItem(value: a.businessId, checked: a.businessId == access.businessId, child: Text(a.businessName)),
                      ],
                    )
                  : null,
            ),
          const SizedBox(height: 16),
          Card(
            child: Column(children: [
              item(Icons.notifications_rounded, Brand.ocean, 'Notifications', () => context.go('/more/notifications'),
                  badge: unread > 0 ? Badge(label: Text('$unread')) : null),
              if (access?.can(BusinessPermission.reportsView) ?? false)
                item(Icons.insights_rounded, Brand.amber, 'Reports', () => context.go('/more/reports')),
              if (access?.isOwner ?? false) item(Icons.groups_rounded, const Color(0xFF7C3AED), 'Team', () => context.go('/more/team')),
              item(Icons.person_rounded, Brand.green, 'Account', () => context.go('/more/account')),
            ]),
          ),
          const SizedBox(height: 12),
          Card(
            child: item(
              Icons.logout_rounded,
              Theme.of(context).colorScheme.error,
              'Sign out',
              () => signOut(ref.read(authRepositoryProvider), ref.read(notificationRepositoryProvider)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'ChargeKaro shows charger status as reported by your staff. It does not control chargers remotely.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
      ),
    );
  }
}

final _membersProvider = FutureProvider.autoDispose<List<BusinessMember>>((ref) {
  final a = ref.watch(currentAccessProvider);
  if (a == null) return const <BusinessMember>[];
  return ref.watch(stationRepositoryProvider).members(a.businessId);
});

class TeamPage extends ConsumerWidget {
  const TeamPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stations = ref.watch(stationsProvider).value ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add member'),
        onPressed: () async {
          if (await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _MemberSheet(stations: stations)) == true) {
            ref.invalidate(_membersProvider);
          }
        },
      ),
      body: AsyncView(
        value: ref.watch(_membersProvider),
        onRetry: () => ref.invalidate(_membersProvider),
        builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          for (final m in list)
            ListTile(
              title: Text(m.fullName ?? m.email ?? 'Member'),
              subtitle: Text([
                m.email ?? '',
                m.role.label,
                if (m.role != BusinessMemberRole.owner)
                  m.stationIds.isEmpty ? 'no stations' : stations.where((s) => m.stationIds.contains(s.id)).map((s) => s.name).join(', '),
              ].where((s) => s.isNotEmpty).join(' · ')),
              trailing: m.role == BusinessMemberRole.owner
                  ? null
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (!m.active) const StatusChip('Removed'),
                      if (m.active)
                        IconButton(
                          tooltip: 'Edit',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () async {
                            if (await showModalBottomSheet<bool>(
                                    context: context, isScrollControlled: true, builder: (_) => _MemberSheet(stations: stations, member: m)) ==
                                true) {
                              ref.invalidate(_membersProvider);
                            }
                          },
                        ),
                      if (m.active)
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () async {
                            final ok = await confirm(context,
                                title: 'Remove ${m.fullName ?? m.email}?', message: 'They lose access immediately.', confirmLabel: 'Remove', destructive: true);
                            if (ok && context.mounted && await runAction(context, () => ref.read(stationRepositoryProvider).revokeMember(m.id))) {
                              ref.invalidate(_membersProvider);
                            }
                          },
                        ),
                    ]),
            ),
        ]),
      ),
    );
  }
}

class _MemberSheet extends ConsumerStatefulWidget {
  const _MemberSheet({required this.stations, this.member});
  final List<Station> stations;
  final BusinessMember? member;

  @override
  ConsumerState<_MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends ConsumerState<_MemberSheet> {
  final _email = TextEditingController();
  late BusinessMemberRole _role = widget.member?.role ?? BusinessMemberRole.stationStaff;
  late Set<String> _stations = {...?widget.member?.stationIds};
  late Set<BusinessPermission> _perms = widget.member?.permissions ?? _defaults(_role);

  static Set<BusinessPermission> _defaults(BusinessMemberRole r) => r == BusinessMemberRole.stationManager
      ? {
          BusinessPermission.stationEdit, BusinessPermission.availabilityEdit, BusinessPermission.pointsManage, BusinessPermission.pointsStatus,
          BusinessPermission.bookingsView, BusinessPermission.bookingsCheckin, BusinessPermission.bookingsManage,
          BusinessPermission.maintenanceReport, BusinessPermission.maintenanceManage, BusinessPermission.reportsView,
        }
      : {BusinessPermission.bookingsView, BusinessPermission.bookingsCheckin, BusinessPermission.pointsStatus, BusinessPermission.maintenanceReport};

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.member != null;
    final valid = (editing || Validators.email(_email.text) == null) && _stations.isNotEmpty;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      builder: (context, scroll) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
          Text(editing ? 'Edit member' : 'Add a team member', style: Theme.of(context).textTheme.titleLarge),
          if (!editing) ...[
            const Text('They must first create a ChargeKaro Business account with this email.'),
            const SizedBox(height: 8),
            TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress, onChanged: (_) => setState(() {})),
          ],
          const SizedBox(height: 12),
          SegmentedButton<BusinessMemberRole>(
            segments: const [
              ButtonSegment(value: BusinessMemberRole.stationManager, label: Text('Manager')),
              ButtonSegment(value: BusinessMemberRole.stationStaff, label: Text('Staff')),
            ],
            selected: {_role},
            onSelectionChanged: (s) => setState(() {
              _role = s.first;
              _perms = _defaults(_role);
            }),
          ),
          const SizedBox(height: 12),
          Text('Stations', style: Theme.of(context).textTheme.titleSmall),
          for (final s in widget.stations)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _stations.contains(s.id),
              title: Text(s.name),
              onChanged: (v) => setState(() => v == true ? _stations = {..._stations, s.id} : _stations = {..._stations}..remove(s.id)),
            ),
          Text('Permissions', style: Theme.of(context).textTheme.titleSmall),
          for (final p in BusinessPermission.values)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _perms.contains(p),
              title: Text(p.label),
              onChanged: (v) => setState(() => v == true ? _perms = {..._perms, p} : _perms = {..._perms}..remove(p)),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: !valid
                ? null
                : () async {
                    final repo = ref.read(stationRepositoryProvider);
                    final businessId = ref.read(currentAccessProvider)!.businessId;
                    final ok = await runAction(context, () async {
                      if (editing) {
                        await repo.updateMember(widget.member!.id, _role, permissions: _perms, stationIds: _stations.toList());
                      } else {
                        await repo.addMember(businessId, _email.text, _role, permissions: _perms, stationIds: _stations.toList());
                      }
                    }, success: editing ? 'Member updated.' : 'Member added.');
                    if (ok && context.mounted) Navigator.pop(context, true);
                  },
            child: Text(editing ? 'Save' : 'Add member'),
          ),
        ]),
      ),
    );
  }
}

typedef _Range = ({DateTime from, DateTime to});

class _ReportRange extends Notifier<_Range> {
  @override
  _Range build() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return (from: today.subtract(const Duration(days: 29)), to: today);
  }

  void set(_Range r) => state = r;
}

final _rangeProvider = NotifierProvider<_ReportRange, _Range>(_ReportRange.new);

final _reportProvider = FutureProvider.autoDispose<BusinessReport>((ref) {
  final a = ref.watch(currentAccessProvider)!;
  final r = ref.watch(_rangeProvider);
  return ref.watch(stationRepositoryProvider).report(a.businessId, r.from, r.to);
});

/// Operational reports from real bookings. There is no revenue here because
/// the platform does not see what customers pay for charging.
class ReportsPage extends ConsumerWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(_rangeProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.date_range),
            label: Text('${Fmt.dateOnly(range.from)} – ${Fmt.dateOnly(range.to)}'),
            onPressed: () async {
              final p = await showDateRangePicker(
                  context: context, firstDate: DateTime(2025), lastDate: DateTime.now().add(const Duration(days: 90)), initialDateRange: DateTimeRange(start: range.from, end: range.to));
              if (p != null) ref.read(_rangeProvider.notifier).set((from: p.start, to: p.end));
            },
          ),
        ],
      ),
      body: AsyncView(
        value: ref.watch(_reportProvider),
        onRetry: () => ref.invalidate(_reportProvider),
        builder: (r) => ListView(padding: const EdgeInsets.all(16), children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (label, key) in const [
              ('Bookings', 'bookings'),
              ('Completed', 'completed'),
              ('Cancelled', 'cancelled'),
              ('No-shows', 'no_show'),
              ('Upcoming', 'confirmed_upcoming'),
            ])
              SizedBox(width: 160, child: MetricTile(label: label, value: '${r.total(key)}')),
          ]),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Charging point utilisation',
            child: Column(children: [
              for (final p in r.byChargingPoint)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p['code']} · ${p['station_name']} · ${Fmt.percent(BusinessReport.utilisation(p))} booked'),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: BusinessReport.utilisation(p), minHeight: 6, borderRadius: BorderRadius.circular(3)),
                    Text('${p['bookings']} bookings · ${p['maintenance_downtime_minutes']} min maintenance', style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Busiest hours (IST)',
            child: r.peakHours.isEmpty
                ? const Text('No bookings in this period.')
                : Column(children: [
                    for (final h in r.peakHours.take(6))
                      KeyValue('${h.hour.toString().padLeft(2, '0')}:00–${(h.hour + 1).toString().padLeft(2, '0')}:00', '${h.bookings} bookings'),
                  ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'By station',
            child: Column(children: [
              for (final s in r.byStation)
                KeyValue('${s['station_name']}', '${s['bookings']} bookings · ${s['completed']} completed · ${s['no_show']} no-shows'),
            ]),
          ),
          const SizedBox(height: 16),
          for (final n in r.notes) Text(n, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

final _notificationsProvider = FutureProvider.autoDispose<List<AppNotification>>((ref) => ref.watch(notificationRepositoryProvider).list());

class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void refresh() {
      ref.invalidate(_notificationsProvider);
      ref.invalidate(unreadNotificationsProvider);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: () async {
              if (await runAction(context, () => ref.read(notificationRepositoryProvider).markAllRead())) refresh();
            },
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => refresh(),
        child: AsyncView(
          value: ref.watch(_notificationsProvider),
          onRetry: refresh,
          builder: (list) => list.isEmpty
              ? ListView(children: const [EmptyState(icon: Icons.notifications_none, title: 'No notifications')])
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final n = list[i];
                    return ListTile(
                      leading: Icon(n.isRead ? Icons.notifications_none : Icons.notifications_active, color: n.isRead ? null : Theme.of(context).colorScheme.primary),
                      title: Text(n.title, style: n.isRead ? null : const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('${n.body}\n${Fmt.relative(n.createdAt)}'),
                      isThreeLine: true,
                      onTap: () async {
                        if (!n.isRead) {
                          await ref.read(notificationRepositoryProvider).markRead([n.id]).catchError((_) => 0);
                          refresh();
                        }
                        if (!context.mounted) return;
                        if (n.bookingId != null) {
                          context.go('/bookings/${n.bookingId}');
                        } else if (n.stationId != null) {
                          context.go('/stations/${n.stationId}');
                        }
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  final _name = TextEditingController();
  final _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    ref.read(authRepositoryProvider).myProfile().then((p) {
      if (mounted) _name.text = (p?['full_name'] as String?) ?? '';
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authRepositoryProvider).currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        KeyValue('Email', user?.email),
        const SizedBox(height: 12),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Full name')),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => runAction(context, () => ref.read(authRepositoryProvider).updateProfile(fullName: _name.text), success: 'Saved.'),
          child: const Text('Save name'),
        ),
        const Divider(height: 32),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'New password', helperText: '10+ characters with upper and lower case and a digit'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () async {
            final problem = Validators.password(_password.text);
            if (problem != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
              return;
            }
            if (await runAction(context, () => ref.read(authRepositoryProvider).updatePassword(_password.text), success: 'Password changed.')) {
              _password.clear();
            }
          },
          child: const Text('Change password'),
        ),
      ]),
    );
  }
}
