import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small on-device state: recent stations, the last search, the unfinished
/// booking and UI preferences. Nothing here is authoritative; bookings and
/// payments always come from the server.
class LocalStore {
  LocalStore(this._prefs);

  final KeyValueStore _prefs;

  static Future<LocalStore> open() async => LocalStore(_PrefsStore(await SharedPreferencesWithCache.create(
        cacheOptions: const SharedPreferencesWithCacheOptions(),
      )));

  /// In-memory store for tests and when device storage is unavailable
  /// (for example private browsing). Nothing survives a restart.
  static Future<LocalStore> memory() async => LocalStore(MemoryStore());

  static const _recent = 'recent_stations_v1';
  static const _search = 'last_search_v1';
  static const _draft = 'booking_draft_v1';
  static const _locale = 'locale_v1';
  static const _otp = 'otp_attempts_v1';

  List<RecentStation> recentStations() {
    final raw = _prefs.getString(_recent);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List).map((e) => RecentStation.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> addRecentStation(RecentStation s) async {
    final list = [s, ...recentStations().where((r) => r.id != s.id)].take(8).toList();
    await _prefs.setString(_recent, jsonEncode(list.map((r) => r.toJson()).toList()));
  }

  Future<void> clearRecent() => _prefs.remove(_recent);

  SavedSearch? lastSearch() {
    final raw = _prefs.getString(_search);
    if (raw == null) return null;
    try {
      return SavedSearch.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSearch(SavedSearch s) => _prefs.setString(_search, jsonEncode(s.toJson()));

  Map<String, dynamic>? draft() {
    final raw = _prefs.getString(_draft);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDraft(Map<String, dynamic>? json) => json == null ? _prefs.remove(_draft) : _prefs.setString(_draft, jsonEncode(json));

  String? locale() => _prefs.getString(_locale);
  Future<void> setLocale(String code) => _prefs.setString(_locale, code);

  /// OTP request timestamps per phone, to pace resends on this device. The
  /// auth server enforces the real limits.
  List<DateTime> otpRequests(String phone) {
    final raw = _prefs.getString(_otp);
    if (raw == null) return const [];
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return ((map[phone] as List?) ?? const []).map((e) => DateTime.parse(e as String)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> recordOtpRequest(String phone, DateTime at) async {
    Map<String, dynamic> map;
    try {
      map = jsonDecode(_prefs.getString(_otp) ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      map = {};
    }
    final recent = [...otpRequests(phone).where((t) => at.difference(t) < const Duration(hours: 1)), at];
    map[phone] = recent.map((t) => t.toIso8601String()).toList();
    await _prefs.setString(_otp, jsonEncode(map));
  }
}

@immutable
class RecentStation {
  const RecentStation({required this.id, required this.name, required this.subtitle, required this.viewedAt});
  factory RecentStation.fromJson(Map<String, dynamic> j) =>
      RecentStation(id: j['id'] as String, name: j['name'] as String, subtitle: j['subtitle'] as String? ?? '', viewedAt: DateTime.parse(j['at'] as String));
  final String id;
  final String name;
  final String subtitle;
  final DateTime viewedAt;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'subtitle': subtitle, 'at': viewedAt.toIso8601String()};
}

@immutable
class SavedSearch {
  const SavedSearch({required this.label, required this.latitude, required this.longitude, required this.radiusKm, required this.fromDevice});
  factory SavedSearch.fromJson(Map<String, dynamic> j) => SavedSearch(
        label: j['label'] as String,
        latitude: (j['lat'] as num).toDouble(),
        longitude: (j['lng'] as num).toDouble(),
        radiusKm: (j['radius'] as num).toDouble(),
        fromDevice: j['device'] as bool? ?? false,
      );
  final String label;
  final double latitude;
  final double longitude;
  final double radiusKm;
  final bool fromDevice;
  Map<String, dynamic> toJson() => {'label': label, 'lat': latitude, 'lng': longitude, 'radius': radiusKm, 'device': fromDevice};
}

/// The few storage operations LocalStore needs.
abstract interface class KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

class _PrefsStore implements KeyValueStore {
  _PrefsStore(this._p);
  final SharedPreferencesWithCache _p;
  @override
  String? getString(String key) => _p.getString(key);
  @override
  Future<void> setString(String key, String value) => _p.setString(key, value);
  @override
  Future<void> remove(String key) => _p.remove(key);
}

class MemoryStore implements KeyValueStore {
  final _m = <String, String>{};
  @override
  String? getString(String key) => _m[key];
  @override
  Future<void> setString(String key, String value) async => _m[key] = value;
  @override
  Future<void> remove(String key) async => _m.remove(key);
}
