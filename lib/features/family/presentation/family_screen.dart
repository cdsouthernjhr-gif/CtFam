import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/providers/session_controller.dart';
import '../../notifications/presentation/notification_settings_screen.dart';
import '../data/family_repository.dart';
import '../domain/family_models.dart';
import '../domain/family_permissions.dart';
import 'family_providers.dart';

String roleLabel(AppLocalizations l10n, FamilyRole r) => switch (r) {
  FamilyRole.owner => l10n.roleOwner,
  FamilyRole.admin => l10n.roleAdmin,
  FamilyRole.moderator => l10n.roleModerator,
  FamilyRole.member => l10n.roleMember,
};

class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final session = ref.watch(sessionControllerProvider);
    final familyId = session.activeFamilyId;
    if (familyId == null) return const Scaffold(body: LoadingView());
    final role = session.activeMembership?.role ?? FamilyRole.member;
    final family = ref.watch(familyProvider(familyId));
    final members = ref.watch(familyMembersProvider(familyId));
    final myId = session.user?.id ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(family.value?.name ?? l10n.navFamily),
        actions: [
          // My families: switch, create another, or join one with a code.
          PopupMenuButton<String>(
            key: const Key('family.menu'),
            tooltip: l10n.myFamilies,
            icon: const Icon(Icons.swap_horiz),
            onSelected: (value) {
              switch (value) {
                case '__create':
                  context.push(Routes.createFamily);
                case '__join':
                  context.push(Routes.join);
                default:
                  ref.read(sessionControllerProvider.notifier).switchFamily(value);
              }
            },
            itemBuilder: (_) => [
              for (final m in session.activeMemberships)
                CheckedPopupMenuItem(
                  value: m.familyId,
                  checked: m.familyId == familyId,
                  child: Text(m.family?.name ?? ''),
                ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: '__create',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.add_home_outlined),
                  title: Text(l10n.createAnotherFamily),
                ),
              ),
              PopupMenuItem(
                value: '__join',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.qr_code_scanner),
                  title: Text(l10n.joinWithCode),
                ),
              ),
            ],
          ),
          if (FamilyPermissions.canEditFamily(role))
            IconButton(
              tooltip: l10n.newAnnouncement,
              icon: const Icon(Icons.campaign_outlined),
              onPressed: () => showAnnouncementSheet(context, ref, familyId: familyId),
            ),
          IconButton(
            tooltip: l10n.linksTitle,
            icon: const Icon(Icons.hub_outlined),
            onPressed: () => context.push(Routes.familyLinks),
          ),
          IconButton(
            tooltip: l10n.treeTitle,
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () => context.push(Routes.familyTree),
          ),
          IconButton(
            tooltip: l10n.activity,
            icon: const Icon(Icons.history),
            onPressed: () => context.push(Routes.activity),
          ),
          if (FamilyPermissions.canViewInvitations(role))
            IconButton(
              tooltip: l10n.invitations,
              icon: const Icon(Icons.mail_outline),
              onPressed: () => context.push(Routes.invitations),
            ),
          IconButton(
            tooltip: l10n.familySettings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.familySettings),
          ),
        ],
      ),
      floatingActionButton: family.hasValue && FamilyPermissions.canInvite(role, family.requireValue)
          ? FloatingActionButton.extended(
              onPressed: () => context.push(Routes.invite),
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(l10n.dashboardQuickInvite),
            )
          : null,
      body: AsyncValueView(
        value: members,
        onRetry: () => ref.invalidate(familyMembersProvider(familyId)),
        data: (list) {
          if (list.isEmpty) return MessageView(icon: Icons.groups_outlined, title: l10n.noMembers);
          final pending = list.where((m) => m.status == MemberStatus.pending).toList();
          final others = list.where((m) => m.status != MemberStatus.pending).toList();
          final canReview = FamilyPermissions.canEditFamily(role);
          return RefreshIndicator(
            onRefresh: () async => ref.refresh(familyMembersProvider(familyId).future),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                if (pending.isNotEmpty && canReview) ...[
                  _Header(l10n.pendingRequests),
                  for (final m in pending) _PendingTile(member: m),
                  const Divider(),
                ],
                _Header(l10n.memberCountLabel(others.length)),
                for (final m in others)
                  _MemberTile(
                    member: m,
                    isMe: m.userId == myId,
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      showDragHandle: true,
                      isScrollControlled: true,
                      builder: (_) => MemberSheet(member: m, myRole: role, myUserId: myId),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
  );
}

class RoleChip extends StatelessWidget {
  const RoleChip({required this.role, super.key});

  final FamilyRole role;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final emphasised = role == FamilyRole.owner || role == FamilyRole.admin;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: emphasised ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(roleLabel(context.l10n, role), style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member, required this.isMe, required this.onTap});

  final FamilyMember member;
  final bool isMe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final suspended = member.status == MemberStatus.suspended;
    return ListTile(
      onTap: onTap,
      leading: StorageAvatar(initials: member.profile?.initials ?? '?', path: member.profile?.avatarPath),
      title: Text(isMe ? '${member.displayName} (${l10n.you})' : member.displayName),
      subtitle: suspended
          ? Text(l10n.statusSuspended, style: TextStyle(color: Theme.of(context).colorScheme.error))
          : null,
      trailing: RoleChip(role: member.role),
    );
  }
}

class _PendingTile extends ConsumerWidget {
  const _PendingTile({required this.member});

  final FamilyMember member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    Future<void> review(bool approve) async {
      try {
        await ref.read(familyRepositoryProvider).reviewMembership(member.familyId, member.userId, approve: approve);
        ref.invalidate(familyMembersProvider(member.familyId));
      } catch (e) {
        if (context.mounted) context.showError(e);
      }
    }

    return ListTile(
      leading: StorageAvatar(initials: member.profile?.initials ?? '?', path: member.profile?.avatarPath),
      title: Text(member.displayName),
      subtitle: Text(l10n.statusPending),
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(tooltip: l10n.reject, icon: const Icon(Icons.close), onPressed: () => review(false)),
          IconButton.filled(tooltip: l10n.approve, icon: const Icon(Icons.check), onPressed: () => review(true)),
        ],
      ),
    );
  }
}

/// Member profile + management actions (shown only when permitted; the
/// server enforces the same rules).
class MemberSheet extends ConsumerWidget {
  const MemberSheet({required this.member, required this.myRole, required this.myUserId, super.key});

  final FamilyMember member;
  final FamilyRole myRole;
  final String myUserId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final repo = ref.read(familyRepositoryProvider);
    final canManage = FamilyPermissions.canManage(myRole, member, myUserId: myUserId);
    final name = member.displayName;
    final profile = member.profile;

    Future<void> run(Future<void> Function() action) async {
      final nav = Navigator.of(context);
      try {
        await action();
        ref.invalidate(familyMembersProvider(member.familyId));
        await ref.read(sessionControllerProvider.notifier).refresh();
        nav.pop();
        if (context.mounted) context.showMessage(l10n.memberUpdated);
      } catch (e) {
        if (context.mounted) context.showError(e);
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: StorageAvatar(initials: profile?.initials ?? '?', path: profile?.avatarPath, radius: 40),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Center(child: RoleChip(role: member.role)),
            if (profile?.bio != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(profile!.bio!, textAlign: TextAlign.center),
            ],
            if (profile?.phone != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(profile!.phone!, textAlign: TextAlign.center),
            ],
            if (member.joinedAt != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.memberJoined(context.formatDate(member.joinedAt!)),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (canManage) ...[
              const SizedBox(height: AppSpacing.md),
              const Divider(),
              if (member.status == MemberStatus.active)
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: Text(l10n.memberChangeRole),
                  trailing: DropdownButton<FamilyRole>(
                    value: member.role,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final r in FamilyPermissions.assignableRoles(myRole))
                        DropdownMenuItem(value: r, child: Text(roleLabel(l10n, r))),
                    ],
                    onChanged: (r) {
                      if (r != null && r != member.role) run(() => repo.setRole(member.familyId, member.userId, r));
                    },
                  ),
                ),
              if (FamilyPermissions.canTransferOwnership(myRole) && member.status == MemberStatus.active)
                ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: Text(l10n.memberTransferOwnership),
                  onTap: () async {
                    final ok = await confirmDialog(
                      context,
                      title: l10n.confirmTransferTitle,
                      message: l10n.confirmTransferBody(name),
                    );
                    if (ok) await run(() => repo.transferOwnership(member.familyId, member.userId));
                  },
                ),
              if (member.status == MemberStatus.suspended)
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text(l10n.memberReactivate),
                  onTap: () => run(() => repo.setStatus(member.familyId, member.userId, MemberStatus.active)),
                )
              else
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: Text(l10n.memberSuspend),
                  onTap: () async {
                    final ok = await confirmDialog(
                      context,
                      title: l10n.confirmSuspendTitle(name),
                      message: l10n.confirmSuspendBody(name),
                      destructive: true,
                    );
                    if (ok) await run(() => repo.setStatus(member.familyId, member.userId, MemberStatus.suspended));
                  },
                ),
              ListTile(
                leading: Icon(Icons.person_remove_outlined, color: Theme.of(context).colorScheme.error),
                title: Text(l10n.memberRemove, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () async {
                  final ok = await confirmDialog(
                    context,
                    title: l10n.confirmRemoveTitle(name),
                    message: l10n.confirmRemoveBody(name),
                    destructive: true,
                  );
                  if (ok) await run(() => repo.setStatus(member.familyId, member.userId, MemberStatus.removed));
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
