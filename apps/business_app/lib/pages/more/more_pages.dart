import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../state.dart';
import 'team_page.dart';

export 'team_page.dart' show TeamPage;

class MorePage extends ConsumerWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(currentAccessProvider);
    final all = ref.watch(businessAccessProvider).value ?? const [];
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;
    final teamBadge = ref.watch(pendingTeamRequestsProvider);
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
              if (access != null && access.role != BusinessMemberRole.stationStaff)
                item(Icons.groups_rounded, const Color(0xFF7C3AED), 'Team', () => context.go('/more/team'),
                    badge: teamBadge > 0 ? Badge(label: Text('$teamBadge')) : null),
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
