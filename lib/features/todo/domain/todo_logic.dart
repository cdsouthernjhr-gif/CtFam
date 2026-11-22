import 'todo_models.dart';

/// Pure, unit-tested helpers for the To-Do feature.

/// Merges an item coming from the server (fetch, RPC result or Realtime) into
/// the local map. Stale data (lower revision than what we already hold) is
/// ignored, which makes duplicate or out-of-order Realtime events harmless.
/// Soft-deleted items are removed.
Map<String, TodoItem> mergeServerItem(Map<String, TodoItem> current, TodoItem incoming) {
  final existing = current[incoming.id];
  if (existing != null && existing.revision > incoming.revision) return current;
  final next = Map<String, TodoItem>.of(current);
  if (incoming.deleted) {
    next.remove(incoming.id);
  } else {
    next[incoming.id] = incoming;
  }
  return next;
}

enum TodoStatusFilter { all, open, completed }

class TodoFilter {
  const TodoFilter({this.status = TodoStatusFilter.all, this.memberId, this.query = ''});

  final TodoStatusFilter status;

  /// Only items assigned to this member (null = everyone).
  final String? memberId;
  final String query;

  TodoFilter copyWith({TodoStatusFilter? status, String? memberId, bool clearMember = false, String? query}) =>
      TodoFilter(
        status: status ?? this.status,
        memberId: clearMember ? null : (memberId ?? this.memberId),
        query: query ?? this.query,
      );

  bool get isActive => status != TodoStatusFilter.all || memberId != null || query.trim().isNotEmpty;
}

bool matchesFilter(TodoItem item, TodoFilter f) {
  if (f.status == TodoStatusFilter.open && item.completed) return false;
  if (f.status == TodoStatusFilter.completed && !item.completed) return false;
  if (f.memberId != null && !item.assigneeIds.contains(f.memberId)) return false;
  final q = f.query.trim().toLowerCase();
  if (q.isNotEmpty) {
    final hay = '${item.title} ${item.description ?? ''}'.toLowerCase();
    if (!hay.contains(q)) return false;
  }
  return true;
}

/// Open items: overdue first, then by due date (soonest first, undated last),
/// then priority (urgent first), then creation order.
/// Completed items: most recently completed first.
List<TodoItem> sortItems(Iterable<TodoItem> items) {
  final list = items.toList();
  list.sort((a, b) {
    if (a.completed != b.completed) return a.completed ? 1 : -1;
    if (a.completed) {
      return (b.completedAt ?? DateTime(0)).compareTo(a.completedAt ?? DateTime(0));
    }
    final ad = a.dueAt, bd = b.dueAt;
    if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
    if (ad != null && bd == null) return -1;
    if (ad == null && bd != null) return 1;
    if (a.priority != b.priority) return b.priority.rank.compareTo(a.priority.rank);
    return a.position.compareTo(b.position);
  });
  return list;
}

class TodoProgress {
  const TodoProgress(this.completed, this.total);

  final int completed;
  final int total;

  double get fraction => total == 0 ? 0 : completed / total;
}

TodoProgress progressOf(Iterable<TodoItem> items) {
  var done = 0, total = 0;
  for (final i in items) {
    total++;
    if (i.completed) done++;
  }
  return TodoProgress(done, total);
}
