// Runs the repositories against a real PostgREST + the migrated test
// database (scripts/rest-integration.sh). Skipped when REST_URL is unset.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _env = Platform.environment;
final _url = _env['REST_URL'];

String _jwt(String sub) {
  String b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final head = '${b64({'alg': 'HS256', 'typ': 'JWT'})}.${b64({'sub': sub, 'role': 'authenticated', 'iat': now, 'exp': now + 3600})}';
  final sig = Hmac(sha256, utf8.encode(_env['REST_JWT_SECRET']!)).convert(utf8.encode(head)).bytes;
  return '$head.${base64Url.encode(sig).replaceAll('=', '')}';
}

/// The user's JWT doubles as the API key, so PostgREST sees that user.
SupabaseClient _as(String envKey) => SupabaseClient(_url!, _jwt(_env[envKey]!),
    authOptions: const AuthClientOptions(autoRefreshToken: false));

void main() {
  if (_url == null) {
    test('REST integration (skipped: run scripts/rest-integration.sh)', () {}, skip: true);
    return;
  }

  const demoBusiness = '00000000-0000-4000-b000-000000000001';
  // The seeded live (Koramangala) and draft (Indiranagar) stations; seed.sql
  // also adds route-test stations to the same business.
  const liveStation = '00000000-0000-4000-c000-000000000001';
  const draftStation = '00000000-0000-4000-c000-000000000002';

  group('business owner', () {
    final client = _as('OWNER_ID');
    final auth = AuthRepository(client);
    final stations = StationRepository(client);
    final onboarding = OnboardingRepository(client);
    final bookings = BookingRepository(client);

    test('access, stations, points, hours, policy, team', () async {
      final access = await auth.businessAccess();
      expect(access.single.businessId, demoBusiness);
      expect(access.single.isOwner, isTrue);
      expect((await auth.platformAccess()).isStaff, isFalse);

      final list = await stations.stations(demoBusiness);
      expect(list.map((s) => s.id), containsAll([liveStation, draftStation]));
      final live = list.firstWhere((s) => s.id == liveStation);

      final points = await stations.points(live.id);
      expect(points, isNotEmpty);
      expect(points.first.connectors, isNotEmpty);
      expect((await stations.hours(live.id)), isNotEmpty);
      final policy = await stations.policy(live.id);
      final updated = await stations.updatePolicy(policy.copyWith(bufferMinutes: 10));
      expect(updated.bufferMinutes, 10);

      final members = await stations.members(demoBusiness);
      expect(members.map((m) => m.email), contains('staff@demo-ev.local'));
      expect(members.firstWhere((m) => m.email == 'staff@demo-ev.local').stationIds, isNotEmpty);
    });

    test('atomic hours and connector replacement', () async {
      final live = (await stations.stations(demoBusiness)).firstWhere((s) => s.id == liveStation);
      await stations.replaceHours(live.id, [
        for (var d = 1; d <= 7; d++) OperatingHours(dayOfWeek: d, opensMinute: 360, closesMinute: 1380),
      ]);
      final hours = (await stations.hours(live.id)).where((h) => h.chargingPointId == null).toList();
      expect(hours.map((h) => h.label).toSet(), {'06:00–23:00'});

      final point = (await stations.points(live.id)).first;
      await stations.setConnectors(point.id, [
        {'connector_type': 'ccs2', 'max_power_kw': 60},
      ]);
      expect((await stations.points(live.id)).first.connectors.single.type, ConnectorType.ccs2);
    });

    test('a live station rejects a direct address change', () async {
      final live = (await stations.stations(demoBusiness)).firstWhere((s) => s.id == liveStation);
      await expectLater(
        stations.updateStation(live.id, {'address_line1': 'Somewhere else'}),
        throwsA(isA<AppFailure>().having((f) => f.code, 'code', 'sensitive_change_requires_approval')),
      );
      final id = await stations.requestChange(live.id, {'address_line1': 'Somewhere else'}, note: 'Moved entrance');
      expect(id, isNotEmpty);
      expect((await stations.changeRequests(live.id)).first.status, 'pending');
    });

    test('drafts, documents and application checklist', () async {
      final draft = await stations.createStation(demoBusiness, {
        'name': 'Integration Draft',
        'address_line1': '1 Test Road',
        'city': 'Pune',
        'district': 'Pune',
        'state': 'Maharashtra',
        'postal_code': '411001',
        'latitude': 18.5204,
        'longitude': 73.8567,
        'contact_phone': '+919800000001',
      });
      expect(draft.status, StationStatus.draft);
      final app = await onboarding.applicationForStation(draft.id);
      expect(app!.status, ApplicationStatus.draft);
      final checklist = await onboarding.checklist(app.id);
      expect(checklist.where((c) => c.isRequired), isNotEmpty);
      await expectLater(onboarding.submit(app.id), throwsA(isA<AppFailure>()));
      expect(await onboarding.documents(demoBusiness, stationId: draft.id), isNotEmpty);
      expect(await onboarding.events(app.id), isNotEmpty);
      expect(await onboarding.documentTypes(), isNotEmpty);
    });

    test('bookings with column grants, events and report', () async {
      final live = (await stations.stations(demoBusiness)).firstWhere((s) => s.id == liveStation);
      final now = DateTime.now();
      final list = await bookings.forStation(live.id, now.subtract(const Duration(days: 1)), now.add(const Duration(days: 30)));
      expect(list, isNotEmpty);
      expect(list.first.stationName, isNotNull);
      expect(list.first.chargingPointCode, isNotNull);
      expect(await bookings.events(list.first.id), isNotEmpty);
      final report = await stations.report(demoBusiness, now.subtract(const Duration(days: 30)), now.add(const Duration(days: 30)));
      expect(report.raw.containsKey('totals'), isTrue);
    });

    test('cannot read platform finance', () async {
      await expectLater(FinanceRepository(client).summary(DateTime(2026), DateTime(2026, 12, 31)),
          throwsA(isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.forbidden)));
    });
  });

  group('station staff', () {
    final client = _as('STAFF_ID');

    test('looks up a booking by reference only at an assigned station', () async {
      final access = (await AuthRepository(client).businessAccess()).single;
      expect(access.isOwner, isFalse);
      final stationId = access.stationIds.single;
      final owner = BookingRepository(_as('OWNER_ID'));
      final now = DateTime.now();
      final b = (await owner.forStation(stationId, now.subtract(const Duration(days: 1)), now.add(const Duration(days: 30)))).first;
      final found = await BookingRepository(client).lookupForCheckIn(stationId, b.reference.toLowerCase());
      expect(found.id, b.id);
      await expectLater(BookingRepository(client).lookupForCheckIn(stationId, 'CK0000000000'),
          throwsA(isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.notFound)));
    });
  });

  group('platform admin', () {
    final client = _as('ADMIN_ID');
    final admin = AdminRepository(client);
    final onboarding = OnboardingRepository(client);
    final finance = FinanceRepository(client);

    test('dashboard, queue, businesses, stations, staff, settings, audit', () async {
      expect((await AuthRepository(client).platformAccess()).role, PlatformRole.superAdmin);
      final now = DateTime.now();
      final dash = await admin.dashboard(from: now.subtract(const Duration(days: 30)), to: now);
      expect(dash.raw, isNotEmpty);
      final queue = await onboarding.queue(statuses: {ApplicationStatus.submitted});
      expect(queue.single.businessName, contains('[DEMO]'));
      expect(await onboarding.checklist(queue.single.id), isNotEmpty);
      expect(await admin.businesses(search: 'green'), isNotEmpty);
      expect(await admin.stations(state: 'Karnataka'), isNotEmpty);
      final staff = await admin.staff();
      expect(staff.map((s) => s.email), containsAll(['admin@chargekaro.local', 'ops@chargekaro.local']));
      expect(staff.firstWhere((s) => s.email == 'ops@chargekaro.local').overrides, isNotEmpty);
      expect(await admin.permissions(), hasLength(21));
      expect((await admin.settings()).map((s) => s['key']), contains('booking_fee_paise'));
      expect(await admin.audit(limit: 5), isNotEmpty);
      expect(await onboarding.pendingChangeRequests(), isA<List<Map<String, dynamic>>>());
      expect(await BookingRepository(client).search(reference: 'ck'), isNotEmpty);
    });

    test('finance: summary is internally consistent; lists load', () async {
      final now = DateTime.now();
      final s = await finance.summary(now.subtract(const Duration(days: 365)), now);
      expect(s.isConsistent, isTrue);
      expect(await finance.timeseries(now.subtract(const Duration(days: 30)), now, bucket: 'week'), isA<List<FinancialPoint>>());
      expect(await finance.payments(), isA<List<PaymentRecord>>());
      expect(await finance.refunds(), isA<List<RefundRecord>>());
      expect(await finance.categories(), isNotEmpty);
      final id = await finance.recordExpense(
          categoryId: (await finance.categories()).first.id, description: 'Integration test hosting', amount: const Money(150000), date: now);
      expect((await finance.expenses(status: ExpenseStatus.submitted)).map((e) => e.id), contains(id));
      await expectLater(finance.decideExpense(id, approve: true),
          completes, reason: 'super admin may approve their own expense');
    });
  });

  group('compliance reviewer', () {
    test('sees the queue but not finance', () async {
      final client = _as('REVIEWER_ID');
      expect(await OnboardingRepository(client).queue(), isNotEmpty);
      await expectLater(FinanceRepository(client).payments(), completion(isEmpty));
    });
  });
}
