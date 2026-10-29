import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../common/fallback.dart';
import '../common/format.dart';

/// The slot being booked, shown at the top of each booking step.
class DraftSummaryCard extends StatelessWidget {
  const DraftSummaryCard({super.key, required this.draft, this.onChange});
  final BookingDraft draft;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(colors: [t.colorScheme.primaryContainer, t.colorScheme.secondaryContainer.withValues(alpha: 0.7)]),
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(gradient: Brand.gradient, borderRadius: BorderRadius.circular(14)),
          child: const Icon(Icons.ev_station_rounded, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(draft.stationName, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            Text(f.slot(draft.start, draft.end), style: t.textTheme.bodySmall),
            Text([if (draft.connectorLabel.isNotEmpty) draft.connectorLabel, f.duration(draft.duration)].join(' · '), style: t.textTheme.bodySmall),
          ]),
        ),
        if (onChange != null) TextButton(onPressed: onChange, child: Text(l(K.change))),
      ]),
    );
  }
}

/// Shown when a booking step is opened without a booking in progress (for
/// example after the draft expired or from an old link).
class NoDraftView extends StatelessWidget {
  const NoDraftView({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      appBar: AppBar(),
      body: FallbackView(
        icon: Icons.event_note_outlined,
        title: l(K.noDraftTitle),
        message: l(K.noDraftBody),
        actions: [
          FallbackAction(l(K.findStation), () => context.go('/'), icon: Icons.explore_rounded, primary: true),
          FallbackAction(l(K.myBookings), () => context.go('/bookings'), icon: Icons.receipt_long_rounded),
        ],
      ),
    );
  }
}

/// A warning/info strip used inside the booking flow.
class FlowNotice extends StatelessWidget {
  const FlowNotice({super.key, required this.text, this.icon = Icons.info_outline_rounded, this.tone = StatusTone.info, this.action});
  final String text;
  final IconData icon;
  final StatusTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = tone.colors(Theme.of(context).colorScheme);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: fg, height: 1.4))),
        ]),
        if (action != null) Align(alignment: Alignment.centerRight, child: action),
      ]),
    );
  }
}

/// Price lines for the booking: what is paid now, and what is not.
class PriceBreakdown extends StatelessWidget {
  const PriceBreakdown({super.key, required this.fee});
  final Money fee;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    Widget row(String a, String b, {bool bold = false, String? hint}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(a, style: bold ? t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800) : t.textTheme.bodyMedium)),
              Text(b, style: bold ? t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800) : t.textTheme.bodyMedium),
            ]),
            if (hint != null) Text(hint, style: t.textTheme.bodySmall),
          ]),
        );
    return Column(children: [
      row(l(K.bookingFee), fee.isZero ? l(K.free) : fee.format(), hint: fee.isZero ? null : l(K.bookingFeeHint)),
      row(l(K.chargingCost), l(K.payAtStation), hint: l(K.chargingCostBody)),
      row(l(K.convenienceFee), Money.zero().format()),
      const Divider(height: 18),
      row(l(K.payNow), fee.format(), bold: true, hint: l(K.inclTaxes)),
    ]);
  }
}
