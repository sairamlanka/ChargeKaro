import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_data/shared_data.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwt(Map<String, Object> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.signature';
}

void main() {
  group('AppConfig', () {
    test('accepts an anon key and rejects privileged keys', () {
      final anon = _jwt({'role': 'anon', 'iss': 'supabase'});
      final service = _jwt({'role': 'service_role', 'iss': 'supabase'});
      expect(AppConfig.looksPrivileged(anon), isFalse);
      expect(AppConfig.looksPrivileged(service), isTrue);
      expect(AppConfig.looksPrivileged('sb_secret_abc'), isTrue);
      expect(AppConfig.looksPrivileged('sb_publishable_abc'), isFalse);

      const base = AppConfig(supabaseUrl: 'https://x.supabase.co', supabaseKey: '', environment: 'production');
      expect(base.problems, contains('SUPABASE_ANON_KEY is not set.'));
      final bad = AppConfig(supabaseUrl: 'https://x.supabase.co', supabaseKey: service, environment: 'production');
      expect(bad.isUsable, isFalse);
      expect(bad.problems.single, contains('privileged'));
      final good = AppConfig(supabaseUrl: 'https://x.supabase.co', supabaseKey: anon, environment: 'production');
      expect(good.isUsable, isTrue);
    });

    test('production requires https', () {
      const c = AppConfig(supabaseUrl: 'http://x.supabase.co', supabaseKey: 'sb_publishable_x', environment: 'production');
      expect(c.problems, ['SUPABASE_URL must use https in production.']);
      const dev = AppConfig(supabaseUrl: 'http://127.0.0.1:54321', supabaseKey: 'sb_publishable_x', environment: 'development');
      expect(dev.isUsable, isTrue);
    });
  });

  group('AppFailure', () {
    test('maps backend PTxyz errors to kinds and plain text', () {
      final f = AppFailure.from(const PostgrestException(message: 'slot_unavailable', code: 'PT409', details: 'Slot taken'));
      expect(f.kind, FailureKind.conflict);
      expect(f.code, 'slot_unavailable');
      expect(f.message, contains('just taken'));

      final unknown = AppFailure.from(const PostgrestException(message: 'brand_new_code', code: 'PT422', details: 'Readable detail'));
      expect(unknown.kind, FailureKind.validation);
      expect(unknown.message, 'Readable detail');

      expect(AppFailure.from(const PostgrestException(message: 'x', code: '42501')).kind, FailureKind.forbidden);
      expect(AppFailure.from(const PostgrestException(message: 'x', code: '23P01')).kind, FailureKind.conflict);
      expect(AppFailure.from(const PostgrestException(message: 'x', code: 'PGRST116')).kind, FailureKind.notFound);
    });

    test('maps auth, network and unknown errors', () {
      final auth = AppFailure.from(const AuthException('Invalid login credentials', statusCode: '400', code: 'invalid_credentials'));
      expect(auth.message, 'Email or password is incorrect.');
      expect(AppFailure.from(const SocketException('down')).kind, FailureKind.network);
      expect(AppFailure.from(StateError('boom')).kind, FailureKind.unknown);
    });

    test('guard rethrows as AppFailure', () async {
      await expectLater(
        guard<void>(() async => throw const PostgrestException(message: 'forbidden', code: 'PT403')),
        throwsA(isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.forbidden)),
      );
    });
  });

  group('StoragePaths', () {
    test('follow the storage policy layout and drop user file names', () {
      final p = StoragePaths.document(businessId: 'b1', stationId: 's1', fileName: 'My Licence (final).PDF');
      expect(p, matches(RegExp(r'^b1/s1/[0-9a-f]{32}\.pdf$')));
      expect(StoragePaths.document(businessId: 'b1', fileName: 'gst.png'), matches(RegExp(r'^b1/business/[0-9a-f]{32}\.png$')));
      expect(StoragePaths.stationMedia(businessId: 'b', stationId: 's', fileName: 'noext'), matches(RegExp(r'^b/s/[0-9a-f]{32}$')));
      expect(StoragePaths.mimeFor('a.JPG'), 'image/jpeg');
      expect(StoragePaths.mimeFor('a.exe'), 'application/octet-stream');
    });
  });

  test('Repository.range and date format for PostgREST', () {
    expect(Repository.date(DateTime(2026, 3, 9)), '2026-03-09');
    expect(Repository.range(DateTime.utc(2026, 1, 1), DateTime.utc(2026, 1, 2)),
        '[2026-01-01T00:00:00.000Z,2026-01-02T00:00:00.000Z)');
  });
}
