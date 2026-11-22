import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/todo_repository.dart';
import '../domain/todo_models.dart';
import 'todo_providers.dart';
import 'todo_ui.dart';

/// Opens the create-list sheet; returns the new list id.
Future<String?> showTodoListForm(BuildContext context, {required String familyId}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _TodoListForm(familyId: familyId),
);

class _TodoListForm extends ConsumerStatefulWidget {
  const _TodoListForm({required this.familyId});

  final String familyId;

  @override
  ConsumerState<_TodoListForm> createState() => _TodoListFormState();
}

class _TodoListFormState extends ConsumerState<_TodoListForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _id = newTodoId();
  TodoCategory _category = TodoCategory.shopping;
  bool _membersOnly = false;
  final Set<String> _members = {};
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(todoRepositoryProvider)
          .createList(
            id: _id, // stable across retries: create_todo_list is idempotent
            familyId: widget.familyId,
            name: _name.text,
            category: _category,
            description: _description.text,
            membersOnly: _membersOnly,
            memberIds: _members.toList(),
          );
      ref.invalidate(todoSummariesProvider(widget.familyId));
      if (mounted) Navigator.of(context).pop(_id);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final me = ref.watch(currentUserIdProvider);
    final members = ref.watch(familyMembersProvider(widget.familyId)).value ?? const <FamilyMember>[];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.newList, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  key: const Key('todoList.name'),
                  controller: _name,
                  autofocus: true,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: l10n.listName, hintText: l10n.listNameHint),
                  validator: (v) => (v ?? '').trim().isEmpty ? l10n.validationRequired : null,
                ),
                Text(l10n.category, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final c in TodoCategory.values.where((c) => c != TodoCategory.custom))
                      ChoiceChip(
                        avatar: Icon(categoryIcon(c), size: 18),
                        label: Text(categoryLabel(l10n, c)),
                        selected: _category == c,
                        onSelected: (_) => setState(() => _category = c),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _description,
                  maxLength: 500,
                  maxLines: 2,
                  minLines: 1,
                  decoration: InputDecoration(labelText: l10n.fieldDescription),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.membersOnlyList),
                  subtitle: Text(l10n.membersOnlyListHint),
                  value: _membersOnly,
                  onChanged: (v) => setState(() => _membersOnly = v),
                ),
                if (_membersOnly)
                  Wrap(
                    spacing: AppSpacing.sm,
                    children: [
                      for (final m in members.where((m) => m.status == MemberStatus.active && m.userId != me))
                        FilterChip(
                          label: Text(m.displayName),
                          selected: _members.contains(m.userId),
                          onSelected: (v) => setState(() => v ? _members.add(m.userId) : _members.remove(m.userId)),
                        ),
                    ],
                  ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : Text(l10n.createList),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
