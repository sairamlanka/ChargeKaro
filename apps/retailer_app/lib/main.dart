import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'data/local_store.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  if (!config.isUsable) {
    runApp(MaterialApp(theme: AppTheme.light(), home: SetupRequiredScreen(appName: 'ChargeKaro', problems: config.problems)));
    return;
  }
  await Future.wait([initializeDateFormatting('en_IN'), initializeDateFormatting('te')]);
  await Supabase.initialize(url: config.supabaseUrl, publishableKey: config.supabaseKey);
  LocalStore store;
  try {
    store = await LocalStore.open();
  } catch (_) {
    // Storage blocked (private browsing): keep working without memory.
    store = await LocalStore.memory();
  }
  runApp(ProviderScope(
    // Screens decide when to retry; automatic retries would hide failures.
    retry: (_, _) => null,
    overrides: [
      appConfigProvider.overrideWithValue(config),
      supabaseClientProvider.overrideWithValue(Supabase.instance.client),
      localStoreProvider.overrideWithValue(store),
    ],
    child: const RetailApp(),
  ));
}
