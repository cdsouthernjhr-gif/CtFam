import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/authentication/data/auth_repository.dart';
import '../../shared/providers/session_controller.dart';
import '../utils/l10n_ext.dart';
import '../widgets/state_views.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.family_restroom_rounded, size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 24),
          const CircularProgressIndicator(),
        ],
      ),
    ),
  );
}

class ConfigErrorScreen extends StatelessWidget {
  const ConfigErrorScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: MessageView(
      icon: Icons.settings_suggest_outlined,
      title: context.l10n.configErrorTitle,
      message: context.l10n.configErrorBody,
    ),
  );
}

class SessionErrorScreen extends ConsumerWidget {
  const SessionErrorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failure = ref.watch(sessionControllerProvider.select((s) => s.failure));
    final l10n = context.l10n;
    return Scaffold(
      body: MessageView(
        icon: Icons.cloud_off_rounded,
        title: l10n.sessionLoadError,
        message: failure == null ? null : l10n.failure(failure.kind),
        action: Column(
          children: [
            FilledButton.icon(
              onPressed: () => ref.read(sessionControllerProvider.notifier).refresh(),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.actionRetry),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => ref.read(authRepositoryProvider).signOut(), child: Text(l10n.signOut)),
          ],
        ),
      ),
    );
  }
}
