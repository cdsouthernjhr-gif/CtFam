import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'shared/providers/session_controller.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };

  final configProblem = AppConfig.validate();
  if (configProblem != null) debugPrint('FamilySync configuration: $configProblem');
  if (configProblem == null) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabasePublishableKey,
      authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
      debug: kDebugMode,
    );
  }

  runApp(
    ProviderScope(
      overrides: [supabaseConfiguredProvider.overrideWithValue(configProblem == null)],
      child: const FamilySyncApp(),
    ),
  );
}
