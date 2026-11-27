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
import '../data/todo_repository.dart';
import '../domain/todo_logic.dart';
import '../domain/todo_models.dart';
import 'todo_item_sheet.dart';
import 'todo_photos.dart';
import 'todo_providers.dart';
import 'todo_ui.dart';

class TodoListScreen extends ConsumerStatefulWidget {
  const TodoListScreen({required this.listId, super.key});

  final String listId;

  @override
  ConsumerState<TodoListScreen> createState() => _TodoListScreenState();
}

class _TodoListScreenState extends ConsumerState<TodoListScreen> {
  final _quickAdd = TextEditingController();
  final _search = TextEditingController();
  TodoFilter _filter = const TodoFilter();
  bool _searching = false;
  bool _showCompleted = true;

  @override
  void dispose() {
    _quickAdd.dispose();
    _search.dispose();
    super.dispose();
  }

  TodoListController get _ctrl => ref.read(todoListControllerProvider(widget.listId).notifier);

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  void _addQuick() {
    final title = _quickAdd.text.trim();
    if (title.isEmpty) return;
    _quickAdd.clear();
    _run(() => _ctrl.saveItem(title: title));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(todoListControllerProvider(widget.listId));
    final familyId = ref.watch(activeFamilyIdProvider);
    final members = familyId == null
        ? const <FamilyMember>[]
        : (ref.watch(familyMembersProvider(familyId)).value ?? const <FamilyMember>[]);
    final memberById = {for (final m in members) m.userId: m};
    final me = ref.watch(currentUserIdProvider);
    final role = ref.watch(myRoleProvider);

    return async.when(
      loading: () => Scaffold(appBar: AppBar(), body: const LoadingView()),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: ErrorView(error: e, onRetry: () => ref.invalidate(todoListControllerProvider(widget.listId))),
      ),
      data: (state) {
        if (state.deleted) {
          return Scaffold(
            appBar: AppBar(),
            body: MessageView(
              icon: Icons.delete_outline,
              title: l10n.listDeleted,
              action: FilledButton(onPressed: () => context.go('/todo'), child: Text(l10n.backToLists)),
            ),
          );
        }
        final list = state.list;
        final all = state.items.values.toList();
        final progress = progressOf(all);
        final visible = sortItems(all.where((i) => matchesFilter(i, _filter)));
        final open = visible.where((i) => !i.completed).toList();
        final done = visible.where((i) => i.completed).toList();
        final canManage = list.createdBy == me || role == FamilyRole.owner || role == FamilyRole.admin;

        return Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _search,
                    autofocus: true,
                    decoration: InputDecoration(hintText: l10n.searchTasks, border: InputBorder.none, filled: false),
                    onChanged: (q) => setState(() => _filter = _filter.copyWith(query: q)),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(list.name, overflow: TextOverflow.ellipsis),
                      Text(
                        l10n.itemsProgress(progress.completed, progress.total),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
            actions: [
              IconButton(
                tooltip: l10n.searchTasks,
                icon: Icon(_searching ? Icons.close : Icons.search),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) {
                    _search.clear();
                    _filter = _filter.copyWith(query: '');
                  }
                }),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'activity':
                      context.go('/todo/${widget.listId}/activity');
                    case 'rename':
                      await _rename(list);
                    case 'cover':
                      await editTodoListCover(context, ref, list);
                    case 'delete':
                      await _delete(list);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'activity', child: Text(l10n.activity)),
                  if (canManage) PopupMenuItem(value: 'rename', child: Text(l10n.renameList)),
                  if (canManage) PopupMenuItem(value: 'cover', child: Text(l10n.listCover)),
                  if (canManage) PopupMenuItem(value: 'delete', child: Text(l10n.deleteList)),
                ],
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(4),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 4,
                color: Theme.of(context).colorScheme.secondary,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
          body: Column(
            children: [
              if (list.coverPath != null)
                SizedBox(
                  key: const ValueKey('todo.cover'),
                  height: 140,
                  width: double.infinity,
                  child: GestureDetector(
                    onTap: canManage ? () => editTodoListCover(context, ref, list) : null,
                    child: TodoImage(path: list.coverPath!),
                  ),
                ),
              _FilterBar(
                filter: _filter,
                members: members.where((m) => m.status == MemberStatus.active).toList(),
                onChanged: (f) => setState(() => _filter = f),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _ctrl.refresh,
                  child: all.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 80),
                            MessageView(icon: Icons.add_task, title: l10n.noTasksTitle, message: l10n.noTasksBody),
                          ],
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                          children: [
                            if (visible.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(AppSpacing.lg),
                                child: Text(l10n.noMatchingTasks, textAlign: TextAlign.center),
                              ),
                            for (final item in open)
                              _ItemTile(
                                item: item,
                                pending: state.pending.contains(item.id),
                                memberById: memberById,
                                onToggle: (v) => _run(() => _ctrl.setCompleted(item, completed: v)),
                                onTap: () => showTodoItemSheet(context, listId: widget.listId, item: item),
                              ),
                            if (done.isNotEmpty)
                              ListTile(
                                dense: true,
                                title: Text(l10n.completedCount(done.length)),
                                trailing: Icon(_showCompleted ? Icons.expand_less : Icons.expand_more),
                                onTap: () => setState(() => _showCompleted = !_showCompleted),
                              ),
                            if (_showCompleted)
                              for (final item in done)
                                _ItemTile(
                                  item: item,
                                  pending: state.pending.contains(item.id),
                                  memberById: memberById,
                                  onToggle: (v) => _run(() => _ctrl.setCompleted(item, completed: v)),
                                  onTap: () => showTodoItemSheet(context, listId: widget.listId, item: item),
                                ),
                          ],
                        ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('todo.quickAdd'),
                          controller: _quickAdd,
                          textCapitalization: TextCapitalization.sentences,
                          maxLength: 200,
                          decoration: InputDecoration(hintText: l10n.addTaskHint, counterText: ''),
                          onSubmitted: (_) => _addQuick(),
                        ),
                      ),
                      IconButton.filled(tooltip: l10n.addTask, icon: const Icon(Icons.add), onPressed: _addQuick),
                      IconButton(
                        tooltip: l10n.addTaskDetailed,
                        icon: const Icon(Icons.edit_note),
                        onPressed: () => showTodoItemSheet(context, listId: widget.listId),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _rename(TodoList list) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: list.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.renameList),
        content: TextField(controller: controller, autofocus: true, maxLength: 80),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.actionCancel)),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(l10n.actionSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _run(() => _ctrl.renameList(name: name, description: list.description));
  }

  Future<void> _delete(TodoList list) async {
    final l10n = context.l10n;
    final ok = await confirmDialog(
      context,
      title: l10n.deleteListTitle(list.name),
      message: l10n.deleteListBody,
      destructive: true,
      confirmLabel: l10n.actionDelete,
    );
    if (!ok || !mounted) return;
    final router = GoRouter.of(context);
    await _run(() async {
      await ref.read(todoRepositoryProvider).deleteList(list.id);
      router.go('/todo');
    });
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.filter, required this.members, required this.onChanged});

  final TodoFilter filter;
  final List<FamilyMember> members;
  final ValueChanged<TodoFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String statusLabel(TodoStatusFilter s) => switch (s) {
      TodoStatusFilter.all => l10n.filterAll,
      TodoStatusFilter.open => l10n.filterOpen,
      TodoStatusFilter.completed => l10n.filterCompleted,
    };
    final selectedMember = members.where((m) => m.userId == filter.memberId).firstOrNull;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        children: [
          for (final s in TodoStatusFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: ChoiceChip(
                label: Text(statusLabel(s)),
                selected: filter.status == s,
                onSelected: (_) => onChanged(filter.copyWith(status: s)),
              ),
            ),
          PopupMenuButton<String?>(
            tooltip: l10n.filterByMember,
            onSelected: (id) =>
                onChanged(id == null ? filter.copyWith(clearMember: true) : filter.copyWith(memberId: id)),
            itemBuilder: (_) => [
              PopupMenuItem<String?>(value: null, child: Text(l10n.everyone)),
              for (final m in members) PopupMenuItem<String?>(value: m.userId, child: Text(m.displayName)),
            ],
            child: Chip(
              avatar: const Icon(Icons.person_search_outlined, size: 18),
              label: Text(selectedMember?.displayName ?? l10n.filterByMember),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.pending,
    required this.memberById,
    required this.onToggle,
    required this.onTap,
  });

  final TodoItem item;
  final bool pending;
  final Map<String, FamilyMember> memberById;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final pColor = priorityColor(theme.colorScheme, item.priority);
    final meta = <Widget>[
      if (item.dueAt != null)
        _Meta(
          icon: Icons.event_outlined,
          text: dueLabel(l10n, item.dueAt!, now),
          color: item.isOverdue(now) ? theme.colorScheme.error : null,
        ),
      if (item.priority == TodoPriority.high || item.priority == TodoPriority.urgent)
        _Meta(icon: Icons.flag_outlined, text: priorityLabel(l10n, item.priority), color: pColor),
      if (item.recurrence != TodoRecurrence.none)
        _Meta(icon: Icons.repeat, text: recurrenceLabel(l10n, item.recurrence)),
      if (item.photos.isNotEmpty) _Meta(icon: Icons.photo_outlined, text: '${item.photos.length}'),
      if (pending) _Meta(icon: Icons.sync, text: l10n.syncing),
    ];
    return ListTile(
      key: ValueKey('todo-item-${item.id}'),
      onTap: onTap,
      leading: Checkbox(value: item.completed, onChanged: (v) => onToggle(v ?? false)),
      title: Text(
        item.title,
        style: item.completed
            ? TextStyle(decoration: TextDecoration.lineThrough, color: theme.colorScheme.onSurfaceVariant)
            : null,
      ),
      subtitle: meta.isEmpty ? null : Wrap(spacing: AppSpacing.md, children: meta),
      trailing: item.assigneeIds.isEmpty
          ? null
          : SizedBox(
              width: 24.0 + 16 * (item.assigneeIds.length.clamp(1, 3) - 1),
              height: 28,
              child: Stack(
                children: [
                  for (var i = 0; i < item.assigneeIds.length && i < 3; i++)
                    Positioned(
                      left: i * 16.0,
                      child: StorageAvatar(
                        radius: 12,
                        initials: memberById[item.assigneeIds[i]]?.profile?.initials ?? '?',
                        path: memberById[item.assigneeIds[i]]?.profile?.avatarPath,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 3),
        Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c)),
      ],
    );
  }
}
