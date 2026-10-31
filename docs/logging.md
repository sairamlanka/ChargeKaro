# Logging

ChargeKaro logs the way a Spring Boot service does: a logger per class,
levels, timestamps, and one line per event.

## Flutter apps

`AppLogging.start` (packages/shared_data/lib/src/logging.dart) runs first in
each app's `main()`. Lines look like this:

```
2026-10-30 14:09:11.902  INFO [App] Starting ChargeKaro (development) against uonxnnqyeubepfmvwmaf.supabase.co, log level DEBUG
2026-10-30 14:09:12.110 DEBUG [RetailRepository] rpc search_stations {p_latitude: 17.4126, p_longitude: 78.4392, p_radius_km: 10.0, p_limit: 60}
2026-10-30 14:09:12.345 DEBUG [RetailRepository] rpc search_stations ok in 235 ms (stations: 0)
2026-10-30 14:09:15.020  WARN [RetailRepository] rpc get_my_bookings after 180 ms failed: unauthenticated/session_expired
2026-10-30 14:09:18.400 ERROR [RetailRepository] function route-plan after 20002 ms failed: network/timeout
```

| Spring Boot | Dart `Logger` call | Used for |
| --- | --- | --- |
| TRACE | `log.finest(...)` | Very detailed tracing |
| DEBUG | `log.fine(...)` | Every backend call with its parameters, timing and row counts |
| INFO | `log.info(...)` | Start-up and notable events |
| WARN | `log.warning(...)` | Expected failures: validation, conflicts, signed out |
| ERROR | `log.severe(msg, error, stack)` | Network, server and unknown errors, uncaught exceptions (with stack trace) |

What is logged automatically:

- Every repository call (`rpc`, `rows`, `row`, `maybeRow`, Edge Function
  calls in the Retail App) with its duration; failures with the error code
  and detail. Every repository has `log`, a logger named after its class.
- Any error mapped by `guard`.
- Device location results in the Retail App.
- Uncaught Flutter and async errors.
- Supabase's own client logs (DEBUG and above).

Parameters whose names mention phone, email, token, password, secret, OTP,
signature or code are masked. Never put secrets or full phone numbers in a
log message.

To add a logger to any class:

```dart
import 'package:shared_data/shared_data.dart';

class ExploreController {
  static final _log = Logger('ExploreController');

  void refresh() {
    _log.fine('Refreshing results');
  }
}
```

### Choosing the level

Like `logging.level.root` in `application.properties`, set `LOG_LEVEL` in the
env file (`env/development.json`) or pass it on the command line:

```
"LOG_LEVEL": "DEBUG"
.\run.ps1 --dart-define=LOG_LEVEL=TRACE
```

Values: TRACE, DEBUG, INFO, WARN, ERROR, OFF. Without it, development builds
log DEBUG and production builds INFO.

### Where to read the app logs

- `flutter run` (or `.\run.ps1`): the terminal it runs in.
- Android Studio / VS Code: the Run or Debug Console.
- Android device or emulator without a debugger: `adb logcat -s flutter`.
- Web: the browser's developer console.

## Edge Functions

`supabase/functions/_shared/log.ts` writes one JSON line per event, and every
function is wrapped in `withLogging`, which logs each request's status and
duration (`request.done`: info for success, warn for 4xx with the error code,
error for 5xx). Scheduled functions log success at debug so their
every-minute runs stay quiet. Set the level with the `LOG_LEVEL` function
secret (debug, info, warn, error; default info):

```
npx supabase secrets set LOG_LEVEL=debug
```

Read them in the Supabase dashboard under **Edge Functions > (function) >
Logs**, or in the terminal running `npx supabase functions serve` locally.

## Database

Errors raised by SQL functions and PostgREST requests appear in the Supabase
dashboard under **Logs > Postgres** and **Logs > API** (each request with its
status code). The app's log line for the same failure carries the error code
to search for.
