import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_validation/shared_validation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Station location. With MAPS_ENABLED (and a Maps key in the native
/// config) the owner drags a pin; otherwise they type coordinates, which is
/// also always available for precise correction. Reviewers check the pin
/// against the address before approval.
class LocationPicker extends StatefulWidget {
  const LocationPicker({super.key, required this.latitude, required this.longitude, required this.onChanged});

  final double? latitude;
  final double? longitude;
  final void Function(double lat, double lng) onChanged;

  static const mapsEnabled = bool.fromEnvironment('MAPS_ENABLED');

  @override
  State<LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker> {
  late final _lat = TextEditingController(text: widget.latitude?.toStringAsFixed(6));
  late final _lng = TextEditingController(text: widget.longitude?.toStringAsFixed(6));
  GoogleMapController? _map;

  static const _india = LatLng(20.5937, 78.9629);

  @override
  void dispose() {
    _lat.dispose();
    _lng.dispose();
    _map?.dispose();
    super.dispose();
  }

  void _set(double lat, double lng, {bool moveMap = false}) {
    lat = Coordinates.round6(lat);
    lng = Coordinates.round6(lng);
    _lat.text = lat.toStringAsFixed(6);
    _lng.text = lng.toStringAsFixed(6);
    widget.onChanged(lat, lng);
    if (moveMap) _map?.animateCamera(CameraUpdate.newLatLng(LatLng(lat, lng)));
    setState(() {});
  }

  void _fromText() {
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    if (lat != null && lng != null) _set(lat, lng, moveMap: true);
  }

  @override
  Widget build(BuildContext context) {
    final lat = double.tryParse(_lat.text);
    final lng = double.tryParse(_lng.text);
    final error = Coordinates.validate(lat, lng);
    final pos = lat != null && lng != null ? LatLng(lat, lng) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (LocationPicker.mapsEnabled)
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 260,
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: pos ?? _india, zoom: pos == null ? 4 : 17),
              onMapCreated: (c) => _map = c,
              onTap: (p) => _set(p.latitude, p.longitude),
              myLocationButtonEnabled: false,
              markers: {
                if (pos != null)
                  Marker(
                    markerId: const MarkerId('station'),
                    position: pos,
                    draggable: true,
                    onDragEnd: (p) => _set(p.latitude, p.longitude),
                  ),
              },
            ),
          ),
        ),
      if (LocationPicker.mapsEnabled) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Tap the map or drag the pin to the charger entrance.')),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _lat,
            decoration: const InputDecoration(labelText: 'Latitude'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            onChanged: (_) => _fromText(),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _lng,
            decoration: const InputDecoration(labelText: 'Longitude'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            onChanged: (_) => _fromText(),
          ),
        ),
      ]),
      if (error != null && (_lat.text.isNotEmpty || _lng.text.isNotEmpty))
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (pos != null && error == null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.map_outlined),
            label: const Text('Check this point in Google Maps'),
            onPressed: () => launchUrl(
              Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': '${pos.latitude},${pos.longitude}'}),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
    ]);
  }
}
