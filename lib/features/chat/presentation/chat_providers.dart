import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/providers/session_controller.dart';
import '../data/chat_repository.dart';
import '../domain/chat_logic.dart';
import '../domain/chat_models.dart';

const _uuid = Uuid();
String newChatId() => _uuid.v4();

// -----------------------------------------------------------------------------
// Conversation list
// -----------------------------------------------------------------------------
final chatFamilyTickProvider = StreamProvider.autoDispose.family<int, String>((ref, familyId) {
  final controller = StreamController<int>();
  var tick = 0;
  Timer? debounce;
  final sub = ref.watch(chatRepositoryProvider).watchFamilyChats(familyId).listen((_) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () => controller.add(++tick));
  });
  ref.onDispose(() {
    debounce?.cancel();
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

final conversationSummariesProvider = FutureProvider.autoDispose.family<List<ConversationSummary>, String>((
  ref,
  familyId,
) async {
  ref.watch(chatFamilyTickProvider(familyId));
  final repo = ref.watch(chatRepositoryProvider);
  final list = await repo.summaries(familyId);
  unawaited(repo.markFamilyDelivered(familyId).catchError((_) {}));
  return list;
});

/// Total unread messages across unmuted conversations (bottom-nav badge).
final totalUnreadProvider = Provider.autoDispose<int>((ref) {
  final familyId = ref.watch(activeFamilyIdProvider);
  if (familyId == null) return 0;
  final list = ref.watch(conversationSummariesProvider(familyId)).value ?? const [];
  final now = DateTime.now();
  return list.where((c) => !c.isMuted(now)).fold<int>(0, (sum, c) => sum + c.unreadCount);
});

/// Online family members (Presence). Kept alive by the home shell.
final onlineUsersProvider = StreamProvider.autoDispose<Set<String>>((ref) {
  final familyId = ref.watch(activeFamilyIdProvider);
  final me = ref.watch(currentUserIdProvider);
  if (familyId == null || me == null) return Stream.value(const {});
  return ref.watch(chatRepositoryProvider).watchPresence(familyId, me);
});

final messageSearchProvider = FutureProvider.autoDispose.family<List<MessageSearchHit>, ({String familyId, String q})>((
  ref,
  arg,
) async {
  if (arg.q.trim().length < 2) return const [];
  await Future<void>.delayed(const Duration(milliseconds: 300)); // debounce typing
  return ref.watch(chatRepositoryProvider).search(arg.familyId, arg.q);
});

// -----------------------------------------------------------------------------
// One conversation
// -----------------------------------------------------------------------------
class PendingUpload {
  const PendingUpload({required this.fileName, required this.mimeType, required this.bytes, this.width, this.height});

  final String fileName;
  final String mimeType;
  final Uint8List bytes;
  final int? width;
  final int? height;
}

class ConversationState {
  const ConversationState({
    required this.messages,
    required this.receipts,
    required this.members,
    this.hasMore = true,
    this.loadingMore = false,
    this.typing = const {},
  });

  /// Oldest → newest (UI renders reversed).
  final List<ChatMessage> messages;
  final Map<String, ChatReceipt> receipts;
  final List<ConversationMember> members;
  final bool hasMore;
  final bool loadingMore;

  /// userId → last "typing" broadcast time.
  final Map<String, DateTime> typing;

  ConversationState copyWith({
    List<ChatMessage>? messages,
    Map<String, ChatReceipt>? receipts,
    List<ConversationMember>? members,
    bool? hasMore,
    bool? loadingMore,
    Map<String, DateTime>? typing,
  }) => ConversationState(
    messages: messages ?? this.messages,
    receipts: receipts ?? this.receipts,
    members: members ?? this.members,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    typing: typing ?? this.typing,
  );

  ChatMessage? byId(String? id) {
    if (id == null) return null;
    for (final m in messages) {
      if (m.id == id) return m;
    }
    return null;
  }
}

final conversationControllerProvider = AsyncNotifierProvider.autoDispose
    .family<ConversationController, ConversationState, String>(ConversationController.new);

class ConversationController extends AsyncNotifier<ConversationState> {
  ConversationController(this.conversationId);

  final String conversationId;
  static const pageSize = 40;

  ConversationChannel? _channel;
  Timer? _typingPrune;
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);
  bool _firstSubscribe = true;

  /// Unsent payloads by message id (for retry after failure).
  final Map<String, ({String? body, String? replyToId, List<PendingUpload> uploads})> _outbox = {};

  ChatRepository get _repo => ref.read(chatRepositoryProvider);
  String? get _me => _repo.currentUserId;

  @override
  Future<ConversationState> build() async {
    final repo = ref.watch(chatRepositoryProvider);
    final channel = repo.openConversation(conversationId);
    _channel = channel;
    final sub = channel.events.listen(_onEvent, onError: (_) {});
    _typingPrune = Timer.periodic(const Duration(seconds: 2), (_) => _pruneTyping());
    ref.onDispose(() {
      sub.cancel();
      _typingPrune?.cancel();
    });
    final results = await Future.wait([
      repo.messages(conversationId, limit: pageSize),
      repo.receipts(conversationId),
      repo.members(conversationId),
    ]);
    final page = results[0] as List<ChatMessage>;
    return ConversationState(
      messages: mergePage(const [], page),
      receipts: {for (final r in results[1] as List<ChatReceipt>) r.userId: r},
      members: results[2] as List<ConversationMember>,
      hasMore: page.length >= pageSize,
    );
  }

  ConversationState? get _s => state.value;
  void _set(ConversationState s) => state = AsyncData(s);

  Future<void> _onEvent(ConversationEvent e) async {
    switch (e) {
      case MessageChanged(:final id):
        final m = await _repo.message(id).catchError((_) => null);
        final s = _s;
        if (m == null || s == null) return;
        final typing = Map<String, DateTime>.of(s.typing)..remove(m.senderId);
        _set(s.copyWith(messages: upsertMessage(s.messages, m), typing: typing));
      case ReceiptChanged(:final receipt):
        final s = _s;
        if (s != null) _set(s.copyWith(receipts: {...s.receipts, receipt.userId: receipt}));
      case MembersChanged():
        final members = await _repo.members(conversationId).catchError((_) => _s?.members ?? const []);
        final s = _s;
        if (s != null) _set(s.copyWith(members: members));
      case TypingEvent(:final userId, :final typing):
        final s = _s;
        if (s == null || userId == _me) return;
        final next = Map<String, DateTime>.of(s.typing);
        typing ? next[userId] = DateTime.now() : next.remove(userId);
        _set(s.copyWith(typing: next));
      case Resubscribed():
        if (_firstSubscribe) {
          _firstSubscribe = false;
          return;
        }
        await _reconcile(); // reconnect: fetch what we missed
    }
  }

  Future<void> _reconcile() async {
    final latest = await _repo.messages(conversationId, limit: pageSize).catchError((_) => <ChatMessage>[]);
    final receipts = await _repo.receipts(conversationId).catchError((_) => <ChatReceipt>[]);
    final s = _s;
    if (s == null) return;
    _set(
      s.copyWith(
        messages: mergePage(s.messages, latest),
        receipts: {...s.receipts, for (final r in receipts) r.userId: r},
      ),
    );
  }

  void _pruneTyping() {
    final s = _s;
    if (s == null || s.typing.isEmpty) return;
    final pruned = pruneTyping(s.typing, DateTime.now());
    if (pruned.length != s.typing.length) _set(s.copyWith(typing: pruned));
  }

  Future<void> loadOlder() async {
    final s = _s;
    if (s == null || !s.hasMore || s.loadingMore) return;
    final oldest = s.messages.where((m) => m.sendState == SendState.sent).firstOrNull;
    _set(s.copyWith(loadingMore: true));
    try {
      final page = await _repo.messages(conversationId, before: oldest?.createdAt, limit: pageSize);
      final cur = _s!;
      _set(cur.copyWith(messages: mergePage(cur.messages, page), hasMore: page.length >= pageSize, loadingMore: false));
    } catch (_) {
      _set(_s!.copyWith(loadingMore: false));
      rethrow;
    }
  }

  /// Sends a message. Shown immediately as "sending"; becomes "sent" only after
  /// the server stored it; "failed" (with retry) otherwise.
  Future<void> send({String? body, String? replyToId, List<PendingUpload> uploads = const []}) async {
    final text = body?.trim();
    if ((text == null || text.isEmpty) && uploads.isEmpty) return;
    final id = newChatId();
    _outbox[id] = (body: text, replyToId: replyToId, uploads: uploads);
    await _deliver(id);
  }

  Future<void> retry(String messageId) => _deliver(messageId);

  void discardFailed(String messageId) {
    _outbox.remove(messageId);
    final s = _s;
    if (s != null) _set(s.copyWith(messages: s.messages.where((m) => m.id != messageId).toList()));
  }

  Future<void> _deliver(String id) async {
    final payload = _outbox[id];
    final s = _s;
    if (payload == null || s == null) return;
    final local = ChatMessage(
      id: id,
      conversationId: conversationId,
      senderId: _me,
      kind: payload.uploads.isEmpty
          ? MessageKind.text
          : (payload.uploads.every((u) => u.mimeType.startsWith('image/')) ? MessageKind.image : MessageKind.file),
      body: payload.body,
      replyToId: payload.replyToId,
      createdAt: DateTime.now(),
      sendState: SendState.sending,
      attachments: [
        for (final u in payload.uploads)
          ChatAttachment(
            storagePath: '',
            mimeType: u.mimeType,
            sizeBytes: u.bytes.length,
            fileName: u.fileName,
            width: u.width,
            height: u.height,
          ),
      ],
    );
    _set(s.copyWith(messages: _replaceLocal(s.messages, local)));
    try {
      final attachments = <ChatAttachment>[];
      for (final u in payload.uploads) {
        final path = await _repo.uploadAttachment(
          conversationId: conversationId,
          messageId: id,
          fileName: u.fileName,
          mimeType: u.mimeType,
          bytes: u.bytes,
        );
        attachments.add(
          ChatAttachment(
            storagePath: path,
            mimeType: u.mimeType,
            sizeBytes: u.bytes.length,
            fileName: u.fileName,
            width: u.width,
            height: u.height,
          ),
        );
      }
      final saved = await _repo.send(
        id: id,
        conversationId: conversationId,
        body: payload.body,
        replyToId: payload.replyToId,
        attachments: attachments,
      );
      _outbox.remove(id);
      final cur = _s!;
      _set(cur.copyWith(messages: upsertMessage(cur.messages.where((m) => m.id != id).toList(), saved)));
      unawaited(sendTyping(false));
    } catch (e) {
      final cur = _s!;
      _set(cur.copyWith(messages: _replaceLocal(cur.messages, local.copyWith(sendState: SendState.failed))));
      rethrow;
    }
  }

  List<ChatMessage> _replaceLocal(List<ChatMessage> list, ChatMessage local) {
    final next = list.where((m) => m.id != local.id).toList()..add(local);
    next.sort(compareMessages);
    return next;
  }

  Future<void> edit(ChatMessage m, String body) async {
    final s = _s;
    if (s == null) return;
    _set(
      s.copyWith(
        messages: upsertMessage(s.messages, m.copyWith(body: body, editedAt: DateTime.now())),
      ),
    );
    try {
      await _repo.edit(m.id, body);
    } catch (_) {
      final cur = _s!;
      _set(cur.copyWith(messages: upsertMessage(cur.messages, m)));
      rethrow;
    }
  }

  Future<void> delete(ChatMessage m) async {
    final s = _s;
    if (s == null) return;
    _set(s.copyWith(messages: upsertMessage(s.messages, m.copyWith(deletedAt: DateTime.now()))));
    try {
      await _repo.delete(m.id);
    } catch (_) {
      final cur = _s!;
      _set(cur.copyWith(messages: upsertMessage(cur.messages, m)));
      rethrow;
    }
  }

  Future<void> setPinned(ChatMessage m, {required bool pinned}) async {
    await _repo.setPinned(m.id, pinned: pinned);
    final fresh = await _repo.message(m.id);
    final s = _s;
    if (fresh != null && s != null) _set(s.copyWith(messages: upsertMessage(s.messages, fresh)));
  }

  /// Marks everything up to the newest received message as read.
  Future<void> markRead() async {
    final s = _s;
    final me = _me;
    if (s == null || me == null || s.messages.isEmpty) return;
    final newest = s.messages.lastWhere((m) => m.sendState == SendState.sent, orElse: () => s.messages.first);
    final mine = s.receipts[me]?.lastReadAt;
    if (mine != null && !newest.createdAt.isAfter(mine)) return;
    await _repo.markRead(conversationId, upTo: newest.createdAt);
  }

  /// Throttled typing broadcast (at most every 2 s while typing).
  Future<void> sendTyping(bool typing) async {
    final me = _me;
    final ch = _channel;
    if (me == null || ch == null) return;
    final now = DateTime.now();
    if (typing && now.difference(_lastTypingSent) < const Duration(seconds: 2)) return;
    _lastTypingSent = typing ? now : DateTime.fromMillisecondsSinceEpoch(0);
    await ch.sendTyping(me, typing: typing).catchError((_) => null);
  }
}

final pinnedMessagesProvider = FutureProvider.autoDispose.family<List<ChatMessage>, String>((ref, conversationId) {
  ref.watch(
    conversationControllerProvider(conversationId)
        .select((s) => s.value?.messages.where((m) => m.pinnedAt != null).map((m) => m.id).join(',')),
  );
  return ref.watch(chatRepositoryProvider).pinned(conversationId);
});
