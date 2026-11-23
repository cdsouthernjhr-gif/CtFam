import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/chat_repository.dart';
import 'chat_providers.dart';

/// Group settings: name, description, members (add/remove/admin), leave.
class GroupInfoScreen extends ConsumerWidget {
  const GroupInfoScreen({required this.conversationId, super.key});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final familyId = ref.watch(activeFamilyIdProvider) ?? '';
    final me = ref.watch(currentUserIdProvider);
    final familyRole = ref.watch(myRoleProvider);
    final repo = ref.read(chatRepositoryProvider);
    final async = ref.watch(conversationControllerProvider(conversationId));
    final summary = ref
        .watch(conversationSummariesProvider(familyId))
        .value
        ?.where((c) => c.id == conversationId)
        .firstOrNull;
    final familyMembers = ref.watch(familyMembersProvider(familyId)).value ?? const <FamilyMember>[];

    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
        ref.invalidate(conversationSummariesProvider(familyId));
      } catch (e) {
        if (context.mounted) context.showError(e);
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.groupInfo)),
      body: AsyncValueView(
        value: async,
        data: (state) {
          final myMember = state.members.where((m) => m.userId == me).firstOrNull;
          final canModerate =
              (myMember?.isAdmin ?? false) ||
              familyRole == FamilyRole.owner ||
              familyRole == FamilyRole.admin ||
              familyRole == FamilyRole.moderator;
          final inGroup = {for (final m in state.members) m.userId};
          final addable = familyMembers
              .where((m) => m.status == MemberStatus.active && !inGroup.contains(m.userId))
              .toList();
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Center(
                child: CircleAvatar(
                  radius: 40,
                  backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                  child: const Icon(Icons.groups_rounded, size: 40),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(summary?.name ?? '', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              if (summary?.description != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(summary!.description!, textAlign: TextAlign.center),
                ),
              if (canModerate)
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(l10n.editGroup),
                    onPressed: () async {
                      final result = await _editDialog(context, summary?.name ?? '', summary?.description ?? '');
                      if (result != null) {
                        await run(() => repo.updateGroup(conversationId, name: result.$1, description: result.$2));
                      }
                    },
                  ),
                ),
              const Divider(height: AppSpacing.xl),
              Row(
                children: [
                  Expanded(
                    child: Text(l10n.membersCount(state.members.length), style: Theme.of(context).textTheme.titleSmall),
                  ),
                  if (canModerate && addable.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.person_add_alt),
                      label: Text(l10n.addMembers),
                      onPressed: () async {
                        final picked = await _pickMembers(context, addable);
                        if (picked != null && picked.isNotEmpty) {
                          await run(() => repo.addMembers(conversationId, picked));
                        }
                      },
                    ),
                ],
              ),
              for (final m in state.members)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: StorageAvatar(
                    initials: (m.displayName ?? '?').substring(0, 1).toUpperCase(),
                    path: m.avatarPath,
                  ),
                  title: Text(m.userId == me ? '${m.displayName ?? ''} (${l10n.you})' : (m.displayName ?? '')),
                  subtitle: m.isAdmin ? Text(l10n.groupAdmin) : null,
                  trailing: canModerate && m.userId != me
                      ? PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'remove') {
                              final ok = await confirmDialog(
                                context,
                                title: l10n.removeFromGroupTitle(m.displayName ?? ''),
                                message: l10n.removeFromGroupBody,
                                destructive: true,
                              );
                              if (ok) await run(() => repo.removeMember(conversationId, m.userId));
                            } else {
                              await run(() => repo.setMemberRole(conversationId, m.userId, v));
                            }
                          },
                          itemBuilder: (_) => [
                            if (!m.isAdmin) PopupMenuItem(value: 'admin', child: Text(l10n.makeGroupAdmin)),
                            if (m.isAdmin) PopupMenuItem(value: 'member', child: Text(l10n.removeGroupAdmin)),
                            PopupMenuItem(value: 'remove', child: Text(l10n.removeFromGroup)),
                          ],
                        )
                      : null,
                ),
              const Divider(height: AppSpacing.xl),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
                title: Text(l10n.leaveGroup, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () async {
                  final ok = await confirmDialog(
                    context,
                    title: l10n.leaveGroupTitle,
                    message: l10n.leaveGroupBody,
                    destructive: true,
                  );
                  if (!ok || !context.mounted) return;
                  final router = GoRouter.of(context);
                  await run(() async {
                    await repo.leave(conversationId);
                    router.go('/chat');
                  });
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<(String, String)?> _editDialog(BuildContext context, String name, String description) {
    final l10n = context.l10n;
    final n = TextEditingController(text: name);
    final d = TextEditingController(text: description);
    return showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.editGroup),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: n,
              maxLength: 80,
              decoration: InputDecoration(labelText: l10n.groupName),
            ),
            TextField(
              controller: d,
              maxLength: 500,
              decoration: InputDecoration(labelText: l10n.fieldDescription),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.actionCancel)),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
            onPressed: () => n.text.trim().isEmpty ? null : Navigator.pop(ctx, (n.text.trim(), d.text.trim())),
            child: Text(l10n.actionSave),
          ),
        ],
      ),
    );
  }

  Future<List<String>?> _pickMembers(BuildContext context, List<FamilyMember> candidates) {
    final l10n = context.l10n;
    final selected = <String>{};
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(l10n.addMembers),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final m in candidates)
                  CheckboxListTile(
                    value: selected.contains(m.userId),
                    title: Text(m.displayName),
                    onChanged: (v) => setState(() => v == true ? selected.add(m.userId) : selected.remove(m.userId)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.actionCancel)),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
              onPressed: () => Navigator.pop(ctx, selected.toList()),
              child: Text(l10n.addMembers),
            ),
          ],
        ),
      ),
    );
  }
}
