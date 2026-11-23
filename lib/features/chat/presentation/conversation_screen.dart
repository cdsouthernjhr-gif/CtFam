import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/chat_repository.dart';
import '../domain/chat_logic.dart';
import '../domain/chat_models.dart';
import 'chat_providers.dart';
import 'chat_screen.dart';
import 'message_bubble.dart';

class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({required this.conversationId, super.key});

  final String conversationId;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  ChatMessage? _replyTo;
  ChatMessage? _editing;
  Timer? _readDebounce;

  ConversationController get _ctrl => ref.read(conversationControllerProvider(widget.conversationId).notifier);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        _ctrl.loadOlder().catchError((_) {});
      }
    });
  }

  @override
  void dispose() {
    _readDebounce?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) context.showError(e);
    }
  }

  void _scheduleMarkRead() {
    _readDebounce?.cancel();
    _readDebounce = Timer(const Duration(milliseconds: 600), () => _ctrl.markRead().catchError((_) {}));
  }

  Future<void> _submit() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    final reply = _replyTo;
    _input.clear();
    setState(() {
      _editing = null;
      _replyTo = null;
    });
    if (editing != null) {
      await _guard(() => _ctrl.edit(editing, text));
    } else {
      await _guard(() => _ctrl.send(body: text, replyToId: reply?.id));
    }
  }

  Future<void> _attach() async {
    final l10n = context.l10n;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.attachPhoto),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(l10n.attachCamera),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(l10n.attachDocument),
              onTap: () => Navigator.pop(ctx, 'doc'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final uploads = <PendingUpload>[];
    if (choice == 'doc') {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: chatDocumentExtensions);
      for (final f in files) {
        final mime = chatMimeForFileName(f.name);
        final bytes = await f.readAsBytes();
        if (mime == null || bytes.length > maxAttachmentBytes) {
          if (mounted) context.showMessage(l10n.attachmentRejected, error: true);
          return;
        }
        uploads.add(PendingUpload(fileName: f.name, mimeType: mime, bytes: bytes));
      }
    } else {
      final img = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1920,
        imageQuality: 80,
      );
      if (img == null) return;
      final bytes = await img.readAsBytes();
      final mime = chatMimeForFileName(img.name) ?? img.mimeType;
      if (mime == null || !mime.startsWith('image/') || bytes.length > maxAttachmentBytes) {
        if (mounted) context.showMessage(l10n.attachmentRejected, error: true);
        return;
      }
      int? width, height;
      try {
        final decoded = await decodeImageFromList(bytes);
        width = decoded.width;
        height = decoded.height;
        decoded.dispose();
      } catch (_) {
        // Dimensions are optional (layout hint only).
      }
      uploads.add(PendingUpload(fileName: img.name, mimeType: mime, bytes: bytes, width: width, height: height));
    }
    if (uploads.isEmpty) return;
    final caption = _input.text.trim();
    _input.clear();
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await _guard(() => _ctrl.send(body: caption.isEmpty ? null : caption, replyToId: reply?.id, uploads: uploads));
  }

  Future<void> _actions(ChatMessage m, {required bool isMine, required bool canModerate, required bool isGroup}) async {
    final l10n = context.l10n;
    final canPin = !isGroup || canModerate;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text(l10n.reply),
              onTap: () => Navigator.pop(ctx, 'reply'),
            ),
            if ((m.body ?? '').isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(l10n.actionCopy),
                onTap: () => Navigator.pop(ctx, 'copy'),
              ),
            if (isMine && (m.body ?? '').isNotEmpty)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.editMessage),
                onTap: () => Navigator.pop(ctx, 'edit'),
              ),
            if (canPin)
              ListTile(
                leading: Icon(m.pinnedAt == null ? Icons.push_pin_outlined : Icons.push_pin),
                title: Text(m.pinnedAt == null ? l10n.pinMessage : l10n.unpinMessage),
                onTap: () => Navigator.pop(ctx, 'pin'),
              ),
            if (isMine || canModerate)
              ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                title: Text(l10n.deleteMessage, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'reply':
        setState(() {
          _replyTo = m;
          _editing = null;
        });
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.body ?? ''));
        if (mounted) context.showMessage(l10n.copied);
      case 'edit':
        setState(() {
          _editing = m;
          _replyTo = null;
          _input.text = m.body ?? '';
        });
      case 'pin':
        await _guard(() => _ctrl.setPinned(m, pinned: m.pinnedAt == null));
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: l10n.deleteMessageTitle,
          message: l10n.deleteMessageBody,
          destructive: true,
          confirmLabel: l10n.actionDelete,
        );
        if (ok) await _guard(() => _ctrl.delete(m));
    }
  }

  Future<void> _mute(ConversationSummary? summary) async {
    final l10n = context.l10n;
    final until = await showModalBottomSheet<DateTime?>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(l10n.mute8h),
              onTap: () => Navigator.pop(ctx, DateTime.now().add(const Duration(hours: 8))),
            ),
            ListTile(
              title: Text(l10n.mute1w),
              onTap: () => Navigator.pop(ctx, DateTime.now().add(const Duration(days: 7))),
            ),
            ListTile(title: Text(l10n.muteAlways), onTap: () => Navigator.pop(ctx, DateTime(2100))),
            if (summary?.isMuted(DateTime.now()) ?? false)
              ListTile(title: Text(l10n.unmute), onTap: () => Navigator.pop(ctx, DateTime(1970))),
          ],
        ),
      ),
    );
    if (until == null) return;
    await _guard(
      () => ref.read(chatRepositoryProvider).setMuted(widget.conversationId, until.year == 1970 ? null : until),
    );
    final familyId = ref.read(activeFamilyIdProvider);
    if (familyId != null) ref.invalidate(conversationSummariesProvider(familyId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final familyId = ref.watch(activeFamilyIdProvider) ?? '';
    final me = ref.watch(currentUserIdProvider) ?? '';
    final familyRole = ref.watch(myRoleProvider);
    final async = ref.watch(conversationControllerProvider(widget.conversationId));
    final familyMembers = ref.watch(familyMembersProvider(familyId)).value ?? const <FamilyMember>[];
    final memberById = {for (final m in familyMembers) m.userId: m};
    final summary = ref
        .watch(conversationSummariesProvider(familyId))
        .value
        ?.where((c) => c.id == widget.conversationId)
        .firstOrNull;
    final online = ref.watch(onlineUsersProvider).value ?? const <String>{};

    ref.listen(conversationControllerProvider(widget.conversationId).select((s) => s.value?.messages.length), (_, _) {
      _scheduleMarkRead();
    });

    String nameOf(String? id) => id == me ? l10n.you : (memberById[id]?.displayName ?? l10n.someone);

    return async.when(
      loading: () => Scaffold(appBar: AppBar(), body: const LoadingView()),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: ErrorView(error: e, onRetry: () => ref.invalidate(conversationControllerProvider(widget.conversationId))),
      ),
      data: (state) {
        final isGroup = summary?.isGroup ?? state.members.length > 2;
        final myMember = state.members.where((m) => m.userId == me).firstOrNull;
        final canModerate =
            (myMember?.isAdmin ?? false) ||
            familyRole == FamilyRole.owner ||
            familyRole == FamilyRole.admin ||
            familyRole == FamilyRole.moderator;
        final title = summary != null ? conversationTitle(l10n, summary, memberById) : l10n.navChat;
        final typingNames = state.typing.keys.map(nameOf).toList();
        final otherId = summary?.otherUserId;
        final subtitle = typingNames.isNotEmpty
            ? (isGroup ? l10n.typingNamed(typingNames.join(', ')) : l10n.typing)
            : isGroup
            ? l10n.membersCount(state.members.length)
            : (online.contains(otherId) ? l10n.online : null);
        final receipts = state.receipts.values.toList();
        final msgs = state.messages.reversed.toList(); // newest first for reverse list
        final pinned = state.messages.where((m) => m.pinnedAt != null && !m.isDeleted).toList()
          ..sort((a, b) => b.pinnedAt!.compareTo(a.pinnedAt!));

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: InkWell(
              onTap: isGroup ? () => context.go('/chat/${widget.conversationId}/info') : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, overflow: TextOverflow.ellipsis),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: typingNames.isNotEmpty ? theme.colorScheme.secondary : null,
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              IconButton(
                tooltip: (summary?.isMuted(DateTime.now()) ?? false) ? l10n.unmute : l10n.mute,
                icon: Icon(
                  (summary?.isMuted(DateTime.now()) ?? false)
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_none,
                ),
                onPressed: () => _mute(summary),
              ),
              if (isGroup)
                IconButton(
                  tooltip: l10n.groupInfo,
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => context.go('/chat/${widget.conversationId}/info'),
                ),
            ],
          ),
          body: Column(
            children: [
              if (pinned.isNotEmpty)
                Material(
                  color: theme.colorScheme.secondaryContainer,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.push_pin, size: 18),
                    title: Text(
                      pinned.first.body ??
                          (pinned.first.attachments.isNotEmpty ? pinned.first.attachments.first.fileName : ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: pinned.length > 1 ? Text('+${pinned.length - 1}') : null,
                  ),
                ),
              Expanded(
                child: msgs.isEmpty
                    ? MessageView(icon: Icons.waving_hand_outlined, title: l10n.sayHello)
                    : ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                        itemCount: msgs.length + (state.hasMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i == msgs.length) {
                            return const Padding(
                              padding: EdgeInsets.all(AppSpacing.md),
                              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            );
                          }
                          final m = msgs[i];
                          final older = i + 1 < msgs.length ? msgs[i + 1] : null;
                          final newDay = older == null || !isSameDay(older.createdAt, m.createdAt);
                          final children = <Widget>[
                            if (newDay)
                              SystemMessageChip(text: DateFormat.yMMMMEEEEd(l10n.localeName).format(m.createdAt)),
                          ];
                          if (m.isSystem) {
                            children.add(
                              SystemMessageChip(text: systemMessageText(l10n, m, nameOf(m.senderId), nameOf)),
                            );
                          } else {
                            final isMine = m.senderId == me;
                            final reply = state.byId(m.replyToId);
                            children.add(
                              MessageBubble(
                                key: ValueKey('msg-${m.id}'),
                                message: m,
                                isMine: isMine,
                                showSender: isGroup && (older == null || newDay || !groupsWith(older, m)),
                                senderName: nameOf(m.senderId),
                                receipt: receiptStateFor(m, me, receipts),
                                readBy: isGroup ? readByCount(m, me, receipts) : null,
                                reply: reply,
                                replySenderName: reply == null ? null : nameOf(reply.senderId),
                                onLongPress: () =>
                                    _actions(m, isMine: isMine, canModerate: canModerate, isGroup: isGroup),
                                onRetry: () => _guard(() => _ctrl.retry(m.id)),
                              ),
                            );
                          }
                          return Column(mainAxisSize: MainAxisSize.min, children: children);
                        },
                      ),
              ),
              _Composer(
                controller: _input,
                replyTo: _replyTo,
                editing: _editing,
                replyName: _replyTo == null ? null : nameOf(_replyTo!.senderId),
                onCancel: () => setState(() {
                  if (_editing != null) _input.clear();
                  _replyTo = null;
                  _editing = null;
                }),
                onAttach: _attach,
                onSend: _submit,
                onTyping: () => _ctrl.sendTyping(true),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onCancel,
    required this.onAttach,
    required this.onSend,
    required this.onTyping,
    this.replyTo,
    this.editing,
    this.replyName,
  });

  final TextEditingController controller;
  final ChatMessage? replyTo;
  final ChatMessage? editing;
  final String? replyName;
  final VoidCallback onCancel;
  final VoidCallback onAttach;
  final VoidCallback onSend;
  final VoidCallback onTyping;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final banner = editing != null
        ? (Icons.edit_outlined, l10n.editingMessage, editing!.body ?? '')
        : replyTo != null
        ? (
            Icons.reply,
            l10n.replyingTo(replyName ?? ''),
            replyTo!.body ?? replyTo!.attachments.firstOrNull?.fileName ?? '',
          )
        : null;
    return Material(
      elevation: 4,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (banner != null)
              ListTile(
                dense: true,
                leading: Icon(banner.$1, size: 20),
                title: Text(banner.$2, style: theme.textTheme.labelMedium),
                subtitle: Text(banner.$3, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(tooltip: l10n.actionCancel, icon: const Icon(Icons.close), onPressed: onCancel),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (editing == null)
                    IconButton(tooltip: l10n.attach, icon: const Icon(Icons.attach_file), onPressed: onAttach),
                  Expanded(
                    child: TextField(
                      key: const Key('chat.input'),
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 4000,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(hintText: l10n.typeMessage, counterText: ''),
                      onChanged: (_) => onTyping(),
                    ),
                  ),
                  IconButton.filled(
                    key: const Key('chat.send'),
                    tooltip: l10n.send,
                    icon: Icon(editing != null ? Icons.check : Icons.send),
                    onPressed: onSend,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
