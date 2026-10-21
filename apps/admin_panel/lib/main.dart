import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  if (!config.isUsable) {
    runApp(MaterialApp(theme: AppTheme.light(), home: SetupRequiredScreen(appName: 'ChargeKaro Admin', problems: config.problems)));
    return;
  }
  await Supabase.initialize(url: config.supabaseUrl, publishableKey: config.supabaseKey);
  runApp(ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(config),
      supabaseClientProvider.overrideWithValue(Supabase.instance.client),
    ],
    child: const AdminApp(),
  ));
}
