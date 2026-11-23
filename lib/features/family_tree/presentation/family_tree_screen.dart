import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
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
import 'person_screen.dart';
import 'tree_photo.dart';
import 'tree_providers.dart';

/// Salasilah: the whole family as generations (zoom and pan), with a prompt
/// to create one's own record and, for admins, proposals to review.
class FamilyTreeScreen extends ConsumerWidget {
  const FamilyTreeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final l10n = context.l10n;
    final tree = ref.watch(treeDataProvider(familyId));
    final me = ref.watch(currentUserIdProvider);
    final admin = isTreeAdmin(ref.watch(myRoleProvider));
    final t = tree.value;
    final pending = t?.pending ?? const <TreeRelation>[];
    final visiblePending = admin ? pending : pending.where((r) => r.proposedBy == me).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.treeTitle),
        actions: [
          if (visiblePending.isNotEmpty)
            IconButton(
              tooltip: l10n.treePendingTitle,
              icon: Badge(label: Text('${visiblePending.length}'), child: const Icon(Icons.pending_actions)),
              onPressed: () => _showPending(context, ref, familyId, t!, visiblePending, admin),
            ),
        ],
      ),
      floatingActionButton: admin
          ? FloatingActionButton.extended(
              heroTag: 'tree-add',
              onPressed: () => showPersonForm(context, familyId: familyId),
              icon: const Icon(Icons.person_add_alt),
              label: Text(l10n.treeAddPerson),
            )
          : null,
      body: AsyncValueView(
        value: tree,
        onRetry: () => ref.invalidate(treeDataProvider(familyId)),
        data: (data) {
          final mine = data.personForUser(me);
          return Column(
            children: [
              _TreeCover(familyId: familyId, admin: admin),
              if (mine == null)
                Card(
                  margin: const EdgeInsets.all(AppSpacing.md),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.badge_outlined),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(l10n.treeCreateOwnTitle, style: Theme.of(context).textTheme.titleSmall),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(l10n.treeCreateOwnHint),
                        const SizedBox(height: AppSpacing.sm),
                        FilledButton.icon(
                          icon: const Icon(Icons.person_add_alt),
                          onPressed: () async {
                            final profile = await ref
                                .read(myProfileProvider.future)
                                .then<Profile?>((p) => p, onError: (Object _) => null);
                            if (!context.mounted) return;
                            await showPersonForm(
                              context,
                              familyId: familyId,
                              linkSelf: true,
                              initialName: profile?.displayName,
                            );
                          },
                          label: Text(l10n.treeCreateOwnAction),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: data.persons.isEmpty
                    ? MessageView(icon: Icons.account_tree_outlined, title: l10n.treeEmpty, message: l10n.treeEmptyHint)
                    : TreeCanvas(tree: data, highlightId: mine?.id),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showPending(
    BuildContext context,
    WidgetRef ref,
    String familyId,
    TreeData tree,
    List<TreeRelation> pending,
    bool admin,
  ) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final l10n = ctx.l10n;
      String name(String id) => tree.persons[id]?.fullName ?? '?';
      String describe(TreeRelation r) => r.kind == RelationKind.spouse
          ? l10n.treePendingSpouse(name(r.personA), name(r.personB))
          : l10n.treePendingParent(name(r.personA), name(r.personB)) +
                (r.adoptive ? ' (${l10n.treeAdoptiveShort})' : '');
      Future<void> act(Future<void> Function() f) async {
        try {
          await f();
          ref.invalidate(treeDataProvider(familyId));
          if (ctx.mounted) Navigator.of(ctx).pop();
        } catch (e) {
          if (ctx.mounted) ctx.showError(e);
        }
      }

      final repo = ref.read(treeRepositoryProvider);
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Text(l10n.treePendingTitle, style: Theme.of(ctx).textTheme.titleMedium),
          for (final r in pending)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(describe(r)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (admin) ...[
                    IconButton(
                      tooltip: l10n.treeApprove,
                      icon: const Icon(Icons.check_circle_outline, color: Colors.green),
                      onPressed: () => act(() => repo.reviewRelation(r.id, approve: true)),
                    ),
                    IconButton(
                      tooltip: l10n.treeReject,
                      icon: Icon(Icons.cancel_outlined, color: Theme.of(ctx).colorScheme.error),
                      onPressed: () => act(() => repo.reviewRelation(r.id, approve: false)),
                    ),
                  ] else
                    TextButton(onPressed: () => act(() => repo.deleteRelation(r.id)), child: Text(l10n.treeWithdraw)),
                ],
              ),
            ),
        ],
      );
    },
  );
}

/// Generations drawn as rows of cards with parent→child connectors and
/// spouse links. Pinch to zoom, drag to pan.
class TreeCanvas extends StatelessWidget {
  const TreeCanvas({required this.tree, this.highlightId, super.key});

  final TreeData tree;
  final String? highlightId;

  static const cardW = 116.0;
  static const cardH = 108.0;
  static const gapX = 20.0;
  static const gapY = 64.0;
  static const pad = 24.0;

  @override
  Widget build(BuildContext context) {
    final rows = tree.layoutRows();
    final widest = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    final width = pad * 2 + widest * cardW + (widest - 1).clamp(0, 1 << 20) * gapX;
    final height = pad * 2 + rows.length * cardH + (rows.length - 1).clamp(0, 1 << 20) * gapY;
    final pos = <String, Offset>{};
    for (var g = 0; g < rows.length; g++) {
      final rowW = rows[g].length * cardW + (rows[g].length - 1) * gapX;
      final startX = (width - rowW) / 2;
      for (var i = 0; i < rows[g].length; i++) {
        pos[rows[g][i]] = Offset(startX + i * (cardW + gapX), pad + g * (cardH + gapY));
      }
    }
    final scheme = Theme.of(context).colorScheme;
    return InteractiveViewer(
      constrained: false,
      minScale: 0.25,
      maxScale: 2.5,
      boundaryMargin: const EdgeInsets.all(200),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _LinksPainter(tree: tree, pos: pos, color: scheme.outline, spouseColor: scheme.primary),
              ),
            ),
            for (final e in pos.entries)
              Positioned(
                left: e.value.dx,
                top: e.value.dy,
                width: cardW,
                height: cardH,
                child: _PersonCard(person: tree.persons[e.key]!, highlight: e.key == highlightId),
              ),
          ],
        ),
      ),
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.person, required this.highlight});

  final TreePerson person;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = person.gender == Gender.male ? Colors.blue : Colors.pink;
    final years = person.isDeceased
        ? '${person.birthDate.year} – ${person.deathDate!.year}'
        : '${person.birthDate.year}';
    return Material(
      color: highlight ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent.withValues(alpha: 0.6), width: highlight ? 2.5 : 1.2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push(Routes.treePerson(person.id)),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              StorageAvatar(
                radius: 17,
                bucket: TreeRepository.photoBucket,
                path: person.photoPath,
                initials: person.initials,
              ),
              const SizedBox(height: 4),
              Text(
                person.fullName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5, height: 1.15),
              ),
              const SizedBox(height: 2),
              Text(person.isDeceased ? '✝︎ $years' : years, style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinksPainter extends CustomPainter {
  _LinksPainter({required this.tree, required this.pos, required this.color, required this.spouseColor});

  final TreeData tree;
  final Map<String, Offset> pos;
  final Color color;
  final Color spouseColor;

  @override
  void paint(Canvas canvas, Size size) {
    const w = TreeCanvas.cardW, h = TreeCanvas.cardH;
    final line = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final dashed = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final spouse = Paint()
      ..color = spouseColor.withValues(alpha: 0.8)
      ..strokeWidth = 2;
    for (final r in tree.relations.where((r) => r.confirmed)) {
      final a = pos[r.personA], b = pos[r.personB];
      if (a == null || b == null) continue;
      if (r.kind == RelationKind.spouse) {
        final left = a.dx < b.dx ? a : b, right = a.dx < b.dx ? b : a;
        final y = left.dy + h / 2;
        canvas.drawLine(Offset(left.dx + w, y), Offset(right.dx, y), spouse);
      } else {
        final from = Offset(a.dx + w / 2, a.dy + h);
        final to = Offset(b.dx + w / 2, b.dy);
        final midY = from.dy + (to.dy - from.dy) / 2;
        final path = Path()
          ..moveTo(from.dx, from.dy)
          ..lineTo(from.dx, midY)
          ..lineTo(to.dx, midY)
          ..lineTo(to.dx, to.dy);
        canvas.drawPath(path, r.adoptive ? dashed : line);
      }
    }
  }

  @override
  bool shouldRepaint(_LinksPainter old) => old.tree != tree || old.pos != pos || old.color != color;
}

/// Cover photo of the tree. Admins add, change or remove it.
class _TreeCover extends ConsumerStatefulWidget {
  const _TreeCover({required this.familyId, required this.admin});

  final String familyId;
  final bool admin;

  @override
  ConsumerState<_TreeCover> createState() => _TreeCoverState();
}

class _TreeCoverState extends ConsumerState<_TreeCover> {
  bool _busy = false;

  Future<void> _edit(String? current) async {
    final l10n = context.l10n;
    final action = await choosePhotoAction(context, hasPhoto: current != null);
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
        await repo.removeTreePhoto(widget.familyId, current);
      } else {
        final picked = await pickTreeImage(context, action, maxWidth: 1600);
        if (picked == null) return;
        setState(() => _busy = true);
        await repo.setTreePhoto(widget.familyId, picked.$1, picked.$2, previousPath: current);
      }
      ref.invalidate(familyProvider(widget.familyId));
      if (mounted) context.showMessage(l10n.saved);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final path = ref.watch(familyProvider(widget.familyId)).value?.treePhotoPath;
    if (path == null) {
      if (!widget.admin) return const SizedBox.shrink();
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: AppSpacing.sm),
          child: TextButton.icon(
            onPressed: _busy ? null : () => _edit(null),
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(l10n.treeAddCover),
          ),
        ),
      );
    }
    return SizedBox(
      height: 150,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          TreeImage(path: path),
          if (widget.admin)
            Positioned(
              right: AppSpacing.sm,
              bottom: AppSpacing.sm,
              child: IconButton.filledTonal(
                tooltip: l10n.treeChangeCover,
                onPressed: _busy ? null : () => _edit(path),
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.photo_camera_outlined),
              ),
            ),
        ],
      ),
    );
  }
}
