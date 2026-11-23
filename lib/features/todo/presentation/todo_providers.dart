import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/sync_engine.dart';
import '../../../shared/providers/session_controller.dart';
import '../data/todo_repository.dart';
import '../domain/todo_logic.dart';
import '../domain/todo_models.dart';

const _uuid = Uuid();
String newTodoId() => _uuid.v4();

/// Debounced tick for family-wide To-Do changes (lists overview, dashboard).
/// Subscribed only while watched; the channel is removed on dispose.
final todoFamilyTickProvider = StreamProvider.autoDispose.family<int, String>((ref, familyId) {
  final controller = StreamController<int>();
  var tick = 0;
  Timer? debounce;
  final sub = ref.watch(todoRepositoryProvider).watchFamily(familyId).listen((_) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 350), () => controller.add(++tick));
  });
  ref.onDispose(() {
    debounce?.cancel();
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

final todoSummariesProvider = FutureProvider.autoDispose.family<List<TodoListSummary>, String>((ref, familyId) {
  ref.watch(todoFamilyTickProvider(familyId));
  return ref.watch(todoRepositoryProvider).summaries(familyId);
});

class TodoOverview {
  const TodoOverview({required this.today, required this.overdue, required this.mine, required this.openCount});

  final List<TodoItem> today;
  final List<TodoItem> overdue;
  final List<TodoItem> mine;
  final int openCount;
}

/// Dashboard data: today's / overdue / my open tasks for the active family.
final todoOverviewProvider = FutureProvider.autoDispose.family<TodoOverview, String>((ref, familyId) async {
  ref.watch(todoFamilyTickProvider(familyId));
  final me = ref.watch(currentUserIdProvider);
  final items = await ref.watch(todoRepositoryProvider).openFamilyItems(familyId);
  final now = DateTime.now();
  return TodoOverview(
    today: items.where((i) => i.isDueOn(now)).toList(),
    overdue: items.where((i) => i.isOverdue(now) && !i.isDueOn(now)).toList(),
    mine: me == null ? const [] : items.where((i) => i.assigneeIds.contains(me)).toList(),
    openCount: items.length,
  );
});

// -----------------------------------------------------------------------------
// One list: state + realtime + optimistic mutations
// -----------------------------------------------------------------------------
class TodoListState {
  const TodoListState({
    required this.list,
    required this.items,
    this.pending = const {},
    this.commentsVersion = 0,
    this.deleted = false,
  });

  final TodoList list;
  final Map<String, TodoItem> items;

  /// Item ids with a mutation in flight (shown as "syncing").
  final Set<String> pending;

  /// Incremented on every comment change so open comment views refresh.
  final int commentsVersion;

  /// The list was deleted (possibly on another device).
  final bool deleted;

  TodoListState copyWith({
    TodoList? list,
    Map<String, TodoItem>? items,
    Set<String>? pending,
    int? commentsVersion,
    bool? deleted,
  }) => TodoListState(
    list: list ?? this.list,
    items: items ?? this.items,
    pending: pending ?? this.pending,
    commentsVersion: commentsVersion ?? this.commentsVersion,
    deleted: deleted ?? this.deleted,
  );
}

final todoListControllerProvider = AsyncNotifierProvider.autoDispose.family<TodoListController, TodoListState, String>(
  TodoListController.new,
);

class TodoListController extends AsyncNotifier<TodoListState> {
  TodoListController(this.listId);

  final String listId;
  bool _initialSubscribe = true;

  TodoRepository get _repo => ref.read(todoRepositoryProvider);

  @override
  Future<TodoListState> build() async {
    final repo = ref.watch(todoRepositoryProvider);
    final sub = repo.watchList(listId).listen(_onChange, onError: (_) {});
    final synced = ref.read(syncEngineProvider.notifier).results.where((r) => r.op.scope == listId).listen((r) {
      final cur = _s;
      if (cur != null) _set(cur.copyWith(pending: _without(r.op.entityId)));
      unawaited(refresh().catchError((Object _) {}));
    });
    ref.onDispose(() {
      sub.cancel();
      synced.cancel();
    });
    final results = await Future.wait([repo.list(listId), repo.items(listId)]);
    final list = results[0] as TodoList;
    final (items, queued) = await _withQueued({for (final i in results[1] as List<TodoItem>) i.id: i});
    return TodoListState(list: list, items: items, pending: queued, deleted: list.deletedAt != null);
  }

  TodoListState? get _s => state.value;

  void _set(TodoListState s) => state = AsyncData(s);

  SyncEngine get _sync => ref.read(syncEngineProvider.notifier);

  /// Server/cached items + writes still queued offline (and their ids).
  Future<(Map<String, TodoItem>, Set<String>)> _withQueued(Map<String, TodoItem> items) async {
    final ops = await _sync.opsFor(listId).catchError((Object _) => <Never>[]);
    if (ops.isEmpty) return (items, <String>{});
    return (
      applyQueuedTodoOps(items, listId, [for (final o in ops) (o.kind, opParams(o))]),
      {for (final o in ops) o.entityId},
    );
  }

  /// True when writes to [itemId] must go through the outbox: offline earlier
  /// writes are still queued, so a direct call would overtake them.
  bool _mustQueue(String itemId) => ref.read(syncEngineProvider).hasPendingFor(itemId);

  static bool _isOffline(Object e) => AppFailure.from(e).kind == FailureKind.network;

  Future<void> _queue(OutboxKind kind, String itemId, Map<String, dynamic> params) =>
      _sync.enqueue(kind: kind, entityId: itemId, scope: listId, params: params);

  Future<void> _onChange(TodoChange c) async {
    final s = _s;
    if (c.resubscribed) {
      if (_initialSubscribe) {
        _initialSubscribe = false;
        return;
      }
      await refresh(); // reconnect: reconcile with the database
      return;
    }
    if (s == null) return;
    switch (c.table) {
      case 'todo_items':
        final id = c.record['id'] as String?;
        if (id == null) return;
        final fresh = await _repo.item(id).catchError((_) => null);
        final cur = _s;
        if (fresh == null || cur == null) return;
        _set(cur.copyWith(items: mergeServerItem(cur.items, fresh)));
      case 'todo_comments':
        _set(s.copyWith(commentsVersion: s.commentsVersion + 1));
      case 'todo_lists':
        if (c.record['deleted_at'] != null) {
          _set(s.copyWith(deleted: true));
        } else {
          final list = await _repo.list(listId).catchError((_) => s.list);
          final cur = _s;
          if (cur != null) _set(cur.copyWith(list: list));
        }
    }
  }

  Future<void> refresh() async {
    final s = _s;
    final results = await Future.wait([_repo.list(listId), _repo.items(listId)]);
    final list = results[0] as TodoList;
    final (items, queued) = await _withQueued({for (final i in results[1] as List<TodoItem>) i.id: i});
    _set(
      TodoListState(
        list: list,
        items: items,
        pending: {...?_s?.pending, ...queued},
        commentsVersion: (s?.commentsVersion ?? 0) + 1,
        deleted: list.deletedAt != null,
      ),
    );
  }

  Set<String> _with(String id) => {...?_s?.pending, id};
  Set<String> _without(String id) => {...?_s?.pending}..remove(id);

  /// Optimistically marks [item] completed/open; rolls back on failure.
  Future<void> setCompleted(TodoItem item, {required bool completed}) async {
    final s = _s;
    if (s == null) return;
    final before = s.items[item.id] ?? item;
    _set(
      s.copyWith(
        items: {
          ...s.items,
          item.id: before.copyWith(completed: completed, completedAt: DateTime.now()),
        },
        pending: _with(item.id),
      ),
    );
    final params = TodoRepository.setStatusParams(item.id, completed: completed);
    if (_mustQueue(item.id)) return _queue(OutboxKind.todoSetStatus, item.id, params);
    try {
      final saved = await _repo.setCompleted(item.id, completed: completed);
      final cur = _s!;
      _set(cur.copyWith(items: mergeServerItem(cur.items, saved), pending: _without(item.id)));
      if (completed && item.recurrence != TodoRecurrence.none) {
        await refresh(); // pick up the next occurrence immediately
      }
    } catch (e) {
      if (_isOffline(e)) return _queue(OutboxKind.todoSetStatus, item.id, params); // keep the optimistic state
      final cur = _s!;
      _set(cur.copyWith(items: {...cur.items, item.id: before}, pending: _without(item.id)));
      rethrow;
    }
  }

  /// Creates (no [original]) or edits an item. Edits carry the original
  /// revision; a conflicting concurrent edit reloads the server copy and
  /// rethrows [FailureKind.conflict].
  Future<void> saveItem({
    TodoItem? original,
    required String title,
    String? description,
    TodoPriority priority = TodoPriority.normal,
    DateTime? dueAt,
    TodoRecurrence recurrence = TodoRecurrence.none,
    List<String>? assigneeIds,
  }) async {
    final s = _s;
    if (s == null) return;
    final id = original?.id ?? newTodoId();
    final optimistic =
        (original ??
                TodoItem(
                  id: id,
                  listId: listId,
                  title: title,
                  completed: false,
                  priority: priority,
                  recurrence: recurrence,
                  revision: 0,
                  position: DateTime.now().millisecondsSinceEpoch / 1000,
                ))
            .copyWith(
              title: title,
              description: description,
              clearDescription: description == null || description.trim().isEmpty,
              priority: priority,
              dueAt: dueAt,
              clearDueAt: dueAt == null,
              recurrence: recurrence,
              assigneeIds: assigneeIds,
            );
    _set(s.copyWith(items: {...s.items, id: optimistic}, pending: _with(id)));
    // While earlier offline writes to this item are queued, the server revision
    // will move on when they sync, so the queued edit cannot carry a revision.
    final queueFirst = _mustQueue(id);
    Map<String, dynamic> params({required bool queued}) => TodoRepository.upsertItemParams(
      id: id,
      listId: listId,
      title: title,
      description: description,
      priority: priority,
      dueAt: dueAt,
      recurrence: recurrence,
      assigneeIds: assigneeIds,
      expectedRevision: queued && queueFirst ? null : (original?.revision == 0 ? null : original?.revision),
    );
    if (queueFirst) return _queue(OutboxKind.todoUpsertItem, id, params(queued: true));
    try {
      final saved = await _repo.upsertItem(
        id: id,
        listId: listId,
        title: title,
        description: description,
        priority: priority,
        dueAt: dueAt,
        recurrence: recurrence,
        assigneeIds: assigneeIds,
        expectedRevision: original?.revision,
      );
      final cur = _s!;
      _set(cur.copyWith(items: mergeServerItem(cur.items, saved), pending: _without(id)));
    } catch (e) {
      if (_isOffline(e)) return _queue(OutboxKind.todoUpsertItem, id, params(queued: true));
      final cur = _s!;
      final rolledBack = Map<String, TodoItem>.of(cur.items);
      if (original == null) {
        rolledBack.remove(id);
      } else {
        rolledBack[id] = original;
      }
      _set(cur.copyWith(items: rolledBack, pending: _without(id)));
      if (AppFailure.from(e).kind == FailureKind.conflict) {
        final fresh = await _repo.item(id).catchError((_) => null);
        final c2 = _s!;
        if (fresh != null) _set(c2.copyWith(items: mergeServerItem(c2.items, fresh)));
      }
      rethrow;
    }
  }

  Future<void> deleteItem(TodoItem item) async {
    final s = _s;
    if (s == null) return;
    final next = Map<String, TodoItem>.of(s.items)..remove(item.id);
    _set(s.copyWith(items: next));
    final params = TodoRepository.deleteItemParams(item.id);
    if (_mustQueue(item.id)) return _queue(OutboxKind.todoDeleteItem, item.id, params);
    try {
      await _repo.deleteItem(item.id);
    } catch (e) {
      if (_isOffline(e)) return _queue(OutboxKind.todoDeleteItem, item.id, params);
      final cur = _s!;
      _set(cur.copyWith(items: {...cur.items, item.id: item}));
      rethrow;
    }
  }

  Future<void> renameList({required String name, String? description, TodoCategory? category}) async {
    final s = _s;
    if (s == null) return;
    final updated = await _repo.updateList(s.list, name: name, description: description, category: category);
    _set(_s!.copyWith(list: updated));
  }
}

/// Comments of one item; refreshes when the list's comment version changes.
final todoCommentsProvider = FutureProvider.autoDispose.family<List<TodoComment>, ({String listId, String itemId})>((
  ref,
  arg,
) {
  ref.watch(todoListControllerProvider(arg.listId).select((s) => s.value?.commentsVersion));
  return ref.watch(todoRepositoryProvider).comments(arg.itemId);
});

final todoActivityProvider = FutureProvider.autoDispose.family<List<TodoActivity>, String>((ref, listId) {
  ref.watch(todoListControllerProvider(listId).select((s) => s.value?.items.length));
  return ref.watch(todoRepositoryProvider).activity(listId);
});
