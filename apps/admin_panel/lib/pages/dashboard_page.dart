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
    Widget grid(List<Widget> tiles) => LayoutBuilder(builder: (context, c) {
          final cols = (c.maxWidth / 220).floor().clamp(1, 6);
          final w = (c.maxWidth - (cols - 1) * 12) / cols;
          return Wrap(spacing: 12, runSpacing: 12, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
        });
    Widget section(String title, List<Widget> tiles, {Widget? action}) => Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)), ?action]),
            const SizedBox(height: 8),
            grid(tiles),
          ]),
        );
    String n(String g, String k) => '${m.metric(g, k)}';
    final finance = m.finance == null ? null : FinancialSummary.fromJson(m.finance);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      section('Onboarding', [
        MetricTile(label: 'Awaiting review', value: n('applications', 'pending'), icon: Icons.assignment_late_outlined),
        MetricTile(label: 'Waiting on business', value: n('applications', 'awaiting_business'), icon: Icons.hourglass_empty),
        MetricTile(label: 'Approved (all time)', value: n('applications', 'approved'), icon: Icons.verified_outlined),
        MetricTile(label: 'Rejected (all time)', value: n('applications', 'rejected'), icon: Icons.block),
      ], action: TextButton(onPressed: () => context.go('/applications'), child: const Text('Open queue'))),
      section('Network', [
        MetricTile(label: 'Businesses', value: n('businesses', 'total'), caption: '${n('businesses', 'demo')} demo'),
        MetricTile(label: 'Active stations', value: n('stations', 'active'), caption: 'of ${n('stations', 'total')} approved'),
        MetricTile(label: 'Suspended stations', value: n('stations', 'suspended')),
        MetricTile(label: 'Temporarily closed', value: n('stations', 'temporarily_closed')),
        MetricTile(
          label: 'Charging points',
          value: n('charging_points', 'total'),
          caption: '${n('charging_points', 'maintenance')} in maintenance · status is staff-reported',
        ),
      ]),
      section('Bookings in range', [
        MetricTile(label: 'Bookings', value: n('bookings', 'in_range_total')),
        MetricTile(label: 'Completed', value: n('bookings', 'completed')),
        MetricTile(label: 'Cancelled', value: n('bookings', 'cancelled')),
        MetricTile(label: 'No-shows', value: n('bookings', 'no_show')),
        MetricTile(label: 'Expired unpaid', value: n('bookings', 'expired_unpaid')),
        MetricTile(label: 'Upcoming confirmed', value: n('bookings', 'upcoming')),
      ]),
      if (finance != null)
        section('Booking-fee finance in range', [
          MetricTile(label: 'Gross collections', value: finance.gross.format(), caption: '${finance.successfulPayments} payments'),
          MetricTile(label: 'Refunds', value: finance.refunds.format(), caption: '${finance.refundCount} refunds'),
          MetricTile(label: 'Net revenue', value: finance.netRevenue.format(), caption: 'after refunds and gateway fees'),
          MetricTile(label: 'Estimated operating profit', value: finance.estimatedProfit.format(), caption: 'net revenue − approved expenses'),
        ], action: TextButton(onPressed: () => context.go('/finance'), child: const Text('Finance details'))),
      if (m.financeFilteredNote != null) Text(m.financeFilteredNote!, style: Theme.of(context).textTheme.bodySmall),
      Text(
        'Charging fees are paid directly to stations and are not part of these figures.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ]);
  }
}
