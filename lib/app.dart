import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/notifications/push/push_service.dart';
import 'features/settings/presentation/app_settings.dart';
import 'l10n/generated/app_localizations.dart';
import 'shared/providers/offline_lifecycle.dart';
import 'shared/providers/session_controller.dart';

/// Root widget. Expects a ProviderScope above it (see bootstrap.dart) that
/// overrides [supabaseConfiguredProvider].
class FamilySyncApp extends ConsumerWidget {
  const FamilySyncApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final push = ref.watch(pushServiceProvider)
      ..onOpenRoute = router.go
      ..currentRoute = (() => router.routerDelegate.currentConfiguration.uri.path);
    // Register for push once the user is in a family (idempotent); the device
    // token is removed again before sign-out.
    final status = ref.watch(sessionControllerProvider.select((s) => s.status));
    ref.watch(offlineLifecycleProvider);
    if (status == SessionStatus.ready) Future.microtask(push.start);
    return MaterialApp.router(
      onGenerateTitle: (ctx) => AppLocalizations.of(ctx).appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      locale: ref.watch(localeProvider),
      supportedLocales: supportedLocales,
      localizationsDelegates: const [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
      routerConfig: router,
    );
  }
}
