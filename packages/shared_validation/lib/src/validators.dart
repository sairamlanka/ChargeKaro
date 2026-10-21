/// A validator returns null when the value is valid, or a user-facing message.
typedef Validator = String? Function(String? value);

abstract final class Validators {
  /// Combines validators; the first failure wins.
  static Validator all(List<Validator> validators) => (value) {
        for (final v in validators) {
          final error = v(value);
          if (error != null) return error;
        }
        return null;
      };

  static Validator required([String message = 'This field is required']) =>
      (value) => (value == null || value.trim().isEmpty) ? message : null;

  static Validator optional(Validator validator) =>
      (value) => (value == null || value.trim().isEmpty) ? null : validator(value);

  static Validator length({int min = 0, required int max, String? field}) => (value) {
        final n = value?.trim().length ?? 0;
        final name = field ?? 'This field';
        if (n < min) return '$name must be at least $min characters';
        if (n > max) return '$name must be at most $max characters';
        return null;
      };

  /// Normalises Indian mobile numbers to E.164 (+91XXXXXXXXXX). Accepts
  /// "98765 43210", "098765-43210", "+91 98765 43210" and other E.164 numbers.
  static String? normalizePhone(String? input) {
    if (input == null) return null;
    var digits = input.replaceAll(RegExp(r'[\s\-().]'), '');
    if (digits.startsWith('+')) {
      return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(digits) ? digits : null;
    }
    if (digits.startsWith('0')) digits = digits.substring(1);
    if (digits.length == 12 && digits.startsWith('91')) digits = digits.substring(2);
    if (RegExp(r'^[6-9]\d{9}$').hasMatch(digits)) return '+91$digits';
    return null;
  }

  static String? phone(String? value) =>
      normalizePhone(value) == null ? 'Enter a valid mobile number, e.g. +91 98765 43210' : null;

  static String? email(String? value) {
    final v = value?.trim() ?? '';
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v) ? null : 'Enter a valid email address';
  }

  /// Indian PIN code: six digits, not starting with 0.
  static String? pinCode(String? value) =>
      RegExp(r'^[1-9]\d{5}$').hasMatch(value?.trim() ?? '') ? null : 'Enter a valid 6-digit PIN code';

  /// GSTIN format and checksum (mod-36 Luhn variant used by GSTN).
  static String? gstin(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    if (!RegExp(r'^\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]$').hasMatch(v)) {
      return 'Enter a valid 15-character GSTIN';
    }
    return gstinChecksumValid(v) ? null : 'GSTIN check digit does not match';
  }

  static bool gstinChecksumValid(String gstin) {
    const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    var sum = 0;
    for (var i = 0; i < 14; i++) {
      final value = chars.indexOf(gstin[i]);
      final product = value * (i.isEven ? 1 : 2);
      sum += product ~/ 36 + product % 36;
    }
    final check = (36 - sum % 36) % 36;
    return gstin[14] == chars[check];
  }

  /// Password policy matching Supabase Auth config: ≥10 chars, upper, lower, digit.
  static String? password(String? value) {
    final v = value ?? '';
    if (v.length < 10) return 'Use at least 10 characters';
    if (!RegExp('[a-z]').hasMatch(v) || !RegExp('[A-Z]').hasMatch(v) || !RegExp(r'\d').hasMatch(v)) {
      return 'Use upper and lower case letters and a number';
    }
    return null;
  }

  static Validator matches(String Function() other, [String message = 'Values do not match']) =>
      (value) => value == other() ? null : message;

  static Validator intRange(int min, int max, {String? field}) => (value) {
        final n = int.tryParse(value?.trim() ?? '');
        if (n == null) return 'Enter a whole number';
        if (n < min || n > max) return '${field ?? 'Value'} must be between $min and $max';
        return null;
      };

  static Validator decimalRange(double min, double max, {String? field}) => (value) {
        final n = double.tryParse(value?.trim() ?? '');
        if (n == null) return 'Enter a number';
        if (n <= min || n > max) return '${field ?? 'Value'} must be more than $min and at most $max';
        return null;
      };

  /// Charging-point identifier, e.g. "DC-1" (mirrors charging_points.code check).
  static String? pointCode(String? value) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$').hasMatch(value?.trim() ?? '')
      ? null
      : 'Use letters, numbers, "-" or "_" (max 32)';

  /// Rejection and override reasons must be meaningful (server requires ≥5).
  static String? reason(String? value) =>
      (value?.trim().length ?? 0) >= 5 ? null : 'Please give a reason (at least 5 characters)';
}

/// Coordinate plausibility. A pin is not proof of address; this only catches
/// obvious mistakes such as swapped lat/lng or a default (0, 0).
abstract final class Coordinates {
  static const indiaLatMin = 6.0;
  static const indiaLatMax = 37.6;
  static const indiaLngMin = 68.0;
  static const indiaLngMax = 97.5;

  static String? validate(double? lat, double? lng, {String countryCode = 'IN'}) {
    if (lat == null || lng == null) return 'Select the station location on the map';
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return 'Coordinates are out of range';
    if (lat == 0 && lng == 0) return 'Select the station location on the map';
    if (countryCode == 'IN' &&
        (lat < indiaLatMin || lat > indiaLatMax || lng < indiaLngMin || lng > indiaLngMax)) {
      return (lng >= indiaLatMin && lng <= indiaLatMax && lat >= indiaLngMin && lat <= indiaLngMax)
          ? 'Latitude and longitude look swapped'
          : 'This location is outside India';
    }
    return null;
  }

  /// Rounds to the 6 decimals the database stores (~0.1 m).
  static double round6(double v) => (v * 1e6).roundToDouble() / 1e6;
}

/// Upload checks mirroring document_types and storage bucket limits.
abstract final class FileRules {
  static const documentMimeTypes = {'application/pdf', 'image/jpeg', 'image/png', 'image/webp'};
  static const imageMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};

  static String? mimeTypeForName(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => null,
    };
  }

  static String? validate({
    required String fileName,
    required int sizeBytes,
    required Iterable<String> allowedMimeTypes,
    required int maxSizeBytes,
  }) {
    final mime = mimeTypeForName(fileName);
    if (mime == null || !allowedMimeTypes.contains(mime)) {
      final allowed = allowedMimeTypes.map((m) => m.split('/').last.toUpperCase()).join(', ');
      return 'Unsupported file type. Allowed: $allowed';
    }
    if (sizeBytes <= 0) return 'The file is empty';
    if (sizeBytes > maxSizeBytes) return 'File is larger than ${(maxSizeBytes / 1048576).toStringAsFixed(0)} MB';
    return null;
  }
}
