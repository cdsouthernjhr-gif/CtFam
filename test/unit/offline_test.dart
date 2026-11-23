import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:familysync/core/errors/app_failure.dart';
import 'package:familysync/core/offline/local_database.dart';
import 'package:familysync/core/offline/offline_store.dart';
import 'package:familysync/core/offline/sync_engine.dart';
import 'package:familysync/features/todo/domain/todo_logic.dart';
import 'package:familysync/features/todo/domain/todo_models.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

LocalDatabase memoryDb() => LocalDatabase(NativeDatabase.memory());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfflineStore', () {
    late LocalDatabase db;
    late OfflineStore store;
    final reach = <bool>[];
    setUp(() {
      db = memoryDb();
      reach.clear();
      store = OfflineStore(db, currentUserId: () => 'u1', onReachability: reach.add);
    });
    tearDown(() => db.close());

    test('online: returns the server rows and stores them', () async {
      final rows = await store.rows(
        'k',
        () async => [
          {'id': 1, 'title': 'Susu'},
        ],
      );
      expect(rows.single['title'], 'Susu');
      await Future<void>.delayed(Duration.zero);
      expect(await db.readCache('u1', 'k'), contains('Susu'));
      expect(reach, [true]);
    });

    test('offline: serves the last stored copy', () async {
      await store.rows(
        'k',
        () async => [
          {'id': 1, 'title': 'Susu'},
        ],
      );
      await Future<void>.delayed(Duration.zero);
      final rows = await store.rows('k', () async => throw const SocketException('Failed host lookup'));
      expect(rows.single['title'], 'Susu');
      expect(reach.last, isFalse);
    });

    test('offline without a copy: network failure is reported', () async {
      expect(
        () => store.rows('none', () async => throw const SocketException('down')),
        throwsA(isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.network)),
      );
    });

    test('other errors are never masked by the cache', () async {
      await store.rows(
        'k',
        () async => [
          {'id': 1},
        ],
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        () => store.rows('k', () async => throw const PostgrestException(message: 'forbidden', code: '42501')),
        throwsA(isA<PostgrestException>()),
      );
    });

    test('cache is per user and wiped for other accounts / on sign-out', () async {
      await db.writeCache('u1', 'k', '1');
      await db.writeCache('u2', 'k', '2');
      expect(await db.readCache('u2', 'k'), '2');
      await db.wipe(keepOwner: 'u1');
      expect(await db.readCache('u2', 'k'), isNull);
      expect(await db.readCache('u1', 'k'), '1');
      await db.wipe();
      expect(await db.readCache('u1', 'k'), isNull);
    });
  });

  group('SyncEngine', () {
    late LocalDatabase db;
    late ProviderContainer c;
    late List<(String, Map<String, dynamic>)> calls;
    late Future<void> Function(String, Map<String, dynamic>) behaviour;

    setUp(() {
      db = memoryDb();
      calls = [];
      behaviour = (_, _) async {};
      c = ProviderContainer(
        overrides: [
          localDatabaseProvider.overrideWithValue(db),
          currentUserIdProvider.overrideWithValue('u1'),
          offlineStoreProvider.overrideWithValue(OfflineStore(db, currentUserId: () => 'u1')),
          connectivityProvider.overrideWith((ref) => Stream.value(true)),
          rpcRunnerProvider.overrideWithValue((rpc, params) {
            calls.add((rpc, params));
            return behaviour(rpc, params);
          }),
        ],
      );
      c.listen(syncEngineProvider, (_, _) {});
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    SyncEngine engine() => c.read(syncEngineProvider.notifier);

    Future<void> queue(OutboxKind k, String id, [String scope = 'L1']) =>
        engine().enqueue(kind: k, entityId: id, scope: scope, params: {'p_id': id});

    test('replays in order, removes applied ops and reports them', () async {
      behaviour = (_, _) async => throw const SocketException('offline'); // hold the queue
      await queue(OutboxKind.todoUpsertItem, 'a');
      await queue(OutboxKind.todoSetStatus, 'a');
      await queue(OutboxKind.chatSendText, 'm1', 'C1');
      expect(c.read(syncEngineProvider).hasPendingFor('a'), isTrue);
      await engine().flush();
      expect(calls.map((x) => x.$1), ['upsert_todo_item'], reason: 'stops at the first network failure');
      expect(c.read(networkStatusProvider), isFalse);

      calls.clear();
      behaviour = (_, _) async {};
      final results = <SyncResult>[];
      final sub = engine().results.listen(results.add);
      await engine().flush();
      expect(calls.map((x) => x.$1), ['upsert_todo_item', 'set_todo_item_status', 'send_message']);
      expect(await db.allOps('u1'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(results.every((r) => r.ok), isTrue);
      expect(c.read(networkStatusProvider), isTrue);
      await sub.cancel();
    });

    test('a rejected op (e.g. conflict) is marked failed; later ops still run; retry and discard', () async {
      behaviour = (rpc, _) async {
        if (rpc == 'upsert_todo_item') {
          throw const PostgrestException(message: 'revision_conflict', code: 'P0409');
        }
      };
      await queue(OutboxKind.todoUpsertItem, 'a');
      await queue(OutboxKind.eventRsvp, 'e1', 'e1');
      await engine().flush();
      final ops = await db.allOps('u1');
      expect(ops, hasLength(1));
      expect(ops.single.status, 'failed');
      expect(ops.single.lastError, 'conflict');
      expect(calls.map((x) => x.$1), ['upsert_todo_item', 'set_event_rsvp']);

      behaviour = (_, _) async {};
      await engine().retryFailed();
      expect(await db.allOps('u1'), isEmpty);

      await queue(OutboxKind.todoDeleteItem, 'b');
      final id = (await db.allOps('u1')).single.id;
      await engine().discard(id);
      expect(await db.allOps('u1'), isEmpty);
    });

    test('ops of other users are never replayed', () async {
      await db.enqueue(
        OutboxOpsCompanion.insert(
          id: 'x',
          owner: 'u2',
          kind: OutboxKind.todoDeleteItem.key,
          entityId: 'z',
          scope: 'L',
          payload: '{}',
          createdAt: DateTime.now(),
        ),
      );
      await engine().flush();
      expect(calls, isEmpty);
    });
  });

  test('queued To-Do ops are re-applied on top of server data', () {
    final items = {
      'a': const TodoItem(
        id: 'a',
        listId: 'L1',
        title: 'Susu',
        completed: false,
        priority: TodoPriority.normal,
        recurrence: TodoRecurrence.none,
        revision: 3,
        position: 1,
      ),
      'b': const TodoItem(
        id: 'b',
        listId: 'L1',
        title: 'Roti',
        completed: false,
        priority: TodoPriority.normal,
        recurrence: TodoRecurrence.none,
        revision: 1,
        position: 2,
      ),
    };
    final out = applyQueuedTodoOps(items, 'L1', [
      ('todo.set_status', {'p_id': 'a', 'p_completed': true}),
      ('todo.delete_item', {'p_id': 'b'}),
      (
        'todo.upsert_item',
        {
          'p_id': 'c',
          'p_list_id': 'L1',
          'p_title': 'Telur',
          'p_priority': 'high',
          'p_due_at': null,
          'p_recurrence': 'none',
        },
      ),
      ('todo.upsert_item', {'p_id': 'd', 'p_list_id': 'OTHER', 'p_title': 'X'}),
    ]);
    expect(out['a']!.completed, isTrue);
    expect(out.containsKey('b'), isFalse);
    expect(out['c']!.title, 'Telur');
    expect(out['c']!.priority, TodoPriority.high);
    expect(out.containsKey('d'), isFalse, reason: 'other list');
  });

  test('network failures from package:http are recognised', () {
    expect(
      AppFailure.from(Exception('ClientException: Connection closed before full header')).kind,
      FailureKind.network,
    );
    expect(AppFailure.from(TimeoutException('slow')).kind, FailureKind.network);
    expect(AppFailure.from(Exception('something else')).kind, FailureKind.unknown);
  });
}
