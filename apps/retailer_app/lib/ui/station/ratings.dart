import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/fallback.dart';
import '../common/format.dart';

/// Five stars, read-only or tappable.
class StarRow extends StatelessWidget {
  const StarRow({super.key, required this.value, this.size = 18, this.onChanged});
  final double value;
  final double size;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    const color = Color(0xFFF5A623);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 1; i <= 5; i++)
        Semantics(
          button: onChanged != null,
          label: l(K.starsLabel, {'n': i}),
          selected: value.round() == i,
          child: InkResponse(
            onTap: onChanged == null ? null : () => onChanged!(i),
            radius: size,
            child: Padding(
              padding: EdgeInsets.all(onChanged == null ? 0 : 4),
              child: Icon(
                value >= i ? Icons.star_rounded : (value >= i - 0.5 ? Icons.star_half_rounded : Icons.star_outline_rounded),
                size: size,
                color: color,
              ),
            ),
          ),
        ),
    ]);
  }
}

/// Average, star breakdown and the latest comments, on the station page.
class StationRatingsSection extends ConsumerWidget {
  const StationRatingsSection({super.key, required this.stationId});
  final String stationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final f = RFmt(l);
    final t = Theme.of(context);
    final value = ref.watch(stationReviewsProvider(stationId));
    final r = value.value;
    if (r == null) return const SizedBox.shrink();
    return SectionCard(
      title: l(K.ratingsTitle),
      child: r.count == 0
          ? Text(l(K.noRatingsYet), style: t.textTheme.bodySmall)
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(r.average!.toStringAsFixed(1), style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  StarRow(value: r.average!),
                  Text(l(K.ratingsCount, {'avg': r.average!.toStringAsFixed(1), 'n': r.count}), style: t.textTheme.bodySmall),
                ]),
              ]),
              const SizedBox(height: 8),
              for (var s = 5; s >= 1; s--)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(children: [
                    SizedBox(width: 14, child: Text('$s', style: t.textTheme.labelSmall)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(value: r.count == 0 ? 0 : (r.stars[s] ?? 0) / r.count, minHeight: 6),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(width: 24, child: Text('${r.stars[s] ?? 0}', textAlign: TextAlign.end, style: t.textTheme.labelSmall)),
                  ]),
                ),
              for (final c in r.recent.where((x) => x.comment != null).take(5)) ...[
                const Divider(height: 20),
                Row(children: [
                  StarRow(value: c.rating.toDouble(), size: 14),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${c.name} · ${f.day(c.createdAt)}', style: t.textTheme.labelSmall, overflow: TextOverflow.ellipsis)),
                ]),
                const SizedBox(height: 4),
                Text(c.comment!, style: t.textTheme.bodyMedium),
              ],
            ]),
    );
  }
}

/// On a finished booking: rate the station (or change the rating).
class RateStationCard extends ConsumerStatefulWidget {
  const RateStationCard({super.key, required this.booking});
  final CustomerBooking booking;

  @override
  ConsumerState<RateStationCard> createState() => _RateStationCardState();
}

class _RateStationCardState extends ConsumerState<RateStationCard> {
  late int _rating = widget.booking.myRating ?? 0;
  late final _comment = TextEditingController(text: widget.booking.myReviewComment ?? '');
  late bool _editing = widget.booking.myRating == null;
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating == 0 || _busy) return;
    setState(() => _busy = true);
    final l = context.l;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(retailRepositoryProvider).submitReview(widget.booking.id, _rating, _comment.text.trim().isEmpty ? null : _comment.text.trim());
      ref.invalidate(bookingProvider(widget.booking.id));
      ref.invalidate(stationReviewsProvider(widget.booking.stationId));
      if (mounted) setState(() => _editing = false);
      messenger.showSnackBar(SnackBar(content: Text(l(K.rateThanks))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(localizedFailureMessage(l, failureOf(e)))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    final b = widget.booking;
    if (!_editing) {
      return SectionCard(
        title: l(K.yourRating),
        trailing: TextButton(onPressed: () => setState(() => _editing = true), child: Text(l(K.change))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          StarRow(value: _rating.toDouble(), size: 24),
          if (_comment.text.trim().isNotEmpty) ...[const SizedBox(height: 6), Text(_comment.text.trim())],
        ]),
      );
    }
    return SectionCard(
      title: l(K.rateStation),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l(K.rateHint, {'station': b.stationName}), style: t.textTheme.bodyMedium),
        const SizedBox(height: 8),
        StarRow(value: _rating.toDouble(), size: 34, onChanged: (v) => setState(() => _rating = v)),
        const SizedBox(height: 8),
        TextField(
          controller: _comment,
          maxLength: 500,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: l(K.rateCommentHint)),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _rating == 0 || _busy ? null : _submit,
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send_rounded),
            label: Text(l(K.rateSubmit)),
          ),
        ),
      ]),
    );
  }
}
