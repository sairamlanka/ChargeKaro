import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_ui/shared_ui.dart';

import '../export/csv.dart';
import '../export/download.dart';
import '../providers.dart';
import '../widgets/finance_chart.dart';
import 'finance_page.dart';

const _names = {'day': 'Daily', 'week': 'Weekly', 'month': 'Monthly'};

/// Profit and loss over time, with exports.
class FinanceReportsTab extends ConsumerWidget {
  const FinanceReportsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(financeRangeProvider);
    final bucket = ref.watch(financeBucketProvider) ?? autoBucket(range);
    final series = ref.watch(financeSeriesProvider);
    final stamp = '${range.from.toIso8601String().substring(0, 10)}_to_${range.to.toIso8601String().substring(0, 10)}';
    final t = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          BucketPicker(range: range),
          FilledButton.tonalIcon(
            onPressed: series.value == null
                ? null
                : () => runAction(
                      context,
                      () => downloadTextFile('chargekaro-profit-and-loss-${_names[bucket]!.toLowerCase()}-$stamp.csv', profitAndLossCsv(series.value!)),
                      success: 'Profit and loss exported.',
                    ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Profit & loss CSV'),
          ),
          Text('Use the Booking revenue and Expenses tabs to export line items.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 16),
        AsyncView(
          value: series,
          onRetry: () => ref.invalidate(financeSeriesProvider),
          builder: (points) {
            final best = points.isEmpty ? null : points.reduce((a, b) => b.estimatedProfit.paise > a.estimatedProfit.paise ? b : a);
            final worst = points.isEmpty ? null : points.reduce((a, b) => b.estimatedProfit.paise < a.estimatedProfit.paise ? b : a);
            final profitable = points.where((p) => p.estimatedProfit.paise > 0).length;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TileGrid(minWidth: 220, tiles: [
                MetricTile(
                  label: 'Profitable periods',
                  value: '$profitable of ${points.length}',
                  caption: '${_names[bucket]} view',
                  icon: Icons.insights_rounded,
                  accent: FinanceColors.of(context).profit,
                ),
                MetricTile(
                  label: 'Best period',
                  value: best == null || best.estimatedProfit.isZero ? '–' : best.estimatedProfit.format(),
                  caption: best == null || best.estimatedProfit.isZero ? null : bucketLabel(best.bucketStart, bucket),
                  icon: Icons.emoji_events_rounded,
                  accent: Brand.green,
                ),
                MetricTile(
                  label: 'Weakest period',
                  value: worst == null || worst.estimatedProfit.isZero ? '–' : worst.estimatedProfit.format(),
                  caption: worst == null || worst.estimatedProfit.isZero ? null : bucketLabel(worst.bucketStart, bucket),
                  icon: Icons.south_east_rounded,
                  accent: FinanceColors.of(context).loss,
                ),
              ]),
              const SizedBox(height: 16),
              Entrance(index: 1, child: SectionCard(title: 'Profit over time', child: ProfitTrendChart(points: points, bucket: bucket))),
              const SizedBox(height: 16),
              Entrance(index: 2, child: SectionCard(title: 'Revenue vs expenses', child: RevenueExpenseChart(points: points, bucket: bucket))),
              const SizedBox(height: 16),
              Entrance(
                index: 3,
                child: SectionCard(
                  title: 'Profit and loss by ${bucket == 'day' ? 'day' : bucket}',
                  child: FinanceTable(points: points, bucket: bucket),
                ),
              ),
            ]);
          },
        ),
        const SizedBox(height: 12),
        Text(
          'Estimated profit = booking fees collected − refunds − gateway fees − approved expenses, in IST calendar periods. '
          'It is before tax and is not an accounting statement.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}
