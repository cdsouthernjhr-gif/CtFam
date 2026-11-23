import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/providers/session_controller.dart';
import '../../notifications/presentation/notifications_screen.dart';
import '../domain/calendar_models.dart';
import 'calendar_providers.dart';
import 'calendar_ui.dart';

/// Family calendar: month grid with the selected day's events, or an agenda
/// of the next 60 days. Live via Realtime (`calendar:{family}`).
class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final l10n = context.l10n;
    final view = ref.watch(calendarViewProvider);
    final ctrl = ref.read(calendarViewProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navCalendar),
        actions: [
          IconButton(tooltip: l10n.dueToday, onPressed: ctrl.today, icon: const Icon(Icons.today_outlined)),
          if (ref.watch(sessionControllerProvider.select((s) => s.activeMemberships.length)) > 1)
            IconButton(
              key: const Key('calendar.all'),
              tooltip: view.allFamilies ? l10n.calendarThisFamily : l10n.calendarAllFamilies,
              isSelected: view.allFamilies,
              onPressed: () => ctrl.setAllFamilies(!view.allFamilies),
              icon: const Icon(Icons.layers_outlined),
              selectedIcon: const Icon(Icons.layers),
            ),
          IconButton(
            tooltip: view.agenda ? l10n.calendarMonthView : l10n.calendarAgendaView,
            onPressed: () => ctrl.setAgenda(!view.agenda),
            icon: Icon(view.agenda ? Icons.calendar_month_outlined : Icons.view_agenda_outlined),
          ),
          const NotificationBell(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-event',
        onPressed: () => context.push(Routes.newEventOn(view.selected)),
        icon: const Icon(Icons.add),
        label: Text(l10n.newEvent),
      ),
      body: view.agenda
          ? _Agenda(familyId: familyId, all: view.allFamilies)
          : _MonthView(familyId: familyId, view: view),
    );
  }
}

/// Occurrences for a range: the active family (with clan events), or every
/// family of the user.
AsyncValue<List<EventOccurrence>> watchOccurrences(WidgetRef ref, CalendarRange r, {required bool all}) =>
    all ? ref.watch(allFamiliesOccurrencesProvider((from: r.from, to: r.to))) : ref.watch(occurrencesProvider(r));

/// Family name for events that are not from the active family.
String? familyLabelFor(WidgetRef ref, BuildContext context, EventOccurrence o, String activeFamilyId) {
  if (o.event.familyId == activeFamilyId) return null;
  for (final m in ref.read(sessionControllerProvider).activeMemberships) {
    if (m.familyId == o.event.familyId) return m.family?.name;
  }
  return context.l10n.linkClan;
}

void openOccurrence(BuildContext context, EventOccurrence o) =>
    context.push(Routes.eventDetail(o.event.id, occurrence: o.event.isRecurring ? o.start : null));

class _MonthView extends ConsumerWidget {
  const _MonthView({required this.familyId, required this.view});

  final String familyId;
  final CalendarViewState view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final range = monthRange(familyId, view.month);
    final occ = watchOccurrences(ref, range, all: view.allFamilies);
    final ctrl = ref.read(calendarViewProvider.notifier);
    final me = ref.watch(currentUserIdProvider);
    final all = occ.value ?? const <EventOccurrence>[];
    final dayList = occurrencesOn(all, view.selected);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(occurrencesProvider(range));
        await ref.read(occurrencesProvider(range).future).catchError((_) => const <EventOccurrence>[]);
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _MonthHeader(
              month: view.month,
              loading: occ.isLoading,
              onPrev: () => ctrl.shiftMonth(-1),
              onNext: () => ctrl.shiftMonth(1),
            ),
          ),
          SliverToBoxAdapter(
            child: _MonthGrid(month: view.month, selected: view.selected, occurrences: all, onSelect: ctrl.select),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
              child: Text(
                DateFormat.yMMMMEEEEd(l10n.localeName).format(view.selected),
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (occ.hasError && !occ.hasValue)
            SliverToBoxAdapter(
              child: ErrorView(error: occ.error!, onRetry: () => ref.invalidate(occurrencesProvider(range))),
            )
          else if (dayList.isEmpty && occ.hasValue)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(l10n.calendarNoEventsDay, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
              ),
            )
          else
            SliverList.list(
              children: [
                for (final o in dayList)
                  EventOccurrenceTile(
                    occurrence: o,
                    myUserId: me,
                    familyLabel: familyLabelFor(ref, context, o, familyId),
                    onTap: () => openOccurrence(context, o),
                  ),
              ],
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 88)),
        ],
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.month, required this.loading, required this.onPrev, required this.onNext});

  final DateTime month;
  final bool loading;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        children: [
          IconButton(tooltip: l10n.calendarPrevMonth, onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  DateFormat.yMMMM(l10n.localeName).format(month),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (loading) ...[
                  const SizedBox(width: AppSpacing.sm),
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ],
            ),
          ),
          IconButton(tooltip: l10n.calendarNextMonth, onPressed: onNext, icon: const Icon(Icons.chevron_right)),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({required this.month, required this.selected, required this.occurrences, required this.onSelect});

  final DateTime month;
  final DateTime selected;
  final List<EventOccurrence> occurrences;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loc = context.l10n.localeName;
    final days = monthGridDays(month);
    final today = dateOnly(DateTime.now());
    // Monday-first weekday initials
    final weekdays = [for (var i = 0; i < 7; i++) DateFormat.E(loc).format(days[i])];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Column(
        children: [
          Row(
            children: [
              for (final w in weekdays)
                Expanded(
                  child: Center(
                    child: Text(w, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.outline)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          for (var week = 0; week < 6; week++)
            Row(
              children: [
                for (final d in days.sublist(week * 7, week * 7 + 7))
                  Expanded(
                    child: _DayCell(
                      day: d,
                      inMonth: d.month == month.month,
                      isToday: sameDay(d, today),
                      isSelected: sameDay(d, selected),
                      dots: [for (final o in occurrencesOn(occurrences, d).take(3)) o.event.category.color],
                      more: occurrencesOn(occurrences, d).length > 3,
                      onTap: () => onSelect(d),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.dots,
    required this.more,
    required this.onTap,
  });

  final DateTime day;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final List<Color> dots;
  final bool more;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = isSelected
        ? scheme.onPrimary
        : inMonth
        ? scheme.onSurface
        : scheme.outline.withValues(alpha: 0.6);
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${DateFormat.yMMMMd(context.l10n.localeName).format(day)}, ${dots.length}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected ? scheme.primary : null,
                  border: isToday && !isSelected ? Border.all(color: scheme.primary, width: 1.5) : null,
                ),
                child: Text(
                  '${day.day}',
                  style: TextStyle(color: fg, fontWeight: isToday || isSelected ? FontWeight.w700 : FontWeight.w400),
                ),
              ),
              const SizedBox(height: 3),
              SizedBox(
                height: 6,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final c in dots)
                      Container(
                        width: 5,
                        height: 5,
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                      ),
                    if (more) Text('+', style: TextStyle(fontSize: 8, height: 0.7, color: scheme.outline)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Agenda extends ConsumerWidget {
  const _Agenda({required this.familyId, this.all = false});

  final String familyId;
  final bool all;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final range = upcomingRange(familyId);
    final occ = watchOccurrences(ref, range, all: all);
    final me = ref.watch(currentUserIdProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(occurrencesProvider(range));
        await ref.read(occurrencesProvider(range).future).catchError((_) => const <EventOccurrence>[]);
      },
      child: AsyncValueView(
        value: occ,
        onRetry: () => ref.invalidate(occurrencesProvider(range)),
        data: (all) {
          final groups = groupByDay(all, range.from, range.to);
          if (groups.isEmpty) {
            return ListView(
              children: [MessageView(icon: Icons.event_available_outlined, title: l10n.calendarNoUpcoming)],
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final entry in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
                  child: Text(
                    DateFormat.yMMMMEEEEd(l10n.localeName).format(entry.key),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                for (final o in entry.value)
                  EventOccurrenceTile(
                    occurrence: o,
                    myUserId: me,
                    familyLabel: familyLabelFor(ref, context, o, familyId),
                    onTap: () => openOccurrence(context, o),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
