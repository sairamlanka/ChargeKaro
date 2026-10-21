import 'dart:math';

/// Object paths the storage policies accept (migration 900):
///   station-documents/{business}/{station|business}/{random}.{ext}
///   station-media/{business}/{station}/{random}.{ext}
///   maintenance-photos/{business}/{station}/{random}.{ext}
///   expense-receipts/{year}/{random}.{ext}
abstract final class StoragePaths {
  static const documentsBucket = 'station-documents';
  static const mediaBucket = 'station-media';
  static const maintenanceBucket = 'maintenance-photos';
  static const receiptsBucket = 'expense-receipts';

  static String document({required String businessId, String? stationId, required String fileName}) =>
      '$businessId/${stationId ?? 'business'}/${_random()}${_ext(fileName)}';

  static String stationMedia({required String businessId, required String stationId, required String fileName}) =>
      '$businessId/$stationId/${_random()}${_ext(fileName)}';

  static String maintenancePhoto({required String businessId, required String stationId, required String fileName}) =>
      '$businessId/$stationId/${_random()}${_ext(fileName)}';

  static String receipt({required DateTime date, required String fileName}) =>
      '${date.year}/${_random()}${_ext(fileName)}';

  /// The user's own file name is never part of the object path.
  static String _ext(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    final ext = fileName.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? '.$ext' : '';
  }

  static final _rng = Random.secure();
  static String _random() => List.generate(16, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  static String mimeFor(String fileName) => switch (_ext(fileName)) {
        '.pdf' => 'application/pdf',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.heic' => 'image/heic',
        _ => 'application/octet-stream',
      };
}
