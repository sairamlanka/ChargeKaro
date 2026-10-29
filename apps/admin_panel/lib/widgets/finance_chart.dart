import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

/// Chart colours, validated for colour-blind separation and contrast on the
/// light and dark surfaces (blue / orange / aqua slots of the reference
/// categorical palette, plus its critical red for losses).
class FinanceColors {
  const FinanceColors._(this.revenue, this.expenses, this.profit, this.loss);

  factory FinanceColors.of(BuildContext context) => Theme.of(context).brightness == Brightness.dark
      ? const FinanceColors._(Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70), Color(0xFFE66767))
      : const FinanceColors._(Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A), Color(0xFFD03B3B));

  final Color revenue;
  final Color expenses;
  final Color profit;
  final Color loss;
}

final _compact = NumberFormat.compactCurrency(locale: 'en_IN', symbol: '₹');

String bucketLabel(DateTime d, String bucket) => switch (bucket) {
      'month' => DateFormat('MMM yyyy').format(d),
      'week' => 'Week of ${DateFormat('d MMM').format(d)}',
      _ => DateFormat('d MMM yyyy').format(d),
    };

String _axisLabel(DateTime d, String bucket) => bucket == 'month' ? DateFormat('MMM yy').format(d) : DateFormat('d MMM').format(d);

/// Grows the chart's values from zero once, unless reduced motion is on.
class _GrowIn extends StatelessWidget {
  const _GrowIn({required this.builder});
  final Widget Function(double t) builder;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 900),
      curve: Motion.curve,
      builder: (context, t, _) => builder(t),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label, this.bar = false});
  final Color color;
  final String label;
  final bool bar;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: bar ? 10 : 14,
          height: bar ? 10 : 3,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(bar ? 3 : 2)),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ]);
}

FlTitlesData _titles(BuildContext context, List<FinancialPoint> pts, String bucket) {
  final t = Theme.of(context);
  final muted = t.colorScheme.onSurfaceVariant;
  final step = (pts.length / 7).ceil().clamp(1, 1000);
  return FlTitlesData(
    topTitles: const AxisTitles(),
    rightTitles: const AxisTitles(),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 58,
        getTitlesWidget: (v, meta) {
          // Only grid-aligned values; the axis ends would otherwise crowd them.
          final steps = v / meta.appliedInterval;
          if ((steps - steps.round()).abs() > 1e-6) return const SizedBox.shrink();
          return SideTitleWidget(
            meta: meta,
            child: Text(_compact.format(v), style: t.textTheme.labelSmall?.copyWith(color: muted)),
          );
        },
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: 1,
        reservedSize: 28,
        getTitlesWidget: (v, meta) {
          final i = v.toInt();
          if (i < 0 || i >= pts.length || i % step != 0) return const SizedBox.shrink();
          return SideTitleWidget(
            meta: meta,
            child: Text(_axisLabel(pts[i].bucketStart, bucket), style: t.textTheme.labelSmall?.copyWith(color: muted)),
          );
        },
      ),
    ),
  );
}

FlGridData _grid(BuildContext context) {
  final s = Theme.of(context).colorScheme;
  return FlGridData(
    drawVerticalLine: false,
    getDrawingHorizontalLine: (v) => FlLine(color: v == 0 ? s.outline : s.outlineVariant.withValues(alpha: 0.5), strokeWidth: 1),
  );
}

double _rupees(Money m) => m.paise / 100;

/// Net booking-fee revenue vs approved expenses per period, as paired bars on
/// one rupee axis. Hover shows exact amounts; a table view lists every figure.
class RevenueExpenseChart extends StatefulWidget {
  const RevenueExpenseChart({super.key, required this.points, required this.bucket, this.height = 280});

  final List<FinancialPoint> points;
  final String bucket;
  final double height;

  @override
  State<RevenueExpenseChart> createState() => _RevenueExpenseChartState();
}

class _RevenueExpenseChartState extends State<RevenueExpenseChart> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = FinanceColors.of(context);
    final pts = widget.points;
    final header = Row(children: [
      Expanded(
        child: Wrap(spacing: 16, runSpacing: 6, children: [
          _Legend(color: c.revenue, label: 'Net revenue', bar: true),
          _Legend(color: c.expenses, label: 'Expenses', bar: true),
        ]),
      ),
      TextButton.icon(
        onPressed: () => setState(() => _table = !_table),
        icon: Icon(_table ? Icons.bar_chart_rounded : Icons.table_rows_outlined, size: 18),
        label: Text(_table ? 'Chart' : 'Table'),
      ),
    ]);
    if (pts.every((p) => p.netRevenue.isZero && p.operatingExpenses.isZero)) {
      return Column(children: [
        header,
        SizedBox(height: 140, child: Center(child: Text('No revenue or expenses in this period.', style: t.textTheme.bodyMedium))),
      ]);
    }
    if (_table) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, FinanceTable(points: pts, bucket: widget.bucket)]);

    // Bars thin out as the number of periods grows.
    final rodWidth = (420 / pts.length / 2.6).clamp(3.0, 18.0);
    BorderRadius ends(Money m) => m.isNegative
        ? const BorderRadius.vertical(bottom: Radius.circular(4))
        : const BorderRadius.vertical(top: Radius.circular(4));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      const SizedBox(height: 12),
      SizedBox(
        height: widget.height,
        child: _GrowIn(
          builder: (k) => BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              barGroups: [
                for (var i = 0; i < pts.length; i++)
                  BarChartGroupData(x: i, barsSpace: 2, barRods: [
                    BarChartRodData(toY: _rupees(pts[i].netRevenue) * k, width: rodWidth, color: c.revenue, borderRadius: ends(pts[i].netRevenue)),
                    BarChartRodData(
                        toY: _rupees(pts[i].operatingExpenses) * k, width: rodWidth, color: c.expenses, borderRadius: ends(pts[i].operatingExpenses)),
                  ]),
              ],
              gridData: _grid(context),
              borderData: FlBorderData(show: false),
              titlesData: _titles(context, pts, widget.bucket),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => t.colorScheme.inverseSurface,
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItem: (group, _, _, _) {
                    final p = pts[group.x];
                    final style = TextStyle(color: t.colorScheme.onInverseSurface, fontSize: 12);
                    return BarTooltipItem(
                      '${bucketLabel(p.bucketStart, widget.bucket)}\n',
                      style.copyWith(fontWeight: FontWeight.w700),
                      children: [
                        TextSpan(text: 'Net revenue ${p.netRevenue.format()}\n', style: style),
                        TextSpan(text: 'Expenses ${p.operatingExpenses.format()}\n', style: style),
                        TextSpan(text: 'Profit ${p.estimatedProfit.format()}', style: style.copyWith(fontWeight: FontWeight.w700)),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Estimated profit per period (or as a running total) as a line with a
/// filled area: aqua above zero, red below.
class ProfitTrendChart extends StatefulWidget {
  const ProfitTrendChart({super.key, required this.points, required this.bucket, this.height = 240});

  final List<FinancialPoint> points;
  final String bucket;
  final double height;

  @override
  State<ProfitTrendChart> createState() => _ProfitTrendChartState();
}

class _ProfitTrendChartState extends State<ProfitTrendChart> {
  bool _cumulative = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = FinanceColors.of(context);
    final pts = widget.points;
    final values = <int>[];
    var running = 0;
    for (final p in pts) {
      running += p.estimatedProfit.paise;
      values.add(_cumulative ? running : p.estimatedProfit.paise);
    }
    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        _Legend(color: c.profit, label: _cumulative ? 'Running profit' : 'Profit per period'),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: false, label: Text('Per period')),
            ButtonSegment(value: true, label: Text('Running total')),
          ],
          selected: {_cumulative},
          onSelectionChanged: (s) => setState(() => _cumulative = s.first),
        ),
      ],
    );
    if (values.every((v) => v == 0)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        SizedBox(height: 120, child: Center(child: Text('No profit or loss recorded in this period.', style: t.textTheme.bodyMedium))),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      const SizedBox(height: 12),
      SizedBox(
        height: widget.height,
        child: _GrowIn(
          builder: (k) => LineChart(
            LineChartData(
              lineBarsData: [
                LineChartBarData(
                  spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i] / 100 * k)],
                  color: c.profit,
                  barWidth: 2,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  dotData: FlDotData(
                    show: values.length <= 16,
                    getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
                      radius: 4,
                      color: spot.y < 0 ? c.loss : c.profit,
                      strokeWidth: 2,
                      strokeColor: t.colorScheme.surface,
                    ),
                  ),
                  belowBarData: BarAreaData(
                    show: true,
                    applyCutOffY: true,
                    cutOffY: 0,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [c.profit.withValues(alpha: 0.28), c.profit.withValues(alpha: 0.02)],
                    ),
                  ),
                  aboveBarData: BarAreaData(
                    show: true,
                    applyCutOffY: true,
                    cutOffY: 0,
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [c.loss.withValues(alpha: 0.28), c.loss.withValues(alpha: 0.02)],
                    ),
                  ),
                ),
              ],
              gridData: _grid(context),
              borderData: FlBorderData(show: false),
              titlesData: _titles(context, pts, widget.bucket),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => t.colorScheme.inverseSurface,
                  fitInsideHorizontally: true,
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        '${bucketLabel(pts[s.x.toInt()].bucketStart, widget.bucket)}\n'
                        '${_cumulative ? 'Running profit' : 'Profit'} ${Money(values[s.x.toInt()]).format()}',
                        TextStyle(color: t.colorScheme.onInverseSurface, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Every figure per period, with a totals row.
class FinanceTable extends StatelessWidget {
  const FinanceTable({super.key, required this.points, required this.bucket});

  final List<FinancialPoint> points;
  final String bucket;

  @override
  Widget build(BuildContext context) {
    Money sum(Money Function(FinancialPoint) f) => points.fold(const Money.zero(), (a, p) => a + f(p));
    final bold = Theme.of(context).textTheme.titleSmall;
    DataRow row(String label, List<Money> values, {bool total = false}) => DataRow(cells: [
          DataCell(Text(label, style: total ? bold : null)),
          for (final v in values) DataCell(MoneyText(v, style: total ? bold : null)),
        ]);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: Theme.of(context).textTheme.labelLarge,
        columns: const [
          DataColumn(label: Text('Period')),
          DataColumn(label: Text('Collected'), numeric: true),
          DataColumn(label: Text('Refunds'), numeric: true),
          DataColumn(label: Text('Gateway fees'), numeric: true),
          DataColumn(label: Text('Net revenue'), numeric: true),
          DataColumn(label: Text('Expenses'), numeric: true),
          DataColumn(label: Text('Est. profit'), numeric: true),
        ],
        rows: [
          for (final p in points)
            row(bucketLabel(p.bucketStart, bucket), [p.gross, p.refunds, p.processingFees, p.netRevenue, p.operatingExpenses, p.estimatedProfit]),
          row('Total', [
            sum((p) => p.gross),
            sum((p) => p.refunds),
            sum((p) => p.processingFees),
            sum((p) => p.netRevenue),
            sum((p) => p.operatingExpenses),
            sum((p) => p.estimatedProfit),
          ], total: true),
        ],
      ),
    );
  }
}

/// Labelled horizontal bars, largest first, that grow in. Used for expenses
/// by category and revenue by station.
class RankedBars extends StatelessWidget {
  const RankedBars({super.key, required this.items, this.color, this.emptyText = 'Nothing to show for this period.'});

  /// (label, caption, amount)
  final List<(String, String?, Money)> items;
  final Color? color;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (items.isEmpty) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text(emptyText, style: t.textTheme.bodyMedium)));
    }
    final colors = FinanceColors.of(context);
    final total = items.fold<int>(0, (a, i) => a + i.$3.paise.abs());
    final max = items.map((i) => i.$3.paise.abs()).fold<int>(1, (a, b) => b > a ? b : a);
    return Column(children: [
      for (final (i, item) in items.indexed)
        Entrance(
          index: i,
          offset: 8,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.$1, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                    if (item.$2 != null)
                      Text(item.$2!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant), overflow: TextOverflow.ellipsis),
                  ]),
                ),
                const SizedBox(width: 12),
                MoneyText(item.$3, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                SizedBox(
                  width: 48,
                  child: Text(
                    total == 0 ? '' : Fmt.percent(item.$3.paise.abs() / total),
                    textAlign: TextAlign.end,
                    style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              _Bar(fraction: item.$3.paise.abs() / max, color: item.$3.isNegative ? colors.loss : (color ?? colors.revenue)),
            ]),
          ),
        ),
    ]);
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 8,
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest)),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
              duration: Motion.reduced(context) ? Duration.zero : Motion.slow,
              curve: Motion.emphasized,
              builder: (context, x, _) => FractionallySizedBox(
                widthFactor: x,
                heightFactor: 1,
                child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
              ),
            ),
          ]),
        ),
      );
}
