import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../state.dart';
import '../../widgets/location_picker.dart';

/// Create a draft station, or edit one. For an approved station, changes to
/// name/address/location become a change request for platform review; the
/// other fields save directly.
class StationFormPage extends ConsumerStatefulWidget {
  const StationFormPage({super.key, this.stationId});
  final String? stationId;

  @override
  ConsumerState<StationFormPage> createState() => _StationFormPageState();
}

class _StationFormPageState extends ConsumerState<StationFormPage> {
  final _form = GlobalKey<FormState>();
  final _c = {
    for (final k in [
      'name', 'description', 'address_line1', 'address_line2', 'landmark', 'city', 'district', 'state', 'postal_code',
      'contact_phone', 'emergency_contact_name', 'emergency_contact_phone', 'parking_spaces',
    ])
      k: TextEditingController(),
  };
  double? _lat;
  double? _lng;
  Set<Amenity> _amenities = {};
  Set<StationPaymentMethod> _payments = {};
  Station? _original;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.stationId == null) {
      _loaded = true;
      _c['parking_spaces']!.text = '1';
    } else {
      ref.read(stationRepositoryProvider).station(widget.stationId!).then((s) {
        if (!mounted) return;
        setState(() {
          _original = s;
          _c['name']!.text = s.name;
          _c['description']!.text = s.description ?? '';
          _c['address_line1']!.text = s.addressLine1;
          _c['address_line2']!.text = s.addressLine2 ?? '';
          _c['landmark']!.text = s.landmark ?? '';
          _c['city']!.text = s.city;
          _c['district']!.text = s.district;
          _c['state']!.text = s.state;
          _c['postal_code']!.text = s.postalCode;
          _c['contact_phone']!.text = s.contactPhone;
          _c['emergency_contact_name']!.text = s.emergencyContactName ?? '';
          _c['emergency_contact_phone']!.text = s.emergencyContactPhone ?? '';
          _c['parking_spaces']!.text = '${s.parkingSpaces}';
          _lat = s.latitude;
          _lng = s.longitude;
          _amenities = {...s.amenities};
          _payments = {...s.acceptedPaymentMethods};
          _loaded = true;
        });
      });
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, Object?> _fields() {
    String? t(String k) => _c[k]!.text.trim().isEmpty ? null : _c[k]!.text.trim();
    return {
      'name': t('name'),
      'description': t('description'),
      'address_line1': t('address_line1'),
      'address_line2': t('address_line2'),
      'landmark': t('landmark'),
      'city': t('city'),
      'district': t('district'),
      'state': t('state'),
      'postal_code': t('postal_code'),
      'latitude': _lat,
      'longitude': _lng,
      'contact_phone': Validators.normalizePhone(t('contact_phone')),
      'emergency_contact_name': t('emergency_contact_name'),
      'emergency_contact_phone': t('emergency_contact_phone') == null ? null : Validators.normalizePhone(t('emergency_contact_phone')),
      'parking_spaces': int.tryParse(_c['parking_spaces']!.text.trim()) ?? 0,
      'amenities': _amenities.map((a) => a.wire).toList(),
      'accepted_payment_methods': _payments.map((p) => p.wire).toList(),
    };
  }

  Map<String, Object?> _originalFields(Station s) => {
        'name': s.name,
        'description': s.description,
        'address_line1': s.addressLine1,
        'address_line2': s.addressLine2,
        'landmark': s.landmark,
        'city': s.city,
        'district': s.district,
        'state': s.state,
        'postal_code': s.postalCode,
        'latitude': s.latitude,
        'longitude': s.longitude,
        'contact_phone': s.contactPhone,
        'emergency_contact_name': s.emergencyContactName,
        'emergency_contact_phone': s.emergencyContactPhone,
        'parking_spaces': s.parkingSpaces,
        'amenities': s.amenities.map((a) => a.wire).toList(),
        'accepted_payment_methods': s.acceptedPaymentMethods.map((p) => p.wire).toList(),
      };

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final coordError = Coordinates.validate(_lat, _lng);
    if (coordError != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(coordError)));
      return;
    }
    setState(() => _busy = true);
    final repo = ref.read(stationRepositoryProvider);
    final fields = _fields();
    String? message;
    final ok = await runAction(context, () async {
      final original = _original;
      if (original == null) {
        final access = ref.read(currentAccessProvider)!;
        final created = await repo.createStation(access.businessId, fields);
        ref.invalidate(stationsProvider);
        if (mounted) context.go('/stations/${created.id}');
        return;
      }
      final before = _originalFields(original);
      final changed = {
        for (final e in fields.entries)
          if (e.value.toString() != before[e.key].toString()) e.key: e.value,
      };
      if (changed.isEmpty) return;
      final sensitive = original.isApproved
          ? {for (final e in changed.entries) if (Station.sensitiveFields.contains(e.key)) e.key: e.value}
          : <String, Object?>{};
      final direct = {for (final e in changed.entries) if (!sensitive.containsKey(e.key)) e.key: e.value};
      if (direct.isNotEmpty) await repo.updateStation(original.id, direct);
      if (sensitive.isNotEmpty) {
        await repo.requestChange(original.id, sensitive, note: 'Submitted from the Business App');
        message = 'Saved. Name, address and location changes were sent to ChargeKaro for review.';
      }
      ref.invalidate(stationProvider(original.id));
      ref.invalidate(stationsProvider);
      if (mounted) context.pop();
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok && message != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message!)));
  }

  Widget _f(String key, String label,
      {String? Function(String?)? validator, TextInputType? keyboard, TextCapitalization caps = TextCapitalization.sentences, int lines = 1}) {
    final locked = (_original?.isApproved ?? false) && Station.sensitiveFields.contains(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _c[key],
        decoration: InputDecoration(labelText: label, helperText: locked ? 'Changes are reviewed by ChargeKaro' : null),
        validator: validator,
        keyboardType: keyboard,
        textCapitalization: caps,
        maxLines: lines,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.stationId == null;
    return Scaffold(
      appBar: AppBar(title: Text(creating ? 'New station' : 'Edit station')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Form(
                key: _form,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  if (creating)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text('Step 1 of 4: station details. Next you add charging points, hours and documents, then submit for review.'),
                    ),
                  _section('Basics'),
                  _f('name', 'Station name', validator: Validators.length(min: 2, max: 120, field: 'Name'), caps: TextCapitalization.words),
                  _f('description', 'Description (optional)', lines: 3),
                  _section('Address'),
                  _f('address_line1', 'Address line 1', validator: Validators.length(min: 3, max: 200, field: 'Address')),
                  _f('address_line2', 'Address line 2 (optional)'),
                  _f('landmark', 'Landmark (optional)'),
                  _f('city', 'City', validator: Validators.required(), caps: TextCapitalization.words),
                  _f('district', 'District', validator: Validators.required(), caps: TextCapitalization.words),
                  _f('state', 'State', validator: Validators.required(), caps: TextCapitalization.words),
                  _f('postal_code', 'PIN code', validator: Validators.pinCode, keyboard: TextInputType.number),
                  _section('Location'),
                  LocationPicker(latitude: _lat, longitude: _lng, onChanged: (a, b) => setState(() {
                    _lat = a;
                    _lng = b;
                  })),
                  const SizedBox(height: 12),
                  _section('Contact'),
                  _f('contact_phone', 'Station phone', validator: Validators.phone, keyboard: TextInputType.phone),
                  _f('emergency_contact_name', 'Emergency contact name (optional)', caps: TextCapitalization.words),
                  _f('emergency_contact_phone', 'Emergency contact phone (optional)',
                      validator: Validators.optional(Validators.phone), keyboard: TextInputType.phone),
                  _section('Facilities'),
                  _f('parking_spaces', 'Parking spaces', validator: Validators.intRange(0, 500, field: 'Parking spaces'), keyboard: TextInputType.number),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final a in Amenity.values)
                      FilterChip(
                        label: Text(a.label),
                        selected: _amenities.contains(a),
                        onSelected: (v) => setState(() => v ? _amenities.add(a) : _amenities.remove(a)),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  Text('How customers pay you for charging', style: Theme.of(context).textTheme.titleSmall),
                  const Text('Charging fees are paid to you at the station. ChargeKaro never collects them.'),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final p in StationPaymentMethod.values)
                      FilterChip(
                        label: Text(p.label),
                        selected: _payments.contains(p),
                        onSelected: (v) => setState(() => v ? _payments.add(p) : _payments.remove(p)),
                      ),
                  ]),
                  const SizedBox(height: 24),
                  FilledButton(onPressed: _busy ? null : _save, child: Text(creating ? 'Save and continue' : 'Save')),
                ]),
              ),
            ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Text(t, style: Theme.of(context).textTheme.titleMedium),
      );
}
