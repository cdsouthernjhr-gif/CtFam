import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../data/notification_repository.dart';
import '../domain/notification_models.dart';
import 'notification_providers.dart';

IconData notificationIcon(String type) => switch (type) {
  'private_message' || 'group_message' => Icons.chat_bubble_outline,
  'task_created' || 'task_assigned' || 'task_completed' => Icons.task_alt,
  'family_request' || 'member_joined' => Icons.group_add_outlined,
  'family_event' => Icons.event_outlined,
  'announcement' => Icons.campaign_outlined,
  'collection' => Icons.volunteer_activism_outlined,
  _ => Icons.notifications_none,
};

/// In-app notification inbox (works even without push / Firebase).
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final repo = ref.read(notificationRepositoryProvider);
    final inbox = ref.watch(inboxProvider);

    Future<void> open(AppNotification n) async {
      if (!n.isRead) await repo.markRead([n.id]).catchError((Object _) {});
      final route = n.route;
      if (route != null && context.mounted) context.go(route);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.notificationsTitle),
        actions: [
          IconButton(
            tooltip: l10n.markAllRead,
            icon: const Icon(Icons.done_all),
            onPressed: () async {
              try {
                await repo.markRead();
                ref.invalidate(inboxProvider);
                ref.invalidate(unreadNotificationsProvider);
              } catch (e) {
                if (context.mounted) context.showError(e);
              }
            },
          ),
          IconButton(
            tooltip: l10n.notificationSettings,
            icon: const Icon(Icons.tune),
            onPressed: () => context.push('/profile/notifications'),
          ),
        ],
      ),
      body: AsyncValueView(
        value: inbox,
        onRetry: () => ref.invalidate(inboxProvider),
        data: (list) => list.isEmpty
            ? MessageView(icon: Icons.notifications_none, title: l10n.noNotifications)
            : RefreshIndicator(
                onRefresh: () async => ref.refresh(inboxProvider.future),
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final n = list[i];
                    return ListTile(
                      key: ValueKey('notif-${n.id}'),
                      leading: Icon(
                        notificationIcon(n.type),
                        color: n.isRead ? null : Theme.of(context).colorScheme.secondary,
                      ),
                      title: Text(n.title, style: n.isRead ? null : const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${n.body}\n${context.formatDateTime(n.createdAt)}'),
                      isThreeLine: true,
                      onTap: () => open(n),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

/// Bell with unread badge for app bars.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(unreadNotificationsProvider).value ?? 0;
    return IconButton(
      tooltip: context.l10n.notificationsTitle,
      onPressed: () => context.push('/notifications'),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 99 ? '99+' : '$count'),
        child: const Icon(Icons.notifications_none),
      ),
    );
  }
}
