import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/calendar_repository.dart';
import '../domain/calendar_models.dart';
import 'calendar_providers.dart';
import 'calendar_ui.dart';

/// Create ([eventId] null) or edit an event.
class EventFormScreen extends ConsumerStatefulWidget {
  const EventFormScreen({this.eventId, this.initialDate, super.key});

  final String? eventId;
  final DateTime? initialDate;

  @override
  ConsumerState<EventFormScreen> createState() => _EventFormScreenState();
}

class _EventFormScreenState extends ConsumerState<EventFormScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _location = TextEditingController();
  final _notes = TextEditingController();
  late final String _id = widget.eventId ?? newEventId();

  FamilyEvent? _original;
  bool _loading = false;
  bool _busy = false;
  Object? _loadError;

  bool _allDay = false;
  late DateTime _start;
  late DateTime _end;
  EventCategory _category = EventCategory.family;
  EventRecurrence _recurrence = EventRecurrence.none;
  DateTime? _until;
  bool _participantsOnly = false;
  final Set<String> _participants = {};
  final Set<int> _reminders = {30};

  bool get _isNew => widget.eventId == null;

  @override
  void initState() {
    super.initState();
    final base = widget.initialDate ?? DateTime.now();
    final now = DateTime.now();
    final hour = sameDay(base, now) ? (now.hour + 1).clamp(0, 23) : 9;
    _start = DateTime(base.year, base.month, base.day, hour);
    _end = _start.add(const Duration(hours: 1));
    if (!_isNew) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final repo = ref.read(calendarRepositoryProvider);
      final e = await repo.event(widget.eventId!);
      final mine = e == null ? const <int>[] : await repo.myReminders(e.id);
      if (!mounted) return;
      if (e == null || e.deletedAt != null) throw const AppFailure(FailureKind.notFound);
      setState(() {
        _original = e;
        _title.text = e.title;
        _location.text = e.location ?? '';
        _notes.text = e.description ?? '';
        _allDay = e.allDay;
        _start = e.startsAt;
        _end = e.allDay ? e.endsAt.subtract(const Duration(days: 1)) : e.endsAt;
        _category = e.category;
        _recurrence = e.recurrence;
        _until = e.recurrenceUntil;
        _participantsOnly = e.participantsOnly;
        _participants
          ..clear()
          ..addAll(e.participants.map((p) => p.userId));
        _reminders
          ..clear()
          ..addAll(e.participant(ref.read(currentUserIdProvider)) != null ? mine : e.defaultReminders);
      });
    } catch (err) {
      if (mounted) setState(() => _loadError = err);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool start}) async {
    final current = start ? _start : _end;
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(DateTime.now().year - 5),
      lastDate: DateTime(DateTime.now().year + 10),
    );
    if (date == null) return;
    setState(() {
      final updated = DateTime(date.year, date.month, date.day, current.hour, current.minute);
      if (start) {
        final length = _end.difference(_start);
        _start = updated;
        _end = updated.add(length);
      } else {
        _end = updated;
      }
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _start : _end;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null) return;
    setState(() {
      final updated = DateTime(current.year, current.month, current.day, time.hour, time.minute);
      if (start) {
        final length = _end.difference(_start);
        _start = updated;
        _end = updated.add(length.isNegative ? const Duration(hours: 1) : length);
      } else {
        _end = updated;
      }
    });
  }

  Future<void> _pickUntil() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _until ?? _start.add(const Duration(days: 90)),
      firstDate: dateOnly(_start),
      lastDate: DateTime(_start.year + 20),
    );
    if (date != null) setState(() => _until = date);
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    if (!_form.currentState!.validate()) return;
    final problem = validateEventTimes(start: _start, end: _end, allDay: _allDay);
    if (problem != null) {
      context.showMessage(problem == 'too_long' ? l10n.eventTooLong : l10n.eventEndBeforeStart, error: true);
      return;
    }
    final familyId = ref.read(activeFamilyIdProvider);
    if (familyId == null) return;
    final (startsAt, endsAt) = eventInstants(start: _start, end: _end, allDay: _allDay);
    setState(() => _busy = true);
    try {
      final saved = await ref
          .read(calendarRepositoryProvider)
          .upsert(
            id: _id,
            familyId: familyId,
            title: _title.text,
            startsAt: startsAt,
            endsAt: endsAt,
            allDay: _allDay,
            description: _notes.text.trim().isEmpty ? null : _notes.text,
            location: _location.text.trim().isEmpty ? null : _location.text,
            category: _category,
            recurrence: _recurrence,
            recurrenceUntil: _recurrence == EventRecurrence.none ? null : _until,
            participantsOnly: _participantsOnly,
            participantIds: _participants.toList(),
            reminderMinutes: _reminders.toList(),
            expectedRevision: _original?.revision,
          );
      if (!mounted) return;
      ref.invalidate(eventProvider((familyId: familyId, eventId: saved.id)));
      ref.invalidate(myRemindersProvider(saved.id));
      context.showMessage(l10n.eventSaved);
      context.pop();
    } on AppFailure catch (e) {
      if (!mounted) return;
      if (e.kind == FailureKind.conflict) {
        context.showMessage(l10n.eventConflictReloaded, error: true);
        await _load();
      } else {
        context.showError(e);
      }
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final loc = l10n.localeName;
    final familyId = ref.watch(activeFamilyIdProvider);
    final me = ref.watch(currentUserIdProvider);
    final members = familyId == null
        ? const <FamilyMember>[]
        : (ref.watch(familyMembersProvider(familyId)).value ?? const <FamilyMember>[])
              .where((m) => m.status == MemberStatus.active && m.userId != me)
              .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? l10n.newEvent : l10n.editEvent),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: FilledButton(
              onPressed: _busy || _loading || _loadError != null ? null : _save,
              style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l10n.actionSave),
            ),
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _loadError != null
          ? ErrorView(error: _loadError!, onRetry: _load)
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  TextFormField(
                    controller: _title,
                    autofocus: _isNew,
                    maxLength: 120,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(labelText: l10n.eventTitle),
                    validator: (v) => (v ?? '').trim().isEmpty ? l10n.validationRequired : null,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.eventAllDay),
                    value: _allDay,
                    onChanged: (v) => setState(() => _allDay = v),
                  ),
                  _DateTimeRow(
                    label: l10n.eventStarts,
                    date: DateFormat.yMMMEd(loc).format(_start),
                    time: _allDay ? null : DateFormat.Hm(loc).format(_start),
                    onDate: () => _pickDate(start: true),
                    onTime: () => _pickTime(start: true),
                  ),
                  _DateTimeRow(
                    label: l10n.eventEnds,
                    date: DateFormat.yMMMEd(loc).format(_end),
                    time: _allDay ? null : DateFormat.Hm(loc).format(_end),
                    onDate: () => _pickDate(start: false),
                    onTime: () => _pickTime(start: false),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    controller: _location,
                    maxLength: 200,
                    decoration: InputDecoration(
                      labelText: l10n.eventLocation,
                      prefixIcon: const Icon(Icons.place_outlined),
                    ),
                  ),
                  TextFormField(
                    controller: _notes,
                    maxLength: 2000,
                    minLines: 2,
                    maxLines: 5,
                    decoration: InputDecoration(labelText: l10n.eventNotes, prefixIcon: const Icon(Icons.notes)),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(l10n.category, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final c in EventCategory.values)
                        ChoiceChip(
                          avatar: Icon(c.icon, size: 18, color: c.color),
                          label: Text(eventCategoryLabel(l10n, c)),
                          selected: _category == c,
                          onSelected: (_) => setState(() => _category = c),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<EventRecurrence>(
                    initialValue: _recurrence,
                    decoration: InputDecoration(labelText: l10n.repeat, prefixIcon: const Icon(Icons.repeat)),
                    items: [
                      for (final r in EventRecurrence.values)
                        DropdownMenuItem(value: r, child: Text(eventRecurrenceLabel(l10n, r))),
                    ],
                    onChanged: (v) => setState(() => _recurrence = v ?? EventRecurrence.none),
                  ),
                  if (_recurrence != EventRecurrence.none)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event_repeat_outlined),
                      title: Text(
                        _until == null
                            ? l10n.eventRepeatForever
                            : l10n.eventRepeatsUntil(DateFormat.yMMMd(loc).format(_until!)),
                      ),
                      trailing: _until == null
                          ? TextButton(onPressed: _pickUntil, child: Text(l10n.eventSetEndDate))
                          : IconButton(
                              tooltip: l10n.eventRepeatForever,
                              onPressed: () => setState(() => _until = null),
                              icon: const Icon(Icons.clear),
                            ),
                      onTap: _pickUntil,
                    ),
                  const Divider(),
                  Text(l10n.eventReminders, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final m in {...reminderChoices, ..._reminders}.toList()..sort())
                        FilterChip(
                          label: Text(reminderLabel(l10n, m)),
                          selected: _reminders.contains(m),
                          onSelected: (v) => setState(() {
                            if (v && _reminders.length >= 5) {
                              context.showMessage(l10n.remindersMax, error: true);
                              return;
                            }
                            v ? _reminders.add(m) : _reminders.remove(m);
                          }),
                        ),
                    ],
                  ),
                  if (_isNew) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(l10n.remindersDefaultHint, style: Theme.of(context).textTheme.bodySmall),
                  ],
                  const Divider(),
                  Text(l10n.eventParticipants, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  if (members.isEmpty)
                    Text(l10n.eventNoOtherMembers, style: Theme.of(context).textTheme.bodySmall)
                  else
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        FilterChip(
                          label: Text(l10n.eventInviteEveryone),
                          selected: members.every((m) => _participants.contains(m.userId)),
                          onSelected: (v) => setState(
                            () => v
                                ? _participants.addAll(members.map((m) => m.userId))
                                : _participants.removeAll(members.map((m) => m.userId)),
                          ),
                        ),
                        for (final m in members)
                          FilterChip(
                            label: Text(m.displayName),
                            selected: _participants.contains(m.userId),
                            onSelected: (v) =>
                                setState(() => v ? _participants.add(m.userId) : _participants.remove(m.userId)),
                          ),
                      ],
                    ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(l10n.eventInviteHint, style: Theme.of(context).textTheme.bodySmall),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.eventVisibleParticipants),
                    subtitle: Text(l10n.eventVisibleParticipantsHint),
                    value: _participantsOnly,
                    onChanged: (v) => setState(() => _participantsOnly = v),
                  ),
                  if (_original?.isRecurring ?? false)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(l10n.eventSeriesNote, style: Theme.of(context).textTheme.bodySmall),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                ],
              ),
            ),
    );
  }
}

class _DateTimeRow extends StatelessWidget {
  const _DateTimeRow({required this.label, required this.date, required this.onDate, required this.onTime, this.time});

  final String label;
  final String date;
  final String? time;
  final VoidCallback onDate;
  final VoidCallback onTime;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 64, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
      Expanded(
        child: TextButton(
          onPressed: onDate,
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
          child: Text(date),
        ),
      ),
      if (time != null) TextButton(onPressed: onTime, child: Text(time!)),
    ],
  );
}
