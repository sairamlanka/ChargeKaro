import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Random id with 128 bits of entropy, as a UUID v4 string. Used for device
/// ids, offline event ids and idempotency keys.
String randomId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

final prefsProvider = FutureProvider<SharedPreferences>((ref) => SharedPreferences.getInstance());

/// Per-install id recorded with check-ins (not a hardware identifier).
/// Reinstalling or clearing app data gives a new one.
final deviceIdProvider = FutureProvider<String>((ref) async {
  final prefs = await ref.watch(prefsProvider.future);
  var id = prefs.getString('checkin.device_id');
  if (id == null) {
    id = randomId();
    await prefs.setString('checkin.device_id', id);
  }
  return id;
});

/// True while the device reports any network. A request can still fail
/// while "online"; screens also fall back to offline on network errors.
final onlineProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  bool online(List<ConnectivityResult> r) => r.any((x) => x != ConnectivityResult.none);
  try {
    yield online(await c.checkConnectivity());
  } catch (_) {
    yield true;
  }
  yield* c.onConnectivityChanged.map(online);
});

/// Offline booking list and queued offline check-ins, kept on the device
/// per staff member. The list holds booking ids, references, slot times and
/// charger type only; no customer data is stored.
class OfflineStore {
  OfflineStore(this._prefs, this.staffId);

  final SharedPreferences _prefs;
  final String staffId;

  String get _cacheKey => 'checkin.cache.$staffId';
  String get _eventsKey => 'checkin.events.$staffId';

  OfflineCache? cacheFor(String stationId) {
    final raw = _prefs.getString('$_cacheKey.$stationId');
    if (raw == null) return null;
    try {
      return OfflineCache.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCache(OfflineCache cache) => _prefs.setString('$_cacheKey.${cache.stationId}', jsonEncode(cache.toJson()));

  List<OfflineCheckinEvent> events() {
    final raw = _prefs.getString(_eventsKey);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).map(OfflineCheckinEvent.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveEvents(List<OfflineCheckinEvent> events) =>
      _prefs.setString(_eventsKey, jsonEncode([for (final e in events) e.toJson()]));
}

typedef OfflineState = ({List<OfflineCheckinEvent> events, bool syncing, DateTime? lastSync, String? lastError});

/// Queue of offline check-ins for the signed-in staff member. Syncs when
/// the network comes back and when asked; every event gets a server verdict
/// and stays visible (accepted or rejected) until cleared.
class OfflineQueue extends AsyncNotifier<OfflineState> {
  OfflineStore? _store;

  @override
  Future<OfflineState> build() async {
    final uid = ref.watch(sessionUserIdProvider).value;
    final prefs = await ref.watch(prefsProvider.future);
    if (uid == null) return (events: const <OfflineCheckinEvent>[], syncing: false, lastSync: null, lastError: null);
    _store = OfflineStore(prefs, uid);
    ref.listen(onlineProvider, (prev, next) {
      if (next.value == true && prev?.value != true) unawaited(sync());
    });
    return (events: _store!.events(), syncing: false, lastSync: null, lastError: null);
  }

  OfflineStore? get store => _store;

  int get pendingCount => state.value?.events.where((e) => e.pending).length ?? 0;

  /// Records a provisional check-in. The booking is not checked in until
  /// the server accepts it.
  Future<OfflineCheckinEvent> record(OfflineBooking b) async {
    final store = _store!;
    final device = await ref.read(deviceIdProvider.future);
    final event = OfflineCheckinEvent(
      eventId: randomId(),
      bookingId: b.id,
      reference: b.reference,
      stationId: b.stationId,
      staffId: store.staffId,
      offlineAt: DateTime.now(),
      deviceId: device,
    );
    final events = [...store.events(), event];
    await store.saveEvents(events);
    state = AsyncData((events: events, syncing: false, lastSync: state.value?.lastSync, lastError: null));
    unawaited(sync());
    return event;
  }

  /// Sends pending events. Safe to call repeatedly: event ids are the
  /// server's idempotency keys, so a resend returns the first verdict.
  Future<void> sync() async {
    final store = _store;
    final current = state.value;
    if (store == null || current == null || current.syncing) return;
    final pending = store.events().where((e) => e.pending).toList();
    if (pending.isEmpty) return;
    state = AsyncData((events: current.events, syncing: true, lastSync: current.lastSync, lastError: null));
    String? error;
    try {
      for (var i = 0; i < pending.length; i += 50) {
        final batch = pending.sublist(i, min(i + 50, pending.length));
        final results = await ref.read(bookingRepositoryProvider).syncOffline(batch);
        final byId = {for (final r in results) r.eventId: r};
        await store.saveEvents([for (final e in store.events()) byId[e.eventId] ?? e]);
      }
    } catch (e) {
      error = AppFailure.from(e).message;
    }
    state = AsyncData((events: store.events(), syncing: false, lastSync: DateTime.now(), lastError: error));
  }

  /// Removes events that already have a verdict.
  Future<void> clearFinished() async {
    final store = _store;
    if (store == null) return;
    final events = store.events().where((e) => e.pending).toList();
    await store.saveEvents(events);
    state = AsyncData((events: events, syncing: false, lastSync: state.value?.lastSync, lastError: null));
  }
}

final offlineQueueProvider = AsyncNotifierProvider<OfflineQueue, OfflineState>(OfflineQueue.new);

final pendingSyncCountProvider =
    Provider<int>((ref) => ref.watch(offlineQueueProvider).value?.events.where((e) => e.pending).length ?? 0);
