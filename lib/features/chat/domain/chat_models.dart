/// Typed models matching `supabase/migrations/20261123000200_chat.sql`.
library;

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();

enum ConversationKind {
  direct,
  group;

  static ConversationKind parse(String? v) => v == 'group' ? group : direct;
}

enum MessageKind {
  text,
  image,
  file,
  system;

  static MessageKind parse(String? v) => MessageKind.values.firstWhere((k) => k.name == v, orElse: () => text);
}

/// Local delivery state of an outgoing message. A message is never shown as
/// sent before the server acknowledged it (send_message committed).
enum SendState { sending, sent, failed }

/// Receipt state of a sent message from the other side's point of view.
enum ReceiptState { sent, delivered, read }

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.memberCount,
    required this.unreadCount,
    this.name,
    this.description,
    this.imagePath,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.lastMessageSenderId,
    this.myRole = 'member',
    this.mutedUntil,
    this.pinnedAt,
    this.otherUserId,
  });

  factory ConversationSummary.fromJson(Map<String, dynamic> j) => ConversationSummary(
    id: j['id'] as String,
    kind: ConversationKind.parse(j['kind'] as String?),
    name: j['name'] as String?,
    description: j['description'] as String?,
    imagePath: j['image_path'] as String?,
    lastMessageAt: _date(j['last_message_at']),
    lastMessagePreview: j['last_message_preview'] as String?,
    lastMessageSenderId: j['last_message_sender_id'] as String?,
    createdAt: _date(j['created_at'])!,
    myRole: (j['my_role'] as String?) ?? 'member',
    mutedUntil: _date(j['muted_until']),
    pinnedAt: _date(j['pinned_at']),
    otherUserId: j['other_user_id'] as String?,
    memberCount: (j['member_count'] as int?) ?? 0,
    unreadCount: (j['unread_count'] as int?) ?? 0,
  );

  final String id;
  final ConversationKind kind;
  final String? name;
  final String? description;
  final String? imagePath;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final String? lastMessageSenderId;
  final DateTime createdAt;
  final String myRole;
  final DateTime? mutedUntil;
  final DateTime? pinnedAt;
  final String? otherUserId;
  final int memberCount;
  final int unreadCount;

  bool get isGroup => kind == ConversationKind.group;
  bool isMuted(DateTime now) => mutedUntil != null && mutedUntil!.isAfter(now);
  DateTime get sortTime => lastMessageAt ?? createdAt;
}

class ChatAttachment {
  const ChatAttachment({
    required this.storagePath,
    required this.mimeType,
    required this.sizeBytes,
    required this.fileName,
    this.width,
    this.height,
  });

  factory ChatAttachment.fromJson(Map<String, dynamic> j) => ChatAttachment(
    storagePath: j['storage_path'] as String,
    mimeType: j['mime_type'] as String,
    sizeBytes: j['size_bytes'] as int,
    fileName: j['file_name'] as String,
    width: j['width'] as int?,
    height: j['height'] as int?,
  );

  final String storagePath;
  final String mimeType;
  final int sizeBytes;
  final String fileName;
  final int? width;
  final int? height;

  bool get isImage => mimeType.startsWith('image/');

  Map<String, dynamic> toRpc() => {
    'path': storagePath,
    'mime_type': mimeType,
    'size_bytes': sizeBytes,
    'file_name': fileName,
    'width': ?width,
    'height': ?height,
  };
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.createdAt,
    this.senderId,
    this.body,
    this.meta,
    this.replyToId,
    this.editedAt,
    this.deletedAt,
    this.pinnedAt,
    this.attachments = const [],
    this.sendState = SendState.sent,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: j['id'] as String,
    conversationId: j['conversation_id'] as String,
    senderId: j['sender_id'] as String?,
    kind: MessageKind.parse(j['kind'] as String?),
    body: j['body'] as String?,
    meta: j['meta'] as Map<String, dynamic>?,
    replyToId: j['reply_to_id'] as String?,
    editedAt: _date(j['edited_at']),
    deletedAt: _date(j['deleted_at']),
    pinnedAt: _date(j['pinned_at']),
    createdAt: _date(j['created_at'])!,
    attachments: j['message_attachments'] is List
        ? (j['message_attachments'] as List).map((a) => ChatAttachment.fromJson(a as Map<String, dynamic>)).toList()
        : const [],
  );

  static const select =
      'id, conversation_id, sender_id, kind, body, meta, reply_to_id, edited_at, deleted_at, pinned_at, created_at, '
      'message_attachments(storage_path, mime_type, size_bytes, file_name, width, height)';

  final String id;
  final String conversationId;
  final String? senderId;
  final MessageKind kind;
  final String? body;
  final Map<String, dynamic>? meta;
  final String? replyToId;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final DateTime? pinnedAt;
  final DateTime createdAt;
  final List<ChatAttachment> attachments;
  final SendState sendState;

  bool get isDeleted => deletedAt != null;
  bool get isSystem => kind == MessageKind.system;

  ChatMessage copyWith({
    String? body,
    DateTime? editedAt,
    DateTime? deletedAt,
    DateTime? pinnedAt,
    bool clearPinned = false,
    SendState? sendState,
    DateTime? createdAt,
  }) => ChatMessage(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    kind: kind,
    body: deletedAt != null ? null : (body ?? this.body),
    meta: meta,
    replyToId: replyToId,
    editedAt: editedAt ?? this.editedAt,
    deletedAt: deletedAt ?? this.deletedAt,
    pinnedAt: clearPinned ? null : (pinnedAt ?? this.pinnedAt),
    createdAt: createdAt ?? this.createdAt,
    attachments: deletedAt != null ? const [] : attachments,
    sendState: sendState ?? this.sendState,
  );
}

class ChatReceipt {
  const ChatReceipt({required this.userId, this.lastDeliveredAt, this.lastReadAt});

  factory ChatReceipt.fromJson(Map<String, dynamic> j) => ChatReceipt(
    userId: j['user_id'] as String,
    lastDeliveredAt: _date(j['last_delivered_at']),
    lastReadAt: _date(j['last_read_at']),
  );

  final String userId;
  final DateTime? lastDeliveredAt;
  final DateTime? lastReadAt;
}

class ConversationMember {
  const ConversationMember({required this.userId, required this.role, this.displayName, this.avatarPath, this.leftAt});

  factory ConversationMember.fromJson(Map<String, dynamic> j) => ConversationMember(
    userId: j['user_id'] as String,
    role: (j['role'] as String?) ?? 'member',
    leftAt: _date(j['left_at']),
    displayName: (j['profiles'] as Map<String, dynamic>?)?['display_name'] as String?,
    avatarPath: (j['profiles'] as Map<String, dynamic>?)?['avatar_path'] as String?,
  );

  final String userId;
  final String role;
  final String? displayName;
  final String? avatarPath;
  final DateTime? leftAt;

  bool get isActive => leftAt == null;
  bool get isAdmin => role == 'admin';
}

class MessageSearchHit {
  const MessageSearchHit({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.createdAt,
    this.senderId,
  });

  factory MessageSearchHit.fromJson(Map<String, dynamic> j) => MessageSearchHit(
    id: j['id'] as String,
    conversationId: j['conversation_id'] as String,
    senderId: j['sender_id'] as String?,
    body: (j['body'] as String?) ?? '',
    createdAt: _date(j['created_at'])!,
  );

  final String id;
  final String conversationId;
  final String? senderId;
  final String body;
  final DateTime createdAt;
}
