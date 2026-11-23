import 'dart:async';

import 'package:familysync/core/errors/app_failure.dart';
import 'package:familysync/features/chat/data/chat_repository.dart';
import 'package:familysync/features/chat/domain/chat_models.dart';
import 'package:familysync/features/chat/presentation/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockChatRepo extends Mock implements ChatRepository {}

class _FakeChannel implements ConversationChannel {
  final controller = StreamController<ConversationEvent>.broadcast();
  final typingSent = <bool>[];

  @override
  Stream<ConversationEvent> get events => controller.stream;

  @override
  Future<void> sendTyping(String userId, {required bool typing}) async => typingSent.add(typing);
}

ChatMessage _msg(String id, {String sender = 'b', String body = 'hai', int minute = 0}) => ChatMessage(
  id: id,
  conversationId: 'C1',
  senderId: sender,
  kind: MessageKind.text,
  body: body,
  createdAt: DateTime(2026, 11, 23, 9, minute),
);

void main() {
  late _MockChatRepo repo;
  late _FakeChannel channel;

  setUp(() {
    repo = _MockChatRepo();
    channel = _FakeChannel();
    when(() => repo.currentUserId).thenReturn('me');
    when(() => repo.openConversation('C1')).thenReturn(channel);
    when(
      () => repo.messages(
        'C1',
        before: any(named: 'before'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => [_msg('m1', body: 'Assalamualaikum')]);
    when(() => repo.receipts('C1'))
        .thenAnswer((_) async => const [ChatReceipt(userId: 'me'), ChatReceipt(userId: 'b')]);
    when(() => repo.members('C1')).thenAnswer(
      (_) async => const [
        ConversationMember(userId: 'me', role: 'member'),
        ConversationMember(userId: 'b', role: 'member'),
      ],
    );
  });

  tearDown(() => channel.controller.close());

  Future<ProviderContainer> ready() async {
    final c = ProviderContainer(overrides: [chatRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(c.dispose);
    final sub = c.listen(conversationControllerProvider('C1'), (_, _) {});
    addTearDown(sub.close);
    await c.read(conversationControllerProvider('C1').future);
    return c;
  }

  ConversationState state(ProviderContainer c) => c.read(conversationControllerProvider('C1')).requireValue;

  test('send: shown as sending, becomes sent only after the server stores it', () async {
    final c = await ready();
    final gate = Completer<ChatMessage>();
    when(
      () => repo.send(
        id: any(named: 'id'),
        conversationId: 'C1',
        body: 'Waalaikumussalam',
        replyToId: any(named: 'replyToId'),
        attachments: any(named: 'attachments'),
      ),
    ).thenAnswer(
      (inv) => gate.future.then((m) => _msg(inv.namedArguments[#id] as String, sender: 'me', body: m.body!, minute: 5)),
    );

    final f = c.read(conversationControllerProvider('C1').notifier).send(body: 'Waalaikumussalam');
    await pumpEventQueue();
    final pending = state(c).messages.last;
    expect(pending.sendState, SendState.sending);
    expect(pending.body, 'Waalaikumussalam');

    gate.complete(_msg('x', sender: 'me', body: 'Waalaikumussalam'));
    await f;
    expect(state(c).messages.last.sendState, SendState.sent);
    expect(state(c).messages.where((m) => m.body == 'Waalaikumussalam').length, 1, reason: 'no duplicate');
  });

  test('failed send is marked failed and retry reuses the same message id', () async {
    final c = await ready();
    final ids = <String>[];
    var attempt = 0;
    when(
      () => repo.send(
        id: any(named: 'id'),
        conversationId: 'C1',
        body: any(named: 'body'),
        replyToId: any(named: 'replyToId'),
        attachments: any(named: 'attachments'),
      ),
    ).thenAnswer((inv) async {
      ids.add(inv.namedArguments[#id] as String);
      if (attempt++ == 0) throw const AppFailure(FailureKind.network);
      return _msg(inv.namedArguments[#id] as String, sender: 'me', body: 'ok', minute: 7);
    });

    final ctrl = c.read(conversationControllerProvider('C1').notifier);
    await expectLater(ctrl.send(body: 'ok'), throwsA(isA<AppFailure>()));
    final failed = state(c).messages.last;
    expect(failed.sendState, SendState.failed);

    await ctrl.retry(failed.id);
    expect(state(c).messages.last.sendState, SendState.sent);
    expect(ids.toSet().length, 1, reason: 'idempotent retry with the same client id');
  });

  test('realtime: incoming message is merged once; typing shows and clears', () async {
    final c = await ready();
    when(() => repo.message('m2')).thenAnswer((_) async => _msg('m2', body: 'Apa khabar?', minute: 3));

    channel.controller.add(const TypingEvent('b', typing: true));
    await pumpEventQueue();
    expect(state(c).typing.keys, ['b']);

    channel.controller.add(const MessageChanged('m2'));
    channel.controller.add(const MessageChanged('m2')); // duplicate delivery
    await pumpEventQueue();
    expect(state(c).messages.where((m) => m.id == 'm2').length, 1);
    expect(state(c).typing, isEmpty, reason: 'a message from the typist clears their indicator');
  });

  test('realtime: remote deletion and receipts update state', () async {
    final c = await ready();
    when(() => repo.message('m1')).thenAnswer(
      (_) async => ChatMessage(
        id: 'm1',
        conversationId: 'C1',
        senderId: 'b',
        kind: MessageKind.text,
        createdAt: DateTime(2026, 11, 23, 9),
        deletedAt: DateTime(2026, 11, 23, 10),
      ),
    );
    channel.controller.add(const MessageChanged('m1'));
    channel.controller.add(ReceiptChanged(ChatReceipt(userId: 'b', lastReadAt: DateTime(2026, 11, 23, 11))));
    await pumpEventQueue();
    expect(state(c).messages.single.isDeleted, isTrue);
    expect(state(c).receipts['b']!.lastReadAt, DateTime(2026, 11, 23, 11));
  });

  test('typing broadcasts are throttled', () async {
    final c = await ready();
    final ctrl = c.read(conversationControllerProvider('C1').notifier);
    await ctrl.sendTyping(true);
    await ctrl.sendTyping(true);
    await ctrl.sendTyping(true);
    expect(channel.typingSent, [true]);
  });
}
