import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/place_suggestions.dart';
import '../../state/search.dart';
import '../common/fallback.dart';

/// Near Me without the device location: type a locality, street, landmark,
/// city or PIN code and pick the place; stations near it are shown. Offered
/// when location is off, denied or unavailable. Along My Route has its own
/// screen (route_search_screen.dart).
class AreaSearchScreen extends ConsumerStatefulWidget {
  const AreaSearchScreen({super.key});

  @override
  ConsumerState<AreaSearchScreen> createState() => _AreaSearchScreenState();
}

class _AreaSearchScreenState extends ConsumerState<AreaSearchScreen> {
  final _text = TextEditingController();
  Timer? _debounce;
  AsyncValue<AreaSearchOutcome>? _result;
  String _lastQuery = '';

  /// The full search is still running behind the suggestions shown.
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  /// Shows what is known at once, then asks the server after a short pause
  /// in typing.
  void _onChanged(String v) {
    _debounce?.cancel();
    final q = v.trim();
    if (q.length < 2) {
      setState(() {
        _result = null;
        _loading = false;
      });
      return;
    }
    _lastQuery = q;
    final s = ref.read(placeSuggestionsProvider);
    final now = s.instant(q);
    final done = s.isCached(q);
    setState(() {
      if (now != null) {
        _result = AsyncValue.data(AreaSearchOutcome(now, providerAvailable: true));
      } else if (_result?.hasValue != true) {
        _result = const AsyncValue.loading();
      }
      _loading = !done;
    });
    if (!done) _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String v) async {
    final q = v.trim();
    if (q.length < 2) return;
    _lastQuery = q;
    try {
      final r = await ref.read(placeSuggestionsProvider).fetch(q);
      if (mounted && q == _lastQuery) {
        setState(() {
          _result = AsyncValue.data(r);
          _loading = false;
        });
      }
    } catch (e, st) {
      if (mounted && q == _lastQuery) {
        setState(() {
          _result = AsyncValue.error(e, st);
          _loading = false;
        });
      }
    }
  }

  void _pick(AreaMatch m) {
    ref.read(placeSuggestionsProvider).remember(m);
    ref.read(searchProvider.notifier).setArea(m);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    final r = _result;
    Widget body;
    if (r == null) {
      body = FallbackView(
        compact: true,
        icon: Icons.travel_explore_rounded,
        title: l(K.pickLocationTitle),
        message: l(K.pickLocationBody),
        actions: [
          FallbackAction(l(K.useMyLocation), () {
            ref.read(searchProvider.notifier).useCurrentLocation();
            context.pop();
          }, icon: Icons.my_location_rounded),
        ],
      );
    } else if (r.isLoading) {
      body = const SingleChildScrollView(physics: NeverScrollableScrollPhysics(), padding: EdgeInsets.all(16), child: SkeletonList(count: 4, itemHeight: 60));
    } else if (r.hasError) {
      body = FailureView(error: r.error!, onRetry: () => _search(_text.text), compact: true);
    } else if (r.value!.matches.isEmpty) {
      body = FallbackView(
        compact: true,
        icon: Icons.wrong_location_outlined,
        title: l(K.areaNotFoundTitle),
        message: l(K.areaNotFoundBody, {'q': _lastQuery}),
        actions: [
          FallbackAction(l(K.useMyLocation), () {
            ref.read(searchProvider.notifier).useCurrentLocation();
            context.pop();
          }, icon: Icons.my_location_rounded),
        ],
      );
    } else {
      final matches = r.value!.matches;
      body = ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        if (matches.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(l(K.areaMultiple), style: t.textTheme.labelLarge),
          ),
        if (!r.value!.providerAvailable)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(l(K.areaLimitedSearch), style: t.textTheme.bodySmall),
          ),
        for (final (i, m) in matches.indexed)
          Entrance(
            index: i,
            child: Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(child: Icon(m.fromProvider ? Icons.place_outlined : Icons.ev_station_outlined)),
                title: Text(m.label),
                subtitle: Text([
                  if (m.secondary.isNotEmpty) m.secondary,
                  if (m.stationCount != null) l(K.areaStationCount, {'n': m.stationCount}),
                ].join(' · ')),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pick(m),
              ),
            ),
          ),
      ]);
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: l(K.searchAreaHint),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            suffixIcon: _text.text.isEmpty
                ? null
                : IconButton(
                    tooltip: l(K.clear),
                    onPressed: () {
                      _text.clear();
                      _onChanged('');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
      ),
      body: Column(children: [
        SizedBox(height: 2, child: _loading ? const LinearProgressIndicator(minHeight: 2) : null),
        Expanded(child: AnimatedSwitcher(duration: Motion.fast, child: KeyedSubtree(key: ValueKey(r?.isLoading), child: body))),
      ]),
    );
  }
}
