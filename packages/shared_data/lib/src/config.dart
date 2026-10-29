import 'dart:convert';

import 'package:meta/meta.dart';

/// Runtime configuration, supplied at build time with --dart-define (or
/// `--dart-define-from-file=env/<flavour>.json`). Only public client values
/// belong here: the Supabase URL and publishable (anon) key. Never the
/// service-role key, Razorpay secrets or FCM credentials.
@immutable
class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabaseKey,
    required this.environment,
    this.authRedirectUrl,
  });

  factory AppConfig.fromEnvironment() => const AppConfig(
        supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
        supabaseKey: String.fromEnvironment('SUPABASE_ANON_KEY'),
        environment: String.fromEnvironment('APP_ENV', defaultValue: 'development'),
        authRedirectUrl: bool.hasEnvironment('AUTH_REDIRECT_URL') ? String.fromEnvironment('AUTH_REDIRECT_URL') : null,
      );

  final String supabaseUrl;
  final String supabaseKey;
  final String environment;
  final String? authRedirectUrl;

  bool get isProduction => environment == 'production';

  /// Problems that stop the app from talking to the backend. An empty list
  /// means the configuration is usable.
  List<String> get problems {
    final out = <String>[];
    final uri = Uri.tryParse(supabaseUrl);
    if (supabaseUrl.isEmpty) {
      out.add('SUPABASE_URL is not set.');
    } else if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      out.add('SUPABASE_URL is not a valid URL.');
    } else if (isProduction && uri.scheme != 'https') {
      out.add('SUPABASE_URL must use https in production.');
    }
    if (supabaseKey.isEmpty) {
      out.add('SUPABASE_ANON_KEY is not set.');
    } else if (looksLikePlaceholder(supabaseKey)) {
      out.add('SUPABASE_ANON_KEY is still the example value. Paste the publishable (anon) key from '
          '`supabase status` (local) or Project Settings → API Keys (hosted).');
    } else if (looksPrivileged(supabaseKey)) {
      out.add('SUPABASE_ANON_KEY is a privileged key. Use the publishable (anon) key; '
          'the service-role key must never ship in an app.');
    }
    return out;
  }

  bool get isUsable => problems.isEmpty;

  /// True for values copied from the example files rather than a real key.
  static bool looksLikePlaceholder(String key) =>
      key.contains('...') || key.contains('<') || key.contains('>') || key.contains(' ') || key == 'sb_publishable_';

  /// True for a service-role JWT or a new-style secret key. Refusing these at
  /// start-up stops a mis-pasted key from being shipped to users.
  static bool looksPrivileged(String key) {
    if (key.startsWith('sb_secret_')) return true;
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(payload);
      return claims is Map && claims['role'] == 'service_role';
    } on FormatException {
      return false;
    }
  }
}
