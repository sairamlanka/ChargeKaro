import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/l10n.dart';
import '../ui/common/format.dart';
import 'models.dart';

/// One reminder the phone should show at [at].
@immutable
class PlannedReminder {
  const PlannedReminder({required this.id, required this.at, required this.title, required this.body, required this.bookingId});
  final int id;
  final DateTime at;
  final String title;
  final String body;
  final String bookingId;

  @override
  String toString() => 'PlannedReminder($id, $at, $title)';
}

/// The three reminders for each upcoming confirmed booking: 30 minutes
/// before the slot, when check-in opens, and 5 minutes before the late
/// window closes. Pure, so it can be tested without a phone.
List<PlannedReminder> planReminders(List<CustomerBooking> bookings, L l, DateTime now) {
  final f = RFmt(l);
  final out = <PlannedReminder>[];
  for (final b in bookings) {
    if (b.phaseAt(now) != CustomerPhase.confirmed) continue;
    final opens = b.checkinOpensAt ?? b.startAt.subtract(Duration(minutes: b.policy.earlyCheckinMinutes));
    final closes = b.checkinClosesAt ?? b.startAt.add(Duration(minutes: b.policy.arrivalGraceMinutes));
    void add(String kind, DateTime at, String title, String body) {
      if (!at.isAfter(now)) return;
      out.add(PlannedReminder(id: _id('${b.id}:$kind'), at: at, title: title, body: body, bookingId: b.id));
    }

    final before = b.startAt.subtract(const Duration(minutes: 30));
    add('before30', before, l(K.remindSoonTitle), l(K.remindSoonBody, {'station': b.stationName, 'time': f.time(b.startAt), 'closes': f.time(closes)}));
    // Skip "check-in open" when it would arrive within 10 minutes of the
    // 30-minute reminder: one buzz is enough.
    if ((opens.difference(before)).inMinutes.abs() > 10) {
      add('checkin', opens, l(K.remindCheckinTitle), l(K.remindCheckinBody, {'station': b.stationName}));
    }
    add('closing', closes.subtract(const Duration(minutes: 5)), l(K.remindClosingTitle),
        l(K.remindClosingBody, {'station': b.stationName, 'time': f.time(closes)}));
  }
  return out;
}

/// Stable positive 31-bit id from a string (FNV-1a), so a booking's
/// reminders keep the same ids across app runs.
int _id(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

/// Shows the planned reminders on the phone. Tests and web use [ReminderScheduler.none].
abstract class ReminderScheduler {
  const ReminderScheduler();
  static const ReminderScheduler none = _NoReminders();

  /// Replaces every scheduled booking reminder with [reminders].
  Future<void> replaceAll(List<PlannedReminder> reminders);
}

class _NoReminders extends ReminderScheduler {
  const _NoReminders();
  @override
  Future<void> replaceAll(List<PlannedReminder> reminders) async {}
}

/// Local notifications scheduled on the device. Works without Firebase or a
/// network connection once scheduled; Android may deliver a few minutes late
/// in battery saver (inexact alarms need no extra permission).
class LocalReminderScheduler extends ReminderScheduler {
  LocalReminderScheduler._(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;
  bool _asked = false;

  /// Route of the booking whose reminder was tapped; the app opens it.
  static final tapped = ValueNotifier<String?>(null);

  static const _channel = AndroidNotificationDetails(
    'booking_reminders',
    'Booking reminders',
    channelDescription: 'Before your slot, when check-in opens and before it closes',
    importance: Importance.high,
    priority: Priority.high,
  );

  static Future<ReminderScheduler> create() async {
    if (kIsWeb || !(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
      return ReminderScheduler.none;
    }
    try {
      tzdata.initializeTimeZones();
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
        ),
        onDidReceiveNotificationResponse: (r) => tapped.value = r.payload,
      );
      final launch = await plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) tapped.value = launch!.notificationResponse?.payload;
      return LocalReminderScheduler._(plugin);
    } catch (_) {
      return ReminderScheduler.none;
    }
  }

  Future<void> _askOnce() async {
    if (_asked) return;
    _asked = true;
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, sound: true);
  }

  @override
  Future<void> replaceAll(List<PlannedReminder> reminders) async {
    try {
      await _plugin.cancelAllPendingNotifications();
      if (reminders.isEmpty) return;
      await _askOnce();
      for (final r in reminders) {
        await _plugin.zonedSchedule(
          id: r.id,
          title: r.title,
          body: r.body,
          payload: '/booking/${r.bookingId}',
          scheduledDate: tz.TZDateTime.from(r.at, tz.UTC),
          notificationDetails: const NotificationDetails(android: _channel, iOS: DarwinNotificationDetails()),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    } catch (_) {
      // Reminders are a convenience; never break the app over them.
    }
  }
}
