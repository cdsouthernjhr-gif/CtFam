/// Typed models matching `supabase/migrations/20261123000100_todo.sql`.
library;

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();

enum TodoCategory {
  shopping,
  grocery,
  household,
  school,
  familyActivities,
  bills,
  travel,
  personal,
  custom;

  String get key => this == familyActivities ? 'family_activities' : name;

  static TodoCategory parse(String? v) =>
      TodoCategory.values.firstWhere((c) => c.key == v, orElse: () => TodoCategory.personal);
}

enum TodoPriority {
  low,
  normal,
  high,
  urgent;

  static TodoPriority parse(String? v) =>
      TodoPriority.values.firstWhere((p) => p.name == v, orElse: () => TodoPriority.normal);

  int get rank => index;
}

enum TodoRecurrence {
  none,
  daily,
  weekly,
  monthly,
  yearly;

  static TodoRecurrence parse(String? v) =>
      TodoRecurrence.values.firstWhere((r) => r.name == v, orElse: () => TodoRecurrence.none);
}

class TodoListSummary {
  const TodoListSummary({
    required this.id,
    required this.name,
    required this.category,
    required this.visibility,
    required this.revision,
    required this.totalItems,
    required this.completedItems,
    required this.overdueItems,
    required this.dueTodayItems,
    this.description,
    this.createdBy,
    this.updatedAt,
    this.coverPath,
  });

  factory TodoListSummary.fromJson(Map<String, dynamic> j) => TodoListSummary(
    id: j['id'] as String,
    name: j['name'] as String,
    description: j['description'] as String?,
    category: TodoCategory.parse(j['category'] as String?),
    visibility: (j['visibility'] as String?) ?? 'family',
    createdBy: j['created_by'] as String?,
    revision: (j['revision'] as int?) ?? 1,
    updatedAt: _date(j['updated_at']),
    totalItems: (j['total_items'] as int?) ?? 0,
    completedItems: (j['completed_items'] as int?) ?? 0,
    overdueItems: (j['overdue_items'] as int?) ?? 0,
    dueTodayItems: (j['due_today_items'] as int?) ?? 0,
    coverPath: j['cover_path'] as String?,
  );

  final String id;
  final String name;
  final String? description;
  final TodoCategory category;
  final String visibility;
  final String? createdBy;
  final int revision;
  final DateTime? updatedAt;
  final int totalItems;
  final int completedItems;
  final int overdueItems;
  final int dueTodayItems;

  /// Optional cover photo (bucket todo-photos).
  final String? coverPath;

  bool get isPrivate => visibility == 'members';
  double get progress => totalItems == 0 ? 0 : completedItems / totalItems;
}

class TodoList {
  const TodoList({
    required this.id,
    required this.familyId,
    required this.name,
    required this.category,
    required this.visibility,
    required this.revision,
    this.description,
    this.createdBy,
    this.deletedAt,
    this.coverPath,
  });

  factory TodoList.fromJson(Map<String, dynamic> j) => TodoList(
    id: j['id'] as String,
    familyId: j['family_id'] as String,
    name: j['name'] as String,
    description: j['description'] as String?,
    category: TodoCategory.parse(j['category'] as String?),
    visibility: (j['visibility'] as String?) ?? 'family',
    createdBy: j['created_by'] as String?,
    revision: (j['revision'] as int?) ?? 1,
    deletedAt: _date(j['deleted_at']),
    coverPath: j['cover_path'] as String?,
  );

  final String id;
  final String familyId;
  final String name;
  final String? description;
  final TodoCategory category;
  final String visibility;
  final String? createdBy;
  final int revision;
  final DateTime? deletedAt;
  final String? coverPath;
}

enum TodoPhotoKind {
  before,
  after;

  static TodoPhotoKind parse(String? v) => v == 'after' ? after : before;
}

/// A before/after photo on an item (bucket todo-photos).
class TodoItemPhoto {
  const TodoItemPhoto({required this.id, required this.kind, required this.path, this.createdAt});

  factory TodoItemPhoto.fromJson(Map<String, dynamic> j) => TodoItemPhoto(
    id: j['id'] as String,
    kind: TodoPhotoKind.parse(j['kind'] as String?),
    path: j['path'] as String,
    createdAt: _date(j['created_at']),
  );

  /// Most photos of each kind per item (enforced by the database).
  static const maxPerKind = 4;

  final String id;
  final TodoPhotoKind kind;
  final String path;
  final DateTime? createdAt;
}

class TodoItem {
  const TodoItem({
    required this.id,
    required this.listId,
    required this.title,
    required this.completed,
    required this.priority,
    required this.recurrence,
    required this.revision,
    required this.position,
    this.familyId,
    this.description,
    this.dueAt,
    this.completedAt,
    this.completedBy,
    this.createdBy,
    this.assigneeIds = const [],
    this.deleted = false,
    this.createdAt,
    this.photos = const [],
  });

  factory TodoItem.fromJson(Map<String, dynamic> j) => TodoItem(
    id: j['id'] as String,
    listId: j['list_id'] as String,
    familyId: j['family_id'] as String?,
    title: j['title'] as String,
    description: j['description'] as String?,
    completed: j['status'] == 'completed',
    priority: TodoPriority.parse(j['priority'] as String?),
    recurrence: TodoRecurrence.parse(j['recurrence'] as String?),
    dueAt: _date(j['due_at']),
    completedAt: _date(j['completed_at']),
    completedBy: j['completed_by'] as String?,
    createdBy: j['created_by'] as String?,
    revision: (j['revision'] as int?) ?? 1,
    position: ((j['position'] as num?) ?? 0).toDouble(),
    deleted: j['deleted_at'] != null,
    createdAt: _date(j['created_at']),
    assigneeIds: j['todo_assignments'] is List
        ? (j['todo_assignments'] as List).map((a) => (a as Map<String, dynamic>)['user_id'] as String).toList()
        : const [],
    photos: j['todo_item_photos'] is List
        ? ((j['todo_item_photos'] as List).map((p) => TodoItemPhoto.fromJson(p as Map<String, dynamic>)).toList()
            ..sort((a, b) => (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0))))
        : const [],
  );

  /// Columns + assignees + photos used by every item query.
  static const select =
      'id, list_id, family_id, title, description, status, priority, due_at, recurrence, position, '
      'completed_at, completed_by, created_by, revision, deleted_at, created_at, todo_assignments(user_id), '
      'todo_item_photos(id, kind, path, created_at)';

  final String id;
  final String listId;
  final String? familyId;
  final String title;
  final String? description;
  final bool completed;
  final TodoPriority priority;
  final TodoRecurrence recurrence;
  final DateTime? dueAt;
  final DateTime? completedAt;
  final String? completedBy;
  final String? createdBy;
  final List<String> assigneeIds;
  final int revision;
  final double position;
  final bool deleted;
  final DateTime? createdAt;
  final List<TodoItemPhoto> photos;

  List<TodoItemPhoto> photosOf(TodoPhotoKind kind) => [
    for (final p in photos)
      if (p.kind == kind) p,
  ];

  bool isOverdue(DateTime now) => !completed && dueAt != null && dueAt!.isBefore(now);

  bool isDueOn(DateTime day) {
    final d = dueAt;
    if (d == null) return false;
    return d.year == day.year && d.month == day.month && d.day == day.day;
  }

  TodoItem copyWith({
    String? title,
    String? description,
    bool clearDescription = false,
    bool? completed,
    TodoPriority? priority,
    TodoRecurrence? recurrence,
    DateTime? dueAt,
    bool clearDueAt = false,
    DateTime? completedAt,
    List<String>? assigneeIds,
    int? revision,
    bool? deleted,
  }) => TodoItem(
    id: id,
    listId: listId,
    familyId: familyId,
    title: title ?? this.title,
    description: clearDescription ? null : (description ?? this.description),
    completed: completed ?? this.completed,
    priority: priority ?? this.priority,
    recurrence: recurrence ?? this.recurrence,
    dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
    completedAt: completed == false ? null : (completedAt ?? this.completedAt),
    completedBy: completedBy,
    createdBy: createdBy,
    assigneeIds: assigneeIds ?? this.assigneeIds,
    revision: revision ?? this.revision,
    position: position,
    deleted: deleted ?? this.deleted,
    createdAt: createdAt,
    photos: photos,
  );
}

class TodoComment {
  const TodoComment({
    required this.id,
    required this.itemId,
    required this.body,
    required this.createdAt,
    this.authorId,
    this.authorName,
    this.deleted = false,
  });

  factory TodoComment.fromJson(Map<String, dynamic> j) => TodoComment(
    id: j['id'] as String,
    itemId: j['item_id'] as String,
    body: j['body'] as String,
    createdAt: _date(j['created_at'])!,
    authorId: j['author_id'] as String?,
    authorName: (j['profiles'] as Map<String, dynamic>?)?['display_name'] as String?,
    deleted: j['deleted_at'] != null,
  );

  final String id;
  final String itemId;
  final String body;
  final DateTime createdAt;
  final String? authorId;
  final String? authorName;
  final bool deleted;
}

class TodoActivity {
  const TodoActivity({required this.id, required this.action, required this.createdAt, this.actorName, this.title});

  factory TodoActivity.fromJson(Map<String, dynamic> j) => TodoActivity(
    id: j['id'] as String,
    action: j['action'] as String,
    createdAt: _date(j['created_at'])!,
    actorName: (j['profiles'] as Map<String, dynamic>?)?['display_name'] as String?,
    title:
        (j['details'] as Map<String, dynamic>?)?['title'] as String? ??
        (j['details'] as Map<String, dynamic>?)?['name'] as String?,
  );

  final String id;
  final String action;
  final DateTime createdAt;
  final String? actorName;
  final String? title;
}
