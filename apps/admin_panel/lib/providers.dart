import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';

/// Inclusive date range used by dashboard and finance pages.
typedef DateRange = ({DateTime from, DateTime to});

DateRange lastDays(int days) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return (from: today.subtract(Duration(days: days - 1)), to: today);
}

class RangeNotifier extends Notifier<DateRange> {
  @override
  DateRange build() => lastDays(30);

  void set(DateRange range) => state = range;
}

final dashboardRangeProvider = NotifierProvider<RangeNotifier, DateRange>(RangeNotifier.new);

final dashboardProvider = FutureProvider.autoDispose<DashboardMetrics>((ref) {
  final r = ref.watch(dashboardRangeProvider);
  return ref.watch(adminRepositoryProvider).dashboard(from: r.from, to: r.to);
});

final financeRangeProvider = NotifierProvider<RangeNotifier, DateRange>(RangeNotifier.new);

final financeSummaryProvider = FutureProvider.autoDispose<FinancialSummary>((ref) {
  final r = ref.watch(financeRangeProvider);
  return ref.watch(financeRepositoryProvider).summary(r.from, r.to);
});

final financeSeriesProvider = FutureProvider.autoDispose<List<FinancialPoint>>((ref) {
  final r = ref.watch(financeRangeProvider);
  final days = r.to.difference(r.from).inDays;
  final bucket = days > 180 ? 'month' : (days > 45 ? 'week' : 'day');
  return ref.watch(financeRepositoryProvider).timeseries(r.from, r.to, bucket: bucket);
});
