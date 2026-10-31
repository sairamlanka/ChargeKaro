import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'config.dart';

/// Spring Boot style application logs for the ChargeKaro apps: one logger
/// per class (`Logger('RetailRepository')`), levels TRACE, DEBUG, INFO, WARN
/// and ERROR, and one line per event:
///
///     2026-10-30 14:09:12.345  INFO [RetailRepository] rpc search_stations ok in 230 ms (stations: 0)
///
/// The root level comes from `LOG_LEVEL` in the env file or --dart-define
/// (TRACE, DEBUG, INFO, WARN, ERROR or OFF). Without it, development builds
/// log DEBUG and production builds INFO. Lines go to the `flutter run`
/// console, to logcat (tag `flutter`) on Android and to the browser console
/// on web. Never log secrets, tokens, OTPs or full phone numbers.
abstract final class AppLogging {
  static bool _started = false;

  /// Sets the level, prints every record and logs uncaught errors. Call once,
  /// before Supabase.initialize (pass `debug: false` there so Supabase's own
  /// records come through here instead of its separate printer).
  static void start(AppConfig config, {required String app}) {
    if (_started) return;
    _started = true;
    const name = String.fromEnvironment('LOG_LEVEL');
    final level = levelFromName(name) ?? (config.isProduction ? Level.INFO : Level.FINE);
    Logger.root.level = level;
    Logger.root.onRecord.listen(_print);

    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      Logger('FlutterError').severe(details.exceptionAsString(), details.exception, details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      Logger('Uncaught').severe('Uncaught error', error, stack);
      return false; // keep the default handling as well
    };

    Logger('App').info('Starting $app (${config.environment}) against ${Uri.tryParse(config.supabaseUrl)?.host}, '
        'log level ${labelOf(level)}');
  }

  /// TRACE, DEBUG, INFO, WARN, ERROR or OFF (any case) to a logging level.
  static Level? levelFromName(String name) => switch (name.trim().toUpperCase()) {
        'TRACE' || 'ALL' => Level.ALL,
        'DEBUG' => Level.FINE,
        'INFO' => Level.INFO,
        'WARN' || 'WARNING' => Level.WARNING,
        'ERROR' => Level.SEVERE,
        'OFF' => Level.OFF,
        _ => null,
      };

  /// The Spring Boot name for a logging level.
  static String labelOf(Level level) {
    if (level >= Level.OFF) return 'OFF';
    if (level >= Level.SEVERE) return 'ERROR';
    if (level >= Level.WARNING) return 'WARN';
    if (level >= Level.INFO) return 'INFO';
    if (level >= Level.FINE) return 'DEBUG';
    return 'TRACE';
  }

  /// One record as a log line, with the error and (for ERROR) the stack
  /// trace on the lines after it.
  @visibleForTesting
  static String format(LogRecord r) {
    final t = r.time;
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    final out = StringBuffer('$time ${labelOf(r.level).padLeft(5)} [${r.loggerName}] ${r.message}');
    if (r.error != null) out.write('\n    ${r.error}');
    if (r.stackTrace != null && r.level >= Level.SEVERE) out.write('\n${r.stackTrace}');
    return out.toString();
  }

  static void _print(LogRecord r) {
    // Supabase's TRACE records include request headers and access tokens.
    if (r.loggerName.startsWith('supabase') && r.level < Level.FINE) return;
    debugPrint(format(r));
  }
}
