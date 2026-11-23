import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/local_database.dart';
import '../../../core/offline/sync_engine.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Thin status strip above the bottom navigation: offline, syncing, or
/// writes that could not be applied. Hidden when everything is in sync.
class SyncStatusBanner extends ConsumerWidget {
  const SyncStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sync = ref.watch(syncEngineProvider);
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String text, Color bg, Color fg)? content = switch (sync) {
      SyncState(failed: > 0) => (
        Icons.sync_problem,
        l10n.syncFailedBanner(sync.failed),
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      SyncState(online: false) => (
        Icons.cloud_off_outlined,
        sync.pending > 0 ? l10n.offlineBannerPending(sync.pending) : l10n.offlineBanner,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      SyncState(pending: > 0) => (
        Icons.sync,
        l10n.syncingBanner(sync.pending),
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      _ => null,
    };
    if (content == null) return const SizedBox.shrink();
    final (icon, text, bg, fg) = content;
    return Material(
      color: bg,
      child: InkWell(
        key: const Key('sync-banner'),
        onTap: () => context.push(Routes.sync),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(color: fg),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: fg),
            ],
          ),
        ),
      ),
    );
  }
}

String outboxOpTitle(AppLocalizations l, OutboxOp op) {
  final p = opParams(op);
  return switch (OutboxKind.parse(op.kind)) {
    OutboxKind.todoUpsertItem => l.syncOpTodoSave(p['p_title'] as String? ?? ''),
    OutboxKind.todoSetStatus => p['p_completed'] == true ? l.syncOpTodoDone : l.syncOpTodoReopen,
    OutboxKind.todoDeleteItem => l.syncOpTodoDelete,
    OutboxKind.chatSendText => l.syncOpMessage(p['p_body'] as String? ?? ''),
    OutboxKind.eventRsvp => l.syncOpRsvp,
    null => op.kind,
  };
}

String? outboxOpError(AppLocalizations l, OutboxOp op) {
  final code = op.lastError;
  if (op.status != 'failed' || code == null) return null;
  final kind = FailureKind.values.where((k) => k.name == code).firstOrNull;
  if (kind == FailureKind.conflict) return l.syncConflict;
  return kind == null ? l.errorGeneric : l.failure(kind);
}

/// Everything waiting to be synced, with retry and discard.
class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sync = ref.watch(syncEngineProvider);
    final engine = ref.read(syncEngineProvider.notifier);
    final fmt = DateFormat.MMMd(l10n.localeName).add_Hm();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.syncTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Card(
            child: ListTile(
              leading: Icon(sync.online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
              title: Text(sync.online ? l10n.syncOnline : l10n.syncOffline),
              subtitle: Text(
                sync.lastSyncedAt == null ? l10n.syncExplain : l10n.syncLastRun(fmt.format(sync.lastSyncedAt!)),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: sync.syncing || !sync.hasWork ? null : () => engine.retryFailed(),
            icon: sync.syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            label: Text(l10n.syncNow),
          ),
          const SizedBox(height: AppSpacing.md),
          if (!sync.hasWork)
            MessageView(icon: Icons.done_all, title: l10n.syncNothing)
          else
            for (final op in sync.ops)
              Card(
                child: ListTile(
                  leading: Icon(
                    op.status == 'failed' ? Icons.error_outline : Icons.schedule,
                    color: op.status == 'failed' ? Theme.of(context).colorScheme.error : null,
                  ),
                  title: Text(outboxOpTitle(l10n, op), maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text([fmt.format(op.createdAt), outboxOpError(l10n, op) ?? l10n.syncWaiting].join(' · ')),
                  trailing: IconButton(
                    tooltip: l10n.syncDiscard,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDialog(
                        context,
                        title: l10n.syncDiscard,
                        message: l10n.syncDiscardMessage,
                        confirmLabel: l10n.syncDiscard,
                        destructive: true,
                      );
                      if (ok) await engine.discard(op.id);
                    },
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
