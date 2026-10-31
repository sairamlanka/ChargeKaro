import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:shared_data/shared_data.dart';

/// Every way asking for the device location can end. The UI shows a
/// specific screen for each, and always offers area search instead.
sealed class LocationOutcome {
  const LocationOutcome();
}

class LocationFound extends LocationOutcome {
  const LocationFound(this.latitude, this.longitude, {required this.accuracyMeters, required this.timestamp, this.lastKnown = false});
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime timestamp;

  /// True when only a cached (possibly old) fix was available.
  final bool lastKnown;

  bool get isApproximate => accuracyMeters > 500;
  bool isStale(DateTime now) => now.difference(timestamp) > const Duration(minutes: 10);
}

enum LocationProblem { servicesOff, denied, deniedForever, unavailable, timeout }

class LocationFailed extends LocationOutcome {
  const LocationFailed(this.problem);
  final LocationProblem problem;
}

/// Thin seam over geolocator so screens can be tested with a fake.
abstract class LocationService {
  Future<LocationOutcome> current();
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
}

class DeviceLocationService implements LocationService {
  const DeviceLocationService();

  static final _log = Logger('DeviceLocationService');

  @override
  Future<LocationOutcome> current() async {
    final outcome = await _current();
    switch (outcome) {
      case LocationFound(:final latitude, :final longitude, :final accuracyMeters, :final lastKnown):
        _log.fine('Location ${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)} '
            '(±${accuracyMeters.round()} m${lastKnown ? ', last known fix' : ''})');
      case LocationFailed(:final problem):
        _log.warning('Location unavailable: ${problem.name}');
    }
    return outcome;
  }

  Future<LocationOutcome> _current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return const LocationFailed(LocationProblem.servicesOff);
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever) return const LocationFailed(LocationProblem.deniedForever);
      if (permission == LocationPermission.denied || permission == LocationPermission.unableToDetermine) {
        return const LocationFailed(LocationProblem.denied);
      }
      try {
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)),
        );
        return LocationFound(p.latitude, p.longitude, accuracyMeters: p.accuracy, timestamp: p.timestamp);
      } on TimeoutException {
        // Indoors or no GPS: fall back to the last known fix, clearly marked.
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return LocationFound(last.latitude, last.longitude, accuracyMeters: last.accuracy, timestamp: last.timestamp, lastKnown: true);
        return const LocationFailed(LocationProblem.timeout);
      }
    } on LocationServiceDisabledException {
      return const LocationFailed(LocationProblem.servicesOff);
    } on PermissionDeniedException {
      return const LocationFailed(LocationProblem.denied);
    } catch (e, stack) {
      _log.severe('Location lookup failed', e, stack);
      return const LocationFailed(LocationProblem.unavailable);
    }
  }

  @override
  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
}
