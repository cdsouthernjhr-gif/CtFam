import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../shared/providers/session_controller.dart';
import '../../authentication/data/auth_repository.dart';

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final pending = ref.watch(sessionControllerProvider.select((s) => s.pendingMemberships));

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: l10n.profileTitle,
            onPressed: () => context.push(Routes.profile),
            icon: const Icon(Icons.account_circle_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Icon(Icons.diversity_3_rounded, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: AppSpacing.md),
            Text(
              l10n.onboardingTitle,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.onboardingBody,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (pending.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.hourglass_top_rounded),
                  title: Text(l10n.pendingApprovalTitle),
                  subtitle: Text(l10n.pendingApprovalBody),
                  trailing: IconButton(
                    tooltip: l10n.refresh,
                    icon: const Icon(Icons.refresh),
                    onPressed: () => ref.read(sessionControllerProvider.notifier).refresh(),
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: () => context.push(Routes.createFamily),
              icon: const Icon(Icons.add_home_outlined),
              label: Text(l10n.createFamily),
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: () => context.push(Routes.join),
              icon: const Icon(Icons.vpn_key_outlined),
              label: Text(l10n.joinWithCode),
            ),
            const SizedBox(height: AppSpacing.xl),
            TextButton(onPressed: () => ref.read(authRepositoryProvider).signOut(), child: Text(l10n.signOut)),
          ],
        ),
      ),
    );
  }
}
