import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../domain/chat_models.dart';
import 'chat_providers.dart';
import 'new_chat_sheet.dart';

/// Chat tab: conversations of the active family, with message search.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final convs = ref.watch(conversationSummariesProvider(familyId));
    final members = ref.watch(familyMembersProvider(familyId)).value ?? const <FamilyMember>[];
    final memberById = {for (final m in members) m.userId: m};
    final online = ref.watch(onlineUsersProvider).value ?? const <String>{};
    final me = ref.watch(currentUserIdProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navChat)),
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.newChat,
        onPressed: () async {
          final id = await showNewChatSheet(context, familyId: familyId);
          if (id != null && context.mounted) context.go('/chat/$id');
        },
        child: const Icon(Icons.edit_square),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: l10n.searchMessages,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                      ),
              ),
              onChanged: (q) => setState(() => _query = q),
            ),
          ),
          Expanded(
            child: _query.trim().length >= 2
                ? _SearchResults(familyId: familyId, query: _query, memberById: memberById)
                : AsyncValueView(
                    value: convs,
                    onRetry: () => ref.invalidate(conversationSummariesProvider(familyId)),
                    data: (list) => list.isEmpty
                        ? MessageView(icon: Icons.forum_outlined, title: l10n.noChatsTitle, message: l10n.noChatsBody)
                        : RefreshIndicator(
                            onRefresh: () async => ref.refresh(conversationSummariesProvider(familyId).future),
                            child: ListView.builder(
                              padding: const EdgeInsets.only(bottom: 88),
                              itemCount: list.length,
                              itemBuilder: (_, i) =>
                                  ConversationTile(summary: list[i], memberById: memberById, online: online, me: me),
                            ),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

String conversationTitle(AppLocalizations l10n, ConversationSummary c, Map<String, FamilyMember> memberById) {
  if (c.isGroup) return c.name ?? l10n.navChat;
  return memberById[c.otherUserId]?.displayName ?? l10n.someone;
}

String chatTime(BuildContext context, DateTime t) {
  final now = DateTime.now();
  final l = context.l10n.localeName;
  if (t.year == now.year && t.month == now.month && t.day == now.day) return DateFormat.Hm(l).format(t);
  if (now.difference(t).inDays < 7) return DateFormat.E(l).format(t);
  return DateFormat.yMd(l).format(t);
}

class ConversationTile extends StatelessWidget {
  const ConversationTile({
    required this.summary,
    required this.memberById,
    required this.online,
    required this.me,
    super.key,
  });

  final ConversationSummary summary;
  final Map<String, FamilyMember> memberById;
  final Set<String> online;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final c = summary;
    final other = memberById[c.otherUserId];
    final muted = c.isMuted(DateTime.now());
    final preview = c.lastMessagePreview == null
        ? (c.lastMessageAt == null ? l10n.noMessagesYet : l10n.messageDeleted)
        : (c.lastMessageSenderId == me ? '${l10n.youPrefix}: ${c.lastMessagePreview}' : c.lastMessagePreview!);
    final unread = c.unreadCount > 0;

    return ListTile(
      key: ValueKey('conv-${c.id}'),
      onTap: () => context.go('/chat/${c.id}'),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          c.isGroup
              ? CircleAvatar(
                  radius: 24,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  child: Icon(Icons.groups_rounded, color: theme.colorScheme.onSecondaryContainer),
                )
              : StorageAvatar(radius: 24, initials: other?.profile?.initials ?? '?', path: other?.profile?.avatarPath),
          if (!c.isGroup && online.contains(c.otherUserId))
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: AppColors.softGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conversationTitle(l10n, c, memberById),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: unread ? const TextStyle(fontWeight: FontWeight.w700) : null,
            ),
          ),
          if (c.pinnedAt != null) Icon(Icons.push_pin, size: 14, color: theme.colorScheme.outline),
          if (muted) Icon(Icons.notifications_off_outlined, size: 14, color: theme.colorScheme.outline),
        ],
      ),
      subtitle: Text(
        preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: unread ? TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600) : null,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(chatTime(context, c.sortTime), style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          if (unread)
            Badge(
              label: Text(c.unreadCount > 99 ? '99+' : '${c.unreadCount}'),
              backgroundColor: muted ? theme.colorScheme.outline : theme.colorScheme.secondary,
            ),
        ],
      ),
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.familyId, required this.query, required this.memberById});

  final String familyId;
  final String query;
  final Map<String, FamilyMember> memberById;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final hits = ref.watch(messageSearchProvider((familyId: familyId, q: query)));
    return AsyncValueView(
      value: hits,
      data: (list) => list.isEmpty
          ? MessageView(icon: Icons.search_off, title: l10n.noSearchResults)
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final h = list[i];
                return ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(h.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${memberById[h.senderId]?.displayName ?? l10n.someone} · ${chatTime(context, h.createdAt)}',
                  ),
                  onTap: () => context.go('/chat/${h.conversationId}'),
                );
              },
            ),
    );
  }
}
