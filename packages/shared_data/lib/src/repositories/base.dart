import 'package:supabase_flutter/supabase_flutter.dart';

import '../failure.dart';

/// Shared plumbing: every call goes through [guard] so callers only ever see
/// [AppFailure]. Authorisation is enforced by RLS and the RPCs, never here.
abstract class Repository {
  Repository(this.client);

  final SupabaseClient client;

  String get uid {
    final id = client.auth.currentUser?.id;
    if (id == null) throw const AppFailure(FailureKind.unauthenticated, 'not_authenticated', 'Please sign in to continue.');
    return id;
  }

  Future<T> rpc<T>(String fn, [Map<String, dynamic>? params]) =>
      guard(() async => await client.rpc<dynamic>(fn, params: params) as T);

  Future<List<T>> rows<T>(Future<List<Map<String, dynamic>>> query, T Function(Object?) parse) =>
      guard(() async => (await query).map(parse).toList());

  Future<T> row<T>(Future<Map<String, dynamic>> query, T Function(Object?) parse) => guard(() async => parse(await query));

  Future<T?> maybeRow<T>(Future<Map<String, dynamic>?> query, T Function(Object?) parse) => guard(() async {
        final r = await query;
        return r == null ? null : parse(r);
      });

  static String date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String range(DateTime from, DateTime to) =>
      '[${from.toUtc().toIso8601String()},${to.toUtc().toIso8601String()})';
}
