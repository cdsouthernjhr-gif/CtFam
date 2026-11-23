import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/todo_models.dart';

final todoRepositoryProvider = Provider<TodoRepository>(
  (ref) => TodoRepository(ref.watch(supabaseClientProvider), offline: ref.watch(offlineStoreProvider)),
);

/// A Realtime change on one To-Do table.
class TodoChange {
  const TodoChange(this.table, this.record, {this.resubscribed = false});

  /// Emitted after (re)subscribing: callers should reconcile with a refetch.
  const TodoChange.resubscribed() : table = '', record = const {}, resubscribed = true;

  final String table;
  final Map<String, dynamic> record;
  final bool resubscribed;
}

class TodoRepository {
  TodoRepository(this._client, {this._offline});

  final SupabaseClient _client;
  final OfflineStore? _offline;

  // Offline: last successful responses are served when the network is down.
  Future<List<Map<String, dynamic>>> _cachedRows(String key, Future<List<dynamic>> Function() fetch) {
    final store = _offline;
    if (store == null) return fetch().then((r) => [for (final x in r) Map<String, dynamic>.from(x as Map)]);
    return store.rows(key, fetch);
  }

  Future<Map<String, dynamic>?> _cachedRow(String key, Future<Map<String, dynamic>?> Function() fetch) {
    final store = _offline;
    return store == null ? fetch() : store.row(key, fetch);
  }

  // ---------------------------------------------------------------- lists
  Future<List<TodoListSummary>> summaries(String familyId) => _guard(() async {
    final rows = await _cachedRows(
      'todo:summaries:$familyId',
      () => _client.rpc<List<dynamic>>('todo_list_summaries', params: {'p_family_id': familyId}),
    );
    return rows.map(TodoListSummary.fromJson).toList();
  });

  Future<TodoList> list(String listId) => _guard(() async {
    final row = await _cachedRow(
      'todo:list:$listId',
      () => _client.from('todo_lists').select().eq('id', listId).single(),
    );
    return TodoList.fromJson(row!);
  });

  Future<TodoList> createList({
    required String id,
    required String familyId,
    required String name,
    required TodoCategory category,
    String? description,
    bool membersOnly = false,
    List<String> memberIds = const [],
  }) => _guard(() async {
    final row = await _client.rpc<Map<String, dynamic>>(
      'create_todo_list',
      params: {
        'p_id': id,
        'p_family_id': familyId,
        'p_name': name.trim(),
        'p_category': category.key,
        'p_description': description?.trim(),
        'p_visibility': membersOnly ? 'members' : 'family',
        'p_member_ids': memberIds,
      },
    );
    return TodoList.fromJson(row);
  });

  Future<TodoList> updateList(TodoList list, {required String name, String? description, TodoCategory? category}) =>
      _guard(() async {
        final row = await _client.rpc<Map<String, dynamic>>(
          'update_todo_list',
          params: {
            'p_id': list.id,
            'p_name': name.trim(),
            'p_description': description?.trim(),
            'p_category': (category ?? list.category).key,
            'p_expected_revision': list.revision,
          },
        );
        return TodoList.fromJson(row);
      });

  Future<void> deleteList(String listId) =>
      _guard(() => _client.rpc<void>('delete_todo_list', params: {'p_id': listId}));

  // ---------------------------------------------------------------- items
  Future<List<TodoItem>> items(String listId) => _guard(() async {
    final rows = await _cachedRows(
      'todo:items:$listId',
      () => _client
          .from('todo_items')
          .select(TodoItem.select)
          .eq('list_id', listId)
          .isFilter('deleted_at', null)
          .order('position'),
    );
    return rows.map(TodoItem.fromJson).toList();
  });

  Future<TodoItem?> item(String itemId) => _guard(() async {
    final row = await _client.from('todo_items').select(TodoItem.select).eq('id', itemId).maybeSingle();
    return row == null ? null : TodoItem.fromJson(row);
  });

  /// Open items of the family (for the dashboard), soonest due first.
  Future<List<TodoItem>> openFamilyItems(String familyId, {int limit = 200}) => _guard(() async {
    final rows = await _cachedRows(
      'todo:open:$familyId',
      () => _client
          .from('todo_items')
          .select(TodoItem.select)
          .eq('family_id', familyId)
          .eq('status', 'open')
          .isFilter('deleted_at', null)
          .order('due_at', ascending: true, nullsFirst: false)
          .limit(limit),
    );
    return rows.map(TodoItem.fromJson).toList();
  });

  /// RPC parameters for `upsert_todo_item` (shared with the offline outbox).
  static Map<String, dynamic> upsertItemParams({
    required String id,
    required String listId,
    required String title,
    String? description,
    TodoPriority priority = TodoPriority.normal,
    DateTime? dueAt,
    TodoRecurrence recurrence = TodoRecurrence.none,
    List<String>? assigneeIds,
    int? expectedRevision,
  }) => {
    'p_id': id,
    'p_list_id': listId,
    'p_title': title.trim(),
    'p_description': description?.trim(),
    'p_priority': priority.name,
    'p_due_at': dueAt?.toUtc().toIso8601String(),
    'p_recurrence': recurrence.name,
    'p_assignee_ids': assigneeIds,
    'p_expected_revision': expectedRevision,
  };

  static Map<String, dynamic> setStatusParams(String itemId, {required bool completed}) => {
    'p_id': itemId,
    'p_completed': completed,
  };

  static Map<String, dynamic> deleteItemParams(String itemId) => {'p_id': itemId};

  /// Idempotent create (client-generated id) or optimistic-concurrency update.
  /// Pass [assigneeIds] = null to keep assignees unchanged.
  Future<TodoItem> upsertItem({
    required String id,
    required String listId,
    required String title,
    String? description,
    TodoPriority priority = TodoPriority.normal,
    DateTime? dueAt,
    TodoRecurrence recurrence = TodoRecurrence.none,
    List<String>? assigneeIds,
    int? expectedRevision,
  }) => _guard(() async {
    await _client.rpc<Map<String, dynamic>>(
      'upsert_todo_item',
      params: upsertItemParams(
        id: id,
        listId: listId,
        title: title,
        description: description,
        priority: priority,
        dueAt: dueAt,
        recurrence: recurrence,
        assigneeIds: assigneeIds,
        expectedRevision: expectedRevision,
      ),
    );
    // Re-read with assignees embedded.
    return (await item(id))!;
  });

  /// Sets the completion state (idempotent, never a blind toggle).
  Future<TodoItem> setCompleted(String itemId, {required bool completed}) => _guard(() async {
    final row = await _client.rpc<Map<String, dynamic>>(
      'set_todo_item_status',
      params: setStatusParams(itemId, completed: completed),
    );
    final base = TodoItem.fromJson(row);
    final full = await item(itemId);
    return full ?? base;
  });

  Future<void> deleteItem(String itemId) =>
      _guard(() => _client.rpc<void>('delete_todo_item', params: deleteItemParams(itemId)));

  // ---------------------------------------------------------------- comments & activity
  Future<List<TodoComment>> comments(String itemId) => _guard(() async {
    final rows = await _client
        .from('todo_comments')
        .select('id, item_id, body, created_at, author_id, deleted_at, profiles(display_name)')
        .eq('item_id', itemId)
        .isFilter('deleted_at', null)
        .order('created_at');
    return rows.map(TodoComment.fromJson).toList();
  });

  Future<void> addComment({
    required String id,
    required TodoItem item,
    required String familyId,
    required String body,
  }) => _guard(() async {
    final uid = _client.auth.currentUser?.id;
    await _client.from('todo_comments').upsert({
      'id': id,
      'item_id': item.id,
      'list_id': item.listId,
      'family_id': familyId,
      'author_id': uid,
      'body': body.trim(),
    }, ignoreDuplicates: true);
  });

  Future<void> deleteComment(String commentId) => _guard(
    () => _client
        .from('todo_comments')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', commentId),
  );

  Future<List<TodoActivity>> activity(String listId) => _guard(() async {
    final rows = await _client
        .from('todo_activity_logs')
        .select('id, action, created_at, details, profiles(display_name)')
        .eq('list_id', listId)
        .order('created_at', ascending: false)
        .limit(100);
    return rows.map(TodoActivity.fromJson).toList();
  });

  // ---------------------------------------------------------------- realtime
  /// Changes of one list: channel `todo:{listId}`.
  Stream<TodoChange> watchList(String listId) => _watch('todo:$listId', [
    ('todo_items', 'list_id', listId),
    ('todo_comments', 'list_id', listId),
    ('todo_lists', 'id', listId),
  ]);

  /// List-level changes for the overview: channel `todo-family:{familyId}`.
  Stream<TodoChange> watchFamily(String familyId) =>
      _watch('todo-family:$familyId', [('todo_lists', 'family_id', familyId), ('todo_items', 'family_id', familyId)]);

  Stream<TodoChange> _watch(String topic, List<(String, String, String)> tables) {
    late final RealtimeChannel channel;
    final controller = StreamController<TodoChange>.broadcast();
    controller.onListen = () {
      channel = _client.channel(topic);
      for (final (table, column, value) in tables) {
        channel.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: column, value: value),
          callback: (p) => controller.add(TodoChange(table, p.newRecord.isNotEmpty ? p.newRecord : p.oldRecord)),
        );
      }
      channel.subscribe((status, _) {
        if (status == RealtimeSubscribeStatus.subscribed) controller.add(const TodoChange.resubscribed());
      });
    };
    controller.onCancel = () async {
      await _client.removeChannel(channel);
      await controller.close();
    };
    return controller.stream;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
