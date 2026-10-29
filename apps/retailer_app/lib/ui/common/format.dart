import 'package:intl/intl.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../l10n/l10n.dart';

/// Locale-aware formatting for the Retail App. Every station is in India, so
/// times are shown in IST (UTC+05:30) whatever the device zone, and labelled.
class RFmt {
  RFmt(this.l);
  final L l;

  String get _loc => l.code == 'te' ? 'te' : 'en_IN';

  DateTime ist(DateTime t) => Fmt.toIst(t);

  String time(DateTime t) => DateFormat('h:mm a', _loc).format(ist(t));
  String day(DateTime t) => DateFormat('EEE, d MMM', _loc).format(ist(t));
  String dayLong(DateTime t) => DateFormat('EEEE, d MMMM yyyy', _loc).format(ist(t));
  String dateTime(DateTime t) => '${day(t)}, ${time(t)}';
  String slot(DateTime start, DateTime end) => '${day(start)} · ${time(start)} – ${time(end)}';
  String timeRange(DateTime start, DateTime end) => '${time(start)} – ${time(end)}';

  /// A calendar date (already a local IST date, no zone conversion).
  String calendarDay(DateTime d) => DateFormat('EEE d', _loc).format(d);
  String monthDay(DateTime d) => DateFormat('d MMM', _loc).format(d);
  String weekdayShort(DateTime d) => DateFormat('EEE', _loc).format(d);

  /// "Today", "Tomorrow" or the weekday, for a local IST date.
  String relativeDay(DateTime localDate, DateTime now) {
    final today = istDate(now);
    final diff = DateTime.utc(localDate.year, localDate.month, localDate.day).difference(today).inDays;
    if (diff == 0) return l(K.today);
    if (diff == 1) return l(K.tomorrow);
    return weekdayShort(localDate);
  }

  /// When a slot starts, relative to now: "Today 4:30 PM", "Tomorrow 9:00 AM".
  String whenStarts(DateTime t, DateTime now) {
    final d = istDate(t);
    return '${relativeDay(d, now)} ${time(t)}';
  }

  String minutesOfDay(int minutes) {
    final m = minutes % 1440;
    final dt = DateTime.utc(2000, 1, 1, m ~/ 60, m % 60);
    if (minutes == 1440) return l(K.midnight);
    return DateFormat('h:mm a', _loc).format(dt);
  }

  String duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h == 0) return l(K.durationMinutes, {'m': m});
    if (m == 0) return l(K.durationHours, {'h': h});
    return l(K.durationHoursMinutes, {'h': h, 'm': m});
  }

  String distance(double km) => km < 1 ? l(K.distanceMeters, {'m': (km * 1000).round()}) : l(K.distanceKm, {'km': km.toStringAsFixed(km < 10 ? 1 : 0)});

  String power(double kw) => '${kw == kw.roundToDouble() ? kw.toStringAsFixed(0) : kw.toStringAsFixed(1)} kW';

  String money(Money m) => m.format();

  String ago(DateTime t, DateTime now) {
    final d = now.difference(t);
    if (d.inMinutes < 1) return l(K.justNow);
    if (d.inMinutes < 60) return l(K.minutesAgo, {'m': d.inMinutes});
    if (d.inHours < 24) return l(K.hoursAgo, {'h': d.inHours});
    return l(K.daysAgo, {'d': d.inDays});
  }

  String countdown(Duration d) {
    if (d.isNegative) return '0:00';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static DateTime istDate(DateTime t) {
    final i = Fmt.toIst(t);
    return DateTime.utc(i.year, i.month, i.day);
  }
}

String connectorLabel(ConnectorType c) => c.label;
