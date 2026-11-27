import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family_tree/presentation/person_screen.dart' show adminOfFamilyProvider;
import '../data/collections_repository.dart';
import '../domain/collection_models.dart';
import 'collection_providers.dart';
import 'collection_sheets.dart';

/// All collections visible from the active family (own + clan-shared).
class CollectionsScreen extends ConsumerWidget {
  const CollectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final familyId = ref.watch(activeFamilyIdProvider);
    if (familyId == null) return const Scaffold(body: LoadingView());
    final list = ref.watch(collectionSummariesProvider(familyId));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.collectionsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('collections.new'),
        icon: const Icon(Icons.add),
        label: Text(l10n.collectionNew),
        onPressed: () async {
          final id = await showCollectionForm(context, familyId: familyId);
          if (id != null && context.mounted) await context.push(Routes.collection(id));
        },
      ),
      body: AsyncValueView(
        value: list,
        onRetry: () => ref.invalidate(collectionSummariesProvider(familyId)),
        data: (items) => RefreshIndicator(
          onRefresh: () => ref.refresh(collectionSummariesProvider(familyId).future),
          child: items.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 80),
                    MessageView(
                      icon: Icons.payments_outlined,
                      title: l10n.collectionsEmptyTitle,
                      message: l10n.collectionsEmptyBody,
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 96),
                  children: [
                    for (final s in items) ...[
                      _SummaryCard(summary: s, otherFamily: s.familyId != familyId),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.otherFamily});

  final CollectionSummary summary;
  final bool otherFamily;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final s = summary;
    final amounts = s.target == null
        ? l10n.collectionCollected(formatRM(context, s.confirmed))
        : '${formatRM(context, s.confirmed)} / ${formatRM(context, s.target!)}';
    return Card(
      key: ValueKey('collection-${s.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.collection(s.id)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.payments_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      s.title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (s.closed) _Chip(text: l10n.collectionClosed, color: theme.colorScheme.outline),
                  if (s.shareWithClan || otherFamily)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.hub_outlined, size: 18, color: theme.colorScheme.outline),
                    ),
                ],
              ),
              Text(s.purpose, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              const SizedBox(height: AppSpacing.sm),
              if (s.progress != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: s.progress,
                    minHeight: 8,
                    color: theme.colorScheme.secondary,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(amounts, style: theme.textTheme.labelLarge),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  if (s.myTarget != null)
                    _Chip(
                      text: l10n.collectionMyPart(formatRM(context, s.myPaid), formatRM(context, s.myTarget!)),
                      color: s.myPaid >= s.myTarget! ? Colors.green.shade700 : theme.colorScheme.primary,
                    ),
                  if (s.isTreasurer && s.pending > 0)
                    _Chip(
                      text: l10n.collectionPendingAmount(formatRM(context, s.pending)),
                      color: Colors.orange.shade800,
                    ),
                  if (s.dueDate != null && !s.closed)
                    _Chip(text: l10n.collectionDue(context.formatDate(s.dueDate!)), color: theme.colorScheme.outline),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

// ------------------------------------------------------------------ detail

class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({required this.collectionId, super.key});

  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final value = ref.watch(collectionProvider(collectionId));
    return value.when(
      loading: () => Scaffold(appBar: AppBar(), body: const LoadingView()),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: ErrorView(error: e, onRetry: () => ref.invalidate(collectionProvider(collectionId))),
      ),
      data: (c) {
        if (c == null) {
          return Scaffold(
            appBar: AppBar(),
            body: MessageView(icon: Icons.payments_outlined, title: l10n.collectionNotFound),
          );
        }
        final me = ref.watch(currentUserIdProvider);
        final treasurer = c.isTreasurer(me, familyAdmin: ref.watch(adminOfFamilyProvider(c.familyId)));
        return _CollectionView(collection: c, me: me, treasurer: treasurer);
      },
    );
  }
}

class _CollectionView extends ConsumerWidget {
  const _CollectionView({required this.collection, required this.me, required this.treasurer});

  final Collection collection;
  final String? me;
  final bool treasurer;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action, {String? done}) async {
    try {
      await action();
      ref.invalidate(collectionProvider(collection.id));
      ref.invalidate(collectionSummariesProvider);
      if (done != null && context.mounted) context.showMessage(done);
    } catch (e) {
      if (context.mounted) context.showError(e);
    }
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, String v) async {
    final l10n = context.l10n;
    final repo = ref.read(collectionsRepositoryProvider);
    final c = collection;
    switch (v) {
      case 'edit':
        await showCollectionForm(context, familyId: c.familyId, existing: c);
      case 'expense':
        await showMoneyEntrySheet(context, collection: c, kind: MoneyEntryKind.expense, treasurer: true);
      case 'remind':
        try {
          final n = await repo.remind(c.id);
          if (context.mounted) context.showMessage(l10n.collectionReminded(n));
        } catch (e) {
          if (context.mounted) context.showError(e);
        }
      case 'close':
        await _run(context, ref, () => repo.setClosed(c.id, closed: !c.closed));
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: l10n.collectionDeleteTitle,
          message: l10n.collectionDeleteMessage(c.title),
          destructive: true,
          confirmLabel: l10n.actionDelete,
        );
        if (!ok || !context.mounted) return;
        await _run(context, ref, () => repo.delete(c.id));
        if (context.mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final c = collection;
    final repo = ref.read(collectionsRepositoryProvider);
    final target = c.target;
    final myTarget = c.targets.where((t) => t.userId == me).firstOrNull;
    final pending = c.pendingPayments;

    Widget stat(String label, int amount, {Color? color, Key? key}) => Expanded(
      child: Column(
        key: key,
        children: [
          Text(
            formatRM(context, amount),
            style: theme.textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
          Text(label, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );

    String statusLabel(PaymentStatus s) => switch (s) {
      PaymentStatus.pending => l10n.collectionStatusPending,
      PaymentStatus.confirmed => l10n.collectionStatusConfirmed,
      PaymentStatus.rejected => l10n.collectionStatusRejected,
    };
    Color statusColor(PaymentStatus s) => switch (s) {
      PaymentStatus.pending => Colors.orange.shade800,
      PaymentStatus.confirmed => Colors.green.shade700,
      PaymentStatus.rejected => theme.colorScheme.error,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(c.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (treasurer)
            PopupMenuButton<String>(
              key: const Key('collection.menu'),
              onSelected: (v) => _menu(context, ref, v),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(l10n.collectionEdit)),
                PopupMenuItem(value: 'expense', child: Text(l10n.collectionAddExpense)),
                if (!c.closed) PopupMenuItem(value: 'remind', child: Text(l10n.collectionRemind)),
                PopupMenuItem(value: 'close', child: Text(c.closed ? l10n.collectionReopen : l10n.collectionClose)),
                PopupMenuItem(value: 'delete', child: Text(l10n.actionDelete)),
              ],
            ),
        ],
      ),
      floatingActionButton: c.closed
          ? null
          : FloatingActionButton.extended(
              key: const Key('collection.pay'),
              icon: const Icon(Icons.add_circle_outline),
              label: Text(treasurer ? l10n.collectionRecordPayment : l10n.collectionPay),
              onPressed: () =>
                  showMoneyEntrySheet(context, collection: c, kind: MoneyEntryKind.payment, treasurer: treasurer),
            ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(collectionProvider(c.id).future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 96),
          children: [
            Text(c.purpose, style: theme.textTheme.bodyLarge),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                _Chip(text: collectionModeLabel(context, c.mode), color: theme.colorScheme.primary),
                if (c.closed) _Chip(text: l10n.collectionClosed, color: theme.colorScheme.outline),
                if (c.shareWithClan) _Chip(text: l10n.collectionSharedClan, color: theme.colorScheme.tertiary),
                if (c.dueDate != null)
                  _Chip(text: l10n.collectionDue(context.formatDate(c.dueDate!)), color: theme.colorScheme.outline),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  children: [
                    if (target != null) ...[
                      Text(
                        l10n.collectionProgress(formatRM(context, c.confirmed), formatRM(context, target)),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: target == 0 ? 0 : (c.confirmed / target).clamp(0, 1).toDouble(),
                          minHeight: 10,
                          color: theme.colorScheme.secondary,
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        c.confirmed >= target
                            ? (c.confirmed > target
                                  ? l10n.collectionAboveTarget(formatRM(context, c.confirmed - target))
                                  : l10n.collectionReached)
                            : l10n.collectionRemaining(formatRM(context, target - c.confirmed)),
                        style: theme.textTheme.bodySmall,
                      ),
                      const Divider(),
                    ],
                    Row(
                      children: [
                        stat(
                          l10n.collectionStatCollected,
                          c.confirmed,
                          color: Colors.green.shade700,
                          key: const Key('stat.collected'),
                        ),
                        stat(l10n.collectionStatPending, c.pending, color: Colors.orange.shade800),
                        stat(l10n.collectionStatSpent, c.spent, color: theme.colorScheme.error),
                        stat(l10n.collectionStatBalance, c.balance, key: const Key('stat.balance')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (myTarget != null && me != null)
              Card(
                color: theme.colorScheme.primaryContainer,
                child: ListTile(
                  leading: Icon(Icons.person_outline, color: theme.colorScheme.onPrimaryContainer),
                  title: Text(
                    l10n.collectionMyPart(formatRM(context, c.paidBy(me!)), formatRM(context, myTarget.amount)),
                    style: TextStyle(color: theme.colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    c.paidBy(me!) >= myTarget.amount
                        ? l10n.collectionMyDone
                        : l10n.collectionRemaining(formatRM(context, myTarget.amount - c.paidBy(me!))),
                    style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                  ),
                ),
              ),
            if (treasurer && pending.isNotEmpty) ...[
              _Header(l10n.collectionToConfirm(pending.length)),
              for (final p in pending)
                Card(
                  key: ValueKey('pending-${p.id}'),
                  child: ListTile(
                    title: Text('${p.payerName ?? '?'} · ${formatRM(context, p.amount)}'),
                    subtitle: Text([context.formatDate(p.paidOn), ?p.note].join(' · ')),
                    leading: p.receiptPath == null
                        ? const Icon(Icons.hourglass_top)
                        : IconButton(
                            tooltip: l10n.receipt,
                            icon: const Icon(Icons.receipt_long),
                            onPressed: () => showReceipt(context, p.receiptPath!),
                          ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: ValueKey('reject-${p.id}'),
                          tooltip: l10n.reject,
                          icon: Icon(Icons.close, color: theme.colorScheme.error),
                          onPressed: () async {
                            final reason = await askRejectReason(context);
                            if (reason == null || !context.mounted) return;
                            await _run(context, ref, () => repo.reviewPayment(p.id, approve: false, reason: reason));
                          },
                        ),
                        IconButton(
                          key: ValueKey('confirm-${p.id}'),
                          tooltip: l10n.collectionConfirm,
                          icon: Icon(Icons.check_circle, color: Colors.green.shade700),
                          onPressed: () => _run(context, ref, () => repo.reviewPayment(p.id, approve: true)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            if (c.mode == CollectionMode.perMember) ...[
              _Header(l10n.collectionByMember),
              for (final t in c.targets)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    c.paidBy(t.userId) >= t.amount ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: c.paidBy(t.userId) >= t.amount ? Colors.green.shade700 : theme.colorScheme.outline,
                  ),
                  title: Text(t.name ?? '?'),
                  subtitle: c.pendingBy(t.userId) > 0
                      ? Text(l10n.collectionPendingAmount(formatRM(context, c.pendingBy(t.userId))))
                      : null,
                  trailing: Text(
                    '${formatRM(context, c.paidBy(t.userId))} / ${formatRM(context, t.amount)}',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
            ],
            _Header(l10n.collectionPayments),
            if (c.payments.isEmpty) Text(l10n.collectionNoPayments, style: theme.textTheme.bodySmall),
            for (final p in c.payments)
              ListTile(
                key: ValueKey('payment-${p.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text('${p.payerName ?? '?'} · ${formatRM(context, p.amount)}'),
                subtitle: Text(
                  [
                    context.formatDate(p.paidOn),
                    statusLabel(p.status),
                    ?p.note,
                    if (p.rejectReason != null) l10n.collectionRejectedBecause(p.rejectReason!),
                  ].join(' · '),
                  style: TextStyle(color: p.status == PaymentStatus.confirmed ? null : statusColor(p.status)),
                ),
                leading: Icon(switch (p.status) {
                  PaymentStatus.pending => Icons.hourglass_top,
                  PaymentStatus.confirmed => Icons.check_circle_outline,
                  PaymentStatus.rejected => Icons.cancel_outlined,
                }, color: statusColor(p.status)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (p.receiptPath != null)
                      IconButton(
                        tooltip: l10n.receipt,
                        icon: const Icon(Icons.receipt_long_outlined),
                        onPressed: () => showReceipt(context, p.receiptPath!),
                      ),
                    if (treasurer || (p.payerId == me && p.status == PaymentStatus.pending))
                      IconButton(
                        tooltip: l10n.actionDelete,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await confirmDialog(
                            context,
                            title: l10n.collectionDeletePayment,
                            message: '${p.payerName ?? '?'} · ${formatRM(context, p.amount)}',
                            destructive: true,
                            confirmLabel: l10n.actionDelete,
                          );
                          if (ok && context.mounted) await _run(context, ref, () => repo.deletePayment(p.id));
                        },
                      ),
                  ],
                ),
              ),
            _Header(l10n.collectionExpenses),
            if (c.expenses.isEmpty) Text(l10n.collectionNoExpenses, style: theme.textTheme.bodySmall),
            for (final e in c.expenses)
              ListTile(
                key: ValueKey('expense-${e.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.shopping_bag_outlined, color: theme.colorScheme.error),
                title: Text('${e.description} · ${formatRM(context, e.amount)}'),
                subtitle: Text(context.formatDate(e.spentOn)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (e.receiptPath != null)
                      IconButton(
                        tooltip: l10n.receipt,
                        icon: const Icon(Icons.receipt_long_outlined),
                        onPressed: () => showReceipt(context, e.receiptPath!),
                      ),
                    if (treasurer)
                      IconButton(
                        tooltip: l10n.actionDelete,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await confirmDialog(
                            context,
                            title: l10n.collectionDeleteExpense,
                            message: '${e.description} · ${formatRM(context, e.amount)}',
                            destructive: true,
                            confirmLabel: l10n.actionDelete,
                          );
                          if (ok && context.mounted) await _run(context, ref, () => repo.deleteExpense(e.id));
                        },
                      ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            Text(
              l10n.collectionRecordOnly,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.xs),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
