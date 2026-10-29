import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../providers.dart';
import '../shell.dart';
import '../widgets/finance_chart.dart';
import '../widgets/range_picker.dart';
import 'finance_expenses_tab.dart';
import 'finance_reports_tab.dart';
import 'finance_revenue_tab.dart';

final _paymentsProvider = FutureProvider.autoDispose<List<PaymentRecord>>((ref) => ref.watch(financeRepositoryProvider).payments());
final _refundsProvider = FutureProvider.autoDispose<List<RefundRecord>>((ref) => ref.watch(financeRepositoryProvider).refunds());

/// Booking-fee finance. Figures are derived from the immutable ledger by
/// get_financial_summary() and friends; definitions are in docs/finance.md.
class FinancePage extends ConsumerWidget {
  const FinancePage({super.key});

  static const tabs = ['Overview', 'Booking revenue', 'Expenses', 'Reports', 'Payments', 'Refunds'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RequiresPermission(
      PlatformPermission.financeRead,
      child: DefaultTabController(
        length: tabs.length,
        child: PageFrame(
          title: 'Finance',
          scroll: false,
          actions: [RangePicker(value: ref.watch(financeRangeProvider), onChanged: ref.read(financeRangeProvider.notifier).set)],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) Tab(text: t)]),
            const SizedBox(height: 16),
            const Expanded(
              child: TabBarView(children: [
                FinanceOverviewTab(),
                FinanceRevenueTab(),
                FinanceExpensesTab(),
                FinanceReportsTab(),
                _Payments(),
                _Refunds(),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Responsive grid of tiles that cascade in.
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.tiles, this.minWidth = 210});
  final List<Widget> tiles;
  final double minWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final cols = (c.maxWidth / minWidth).floor().clamp(1, 6);
        final w = (c.maxWidth - (cols - 1) * 14) / cols;
        return Wrap(spacing: 14, runSpacing: 14, children: [
          for (final (i, tile) in tiles.indexed) SizedBox(width: w, child: Entrance(index: i, child: tile)),
        ]);
      });
}

String money(num paise) => Money(paise.round()).format();

class FinanceOverviewTab extends ConsumerWidget {
  const FinanceOverviewTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(financeSummaryProvider);
    final series = ref.watch(financeSeriesProvider);
    final stations = ref.watch(revenueByStationProvider);
    final range = ref.watch(financeRangeProvider);
    final bucket = ref.watch(financeBucketProvider) ?? autoBucket(range);
    final c = FinanceColors.of(context);
    final t = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AsyncView(
          value: summary,
          onRetry: () => ref.invalidate(financeSummaryProvider),
          builder: (s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Entrance(
              child: HeroHeader(
                eyebrow: '${Fmt.dateOnly(range.from)} – ${Fmt.dateOnly(range.to)}',
                title: s.estimatedProfit.isNegative ? 'Running at a loss this period' : 'Your booking-fee earnings',
                subtitle: '${s.successfulPayments} paid booking${s.successfulPayments == 1 ? '' : 's'} at '
                    '${(s.successfulPayments == 0 ? const Money.zero() : Money(s.gross.paise ~/ s.successfulPayments)).format()} average fee',
                child: _HeroMoney(summary: s),
              ),
            ),
            if (!s.isConsistent)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: StatusChip('Totals do not reconcile. Check the ledger before relying on these figures.', tone: StatusTone.danger),
              ),
            const SizedBox(height: 20),
            TileGrid(tiles: [
              MetricTile(
                label: 'Fees collected',
                count: s.gross.paise,
                format: money,
                caption: '${s.successfulPayments} paid · ${s.failedPayments} failed',
                icon: Icons.payments_rounded,
                accent: c.revenue,
              ),
              MetricTile(
                label: 'Refunds',
                count: s.refunds.paise,
                format: money,
                caption: '${s.refundCount} processed · ${s.pendingRefunds.format()} pending',
                icon: Icons.undo_rounded,
                accent: Brand.amber,
              ),
              MetricTile(
                label: 'Gateway fees',
                count: s.processingFees.paise,
                format: money,
                caption: 'incl. ${s.processingFeeTax.format()} GST',
                icon: Icons.account_balance_rounded,
                accent: t.colorScheme.outline,
              ),
              MetricTile(
                label: 'Net revenue',
                count: s.netRevenue.paise,
                format: money,
                caption: 'after refunds and gateway fees',
                icon: Icons.account_balance_wallet_rounded,
                accent: c.revenue,
              ),
              MetricTile(
                label: 'Expenses',
                count: s.operatingExpenses.paise,
                format: money,
                caption: 'approved in this period',
                icon: Icons.receipt_long_rounded,
                accent: c.expenses,
                onTap: () => DefaultTabController.of(context).animateTo(2),
              ),
              MetricTile(
                label: 'Estimated profit',
                count: s.estimatedProfit.paise,
                format: money,
                caption: 'net revenue − expenses',
                icon: s.estimatedProfit.isNegative ? Icons.trending_down_rounded : Icons.trending_up_rounded,
                accent: s.estimatedProfit.isNegative ? c.loss : c.profit,
              ),
            ]),
          ]),
        ),
        const SizedBox(height: 20),
        Entrance(
          index: 2,
          child: SectionCard(
            title: 'Revenue vs expenses',
            trailing: BucketPicker(range: range),
            child: AsyncView(
              value: series,
              onRetry: () => ref.invalidate(financeSeriesProvider),
              builder: (p) => RevenueExpenseChart(points: p, bucket: bucket),
            ),
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, box) {
          final pnl = AsyncView(
            value: summary,
            onRetry: () => ref.invalidate(financeSummaryProvider),
            builder: (s) => SectionCard(title: 'Profit and loss', child: ProfitAndLoss(summary: s)),
          );
          final categories = AsyncView(
            value: summary,
            onRetry: () => ref.invalidate(financeSummaryProvider),
            builder: (s) => SectionCard(
              title: 'Expenses by category',
              child: RankedBars(
                color: c.expenses,
                emptyText: 'No approved expenses in this period.',
                items: [for (final e in s.expensesByCategory.entries) (e.key, null, e.value)],
              ),
            ),
          );
          final top = SectionCard(
            title: 'Top stations by revenue',
            trailing: TextButton(onPressed: () => DefaultTabController.of(context).animateTo(1), child: const Text('All bookings')),
            child: AsyncView(
              value: stations,
              onRetry: () => ref.invalidate(revenueByStationProvider),
              builder: (list) => RankedBars(
                emptyText: 'No booking fees collected in this period.',
                items: [
                  for (final s in list.take(5))
                    (s.stationName, '${s.businessName}${s.city == null ? '' : ' · ${s.city}'} · ${s.paidBookings} paid', s.net),
                ],
              ),
            ),
          );
          if (box.maxWidth < 900) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Entrance(index: 3, child: pnl),
              const SizedBox(height: 16),
              Entrance(index: 4, child: top),
              const SizedBox(height: 16),
              Entrance(index: 5, child: categories),
            ]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Entrance(index: 3, child: pnl)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Entrance(index: 4, child: top),
                const SizedBox(height: 16),
                Entrance(index: 5, child: categories),
              ]),
            ),
          ]);
        }),
        const SizedBox(height: 12),
        Text(
          'The platform only earns the booking fee. Charging fees are paid to stations directly and never appear here.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

/// Net revenue, expenses and profit as big white figures on the hero card.
class _HeroMoney extends StatelessWidget {
  const _HeroMoney({required this.summary});
  final FinancialSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget stat(String label, Money m, IconData icon) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: CountUp(m.paise, format: money, style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                ),
              ),
              Icon(icon, size: 18, color: Colors.white70),
            ]),
            Text(label, style: t.textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85))),
          ]),
        );
    final items = [
      stat('Net revenue', summary.netRevenue, Icons.account_balance_wallet_rounded),
      stat('Expenses', summary.operatingExpenses, Icons.receipt_long_rounded),
      stat('Estimated profit', summary.estimatedProfit, Icons.savings_rounded),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 640 ? 3 : 1;
      final w = (c.maxWidth - (cols - 1) * 10) / cols;
      return Wrap(spacing: 10, runSpacing: 10, children: [for (final s in items) SizedBox(width: w, child: s)]);
    });
  }
}

/// Day / week / month switch for charts and reports. "Auto" follows the range.
class BucketPicker extends ConsumerWidget {
  const BucketPicker({super.key, required this.range});
  final DateRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(financeBucketProvider) ?? autoBucket(range);
    final tooLong = range.to.difference(range.from).inDays > 120;
    return SegmentedButton<String>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        ButtonSegment(value: 'day', label: const Text('Daily'), enabled: !tooLong),
        const ButtonSegment(value: 'week', label: Text('Weekly')),
        const ButtonSegment(value: 'month', label: Text('Monthly')),
      ],
      selected: {if (!(tooLong && selected == 'day')) selected},
      emptySelectionAllowed: true,
      onSelectionChanged: (s) => ref.read(financeBucketProvider.notifier).set(s.isEmpty ? null : s.first),
    );
  }
}

/// The summary as a statement: collections down to estimated profit.
class ProfitAndLoss extends StatelessWidget {
  const ProfitAndLoss({super.key, required this.summary});
  final FinancialSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Column(children: [
      _Line('Booking fees collected', s.gross, note: '${s.successfulPayments} successful payments'),
      _Line('Refunds', Money(-s.refunds.paise), note: '${s.refundCount} processed · ${s.pendingRefunds.format()} pending'),
      _Line('Payment gateway fees', Money(-s.processingFees.paise), note: 'includes ${s.processingFeeTax.format()} GST on fees'),
      const Divider(),
      _Line('Net booking-fee revenue', s.netRevenue, bold: true),
      _Line('Approved operating expenses', Money(-s.operatingExpenses.paise)),
      for (final e in s.expensesByCategory.entries) _Line('   ${e.key}', Money(-e.value.paise), small: true),
      const Divider(),
      _Line('Estimated operating profit', s.estimatedProfit, bold: true, note: 'before tax; not an accounting statement'),
    ]);
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.amount, {this.note, this.bold = false, this.small = false});
  final String label;
  final Money amount;
  final String? note;
  final bool bold;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final style = small ? t.bodySmall : (bold ? t.titleSmall : t.bodyMedium);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: style),
            if (note != null) Text(note!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        MoneyText(amount, style: style),
      ]),
    );
  }
}

class _Payments extends ConsumerWidget {
  const _Payments();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
        value: ref.watch(_paymentsProvider),
        onRetry: () => ref.invalidate(_paymentsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.payments_outlined, title: 'No payments yet', message: 'Payments appear once Razorpay is connected and customers pay booking fees.')
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = list[i];
                  return ListTile(
                    title: Text('${p.amount.format()} · ${p.bookingReference ?? ''}'),
                    subtitle: Text([
                      p.gatewayPaymentId,
                      Fmt.dateTime(p.createdAt),
                      if (p.method != null) p.method!,
                      if (p.fee != null) 'fee ${p.fee!.format()}',
                      if (p.errorDescription != null) p.errorDescription!,
                    ].join(' · ')),
                    trailing: StatusChip(p.status.label,
                        tone: switch (p.status.wire) { 'captured' => StatusTone.success, 'failed' => StatusTone.danger, _ => StatusTone.warning }),
                  );
                },
              ),
      );
}

class _Refunds extends ConsumerWidget {
  const _Refunds();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
        value: ref.watch(_refundsProvider),
        onRetry: () => ref.invalidate(_refundsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.undo, title: 'No refunds')
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = list[i];
                  return ListTile(
                    title: Text('${r.amount.format()} · ${r.reason}'),
                    subtitle: Text([
                      Fmt.dateTime(r.createdAt),
                      r.isAutomatic ? 'automatic' : 'manual',
                      if (r.gatewayRefundId != null) r.gatewayRefundId!,
                      if (r.failureReason != null) r.failureReason!,
                    ].join(' · ')),
                    trailing: StatusChip.refund(r.status),
                  );
                },
              ),
      );
}
