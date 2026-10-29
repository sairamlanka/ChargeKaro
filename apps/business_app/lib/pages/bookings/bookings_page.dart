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
    final station = ref.watch(currentStationProvider);
    final live = station == null ? null : ref.watch(_liveProvider(station.id));
    final day = Fmt.toIst(DateTime.now()).add(Duration(days: offset));
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const StationSwitcher(),
        actions: [
          if (live != null && !live.hasError)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Tooltip(
                message: 'Updates appear automatically',
                child: Row(children: [
                  PulseDot(color: t.colorScheme.primary, size: 7),
                  Text('Live', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
                ]),
              ),
            ),
        ],
      ),
      body: Column(children: [
        _DayStrip(offset: offset, onSelect: ref.read(_dayProvider.notifier).set),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(_dayBookingsProvider),
            child: AnimatedSwitcher(
              duration: Motion.medium,
              switchInCurve: Motion.curve,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(a), child: child),
              ),
              child: KeyedSubtree(
                key: ValueKey(offset),
                child: AsyncView(
                  value: bookings,
                  onRetry: () => ref.invalidate(_dayBookingsProvider),
                  loading: const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 4)),
                  builder: (list) {
                    final visible = list.where((b) => b.status != BookingStatus.expired).toList();
                    if (visible.isEmpty) {
                      return ListView(children: [
                        EmptyState(
                          icon: Icons.event_available_rounded,
                          title: 'A quiet day',
                          message: 'Nothing booked on ${Fmt.dateOnly(day)}. New bookings appear here instantly.',
                        ),
                      ]);
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => Entrance(index: i, child: BookingTile(visible[i])),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _DayStrip extends StatefulWidget {
  const _DayStrip({required this.offset, required this.onSelect});
  final int offset;
  final ValueChanged<int> onSelect;

  @override
  State<_DayStrip> createState() => _DayStripState();
}

class _DayStripState extends State<_DayStrip> {
  // Starts with yesterday at the left edge so today is in view.
  final _scroll = ScrollController(initialScrollOffset: 2 * 66.0);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 84,
        child: ListView.builder(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          itemCount: 21,
          itemBuilder: (context, i) {
            final o = i - 3;
            return _DayPill(offset: o, selected: o == widget.offset, onTap: () => widget.onSelect(o));
          },
        ),
      );
}

class _DayPill extends StatelessWidget {
  const _DayPill({required this.offset, required this.selected, required this.onTap});
  final int offset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = Fmt.toIst(DateTime.now()).add(Duration(days: offset));
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final top = offset == 0 ? 'Today' : days[d.weekday - 1];
    final fg = selected ? Colors.white : t.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Semantics(
        selected: selected,
        button: true,
        label: offset == 0 ? 'Today' : Fmt.dateOnly(d),
        excludeSemantics: true,
        child: Pressable(
          child: GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: Motion.medium,
              curve: Motion.curve,
              width: 58,
              decoration: BoxDecoration(
                gradient: selected ? Brand.gradient : null,
                color: selected ? null : t.colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: selected ? Colors.transparent : t.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                boxShadow: selected ? [BoxShadow(color: Brand.green.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 6))] : const [],
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(top, style: t.textTheme.labelSmall?.copyWith(color: selected ? Colors.white70 : t.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text('${d.day}', style: t.textTheme.titleLarge?.copyWith(color: fg, fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class BookingTile extends StatelessWidget {
  const BookingTile(this.b, {super.key});
  final Booking b;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final accent = StatusChip.bookingTone(b.status).accent(t.colorScheme);
    final faded = b.status == BookingStatus.cancelled || b.status == BookingStatus.noShow;
    return Pressable(
      child: Card(
        child: InkWell(
          onTap: () => context.go('/bookings/${b.id}'),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 5, color: accent),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 0, 14),
                child: SizedBox(
                  width: 76,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(Fmt.time(b.startAt), style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                    Text(Fmt.time(b.endAt), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ),
              Expanded(
                child: Opacity(
                  opacity: faded ? 0.6 : 1,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 14, 14, 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(b.customerDisplayName ?? 'Customer', style: t.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(
                        [b.reference, if (b.chargingPointCode != null) 'Point ${b.chargingPointCode}', ?b.vehicleLabel].join(' · '),
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        StatusChip.booking(b.status),
                        if (!b.paymentStatus.settled) StatusChip.payment(b.paymentStatus),
                      ]),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
