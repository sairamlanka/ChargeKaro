import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../state.dart';
import '../../widgets/station_switcher.dart';

/// IST calendar day being viewed, as an offset from today.
class _DayOffset extends Notifier<int> {
  @override
  int build() => 0;
  void set(int v) => state = v;
}

final _dayProvider = NotifierProvider<_DayOffset, int>(_DayOffset.new);

final _dayBookingsProvider = FutureProvider.autoDispose<List<Booking>>((ref) async {
  final station = ref.watch(currentStationProvider);
  if (station == null) return const [];
  // Refetch whenever a booking event for this station arrives.
  ref.watch(_liveProvider(station.id));
  final offset = ref.watch(_dayProvider);
  final ist = Fmt.toIst(DateTime.now()).add(Duration(days: offset));
  final from = Fmt.fromIst(ist.year, ist.month, ist.day);
  return ref.watch(bookingRepositoryProvider).forStation(station.id, from, from.add(const Duration(days: 1)));
});

final _liveProvider = StreamProvider.autoDispose.family<void, String>((ref, stationId) => ref.watch(bookingRepositoryProvider).stationChanges(stationId));

class BookingsPage extends ConsumerWidget {
  const BookingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offset = ref.watch(_dayProvider);
    final bookings = ref.watch(_dayBookingsProvider);
    final day = Fmt.toIst(DateTime.now()).add(Duration(days: offset));
    return Scaffold(
      appBar: AppBar(title: const StationSwitcher()),
      body: Column(children: [
        SizedBox(
          height: 64,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: 21,
            itemBuilder: (context, i) {
              final o = i - 3;
              final d = Fmt.toIst(DateTime.now()).add(Duration(days: o));
              return Padding(
                padding: const EdgeInsets.all(4),
                child: ChoiceChip(
                  selected: o == offset,
                  label: Text(o == 0 ? 'Today' : (o == 1 ? 'Tomorrow' : '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1]} ${d.day}')),
                  onSelected: (_) => ref.read(_dayProvider.notifier).set(o),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(_dayBookingsProvider),
            child: AsyncView(
              value: bookings,
              onRetry: () => ref.invalidate(_dayBookingsProvider),
              builder: (list) {
                final visible = list.where((b) => b.status != BookingStatus.expired).toList();
                if (visible.isEmpty) {
                  return ListView(children: [
                    EmptyState(icon: Icons.event_available, title: 'No bookings', message: 'Nothing booked on ${day.day}/${day.month}.'),
                  ]);
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => BookingTile(visible[i]),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class BookingTile extends StatelessWidget {
  const BookingTile(this.b, {super.key});
  final Booking b;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          title: Text('${Fmt.time(b.startAt)}–${Fmt.time(b.endAt)} · ${b.chargingPointCode ?? ''}'),
          subtitle: Text([b.reference, b.customerDisplayName ?? 'Customer', if (b.vehicleLabel != null) b.vehicleLabel!].join(' · ')),
          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            StatusChip.booking(b.status),
            if (!b.paymentStatus.settled) Padding(padding: const EdgeInsets.only(top: 2), child: StatusChip.payment(b.paymentStatus)),
          ]),
          onTap: () => context.go('/bookings/${b.id}'),
        ),
      );
}
