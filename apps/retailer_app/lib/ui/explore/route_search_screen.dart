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

enum _End { from, to }

/// Plan a trip: type where you start and where you are going. Once both are
/// set the route's stations are shown on Explore. Live location is the other
/// search on Explore, not part of this one.
class RouteSearchScreen extends ConsumerStatefulWidget {
  const RouteSearchScreen({super.key});

  @override
  ConsumerState<RouteSearchScreen> createState() => _RouteSearchScreenState();
}

class _RouteSearchScreenState extends ConsumerState<RouteSearchScreen> {
  final _fromText = TextEditingController();
  final _toText = TextEditingController();
  final _fromFocus = FocusNode();
  final _toFocus = FocusNode();
  TripPlace? _from;
  TripPlace? _to;
  _End _active = _End.from;
  Timer? _debounce;
  AsyncValue<AreaSearchOutcome>? _result;
  String _lastQuery = '';

  /// The full search is still running behind the suggestions shown.
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final trip = ref.read(searchProvider).trip;
    _from = trip?.from;
    _to = trip?.to;
    _active = _from == null ? _End.from : _End.to;
    _fromFocus.addListener(() => _onFocus(_End.from, _fromFocus));
    _toFocus.addListener(() => _onFocus(_End.to, _toFocus));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _fromText.text = _from == null ? '' : _labelOf(_from!);
      _toText.text = _to == null ? '' : _labelOf(_to!);
      (_active == _End.from ? _fromFocus : _toFocus).requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _fromText.dispose();
    _toText.dispose();
    _fromFocus.dispose();
    _toFocus.dispose();
    super.dispose();
  }

  String _labelOf(TripPlace p) => p.fromDevice ? context.l(K.yourLocation) : p.label;

  void _onFocus(_End end, FocusNode node) {
    if (!node.hasFocus || _active == end) return;
    setState(() {
      _active = end;
      _result = null;
    });
    final text = (end == _End.from ? _fromText : _toText).text;
    final chosen = end == _End.from ? _from : _to;
    // Re-search what is typed unless it is the place already chosen.
    if (chosen == null || text != _labelOf(chosen)) _suggest(text);
  }

  void _onChanged(_End end, String v) {
    // Typing replaces the chosen place.
    setState(() => end == _End.from ? _from = null : _to = null);
    _suggest(v);
  }

  /// Rank destinations near the start, and starts near the destination.
  TripPlace? get _near => _active == _End.to ? _from : _to;

  /// Shows what is known at once, then asks the server after a short pause
  /// in typing.
  void _suggest(String v) {
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
    final now = s.instant(q, near: _near);
    final done = s.isCached(q, near: _near);
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

  Future<void> _search(String q) async {
    _lastQuery = q;
    try {
      final r = await ref.read(placeSuggestionsProvider).fetch(q, near: _near);
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

  void _choose(_End end, AreaMatch match) {
    ref.read(placeSuggestionsProvider).remember(match);
    final place = TripPlace.fromArea(match);
    _debounce?.cancel();
    setState(() {
      _loading = false;
      if (end == _End.from) {
        _from = place;
        _fromText.text = _labelOf(place);
      } else {
        _to = place;
        _toText.text = _labelOf(place);
      }
      _result = null;
    });
    if (_from != null && _to != null) {
      _go();
    } else {
      (end == _End.from ? _toFocus : _fromFocus).requestFocus();
    }
  }

  void _swap() {
    setState(() {
      final f = _from;
      _from = _to;
      _to = f;
      final t = _fromText.text;
      _fromText.text = _toText.text;
      _toText.text = t;
      _result = null;
    });
  }

  void _go() {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return;
    FocusScope.of(context).unfocus();
    ref.read(searchProvider.notifier).setTrip(from, to);
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    final ready = _from != null && _to != null;
    return Scaffold(
      appBar: AppBar(title: Text(l(K.planTripTitle))),
      body: Column(children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: Row(children: [
                    Expanded(
                      child: Column(children: [
                        _PlaceField(
                          controller: _fromText,
                          focusNode: _fromFocus,
                          label: l(K.tripFrom),
                          hint: l(K.tripFromHint),
                          icon: Icons.trip_origin_rounded,
                          iconColor: Brand.green,
                          active: _active == _End.from,
                          onChanged: (v) => _onChanged(_End.from, v),
                          onClear: () {
                            _fromText.clear();
                            _onChanged(_End.from, '');
                          },
                        ),
                        const Divider(height: 1, indent: 52),
                        _PlaceField(
                          controller: _toText,
                          focusNode: _toFocus,
                          label: l(K.tripTo),
                          hint: l(K.tripToHint),
                          icon: Icons.place_rounded,
                          iconColor: Brand.ocean,
                          active: _active == _End.to,
                          onChanged: (v) => _onChanged(_End.to, v),
                          onClear: () {
                            _toText.clear();
                            _onChanged(_End.to, '');
                          },
                        ),
                      ]),
                    ),
                    IconButton(tooltip: l(K.swapTrip), onPressed: _swap, icon: const Icon(Icons.swap_vert_rounded)),
                  ]),
                ),
              ),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: ready ? _go : null,
                  icon: const Icon(Icons.alt_route_rounded),
                  label: Text(l(K.findStationsOnRoute)),
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: 2, child: _loading ? const LinearProgressIndicator(minHeight: 2) : null),
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.fast,
            child: KeyedSubtree(key: ValueKey('${_active.name}-${_result?.isLoading}'), child: _suggestions(l, t)),
          ),
        ),
      ]),
    );
  }

  Widget _suggestions(L l, ThemeData t) {
    final r = _result;
    final end = _active;
    final children = <Widget>[];
    if (r == null) {
      final recent = ref.read(placeSuggestionsProvider).recent();
      if (recent.isNotEmpty) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(l(K.recentPlaces), style: t.textTheme.labelLarge)),
                  for (final m in recent)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.history_rounded)),
                        title: Text(m.label),
                        subtitle: m.secondary.isEmpty ? null : Text(m.secondary),
                        onTap: () => _choose(end, m),
                      ),
                    ),
                ]),
              ),
            ),
          ],
        );
      }
      return FallbackView(
        compact: true,
        icon: Icons.alt_route_rounded,
        title: l(K.routeSearchIntroTitle),
        message: l(K.routeSearchIntroBody),
      );
    } else if (r.isLoading) {
      children.add(const SkeletonList(count: 4, itemHeight: 60));
    } else if (r.hasError) {
      children.add(FailureView(error: r.error!, onRetry: () => _search(_lastQuery), compact: true));
    } else if (r.value!.matches.isEmpty) {
      children.add(FallbackView(
        compact: true,
        icon: Icons.wrong_location_outlined,
        title: l(K.areaNotFoundTitle),
        message: l(K.areaNotFoundBody, {'q': _lastQuery}),
      ));
    } else {
      final matches = r.value!.matches;
      if (!r.value!.providerAvailable) {
        children.add(Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(l(K.areaLimitedSearch), style: t.textTheme.bodySmall)));
      }
      for (final (i, m) in matches.indexed) {
        children.add(Entrance(
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
              onTap: () => _choose(end, m),
            ),
          ),
        ));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)))],
    );
  }
}

class _PlaceField extends StatelessWidget {
  const _PlaceField({
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.hint,
    required this.icon,
    required this.iconColor,
    required this.active,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final String hint;
  final IconData icon;
  final Color iconColor;
  final bool active;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => TextField(
          controller: controller,
          focusNode: focusNode,
          textInputAction: TextInputAction.search,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            prefixIcon: Icon(icon, color: iconColor),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: active,
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(tooltip: context.l(K.clear), onPressed: onClear, icon: const Icon(Icons.close_rounded)),
          ),
        ),
      );
}
