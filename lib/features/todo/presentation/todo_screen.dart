import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/providers/session_controller.dart';
import '../domain/todo_models.dart';
import 'todo_list_form_sheet.dart';
import 'todo_providers.dart';
import 'todo_ui.dart';

/// To-Do tab: all lists of the active family with live progress.
class TodoScreen extends ConsumerStatefulWidget {
  const TodoScreen({super.key});

  @override
  ConsumerState<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends ConsumerState<TodoScreen> {
  TodoCategory? _category;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final summaries = ref.watch(todoSummariesProvider(familyId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.todoListsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final id = await showTodoListForm(context, familyId: familyId);
          if (id != null && context.mounted) context.go('/todo/$id');
        },
        icon: const Icon(Icons.playlist_add),
        label: Text(l10n.newList),
      ),
      body: AsyncValueView(
        value: summaries,
        onRetry: () => ref.invalidate(todoSummariesProvider(familyId)),
        data: (lists) {
          if (lists.isEmpty) {
            return MessageView(icon: Icons.checklist_rounded, title: l10n.noListsTitle, message: l10n.noListsBody);
          }
          final categories = {for (final s in lists) s.category}.toList()..sort((a, b) => a.index.compareTo(b.index));
          final shown = _category == null ? lists : lists.where((s) => s.category == _category).toList();
          return RefreshIndicator(
            onRefresh: () async => ref.refresh(todoSummariesProvider(familyId).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 96),
              children: [
                if (categories.length > 1)
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpacing.sm),
                          child: ChoiceChip(
                            label: Text(l10n.filterAll),
                            selected: _category == null,
                            onSelected: (_) => setState(() => _category = null),
                          ),
                        ),
                        for (final c in categories)
                          Padding(
                            padding: const EdgeInsets.only(right: AppSpacing.sm),
                            child: ChoiceChip(
                              avatar: Icon(categoryIcon(c), size: 18),
                              label: Text(categoryLabel(l10n, c)),
                              selected: _category == c,
                              onSelected: (_) => setState(() => _category = _category == c ? null : c),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: AppSpacing.sm),
                for (final s in shown) ...[_ListCard(summary: s), const SizedBox(height: AppSpacing.sm)],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.summary});

  final TodoListSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final s = summary;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go('/todo/${s.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    child: Icon(categoryIcon(s.category), size: 20, color: theme.colorScheme.onSecondaryContainer),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(
                          '${categoryLabel(l10n, s.category)} · ${l10n.itemsProgress(s.completedItems, s.totalItems)}',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (s.isPrivate) Icon(Icons.lock_outline, size: 18, color: theme.colorScheme.outline),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: s.progress,
                  minHeight: 8,
                  color: theme.colorScheme.secondary,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              if (s.overdueItems > 0 || s.dueTodayItems > 0) ...[
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    if (s.overdueItems > 0)
                      _Badge(text: l10n.overdueCount(s.overdueItems), color: theme.colorScheme.error),
                    if (s.dueTodayItems > 0)
                      _Badge(text: l10n.dueTodayCount(s.dueTodayItems), color: theme.colorScheme.primary),
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

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
    child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
  );
}
