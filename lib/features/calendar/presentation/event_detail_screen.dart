import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/calendar_repository.dart';
import '../domain/calendar_models.dart';
import 'calendar_providers.dart';
import 'calendar_ui.dart';

/// True when the user may edit/delete: creator, or family owner/admin.
bool canManageEvent(FamilyEvent e, {required String? userId, required FamilyRole? role}) =>
    e.createdBy == userId || role == FamilyRole.owner || role == FamilyRole.admin;

class EventDetailScreen extends ConsumerWidget {
  const EventDetailScreen({required this.eventId, this.occurrenceStart, super.key});

  final String eventId;

  /// The tapped occurrence of a recurring event (null = the first one).
  final DateTime? occurrenceStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final l10n = context.l10n;
    final key = (familyId: familyId, eventId: eventId);
    final ev = ref.watch(eventProvider(key));
    final me = ref.watch(currentUserIdProvider);
    final role = ref.watch(myRoleProvider);

    final event = ev.value;
    final canManage = event != null && event.deletedAt == null && canManageEvent(event, userId: me, role: role);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.eventDetails),
        actions: [
          if (canManage) ...[
            IconButton(
              tooltip: l10n.editEvent,
              onPressed: () => context.push(Routes.eventEdit(eventId)),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: l10n.actionDelete,
              onPressed: () => _delete(context, ref, event),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
      body: AsyncValueView(
        value: ev,
        onRetry: () => ref.invalidate(eventProvider(key)),
        data: (e) => e == null || e.deletedAt != null
            ? MessageView(icon: Icons.event_busy_outlined, title: l10n.eventNotFound)
            : _Body(event: e, occurrenceStart: occurrenceStart),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, FamilyEvent e) async {
    final l10n = context.l10n;
    final repo = ref.read(calendarRepositoryProvider);
    final router = GoRouter.of(context);
    if (e.isRecurring && occurrenceStart != null) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(l10n.eventDeleteTitle),
          children: [
            SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop('one'), child: Text(l10n.eventCancelOccurrence)),
            SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop('all'), child: Text(l10n.eventDeleteSeries)),
            SimpleDialogOption(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.actionCancel)),
          ],
        ),
      );
      if (choice == null || !context.mounted) return;
      try {
        if (choice == 'one') {
          await repo.cancelOccurrence(e.id, occurrenceStart!);
        } else {
          await repo.delete(e.id);
        }
        if (context.mounted) context.showMessage(l10n.eventDeleted);
        router.pop();
      } catch (err) {
        if (context.mounted) context.showError(err);
      }
      return;
    }
    final ok = await confirmDialog(
      context,
      title: l10n.eventDeleteTitle,
      message: l10n.eventDeleteMessage(e.title),
      confirmLabel: l10n.actionDelete,
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await repo.delete(e.id);
      if (context.mounted) context.showMessage(l10n.eventDeleted);
      router.pop();
    } catch (err) {
      if (context.mounted) context.showError(err);
    }
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.event, this.occurrenceStart});

  final FamilyEvent event;
  final DateTime? occurrenceStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final loc = l10n.localeName;
    final scheme = Theme.of(context).colorScheme;
    final me = ref.watch(currentUserIdProvider);
    final members = ref.watch(familyMembersProvider(event.familyId)).value ?? const <FamilyMember>[];
    final start = occurrenceStart ?? event.startsAt;
    final occ = EventOccurrence(event: event, start: start, end: start.add(event.endsAt.difference(event.startsAt)));
    final mine = event.participant(me);
    String? creator;
    for (final m in members) {
      if (m.userId == event.createdBy) creator = m.displayName;
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            CircleAvatar(
              backgroundColor: event.category.color.withValues(alpha: 0.15),
              foregroundColor: event.category.color,
              child: Icon(event.category.icon),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(eventCategoryLabel(l10n, event.category), style: TextStyle(color: scheme.outline)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.schedule),
          title: Text(DateFormat.yMMMMEEEEd(loc).format(occ.start)),
          subtitle: Text(occurrenceTimeLabel(l10n, occ)),
        ),
        if (event.isRecurring)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.repeat),
            title: Text(eventRecurrenceLabel(l10n, event.recurrence)),
            subtitle: event.recurrenceUntil == null
                ? null
                : Text(l10n.eventRepeatsUntil(DateFormat.yMMMd(loc).format(event.recurrenceUntil!))),
          ),
        if (event.location != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined),
            title: Text(event.location!),
            trailing: IconButton(
              tooltip: l10n.eventOpenMap,
              icon: const Icon(Icons.map_outlined),
              onPressed: () => launchUrl(
                Uri.parse('geo:0,0?q=${Uri.encodeComponent(event.location!)}'),
                mode: LaunchMode.externalApplication,
              ).catchError((_) => false),
            ),
          ),
        if (event.description != null)
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.notes), title: Text(event.description!)),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(event.participantsOnly ? Icons.lock_outline : Icons.groups_outlined),
          title: Text(event.participantsOnly ? l10n.eventVisibleParticipants : l10n.eventVisibleFamily),
          subtitle: creator == null ? null : Text(l10n.eventCreatedBy(creator)),
        ),
        const Divider(),
        Text(l10n.rsvpQuestion, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        SegmentedButton<Rsvp>(
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          segments: [
            for (final r in [Rsvp.going, Rsvp.maybe, Rsvp.declined])
              ButtonSegment(value: r, label: Text(rsvpLabel(l10n, r)), icon: Icon(rsvpIcon(r))),
          ],
          selected: {if (mine != null && mine.rsvp != Rsvp.pending) mine.rsvp},
          onSelectionChanged: (s) async {
            if (s.isEmpty) return;
            try {
              await ref.read(calendarRepositoryProvider).setRsvp(event.id, s.first);
              ref.invalidate(eventProvider((familyId: event.familyId, eventId: event.id)));
              ref.invalidate(myRemindersProvider(event.id));
            } catch (e) {
              if (context.mounted) context.showError(e);
            }
          },
        ),
        const SizedBox(height: AppSpacing.md),
        _Reminders(event: event, isParticipant: mine != null),
        const Divider(),
        Text(
          '${l10n.eventParticipants} · ${l10n.rsvpSummary(event.countRsvp(Rsvp.going), event.countRsvp(Rsvp.maybe), event.countRsvp(Rsvp.declined))}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        for (final p in event.participants)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: StorageAvatar(
              radius: 18,
              path: p.avatarPath,
              initials: participantName(p, members).characters.first.toUpperCase(),
            ),
            title: Text(participantName(p, members)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(rsvpLabel(l10n, p.rsvp), style: TextStyle(color: scheme.outline)),
                const SizedBox(width: 4),
                Icon(rsvpIcon(p.rsvp), size: 18, color: p.rsvp == Rsvp.going ? Colors.green.shade600 : scheme.outline),
              ],
            ),
          ),
      ],
    );
  }
}

class _Reminders extends ConsumerWidget {
  const _Reminders({required this.event, required this.isParticipant});

  final FamilyEvent event;
  final bool isParticipant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (!isParticipant) {
      return Text(l10n.remindersNeedRsvp, style: TextStyle(color: Theme.of(context).colorScheme.outline));
    }
    final rem = ref.watch(myRemindersProvider(event.id));
    final current = rem.value ?? const <int>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.eventReminders, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            for (final m in {...reminderChoices, ...current}.toList()..sort())
              FilterChip(
                label: Text(reminderLabel(l10n, m)),
                selected: current.contains(m),
                onSelected: rem.isLoading
                    ? null
                    : (v) async {
                        final next = {...current};
                        v ? next.add(m) : next.remove(m);
                        if (next.length > 5) {
                          context.showMessage(l10n.remindersMax, error: true);
                          return;
                        }
                        try {
                          await ref.read(calendarRepositoryProvider).setReminders(event.id, next.toList());
                          ref.invalidate(myRemindersProvider(event.id));
                        } catch (e) {
                          if (context.mounted) context.showError(e);
                        }
                      },
              ),
          ],
        ),
      ],
    );
  }
}
