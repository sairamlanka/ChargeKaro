import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/fallback.dart';
import '../common/format.dart';
import '../station/slots_screen.dart';

/// Loads the booking, then shows the slot picker in "move this booking" mode.
class RescheduleScreen extends ConsumerWidget {
  const RescheduleScreen({super.key, required this.bookingId});
  final String bookingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final value = ref.watch(bookingProvider(bookingId));
    return value.when(
      loading: () => Scaffold(appBar: AppBar(title: Text(l(K.rescheduleTitle))), body: const SlowLoading()),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: Text(l(K.rescheduleTitle))),
        body: FailureView(error: e, onRetry: () => ref.invalidate(bookingProvider(bookingId))),
      ),
      data: (b) => b.canReschedule
          ? SlotsScreen(stationId: b.stationId, initialDate: RFmt.istDate(b.startAt), rescheduleOf: b)
          : Scaffold(
              appBar: AppBar(title: Text(l(K.rescheduleTitle))),
              body: FallbackView(icon: Icons.event_busy_rounded, title: l(K.reschedule), message: l(K.errRescheduleLimit)),
            ),
    );
  }
}
