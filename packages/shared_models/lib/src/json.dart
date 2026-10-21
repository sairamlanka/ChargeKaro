/// Small typed reader over decoded JSON maps. Throws [FormatException] with
/// the offending key instead of a vague cast error.
extension type const Json(Map<String, dynamic> map) {
  factory Json.of(Object? value) {
    if (value is Map<String, dynamic>) return Json(value);
    if (value is Map) return Json(value.cast<String, dynamic>());
    throw FormatException('Expected a JSON object, got ${value.runtimeType}');
  }

  Object? operator [](String key) => map[key];

  String str(String key) {
    final v = map[key];
    if (v is String) return v;
    throw FormatException('Expected string at "$key", got ${v.runtimeType}');
  }

  String? strOrNull(String key) {
    final v = map[key];
    return v is String ? v : v?.toString();
  }

  int integer(String key, [int? fallback]) {
    final v = map[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final parsed = int.tryParse(v);
      if (parsed != null) return parsed;
    }
    if (fallback != null) return fallback;
    throw FormatException('Expected integer at "$key", got ${v.runtimeType}');
  }

  int? intOrNull(String key) {
    final v = map[key];
    if (v == null) return null;
    return integer(key);
  }

  double number(String key, [double? fallback]) {
    final v = map[key];
    if (v is num) return v.toDouble();
    if (v is String) {
      final parsed = double.tryParse(v);
      if (parsed != null) return parsed;
    }
    if (fallback != null) return fallback;
    throw FormatException('Expected number at "$key", got ${v.runtimeType}');
  }

  bool boolean(String key, [bool fallback = false]) {
    final v = map[key];
    return v is bool ? v : fallback;
  }

  bool? boolOrNull(String key) {
    final v = map[key];
    return v is bool ? v : null;
  }

  DateTime dateTime(String key) {
    final v = dateTimeOrNull(key);
    if (v == null) throw FormatException('Expected timestamp at "$key"');
    return v;
  }

  DateTime? dateTimeOrNull(String key) {
    final v = map[key];
    if (v is String) return DateTime.tryParse(v)?.toUtc();
    if (v is DateTime) return v.toUtc();
    return null;
  }

  /// Date-only values (e.g. expires_on) parsed as a calendar date.
  DateTime? dateOrNull(String key) {
    final v = map[key];
    if (v is! String) return null;
    final d = DateTime.tryParse(v);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  List<String> strings(String key) {
    final v = map[key];
    if (v is List) return v.map((e) => e.toString()).toList(growable: false);
    return const [];
  }

  List<Json> objects(String key) {
    final v = map[key];
    if (v is List) return v.map(Json.of).toList(growable: false);
    return const [];
  }

  Json? objectOrNull(String key) {
    final v = map[key];
    return v == null ? null : Json.of(v);
  }
}
