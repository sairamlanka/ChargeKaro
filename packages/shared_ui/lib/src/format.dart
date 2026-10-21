import 'package:intl/intl.dart';
import 'package:shared_models/shared_models.dart';

/// Display formatting. Every station is in India, which has a single fixed
/// offset (IST, UTC+05:30, no daylight saving), so times are shown in IST
/// regardless of the device's zone. Stored values are always UTC.
abstract final class Fmt {
  static const istOffset = Duration(hours: 5, minutes: 30);

  static DateTime toIst(DateTime t) => t.toUtc().add(istOffset);

  /// Interprets wall-clock fields as IST and returns the UTC instant.
  static DateTime fromIst(int year, int month, int day, [int hour = 0, int minute = 0]) =>
      DateTime.utc(year, month, day, hour, minute).subtract(istOffset);

  static String date(DateTime t) => DateFormat('d MMM yyyy').format(toIst(t));
  static String dateOnly(DateTime d) => DateFormat('d MMM yyyy').format(d);
  static String time(DateTime t) => DateFormat('h:mm a').format(toIst(t));
  static String dateTime(DateTime t) => DateFormat('d MMM yyyy, h:mm a').format(toIst(t));
  static String weekday(DateTime t) => DateFormat('EEE d MMM').format(toIst(t));
  static String slot(DateTime start, DateTime end) => '${weekday(start)}, ${time(start)}–${time(end)}';

  static String money(Money m) => m.format();

  static String relative(DateTime t, {DateTime? now}) {
    final d = (now ?? DateTime.now()).difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return date(t);
  }

  static String fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String percent(double v) => '${(v * 100).toStringAsFixed(0)}%';
}
