import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../data/notification_repository.dart';
import '../domain/notification_models.dart';
import 'notification_providers.dart';

class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final repo = ref.read(notificationRepositoryProvider);

    Future<void> update(Map<String, dynamic> patch) async {
      try {
        await repo.updatePrefs(patch);
        ref.invalidate(notificationPrefsProvider);
      } catch (e) {
        if (context.mounted) context.showError(e);
      }
    }

    Future<int?> pickTime(int? current) async {
      final t = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: (current ?? 22 * 60) ~/ 60, minute: (current ?? 0) % 60),
      );
      return t == null ? null : t.hour * 60 + t.minute;
    }

    String fmt(int m) => MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay(hour: m ~/ 60, minute: m % 60));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.notificationSettings)),
      body: AsyncValueView(
        value: ref.watch(notificationPrefsProvider),
        onRetry: () => ref.invalidate(notificationPrefsProvider),
        data: (p) => ListView(
          children: [
            if (!AppConfig.isPushConfigured)
              Card(
                margin: const EdgeInsets.all(AppSpacing.md),
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: ListTile(leading: const Icon(Icons.info_outline), title: Text(l10n.pushNotConfigured)),
              ),
            _Section(l10n.notifyFor),
            SwitchListTile(
              title: Text(l10n.prefPrivateMessages),
              value: p.privateMessages,
              onChanged: (v) => update({'notify_private_messages': v}),
            ),
            SwitchListTile(
              title: Text(l10n.prefGroupMessages),
              value: p.groupMessages,
              onChanged: (v) => update({'notify_group_messages': v}),
            ),
            SwitchListTile(title: Text(l10n.prefTasks), value: p.tasks, onChanged: (v) => update({'notify_tasks': v})),
            SwitchListTile(
              title: Text(l10n.prefEvents),
              value: p.events,
              onChanged: (v) => update({'notify_events': v}),
            ),
            SwitchListTile(
              title: Text(l10n.prefAnnouncements),
              value: p.announcements,
              onChanged: (v) => update({'notify_announcements': v}),
            ),
            _Section(l10n.privacy),
            SwitchListTile(
              key: const Key('prefs.preview'),
              title: Text(l10n.prefShowPreview),
              subtitle: Text(l10n.prefShowPreviewHint),
              value: p.showPreview,
              onChanged: (v) => update({'show_message_preview': v}),
            ),
            _Section(l10n.quietHours),
            SwitchListTile(
              title: Text(l10n.quietHoursEnable),
              subtitle: Text(l10n.quietHoursHint),
              value: p.quietHoursEnabled,
              onChanged: (v) => update(
                v
                    ? {'quiet_hours_start': '22:00:00', 'quiet_hours_end': '07:00:00'}
                    : {'quiet_hours_start': null, 'quiet_hours_end': null},
              ),
            ),
            if (p.quietHoursEnabled) ...[
              ListTile(
                leading: const Icon(Icons.bedtime_outlined),
                title: Text(l10n.quietFrom),
                trailing: Text(fmt(p.quietStart!)),
                onTap: () async {
                  final m = await pickTime(p.quietStart);
                  if (m != null) await update({'quiet_hours_start': formatTimeOfDay(m)});
                },
              ),
              ListTile(
                leading: const Icon(Icons.wb_sunny_outlined),
                title: Text(l10n.quietUntil),
                trailing: Text(fmt(p.quietEnd!)),
                onTap: () async {
                  final m = await pickTime(p.quietEnd);
                  if (m != null) await update({'quiet_hours_end': formatTimeOfDay(m)});
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.xs),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
  );
}

/// Sheet for owners/admins to send an important family announcement.
Future<void> showAnnouncementSheet(BuildContext context, WidgetRef ref, {required String familyId}) async {
  final l10n = context.l10n;
  final title = TextEditingController();
  final body = TextEditingController();
  final sent = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        MediaQuery.viewInsetsOf(ctx).bottom + AppSpacing.lg,
      ),
      child: StatefulBuilder(
        builder: (ctx, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.newAnnouncement, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: title,
              maxLength: 120,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.announcementTitle),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: body,
              maxLength: 300,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: l10n.announcementBody),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              icon: const Icon(Icons.campaign_outlined),
              label: Text(l10n.sendAnnouncement),
              onPressed: title.text.trim().isEmpty || body.text.trim().isEmpty
                  ? null
                  : () async {
                      try {
                        final n = await ref
                            .read(notificationRepositoryProvider)
                            .postAnnouncement(familyId, title: title.text, body: body.text);
                        if (ctx.mounted) Navigator.pop(ctx, n);
                      } catch (e) {
                        if (ctx.mounted) ctx.showError(e);
                      }
                    },
            ),
          ],
        ),
      ),
    ),
  );
  title.dispose();
  body.dispose();
  if (sent != null && context.mounted) context.showMessage(l10n.announcementSent(sent));
}
