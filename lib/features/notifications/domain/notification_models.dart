/// Models for `public.notifications` and the notification columns of
/// `public.user_preferences`.
library;

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    this.data = const {},
    this.readAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
    id: j['id'] as String,
    type: j['type'] as String,
    title: j['title'] as String,
    body: (j['body'] as String?) ?? '',
    data: (j['data'] as Map<String, dynamic>?) ?? const {},
    readAt: j['read_at'] == null ? null : DateTime.parse(j['read_at'] as String).toLocal(),
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
  );

  final String id;
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isRead => readAt != null;
  String? get route => safeNotificationRoute(data['route']);
}

class NotificationPrefs {
  const NotificationPrefs({
    this.privateMessages = true,
    this.groupMessages = true,
    this.tasks = true,
    this.events = true,
    this.announcements = true,
    this.showPreview = false,
    this.quietStart,
    this.quietEnd,
  });

  factory NotificationPrefs.fromJson(Map<String, dynamic> j) => NotificationPrefs(
    privateMessages: (j['notify_private_messages'] as bool?) ?? true,
    groupMessages: (j['notify_group_messages'] as bool?) ?? true,
    tasks: (j['notify_tasks'] as bool?) ?? true,
    events: (j['notify_events'] as bool?) ?? true,
    announcements: (j['notify_announcements'] as bool?) ?? true,
    showPreview: (j['show_message_preview'] as bool?) ?? false,
    quietStart: parseTimeOfDay(j['quiet_hours_start'] as String?),
    quietEnd: parseTimeOfDay(j['quiet_hours_end'] as String?),
  );

  static const columns =
      'notify_private_messages, notify_group_messages, notify_tasks, notify_events, notify_announcements, '
      'show_message_preview, quiet_hours_start, quiet_hours_end';

  final bool privateMessages;
  final bool groupMessages;
  final bool tasks;
  final bool events;
  final bool announcements;

  /// Show message content in notifications (default off for lock-screen privacy).
  final bool showPreview;

  /// Minutes since midnight, or null when quiet hours are off.
  final int? quietStart;
  final int? quietEnd;

  bool get quietHoursEnabled => quietStart != null && quietEnd != null && quietStart != quietEnd;
}

/// "22:30:00" → 1350 minutes.
int? parseTimeOfDay(String? v) {
  if (v == null) return null;
  final parts = v.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return h * 60 + m;
}

String formatTimeOfDay(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}:00';

final _uuidPart = RegExp(r'^[0-9a-fA-F-]{36}$');

/// Only in-app routes the app knows are allowed from a notification payload;
/// anything else (external URLs, unknown paths) is ignored.
String? safeNotificationRoute(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  const fixed = {'/home', '/family', '/chat', '/todo', '/calendar', '/notifications'};
  if (fixed.contains(raw)) return raw;
  final parts = raw.split('/');
  if (parts.length == 3 &&
      parts[0].isEmpty &&
      (parts[1] == 'chat' || parts[1] == 'todo' || parts[1] == 'calendar') &&
      _uuidPart.hasMatch(parts[2])) {
    return raw;
  }
  return null;
}
