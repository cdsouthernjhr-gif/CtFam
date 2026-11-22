import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../domain/todo_models.dart';
import 'todo_providers.dart';

String todoActivityText(AppLocalizations l, TodoActivity a) {
  final actor = (a.actorName?.trim().isNotEmpty ?? false) ? a.actorName! : l.someone;
  final t = a.title ?? '';
  return switch (a.action) {
    'list.created' => l.todoActListCreated(actor, t),
    'list.updated' => l.todoActListUpdated(actor, t),
    'list.deleted' => l.todoActListDeleted(actor),
    'list.members_changed' => l.todoActListMembers(actor),
    'item.created' => l.todoActItemCreated(actor, t),
    'item.updated' => l.todoActItemUpdated(actor, t),
    'item.completed' => l.todoActItemCompleted(actor, t),
    'item.reopened' => l.todoActItemReopened(actor, t),
    'item.deleted' => l.todoActItemDeleted(actor, t),
    'item.assigned' => l.todoActItemAssigned(actor),
    'item.recurred' => l.todoActItemRecurred(t),
    _ => l.activityGeneric(actor, a.action),
  };
}

IconData _icon(String action) => switch (action) {
  'item.completed' => Icons.check_circle_outline,
  'item.reopened' => Icons.replay,
  'item.deleted' || 'list.deleted' => Icons.delete_outline,
  'item.assigned' => Icons.person_add_alt,
  'item.recurred' => Icons.repeat,
  _ => Icons.edit_note,
};

class TodoActivityScreen extends ConsumerWidget {
  const TodoActivityScreen({required this.listId, super.key});

  final String listId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.activity)),
      body: AsyncValueView(
        value: ref.watch(todoActivityProvider(listId)),
        onRetry: () => ref.invalidate(todoActivityProvider(listId)),
        data: (entries) => entries.isEmpty
            ? MessageView(icon: Icons.history, title: l10n.dashboardNoActivity)
            : ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => ListTile(
                  leading: Icon(_icon(entries[i].action)),
                  title: Text(todoActivityText(l10n, entries[i])),
                  subtitle: Text(context.formatDateTime(entries[i].createdAt)),
                ),
              ),
      ),
    );
  }
}
