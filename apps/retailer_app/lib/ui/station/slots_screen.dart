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
import '../common/fallback.dart';
import '../common/format.dart';
import '../common/widgets.dart';
import 'station_screen.dart' show pointReason;

/// Step 1: pick a date, a charging point, a length and a start time. The
/// grid is a snapshot; it refreshes every minute and the server re-checks
/// the slot before anything is reserved.
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
  String? _pointId;
  int? _minutes;
  DateTime? _start;
  Timer? _refresh;

  /// Shown once when a refresh shows the chosen time is no longer free.
  bool _lostSelection = false;

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
      if (mounted) ref.invalidate(slotsProvider(_query));
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
        _lostSelection = false;
      });

  /// Keeps the selection consistent with a freshly loaded grid.
  void _reconcile(SlotGrid grid) {
    if (grid.points.isEmpty) return;
    final current = grid.points.where((p) => p.point.id == _pointId).firstOrNull;
    if (current == null || !current.point.bookable) {
      final preferred = grid.points.where((p) => p.point.bookable && p.cells.any((c) => c.canStart)).firstOrNull ??
          grid.points.where((p) => p.point.bookable).firstOrNull ??
          grid.points.first;
      _pointId = preferred.point.id;
      _start = null;
    }
    final ps = grid.points.firstWhere((p) => p.point.id == _pointId);
    final options = _durations(grid, ps.point);
    if (_minutes == null || !options.contains(_minutes)) _minutes = options.isEmpty ? null : options.first;
    if (_start != null && (_minutes == null || !ps.fits(_start!, _minutes!, grid.slotMinutes))) {
      _start = null;
      _lostSelection = true;
    }
  }

  List<int> _durations(SlotGrid grid, PointInfo point) {
    final policyMax = ref.read(stationProvider(widget.stationId)).value?.policy.maxBookingMinutes ?? point.maxBookingMinutes;
    final max = policyMax < point.maxBookingMinutes ? policyMax : point.maxBookingMinutes;
    return [for (var m = grid.minBookingMinutes; m <= max; m += grid.slotMinutes) m];
  }

  void _tapCell(SlotGrid grid, PointSlots ps, SlotCell c) {
    final l = context.l;
    final mins = _minutes;
    if (mins == null) return;
    if (!c.canStart || c.state != SlotState.available) {
      _explain(c);
      return;
    }
    if (!ps.fits(c.start, mins, grid.slotMinutes)) {
      // Pick the longest length that fits rather than refusing outright.
      final fitting = _durations(grid, ps.point).reversed.where((m) => ps.fits(c.start, m, grid.slotMinutes)).firstOrNull;
      if (fitting == null) {
        _snack(l(K.slotNoLengthFits));
        return;
      }
      setState(() {
        _minutes = fitting;
        _start = c.start;
        _lostSelection = false;
      });
      _snack(l(K.slotLengthAdjusted, {'d': RFmt(l).duration(Duration(minutes: fitting))}));
      return;
    }
    setState(() {
      _start = c.start;
      _lostSelection = false;
    });
  }

  void _explain(SlotCell c) {
    final l = context.l;
    _snack(switch (c.state) {
      SlotState.booked => l(K.slotBookedHint),
      SlotState.reserved => l(K.slotReservedHint),
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

  void _continue(StationDetail detail, SlotGrid grid, PointSlots ps) {
    final start = _start!;
    final end = start.add(Duration(minutes: _minutes!));
    final s = detail.summary;
    ref.read(bookingFlowProvider.notifier).selectSlot(
          stationId: s.id,
          stationName: s.name,
          stationAddress: s.fullAddress,
          latitude: s.latitude,
          longitude: s.longitude,
          pointId: ps.point.id,
          pointLabel: ps.point.label,
          connectorLabel: ps.point.connectors.map((c) => c.type.label).join(', '),
          start: start,
          end: end,
          feePaise: grid.bookingFee.paise,
        );
    context.push('/book/details');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final stationValue = ref.watch(stationProvider(widget.stationId));
    final detail = stationValue.value;
    final gridValue = ref.watch(slotsProvider(_query));
    ref.listen(slotsProvider(_query), (_, next) {
      final g = next.value;
      if (g != null) setState(() => _reconcile(g));
    });
    final grid = gridValue.value;
    if (grid != null && _pointId == null) _reconcile(grid);

    final today = RFmt.istDate(DateTime.now());
    final days = (detail?.policy.maxAdvanceDays ?? 7).clamp(1, 30);
    final dates = [for (var i = 0; i <= days; i++) today.add(Duration(days: i))];

    final ps = grid?.points.where((p) => p.point.id == _pointId).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.summary.name ?? l(K.chooseSlot), maxLines: 1, overflow: TextOverflow.ellipsis),
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
                  data: (g) => _body(context, detail, g, ps),
                ),
        ),
      ]),
      bottomNavigationBar: (grid != null && ps != null && _start != null && _minutes != null && detail != null)
          ? BottomBar(
              child: Row(children: [
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(RFmt(l).slot(_start!, _start!.add(Duration(minutes: _minutes!))),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), maxLines: 2),
                    Text('${ps.point.label} · ${grid.bookingFee.isZero ? l(K.free) : l(K.feeInclTaxes, {'fee': grid.bookingFee.format()})}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                const SizedBox(width: 12),
                GradientButton(label: l(K.continueLabel), icon: Icons.arrow_forward_rounded, onPressed: () => _continue(detail, grid, ps)),
              ]),
            )
          : null,
    );
  }

  Widget _body(BuildContext context, StationDetail? detail, SlotGrid g, PointSlots? ps) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    if (g.unavailableReason != null || g.points.isEmpty) {
      return FallbackView(
        icon: Icons.event_busy_rounded,
        title: l(K.noSlotsStationTitle),
        message: l(K.noSlotsStationBody),
        tone: StatusTone.warning,
        actions: [
          FallbackAction(l(K.seeAlternatives), () => context.push('/alternatives?exclude=${g.stationId}'), icon: Icons.alt_route_rounded, primary: true),
        ],
      );
    }
    final durations = ps == null ? const <int>[] : _durations(g, ps.point);
    final children = <Widget>[
      if (_lostSelection)
        _Notice(icon: Icons.info_outline_rounded, text: l(K.slotJustTaken), tone: StatusTone.warning),
      Text(l(K.choosePoint), style: t.textTheme.titleSmall),
      const SizedBox(height: 8),
      SizedBox(
        height: 116,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: g.points.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final p = g.points[i];
            return _PointChoice(
              point: p,
              selected: p.point.id == _pointId,
              freeCount: p.cells.where((c) => c.canStart).length,
              onTap: () => setState(() {
                _pointId = p.point.id;
                _start = null;
                _lostSelection = false;
                final opts = _durations(g, p.point);
                if (!opts.contains(_minutes)) _minutes = opts.isEmpty ? null : opts.first;
              }),
            );
          },
        ),
      ),
      if (ps != null && !ps.point.bookable)
        _Notice(icon: Icons.build_circle_outlined, text: pointReason(l, ps.point.unavailableReason), tone: StatusTone.danger),
      const SizedBox(height: 16),
      Text(l(K.chargingLength), style: t.textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final m in durations)
          ChoiceChip(
            label: Text(f.duration(Duration(minutes: m))),
            selected: _minutes == m,
            onSelected: (_) => setState(() {
              _minutes = m;
              if (_start != null && !ps!.fits(_start!, m, g.slotMinutes)) _start = null;
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
      if (ps == null || ps.cells.isEmpty)
        FallbackView(compact: true, icon: Icons.nightlight_round, title: l(K.closedThisDay), message: l(K.closedThisDayBody))
      else if (!ps.cells.any((c) => c.canStart))
        Column(children: [
          FallbackView(
            compact: true,
            icon: Icons.event_busy_rounded,
            title: l(K.noFreeSlotsDay),
            message: l(K.noFreeSlotsDayBody),
            actions: [
              if (detail?.summary.nextAvailable != null)
                FallbackAction(l(K.jumpToNextFree, {'when': f.whenStarts(detail!.summary.nextAvailable!.startAt, DateTime.now())}), () {
                  _setDate(RFmt.istDate(detail.summary.nextAvailable!.startAt));
                }, icon: Icons.fast_forward_rounded, primary: true),
            ],
          ),
          _SlotGridView(grid: g, slots: ps, minutes: _minutes, start: _start, onTap: (c) => _tapCell(g, ps, c)),
        ])
      else
        _SlotGridView(grid: g, slots: ps, minutes: _minutes, start: _start, onTap: (c) => _tapCell(g, ps, c)),
      const SizedBox(height: 12),
      Text(l(K.gridUpdated, {'when': f.time(g.generatedAt)}), style: t.textTheme.bodySmall),
      if (g.bufferMinutes > 0) Text(l(K.ruleBufferValue, {'mins': g.bufferMinutes}), style: t.textTheme.bodySmall),
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

class _PointChoice extends StatelessWidget {
  const _PointChoice({required this.point, required this.selected, required this.freeCount, required this.onTap});
  final PointSlots point;
  final bool selected;
  final int freeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final p = point.point;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.fast,
          width: 172,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: selected ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerLow,
            border: Border.all(color: selected ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: selected ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(p.currentType == CurrentType.dc ? Icons.flash_on_rounded : Icons.power_rounded, size: 18, color: t.colorScheme.primary),
              const SizedBox(width: 4),
              Expanded(child: Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall)),
              if (selected) Icon(Icons.check_circle_rounded, size: 18, color: t.colorScheme.primary),
            ]),
            const SizedBox(height: 2),
            Text('${p.currentType.label} · ${f.power(p.maxPowerKw)}', style: t.textTheme.bodySmall),
            Text(p.connectors.map((c) => c.type.label).join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
            const Spacer(),
            Text(
              !p.bookable ? pointReason(l, p.unavailableReason) : (freeCount == 0 ? l(K.noFreeTimes) : l(K.freeTimesCount, {'n': freeCount})),
              style: t.textTheme.labelSmall?.copyWith(color: !p.bookable || freeCount == 0 ? t.colorScheme.error : t.colorScheme.primary, fontWeight: FontWeight.w700),
            ),
          ]),
        ),
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
    SlotState.booked => (bg, fg, Icons.event_busy_rounded, l(K.slotOccupied)),
    SlotState.reserved => (bg, fg, Icons.hourglass_top_rounded, l(K.slotReserved)),
    SlotState.blocked => (bg, fg, Icons.construction_rounded, l(K.slotBlocked)),
    SlotState.closed => (bg, fg, Icons.nightlight_round, l(K.slotClosed)),
    _ => (bg, fg, Icons.remove_circle_outline_rounded, l(K.slotUnavailable)),
  };
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Wrap(spacing: 12, runSpacing: 6, children: [
      for (final s in [SlotState.available, SlotState.booked, SlotState.reserved, SlotState.blocked, SlotState.unavailable])
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
  const _SlotGridView({required this.grid, required this.slots, required this.minutes, required this.start, required this.onTap});
  final SlotGrid grid;
  final PointSlots slots;
  final int? minutes;
  final DateTime? start;
  final ValueChanged<SlotCell> onTap;

  bool _inSelection(SlotCell c) {
    if (start == null || minutes == null) return false;
    final end = start!.add(Duration(minutes: minutes!));
    return !c.start.isBefore(start!) && c.start.isBefore(end);
  }

  @override
  Widget build(BuildContext context) {
    final f = RFmt(context.l);
    final t = Theme.of(context);
    // Hide long runs of past cells so the grid starts near "now".
    final firstUseful = slots.cells.indexWhere((c) => c.state != SlotState.past);
    final cells = firstUseful < 0 ? const <SlotCell>[] : slots.cells.sublist(firstUseful);
    return LayoutBuilder(builder: (context, box) {
      final cols = (box.maxWidth / 96).floor().clamp(3, 8);
      final w = (box.maxWidth - (cols - 1) * 8) / cols;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (i, c) in cells.indexed)
          Builder(builder: (context) {
            final sel = _inSelection(c);
            final (bg, fg, icon, label) = slotLook(context, c.state, selected: sel);
            final tappable = c.canStart && c.state == SlotState.available;
            return Semantics(
              button: true,
              selected: sel,
              enabled: tappable,
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
