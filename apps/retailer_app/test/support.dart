import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:retailer_app/data/checkout/checkout.dart';
import 'package:retailer_app/data/local_store.dart';
import 'package:retailer_app/data/location_service.dart';
import 'package:retailer_app/data/models.dart';
import 'package:retailer_app/data/retail_repository.dart';
import 'package:retailer_app/l10n/l10n.dart';
import 'package:retailer_app/state/providers.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

class MockRepo extends Mock implements RetailRepository {}

class FakeLocation implements LocationService {
  FakeLocation(this.outcome);
  LocationOutcome outcome;
  @override
  Future<LocationOutcome> current() async => outcome;
  @override
  Future<bool> openAppSettings() async => true;
  @override
  Future<bool> openLocationSettings() async => true;
}

class FakeCheckout extends PaymentCheckout {
  FakeCheckout(this.result);
  CheckoutResult result;
  int opened = 0;
  @override
  Future<CheckoutResult> open(CheckoutRequest request) async {
    opened++;
    return result;
  }
}

/// A guest by default; set [userId] for a signed-in customer.
MockRepo mockRepo({String? userId, String? phone}) {
  final r = MockRepo();
  when(() => r.userId).thenReturn(userId);
  when(() => r.signedIn).thenReturn(userId != null);
  when(() => r.sessionPhone).thenReturn(phone);
  when(() => r.authChanges).thenAnswer((_) => const Stream<AuthState>.empty());
  when(() => r.terms()).thenAnswer((_) async => BookingTerms.fromJson(termsJson));
  return r;
}

final termsJson = {
  'booking_fee_paise': 1200,
  'payment_hold_minutes': 10,
  'terms_version': '2026-10-22',
  'refund_policy': {
    'customer_cancellation_refundable': true,
    'customer_cancellation_cutoff_minutes': 60,
    'business_cancellation_refundable': true,
    'late_payment_slot_lost_refundable': true,
    'policy_confirmed': false,
  },
};

DateTime istDay(DateTime now) => DateTime.utc(now.toUtc().add(const Duration(hours: 5, minutes: 30)).year,
    now.toUtc().add(const Duration(hours: 5, minutes: 30)).month, now.toUtc().add(const Duration(hours: 5, minutes: 30)).day);

Map<String, Object?> stationJson({String id = 'st1', bool bookable = true}) => {
      'id': id,
      'public': true,
      'name': 'Banjara EV Hub',
      'address_line1': 'Road No. 12',
      'city': 'Hyderabad',
      'state': 'Telangana',
      'postal_code': '500034',
      'latitude': 17.41,
      'longitude': 78.44,
      'distance_km': 1.2,
      'status': 'active',
      'bookable': bookable,
      'unavailable_reason': bookable ? null : 'temporarily_closed',
      'points': {'total': 2, 'available': 1, 'in_use': 1, 'unavailable': 0},
      'connector_types': ['ccs2'],
      'max_power_kw': 60,
      'hours': [for (var d = 1; d <= 7; d++) {'day': d, 'opens': 0, 'closes': 1440}],
      'open': {'open_now': true},
      'booking_fee_paise': 1200,
      'points_detail': [
        {
          'id': 'p1',
          'code': 'A1',
          'current_type': 'dc',
          'max_power_kw': 60,
          'operational_status': 'available',
          'bookable': true,
          'max_booking_minutes': 120,
          'connectors': [
            {'number': 1, 'type': 'ccs2', 'max_power_kw': 60},
          ],
        },
      ],
      'policy': {'slot_duration_minutes': 30, 'min_booking_minutes': 30, 'max_booking_minutes': 120, 'max_advance_days': 7},
      'refund_policy': termsJson['refund_policy'],
      'payment_hold_minutes': 10,
    };

/// A grid with cells every [slot] minutes from [from]. [states] is one
/// point's states in order; [points] gives several points (codes P1, P2...),
/// each with its own connector from [connectors].
Map<String, Object?> gridJson(
  DateTime from,
  List<String> states, {
  String stationId = 'st1',
  List<List<String>>? points,
  List<String>? connectors,
  int slot = 30,
}) {
  final base = (stationJson()['points_detail'] as List).first as Map<String, Object?>;
  final all = points ?? [states];
  return {
    'station_id': stationId,
    'date': '${from.year}-${from.month.toString().padLeft(2, '0')}-${from.day.toString().padLeft(2, '0')}',
    'slot_minutes': slot,
    'min_booking_minutes': 30,
    'buffer_minutes': 0,
    'booking_fee_paise': 1200,
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'points': [
      for (final (n, ps) in all.indexed)
        {
          ...base,
          if (points != null) 'id': 'p${n + 1}',
          if (points != null) 'code': 'P${n + 1}',
          if (connectors != null) 'connectors': [{'number': 1, 'type': connectors[n], 'max_power_kw': 60}],
          'cells': [
            for (final (i, s) in ps.indexed)
              {
                'start_at': from.add(Duration(minutes: slot * i)).toIso8601String(),
                'end_at': from.add(Duration(minutes: slot * (i + 1))).toIso8601String(),
                'state': s,
                'can_start': s == 'available',
              },
          ],
        },
    ],
  };
}

Map<String, Object?> bookingJson({
  String id = 'b1',
  String status = 'confirmed',
  String paymentStatus = 'paid',
  DateTime? start,
  DateTime? holdExpiresAt,
  Map<String, Object?>? payment,
  List<Map<String, Object?>> refunds = const [],
  String? cancellationActor,
}) {
  final s = start ?? DateTime.now().toUtc().add(const Duration(hours: 3));
  return {
    'id': id,
    'reference': 'CK7M2X9KQ4P1',
    'station_id': 'st1',
    'start_at': s.toIso8601String(),
    'end_at': s.add(const Duration(hours: 1)).toIso8601String(),
    'status': status,
    'payment_status': paymentStatus,
    'booking_fee_paise': 1200,
    'hold_expires_at': holdExpiresAt?.toIso8601String(),
    'cancellation_actor': cancellationActor,
    'station': {'name': 'Banjara EV Hub', 'address_line1': 'Road No. 12', 'city': 'Hyderabad', 'latitude': 17.41, 'longitude': 78.44, 'status': 'active'},
    'point': {'code': 'A1', 'max_power_kw': 60, 'connectors': ['ccs2']},
    'policy': {'early_checkin_minutes': 15, 'arrival_grace_minutes': 5, 'report_before_minutes': 5},
    'payment': payment,
    'refunds': refunds,
    'messages': [],
    'events': [],
  };
}

/// Wraps [child] (or a router) with the app's localisation and theme, and
/// with animations disabled so decorative loops settle.
Widget harness({
  required List overrides,
  required LocalStore store,
  Widget? child,
  GoRouter? router,
  Locale locale = const Locale('en'),
  bool mockPayments = false,
}) {
  Widget wrap(BuildContext context, Widget? c) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: c!);
  const delegates = <LocalizationsDelegate<dynamic>>[L.delegate, GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate];
  return ProviderScope(
    retry: (_, _) => null,
    overrides: [localStoreProvider.overrideWithValue(store), mockPaymentsProvider.overrideWithValue(mockPayments), ...overrides.cast()],
    child: router != null
        ? MaterialApp.router(routerConfig: router, theme: AppTheme.light(), locale: locale, supportedLocales: L.supported, localizationsDelegates: delegates, builder: wrap)
        : MaterialApp(home: child, theme: AppTheme.light(), locale: locale, supportedLocales: L.supported, localizationsDelegates: delegates, builder: wrap),
  );
}

Future<void> settle(WidgetTester t, [Duration d = const Duration(milliseconds: 100), int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(d);
  }
}


Future<void> tapVisible(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
}

/// A common phone viewport (360 x 780 dp).
void usePhone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}
