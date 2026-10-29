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
  final bucket = ref.watch(financeBucketProvider) ?? autoBucket(r);
  return ref.watch(financeRepositoryProvider).timeseries(r.from, r.to, bucket: bucket);
});

/// Chart / report granularity. Null picks one from the range length.
class BucketNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? bucket) => state = bucket;
}

final financeBucketProvider = NotifierProvider<BucketNotifier, String?>(BucketNotifier.new);

String autoBucket(DateRange r) {
  final days = r.to.difference(r.from).inDays;
  return days > 180 ? 'month' : (days > 45 ? 'week' : 'day');
}

final revenueByStationProvider = FutureProvider.autoDispose<List<StationRevenue>>((ref) {
  final r = ref.watch(financeRangeProvider);
  return ref.watch(financeRepositoryProvider).revenueByStation(r.from, r.to);
});

final financeExpensesProvider = FutureProvider.autoDispose<List<Expense>>((ref) {
  final r = ref.watch(financeRangeProvider);
  return ref.watch(financeRepositoryProvider).expenses(from: r.from, to: r.to);
});

final expenseCategoriesProvider =
    FutureProvider.autoDispose<List<ExpenseCategory>>((ref) => ref.watch(financeRepositoryProvider).categories());

/// Refreshes every finance figure after a write.
void refreshFinance(WidgetRef ref) {
  ref.invalidate(financeExpensesProvider);
  ref.invalidate(financeSummaryProvider);
  ref.invalidate(financeSeriesProvider);
  ref.invalidate(revenueByStationProvider);
}
