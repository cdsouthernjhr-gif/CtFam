import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/domain/family_permissions.dart';
import '../../family/presentation/activity_screen.dart';
import '../../family/presentation/family_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final l10n = context.l10n;
    final family = ref.watch(familyProvider(familyId));
    final members = ref.watch(familyMembersProvider(familyId));
    final activity = ref.watch(familyActivityProvider(familyId));
    final me = ref.watch(myProfileProvider);
    final role = ref.watch(myRoleProvider);

    Future<void> refresh() async {
      ref.invalidate(familyProvider(familyId));
      ref.invalidate(familyMembersProvider(familyId));
      ref.invalidate(familyActivityProvider(familyId));
      ref.invalidate(myProfileProvider);
      await ref.read(familyMembersProvider(familyId).future);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(family.value?.name ?? l10n.appName, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: IconButton(
              tooltip: l10n.profileTitle,
              onPressed: () => context.push(Routes.profile),
              icon: StorageAvatar(radius: 16, initials: me.value?.initials ?? '', path: me.value?.avatarPath),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text(
              l10n.greeting(me.value?.displayName ?? ''),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.md),
            if (family.hasValue) _FamilyHeader(family: family.requireValue, memberCount: members.value?.length),
            const SizedBox(height: AppSpacing.md),
            _SectionHeader(
              title: l10n.dashboardMembers,
              action: TextButton(onPressed: () => context.go(Routes.family), child: Text(l10n.dashboardSeeAll)),
            ),
            SizedBox(
              height: 92,
              child: AsyncValueView(
                value: members,
                onRetry: () => ref.invalidate(familyMembersProvider(familyId)),
                data: (list) => ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: list.where((m) => m.status == MemberStatus.active).length,
                  separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
                  itemBuilder: (_, i) {
                    final m = list.where((m) => m.status == MemberStatus.active).elementAt(i);
                    return SizedBox(
                      width: 64,
                      child: Column(
                        children: [
                          StorageAvatar(initials: m.profile?.initials ?? '?', path: m.profile?.avatarPath, radius: 26),
                          const SizedBox(height: 6),
                          Text(
                            m.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            if (family.hasValue && role != null && FamilyPermissions.canInvite(role, family.requireValue)) ...[
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => context.push(Routes.invite),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: Text(l10n.dashboardQuickInvite),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_outlined, color: Theme.of(context).colorScheme.secondary),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(child: Text(l10n.dashboardComingSoon)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            _SectionHeader(
              title: l10n.dashboardRecentActivity,
              action: TextButton(onPressed: () => context.push(Routes.activity), child: Text(l10n.dashboardSeeAll)),
            ),
            AsyncValueView(
              value: activity,
              onRetry: () => ref.invalidate(familyActivityProvider(familyId)),
              data: (entries) => entries.isEmpty
                  ? Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Text(l10n.dashboardNoActivity))
                  : Card(
                      child: Column(children: [for (final e in entries.take(5)) ActivityTile(entry: e)]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FamilyHeader extends StatelessWidget {
  const _FamilyHeader({required this.family, this.memberCount});

  final Family family;
  final int? memberCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primary,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            StorageAvatar(
              bucket: 'family-media',
              path: family.imagePath,
              initials: family.name.substring(0, 1).toUpperCase(),
              icon: family.imagePath == null ? Icons.family_restroom_rounded : null,
              radius: 28,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    family.name,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w700),
                  ),
                  if (memberCount != null)
                    Text(
                      context.l10n.memberCountLabel(memberCount!),
                      style: TextStyle(color: scheme.onPrimary.withValues(alpha: 0.85)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      ?action,
    ],
  );
}
