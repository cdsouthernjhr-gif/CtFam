import 'package:familysync/features/chat/domain/chat_logic.dart';
import 'package:familysync/features/chat/domain/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 11, 23, 10);

ChatMessage _m(
  String id, {
  int minute = 0,
  String sender = 'a',
  SendState state = SendState.sent,
  String body = 'hai',
  MessageKind kind = MessageKind.text,
}) => ChatMessage(
  id: id,
  conversationId: 'c',
  senderId: sender,
  kind: kind,
  body: body,
  createdAt: _t0.add(Duration(minutes: minute)),
  sendState: state,
);

void main() {
  group('upsertMessage', () {
    test('dedupes by id and keeps chronological order', () {
      var list = upsertMessage(const [], _m('2', minute: 2));
      list = upsertMessage(list, _m('1', minute: 1));
      list = upsertMessage(list, _m('2', minute: 2, body: 'diubah'));
      expect(list.map((m) => m.id), ['1', '2']);
      expect(list.last.body, 'diubah');
    });

    test('server copy replaces a pending local copy, never the reverse', () {
      var list = upsertMessage(const [], _m('x', state: SendState.sending, body: 'lokal'));
      list = upsertMessage(list, _m('x', body: 'pelayan'));
      expect(list.single.sendState, SendState.sent);
      final again = upsertMessage(list, _m('x', state: SendState.sending, body: 'lokal lagi'));
      expect(again.single.body, 'pelayan', reason: 'a stale local copy must not overwrite the server copy');
    });

    test('pending messages sort after sent ones', () {
      final list = mergePage(const [], [_m('p', minute: 0, state: SendState.sending), _m('s', minute: 5)]);
      expect(list.map((m) => m.id), ['s', 'p']);
    });
  });

  group('receipts', () {
    final msg = _m('m', minute: 5, sender: 'me');

    test('direct chat: sent → delivered → read', () {
      expect(receiptStateFor(msg, 'me', [const ChatReceipt(userId: 'me')]), ReceiptState.sent);
      expect(
        receiptStateFor(msg, 'me', [ChatReceipt(userId: 'b', lastDeliveredAt: _t0.add(const Duration(minutes: 5)))]),
        ReceiptState.delivered,
      );
      expect(
        receiptStateFor(msg, 'me', [ChatReceipt(userId: 'b', lastReadAt: _t0.add(const Duration(minutes: 6)))]),
        ReceiptState.read,
      );
      expect(
        receiptStateFor(msg, 'me', [ChatReceipt(userId: 'b', lastReadAt: _t0.add(const Duration(minutes: 4)))]),
        ReceiptState.sent,
        reason: 'read cursor before the message does not count',
      );
    });

    test('group: read only when everyone read; readBy counts readers', () {
      final receipts = [
        ChatReceipt(userId: 'b', lastReadAt: _t0.add(const Duration(minutes: 9))),
        ChatReceipt(userId: 'c', lastDeliveredAt: _t0.add(const Duration(minutes: 9))),
        ChatReceipt(userId: 'me', lastReadAt: _t0.add(const Duration(minutes: 9))),
      ];
      expect(receiptStateFor(msg, 'me', receipts), ReceiptState.delivered);
      expect(readByCount(msg, 'me', receipts), 1);
    });
  });

  test('typing indicators expire', () {
    final now = DateTime(2026, 11, 23, 12);
    final pruned = pruneTyping({
      'b': now.subtract(const Duration(seconds: 2)),
      'c': now.subtract(const Duration(seconds: 9)),
    }, now);
    expect(pruned.keys, ['b']);
  });

  test('grouping of adjacent messages', () {
    expect(groupsWith(_m('1'), _m('2', minute: 1)), isTrue);
    expect(groupsWith(_m('1'), _m('2', minute: 5)), isFalse);
    expect(groupsWith(_m('1'), _m('2', sender: 'b')), isFalse);
    expect(groupsWith(_m('1', kind: MessageKind.system), _m('2')), isFalse);
  });

  test('attachments: mime, path sanitising, size', () {
    expect(chatMimeForFileName('Resit.PDF'), 'application/pdf');
    expect(chatMimeForFileName('foto.jpeg'), 'image/jpeg');
    expect(chatMimeForFileName('virus.exe'), isNull);
    expect(attachmentPath('c1', 'm1', 'Bil Elektrik (Nov).pdf'), 'c1/m1/Bil_Elektrik__Nov_.pdf');
    expect(
      attachmentPath('c1', 'm1', '../../etc/passwd'),
      'c1/m1/.._.._etc_passwd',
      reason: 'no path traversal: slashes are replaced',
    );
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
  });

  test('ChatMessage.fromJson reads attachments', () {
    final m = ChatMessage.fromJson({
      'id': 'm',
      'conversation_id': 'c',
      'sender_id': 'a',
      'kind': 'image',
      'created_at': '2026-11-23T02:00:00Z',
      'message_attachments': [
        {
          'storage_path': 'c/m/a.jpg',
          'mime_type': 'image/jpeg',
          'size_bytes': 10,
          'file_name': 'a.jpg',
          'width': 4,
          'height': 3,
        },
      ],
    });
    expect(m.kind, MessageKind.image);
    expect(m.attachments.single.isImage, isTrue);
    expect(m.attachments.single.toRpc()['path'], 'c/m/a.jpg');
  });
}
