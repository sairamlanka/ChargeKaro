import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'push.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogging.start(AppConfig.fromEnvironment(), app: 'ChargeKaro Business');
  // The logo shows for 3 seconds while the app starts up behind it.
  runApp(const SplashGate(load: _start));
}

Future<Widget> _start() async {
  final config = AppConfig.fromEnvironment();
  if (!config.isUsable) {
    Logger('App').severe('Not configured: ${config.problems.join(' ')}');
    return MaterialApp(theme: AppTheme.light(), home: SetupRequiredScreen(appName: 'ChargeKaro Business', problems: config.problems));
  }
  await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.supabaseKey,
    debug: false, // Supabase's own logs go through AppLogging instead
    authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
  );
  await Push.initialize();
  return ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(config),
      supabaseClientProvider.overrideWithValue(Supabase.instance.client),
    ],
    child: const BusinessApp(),
  );
}
