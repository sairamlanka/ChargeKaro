import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../../state/search.dart';
import '../common/fallback.dart';

/// Type a locality, street, landmark, city or PIN code; pick the intended
/// place when several match.
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

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(v));
  }

  Future<void> _search(String v) async {
    final q = v.trim();
    if (q.length < 2) {
      setState(() => _result = null);
      return;
    }
    _lastQuery = q;
    setState(() => _result = const AsyncValue.loading());
    try {
      final r = await ref.read(retailRepositoryProvider).searchAreas(q);
      if (mounted && q == _lastQuery) setState(() => _result = AsyncValue.data(r));
    } catch (e, st) {
      if (mounted && q == _lastQuery) setState(() => _result = AsyncValue.error(e, st));
    }
  }

  void _pick(AreaMatch m) {
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
        title: l(K.areaSearchIntroTitle),
        message: l(K.areaSearchIntroBody),
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
                      setState(() => _result = null);
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
      ),
      body: AnimatedSwitcher(duration: Motion.fast, child: KeyedSubtree(key: ValueKey(r?.isLoading), child: body)),
    );
  }
}
