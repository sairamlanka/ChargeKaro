import 'package:flutter/material.dart';
import 'package:shared_ui/shared_ui.dart';

import '../providers.dart';

/// Preset ranges plus a custom picker, as one compact control.
class RangePicker extends StatelessWidget {
  const RangePicker({super.key, required this.value, required this.onChanged});

  final DateRange value;
  final ValueChanged<DateRange> onChanged;

  @override
  Widget build(BuildContext context) {
    final days = value.to.difference(value.from).inDays + 1;
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SegmentedButton<int>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: 7, label: Text('7 d')),
          ButtonSegment(value: 30, label: Text('30 d')),
          ButtonSegment(value: 90, label: Text('90 d')),
          ButtonSegment(value: 365, label: Text('1 y')),
        ],
        selected: {if ([7, 30, 90, 365].contains(days)) days},
        emptySelectionAllowed: true,
        onSelectionChanged: (s) {
          if (s.isNotEmpty) onChanged(lastDays(s.first));
        },
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.date_range, size: 18),
        label: Text('${Fmt.dateOnly(value.from)} – ${Fmt.dateOnly(value.to)}'),
        onPressed: () async {
          final picked = await showDateRangePicker(
            context: context,
            firstDate: DateTime(2025),
            lastDate: DateTime.now(),
            initialDateRange: DateTimeRange(start: value.from, end: value.to),
          );
          if (picked != null) onChanged((from: picked.start, to: picked.end));
        },
      ),
    ]);
  }
}
