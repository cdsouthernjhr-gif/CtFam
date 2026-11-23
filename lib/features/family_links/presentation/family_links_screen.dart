import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/links_repository.dart';
import '../domain/link_models.dart';

final clanProvider = FutureProvider.autoDispose.family<List<LinkedFamily>, String>(
  (ref, familyId) => ref.watch(linksRepositoryProvider).clan(familyId),
);

final linkRequestsProvider = FutureProvider.autoDispose.family<List<LinkRequest>, String>(
  (ref, familyId) => ref.watch(linksRepositoryProvider).requests(familyId),
);

/// Keluarga berkaitan: the clan outline, the parent/branches of the active
/// family, pending requests, and (owner/admin) linking actions.
class FamilyLinksScreen extends ConsumerWidget {
  const FamilyLinksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final familyId = session.activeFamilyId;
    if (familyId == null) return const Scaffold(body: LoadingView());
    final l10n = context.l10n;
    final role = ref.watch(myRoleProvider);
    final admin = role == FamilyRole.owner || role == FamilyRole.admin;
    final clan = ref.watch(clanProvider(familyId));
    final requests = ref.watch(linkRequestsProvider(familyId));

    void refresh() {
      ref.invalidate(clanProvider(familyId));
      ref.invalidate(linkRequestsProvider(familyId));
    }

    Future<void> act(Future<void> Function() f, {String? success}) async {
      try {
        await f();
        refresh();
        if (context.mounted && success != null) context.showMessage(success);
      } catch (e) {
        if (context.mounted) context.showError(e);
      }
    }

    // Families I belong to, other than the active one (link candidates).
    final mine = session.activeMemberships.where((m) => m.familyId != familyId).toList();
    final list = clan.value ?? const <LinkedFamily>[];
    final hasParent = list.any((f) => f.relation == LinkRelation.parent);
    final clanIds = {for (final f in list) f.familyId};
    final candidates = mine.where((m) => !clanIds.contains(m.familyId)).toList();

    Future<void> requestLink({required bool asBranch}) async {
      final picked = await showDialog<MyMembership>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(asBranch ? l10n.linkPickParent : l10n.linkPickBranch),
          children: [
            for (final m in candidates)
              SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop(m), child: Text(m.family?.name ?? '')),
          ],
        ),
      );
      if (picked == null || !context.mounted) return;
      await act(() async {
        final active = await ref
            .read(linksRepositoryProvider)
            .request(
              parentFamilyId: asBranch ? picked.familyId : familyId,
              childFamilyId: asBranch ? familyId : picked.familyId,
            );
        if (context.mounted) context.showMessage(active ? l10n.linkActive : l10n.linkRequested);
      });
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.linksTitle)),
      body: RefreshIndicator(
        onRefresh: () async => refresh(),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text(l10n.linksExplain, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.md),
            AsyncValueView(
              value: requests,
              onRetry: refresh,
              data: (reqs) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final r in reqs)
                    Card(
                      child: ListTile(
                        leading: Icon(r.incoming ? Icons.call_received : Icons.call_made),
                        title: Text(
                          r.incoming ? l10n.linkIncoming(r.otherFamilyName) : l10n.linkOutgoing(r.otherFamilyName),
                        ),
                        subtitle: Text(
                          r.childFamilyId == familyId
                              ? l10n.linkAsBranchOf(r.otherFamilyName)
                              : l10n.linkAsParentOf(r.otherFamilyName),
                        ),
                        trailing: !admin
                            ? null
                            : r.incoming
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: l10n.linkApprove,
                                    icon: const Icon(Icons.check_circle_outline, color: Colors.green),
                                    onPressed: () => act(
                                      () => ref.read(linksRepositoryProvider).respond(r.id, approve: true),
                                      success: l10n.linkActive,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: l10n.linkDecline,
                                    icon: Icon(Icons.cancel_outlined, color: Theme.of(context).colorScheme.error),
                                    onPressed: () =>
                                        act(() => ref.read(linksRepositoryProvider).respond(r.id, approve: false)),
                                  ),
                                ],
                              )
                            : TextButton(
                                onPressed: () => act(() => ref.read(linksRepositoryProvider).remove(r.id)),
                                child: Text(l10n.linkWithdraw),
                              ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(l10n.linksClan, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            AsyncValueView(
              value: clan,
              onRetry: refresh,
              data: (all) {
                if (all.length <= 1) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Text(l10n.linksNone),
                  );
                }
                final outline = clanOutline(all);
                final rootDepth = outline.isEmpty ? 0 : outline.map((f) => f.depth).reduce((a, b) => a < b ? a : b);
                return Card(
                  child: Column(
                    children: [
                      for (final f in outline)
                        ListTile(
                          contentPadding: EdgeInsets.only(left: AppSpacing.md + (f.depth - rootDepth) * 20.0, right: 8),
                          leading: Icon(switch (f.relation) {
                            LinkRelation.self => Icons.home,
                            LinkRelation.parent => Icons.north,
                            LinkRelation.child => Icons.south,
                            LinkRelation.clan => Icons.diversity_3_outlined,
                          }, color: f.relation == LinkRelation.self ? Theme.of(context).colorScheme.primary : null),
                          title: Text(
                            f.name,
                            style: TextStyle(
                              fontWeight: f.relation == LinkRelation.self ? FontWeight.w700 : FontWeight.w400,
                            ),
                          ),
                          subtitle: Text(
                            '${switch (f.relation) {
                              LinkRelation.self => l10n.linkSelf,
                              LinkRelation.parent => l10n.linkParent,
                              LinkRelation.child => l10n.linkChild,
                              LinkRelation.clan => l10n.linkClan,
                            }} · ${l10n.memberCountLabel(f.memberCount)}',
                          ),
                          trailing: admin && (f.relation == LinkRelation.parent || f.relation == LinkRelation.child)
                              ? IconButton(
                                  tooltip: l10n.linkRemove,
                                  icon: const Icon(Icons.link_off),
                                  onPressed: () async {
                                    final ok = await confirmDialog(
                                      context,
                                      title: l10n.linkRemove,
                                      message: l10n.linkRemoveMessage(f.name),
                                      confirmLabel: l10n.linkRemove,
                                      destructive: true,
                                    );
                                    if (!ok) return;
                                    final childId = f.relation == LinkRelation.parent ? familyId : f.familyId;
                                    await act(() async {
                                      final id = await ref.read(linksRepositoryProvider).linkIdForChild(childId);
                                      if (id != null) await ref.read(linksRepositoryProvider).remove(id);
                                    });
                                  },
                                )
                              : null,
                        ),
                    ],
                  ),
                );
              },
            ),
            if (admin) ...[
              const SizedBox(height: AppSpacing.lg),
              if (candidates.isEmpty)
                Text(l10n.linksNoCandidates, style: Theme.of(context).textTheme.bodySmall)
              else ...[
                if (!hasParent)
                  OutlinedButton.icon(
                    onPressed: () => requestLink(asBranch: true),
                    icon: const Icon(Icons.north),
                    label: Text(l10n.linkMakeBranch),
                  ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: () => requestLink(asBranch: false),
                  icon: const Icon(Icons.south),
                  label: Text(l10n.linkAddBranch),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
