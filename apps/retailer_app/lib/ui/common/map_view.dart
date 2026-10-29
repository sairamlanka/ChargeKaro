import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import 'widgets.dart';

/// Map tiles. OpenStreetMap by default (no key; light use only, see
/// docs); set MAP_TILE_URL to a commercial tile service for production.
const _tileUrl = String.fromEnvironment('MAP_TILE_URL', defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
const _tileAttribution = String.fromEnvironment('MAP_TILE_ATTRIBUTION', defaultValue: '© OpenStreetMap contributors');

/// Stations around the search centre with the search radius drawn. If tiles
/// cannot load, says so and offers the list instead of showing a blank map.
class StationsMap extends StatefulWidget {
  const StationsMap({
    super.key,
    required this.stations,
    required this.centerLat,
    required this.centerLng,
    required this.radiusKm,
    required this.onOpen,
    required this.onShowList,
    this.showUserDot = false,
  });

  final List<StationSummary> stations;
  final double centerLat;
  final double centerLng;
  final double radiusKm;
  final ValueChanged<StationSummary> onOpen;
  final VoidCallback onShowList;
  final bool showUserDot;

  @override
  State<StationsMap> createState() => _StationsMapState();
}

class _StationsMapState extends State<StationsMap> {
  StationSummary? _selected;
  int _tileErrors = 0;
  int _tileLoads = 0;

  bool get _tilesFailing => _tileErrors >= 6 && _tileLoads == 0;

  double get _zoom {
    // Fit the radius circle in roughly 360 logical pixels.
    final metersPerPixel = widget.radiusKm * 2000 / 360;
    final z = math.log(156543.03 * math.cos(widget.centerLat * math.pi / 180) / metersPerPixel) / math.ln2;
    return z.clamp(3, 17).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final center = LatLng(widget.centerLat, widget.centerLng);
    return Stack(children: [
      Semantics(
        label: l(K.mapSemantics, {'n': widget.stations.length}),
        child: FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: _zoom,
            onTap: (_, _) => setState(() => _selected = null),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            TileLayer(
              urlTemplate: _tileUrl,
              userAgentPackageName: 'com.chargekaro.retailer_app',
              tileBuilder: (context, tile, image) {
                _tileLoads++;
                return tile;
              },
              errorTileCallback: (_, _, _) {
                if (!mounted) return;
                _tileErrors++;
                if (_tilesFailing) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
              },
            ),
            CircleLayer(circles: [
              CircleMarker(
                point: center,
                radius: widget.radiusKm * 1000,
                useRadiusInMeter: true,
                color: Brand.green.withValues(alpha: 0.08),
                borderColor: Brand.green.withValues(alpha: 0.6),
                borderStrokeWidth: 1.5,
              ),
            ]),
            MarkerLayer(markers: [
              Marker(
                point: center,
                width: 28,
                height: 28,
                child: widget.showUserDot
                    ? PulseDot(color: Brand.ocean, size: 10)
                    : Icon(Icons.location_searching_rounded, color: Brand.ocean, size: 24, semanticLabel: l(K.searchCentre)),
              ),
              for (final s in widget.stations)
                Marker(
                  point: LatLng(s.latitude, s.longitude),
                  width: 44,
                  height: 52,
                  alignment: Alignment.topCenter,
                  child: _Pin(station: s, selected: _selected?.id == s.id, onTap: () => setState(() => _selected = s)),
                ),
            ]),
            const SimpleAttributionWidget(source: Text(_tileAttribution)),
          ],
        ),
      ),
      if (_tilesFailing)
        Positioned(
          left: 16,
          right: 16,
          top: 16,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Icon(Icons.map_outlined, color: scheme.error),
                const SizedBox(width: 10),
                Expanded(child: Text(l(K.mapUnavailable))),
                TextButton(onPressed: widget.onShowList, child: Text(l(K.showList))),
              ]),
            ),
          ),
        ),
      AnimatedPositioned(
        duration: Motion.medium,
        curve: Motion.emphasized,
        left: 12,
        right: 12,
        bottom: _selected == null ? -320 : 12,
        child: _selected == null
            ? const SizedBox.shrink()
            : StationCard(station: _selected!, compact: true, onOpen: () => widget.onOpen(_selected!)),
      ),
    ]);
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.station, required this.selected, required this.onTap});
  final StationSummary station;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final s = station;
    final color = !s.bookable ? Colors.grey.shade600 : (s.points.available > 0 ? Brand.green : Brand.ocean);
    final icon = !s.bookable ? Icons.block_rounded : Icons.bolt_rounded;
    return Semantics(
      button: true,
      label: '${s.name}. ${s.bookable ? l(K.statusOpen) : l(K.statusNotAccepting)}',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          scale: selected ? 1.2 : 1,
          duration: Motion.fast,
          alignment: Alignment.bottomCenter,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            Container(width: 3, height: 10, color: color),
          ]),
        ),
      ),
    );
  }
}
