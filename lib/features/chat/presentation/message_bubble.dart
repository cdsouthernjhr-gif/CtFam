import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../family/presentation/family_providers.dart';
import '../domain/chat_logic.dart';
import '../domain/chat_models.dart';

String systemMessageText(AppLocalizations l, ChatMessage m, String actor, String Function(String?) nameOf) {
  final meta = m.meta ?? const {};
  return switch (m.body) {
    'group_created' => l.sysGroupCreated(actor, (meta['name'] as String?) ?? ''),
    'group_renamed' => l.sysGroupRenamed(actor, (meta['name'] as String?) ?? ''),
    'members_added' => l.sysMembersAdded(
      actor,
      ((meta['user_ids'] as List?) ?? const []).map((u) => nameOf(u as String?)).join(', '),
    ),
    'member_removed' => l.sysMemberRemoved(actor, nameOf(meta['user_id'] as String?)),
    'member_left' => l.sysMemberLeft(actor),
    _ => m.body ?? '',
  };
}

class SystemMessageChip extends StatelessWidget {
  const SystemMessageChip({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.lg),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall),
    ),
  );
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    required this.isMine,
    required this.showSender,
    required this.senderName,
    required this.receipt,
    required this.onLongPress,
    this.reply,
    this.replySenderName,
    this.readBy,
    this.onRetry,
    super.key,
  });

  final ChatMessage message;
  final bool isMine;
  final bool showSender;
  final String senderName;
  final ReceiptState receipt;
  final ChatMessage? reply;
  final String? replySenderName;

  /// Group chats: number of members who read this message.
  final int? readBy;
  final VoidCallback onLongPress;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = message;
    final bg = isMine ? scheme.primary : scheme.surfaceContainerHighest;
    final fg = isMine ? scheme.onPrimary : scheme.onSurface;
    final failed = m.sendState == SendState.failed;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: m.isDeleted || m.sendState != SendState.sent ? null : onLongPress,
        onTap: failed ? onRetry : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          child: Container(
            margin: EdgeInsets.only(left: AppSpacing.sm, right: AppSpacing.sm, top: showSender ? 8 : 2, bottom: 2),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            decoration: BoxDecoration(
              color: failed ? scheme.errorContainer : bg,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMine ? 16 : 4),
                bottomRight: Radius.circular(isMine ? 4 : 16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showSender && !isMine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      senderName,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (m.pinnedAt != null && !m.isDeleted)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.push_pin, size: 12, color: fg.withValues(alpha: 0.7)),
                      const SizedBox(width: 2),
                      Text(l10n.pinned, style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7))),
                    ],
                  ),
                if (reply != null && !m.isDeleted) _ReplyQuote(reply: reply!, senderName: replySenderName, color: fg),
                if (m.isDeleted)
                  Text(
                    l10n.messageDeleted,
                    style: TextStyle(fontStyle: FontStyle.italic, color: fg.withValues(alpha: 0.75)),
                  )
                else ...[
                  for (final a in m.attachments) _AttachmentView(attachment: a, color: fg),
                  if ((m.body ?? '').isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: m.attachments.isEmpty ? 0 : 6),
                      child: SelectableText(m.body!, style: TextStyle(color: fg, fontSize: 15)),
                    ),
                ],
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m.editedAt != null && !m.isDeleted)
                      Text(
                        '${l10n.edited} · ',
                        style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7)),
                      ),
                    Text(
                      DateFormat.Hm(l10n.localeName).format(m.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7)),
                    ),
                    if (isMine) ...[const SizedBox(width: 4), _StatusIcon(message: m, receipt: receipt, color: fg)],
                    if (isMine && readBy != null && readBy! > 0 && m.sendState == SendState.sent) ...[
                      const SizedBox(width: 2),
                      Text('$readBy', style: theme.textTheme.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7))),
                    ],
                  ],
                ),
                if (failed)
                  Text(l10n.tapToRetry, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onErrorContainer)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.message, required this.receipt, required this.color});

  final ChatMessage message;
  final ReceiptState receipt;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, tint, label) = switch (message.sendState) {
      SendState.sending => (Icons.schedule, color.withValues(alpha: 0.7), l10n.statusSending),
      SendState.failed => (Icons.error_outline, Theme.of(context).colorScheme.error, l10n.statusFailed),
      SendState.sent => switch (receipt) {
        ReceiptState.sent => (Icons.check, color.withValues(alpha: 0.7), l10n.statusSent),
        ReceiptState.delivered => (Icons.done_all, color.withValues(alpha: 0.7), l10n.statusDelivered),
        ReceiptState.read => (Icons.done_all, AppColors.softGreen, l10n.statusRead),
      },
    };
    return Semantics(
      label: label,
      child: Icon(icon, size: 14, color: tint),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.reply, required this.color, this.senderName});

  final ChatMessage reply;
  final String? senderName;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = reply.isDeleted
        ? l10n.messageDeleted
        : (reply.body?.isNotEmpty ?? false)
        ? reply.body!
        : (reply.attachments.isNotEmpty ? reply.attachments.first.fileName : '');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border(left: BorderSide(color: color.withValues(alpha: 0.6), width: 3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (senderName != null)
            Text(
              senderName!,
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _AttachmentView extends ConsumerWidget {
  const _AttachmentView({required this.attachment, required this.color});

  final ChatAttachment attachment;
  final Color color;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    try {
      final url = await ref.read(signedUrlProvider((bucket: 'chat-attachments', path: attachment.storagePath)).future);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = attachment;
    final uploading = a.storagePath.isEmpty;
    if (a.isImage && !uploading) {
      final url = ref.watch(signedUrlProvider((bucket: 'chat-attachments', path: a.storagePath)));
      final aspect = (a.width != null && a.height != null && a.height! > 0) ? a.width! / a.height! : 4 / 3;
      return GestureDetector(
        onTap: () => _open(context, ref),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(
            aspectRatio: aspect.clamp(0.5, 2.0),
            child: url.maybeWhen(
              data: (u) => Image.network(
                u,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: color),
              ),
              orElse: () => Center(child: CircularProgressIndicator(color: color, strokeWidth: 2)),
            ),
          ),
        ),
      );
    }
    return InkWell(
      onTap: uploading ? null : () => _open(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            uploading
                ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                : Icon(a.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                  Text(formatBytes(a.sizeBytes), style: TextStyle(color: color.withValues(alpha: 0.7), fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
