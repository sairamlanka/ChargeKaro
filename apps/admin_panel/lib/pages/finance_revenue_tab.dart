import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../export/csv.dart';
import '../export/download.dart';
import '../providers.dart';
import '../widgets/finance_chart.dart';
import 'finance_page.dart';

typedef _RevenueQuery = ({String? stationId, String search, int pages});

class _QueryNotifier extends Notifier<_RevenueQuery> {
  @override
  _RevenueQuery build() {
    ref.watch(financeRangeProvider);
    return (stationId: null, search: '', pages: 1);
  }

  void station(String? id) => state = (stationId: id, search: state.search, pages: 1);
  void search(String text) => state = (stationId: state.stationId, search: text, pages: 1);
  void more() => state = (stationId: state.stationId, search: state.search, pages: state.pages + 1);
}

final _queryProvider = NotifierProvider.autoDispose<_QueryNotifier, _RevenueQuery>(_QueryNotifier.new);

const _pageSize = 50;

final _revenueProvider = FutureProvider.autoDispose<BookingRevenueReport>((ref) {
  final r = ref.watch(financeRangeProvider);
  final q = ref.watch(_queryProvider);
  return ref
      .watch(financeRepositoryProvider)
      .bookingRevenue(r.from, r.to, stationId: q.stationId, search: q.search, limit: _pageSize * q.pages);
});

/// Who booked, where, and what each booking earned the platform.
class FinanceRevenueTab extends ConsumerStatefulWidget {
  const FinanceRevenueTab({super.key});

  @override
  ConsumerState<FinanceRevenueTab> createState() => _FinanceRevenueTabState();
}

class _FinanceRevenueTabState extends ConsumerState<FinanceRevenueTab> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final r = ref.read(financeRangeProvider);
    final q = ref.read(_queryProvider);
    final repo = ref.read(financeRepositoryProvider);
    await runAction(context, () async {
      final rows = <BookingRevenueRow>[];
      // Pages of 500 until everything matching the filter is fetched.
      for (var offset = 0;; offset += 500) {
        final page = await repo.bookingRevenue(r.from, r.to, stationId: q.stationId, search: q.search, limit: 500, offset: offset);
        rows.addAll(page.rows);
        if (rows.length >= page.totalCount || page.rows.isEmpty) break;
      }
      await downloadTextFile('chargekaro-booking-revenue-${_stamp(r)}.csv', bookingRevenueCsv(rows));
    }, success: 'Booking revenue exported.');
  }

  @override
  Widget build(BuildContext context) {
    final stations = ref.watch(revenueByStationProvider);
    final report = ref.watch(_revenueProvider);
    final q = ref.watch(_queryProvider);
    final t = Theme.of(context);

    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: AsyncView(
          value: report,
          onRetry: () => ref.invalidate(_revenueProvider),
          builder: (r) => TileGrid(minWidth: 190, tiles: [
            MetricTile(label: 'Paid bookings', count: r.paidBookings, icon: Icons.event_available_rounded, accent: Brand.ocean),
            MetricTile(label: 'Fees collected', count: r.gross.paise, format: money, icon: Icons.payments_rounded, accent: FinanceColors.of(context).revenue),
            MetricTile(
                label: 'Refunds + gateway fees', count: (r.refunds + r.fees).paise, format: money, icon: Icons.remove_circle_outline_rounded, accent: Brand.amber),
            MetricTile(label: 'Net revenue', count: r.net.paise, format: money, icon: Icons.account_balance_wallet_rounded, accent: FinanceColors.of(context).profit),
          ]),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
      SliverToBoxAdapter(
        child: Entrance(
          index: 1,
          child: SectionCard(
            title: 'Revenue by station',
            child: AsyncView(
              value: stations,
              onRetry: () => ref.invalidate(revenueByStationProvider),
              builder: (list) => list.isEmpty
                  ? const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No booking fees collected in this period.'))
                  : _StationTable(list: list, selected: q.stationId, onSelect: ref.read(_queryProvider.notifier).station),
            ),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
      SliverToBoxAdapter(
        child: Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 320,
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Booking ID, customer or station',
                isDense: true,
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _search.clear();
                          ref.read(_queryProvider.notifier).search('');
                          setState(() {});
                        },
                      ),
              ),
              onChanged: (v) {
                setState(() {});
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), () => ref.read(_queryProvider.notifier).search(v));
              },
            ),
          ),
          if (q.stationId != null)
            InputChip(
              avatar: const Icon(Icons.ev_station_rounded, size: 18),
              label: Text(stations.value?.where((s) => s.stationId == q.stationId).firstOrNull?.stationName ?? 'Station'),
              onDeleted: () => ref.read(_queryProvider.notifier).station(null),
            ),
          OutlinedButton.icon(onPressed: _export, icon: const Icon(Icons.download_rounded, size: 18), label: const Text('Export CSV')),
        ]),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ...switch (report) {
        AsyncValue(:final value?) when value.rows.isEmpty => [
            const SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No paid bookings',
                message: 'Bookings appear here as soon as a customer pays the booking fee.',
              ),
            ),
          ],
        AsyncValue(:final value?) => [
            SliverList.builder(
              itemCount: value.rows.length,
              itemBuilder: (context, i) => Entrance(index: i % _pageSize, child: _BookingRow(row: value.rows[i])),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: value.rows.length < value.totalCount
                      ? OutlinedButton(
                          onPressed: ref.read(_queryProvider.notifier).more,
                          child: Text('Show more (${value.totalCount - value.rows.length} left)'),
                        )
                      : Text('${value.totalCount} booking${value.totalCount == 1 ? '' : 's'}',
                          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
              ),
            ),
          ],
        AsyncValue(:final error?) => [
            SliverToBoxAdapter(child: ErrorState(failure: AppFailure.from(error), onRetry: () => ref.invalidate(_revenueProvider))),
          ],
        _ => [const SliverToBoxAdapter(child: SkeletonList())],
      },
    ]);
  }
}

String _stamp(DateRange r) => '${r.from.toIso8601String().substring(0, 10)}_to_${r.to.toIso8601String().substring(0, 10)}';

class _StationTable extends StatelessWidget {
  const _StationTable({required this.list, required this.selected, required this.onSelect});
  final List<StationRevenue> list;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final total = list.fold<int>(0, (a, s) => a + s.net.paise);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        showCheckboxColumn: false,
        headingTextStyle: Theme.of(context).textTheme.labelLarge,
        columns: const [
          DataColumn(label: Text('Station')),
          DataColumn(label: Text('Business')),
          DataColumn(label: Text('Paid bookings'), numeric: true),
          DataColumn(label: Text('Collected'), numeric: true),
          DataColumn(label: Text('Refunds'), numeric: true),
          DataColumn(label: Text('Gateway fees'), numeric: true),
          DataColumn(label: Text('Net revenue'), numeric: true),
          DataColumn(label: Text('Share')),
        ],
        rows: [
          for (final s in list)
            DataRow(
              selected: s.stationId == selected,
              onSelectChanged: (_) => onSelect(s.stationId == selected ? null : s.stationId),
              cells: [
                DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(s.stationName),
                  if (s.isDemo) ...[const SizedBox(width: 6), const DemoBadge()],
                ])),
                DataCell(Text([s.businessName, if (s.city != null) s.city!].join(' · '))),
                DataCell(Text('${s.paidBookings}')),
                DataCell(MoneyText(s.gross)),
                DataCell(MoneyText(s.refunds)),
                DataCell(MoneyText(s.fees)),
                DataCell(MoneyText(s.net, style: const TextStyle(fontWeight: FontWeight.w700))),
                DataCell(SizedBox(
                  width: 110,
                  child: GradientProgressBar(value: total <= 0 ? 0 : s.net.paise / total, height: 8, semanticsLabel: 'Share of net revenue'),
                )),
              ],
            ),
        ],
      ),
    );
  }
}

class _BookingRow extends StatelessWidget {
  const _BookingRow({required this.row});
  final BookingRevenueRow row;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final c = FinanceColors.of(context);
    final initials = row.customerName.trim().isEmpty ? '?' : row.customerName.trim()[0].toUpperCase();
    final amounts = Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      MoneyText(row.net, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      Text(
        [
          'paid ${row.gross.format()}',
          if (!row.refunds.isZero) 'refunded ${row.refunds.format()}',
          if (!row.fees.isZero) 'fees ${row.fees.format()}',
        ].join(' · '),
        style: muted,
      ),
    ]);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(builder: (context, box) {
          final details = Row(children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: c.revenue.withValues(alpha: 0.12),
              child: Text(initials, style: TextStyle(color: c.revenue, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(row.customerName, style: t.textTheme.titleSmall),
                  SelectableText(row.reference, style: t.textTheme.labelMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  StatusChip.booking(row.status),
                  StatusChip.payment(row.paymentStatus),
                ]),
                const SizedBox(height: 4),
                Text('${row.stationName}${row.city == null ? '' : ', ${row.city}'} · ${row.businessName}', style: muted),
                Text(
                  'Slot ${Fmt.slot(row.slotStart, row.slotEnd)}${row.paidAt == null ? '' : ' · paid ${Fmt.dateTime(row.paidAt!)}'}',
                  style: muted,
                ),
              ]),
            ),
          ]);
          if (box.maxWidth < 620) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [details, const SizedBox(height: 8), amounts]);
          }
          return Row(children: [Expanded(child: details), const SizedBox(width: 16), amounts]);
        }),
      ),
    );
  }
}
