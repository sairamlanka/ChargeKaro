import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../checkin/checkin_state.dart';
import '../../state.dart';
import 'checkin_widgets.dart';
import 'confirm_arrival_page.dart';

/// Manual check-in: search this station's bookings by booking ID or the
/// customer's registered mobile number. Results show the reference and slot
/// only; the server rate-limits searches.
class ManualCheckinPage extends ConsumerStatefulWidget {
  const ManualCheckinPage({super.key});

  @override
  ConsumerState<ManualCheckinPage> createState() => _ManualCheckinPageState();
}

class _ManualCheckinPageState extends ConsumerState<ManualCheckinPage> {
  final _query = TextEditingController();
  bool _busy = false;
  CheckinResult? _result;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final station = ref.read(currentStationProvider);
    final q = _query.text.trim();
    if (_busy || station == null) return;
    if (q.isEmpty) return setState(() => _error = 'Enter a booking ID (starts with CK) or a mobile number.');
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final device = await ref.read(deviceIdProvider.future);
      final r = await ref.read(bookingRepositoryProvider).searchForCheckIn(station.id, q, deviceId: device);
      setState(() {
        _result = r;
        _error = r.rejected ? r.displayMessage : null;
      });
    } on AppFailure catch (f) {
      setState(() => _error = f.kind == FailureKind.network ? 'No connection. Use offline check-in instead.' : f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final online = ref.watch(onlineProvider).value ?? true;
    final bookings = _result?.bookings ?? const <Booking>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Manual check-in')),
      body: Column(children: [
        if (!online) const OfflineBanner(),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                inputFormatters: [LengthLimitingTextInputFormatter(20)],
                decoration: const InputDecoration(
                  labelText: 'Booking ID or mobile number',
                  hintText: 'CK… or 98765 43210',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(width: 96, child: GradientButton(label: 'Find', busy: _busy, onPressed: _search)),
          ]),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: RejectionPanel(message: _error!)),
        Expanded(
          child: _result == null || _result!.rejected
              ? const EmptyState(
                  icon: Icons.manage_search_rounded,
                  title: 'Find the booking',
                  message: 'Only bookings at this station from the last 12 hours to the next 24 hours are shown. '
                      'Customer details appear after check-in.',
                )
              : bookings.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No booking found',
                      message: 'Check the booking ID or number. The customer can also open the booking in their app.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: bookings.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final b = bookings[i];
                        return Card(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            title: Text(b.reference, style: t.textTheme.titleMedium?.copyWith(letterSpacing: 1)),
                            subtitle: Text([Fmt.slot(b.startAt, b.endAt), if (b.chargingPointCode != null) 'Point ${b.chargingPointCode}'].join(' · ')),
                            trailing: StatusChip.booking(b.status),
                            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ManualConfirmLoader(bookingId: b.id))),
                          ),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}

/// Re-validates one booking on the server, then shows the confirmation.
/// Also used from booking details.
class ManualConfirmLoader extends ConsumerWidget {
  const ManualConfirmLoader({super.key, required this.bookingId, this.stationId});
  final String bookingId;
  final String? stationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final station = stationId ?? ref.watch(currentStationProvider)?.id;
    if (station == null) return const Scaffold(body: EmptyState(icon: Icons.ev_station_outlined, title: 'No station selected'));
    final data = ref.watch(_previewProvider((station, bookingId)));
    return AsyncView(
      value: data,
      onRetry: () => ref.invalidate(_previewProvider((station, bookingId))),
      loading: const Scaffold(body: Center(child: CircularProgressIndicator())),
      builder: (p) => p.rejected || p.booking == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Manual check-in')),
              body: Padding(padding: const EdgeInsets.all(16), child: RejectionPanel(message: p.displayMessage)),
            )
          : ConfirmArrivalPage(stationId: station, preview: p, method: CheckinMethod.manual),
    );
  }
}

final _previewProvider = FutureProvider.autoDispose.family<CheckinResult, (String, String)>(
    (ref, a) => ref.watch(bookingRepositoryProvider).forCheckIn(a.$1, a.$2));
