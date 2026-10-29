import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_store.dart';
import '../data/models.dart';
import '../data/retail_repository.dart';
import 'providers.dart';

/// Place suggestions while the customer types. Places picked before and
/// earlier answers (a search for "gach" already answers "gachi") show at
/// once; the full search replaces them when it arrives. Shared by the trip
/// planner and the Near Me place picker.
class PlaceSuggestions {
  PlaceSuggestions(this._repo, this._store);

  final RetailRepository _repo;
  final LocalStore _store;

  /// Full answers by query, oldest first, for this app session.
  final _cache = <String, AreaSearchOutcome>{};
  static const _maxCached = 100;

  static String _key(String q, TripPlace? near) =>
      '${q.trim().toLowerCase()}|${near == null ? '' : '${near.latitude.toStringAsFixed(1)},${near.longitude.toStringAsFixed(1)}'}';

  List<AreaMatch> recent() => _store.recentPlaces();

  bool isCached(String query, {TripPlace? near}) => _cache.containsKey(_key(query, near));

  /// What can be shown without the network, or null when there is nothing.
  List<AreaMatch>? instant(String query, {TripPlace? near}) {
    final q = query.trim().toLowerCase();
    if (q.length < 2) return null;
    final exact = _cache[_key(q, near)];
    if (exact != null) return exact.matches;
    bool hit(AreaMatch m) => m.label.toLowerCase().contains(q) || m.secondary.toLowerCase().contains(q);
    final out = <AreaMatch>[...recent().where(hit)];
    // The answer for the longest shorter query, narrowed to this one.
    for (var n = q.length - 1; n >= 2; n--) {
      final earlier = _cache[_key(q.substring(0, n), near)];
      if (earlier != null) {
        out.addAll(earlier.matches.where(hit));
        break;
      }
    }
    final seen = <String>{};
    final unique = [
      for (final m in out)
        if (seen.add('${m.label.toLowerCase()}|${m.latitude.toStringAsFixed(3)}|${m.longitude.toStringAsFixed(3)}')) m,
    ];
    return unique.isEmpty ? null : unique;
  }

  Future<AreaSearchOutcome> fetch(String query, {TripPlace? near}) async {
    final key = _key(query, near);
    final cached = _cache[key];
    if (cached != null) return cached;
    final r = await _repo.searchAreas(query.trim(), near: near);
    // A partial answer (map search down) is not kept, so it is asked again.
    if (r.providerAvailable) {
      _cache[key] = r;
      if (_cache.length > _maxCached) _cache.remove(_cache.keys.first);
    }
    return r;
  }

  Future<void> remember(AreaMatch m) => _store.addRecentPlace(m);
}

final placeSuggestionsProvider = Provider<PlaceSuggestions>(
  (ref) => PlaceSuggestions(ref.watch(retailRepositoryProvider), ref.watch(localStoreProvider)),
);
