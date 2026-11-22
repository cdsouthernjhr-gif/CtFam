import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/todo_repository.dart';
import '../domain/todo_models.dart';
import 'todo_providers.dart';
import 'todo_ui.dart';

/// Create ([item] null) or edit an item; existing items also show comments.
Future<void> showTodoItemSheet(BuildContext context, {required String listId, TodoItem? item}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => TodoItemSheet(listId: listId, item: item),
    );

class TodoItemSheet extends ConsumerStatefulWidget {
  const TodoItemSheet({required this.listId, this.item, super.key});

  final String listId;
  final TodoItem? item;

  @override
  ConsumerState<TodoItemSheet> createState() => _TodoItemSheetState();
}

class _TodoItemSheetState extends ConsumerState<TodoItemSheet> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.item?.title ?? '');
  late final _description = TextEditingController(text: widget.item?.description ?? '');
  final _comment = TextEditingController();
  late TodoPriority _priority = widget.item?.priority ?? TodoPriority.normal;
  late DateTime? _due = widget.item?.dueAt;
  late TodoRecurrence _recurrence = widget.item?.recurrence ?? TodoRecurrence.none;
  late final Set<String> _assignees = {...?widget.item?.assigneeIds};
  bool _busy = false;

  bool get _isNew => widget.item == null;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: _due != null ? TimeOfDay.fromDateTime(_due!) : const TimeOfDay(hour: 9, minute: 0),
    );
    setState(() => _due = DateTime(date.year, date.month, date.day, time?.hour ?? 0, time?.minute ?? 0));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    try {
      await ref
          .read(todoListControllerProvider(widget.listId).notifier)
          .saveItem(
            original: widget.item,
            title: _title.text,
            description: _description.text,
            priority: _priority,
            dueAt: _due,
            recurrence: _due == null ? TodoRecurrence.none : _recurrence,
            assigneeIds: _assignees.toList(),
          );
      nav.pop();
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final ok = await confirmDialog(
      context,
      title: l10n.deleteTaskTitle,
      message: widget.item!.title,
      destructive: true,
      confirmLabel: l10n.actionDelete,
    );
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    try {
      await ref.read(todoListControllerProvider(widget.listId).notifier).deleteItem(widget.item!);
      nav.pop();
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  Future<void> _sendComment(String familyId) async {
    final body = _comment.text.trim();
    if (body.isEmpty || widget.item == null) return;
    _comment.clear();
    try {
      await ref
          .read(todoRepositoryProvider)
          .addComment(id: newTodoId(), item: widget.item!, familyId: familyId, body: body);
      ref.invalidate(todoCommentsProvider((listId: widget.listId, itemId: widget.item!.id)));
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final familyId = ref.watch(activeFamilyIdProvider) ?? '';
    final members = (ref.watch(familyMembersProvider(familyId)).value ?? const <FamilyMember>[])
        .where((m) => m.status == MemberStatus.active)
        .toList();
    final me = ref.watch(currentUserIdProvider);
    final role = ref.watch(myRoleProvider);
    final list = ref.watch(todoListControllerProvider(widget.listId)).value?.list;
    final canDelete =
        !_isNew &&
        (widget.item!.createdBy == me || list?.createdBy == me || role == FamilyRole.owner || role == FamilyRole.admin);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: _isNew ? 0.75 : 0.9,
        maxChildSize: 0.95,
        builder: (context, scroll) => Form(
          key: _form,
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
            children: [
              Row(
                children: [
                  Expanded(child: Text(_isNew ? l10n.newTask : l10n.editTask, style: theme.textTheme.titleLarge)),
                  if (canDelete)
                    IconButton(
                      tooltip: l10n.actionDelete,
                      icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                      onPressed: _delete,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                key: const Key('todoItem.title'),
                controller: _title,
                autofocus: _isNew,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: l10n.taskTitle),
                validator: (v) => (v ?? '').trim().isEmpty ? l10n.validationRequired : null,
              ),
              TextFormField(
                controller: _description,
                maxLength: 2000,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(labelText: l10n.fieldDescription),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(l10n.priority, style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              SegmentedButton<TodoPriority>(
                segments: [
                  for (final p in TodoPriority.values)
                    ButtonSegment(
                      value: p,
                      label: Text(priorityLabel(l10n, p), overflow: TextOverflow.ellipsis),
                    ),
                ],
                selected: {_priority},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _priority = s.first),
              ),
              const SizedBox(height: AppSpacing.md),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: Text(_due == null ? l10n.noDueDate : dueLabel(l10n, _due!, DateTime.now())),
                subtitle: _due == null ? null : Text(context.formatDateTime(_due!)),
                trailing: _due == null
                    ? null
                    : IconButton(
                        tooltip: l10n.clearDueDate,
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _due = null),
                      ),
                onTap: _pickDue,
              ),
              if (_due != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.repeat),
                  title: Text(l10n.repeat),
                  trailing: DropdownButton<TodoRecurrence>(
                    value: _recurrence,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final r in TodoRecurrence.values)
                        DropdownMenuItem(value: r, child: Text(recurrenceLabel(l10n, r))),
                    ],
                    onChanged: (r) => setState(() => _recurrence = r ?? TodoRecurrence.none),
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              Text(l10n.assignTo, style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final m in members)
                    FilterChip(
                      label: Text(m.userId == me ? '${m.displayName} (${l10n.you})' : m.displayName),
                      selected: _assignees.contains(m.userId),
                      onSelected: (v) => setState(() => v ? _assignees.add(m.userId) : _assignees.remove(m.userId)),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                key: const Key('todoItem.save'),
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Text(_isNew ? l10n.addTask : l10n.actionSave),
              ),
              if (!_isNew) ...[
                const Divider(height: AppSpacing.xl),
                Text(l10n.comments, style: theme.textTheme.titleMedium),
                _Comments(listId: widget.listId, itemId: widget.item!.id),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _comment,
                        maxLength: 2000,
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(hintText: l10n.writeComment, counterText: ''),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.send,
                      icon: const Icon(Icons.send),
                      onPressed: () => _sendComment(familyId),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Comments extends ConsumerWidget {
  const _Comments({required this.listId, required this.itemId});

  final String listId;
  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final comments = ref.watch(todoCommentsProvider((listId: listId, itemId: itemId)));
    return comments.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(padding: const EdgeInsets.all(AppSpacing.sm), child: Text(context.errorText(e))),
      data: (list) => list.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(l10n.noComments),
            )
          : Column(
              children: [
                for (final c in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(c.authorName ?? l10n.someone, style: Theme.of(context).textTheme.labelLarge),
                    subtitle: Text(c.body),
                    trailing: Text(context.formatDateTime(c.createdAt), style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
    );
  }
}
