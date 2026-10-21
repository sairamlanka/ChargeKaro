import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../state.dart';

final _blockedProvider = FutureProvider.autoDispose.family<List<BlockedPeriod>, String>(
    (ref, id) => ref.watch(stationRepositoryProvider).blockedPeriods(id));

/// Operating hours, booking rules and blocked periods (maintenance or
/// closures). Times are Indian Standard Time.
class AvailabilityTab extends ConsumerWidget {
  const AvailabilityTab({super.key, required this.station});
  final Station station;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(currentAccessProvider)?.can(BusinessPermission.availabilityEdit, stationId: station.id) ?? false;
    return ListView(padding: const EdgeInsets.all(16), children: [
      AsyncView(
        value: ref.watch(hoursProvider(station.id)),
        onRetry: () => ref.invalidate(hoursProvider(station.id)),
        builder: (hours) => _HoursCard(station: station, hours: hours.where((h) => h.chargingPointId == null).toList(), canEdit: canEdit),
      ),
      const SizedBox(height: 16),
      AsyncView(
        value: ref.watch(policyProvider(station.id)),
        onRetry: () => ref.invalidate(policyProvider(station.id)),
        builder: (p) => _PolicyCard(policy: p, canEdit: canEdit),
      ),
      const SizedBox(height: 16),
      _BlockedCard(station: station, canEdit: canEdit),
    ]);
  }
}

class _HoursCard extends ConsumerWidget {
  const _HoursCard({required this.station, required this.hours, required this.canEdit});
  final Station station;
  final List<OperatingHours> hours;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionCard(
      title: 'Operating hours',
      trailing: canEdit
          ? TextButton(
              onPressed: () async {
                final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => HoursEditor(stationId: station.id, initial: hours)));
                if (saved == true) ref.invalidate(hoursProvider(station.id));
              },
              child: const Text('Edit'),
            )
          : null,
      child: hours.isEmpty
          ? const Text('Not set. Customers cannot book until hours are added.')
          : Column(children: [
              for (var d = 1; d <= 7; d++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    SizedBox(width: 48, child: Text(OperatingHours.dayNames[d - 1])),
                    Expanded(
                      child: Text(() {
                        final day = hours.where((h) => h.dayOfWeek == d).toList()..sort((a, b) => a.opensMinute.compareTo(b.opensMinute));
                        if (day.isEmpty) return 'Closed';
                        if (day.length == 1 && day.first.opensMinute == 0 && day.first.closesMinute == 1440) return 'Open 24 hours';
                        return day.map((h) => h.label).join(', ');
                      }()),
                    ),
                  ]),
                ),
            ]),
    );
  }
}

/// Weekly schedule editor. Saved atomically: the old schedule stays if the
/// new one is rejected (for example, overlapping ranges).
class HoursEditor extends ConsumerStatefulWidget {
  const HoursEditor({super.key, required this.stationId, required this.initial});
  final String stationId;
  final List<OperatingHours> initial;

  @override
  ConsumerState<HoursEditor> createState() => _HoursEditorState();
}

class _HoursEditorState extends ConsumerState<HoursEditor> {
  late final Map<int, List<(int, int)>> _days = {
    for (var d = 1; d <= 7; d++)
      d: [for (final h in widget.initial.where((h) => h.dayOfWeek == d)) (h.opensMinute, h.closesMinute)]..sort((a, b) => a.$1.compareTo(b.$1)),
  };
  bool _busy = false;

  String? get _problem {
    for (final e in _days.entries) {
      final r = e.value;
      for (var i = 0; i < r.length; i++) {
        if (r[i].$2 <= r[i].$1) return '${OperatingHours.dayNames[e.key - 1]}: closing must be after opening.';
        if (i > 0 && r[i].$1 < r[i - 1].$2) return '${OperatingHours.dayNames[e.key - 1]}: time ranges overlap.';
      }
    }
    return null;
  }

  Future<TimeOfDay?> _pick(int minute) => showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: (minute ~/ 60) % 24, minute: minute % 60),
        initialEntryMode: TimePickerEntryMode.input,
      );

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(title: const Text('Operating hours')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 8, children: [
          ActionChip(label: const Text('24 hours, every day'), onPressed: () => setState(() => _days.updateAll((_, _) => [(0, 1440)]))),
          ActionChip(label: const Text('6 am – 10 pm, every day'), onPressed: () => setState(() => _days.updateAll((_, _) => [(360, 1320)]))),
          ActionChip(label: const Text('Copy Monday to all'), onPressed: () => setState(() => _days.updateAll((_, _) => [..._days[1]!]))),
        ]),
        const SizedBox(height: 8),
        for (var d = 1; d <= 7; d++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(OperatingHours.dayNames[d - 1], style: Theme.of(context).textTheme.titleSmall)),
                  if (_days[d]!.isEmpty) const Text('Closed'),
                  IconButton(
                    tooltip: 'Add time range',
                    icon: const Icon(Icons.add),
                    onPressed: () => setState(() {
                      final last = _days[d]!.isEmpty ? 0 : _days[d]!.last.$2;
                      _days[d]!.add(last >= 1380 ? (0, 1440) : (last == 0 ? 360 : last + 60, 1440));
                    }),
                  ),
                ]),
                for (var i = 0; i < _days[d]!.length; i++)
                  Row(children: [
                    TextButton(
                      onPressed: () async {
                        final t = await _pick(_days[d]![i].$1);
                        if (t != null) setState(() => _days[d]![i] = (t.hour * 60 + t.minute, _days[d]![i].$2));
                      },
                      child: Text(OperatingHours.formatMinute(_days[d]![i].$1)),
                    ),
                    const Text('to'),
                    TextButton(
                      onPressed: () async {
                        final t = await _pick(_days[d]![i].$2);
                        if (t == null) return;
                        final m = t.hour * 60 + t.minute;
                        setState(() => _days[d]![i] = (_days[d]![i].$1, m == 0 ? 1440 : m));
                      },
                      child: Text(_days[d]![i].$2 == 1440 ? '24:00' : OperatingHours.formatMinute(_days[d]![i].$2)),
                    ),
                    const Spacer(),
                    IconButton(tooltip: 'Remove', icon: const Icon(Icons.close), onPressed: () => setState(() => _days[d]!.removeAt(i))),
                  ]),
              ]),
            ),
          ),
        if (problem != null) Padding(padding: const EdgeInsets.all(8), child: Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy || problem != null
              ? null
              : () async {
                  setState(() => _busy = true);
                  final hours = [
                    for (final e in _days.entries)
                      for (final r in e.value) OperatingHours(dayOfWeek: e.key, opensMinute: r.$1, closesMinute: r.$2),
                  ];
                  final ok = await runAction(context, () => ref.read(stationRepositoryProvider).replaceHours(widget.stationId, hours),
                      success: 'Hours saved.');
                  if (!mounted) return;
                  setState(() => _busy = false);
                  if (ok && context.mounted) Navigator.pop(context, true);
                },
          child: const Text('Save hours'),
        ),
        const SizedBox(height: 8),
        const Text('Existing bookings are not changed. Times are IST. To close for specific dates, use a blocked period instead.'),
      ]),
    );
  }
}

class _PolicyCard extends ConsumerWidget {
  const _PolicyCard({required this.policy, required this.canEdit});
  final BookingPolicy policy;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = policy;
    return SectionCard(
      title: 'Booking rules',
      trailing: canEdit
          ? TextButton(
              onPressed: () async {
                final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PolicyEditor(policy: p)));
                if (saved == true) ref.invalidate(policyProvider(p.stationId));
              },
              child: const Text('Edit'),
            )
          : null,
      child: Column(children: [
        KeyValue('Slot length', '${p.slotDurationMinutes} min'),
        KeyValue('Booking length', '${p.minBookingMinutes}–${p.maxBookingMinutes} min'),
        KeyValue('Book ahead', '${p.minAdvanceMinutes} min to ${p.maxAdvanceDays} days'),
        KeyValue('Buffer between bookings', '${p.bufferMinutes} min'),
        KeyValue('Arrival grace', '${p.arrivalGraceMinutes} min'),
        KeyValue('Early check-in', '${p.earlyCheckinMinutes} min before'),
        KeyValue('Customer cancellation', 'until ${p.customerCancelUntilMinutes} min before'),
        KeyValue('Automatic no-show', p.autoNoShowEnabled ? 'After grace period' : 'Off (staff mark no-shows)'),
      ]),
    );
  }
}

class PolicyEditor extends ConsumerStatefulWidget {
  const PolicyEditor({super.key, required this.policy});
  final BookingPolicy policy;

  @override
  ConsumerState<PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends ConsumerState<PolicyEditor> {
  late BookingPolicy _p = widget.policy;

  Widget _num(String label, int value, int min, int max, int step, BookingPolicy Function(int) update, {String unit = 'min'}) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text('$value $unit'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Decrease', icon: const Icon(Icons.remove), onPressed: value - step < min ? null : () => setState(() => _p = update(value - step))),
          IconButton(tooltip: 'Increase', icon: const Icon(Icons.add), onPressed: value + step > max ? null : () => setState(() => _p = update(value + step))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final problems = _p.validate();
    final slot = _p.slotDurationMinutes;
    return Scaffold(
      appBar: AppBar(title: const Text('Booking rules')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<int>(
          initialValue: slot,
          decoration: const InputDecoration(labelText: 'Slot length'),
          items: [for (final m in const [15, 30, 45, 60, 90, 120]) DropdownMenuItem(value: m, child: Text('$m minutes'))],
          onChanged: (m) => setState(() {
            if (m == null) return;
            int round(int v) => ((v / m).ceil() * m).clamp(m, 1440);
            _p = _p.copyWith(slotDurationMinutes: m, minBookingMinutes: round(_p.minBookingMinutes), maxBookingMinutes: round(_p.maxBookingMinutes));
          }),
        ),
        _num('Shortest booking', _p.minBookingMinutes, slot, _p.maxBookingMinutes, slot, (v) => _p.copyWith(minBookingMinutes: v)),
        _num('Longest booking', _p.maxBookingMinutes, _p.minBookingMinutes, 720, slot, (v) => _p.copyWith(maxBookingMinutes: v)),
        _num('Minimum notice', _p.minAdvanceMinutes, 0, 1440, 15, (v) => _p.copyWith(minAdvanceMinutes: v)),
        _num('Book up to', _p.maxAdvanceDays, 1, 90, 1, (v) => _p.copyWith(maxAdvanceDays: v), unit: 'days ahead'),
        _num('Buffer between bookings', _p.bufferMinutes, 0, 120, 5, (v) => _p.copyWith(bufferMinutes: v)),
        _num('Arrival grace period', _p.arrivalGraceMinutes, 0, 120, 5, (v) => _p.copyWith(arrivalGraceMinutes: v)),
        _num('Early check-in allowed', _p.earlyCheckinMinutes, 0, 120, 5, (v) => _p.copyWith(earlyCheckinMinutes: v)),
        _num('Customer can cancel until', _p.customerCancelUntilMinutes, 0, 1440, 15, (v) => _p.copyWith(customerCancelUntilMinutes: v), unit: 'min before start'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _p.autoNoShowEnabled,
          onChanged: (v) => setState(() => _p = _p.copyWith(autoNoShowEnabled: v)),
          title: const Text('Mark no-show automatically after the grace period'),
        ),
        for (final m in problems) Text(m, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: problems.isNotEmpty
              ? null
              : () async {
                  final ok = await runAction(context, () => ref.read(stationRepositoryProvider).updatePolicy(_p), success: 'Booking rules saved.');
                  if (ok && context.mounted) Navigator.pop(context, true);
                },
          child: const Text('Save'),
        ),
        const SizedBox(height: 8),
        const Text('New rules apply to new bookings. Confirmed bookings keep their times.'),
      ]),
    );
  }
}

class _BlockedCard extends ConsumerWidget {
  const _BlockedCard({required this.station, required this.canEdit});
  final Station station;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void refresh() => ref.invalidate(_blockedProvider(station.id));
    return SectionCard(
      title: 'Blocked periods',
      trailing: canEdit ? TextButton(onPressed: () => _add(context, ref, refresh), child: const Text('Block time')) : null,
      child: AsyncView(
        value: ref.watch(_blockedProvider(station.id)),
        onRetry: refresh,
        builder: (list) => list.isEmpty
            ? const Text('None. Block time for maintenance, events or closures; customers cannot book it.')
            : Column(children: [
                for (final b in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${b.kind.label}${b.chargingPointId == null ? ' · whole station' : ''}'),
                    subtitle: Text('${Fmt.dateTime(b.startsAt)} – ${Fmt.dateTime(b.endsAt)}${b.reason == null ? '' : '\n${b.reason}'}'),
                    trailing: canEdit
                        ? IconButton(
                            tooltip: 'Remove block',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (await runAction(context, () => ref.read(stationRepositoryProvider).cancelBlockedPeriod(b.id))) refresh();
                            },
                          )
                        : null,
                  ),
              ]),
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref, VoidCallback refresh) async {
    final points = ref.read(pointsProvider(station.id)).value ?? const [];
    final result = await showModalBottomSheet<(DateTime, DateTime, String?, BlockedPeriodKind, String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BlockSheet(points: points),
    );
    if (result == null || !context.mounted) return;
    final (start, end, pointId, kind, reason) = result;
    final repo = ref.read(stationRepositoryProvider);
    Future<void> create(bool cancel) => repo.createBlockedPeriod(
        stationId: station.id, chargingPointId: pointId, startsAt: start, endsAt: end, kind: kind, reason: reason, cancelConflicting: cancel);
    try {
      await create(false);
      refresh();
    } on AppFailure catch (f) {
      if (!context.mounted) return;
      if (f.code != 'bookings_conflict') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(f.message)));
        return;
      }
      final go = await confirm(context,
          title: 'Bookings in this period',
          message: '${f.detail} Cancelling notifies the customers; their booking fee is refunded under the platform policy.',
          confirmLabel: 'Cancel them and block',
          destructive: true);
      if (go && context.mounted && await runAction(context, () => create(true), success: 'Time blocked.')) refresh();
    }
  }
}

class _BlockSheet extends StatefulWidget {
  const _BlockSheet({required this.points});
  final List<ChargingPoint> points;

  @override
  State<_BlockSheet> createState() => _BlockSheetState();
}

class _BlockSheetState extends State<_BlockSheet> {
  DateTime? _start;
  DateTime? _end;
  String? _point;
  BlockedPeriodKind _kind = BlockedPeriodKind.maintenance;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime? initial) async {
    final now = Fmt.toIst(DateTime.now());
    final d = await showDatePicker(context: context, firstDate: DateTime(now.year, now.month, now.day), lastDate: now.add(const Duration(days: 365)));
    if (d == null || !mounted) return null;
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 9, minute: 0), initialEntryMode: TimePickerEntryMode.input);
    if (t == null) return null;
    return Fmt.fromIst(d.year, d.month, d.day, t.hour, t.minute);
  }

  @override
  Widget build(BuildContext context) {
    final valid = _start != null && _end != null && _end!.isAfter(_start!) && _reason.text.trim().length >= 3;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Block time', style: Theme.of(context).textTheme.titleLarge),
        DropdownButtonFormField<BlockedPeriodKind>(
          initialValue: _kind,
          decoration: const InputDecoration(labelText: 'Why'),
          items: [for (final k in BlockedPeriodKind.values) DropdownMenuItem(value: k, child: Text(k.label))],
          onChanged: (v) => setState(() => _kind = v ?? _kind),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          initialValue: _point,
          decoration: const InputDecoration(labelText: 'Applies to'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Whole station')),
            for (final p in widget.points) DropdownMenuItem(value: p.id, child: Text(p.code)),
          ],
          onChanged: (v) => setState(() => _point = v),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('From'),
          subtitle: Text(_start == null ? 'Choose' : Fmt.dateTime(_start!)),
          onTap: () async {
            final v = await _pick(_start);
            if (v != null) setState(() => _start = v);
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Until'),
          subtitle: Text(_end == null ? 'Choose' : Fmt.dateTime(_end!)),
          onTap: () async {
            final v = await _pick(_end);
            if (v != null) setState(() => _end = v);
          },
        ),
        TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason'), onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, (_start!, _end!, _point, _kind, _reason.text.trim())) : null,
          child: const Text('Block'),
        ),
      ]),
    );
  }
}
