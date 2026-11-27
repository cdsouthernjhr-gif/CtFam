import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../family/presentation/family_providers.dart';
import '../../family_tree/presentation/tree_photo.dart' show PhotoAction, choosePhotoAction, pickTreeImage;
import '../data/todo_repository.dart';
import '../domain/todo_models.dart';
import 'todo_providers.dart';

/// An image from the private To-Do bucket (signed URL).
class TodoImage extends ConsumerWidget {
  const TodoImage({required this.path, this.fit = BoxFit.cover, super.key});

  final String path;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(signedUrlProvider((bucket: TodoRepository.photoBucket, path: path)));
    final scheme = Theme.of(context).colorScheme;
    return url.maybeWhen(
      data: (u) => Image.network(
        u,
        fit: fit,
        errorBuilder: (_, _, _) => ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Icon(Icons.broken_image_outlined, color: scheme.outline),
        ),
      ),
      orElse: () => ColoredBox(color: scheme.surfaceContainerHighest),
    );
  }
}

String photoKindLabel(BuildContext context, TodoPhotoKind k) =>
    k == TodoPhotoKind.before ? context.l10n.photoBefore : context.l10n.photoAfter;

/// Before / after photos of an item (optional, up to 4 each). Shown in the
/// item sheet for existing items; follows live changes of the item.
class TodoPhotoSection extends ConsumerStatefulWidget {
  const TodoPhotoSection({required this.listId, required this.item, super.key});

  final String listId;
  final TodoItem item;

  @override
  ConsumerState<TodoPhotoSection> createState() => _TodoPhotoSectionState();
}

class _TodoPhotoSectionState extends ConsumerState<TodoPhotoSection> {
  TodoPhotoKind? _busy;

  TodoItem get _item =>
      ref.watch(todoListControllerProvider(widget.listId).select((s) => s.value?.items[widget.item.id])) ?? widget.item;

  Future<void> _add(TodoPhotoKind kind) async {
    final action = await choosePhotoAction(context, hasPhoto: false);
    if (action == null || action == PhotoAction.remove || !mounted) return;
    final picked = await pickTreeImage(context, action, maxWidth: 1600);
    if (picked == null || !mounted) return;
    final familyId = ref.read(todoListControllerProvider(widget.listId)).value?.list.familyId;
    if (familyId == null) return;
    setState(() => _busy = kind);
    try {
      await ref.read(todoRepositoryProvider).addItemPhoto(_itemNow, familyId, kind, picked.$1, picked.$2);
      await ref.read(todoListControllerProvider(widget.listId).notifier).reloadItem(widget.item.id);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  TodoItem get _itemNow =>
      ref.read(todoListControllerProvider(widget.listId)).value?.items[widget.item.id] ?? widget.item;

  Future<void> _open(List<TodoItemPhoto> photos, int index) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => TodoPhotoViewer(listId: widget.listId, itemId: widget.item.id, photos: photos, initial: index),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final item = _item;
    final before = item.photosOf(TodoPhotoKind.before);
    final after = item.photosOf(TodoPhotoKind.after);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(l10n.photosTitle, style: theme.textTheme.titleMedium)),
            if (before.isNotEmpty && after.isNotEmpty)
              TextButton.icon(
                key: const ValueKey('todo.compare'),
                icon: const Icon(Icons.compare),
                label: Text(l10n.photoCompare),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    fullscreenDialog: true,
                    builder: (_) => TodoPhotoCompare(before: before, after: after),
                  ),
                ),
              ),
          ],
        ),
        Text(l10n.photosOptionalHint, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        for (final (kind, photos) in [(TodoPhotoKind.before, before), (TodoPhotoKind.after, after)]) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${photoKindLabel(context, kind)} (${photos.length}/${TodoItemPhoto.maxPerKind})',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            height: 76,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < photos.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: InkWell(
                      key: ValueKey('todo-photo-${photos[i].id}'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _open(photos, i),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(width: 76, height: 76, child: TodoImage(path: photos[i].path)),
                      ),
                    ),
                  ),
                if (photos.length < TodoItemPhoto.maxPerKind)
                  SizedBox(
                    width: 76,
                    child: OutlinedButton(
                      key: ValueKey('todo.addPhoto.${kind.name}'),
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _busy != null ? null : () => _add(kind),
                      child: _busy == kind
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : Semantics(
                              label: l10n.photoAdd(photoKindLabel(context, kind)),
                              child: const Icon(Icons.add_a_photo_outlined),
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Full-screen photos with zoom; each can be deleted.
class TodoPhotoViewer extends ConsumerStatefulWidget {
  const TodoPhotoViewer({
    required this.listId,
    required this.itemId,
    required this.photos,
    required this.initial,
    super.key,
  });

  final String listId;
  final String itemId;
  final List<TodoItemPhoto> photos;
  final int initial;

  @override
  ConsumerState<TodoPhotoViewer> createState() => _TodoPhotoViewerState();
}

class _TodoPhotoViewerState extends ConsumerState<TodoPhotoViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final photo = widget.photos[_index];
    final ok = await confirmDialog(
      context,
      title: l10n.photoDeleteTitle,
      message: photoKindLabel(context, photo.kind),
      destructive: true,
      confirmLabel: l10n.actionDelete,
    );
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    try {
      await ref.read(todoRepositoryProvider).deleteItemPhoto(photo.id);
      await ref.read(todoListControllerProvider(widget.listId).notifier).reloadItem(widget.itemId);
      nav.pop();
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${photoKindLabel(context, photo.kind)} · ${_index + 1}/${widget.photos.length}'),
        actions: [
          IconButton(
            key: const ValueKey('todo.deletePhoto'),
            tooltip: context.l10n.actionDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      body: PageView(
        controller: _pages,
        onPageChanged: (i) => setState(() => _index = i),
        children: [
          for (final p in widget.photos)
            InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: TodoImage(path: p.path, fit: BoxFit.contain),
              ),
            ),
        ],
      ),
    );
  }
}

/// Before and after side by side (above each other in portrait).
class TodoPhotoCompare extends StatefulWidget {
  const TodoPhotoCompare({required this.before, required this.after, super.key});

  final List<TodoItemPhoto> before;
  final List<TodoItemPhoto> after;

  @override
  State<TodoPhotoCompare> createState() => _TodoPhotoCompareState();
}

class _TodoPhotoCompareState extends State<TodoPhotoCompare> {
  var _b = 0;
  var _a = 0;

  Widget _side(BuildContext context, TodoPhotoKind kind, List<TodoItemPhoto> photos, int index, ValueChanged<int> on) =>
      Expanded(
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView(
              onPageChanged: on,
              children: [
                for (final p in photos)
                  InteractiveViewer(
                    maxScale: 5,
                    child: Center(
                      child: TodoImage(path: p.path, fit: BoxFit.contain),
                    ),
                  ),
              ],
            ),
            Positioned(
              left: AppSpacing.sm,
              top: AppSpacing.sm,
              child: Chip(
                label: Text(
                  photos.length > 1
                      ? '${photoKindLabel(context, kind)} ${index + 1}/${photos.length}'
                      : photoKindLabel(context, kind),
                ),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final children = [
      _side(context, TodoPhotoKind.before, widget.before, _b, (i) => setState(() => _b = i)),
      const SizedBox(width: 2, height: 2),
      _side(context, TodoPhotoKind.after, widget.after, _a, (i) => setState(() => _a = i)),
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(context.l10n.photoCompare),
      ),
      body: portrait ? Column(children: children) : Row(children: children),
    );
  }
}

/// Cover photo menu for a list (creator or family owner/admin).
Future<void> editTodoListCover(BuildContext context, WidgetRef ref, TodoList list) async {
  final action = await choosePhotoAction(context, hasPhoto: list.coverPath != null);
  if (action == null || !context.mounted) return;
  final repo = ref.read(todoRepositoryProvider);
  try {
    if (action == PhotoAction.remove) {
      await repo.removeListCover(list);
    } else {
      final picked = await pickTreeImage(context, action, maxWidth: 1600);
      if (picked == null) return;
      await repo.setListCover(list, picked.$1, picked.$2);
    }
    await ref.read(todoListControllerProvider(list.id).notifier).refresh();
  } catch (e) {
    if (context.mounted) context.showError(e);
  }
}
