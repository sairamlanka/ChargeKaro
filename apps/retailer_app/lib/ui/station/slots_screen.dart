import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../../state/providers.dart';
import '../booking/reserve.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import 'station_screen.dart';

/// The station page. Slot booking comes first: pick a date, a length and a
/// start time; what else there is to know about the station is below the
/// grid. The customer does not pick a charging point: any compatible point that is
/// free for the whole time is assigned when the hold is made, so a time is
/// "full" only when every point is taken. The grid is a snapshot; it
/// refreshes every minute and the server re-checks before reserving.
class SlotsScreen extends ConsumerStatefulWidget {
  const SlotsScreen({super.key, required this.stationId, this.initialDate});
  final String stationId;

  /// IST calendar date to open on, e.g. the day of the next free slot.
  final DateTime? initialDate;

  @override
  ConsumerState<SlotsScreen> createState() => _SlotsScreenState();
}

class _SlotsScreenState extends ConsumerState<SlotsScreen> {
  late DateTime _date = _startDate();

  /// Connector wire value the customer needs, or null for any.
  String? _connector;
  int? _minutes;
  DateTime? _start;
  Timer? _refresh;

  /// Why a refresh dropped the chosen time, shown until the next choice:
  /// someone else took it, or the clock passed it.
  String? _lostReason;
  bool _continuing = false;

  DateTime _startDate() {
    final today = RFmt.istDate(DateTime.now());
    final d = widget.initialDate;
    if (d == null || d.isBefore(today) || d.difference(today).inDays > 30) return today;
    return DateTime.utc(d.year, d.month, d.day);
  }

  SlotQuery get _query => (stationId: widget.stationId, date: _date);

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      // Past midnight (IST) the old day can't be booked any more.
      final today = RFmt.istDate(DateTime.now());
      if (_date.isBefore(today)) {
        _setDate(today);
      } else if (_start != null && _startedOrTooSoon(_start!)) {
        setState(() {
          _start = null;
          _lostReason = context.l(K.slotTimePassed);
        });
      }
      ref.invalidate(slotsProvider(_query));
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _setDate(DateTime d) => setState(() {
        _date = d;
        _start = null;
        _lostReason = null;
      });

  /// True once [t] has started or is inside the station's minimum notice.
  bool _startedOrTooSoon(DateTime t) {
    final notice = ref.read(stationProvider(widget.stationId)).value?.policy.minAdvanceMinutes ?? 0;
    return !t.isAfter(DateTime.now().add(Duration(minutes: notice)));
  }

  /// Keeps the selection consistent with a freshly loaded grid. A time that
  /// is no longer free is dropped with the reason (taken, or passed).
  void _reconcile(SlotGrid grid) {
    final types = grid.connectorTypes.map((c) => c.wire).toSet();
    if (_connector != null && !types.contains(_connector)) _connector = null;
    final options = _durations(grid);
    if (_minutes == null || !options.contains(_minutes)) _minutes = options.isEmpty ? null : options.first;
    if (_start != null && (_minutes == null || !_freeAt(grid, _start!, _minutes!))) {
      _lostReason = _startedOrTooSoon(_start!) ? context.l(K.slotTimePassed) : context.l(K.slotJustTaken);
      _start = null;
    }
  }

  /// After the customer changes the connector or length: keep the chosen
  /// time if it still fits, otherwise drop it and say why.
  void _afterChoiceChange(SlotGrid grid, String message) {
    if (_start != null && (_minutes == null || !_freeAt(grid, _start!, _minutes!))) {
      _start = null;
      _snack(message);
    }
  }

  /// The customer's own bookings that would overlap [minutes] from [t].
  /// One vehicle can't be in two places, so these times can't be booked
  /// again (the server refuses them too).
  CustomerBooking? _ownAt(List<CustomerBooking> mine, DateTime t, int minutes) {
    final end = t.add(Duration(minutes: minutes));
    final now = DateTime.now();
    for (final b in mine) {
      final phase = b.phaseAt(now);
      final active = phase == CustomerPhase.pendingPayment ||
          phase == CustomerPhase.paymentProcessing ||
          phase == CustomerPhase.paymentFailed ||
          phase == CustomerPhase.confirmed ||
          phase == CustomerPhase.checkedIn;
      if (active && t.isBefore(b.endAt) && end.isAfter(b.startAt)) return b;
    }
    return null;
  }

  List<CustomerBooking> get _mine => ref.read(myBookingsProvider).value ?? const [];

  bool _freeAt(SlotGrid grid, DateTime t, int minutes) =>
      grid.pointsFor(_connector).any((p) => p.point.bookable && p.fits(t, minutes, grid.slotMinutes));

  /// Lengths from the station minimum up to the longest any compatible
  /// point allows, in grid steps (e.g. 30, 45, 60 ... minutes).
  List<int> _durations(SlotGrid grid) {
    final points = grid.pointsFor(_connector).where((p) => p.point.bookable);
    if (points.isEmpty) return const [];
    final pointMax = points.map((p) => p.point.maxBookingMinutes).reduce((a, b) => a > b ? a : b);
    final policyMax = ref.read(stationProvider(widget.stationId)).value?.policy.maxBookingMinutes ?? pointMax;
    final max = policyMax < pointMax ? policyMax : pointMax;
    return [for (var m = grid.minBookingMinutes; m <= max; m += grid.slotMinutes) m];
  }

  void _tapCell(SlotGrid grid, StationCell c) {
    final l = context.l;
    final mins = _minutes;
    if (mins == null) return;
    final own = _ownAt(_mine, c.start, mins);
    if (own != null) {
      _explainOwn(own);
      return;
    }
    if (!c.canBook) {
      // A shorter length may still fit here.
      final fitting = _durations(grid).reversed
          .where((m) => m < mins && _freeAt(grid, c.start, m) && _ownAt(_mine, c.start, m) == null)
          .firstOrNull;
      if (fitting != null && (c.tooLong || c.state == SlotState.booked)) {
        setState(() {
          _minutes = fitting;
          _start = c.start;
          _lostReason = null;
        });
        _snack(l(K.slotLengthAdjusted, {'d': RFmt(l).duration(Duration(minutes: fitting))}));
        return;
      }
      _explain(c);
      return;
    }
    setState(() {
      _start = c.start;
      _lostReason = null;
    });
  }

  void _explainOwn(CustomerBooking b) {
    final l = context.l;
    final pending = b.phaseAt(DateTime.now()) == CustomerPhase.pendingPayment || b.phaseAt(DateTime.now()) == CustomerPhase.paymentFailed;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(pending ? l(K.slotYoursHoldHint) : l(K.slotYoursHint)),
        action: SnackBarAction(
          label: pending ? l(K.continueToPayment) : l(K.viewBooking),
          onPressed: () => context.push(pending ? '/book/pay/${b.id}' : '/booking/${b.id}'),
        ),
      ));
  }

  void _explain(StationCell c) {
    final l = context.l;
    _snack(switch (c.state) {
      _ when c.tooLong => l(K.slotTooShortHint),
      SlotState.booked || SlotState.reserved => l(K.slotFullHint),
      SlotState.blocked => l(K.slotBlockedHint),
      SlotState.closed => l(K.slotClosedHint),
      SlotState.past => l(K.slotPastHint),
      SlotState.tooSoon => l(K.slotTooSoonHint),
      SlotState.tooFar => l(K.slotTooFarHint),
      SlotState.available => l(K.slotTooShortHint),
      SlotState.unavailable => l(K.slotUnavailableHint),
    });
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _continue(StationDetail detail, SlotGrid grid) async {
    if (_continuing) return;
    final start = _start!;
    final end = start.add(Duration(minutes: _minutes!));
    // The screen may have been open a while: re-check before moving on.
    if (_startedOrTooSoon(start)) {
      setState(() {
        _start = null;
        _lostReason = context.l(K.slotTimePassed);
      });
      ref.invalidate(slotsProvider(_query));
      return;
    }
    final own = _ownAt(_mine, start, _minutes!);
    if (own != null) {
      _explainOwn(own);
      return;
    }
    final s = detail.summary;
    ref.read(bookingFlowProvider.notifier).selectSlot(
          stationId: s.id,
          stationName: s.name,
          stationAddress: s.fullAddress,
          latitude: s.latitude,
          longitude: s.longitude,
          connector: _connector,
          connectorLabel: _connector == null ? '' : ConnectorType.parse(_connector).label,
          start: start,
          end: end,
          feePaise: grid.bookingFee.paise,
        );
    setState(() => _continuing = true);
    await continueBooking(context, ref);
    if (mounted) setState(() => _continuing = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final stationValue = ref.watch(stationProvider(widget.stationId));
    final detail = stationValue.value;
    ref.listen(stationProvider(widget.stationId), (_, next) {
      final d = next.value;
      if (d != null && d.isPublic) ref.read(recentStationsProvider.notifier).add(d.summary);
    });
    if (detail != null && !detail.isPublic) {
      return Scaffold(
        appBar: AppBar(title: Text(detail.summary.name)),
        body: FallbackView(
          icon: Icons.block_rounded,
          title: l(K.stationNotAcceptingTitle),
          message: l(K.stationNotAcceptingBody),
          tone: StatusTone.warning,
          actions: [
            FallbackAction(l(K.seeAlternatives), () => context.push('/alternatives?exclude=${detail.summary.id}'), icon: Icons.alt_route_rounded, primary: true),
            FallbackAction(l(K.backToResults), () => context.pop(), icon: Icons.arrow_back_rounded),
          ],
        ),
      );
    }
    final gridValue = ref.watch(slotsProvider(_query));
    ref.listen(slotsProvider(_query), (_, next) {
      final g = next.value;
      if (g != null) setState(() => _reconcile(g));
    });
    final grid = gridValue.value;
    if (grid != null && _minutes == null) _reconcile(grid);
    ref.watch(myBookingsProvider);

    final today = RFmt.istDate(DateTime.now());
    final days = (detail?.policy.maxAdvanceDays ?? 7).clamp(1, 30);
    final dates = [for (var i = 0; i <= days; i++) today.add(Duration(days: i))];
    final free = (grid != null && _start != null && _minutes != null)
        ? grid.stationCells(_minutes!, connector: _connector).where((c) => c.start == _start).firstOrNull
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.summary.name ?? l(K.stationDetails), maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: l(K.refresh),
            onPressed: () => ref.invalidate(slotsProvider(_query)),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(children: [
        const StepProgress(step: 0),
        _DateStrip(dates: dates, selected: _date, onSelect: _setDate),
        Expanded(
          child: stationValue.hasError && detail == null
              ? FailureView(error: stationValue.error!, onRetry: () => ref.invalidate(stationProvider(widget.stationId)))
              : gridValue.when(
                  skipLoadingOnRefresh: true,
                  skipLoadingOnReload: true,
                  loading: () => const SingleChildScrollView(physics: NeverScrollableScrollPhysics(), padding: EdgeInsets.all(16), child: SkeletonList(count: 5, itemHeight: 56)),
                  error: (e, _) => FailureView(
                    error: e,
                    onRetry: () => ref.invalidate(slotsProvider(_query)),
                    extra: [if (_date != today) FallbackAction(l(K.backToToday), () => _setDate(today), icon: Icons.today_rounded)],
                  ),
                  data: (g) => _body(context, detail, g),
                ),
        ),
      ]),
      bottomNavigationBar: (grid != null && _start != null && _minutes != null && detail != null)
          ? BottomBar(
              child: Row(children: [
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(RFmt(l).slot(_start!, _start!.add(Duration(minutes: _minutes!))),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), maxLines: 2),
                    if (free != null)
                      Text(l(K.pointsFreeCount, {'n': free.free, 'total': free.total}), style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                const SizedBox(width: 12),
                GradientButton(label: l(K.continueLabel), icon: Icons.arrow_forward_rounded, busy: _continuing, onPressed: () => _continue(detail, grid)),
              ]),
            )
          : null,
    );
  }

  /// A shorter length than the chosen one that has a free time this day.
  int? _shortestFree(SlotGrid g) {
    final mins = _minutes;
    if (mins == null) return null;
    for (final m in _durations(g)) {
      if (m >= mins) break;
      if (g.stationCells(m, connector: _connector).any((c) => c.canBook)) return m;
    }
    return null;
  }

  Widget _body(BuildContext context, StationDetail? detail, SlotGrid g) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final bookable = g.points.where((p) => p.point.bookable).toList();
    if (g.unavailableReason != null || bookable.isEmpty) {
      return PageBody(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        FallbackView(
          compact: true,
          icon: Icons.event_busy_rounded,
          title: l(K.noSlotsStationTitle),
          message: l(K.noSlotsStationBody),
          tone: StatusTone.warning,
          actions: [
            FallbackAction(l(K.seeAlternatives), () => context.push('/alternatives?exclude=${g.stationId}'), icon: Icons.alt_route_rounded, primary: true),
          ],
        ),
        if (detail != null) ...[const SizedBox(height: 24), StationInfo(detail: detail)],
      ]);
    }
    final durations = _durations(g);
    final types = g.connectorTypes;
    final cells = _minutes == null ? const <StationCell>[] : g.stationCells(_minutes!, connector: _connector);
    final policy = detail?.policy;
    final children = <Widget>[
      if (_lostReason != null)
        _Notice(icon: Icons.info_outline_rounded, text: _lostReason!, tone: StatusTone.warning),
      _Notice(icon: Icons.ev_station_rounded, text: l(K.anyPointAssigned), tone: StatusTone.info),
      if (types.length > 1) ...[
        Text(l(K.yourConnector), style: t.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(
            label: Text(l(K.connectorAny)),
            selected: _connector == null,
            onSelected: (_) => setState(() {
              _connector = null;
              _reconcile(g);
              _afterChoiceChange(g, l(K.slotNotForConnector));
            }),
          ),
          for (final c in types)
            ChoiceChip(
              label: Text(c.label),
              selected: _connector == c.wire,
              onSelected: (_) => setState(() {
                _connector = c.wire;
                _afterChoiceChange(g, l(K.slotNotForConnector));
                _reconcile(g);
              }),
            ),
        ]),
        const SizedBox(height: 16),
      ],
      Text(l(K.chargingLength), style: t.textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final m in durations)
          ChoiceChip(
            label: Text(f.duration(Duration(minutes: m))),
            selected: _minutes == m,
            onSelected: (_) => setState(() {
              _minutes = m;
              if (_start != null) {
                _afterChoiceChange(g, l(K.slotNotForLength, {'time': f.time(_start!)}));
                if (_start != null && _ownAt(_mine, _start!, m) != null) _start = null;
              }
            }),
          ),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: Text(l(K.startTime), style: t.textTheme.titleSmall)),
        Text(l(K.timesInIst), style: t.textTheme.labelSmall),
      ]),
      const SizedBox(height: 8),
      const _Legend(),
      const SizedBox(height: 10),
      if (cells.isEmpty)
        FallbackView(compact: true, icon: Icons.nightlight_round, title: l(K.closedThisDay), message: l(K.closedThisDayBody))
      else if (!cells.any((c) => c.canBook))
        Column(children: [
          FallbackView(
            compact: true,
            icon: Icons.event_busy_rounded,
            title: l(K.noFreeSlotsDay),
            message: l(K.noFreeSlotsDayBody),
            actions: [
              if (_shortestFree(g) case final m?)
                FallbackAction(l(K.tryLength, {'d': f.duration(Duration(minutes: m))}), () => setState(() => _minutes = m),
                    icon: Icons.timelapse_rounded, primary: true),
              if (detail?.summary.nextAvailable != null)
                FallbackAction(l(K.jumpToNextFree, {'when': f.whenStarts(detail!.summary.nextAvailable!.startAt, DateTime.now())}), () {
                  _setDate(RFmt.istDate(detail.summary.nextAvailable!.startAt));
                }, icon: Icons.fast_forward_rounded, primary: _shortestFree(g) == null),
            ],
          ),
          _SlotGridView(cells: cells, minutes: _minutes, start: _start, isOwn: (t) => _minutes != null && _ownAt(_mine, t, _minutes!) != null, onTap: (c) => _tapCell(g, c)),
        ])
      else
        _SlotGridView(cells: cells, minutes: _minutes, start: _start, isOwn: (t) => _minutes != null && _ownAt(_mine, t, _minutes!) != null, onTap: (c) => _tapCell(g, c)),
      const SizedBox(height: 12),
      if (policy != null)
        _Notice(
          icon: Icons.directions_walk_rounded,
          text: l(K.arrivalRuleNotice, {'before': policy.reportBeforeMinutes, 'grace': policy.arrivalGraceMinutes}),
          tone: StatusTone.warning,
        ),
      Text(l(K.gridUpdated, {'when': f.time(g.generatedAt)}), style: t.textTheme.bodySmall),
      if (g.bufferMinutes > 0) Text(l(K.ruleBufferValue, {'mins': g.bufferMinutes}), style: t.textTheme.bodySmall),
      if (detail != null) ...[const Divider(height: 40), StationInfo(detail: detail)],
    ];
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(slotsProvider(_query)),
      child: PageBody(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: children),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.tone});
  final IconData icon;
  final String text;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = tone.colors(Theme.of(context).colorScheme);
    return Container(
      margin: const EdgeInsets.only(bottom: 12, top: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(icon, color: fg),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: fg))),
      ]),
    );
  }
}

class _DateStrip extends StatelessWidget {
  const _DateStrip({required this.dates, required this.selected, required this.onSelect});
  final List<DateTime> dates;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final now = DateTime.now();
    return SizedBox(
      height: 76,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: dates.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final d = dates[i];
          final sel = d == selected;
          return Semantics(
            selected: sel,
            button: true,
            label: '${f.relativeDay(d, now)}, ${f.monthDay(d)}',
            excludeSemantics: true,
            child: Pressable(
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onSelect(d),
                child: AnimatedContainer(
                  duration: Motion.fast,
                  width: 64,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    gradient: sel ? Brand.gradient : null,
                    color: sel ? null : t.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(f.relativeDay(d, now), maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: t.textTheme.labelSmall?.copyWith(color: sel ? Colors.white : t.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text('${d.day}', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: sel ? Colors.white : null)),
                    Text(f.monthDay(d).replaceAll(RegExp(r'^\d+\s*'), ''),
                        style: t.textTheme.labelSmall?.copyWith(color: sel ? Colors.white70 : t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Visual treatment per state: colour, icon and a word, so nothing relies
/// on colour alone.
(Color bg, Color fg, IconData icon, String label) slotLook(BuildContext context, SlotState s, {bool selected = false}) {
  final l = context.l;
  final c = Theme.of(context).colorScheme;
  if (selected) return (c.primary, c.onPrimary, Icons.check_rounded, l(K.slotSelected));
  final (bg, fg) = switch (s) {
    SlotState.available => StatusTone.success.colors(c),
    SlotState.booked => StatusTone.danger.colors(c),
    SlotState.reserved => StatusTone.warning.colors(c),
    SlotState.blocked => StatusTone.neutral.colors(c),
    _ => (c.surfaceContainerHighest, c.onSurfaceVariant.withValues(alpha: 0.7)),
  };
  return switch (s) {
    SlotState.available => (bg, fg, Icons.bolt_rounded, l(K.slotAvailable)),
    SlotState.booked => (bg, fg, Icons.event_busy_rounded, l(K.slotFull)),
    SlotState.reserved => (bg, fg, Icons.hourglass_top_rounded, l(K.slotReserved)),
    SlotState.blocked => (bg, fg, Icons.construction_rounded, l(K.slotBlocked)),
    SlotState.closed => (bg, fg, Icons.nightlight_round, l(K.slotClosed)),
    SlotState.past => (bg, fg, Icons.history_rounded, l(K.slotPast)),
    SlotState.tooSoon => (bg, fg, Icons.schedule_rounded, l(K.slotTooSoon)),
    SlotState.tooFar => (bg, fg, Icons.event_rounded, l(K.slotTooFar)),
    _ => (bg, fg, Icons.remove_circle_outline_rounded, l(K.slotUnavailable)),
  };
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Wrap(spacing: 12, runSpacing: 6, children: [
      for (final s in [SlotState.available, SlotState.booked, SlotState.blocked, SlotState.unavailable])
        Builder(builder: (context) {
          final (bg, fg, icon, label) = slotLook(context, s);
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
              child: Icon(icon, size: 13, color: fg),
            ),
            const SizedBox(width: 4),
            Text(label, style: t.textTheme.labelSmall),
          ]);
        }),
    ]);
  }
}

class _SlotGridView extends StatelessWidget {
  const _SlotGridView({required this.cells, required this.minutes, required this.start, required this.isOwn, required this.onTap});
  final List<StationCell> cells;
  final int? minutes;
  final DateTime? start;
  final bool Function(DateTime) isOwn;
  final ValueChanged<StationCell> onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    // Hide long runs of past cells so the grid starts near "now".
    final firstUseful = cells.indexWhere((c) => c.state != SlotState.past);
    final shown = firstUseful < 0 ? const <StationCell>[] : cells.sublist(firstUseful);
    return LayoutBuilder(builder: (context, box) {
      final cols = (box.maxWidth / 96).floor().clamp(3, 8);
      final w = (box.maxWidth - (cols - 1) * 8) / cols;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (i, c) in shown.indexed)
          Builder(builder: (context) {
            // Each cell is a start time for the chosen length; only the
            // chosen start is marked, and it says when the booking ends.
            final sel = start != null && c.start == start;
            final own = !sel && isOwn(c.start);
            var (bg, fg, icon, stateLabel) = slotLook(context, c.state, selected: sel);
            if (own) {
              (bg, fg, icon) = (t.colorScheme.secondaryContainer, t.colorScheme.onSecondaryContainer, Icons.person_pin_circle_rounded);
            } else if (c.tooLong && !sel) {
              (bg, fg, icon) = (StatusTone.warning.colors(t.colorScheme).$1, StatusTone.warning.colors(t.colorScheme).$2, Icons.timelapse_rounded);
            }
            // Free cells say how many points are left, so "2 of 3 free"
            // shows the station filling up before it is full.
            final label = sel
                ? l(K.slotUntil, {'time': f.time(c.start.add(Duration(minutes: minutes ?? 0)))})
                : own
                    ? l(K.slotYours)
                    : c.canBook
                        ? l(K.pointsFreeCount, {'n': c.free, 'total': c.total})
                        : c.tooLong
                            ? l(K.slotShorterOnly)
                            : stateLabel;
            return Semantics(
              button: true,
              selected: sel,
              enabled: c.canBook && !own,
              label: '${f.time(c.start)}, $label',
              excludeSemantics: true,
              child: Entrance(
                index: i.clamp(0, 12),
                offset: 8,
                child: Material(
                  color: bg,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onTap(c),
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      width: w,
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: sel ? t.colorScheme.primary : Colors.transparent, width: 2),
                      ),
                      child: Column(children: [
                        Text(f.time(c.start), style: t.textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(icon, size: 12, color: fg),
                          const SizedBox(width: 2),
                          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelSmall?.copyWith(color: fg))),
                        ]),
                      ]),
                    ),
                  ),
                ),
              ),
            );
          }),
      ]);
    });
  }
}
