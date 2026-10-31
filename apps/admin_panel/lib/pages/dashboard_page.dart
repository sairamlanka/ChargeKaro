import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../providers.dart';
import '../shell.dart';
import '../widgets/range_picker.dart';

/// Every figure is a count of real rows from get_admin_dashboard(). Nothing
/// here is estimated or padded; an empty platform shows zeros.
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(dashboardRangeProvider);
    final data = ref.watch(dashboardProvider);
    return PageFrame(
      title: 'Dashboard',
      actions: [RangePicker(value: range, onChanged: ref.read(dashboardRangeProvider.notifier).set)],
      child: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(dashboardProvider),
        builder: (m) => _Body(m),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.m);
  final DashboardMetrics m;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget grid(List<Widget> tiles) => LayoutBuilder(builder: (context, c) {
          final cols = (c.maxWidth / 220).floor().clamp(1, 6);
          final w = (c.maxWidth - (cols - 1) * 14) / cols;
          return Wrap(spacing: 14, runSpacing: 14, children: [
            for (final (i, tile) in tiles.indexed) SizedBox(width: w, child: Entrance(index: i, child: tile)),
          ]);
        });
    Widget section(String title, IconData icon, Color color, List<Widget> tiles, {Widget? action}) => Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: t.textTheme.titleLarge)),
              ?action,
            ]),
            const SizedBox(height: 12),
            grid(tiles),
          ]),
        );
    int n(String g, String k) => m.metric(g, k);
    String money(num paise) => Money(paise.round()).format();
    final finance = m.finance == null ? null : FinancialSummary.fromJson(m.finance);
    const violet = Color(0xFF7C3AED);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Entrance(
        child: HeroHeader(
          eyebrow: Fmt.greeting(),
          title: 'Here\'s your network today',
          subtitle: n('applications', 'pending') == 0
              ? 'No applications are waiting for review.'
              : '${n('applications', 'pending')} application${n('applications', 'pending') == 1 ? '' : 's'} waiting for review.',
          trailing: n('applications', 'pending') > 0
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Brand.greenDeep),
                  onPressed: () => context.go('/applications'),
                  icon: const Icon(Icons.rate_review_rounded),
                  label: const Text('Review now'),
                )
              : null,
          child: LayoutBuilder(builder: (context, c) {
            final stats = [
              HeroStat(label: 'Active stations', count: n('stations', 'active'), icon: Icons.ev_station_rounded),
              HeroStat(label: 'Charging points', count: n('charging_points', 'total'), icon: Icons.electrical_services_rounded),
              HeroStat(label: 'Bookings in range', count: n('bookings', 'in_range_total'), icon: Icons.event_available_rounded),
              HeroStat(label: 'Retail customers', count: n('customers', 'total'), icon: Icons.people_alt_rounded),
            ];
            final cols = c.maxWidth > 700 ? 4 : 2;
            final w = (c.maxWidth - (cols - 1) * 10) / cols;
            return Wrap(spacing: 10, runSpacing: 10, children: [for (final s in stats) SizedBox(width: w, child: s)]);
          }),
        ),
      ),
      const SizedBox(height: 28),
      section('Onboarding', Icons.assignment_rounded, Brand.ocean, [
        MetricTile(label: 'Awaiting review', count: n('applications', 'pending'), icon: Icons.assignment_late_rounded, accent: Brand.ocean, onTap: () => context.go('/applications')),
        MetricTile(label: 'Waiting on business', count: n('applications', 'awaiting_business'), icon: Icons.hourglass_top_rounded, accent: Brand.amber),
        MetricTile(label: 'Approved (all time)', count: n('applications', 'approved'), icon: Icons.verified_rounded, accent: Brand.green),
        MetricTile(label: 'Rejected (all time)', count: n('applications', 'rejected'), icon: Icons.block_rounded, accent: t.colorScheme.error),
      ], action: TextButton(onPressed: () => context.go('/applications'), child: const Text('Open queue'))),
      section('Network', Icons.hub_rounded, Brand.green, [
        MetricTile(label: 'Businesses', count: n('businesses', 'total'), caption: '${n('businesses', 'demo')} demo', icon: Icons.storefront_rounded, accent: violet),
        MetricTile(label: 'Active stations', count: n('stations', 'active'), caption: 'of ${n('stations', 'total')} approved', icon: Icons.ev_station_rounded, accent: Brand.green),
        MetricTile(label: 'Suspended stations', count: n('stations', 'suspended'), icon: Icons.pause_circle_rounded, accent: t.colorScheme.error),
        MetricTile(label: 'Temporarily closed', count: n('stations', 'temporarily_closed'), icon: Icons.door_front_door_rounded, accent: Brand.amber),
        MetricTile(
          label: 'Charging points',
          count: n('charging_points', 'total'),
          caption: '${n('charging_points', 'maintenance')} in maintenance · status is staff-reported',
          icon: Icons.electrical_services_rounded,
          accent: Brand.ocean,
        ),
      ]),
      section('Retail customers', Icons.people_alt_rounded, Brand.ocean, [
        MetricTile(label: 'Customers', count: n('customers', 'total'), caption: 'all time · excludes staff and business accounts', icon: Icons.people_alt_rounded, accent: Brand.ocean),
        MetricTile(label: 'New in range', count: n('customers', 'new_in_range'), icon: Icons.person_add_alt_1_rounded, accent: Brand.green),
        MetricTile(label: 'Booked in range', count: n('customers', 'booked_in_range'), caption: 'customers with at least one booking', icon: Icons.how_to_reg_rounded, accent: violet),
      ]),
      section('Bookings in range', Icons.event_note_rounded, violet, [
        MetricTile(label: 'Bookings', count: n('bookings', 'in_range_total'), icon: Icons.event_rounded, accent: violet),
        MetricTile(label: 'Completed', count: n('bookings', 'completed'), icon: Icons.task_alt_rounded, accent: Brand.green),
        MetricTile(label: 'Cancelled', count: n('bookings', 'cancelled'), icon: Icons.event_busy_rounded, accent: t.colorScheme.error),
        MetricTile(label: 'No-shows', count: n('bookings', 'no_show'), icon: Icons.person_off_rounded, accent: Brand.amber),
        MetricTile(label: 'Expired unpaid', count: n('bookings', 'expired_unpaid'), icon: Icons.timer_off_rounded, accent: t.colorScheme.outline),
        MetricTile(label: 'Upcoming confirmed', count: n('bookings', 'upcoming'), icon: Icons.upcoming_rounded, accent: Brand.ocean),
      ]),
      if (finance != null)
        section('Booking-fee finance in range', Icons.account_balance_rounded, Brand.amber, [
          MetricTile(label: 'Gross collections', count: finance.gross.paise, format: money, caption: '${finance.successfulPayments} payments', icon: Icons.payments_rounded, accent: Brand.green),
          MetricTile(label: 'Refunds', count: finance.refunds.paise, format: money, caption: '${finance.refundCount} refunds', icon: Icons.undo_rounded, accent: Brand.amber),
          MetricTile(label: 'Net revenue', count: finance.netRevenue.paise, format: money, caption: 'after refunds and gateway fees', icon: Icons.account_balance_wallet_rounded, accent: Brand.ocean),
          MetricTile(
            label: 'Estimated operating profit',
            count: finance.estimatedProfit.paise,
            format: money,
            caption: 'net revenue − approved expenses',
            icon: Icons.trending_up_rounded,
            accent: violet,
          ),
        ], action: TextButton(onPressed: () => context.go('/finance'), child: const Text('Finance details'))),
      if (m.financeFilteredNote != null) Text(m.financeFilteredNote!, style: t.textTheme.bodySmall),
      Text(
        'Charging fees are paid directly to stations and are not part of these figures.',
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    ]);
  }
}
