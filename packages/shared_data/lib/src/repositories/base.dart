import 'package:logging/logging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../failure.dart';

/// Shared plumbing: every call goes through [guard] so callers only ever see
/// [AppFailure]. Authorisation is enforced by RLS and the RPCs, never here.
abstract class Repository {
  Repository(this.client);

  final SupabaseClient client;

  /// One logger per repository class, named after it, like a Spring Boot
  /// class logger.
  late final Logger log = Logger('$runtimeType');

  String get uid {
    final id = client.auth.currentUser?.id;
    if (id == null) throw const AppFailure(FailureKind.unauthenticated, 'not_authenticated', 'Please sign in to continue.');
    return id;
  }

  Future<T> rpc<T>(String fn, [Map<String, dynamic>? params]) =>
      logged('rpc $fn', () async => await client.rpc<dynamic>(fn, params: params) as T, params: params);

  Future<List<T>> rows<T>(Future<List<Map<String, dynamic>>> query, T Function(Object?) parse) =>
      logged('select', () async => (await query).map(parse).toList());

  Future<T> row<T>(Future<Map<String, dynamic>> query, T Function(Object?) parse) => logged('select', () async => parse(await query));

  Future<T?> maybeRow<T>(Future<Map<String, dynamic>?> query, T Function(Object?) parse) => logged('select', () async {
        final r = await query;
        return r == null ? null : parse(r);
      });

  /// Like [guard], with timing: DEBUG on success with a short summary of the
  /// result, WARN or ERROR on failure (see [logFailure]). [params] are logged
  /// at DEBUG with personal and secret values masked.
  Future<T> logged<T>(String what, Future<T> Function() body, {Map<String, dynamic>? params}) async {
    if (params != null && log.isLoggable(Level.FINE)) log.fine('$what ${redact(params)}');
    final watch = Stopwatch()..start();
    try {
      final result = await body();
      log.fine('$what ok in ${watch.elapsedMilliseconds} ms${summarize(result)}');
      return result;
    } catch (e, stack) {
      final failure = AppFailure.from(e);
      logFailure(log, '$what after ${watch.elapsedMilliseconds} ms', failure, e, stack);
      throw failure;
    }
  }

  static final _sensitive = RegExp('phone|email|token|password|secret|otp|signature|code', caseSensitive: false);

  /// [params] with personal and secret values replaced, for logs.
  static Map<String, dynamic> redact(Map<String, dynamic> params) =>
      {for (final e in params.entries) e.key: _sensitive.hasMatch(e.key) && e.value != null ? '***' : e.value};

  /// A few words about a result for a log line: row counts, not contents.
  static String summarize(Object? result) => switch (result) {
        null => '',
        List<Object?>() => ' (${result.length} rows)',
        Map<String, dynamic>() => () {
            final lists = [for (final e in result.entries) if (e.value is List) '${e.key}: ${(e.value as List).length}'];
            return lists.isEmpty ? '' : ' (${lists.join(', ')})';
          }(),
        _ => '',
      };

  static String date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String range(DateTime from, DateTime to) =>
      '[${from.toUtc().toIso8601String()},${to.toUtc().toIso8601String()})';
}
