import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

/// Gross booking-fee collections vs net revenue per bucket. One y-axis
/// (both in rupees), legend always shown, hover tooltip, and a table view.
class FinanceChart extends StatefulWidget {
  const FinanceChart({super.key, required this.points});

  final List<FinancialPoint> points;

  @override
  State<FinanceChart> createState() => _FinanceChartState();
}

class _FinanceChartState extends State<FinanceChart> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final gross = dark ? const Color(0xFF3987E5) : const Color(0xFF2A78D6);
    final net = dark ? const Color(0xFFD95926) : const Color(0xFFEB6834);
    final pts = widget.points;
    final muted = t.colorScheme.onSurfaceVariant;

    final header = Row(children: [
      _Legend(color: gross, label: 'Gross collections'),
      const SizedBox(width: 16),
      _Legend(color: net, label: 'Net revenue'),
      const Spacer(),
      TextButton.icon(
        onPressed: () => setState(() => _table = !_table),
        icon: Icon(_table ? Icons.show_chart : Icons.table_rows_outlined, size: 18),
        label: Text(_table ? 'Chart' : 'Table'),
      ),
    ]);

    if (pts.isEmpty) {
      return Column(children: [
        header,
        const SizedBox(height: 120, child: Center(child: Text('No booking-fee activity in this period.'))),
      ]);
    }

    if (_table) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Period')),
              DataColumn(label: Text('Gross'), numeric: true),
              DataColumn(label: Text('Refunds'), numeric: true),
              DataColumn(label: Text('Fees'), numeric: true),
              DataColumn(label: Text('Net'), numeric: true),
              DataColumn(label: Text('Expenses'), numeric: true),
              DataColumn(label: Text('Est. profit'), numeric: true),
            ],
            rows: [
              for (final p in pts)
                DataRow(cells: [
                  DataCell(Text(Fmt.dateOnly(p.bucketStart))),
                  DataCell(MoneyText(p.gross)),
                  DataCell(MoneyText(p.refunds)),
                  DataCell(MoneyText(p.processingFees)),
                  DataCell(MoneyText(p.netRevenue)),
                  DataCell(MoneyText(p.operatingExpenses)),
                  DataCell(MoneyText(p.estimatedProfit)),
                ]),
            ],
          ),
        ),
      ]);
    }

    double rupees(Money m) => m.paise / 100;
    LineChartBarData line(List<double> ys, Color c) => LineChartBarData(
          spots: [for (var i = 0; i < ys.length; i++) FlSpot(i.toDouble(), ys[i])],
          color: c,
          barWidth: 2,
          isCurved: false,
          dotData: FlDotData(show: ys.length <= 12),
        );
    final compact = NumberFormat.compactCurrency(locale: 'en_IN', symbol: '₹');
    final label = DateFormat('d MMM');
    final step = (pts.length / 6).ceil().clamp(1, 1000);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      const SizedBox(height: 8),
      SizedBox(
        height: 260,
        child: LineChart(LineChartData(
          lineBarsData: [
            line([for (final p in pts) rupees(p.gross)], gross),
            line([for (final p in pts) rupees(p.netRevenue)], net),
          ],
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: t.colorScheme.outlineVariant.withValues(alpha: 0.5), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 56,
                getTitlesWidget: (v, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(compact.format(v), style: t.textTheme.labelSmall?.copyWith(color: muted)),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i < 0 || i >= pts.length || i % step != 0) return const SizedBox.shrink();
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(label.format(pts[i].bucketStart), style: t.textTheme.labelSmall?.copyWith(color: muted)),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => t.colorScheme.inverseSurface,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${s.barIndex == 0 ? 'Gross' : 'Net'} ${label.format(pts[s.x.toInt()].bucketStart)}: '
                    '${Money((s.y * 100).round()).format()}',
                    TextStyle(color: t.colorScheme.onInverseSurface, fontSize: 12),
                  ),
              ],
            ),
          ),
        )),
      ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 14, height: 3, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ]);
}
