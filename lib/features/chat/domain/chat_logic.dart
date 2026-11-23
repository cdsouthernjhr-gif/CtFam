import 'chat_models.dart';

/// Pure, unit-tested chat helpers.

/// Inserts or replaces [incoming] (deduplicated by id) and keeps the list
/// sorted oldest → newest. A server copy always replaces a local pending copy;
/// a local copy never replaces a server copy.
List<ChatMessage> upsertMessage(List<ChatMessage> current, ChatMessage incoming) {
  final idx = current.indexWhere((m) => m.id == incoming.id);
  final next = List<ChatMessage>.of(current);
  if (idx >= 0) {
    final existing = next[idx];
    if (existing.sendState == SendState.sent && incoming.sendState != SendState.sent) return current;
    next[idx] = incoming;
  } else {
    next.add(incoming);
  }
  next.sort(compareMessages);
  return next;
}

/// Merges a page of older messages fetched from the server.
List<ChatMessage> mergePage(List<ChatMessage> current, List<ChatMessage> page) {
  var out = current;
  for (final m in page) {
    out = upsertMessage(out, m);
  }
  return out;
}

int compareMessages(ChatMessage a, ChatMessage b) {
  // Unsent local messages always sort last, in creation order.
  final ap = a.sendState != SendState.sent, bp = b.sendState != SendState.sent;
  if (ap != bp) return ap ? 1 : -1;
  final c = a.createdAt.compareTo(b.createdAt);
  return c != 0 ? c : a.id.compareTo(b.id);
}

/// Receipt state of [message] sent by [me], given everyone's receipts.
/// Direct chat: the other participant's cursors. Group: read/delivered only
/// when every other active member has reached it.
ReceiptState receiptStateFor(ChatMessage message, String me, Iterable<ChatReceipt> receipts) {
  final others = receipts.where((r) => r.userId != me).toList();
  if (others.isEmpty) return ReceiptState.sent;
  bool reached(DateTime? at) => at != null && !at.isBefore(message.createdAt);
  if (others.every((r) => reached(r.lastReadAt))) return ReceiptState.read;
  if (others.every((r) => reached(r.lastDeliveredAt) || reached(r.lastReadAt))) return ReceiptState.delivered;
  return ReceiptState.sent;
}

/// Number of other members who have read [message] (group "read by N").
int readByCount(ChatMessage message, String me, Iterable<ChatReceipt> receipts) =>
    receipts.where((r) => r.userId != me && r.lastReadAt != null && !r.lastReadAt!.isBefore(message.createdAt)).length;

/// Typing indicators expire if no new "typing" broadcast arrives.
const typingTimeout = Duration(seconds: 5);

/// Drops typing entries older than [typingTimeout].
Map<String, DateTime> pruneTyping(Map<String, DateTime> typing, DateTime now) => {
  for (final e in typing.entries)
    if (now.difference(e.value) < typingTimeout) e.key: e.value,
};

/// Whether two adjacent messages should be visually grouped (same sender,
/// within 3 minutes, neither is a system message).
bool groupsWith(ChatMessage previous, ChatMessage next) =>
    !previous.isSystem &&
    !next.isSystem &&
    previous.senderId == next.senderId &&
    next.createdAt.difference(previous.createdAt).inMinutes < 3;

bool isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// MIME type for a picked file name (only types the server accepts).
String? chatMimeForFileName(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'doc' => 'application/msword',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => null,
  };
}

const chatDocumentExtensions = ['pdf', 'txt', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'];
const maxAttachmentBytes = 10 * 1024 * 1024;

/// Storage object name: {conversation}/{message}/{sanitised file name}.
String attachmentPath(String conversationId, String messageId, String fileName) {
  final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final trimmed = safe.length > 100 ? safe.substring(safe.length - 100) : safe;
  return '$conversationId/$messageId/${trimmed.isEmpty ? 'file' : trimmed}';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
