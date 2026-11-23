import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/chat_logic.dart';
import '../domain/chat_models.dart';

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => ChatRepository(ref.watch(supabaseClientProvider), offline: ref.watch(offlineStoreProvider)),
);

/// Events of one open conversation (channel `conversation:{id}`, private).
sealed class ConversationEvent {
  const ConversationEvent();
}

class MessageChanged extends ConversationEvent {
  const MessageChanged(this.id);
  final String id;
}

class ReceiptChanged extends ConversationEvent {
  const ReceiptChanged(this.receipt);
  final ChatReceipt receipt;
}

class MembersChanged extends ConversationEvent {
  const MembersChanged();
}

class TypingEvent extends ConversationEvent {
  const TypingEvent(this.userId, {required this.typing});
  final String userId;
  final bool typing;
}

/// Emitted after (re)subscribing; callers reconcile with a refetch.
class Resubscribed extends ConversationEvent {
  const Resubscribed();
}

/// A live connection to one conversation channel.
abstract class ConversationChannel {
  Stream<ConversationEvent> get events;
  Future<void> sendTyping(String userId, {required bool typing});
}

class _RealtimeConversationChannel implements ConversationChannel {
  _RealtimeConversationChannel(this._channel, this.events);

  final RealtimeChannel _channel;

  @override
  final Stream<ConversationEvent> events;

  @override
  Future<void> sendTyping(String userId, {required bool typing}) =>
      _channel.sendBroadcastMessage(event: 'typing', payload: {'user_id': userId, 'typing': typing});
}

class ChatRepository {
  ChatRepository(this._client, {this._offline});

  final SupabaseClient _client;
  final OfflineStore? _offline;

  // Offline: last successful responses are served when the network is down.
  Future<List<Map<String, dynamic>>> _cachedRows(String key, Future<List<dynamic>> Function() fetch) {
    final store = _offline;
    if (store == null) return fetch().then((r) => [for (final x in r) Map<String, dynamic>.from(x as Map)]);
    return store.rows(key, fetch);
  }

  String? get currentUserId => _client.auth.currentUser?.id;

  // ------------------------------------------------------------ conversations
  Future<List<ConversationSummary>> summaries(String familyId) => _guard(() async {
    final rows = await _cachedRows(
      'chat:summaries:$familyId',
      () => _client.rpc<List<dynamic>>('conversation_summaries', params: {'p_family_id': familyId}),
    );
    return rows.map(ConversationSummary.fromJson).toList();
  });

  Future<String> openDirect(String familyId, String otherUserId) => _guard(
    () => _client.rpc<String>(
      'get_or_create_direct_conversation',
      params: {'p_family_id': familyId, 'p_other_user_id': otherUserId},
    ),
  );

  Future<String> createGroup({
    required String id,
    required String familyId,
    required String name,
    String? description,
    required List<String> memberIds,
  }) => _guard(
    () => _client.rpc<String>(
      'create_group_conversation',
      params: {
        'p_id': id,
        'p_family_id': familyId,
        'p_name': name.trim(),
        'p_description': description?.trim(),
        'p_member_ids': memberIds,
      },
    ),
  );

  Future<void> updateGroup(String id, {required String name, String? description}) => _guard(
    () => _client.rpc<void>(
      'update_group_conversation',
      params: {'p_id': id, 'p_name': name.trim(), 'p_description': description?.trim()},
    ),
  );

  Future<void> addMembers(String id, List<String> userIds) =>
      _guard(() => _client.rpc<int>('add_conversation_members', params: {'p_id': id, 'p_user_ids': userIds}));

  Future<void> removeMember(String id, String userId) =>
      _guard(() => _client.rpc<void>('remove_conversation_member', params: {'p_id': id, 'p_user_id': userId}));

  Future<void> setMemberRole(String id, String userId, String role) => _guard(
    () => _client.rpc<void>('set_conversation_member_role', params: {'p_id': id, 'p_user_id': userId, 'p_role': role}),
  );

  Future<void> leave(String id) => _guard(() => _client.rpc<void>('leave_conversation', params: {'p_id': id}));

  Future<List<ConversationMember>> members(String conversationId) => _guard(() async {
    final rows = await _client
        .from('conversation_members')
        .select('user_id, role, left_at, profiles(display_name, avatar_path)')
        .eq('conversation_id', conversationId)
        .isFilter('left_at', null);
    return rows.map(ConversationMember.fromJson).toList();
  });

  Future<void> setMuted(String conversationId, DateTime? until) => _guard(
    () => _client
        .from('conversation_members')
        .update({'muted_until': until?.toUtc().toIso8601String()})
        .eq('conversation_id', conversationId)
        .eq('user_id', currentUserId!),
  );

  // ------------------------------------------------------------ messages
  /// Newest-first page; [before] = createdAt of the oldest message held.
  Future<List<ChatMessage>> messages(String conversationId, {DateTime? before, int limit = 40}) => _guard(() async {
    var q = _client.from('messages').select(ChatMessage.select).eq('conversation_id', conversationId);
    if (before != null) q = q.lt('created_at', before.toUtc().toIso8601String());
    final query = q.order('created_at', ascending: false).order('id', ascending: false).limit(limit);
    // Only the latest page is kept for offline reading.
    final rows = before == null ? await _cachedRows('chat:messages:$conversationId', () => query) : await query;
    return rows.map(ChatMessage.fromJson).toList();
  });

  Future<ChatMessage?> message(String id) => _guard(() async {
    final row = await _client.from('messages').select(ChatMessage.select).eq('id', id).maybeSingle();
    return row == null ? null : ChatMessage.fromJson(row);
  });

  Future<List<ChatMessage>> pinned(String conversationId) => _guard(() async {
    final rows = await _client
        .from('messages')
        .select(ChatMessage.select)
        .eq('conversation_id', conversationId)
        .not('pinned_at', 'is', null)
        .isFilter('deleted_at', null)
        .order('pinned_at', ascending: false);
    return rows.map(ChatMessage.fromJson).toList();
  });

  /// Idempotent: retrying with the same [id] never duplicates the message.
  Future<ChatMessage> send({
    required String id,
    required String conversationId,
    String? body,
    String? replyToId,
    List<ChatAttachment> attachments = const [],
  }) => _guard(() async {
    await _client.rpc<Map<String, dynamic>>(
      'send_message',
      params: sendParams(
        id: id,
        conversationId: conversationId,
        body: body,
        replyToId: replyToId,
        attachments: attachments,
      ),
    );
    return (await message(id))!;
  });

  /// RPC parameters for `send_message` (shared with the offline outbox).
  static Map<String, dynamic> sendParams({
    required String id,
    required String conversationId,
    String? body,
    String? replyToId,
    List<ChatAttachment> attachments = const [],
  }) => {
    'p_id': id,
    'p_conversation_id': conversationId,
    'p_body': body,
    'p_reply_to_id': replyToId,
    'p_attachments': attachments.map((a) => a.toRpc()).toList(),
  };

  Future<String> uploadAttachment({
    required String conversationId,
    required String messageId,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) => _guard(() async {
    final path = attachmentPath(conversationId, messageId, fileName);
    await _client.storage
        .from('chat-attachments')
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mimeType, upsert: true));
    return path;
  });

  Future<void> edit(String id, String body) =>
      _guard(() => _client.rpc<Map<String, dynamic>>('edit_message', params: {'p_id': id, 'p_body': body}));

  Future<void> delete(String id) => _guard(() => _client.rpc<void>('delete_message', params: {'p_id': id}));

  Future<void> setPinned(String id, {required bool pinned}) =>
      _guard(() => _client.rpc<void>('set_message_pinned', params: {'p_id': id, 'p_pinned': pinned}));

  Future<void> markRead(String conversationId, {DateTime? upTo}) => _guard(
    () => _client.rpc<void>(
      'mark_conversation_read',
      params: {'p_conversation_id': conversationId, 'p_up_to': upTo?.toUtc().toIso8601String()},
    ),
  );

  Future<void> markFamilyDelivered(String familyId) =>
      _guard(() => _client.rpc<void>('mark_family_delivered', params: {'p_family_id': familyId}));

  Future<List<ChatReceipt>> receipts(String conversationId) => _guard(() async {
    final rows = await _cachedRows(
      'chat:receipts:$conversationId',
      () => _client
          .from('message_receipts')
          .select('user_id, last_delivered_at, last_read_at')
          .eq('conversation_id', conversationId),
    );
    return rows.map(ChatReceipt.fromJson).toList();
  });

  Future<List<MessageSearchHit>> search(String familyId, String query) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>(
      'search_messages',
      params: {'p_family_id': familyId, 'p_query': query},
    );
    return rows.map((r) => MessageSearchHit.fromJson(r as Map<String, dynamic>)).toList();
  });

  // ------------------------------------------------------------ realtime
  /// Opens the private channel `conversation:{id}`: Postgres Changes for
  /// messages / receipts / members (RLS-aware) and Broadcast for typing.
  /// Cancel the stream subscription to leave the channel.
  ConversationChannel openConversation(String conversationId) {
    final topic = 'conversation:$conversationId';
    final channel = _client.channel(topic, opts: const RealtimeChannelConfig(private: true));
    final controller = StreamController<ConversationEvent>.broadcast();
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'conversation_id',
      value: conversationId,
    );
    channel
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'messages',
        filter: filter,
        callback: (p) {
          final id = (p.newRecord['id'] ?? p.oldRecord['id']) as String?;
          if (id != null) controller.add(MessageChanged(id));
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'message_receipts',
        filter: filter,
        callback: (p) {
          if (p.newRecord.isNotEmpty) controller.add(ReceiptChanged(ChatReceipt.fromJson(p.newRecord)));
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'conversation_members',
        filter: filter,
        callback: (_) => controller.add(const MembersChanged()),
      )
      ..onBroadcast(
        event: 'typing',
        callback: (payload) {
          final uid = payload['user_id'] as String?;
          if (uid != null) controller.add(TypingEvent(uid, typing: payload['typing'] == true));
        },
      );
    controller.onListen = () => channel.subscribe((status, _) {
      if (status == RealtimeSubscribeStatus.subscribed) controller.add(const Resubscribed());
    });
    controller.onCancel = () async {
      await _client.removeChannel(channel);
      await controller.close();
    };
    return _RealtimeConversationChannel(channel, controller.stream);
  }

  /// Conversation list changes for the family (new messages bump the
  /// conversation row). Channel `chats:{familyId}`.
  Stream<void> watchFamilyChats(String familyId) {
    late final RealtimeChannel channel;
    final controller = StreamController<void>.broadcast();
    controller.onListen = () {
      channel = _client
          .channel('chats:$familyId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'conversations',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'family_id', value: familyId),
            callback: (_) => controller.add(null),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'conversation_members',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'family_id', value: familyId),
            callback: (_) => controller.add(null),
          )
          .subscribe((status, _) {
            if (status == RealtimeSubscribeStatus.subscribed) controller.add(null);
          });
    };
    controller.onCancel = () async {
      await _client.removeChannel(channel);
      await controller.close();
    };
    return controller.stream;
  }

  /// Family-wide Presence (private channel `presence:family:{id}`). Emits the
  /// set of online user ids whenever it changes.
  Stream<Set<String>> watchPresence(String familyId, String me) {
    late final RealtimeChannel channel;
    final controller = StreamController<Set<String>>.broadcast();
    Set<String> online() => {
      for (final s in channel.presenceState())
        for (final p in s.presences)
          if (p.payload['user_id'] is String) p.payload['user_id'] as String,
    };
    controller.onListen = () {
      channel = _client.channel('presence:family:$familyId', opts: RealtimeChannelConfig(private: true, key: me));
      channel
          .onPresenceSync((_) => controller.add(online()))
          .onPresenceJoin((_) => controller.add(online()))
          .onPresenceLeave((_) => controller.add(online()))
          .subscribe((status, _) async {
            if (status == RealtimeSubscribeStatus.subscribed) {
              await channel.track({'user_id': me, 'online_at': DateTime.now().toUtc().toIso8601String()});
            }
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
