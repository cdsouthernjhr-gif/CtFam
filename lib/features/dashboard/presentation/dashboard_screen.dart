import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../shared/providers/session_controller.dart';
import '../../calendar/presentation/calendar_providers.dart';
import '../../calendar/presentation/calendar_screen.dart';
import '../../calendar/presentation/calendar_ui.dart';
import '../../chat/presentation/chat_providers.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../family/domain/family_models.dart';
import '../../notifications/presentation/notifications_screen.dart';
import '../../family/domain/family_permissions.dart';
import '../../family/presentation/activity_screen.dart';
import '../../family/presentation/family_providers.dart';
import '../../todo/domain/todo_models.dart';
import '../../todo/presentation/todo_providers.dart';
import '../../todo/presentation/todo_ui.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final l10n = context.l10n;
    final family = ref.watch(familyProvider(familyId));
    final members = ref.watch(familyMembersProvider(familyId));
    final activity = ref.watch(familyActivityProvider(familyId));
    final me = ref.watch(myProfileProvider);
    final role = ref.watch(myRoleProvider);

    Future<void> refresh() async {
      ref.invalidate(familyProvider(familyId));
      ref.invalidate(familyMembersProvider(familyId));
      ref.invalidate(familyActivityProvider(familyId));
      ref.invalidate(myProfileProvider);
      ref.invalidate(todoOverviewProvider(familyId));
      ref.invalidate(occurrencesProvider(upcomingRange(familyId, days: 7)));
      await ref.read(familyMembersProvider(familyId).future);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(family.value?.name ?? l10n.appName, overflow: TextOverflow.ellipsis),
        actions: [
          const NotificationBell(),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: IconButton(
              tooltip: l10n.profileTitle,
              onPressed: () => context.push(Routes.profile),
              icon: StorageAvatar(radius: 16, initials: me.value?.initials ?? '', path: me.value?.avatarPath),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text(
              l10n.greeting(me.value?.displayName ?? ''),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.md),
            if (family.hasValue) _FamilyHeader(family: family.requireValue, memberCount: members.value?.length),
            const SizedBox(height: AppSpacing.md),
            _SectionHeader(
              title: l10n.dashboardMembers,
              action: TextButton(onPressed: () => context.go(Routes.family), child: Text(l10n.dashboardSeeAll)),
            ),
            SizedBox(
              height: 92,
              child: AsyncValueView(
                value: members,
                onRetry: () => ref.invalidate(familyMembersProvider(familyId)),
                data: (list) => ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: list.where((m) => m.status == MemberStatus.active).length,
                  separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
                  itemBuilder: (_, i) {
                    final m = list.where((m) => m.status == MemberStatus.active).elementAt(i);
                    return SizedBox(
                      width: 64,
                      child: Column(
                        children: [
                          StorageAvatar(initials: m.profile?.initials ?? '?', path: m.profile?.avatarPath, radius: 26),
                          const SizedBox(height: 6),
                          Text(
                            m.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            if (family.hasValue && role != null && FamilyPermissions.canInvite(role, family.requireValue)) ...[
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => context.push(Routes.invite),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: Text(l10n.dashboardQuickInvite),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            _SectionHeader(
              title: l10n.dashboardTodayTasks,
              action: TextButton(onPressed: () => context.go(Routes.todo), child: Text(l10n.viewAllTasks)),
            ),
            _TodayTasks(familyId: familyId),
            const SizedBox(height: AppSpacing.lg),
            _SectionHeader(
              title: l10n.dashboardUpcomingEvents,
              action: TextButton(onPressed: () => context.go(Routes.calendar), child: Text(l10n.dashboardSeeAll)),
            ),
            _UpcomingEvents(familyId: familyId),
            const SizedBox(height: AppSpacing.lg),
            _SectionHeader(
              title: l10n.dashboardRecentMessages,
              action: TextButton(onPressed: () => context.go(Routes.chat), child: Text(l10n.dashboardSeeAll)),
            ),
            _RecentChats(familyId: familyId),
            const SizedBox(height: AppSpacing.lg),
            _SectionHeader(
              title: l10n.dashboardRecentActivity,
              action: TextButton(onPressed: () => context.push(Routes.activity), child: Text(l10n.dashboardSeeAll)),
            ),
            AsyncValueView(
              value: activity,
              onRetry: () => ref.invalidate(familyActivityProvider(familyId)),
              data: (entries) => entries.isEmpty
                  ? Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Text(l10n.dashboardNoActivity))
                  : Card(
                      child: Column(children: [for (final e in entries.take(5)) ActivityTile(entry: e)]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FamilyHeader extends StatelessWidget {
  const _FamilyHeader({required this.family, this.memberCount});

  final Family family;
  final int? memberCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primary,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            StorageAvatar(
              bucket: 'family-media',
              path: family.imagePath,
              initials: family.name.substring(0, 1).toUpperCase(),
              icon: family.imagePath == null ? Icons.family_restroom_rounded : null,
              radius: 28,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    family.name,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w700),
                  ),
                  if (memberCount != null)
                    Text(
                      context.l10n.memberCountLabel(memberCount!),
                      style: TextStyle(color: scheme.onPrimary.withValues(alpha: 0.85)),
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      ?action,
    ],
  );
}

/// Today's / overdue / my open tasks, live via the family To-Do channel.
class _TodayTasks extends ConsumerWidget {
  const _TodayTasks({required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final overview = ref.watch(todoOverviewProvider(familyId));
    return overview.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ListTile(
        leading: const Icon(Icons.error_outline),
        title: Text(context.errorText(e)),
        trailing: IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.invalidate(todoOverviewProvider(familyId)),
        ),
      ),
      data: (o) {
        final shown = <TodoItem>[...o.overdue, ...o.today].take(5).toList();
        final now = DateTime.now();
        return Card(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
                child: Row(
                  children: [
                    _Stat(value: o.today.length, label: l10n.statToday, color: theme.colorScheme.primary),
                    _Stat(value: o.overdue.length, label: l10n.statOverdue, color: theme.colorScheme.error),
                    _Stat(value: o.mine.length, label: l10n.statMine, color: theme.colorScheme.secondary),
                    _Stat(value: o.openCount, label: l10n.statOpen, color: theme.colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
              if (shown.isEmpty)
                Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Text(l10n.dashboardNoTasksToday))
              else
                for (final item in shown)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      item.isOverdue(now) ? Icons.warning_amber_rounded : Icons.radio_button_unchecked,
                      color: item.isOverdue(now) ? theme.colorScheme.error : null,
                    ),
                    title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: item.dueAt == null ? null : Text(dueLabel(l10n, item.dueAt!, now)),
                    onTap: () => context.go('/todo/${item.listId}'),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});

  final int value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(
          '$value',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
        Text(label, style: Theme.of(context).textTheme.labelSmall, textAlign: TextAlign.center),
      ],
    ),
  );
}

/// The three most recent conversations (live via the chat family channel).
class _RecentChats extends ConsumerWidget {
  const _RecentChats({required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final convs = ref.watch(conversationSummariesProvider(familyId));
    final members = ref.watch(familyMembersProvider(familyId)).value ?? const <FamilyMember>[];
    final online = ref.watch(onlineUsersProvider).value ?? const <String>{};
    final me = ref.watch(currentUserIdProvider);
    return convs.when(
      loading: () => const SizedBox(height: 56, child: Center(child: CircularProgressIndicator())),
      error: (e, _) => ListTile(leading: const Icon(Icons.error_outline), title: Text(context.errorText(e))),
      data: (list) {
        final recent = list.where((c) => c.lastMessageAt != null).take(3).toList();
        if (recent.isEmpty) {
          return Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Text(l10n.noMessagesYet));
        }
        return Card(
          child: Column(
            children: [
              for (final c in recent)
                ConversationTile(
                  summary: c,
                  memberById: {for (final m in members) m.userId: m},
                  online: online,
                  me: me,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _UpcomingEvents extends ConsumerWidget {
  const _UpcomingEvents({required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final range = upcomingRange(familyId, days: 7);
    final occ = ref.watch(occurrencesProvider(range));
    final me = ref.watch(currentUserIdProvider);
    return AsyncValueView(
      value: occ,
      onRetry: () => ref.invalidate(occurrencesProvider(range)),
      data: (all) {
        final upcoming = all.where((o) => o.end.isAfter(DateTime.now()) || o.event.allDay).take(4).toList();
        if (upcoming.isEmpty) {
          return Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Text(l10n.calendarNoUpcomingWeek));
        }
        return Card(
          child: Column(
            children: [
              for (final o in upcoming)
                EventOccurrenceTile(
                  occurrence: o,
                  myUserId: me,
                  showDate: true,
                  onTap: () => openOccurrence(context, o),
                ),
            ],
          ),
        );
      },
    );
  }
}
