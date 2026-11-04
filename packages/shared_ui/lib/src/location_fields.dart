import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';

const _other = '\u0000other';

/// Cascading State -> District -> City dropdowns backed by the location lists
/// in the database. Each list ends with "Other", which shows a text field for
/// a value that is missing; the form then raises a request with
/// [LocationRepository.requestNew] so ChargeKaro can add it to the list.
class LocationFields extends ConsumerStatefulWidget {
  const LocationFields({
    super.key,
    required this.onChanged,
    this.initial = const AddressPlace(),
    this.required = true,
    this.helperText,
    this.spacing = 12,
  });

  final AddressPlace initial;
  final ValueChanged<AddressPlace> onChanged;

  /// When false, every level may be left empty (an optional address).
  final bool required;
  final String? helperText;
  final double spacing;

  @override
  ConsumerState<LocationFields> createState() => _LocationFieldsState();
}

class _Level {
  _Level(String value) : text = TextEditingController(text: value);

  /// Picked from the list (canonical spelling), or empty.
  String picked = '';

  /// "Other" chosen; the value is in [text].
  bool other = false;

  /// The saved value before the lists loaded; resolved against the list.
  bool resolved = false;
  final TextEditingController text;

  String get value => other ? text.text.trim() : picked;

  void reset() {
    picked = '';
    other = false;
    resolved = true;
    text.clear();
  }
}

class _LocationFieldsState extends ConsumerState<LocationFields> {
  late final _state = _Level(widget.initial.state);
  late final _district = _Level(widget.initial.district);
  late final _city = _Level(widget.initial.city);

  @override
  void dispose() {
    _state.text.dispose();
    _district.text.dispose();
    _city.text.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(AddressPlace(
        state: _state.value,
        district: _district.value,
        city: _city.value,
        newState: _state.other,
        newDistrict: _district.other,
        newCity: _city.other,
      ));

  /// Matches the saved value to the list once it has loaded: a known name is
  /// selected, an unknown one shows under "Other".
  void _resolve(_Level l, List<Place>? items) {
    if (l.resolved) return;
    l.resolved = true;
    final saved = l.text.text.trim();
    if (saved.isEmpty) return;
    final match = items?.where((p) => p.name.toLowerCase() == saved.toLowerCase()).firstOrNull;
    if (match != null) {
      l.picked = match.name;
      l.text.clear();
    } else {
      l.other = true;
    }
  }

  int? _idOf(_Level l, List<Place>? items) =>
      l.other ? null : items?.where((p) => p.name == l.picked).firstOrNull?.id;

  @override
  Widget build(BuildContext context) {
    final states = ref.watch(locationStatesProvider);
    if (states.hasValue || states.hasError) _resolve(_state, states.value);
    final stateId = _idOf(_state, states.value);

    final districts = stateId == null ? null : ref.watch(locationDistrictsProvider(stateId));
    final districtItems = _state.other ? const <Place>[] : districts?.value;
    if (_state.other || (districts != null && (districts.hasValue || districts.hasError))) _resolve(_district, districtItems);
    final districtId = _idOf(_district, districtItems);

    final cities = districtId == null ? null : ref.watch(locationCitiesProvider(districtId));
    final cityItems = _district.other ? const <Place>[] : cities?.value;
    if (_district.other || (cities != null && (cities.hasValue || cities.hasError))) _resolve(_city, cityItems);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _field(
        level: _state,
        label: 'State',
        items: states.value,
        loading: states.isLoading && !states.hasValue,
        failed: states.hasError && !states.hasValue,
        retry: () => ref.invalidate(locationStatesProvider),
        enabled: true,
        onPicked: () {
          _district.reset();
          _city.reset();
        },
      ),
      _field(
        level: _district,
        label: 'District',
        items: districtItems,
        loading: districts?.isLoading == true && districts?.hasValue != true,
        failed: districts?.hasError == true && districts?.hasValue != true,
        retry: stateId == null ? null : () => ref.invalidate(locationDistrictsProvider(stateId)),
        enabled: _state.value.isNotEmpty,
        parentIsNew: _state.other,
        onPicked: _city.reset,
      ),
      _field(
        level: _city,
        label: 'City / town',
        items: cityItems,
        loading: cities?.isLoading == true && cities?.hasValue != true,
        failed: cities?.hasError == true && cities?.hasValue != true,
        retry: districtId == null ? null : () => ref.invalidate(locationCitiesProvider(districtId)),
        enabled: _district.value.isNotEmpty,
        parentIsNew: _district.other || _state.other,
        onPicked: () {},
      ),
    ]);
  }

  Widget _field({
    required _Level level,
    required String label,
    required List<Place>? items,
    required bool loading,
    required bool failed,
    required VoidCallback? retry,
    required bool enabled,
    required VoidCallback onPicked,
    bool parentIsNew = false,
  }) {
    final lower = label.split(' ').first.toLowerCase();
    // A new parent has no list yet: the only choice is to type the value.
    final typeOnly = parentIsNew || failed;
    if (typeOnly && !level.other) level.other = true;

    final textField = Padding(
      padding: EdgeInsets.only(bottom: widget.spacing),
      child: TextFormField(
        controller: level.text,
        enabled: enabled,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: typeOnly ? label : 'Type the $lower name',
          helperText: failed
              ? 'Could not load the list. Type the name.'
              : 'ChargeKaro will review it and add it to the list.',
          suffixIcon: failed && retry != null ? IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: retry) : null,
        ),
        // Rebuild so the next level is enabled once this one has a value.
        onChanged: (_) => setState(_emit),
        validator: (v) {
          final t = v?.trim() ?? '';
          if (t.isEmpty) return widget.required && enabled ? 'Enter the $lower' : null;
          if (t.length < 2 || t.length > 80) return 'Use 2 to 80 characters';
          return null;
        },
      ),
    );
    if (typeOnly) return textField;

    final names = [for (final p in items ?? const <Place>[]) p.name];
    final value = level.other ? _other : (names.contains(level.picked) ? level.picked : null);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.only(bottom: widget.spacing),
        child: DropdownButtonFormField<String>(
          key: ValueKey('$label:${items?.length}:$value'),
          initialValue: value,
          isExpanded: true,
          menuMaxHeight: 420,
          decoration: InputDecoration(
            labelText: label,
            helperText: level.other ? null : widget.helperText,
            suffixIcon: loading ? const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))) : null,
          ),
          hint: Text(enabled ? 'Select $lower' : 'Select the ${label == 'District' ? 'state' : 'district'} first'),
          items: [
            for (final n in names) DropdownMenuItem(value: n, child: Text(n, overflow: TextOverflow.ellipsis)),
            if (items != null) const DropdownMenuItem(value: _other, child: Text('Other (not in the list)')),
          ],
          onChanged: !enabled || items == null
              ? null
              : (v) => setState(() {
                    if (v == null) return;
                    final wasOther = level.other;
                    level.other = v == _other;
                    level.resolved = true;
                    if (!level.other) {
                      level.picked = v;
                      level.text.clear();
                    } else {
                      level.picked = '';
                    }
                    if (!wasOther || !level.other) onPicked();
                    _emit();
                  }),
          validator: (v) => widget.required && enabled && v == null ? 'Select the $lower' : null,
        ),
      ),
      if (level.other) textField,
    ]);
  }
}
