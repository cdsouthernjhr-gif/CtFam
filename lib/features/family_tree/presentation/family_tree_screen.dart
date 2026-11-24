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
import '../domain/tree_layout.dart';
import '../domain/tree_models.dart';
import 'person_form_sheet.dart';
import 'person_screen.dart';
import 'relation_sheet.dart';
import 'tree_print_screen.dart';
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
    final adminFamilies = {
      for (final m in ref.watch(sessionControllerProvider.select((s) => s.activeMemberships)))
        if (isTreeAdmin(m.role)) m.familyId,
    };
    final t = tree.value;
    final pending = t?.pending ?? const <TreeRelation>[];
    // Relations waiting for a family I administer, plus my own proposals.
    final visiblePending = pending
        .where((r) => r.awaitingFamilies.any(adminFamilies.contains) || r.proposedBy == me)
        .toList();
    final mergesForMe = (t?.merges ?? const <PersonMerge>[])
        .where((m) => adminFamilies.contains(t!.persons[m.keepId]?.familyId))
        .toList();
    final waiting = visiblePending.length + mergesForMe.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.treeTitle),
        actions: [
          if (t != null && t.persons.isNotEmpty)
            IconButton(
              key: const Key('tree.pdf'),
              tooltip: l10n.treeDownloadPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () => _exportPdf(context, ref, familyId, t),
            ),
          if (adminFamilies.isNotEmpty && t != null)
            IconButton(
              tooltip: l10n.treeMergeTitle,
              icon: const Icon(Icons.merge_type),
              onPressed: () => _showMergeSuggestions(context, ref, familyId),
            ),
          if (waiting > 0)
            IconButton(
              tooltip: l10n.treePendingTitle,
              icon: Badge(label: Text('$waiting'), child: const Icon(Icons.pending_actions)),
              onPressed: () => _showPending(context, ref, familyId, t!, visiblePending, mergesForMe, adminFamilies, me),
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
                    : TreeCanvas(
                        tree: data,
                        highlightId: mine?.id,
                        onLongPress: adminFamilies.isEmpty
                            ? null
                            : (p) =>
                                  _personActions(context, ref, familyId, data, p, adminFamilies.contains(p.familyId)),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Owner/admin quick editing from the chart (long-press on a card).
  Future<void> _personActions(
    BuildContext context,
    WidgetRef ref,
    String familyId,
    TreeData tree,
    TreePerson person,
    bool homeAdmin,
  ) async {
    final l10n = context.l10n;
    final activeAdmin = isTreeAdmin(ref.read(myRoleProvider));
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(person.fullName, style: Theme.of(ctx).textTheme.titleMedium)),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text(l10n.treeOpenPerson),
                onTap: () => Navigator.of(ctx).pop('open'),
              ),
              if (homeAdmin)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(l10n.treeEditPerson),
                  onTap: () => Navigator.of(ctx).pop('edit'),
                ),
              ListTile(
                leading: const Icon(Icons.north),
                title: Text(l10n.treeAddParent),
                onTap: () => Navigator.of(ctx).pop('parent'),
              ),
              ListTile(
                leading: const Icon(Icons.south),
                title: Text(l10n.treeAddChild),
                onTap: () => Navigator.of(ctx).pop('child'),
              ),
              ListTile(
                leading: const Icon(Icons.favorite_border),
                title: Text(l10n.treeAddSpouse),
                onTap: () => Navigator.of(ctx).pop('spouse'),
              ),
              if (homeAdmin)
                ListTile(
                  leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                  title: Text(l10n.treeDeletePerson, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                  onTap: () => Navigator.of(ctx).pop('delete'),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'open':
        await context.push(Routes.treePerson(person.id));
      case 'edit':
        await showPersonForm(context, familyId: person.familyId, person: person);
      case 'parent' || 'child' || 'spouse':
        await showRelationSheet(
          context,
          familyId: familyId,
          person: person,
          tree: tree,
          isAdmin: activeAdmin,
          initial: switch (action) {
            'parent' => RelationChoice.parent,
            'spouse' => RelationChoice.spouse,
            _ => RelationChoice.child,
          },
        );
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: l10n.treeDeletePerson,
          message: l10n.treeDeletePersonMessage(person.fullName),
          confirmLabel: l10n.actionDelete,
          destructive: true,
        );
        if (!ok) return;
        try {
          await ref.read(treeRepositoryProvider).deletePerson(person.id, photoPath: person.photoPath);
          ref.invalidate(treeDataProvider(familyId));
        } catch (e) {
          if (context.mounted) context.showError(e);
        }
    }
  }

  /// Print options (scope, generations, style), then an A4 print preview
  /// from which it can be printed or shared.
  Future<void> _exportPdf(BuildContext context, WidgetRef ref, String familyId, TreeData tree) =>
      printFamilyTree(context, tree, ref.read(familyProvider(familyId)).value?.name ?? context.l10n.treeTitle);

  Future<void> _showPending(
    BuildContext context,
    WidgetRef ref,
    String familyId,
    TreeData tree,
    List<TreeRelation> pending,
    List<PersonMerge> merges,
    Set<String> adminFamilies,
    String? me,
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
      String? waitingFor(TreeRelation r) {
        final others = r.awaitingFamilies
            .where((f) => !adminFamilies.contains(f))
            .map((f) => tree.familyNames[f] ?? '?');
        return others.isEmpty ? null : l10n.treeWaitingFor(others.join(', '));
      }

      Future<void> act(Future<void> Function() f) async {
        try {
          await f();
          ref.invalidate(treeDataProvider(familyId));
          if (ctx.mounted) Navigator.of(ctx).pop();
        } catch (e) {
          if (ctx.mounted) ctx.showError(e);
        }
      }

      Widget approveReject(Future<void> Function() yes, Future<void> Function() no) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.treeApprove,
            icon: const Icon(Icons.check_circle_outline, color: Colors.green),
            onPressed: () => act(yes),
          ),
          IconButton(
            tooltip: l10n.treeReject,
            icon: Icon(Icons.cancel_outlined, color: Theme.of(ctx).colorScheme.error),
            onPressed: () => act(no),
          ),
        ],
      );

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
              subtitle: waitingFor(r) == null ? null : Text(waitingFor(r)!),
              trailing: r.awaitingFamilies.any(adminFamilies.contains)
                  ? approveReject(
                      () => repo.reviewRelation(r.id, approve: true),
                      () => repo.reviewRelation(r.id, approve: false),
                    )
                  : TextButton(onPressed: () => act(() => repo.deleteRelation(r.id)), child: Text(l10n.treeWithdraw)),
            ),
          for (final m in merges)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.merge_type),
              title: Text(l10n.treeMergeRequest(name(m.removeId), name(m.keepId))),
              subtitle: Text(tree.familyNames[tree.persons[m.removeId]?.familyId] ?? ''),
              trailing: approveReject(
                () => repo.reviewMerge(m.id, approve: true),
                () => repo.reviewMerge(m.id, approve: false),
              ),
            ),
        ],
      );
    },
  );

  Future<void> _showMergeSuggestions(BuildContext context, WidgetRef ref, String familyId) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => Consumer(
          builder: (ctx, ref, _) {
            final l10n = ctx.l10n;
            final suggestions = ref.watch(mergeSuggestionsProvider(familyId));
            return Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.treeMergeTitle, style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(l10n.treeMergeHint, style: Theme.of(ctx).textTheme.bodySmall),
                  AsyncValueView(
                    value: suggestions,
                    onRetry: () => ref.invalidate(mergeSuggestionsProvider(familyId)),
                    data: (list) => list.isEmpty
                        ? Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Text(l10n.treeMergeNone))
                        : Column(
                            children: [
                              for (final s in list)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text('${s.removeName} → ${s.keepName}'),
                                  subtitle: Text('${s.removeFamily} → ${s.keepFamily}'),
                                  trailing: TextButton(
                                    onPressed: () async {
                                      try {
                                        final status = await ref
                                            .read(treeRepositoryProvider)
                                            .mergePersons(keepId: s.keepId, removeId: s.removeId);
                                        ref.invalidate(treeDataProvider(familyId));
                                        ref.invalidate(mergeSuggestionsProvider(familyId));
                                        if (ctx.mounted) {
                                          ctx.showMessage(status == 'done' ? l10n.treeMerged : l10n.treeMergeRequested);
                                        }
                                      } catch (e) {
                                        if (ctx.mounted) ctx.showError(e);
                                      }
                                    },
                                    child: Text(l10n.treeMergeAction),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      );
}

/// Generations drawn as rows of cards with parent→child connectors and
/// spouse links. Pinch or use the buttons to zoom, drag to pan, double-tap to
/// zoom in/out. Starts fitted to the screen width.
class TreeCanvas extends StatefulWidget {
  const TreeCanvas({required this.tree, this.highlightId, this.onLongPress, super.key});

  final TreeData tree;
  final String? highlightId;

  /// Long-press on a card (owner/admin editing menu); null = disabled.
  final void Function(TreePerson person)? onLongPress;

  static const cardW = TreeLayout.cardW;
  static const cardH = TreeLayout.cardH;

  @override
  State<TreeCanvas> createState() => _TreeCanvasState();
}

class _TreeCanvasState extends State<TreeCanvas> {
  static const minScale = 0.2;
  static const maxScale = 3.0;
  final _ctrl = TransformationController();
  Size? _viewport;
  bool _fitted = false;
  Offset? _doubleTapAt;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // getMaxScaleOnAxis() also looks at the z axis (always 1), so read x directly.
  double get _scale => _ctrl.value.storage[0];

  void _fit(TreeLayout layout) {
    final vp = _viewport;
    if (vp == null || layout.width == 0) return;
    final s = (vp.width / layout.width).clamp(minScale, 1.0);
    final dx = ((vp.width - layout.width * s) / 2).clamp(0.0, double.infinity);
    _ctrl.value = Matrix4.identity()
      ..translateByDouble(dx, 0, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  /// Zooms by [factor] around the centre of the screen.
  void _zoom(double factor) {
    final vp = _viewport;
    if (vp == null) return;
    final target = (_scale * factor).clamp(minScale, maxScale);
    final f = target / _scale;
    final c = Offset(vp.width / 2, vp.height / 2);
    _ctrl.value = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1)
      ..multiply(_ctrl.value);
  }

  void _onDoubleTap() {
    final at = _doubleTapAt;
    if (at == null) return;
    if (_scale >= 1.4) {
      _fit(TreeLayout.of(widget.tree));
      return;
    }
    final f = (2.0 / _scale).clamp(1.0, maxScale / _scale);
    _ctrl.value = Matrix4.identity()
      ..translateByDouble(at.dx, at.dy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-at.dx, -at.dy, 0, 1)
      ..multiply(_ctrl.value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final layout = TreeLayout.of(widget.tree);
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        if (!_fitted) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fit(layout);
          });
        }
        return Stack(
          children: [
            GestureDetector(
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: _onDoubleTap,
              child: InteractiveViewer(
                key: const Key('tree.viewer'),
                transformationController: _ctrl,
                constrained: false,
                minScale: minScale,
                maxScale: maxScale,
                boundaryMargin: const EdgeInsets.all(400),
                child: SizedBox(
                  width: layout.width,
                  height: layout.height,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _LinksPainter(
                            links: layout.links(widget.tree),
                            color: scheme.outline,
                            spouseColor: scheme.primary,
                          ),
                        ),
                      ),
                      for (final e in layout.positions.entries)
                        Positioned(
                          left: e.value.x,
                          top: e.value.y,
                          width: TreeLayout.cardW,
                          height: TreeLayout.cardH,
                          child: _PersonCard(
                            person: widget.tree.persons[e.key]!,
                            highlight: e.key == widget.highlightId,
                            onLongPress: widget.onLongPress,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: AppSpacing.sm,
              bottom: AppSpacing.sm + 72, // above the "Add person" button
              child: Card(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(tooltip: l10n.treeZoomIn, icon: const Icon(Icons.add), onPressed: () => _zoom(1.3)),
                    IconButton(
                      tooltip: l10n.treeZoomOut,
                      icon: const Icon(Icons.remove),
                      onPressed: () => _zoom(1 / 1.3),
                    ),
                    IconButton(
                      tooltip: l10n.treeZoomFit,
                      icon: const Icon(Icons.fit_screen_outlined),
                      onPressed: () => _fit(layout),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PersonCard extends StatelessWidget {
  const _PersonCard({required this.person, required this.highlight, this.onLongPress});

  final TreePerson person;
  final bool highlight;
  final void Function(TreePerson person)? onLongPress;

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
        key: ValueKey('tree-card-${person.id}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push(Routes.treePerson(person.id)),
        onLongPress: onLongPress == null ? null : () => onLongPress!(person),
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
  _LinksPainter({required this.links, required this.color, required this.spouseColor});

  final List<({List<({double x, double y})> points, RelationKind kind, bool adoptive})> links;
  final Color color;
  final Color spouseColor;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final adoptive = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final spouse = Paint()
      ..color = spouseColor.withValues(alpha: 0.8)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final l in links) {
      final path = Path()..moveTo(l.points.first.x, l.points.first.y);
      for (final p in l.points.skip(1)) {
        path.lineTo(p.x, p.y);
      }
      canvas.drawPath(path, l.kind == RelationKind.spouse ? spouse : (l.adoptive ? adoptive : line));
    }
  }

  @override
  bool shouldRepaint(_LinksPainter old) => old.links != links || old.color != color;
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
