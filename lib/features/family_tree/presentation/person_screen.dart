import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/tree_repository.dart';
import '../domain/tree_models.dart';
import 'person_form_sheet.dart';
import 'relation_sheet.dart';
import 'tree_photo.dart';
import 'tree_providers.dart';

/// Malay/English name of the n-th generation below someone.
String descendantLabel(AppLocalizations l10n, int generation) => switch (generation) {
  1 => l10n.treeChildren,
  2 => l10n.treeGrandchildren,
  3 => l10n.treeGreatGrandchildren,
  4 => l10n.treeGreatGreatGrandchildren,
  _ => l10n.treeGenerationN(generation),
};

bool isTreeAdmin(FamilyRole? role) => role == FamilyRole.owner || role == FamilyRole.admin;

/// Owner/admin of [familyId] (people are edited by their home family).
/// "Anak saudara anda (melalui Ali)" etc.; null when there is no label.
String? relationshipText(AppLocalizations l10n, TreeData tree, Relationship r) {
  final label = r.label(l10n.localeName);
  if (label == null) return null;
  final via = r.via == null ? null : tree.persons[r.via!];
  if (via == null) return l10n.treeRelationIs(label);
  return r.kind == 'marriage'
      ? l10n.treeRelationViaSpouse(label, via.fullName)
      : l10n.treeRelationViaParent(label, via.fullName);
}

final adminOfFamilyProvider = Provider.family<bool, String>((ref, familyId) {
  final memberships = ref.watch(sessionControllerProvider.select((s) => s.activeMemberships));
  return memberships.any((m) => m.familyId == familyId && isTreeAdmin(m.role));
});

class PersonScreen extends ConsumerWidget {
  const PersonScreen({required this.personId, super.key});

  final String personId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final l10n = context.l10n;
    final tree = ref.watch(treeDataProvider(familyId));
    final me = ref.watch(currentUserIdProvider);
    final person = tree.value?.persons[personId];
    // Editing belongs to the person's home family; proposing works from the active family.
    final admin = person == null
        ? isTreeAdmin(ref.watch(myRoleProvider))
        : ref.watch(adminOfFamilyProvider(person.familyId));
    final canEdit = person != null && (admin || person.userId == me);

    return Scaffold(
      appBar: AppBar(
        title: Text(person?.fullName ?? l10n.treeTitle),
        actions: [
          if (canEdit)
            IconButton(
              tooltip: l10n.treeEditPerson,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => showPersonForm(context, familyId: familyId, person: person),
            ),
          if (admin && person != null)
            PopupMenuButton<String>(
              onSelected: (v) => _adminAction(context, ref, v, familyId, person),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'link', child: Text(l10n.treeLinkAccount)),
                if (person.hasAccount) PopupMenuItem(value: 'unlink', child: Text(l10n.treeUnlinkAccount)),
                PopupMenuItem(value: 'delete', child: Text(l10n.treeDeletePerson)),
              ],
            ),
        ],
      ),
      body: AsyncValueView(
        value: tree,
        onRetry: () => ref.invalidate(treeDataProvider(familyId)),
        data: (t) => person == null
            ? MessageView(icon: Icons.person_off_outlined, title: l10n.treePersonNotFound)
            : _Body(familyId: familyId, tree: t, person: person, admin: admin),
      ),
    );
  }

  Future<void> _adminAction(BuildContext context, WidgetRef ref, String action, String familyId, TreePerson p) async {
    final l10n = context.l10n;
    final repo = ref.read(treeRepositoryProvider);
    try {
      switch (action) {
        case 'link':
          final members = await ref.read(familyMembersProvider(familyId).future);
          if (!context.mounted) return;
          final userId = await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: Text(l10n.treeLinkAccount),
              children: [
                for (final m in members.where((m) => m.status == MemberStatus.active))
                  SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop(m.userId), child: Text(m.displayName)),
              ],
            ),
          );
          if (userId == null) return;
          await repo.linkAccount(p.id, userId);
        case 'unlink':
          await repo.linkAccount(p.id, null);
        case 'delete':
          final ok = await confirmDialog(
            context,
            title: l10n.treeDeletePerson,
            message: l10n.treeDeletePersonMessage(p.fullName),
            confirmLabel: l10n.actionDelete,
            destructive: true,
          );
          if (!ok) return;
          await repo.deletePerson(p.id, photoPath: p.photoPath);
          if (context.mounted) context.pop();
      }
      ref.invalidate(treeDataProvider(familyId));
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.familyId, required this.tree, required this.person, required this.admin});

  final String familyId;
  final TreeData tree;
  final TreePerson person;
  final bool admin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final me = ref.watch(currentUserIdProvider);
    final isMe = person.userId != null && person.userId == me;
    final rel = isMe ? null : ref.watch(relationshipProvider((familyId: familyId, personId: person.id)));
    final now = DateTime.now();

    final memberships = ref.watch(sessionControllerProvider.select((s) => s.activeMemberships));
    bool adminOf(String? familyId) => memberships.any((m) => m.familyId == familyId && isTreeAdmin(m.role));
    bool canUnlink(TreePerson other) {
      final r = tree.relationBetween(person.id, other.id);
      return r != null && (adminOf(r.familyId) || adminOf(r.otherFamilyId));
    }

    Future<void> unlink(TreePerson other) async {
      final r = tree.relationBetween(person.id, other.id);
      if (r == null) return;
      final ok = await confirmDialog(
        context,
        title: l10n.treeRemoveRelation,
        message: l10n.treeRemoveRelationMessage(person.fullName, other.fullName),
        confirmLabel: l10n.actionDelete,
        destructive: true,
      );
      if (!ok) return;
      try {
        await ref.read(treeRepositoryProvider).deleteRelation(r.id);
        ref.invalidate(treeDataProvider(familyId));
      } catch (e) {
        if (context.mounted) context.showError(e);
      }
    }

    Widget group(String title, List<TreePerson> people) => people.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final p in people)
                      if (canUnlink(p))
                        InputChip(
                          key: ValueKey('rel-${p.id}'),
                          avatar: Icon(p.gender == Gender.male ? Icons.male : Icons.female, size: 16),
                          label: Text(p.fullName),
                          onPressed: () => context.push(Routes.treePerson(p.id)),
                          deleteButtonTooltipMessage: l10n.treeRemoveRelation,
                          onDeleted: () => unlink(p),
                        )
                      else
                        ActionChip(
                          avatar: Icon(p.gender == Gender.male ? Icons.male : Icons.female, size: 16),
                          label: Text(
                            tree.isAdoptiveChild(person.id, p.id) || tree.isAdoptiveChild(p.id, person.id)
                                ? '${p.fullName} (${l10n.treeAdoptiveShort})'
                                : p.fullName,
                          ),
                          onPressed: () => context.push(Routes.treePerson(p.id)),
                        ),
                  ],
                ),
              ],
            ),
          );

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            _PersonPhoto(person: person, canEdit: admin || isMe, familyId: familyId),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.fullName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    person.isDeceased
                        ? l10n.treeDeceasedLabel(person.gender == Gender.male ? l10n.treeLateMale : l10n.treeLateFemale)
                        : l10n.treeAge(person.ageOn(now)),
                    style: TextStyle(color: scheme.outline),
                  ),
                  if (person.familyId != familyId && tree.familyNames[person.familyId] != null)
                    Text(
                      l10n.treeFromFamily(tree.familyNames[person.familyId]!),
                      style: TextStyle(color: scheme.outline, fontSize: 12),
                    ),
                  if (person.hasAccount)
                    Row(
                      children: [
                        Icon(Icons.verified_user_outlined, size: 14, color: scheme.primary),
                        const SizedBox(width: 4),
                        Text(l10n.treeHasAccount, style: TextStyle(color: scheme.primary, fontSize: 12)),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Card(
          color: scheme.primaryContainer,
          child: ListTile(
            leading: Icon(Icons.diversity_3_outlined, color: scheme.onPrimaryContainer),
            title: Text(
              isMe
                  ? l10n.treeThisIsYou
                  : rel == null || rel.isLoading
                  ? '…'
                  : rel.hasError
                  ? context.errorText(rel.error!)
                  : switch (rel.requireValue.kind) {
                      'none' => l10n.treeNoRelation,
                      'no_profile' => l10n.treeNeedOwnProfile,
                      _ => relationshipText(l10n, tree, rel.requireValue) ?? l10n.treeNoRelation,
                    },
              style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cake_outlined),
          title: Text(context.formatDate(person.birthDate)),
          subtitle: person.isDeceased ? Text(l10n.treeDiedOn(context.formatDate(person.deathDate!))) : null,
        ),
        if (person.notes != null)
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.notes), title: Text(person.notes!)),
        group(l10n.treeParents, tree.parentsOf(person.id)),
        group(l10n.treeSpouses, tree.spousesOf(person.id)),
        group(l10n.treeSiblings, tree.siblingsOf(person.id)),
        group(l10n.treeChildren, tree.childrenOf(person.id)),
        // Grandchildren, great-grandchildren, … without limit.
        for (final e in tree.descendantsByGeneration(person.id).entries.where((e) => e.key >= 2))
          group('${descendantLabel(l10n, e.key)} (${e.value.length})', e.value),
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton.icon(
          onPressed: () => showRelationSheet(
            context,
            familyId: familyId,
            person: person,
            tree: tree,
            isAdmin: isTreeAdmin(ref.read(myRoleProvider)),
          ),
          icon: const Icon(Icons.link),
          label: Text(admin ? l10n.treeAddRelation : l10n.treeProposeRelation),
        ),
      ],
    );
  }
}

/// Person photo; tap to change or remove it (admins, or the person themselves).
class _PersonPhoto extends ConsumerStatefulWidget {
  const _PersonPhoto({required this.person, required this.canEdit, required this.familyId});

  final TreePerson person;
  final bool canEdit;
  final String familyId;

  @override
  ConsumerState<_PersonPhoto> createState() => _PersonPhotoState();
}

class _PersonPhotoState extends ConsumerState<_PersonPhoto> {
  bool _busy = false;

  Future<void> _edit() async {
    final l10n = context.l10n;
    final action = await choosePhotoAction(context, hasPhoto: widget.person.photoPath != null);
    if (action == null || !mounted) return;
    final repo = ref.read(treeRepositoryProvider);
    try {
      if (action == PhotoAction.remove) {
        final ok = await confirmDialog(
          context,
          title: l10n.photoRemove,
          message: l10n.photoRemoveMessage,
          confirmLabel: l10n.actionDelete,
          destructive: true,
        );
        if (!ok) return;
        setState(() => _busy = true);
        await repo.removePersonPhoto(widget.person);
      } else {
        final picked = await pickTreeImage(context, action);
        if (picked == null) return;
        setState(() => _busy = true);
        await repo.setPersonPhoto(widget.person, picked.$1, picked.$2);
      }
      ref.invalidate(treeDataProvider(widget.familyId));
      if (mounted) context.showMessage(l10n.saved);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = StorageAvatar(
      radius: 40,
      bucket: TreeRepository.photoBucket,
      path: widget.person.photoPath,
      initials: widget.person.initials,
    );
    if (!widget.canEdit) return avatar;
    return Semantics(
      button: true,
      label: context.l10n.photoChange,
      child: InkWell(
        key: const Key('tree.photo'),
        customBorder: const CircleBorder(),
        onTap: _busy ? null : _edit,
        child: Stack(
          children: [
            avatar,
            Positioned(
              right: 0,
              bottom: 0,
              child: CircleAvatar(
                radius: 14,
                backgroundColor: scheme.primary,
                child: _busy
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                      )
                    : Icon(Icons.photo_camera, size: 15, color: scheme.onPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
