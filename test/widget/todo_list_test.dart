import 'dart:async';

import 'package:familysync/core/errors/app_failure.dart';
import 'package:familysync/core/offline/offline_store.dart';
import 'package:familysync/core/offline/sync_engine.dart';
import 'package:familysync/features/family/data/family_repository.dart';
import 'package:familysync/features/family/domain/family_models.dart';
import 'package:familysync/features/todo/data/todo_repository.dart';
import 'package:familysync/features/todo/domain/todo_models.dart';
import 'package:familysync/features/todo/presentation/todo_list_screen.dart';
import 'package:familysync/features/todo/presentation/todo_providers.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/pump_app.dart';

class _MockTodoRepo extends Mock implements TodoRepository {}

class _MockFamilyRepo extends Mock implements FamilyRepository {}

const _list = TodoList(
  id: 'L1',
  familyId: 'F1',
  name: 'Barang dapur',
  category: TodoCategory.grocery,
  visibility: 'family',
  revision: 1,
  createdBy: 'u1',
);

TodoItem _item(
  String id,
  String title, {
  int revision = 1,
  bool completed = false,
  List<String> assignees = const [],
}) => TodoItem(
  id: id,
  listId: 'L1',
  title: title,
  completed: completed,
  priority: TodoPriority.normal,
  recurrence: TodoRecurrence.none,
  revision: revision,
  position: 0,
  assigneeIds: assignees,
  completedAt: completed ? DateTime(2026, 11, 22) : null,
);

void main() {
  late _MockTodoRepo repo;
  late StreamController<TodoChange> changes;

  setUpAll(() {
    registerFallbackValue(_list);
    registerFallbackValue(TodoPriority.normal);
    registerFallbackValue(TodoRecurrence.none);
  });

  setUp(() {
    repo = _MockTodoRepo();
    changes = StreamController<TodoChange>.broadcast();
    when(() => repo.watchList('L1')).thenAnswer((_) => changes.stream);
    when(() => repo.list('L1')).thenAnswer((_) async => _list);
    when(() => repo.items('L1')).thenAnswer(
      (_) async => [
        _item('a', 'Beli susu', assignees: ['u2']),
        _item('b', 'Beli roti'),
      ],
    );
  });

  tearDown(() => changes.close());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        ...offlineOverrides(userId: 'u1'),
        todoRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('TodoListController', () {
    test('optimistic completion is confirmed by the server', () async {
      final c = container();
      final sub = c.listen(todoListControllerProvider('L1'), (_, _) {});
      addTearDown(sub.close);
      await c.read(todoListControllerProvider('L1').future);
      final done = Completer<TodoItem>();
      when(() => repo.setCompleted('a', completed: true)).thenAnswer((_) => done.future);

      final future = c
          .read(todoListControllerProvider('L1').notifier)
          .setCompleted(_item('a', 'Beli susu'), completed: true);
      final mid = c.read(todoListControllerProvider('L1')).requireValue;
      expect(mid.items['a']!.completed, isTrue, reason: 'UI updates before the server answers');
      expect(mid.pending, contains('a'));

      done.complete(_item('a', 'Beli susu', revision: 2, completed: true));
      await future;
      final after = c.read(todoListControllerProvider('L1')).requireValue;
      expect(after.items['a']!.revision, 2);
      expect(after.pending, isEmpty);
    });

    test('offline completion is kept, queued, survives a reload and replays later', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final c = ProviderContainer(
        overrides: [
          ...offlineOverrides(userId: 'u1', rpcCalls: calls),
          todoRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(c.dispose);
      c.listen(syncEngineProvider, (_, _) {});
      final sub = c.listen(todoListControllerProvider('L1'), (_, _) {});
      addTearDown(sub.close);
      await c.read(todoListControllerProvider('L1').future);
      when(() => repo.setCompleted('a', completed: true))
          .thenAnswer((_) async => throw const AppFailure(FailureKind.network));
      c.read(networkStatusProvider.notifier).report(reachable: false);

      await c.read(todoListControllerProvider('L1').notifier).setCompleted(_item('a', 'Beli susu'), completed: true);
      var s = c.read(todoListControllerProvider('L1')).requireValue;
      expect(s.items['a']!.completed, isTrue, reason: 'no rollback when offline');
      expect(c.read(syncEngineProvider).pending, 1);

      // App restart / reload: the server still says "open", the queued write wins locally.
      c.invalidate(todoListControllerProvider('L1'));
      s = await c.read(todoListControllerProvider('L1').future);
      expect(s.items['a']!.completed, isTrue);
      expect(s.pending, contains('a'));

      // A second change to the same item is queued behind the first (order kept).
      await c.read(todoListControllerProvider('L1').notifier).setCompleted(s.items['a']!, completed: false);
      verify(() => repo.setCompleted('a', completed: true)).called(1);
      verifyNever(() => repo.setCompleted('a', completed: false));
      expect(c.read(syncEngineProvider).pending, 2);

      c.read(networkStatusProvider.notifier).report(reachable: true);
      await c.read(syncEngineProvider.notifier).flush();
      expect(calls.map((x) => (x.$1, x.$2['p_completed'])), [
        ('set_todo_item_status', true),
        ('set_todo_item_status', false),
      ]);
      expect(c.read(syncEngineProvider).pending, 0);
    });

    test('rejected completion rolls back and rethrows', () async {
      final c = container();
      final sub = c.listen(todoListControllerProvider('L1'), (_, _) {});
      addTearDown(sub.close);
      await c.read(todoListControllerProvider('L1').future);
      when(() => repo.setCompleted('a', completed: true))
          .thenAnswer((_) async => throw const AppFailure(FailureKind.forbidden));

      await expectLater(
        c.read(todoListControllerProvider('L1').notifier).setCompleted(_item('a', 'Beli susu'), completed: true),
        throwsA(isA<AppFailure>()),
      );
      final s = c.read(todoListControllerProvider('L1')).requireValue;
      expect(s.items['a']!.completed, isFalse, reason: 'rolled back');
      expect(s.pending, isEmpty);
    });

    test('conflicting edit rolls back, reloads the server copy and reports conflict', () async {
      final c = container();
      final sub = c.listen(todoListControllerProvider('L1'), (_, _) {});
      addTearDown(sub.close);
      await c.read(todoListControllerProvider('L1').future);
      when(
        () => repo.upsertItem(
          id: 'a',
          listId: 'L1',
          title: any(named: 'title'),
          description: any(named: 'description'),
          priority: any(named: 'priority'),
          dueAt: any(named: 'dueAt'),
          recurrence: any(named: 'recurrence'),
          assigneeIds: any(named: 'assigneeIds'),
          expectedRevision: 1,
        ),
      ).thenAnswer((_) async => throw const AppFailure(FailureKind.conflict));
      when(() => repo.item('a')).thenAnswer((_) async => _item('a', 'Beli susu 2L (oleh B)', revision: 2));

      await expectLater(
        c
            .read(todoListControllerProvider('L1').notifier)
            .saveItem(original: _item('a', 'Beli susu'), title: 'Beli susu 1L'),
        throwsA(isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.conflict)),
      );
      expect(c.read(todoListControllerProvider('L1')).requireValue.items['a']!.title, 'Beli susu 2L (oleh B)');
    });

    test('realtime: newer events apply, stale events are ignored', () async {
      final c = container();
      final sub = c.listen(todoListControllerProvider('L1'), (_, _) {});
      addTearDown(sub.close);
      await c.read(todoListControllerProvider('L1').future);

      when(() => repo.item('b')).thenAnswer((_) async => _item('b', 'Beli roti', revision: 3, completed: true));
      changes.add(const TodoChange('todo_items', {'id': 'b'}));
      await pumpEventQueue();
      expect(c.read(todoListControllerProvider('L1')).requireValue.items['b']!.completed, isTrue);

      when(() => repo.item('b')).thenAnswer((_) async => _item('b', 'Beli roti', revision: 2));
      changes.add(const TodoChange('todo_items', {'id': 'b'}));
      await pumpEventQueue();
      expect(
        c.read(todoListControllerProvider('L1')).requireValue.items['b']!.completed,
        isTrue,
        reason: 'a late event with an older revision must not undo the newer state',
      );
    });

    test('list deleted on another device is reflected', () async {
      final c = container();
      final sub = c.listen(todoListControllerProvider('L1'), (_, _) {});
      addTearDown(sub.close);
      await c.read(todoListControllerProvider('L1').future);
      changes.add(const TodoChange('todo_lists', {'id': 'L1', 'deleted_at': '2026-11-22T00:00:00Z'}));
      await pumpEventQueue();
      expect(c.read(todoListControllerProvider('L1')).requireValue.deleted, isTrue);
    });
  });

  group('TodoListScreen', () {
    late _MockFamilyRepo familyRepo;

    setUp(() {
      familyRepo = _MockFamilyRepo();
      when(() => familyRepo.watchFamily(any())).thenAnswer((_) => const Stream.empty());
      when(() => familyRepo.members('F1')).thenAnswer(
        (_) async => [
          const FamilyMember(
            id: 'm1',
            familyId: 'F1',
            userId: 'u1',
            role: FamilyRole.owner,
            status: MemberStatus.active,
            profile: Profile(id: 'u1', displayName: 'Aminah'),
          ),
          const FamilyMember(
            id: 'm2',
            familyId: 'F1',
            userId: 'u2',
            role: FamilyRole.member,
            status: MemberStatus.active,
            profile: Profile(id: 'u2', displayName: 'Badrul'),
          ),
        ],
      );
    });

    Future<void> pump(WidgetTester tester) => pumpLocalized(
      tester,
      const TodoListScreen(listId: 'L1'),
      overrides: [
        todoRepositoryProvider.overrideWithValue(repo),
        familyRepositoryProvider.overrideWithValue(familyRepo),
        sessionControllerProvider.overrideWith(
          () => FixedSession(
            SessionState(
              status: SessionStatus.ready,
              user: fakeUser('u1'),
              activeFamilyId: 'F1',
              memberships: const [MyMembership(familyId: 'F1', role: FamilyRole.owner, status: MemberStatus.active)],
            ),
          ),
        ),
      ],
    );

    testWidgets('shows items, progress and toggles completion', (tester) async {
      when(() => repo.setCompleted('b', completed: true))
          .thenAnswer((_) async => _item('b', 'Beli roti', revision: 2, completed: true));
      await pump(tester);

      expect(find.text('Barang dapur'), findsOneWidget);
      expect(find.text('0/2 siap'), findsOneWidget);
      expect(find.text('Beli susu'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('todo-item-b')), matching: find.byType(Checkbox)));
      await tester.pumpAndSettle();
      verify(() => repo.setCompleted('b', completed: true)).called(1);
      expect(find.text('1/2 siap'), findsOneWidget);
    });

    testWidgets('quick add creates an item with a client id', (tester) async {
      when(
        () => repo.upsertItem(
          id: any(named: 'id'),
          listId: 'L1',
          title: 'Beli telur',
          description: any(named: 'description'),
          priority: any(named: 'priority'),
          dueAt: any(named: 'dueAt'),
          recurrence: any(named: 'recurrence'),
          assigneeIds: any(named: 'assigneeIds'),
          expectedRevision: any(named: 'expectedRevision'),
        ),
      ).thenAnswer((inv) async => _item(inv.namedArguments[#id] as String, 'Beli telur'));
      await pump(tester);

      await tester.enterText(find.byKey(const Key('todo.quickAdd')), 'Beli telur');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Beli telur'), findsOneWidget);
      expect(find.text('0/3 siap'), findsOneWidget);
    });

    testWidgets('member filter shows only that member\'s tasks', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Ahli'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Badrul').last);
      await tester.pumpAndSettle();
      expect(find.text('Beli susu'), findsOneWidget);
      expect(find.text('Beli roti'), findsNothing);
    });
  });
}
