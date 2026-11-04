import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../checkin/checkin_state.dart';
import '../../state.dart';
import '../../widgets/station_switcher.dart';
import 'checkin_history_page.dart';
import 'checkin_widgets.dart';
import 'manual_checkin_page.dart';
import 'offline_checkin_page.dart';
import 'qr_scan_page.dart';
import 'sync_queue_page.dart';

/// Check-in hub: QR (primary), manual (fallback), offline (emergency),
/// plus the sync queue and history. While online it keeps the offline
/// booking list for the current station fresh.
class CheckinHomePage extends ConsumerStatefulWidget {
  const CheckinHomePage({super.key});

  @override
  ConsumerState<CheckinHomePage> createState() => _CheckinHomePageState();
}

class _CheckinHomePageState extends ConsumerState<CheckinHomePage> {
  String? _cachedFor;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCache());
  }

  Future<void> _refreshCache({bool force = false}) async {
    final station = ref.read(currentStationProvider);
    final online = ref.read(onlineProvider).value ?? true;
    if (station == null || !online || _refreshing || (!force && _cachedFor == station.id)) return;
    _refreshing = true;
    try {
      await ref.read(offlineQueueProvider.future);
      final store = ref.read(offlineQueueProvider.notifier).store;
      if (store == null) return;
      unawaited(ref.read(offlineQueueProvider.notifier).sync());
      final device = await ref.read(deviceIdProvider.future);
      final cache = await ref.read(bookingRepositoryProvider).offlineCache(station.id, deviceId: device);
      await store.saveCache(cache);
      _cachedFor = station.id;
      if (mounted) setState(() {});
    } on AppFailure {
      // Keep the previous list; the offline screen shows its age.
    } finally {
      _refreshing = false;
    }
  }

  void _open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final station = ref.watch(currentStationProvider);
    final online = ref.watch(onlineProvider).value ?? true;
    final pending = ref.watch(pendingSyncCountProvider);
    ref.listen(currentStationProvider, (_, _) => unawaited(_refreshCache()));
    ref.listen(onlineProvider, (_, next) {
      if (next.value == true) unawaited(_refreshCache(force: true));
    });
    final cache = station == null ? null : ref.watch(offlineQueueProvider.notifier).store?.cacheFor(station.id);

    return Scaffold(
      appBar: AppBar(title: const StationSwitcher()),
      body: station == null
          ? const EmptyState(icon: Icons.ev_station_outlined, title: 'No station selected')
          : ListView(padding: EdgeInsets.zero, children: [
              if (!online) const OfflineBanner(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _ActionCard(
                    primary: true,
                    icon: Icons.qr_code_scanner_rounded,
                    title: 'Scan QR',
                    subtitle: 'Fastest. Scan the code in the driver\'s ChargeKaro app.',
                    enabled: online,
                    onTap: () => _open(const QrScanPage()),
                  ),
                  const SizedBox(height: 12),
                  _ActionCard(
                    icon: Icons.keyboard_rounded,
                    title: 'Manual check-in',
                    subtitle: 'Search by booking ID or the driver\'s mobile number.',
                    enabled: online,
                    onTap: () => _open(const ManualCheckinPage()),
                  ),
                  const SizedBox(height: 12),
                  _ActionCard(
                    icon: Icons.cloud_off_rounded,
                    title: 'Offline check-in',
                    subtitle: 'No internet? Record a provisional check-in that syncs later.',
                    onTap: () => _open(const OfflineCheckinPage()),
                  ),
                  const SizedBox(height: 20),
                  Card(
                    child: Column(children: [
                      ListTile(
                        leading: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.sync_rounded)),
                        title: const Text('Sync queue'),
                        subtitle: Text(pending == 0 ? 'Nothing waiting' : '$pending offline check-in${pending == 1 ? '' : 's'} pending sync'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _open(const SyncQueuePage()),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.history_rounded),
                        title: const Text('Check-in history'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _open(const CheckinHistoryPage()),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.offline_pin_outlined),
                        title: const Text('Offline booking list'),
                        subtitle: Text(cache == null
                            ? 'Not downloaded yet'
                            : '${cache.bookings.length} bookings · updated ${Fmt.time(cache.generatedAt)}'),
                        trailing: IconButton(
                          tooltip: 'Refresh offline list',
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: online ? () => _refreshCache(force: true) : null,
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Customer details are shown only after a booking is checked in.',
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ]),
              ),
            ]),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.title, required this.subtitle, required this.onTap, this.primary = false, this.enabled = true});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fg = primary ? Colors.white : t.colorScheme.onSurface;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        color: primary ? null : t.colorScheme.surfaceContainerLow,
        child: Ink(
          decoration: primary ? const BoxDecoration(gradient: Brand.gradient) : null,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(children: [
                Icon(icon, size: 34, color: primary ? Colors.white : t.colorScheme.primary),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: t.textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(enabled ? subtitle : 'Needs internet', style: t.textTheme.bodySmall?.copyWith(color: fg.withValues(alpha: 0.85))),
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, color: fg),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
