import 'package:familysync/features/todo/domain/todo_logic.dart';
import 'package:familysync/features/todo/domain/todo_models.dart';
import 'package:flutter_test/flutter_test.dart';

TodoItem _item(
  String id, {
  int revision = 1,
  bool completed = false,
  DateTime? due,
  TodoPriority priority = TodoPriority.normal,
  List<String> assignees = const [],
  String title = 'Tugasan',
  double position = 0,
  bool deleted = false,
  DateTime? completedAt,
}) => TodoItem(
  id: id,
  listId: 'l',
  title: title,
  completed: completed,
  priority: priority,
  recurrence: TodoRecurrence.none,
  revision: revision,
  position: position,
  dueAt: due,
  assigneeIds: assignees,
  deleted: deleted,
  completedAt: completedAt,
);

void main() {
  group('mergeServerItem', () {
    test('adds new and replaces with newer revision', () {
      var m = mergeServerItem({}, _item('a'));
      expect(m['a']!.revision, 1);
      m = mergeServerItem(m, _item('a', revision: 2, completed: true));
      expect(m['a']!.completed, isTrue);
    });

    test('ignores stale or duplicate out-of-order events', () {
      final m = mergeServerItem({'a': _item('a', revision: 5, title: 'baru')}, _item('a', revision: 3, title: 'lama'));
      expect(m['a']!.title, 'baru');
    });

    test('equal revision is accepted (server copy wins over optimistic copy)', () {
      final m = mergeServerItem({
        'a': _item('a', revision: 2, completed: true),
      }, _item('a', revision: 2, completed: false));
      expect(m['a']!.completed, isFalse);
    });

    test('soft-deleted items are removed', () {
      final m = mergeServerItem({'a': _item('a')}, _item('a', revision: 2, deleted: true));
      expect(m.containsKey('a'), isFalse);
    });
  });

  group('filter', () {
    final items = [
      _item('1', title: 'Beli susu', assignees: ['u1']),
      _item('2', title: 'Bayar bil elektrik', completed: true, assignees: ['u2']),
      _item('3', title: 'Cuci kereta'),
    ];

    test('by status', () {
      expect(items.where((i) => matchesFilter(i, const TodoFilter(status: TodoStatusFilter.open))).length, 2);
      expect(items.where((i) => matchesFilter(i, const TodoFilter(status: TodoStatusFilter.completed))).length, 1);
    });

    test('by member', () {
      expect(items.where((i) => matchesFilter(i, const TodoFilter(memberId: 'u1'))).map((i) => i.id), ['1']);
    });

    test('by search text (case-insensitive)', () {
      expect(items.where((i) => matchesFilter(i, const TodoFilter(query: 'BIL'))).map((i) => i.id), ['2']);
    });

    test('isActive', () {
      expect(const TodoFilter().isActive, isFalse);
      expect(const TodoFilter(query: ' x ').isActive, isTrue);
    });
  });

  test('sort: open first by due date then priority; completed last by completion time', () {
    final d = DateTime(2026, 11, 22);
    final sorted = sortItems([
      _item('nodue-urgent', priority: TodoPriority.urgent),
      _item('done-old', completed: true, completedAt: d),
      _item('due-later', due: d.add(const Duration(days: 2))),
      _item('due-soon', due: d),
      _item('nodue-normal', position: 1),
      _item('done-new', completed: true, completedAt: d.add(const Duration(hours: 1))),
    ]);
    expect(sorted.map((i) => i.id), ['due-soon', 'due-later', 'nodue-urgent', 'nodue-normal', 'done-new', 'done-old']);
  });

  test('progress', () {
    final p = progressOf([_item('a', completed: true), _item('b'), _item('c', completed: true)]);
    expect(p.completed, 2);
    expect(p.total, 3);
    expect(p.fraction, closeTo(0.667, 0.001));
    expect(progressOf([]).fraction, 0);
  });

  test('TodoItem.fromJson reads assignees and status', () {
    final item = TodoItem.fromJson({
      'id': 'i',
      'list_id': 'l',
      'title': 'x',
      'status': 'completed',
      'priority': 'urgent',
      'recurrence': 'weekly',
      'revision': 4,
      'position': 12.5,
      'completed_at': '2026-11-22T01:00:00Z',
      'todo_assignments': [
        {'user_id': 'u1'},
        {'user_id': 'u2'},
      ],
    });
    expect(item.completed, isTrue);
    expect(item.priority, TodoPriority.urgent);
    expect(item.recurrence, TodoRecurrence.weekly);
    expect(item.assigneeIds, ['u1', 'u2']);
  });

  test('category keys match the database check constraint', () {
    expect(TodoCategory.familyActivities.key, 'family_activities');
    expect(TodoCategory.parse('family_activities'), TodoCategory.familyActivities);
    expect(TodoCategory.parse('unknown'), TodoCategory.personal);
  });
}
