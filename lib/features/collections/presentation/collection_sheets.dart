import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../family/domain/family_models.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/presentation/family_providers.dart';
import '../../family_tree/presentation/tree_photo.dart' show PhotoAction, choosePhotoAction, pickTreeImage;
import '../data/collections_repository.dart';
import '../domain/collection_models.dart';
import 'collection_providers.dart';

String collectionModeLabel(BuildContext context, CollectionMode m) => switch (m) {
  CollectionMode.open => context.l10n.collectionModeOpen,
  CollectionMode.lump => context.l10n.collectionModeLump,
  CollectionMode.perMember => context.l10n.collectionModePerMember,
};

String? _amountError(BuildContext context, String? v, {bool required = true}) {
  if ((v ?? '').trim().isEmpty) return required ? context.l10n.validationRequired : null;
  return parseAmount(v!) == null ? context.l10n.collectionAmountInvalid : null;
}

InputDecoration _moneyDecoration(String label) => InputDecoration(labelText: label, prefixText: 'RM ');

// ------------------------------------------------------------------ create / edit

/// Create ([existing] null) or edit a collection. Returns the id when saved.
Future<String?> showCollectionForm(BuildContext context, {required String familyId, Collection? existing}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => CollectionFormSheet(familyId: familyId, existing: existing),
    );

class CollectionFormSheet extends ConsumerStatefulWidget {
  const CollectionFormSheet({required this.familyId, this.existing, super.key});

  final String familyId;
  final Collection? existing;

  @override
  ConsumerState<CollectionFormSheet> createState() => _CollectionFormSheetState();
}

class _CollectionFormSheetState extends ConsumerState<CollectionFormSheet> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _purpose = TextEditingController(text: widget.existing?.purpose ?? '');
  late final _lump = TextEditingController(
    text: widget.existing?.lumpTarget == null ? '' : amountText(widget.existing!.lumpTarget!),
  );
  late var _mode = widget.existing?.mode ?? CollectionMode.lump;
  late var _share = widget.existing?.shareWithClan ?? false;
  late DateTime? _due = widget.existing?.dueDate;
  late final Set<String> _treasurers = {...?widget.existing?.treasurerIds};
  late final Map<String, TextEditingController> _targets = {
    for (final t in widget.existing?.targets ?? const <CollectionTarget>[])
      t.userId: TextEditingController(text: amountText(t.amount)),
  };
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _purpose.dispose();
    _lump.dispose();
    for (final c in _targets.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final l10n = context.l10n;
    final targets = <String, int>{for (final e in _targets.entries) e.key: ?parseAmount(e.value.text)};
    if (_mode == CollectionMode.perMember && targets.isEmpty) {
      context.showMessage(l10n.collectionNeedTargets, error: true);
      return;
    }
    setState(() => _busy = true);
    final id = widget.existing?.id ?? CollectionsRepository.newId();
    try {
      await ref
          .read(collectionsRepositoryProvider)
          .upsert(
            id: id,
            familyId: widget.existing?.familyId ?? widget.familyId,
            title: _title.text,
            purpose: _purpose.text,
            mode: _mode,
            lumpTarget: parseAmount(_lump.text),
            dueDate: _due,
            shareWithClan: _share,
            treasurerIds: _treasurers.toList(),
            memberTargets: _mode == CollectionMode.perMember ? targets : null,
            expectedRevision: widget.existing?.revision,
          );
      ref.invalidate(collectionSummariesProvider);
      ref.invalidate(collectionProvider(id));
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final familyId = widget.existing?.familyId ?? widget.familyId;
    final members =
        (ref.watch(familyMembersProvider(familyId)).value ?? const <FamilyMember>[])
            .where((m) => m.status == MemberStatus.active)
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
    final me = ref.watch(currentUserIdProvider);
    final total = _targets.values.fold<int>(0, (s, c) => s + (parseAmount(c.text) ?? 0));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _form,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
          children: [
            Text(widget.existing == null ? l10n.collectionNew : l10n.collectionEdit, style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              key: const Key('collection.title'),
              controller: _title,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.collectionTitle),
              validator: (v) => (v ?? '').trim().isEmpty ? l10n.validationRequired : null,
            ),
            TextFormField(
              key: const Key('collection.purpose'),
              controller: _purpose,
              maxLength: 500,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.collectionPurpose, hintText: l10n.collectionPurposeHint),
              validator: (v) => (v ?? '').trim().isEmpty ? l10n.validationRequired : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(l10n.collectionTargetType, style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            SegmentedButton<CollectionMode>(
              showSelectedIcon: false,
              segments: [
                for (final m in [CollectionMode.lump, CollectionMode.perMember, CollectionMode.open])
                  ButtonSegment(
                    value: m,
                    label: Text(collectionModeLabel(context, m), textAlign: TextAlign.center),
                  ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_mode == CollectionMode.lump)
              TextFormField(
                key: const Key('collection.lump'),
                controller: _lump,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: _moneyDecoration(l10n.collectionTarget),
                validator: (v) => _amountError(context, v),
              ),
            if (_mode == CollectionMode.perMember) ...[
              Text(l10n.collectionPerMemberHint, style: theme.textTheme.bodySmall),
              for (final m in members)
                Row(
                  children: [
                    Checkbox(
                      value: _targets.containsKey(m.userId),
                      onChanged: (v) => setState(() {
                        if (v ?? false) {
                          _targets[m.userId] = TextEditingController();
                        } else {
                          _targets.remove(m.userId)?.dispose();
                        }
                      }),
                    ),
                    Expanded(child: Text(m.userId == me ? '${m.displayName} (${l10n.you})' : m.displayName)),
                    if (_targets.containsKey(m.userId))
                      SizedBox(
                        width: 130,
                        child: TextFormField(
                          key: Key('collection.target.${m.userId}'),
                          controller: _targets[m.userId],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(prefixText: 'RM ', isDense: true),
                          onChanged: (_) => setState(() {}),
                          validator: (v) => _amountError(context, v),
                        ),
                      ),
                  ],
                ),
              Align(
                alignment: Alignment.centerRight,
                child: Text(l10n.collectionTargetTotal(formatRM(context, total)), style: theme.textTheme.labelLarge),
              ),
            ],
            if (_mode == CollectionMode.open) Text(l10n.collectionOpenHint, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(_due == null ? l10n.collectionNoDueDate : l10n.collectionDue(context.formatDate(_due!))),
              trailing: _due == null
                  ? null
                  : IconButton(
                      tooltip: l10n.clearDueDate,
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _due = null),
                    ),
              onTap: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: context,
                  initialDate: _due ?? now,
                  firstDate: DateTime(now.year - 1),
                  lastDate: DateTime(now.year + 5),
                );
                if (d != null) setState(() => _due = d);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.hub_outlined),
              title: Text(l10n.collectionShareClan),
              subtitle: Text(l10n.collectionShareClanHint),
              value: _share,
              onChanged: (v) => setState(() => _share = v),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(l10n.collectionTreasurers, style: theme.textTheme.titleSmall),
            Text(l10n.collectionTreasurersHint, style: theme.textTheme.bodySmall),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final m in members)
                  if (m.userId != (widget.existing?.createdBy ?? me))
                    FilterChip(
                      label: Text(m.displayName),
                      selected: _treasurers.contains(m.userId),
                      onSelected: (v) => setState(() => v ? _treasurers.add(m.userId) : _treasurers.remove(m.userId)),
                    ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              l10n.collectionRecordOnly,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              key: const Key('collection.save'),
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Text(l10n.actionSave),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ payment / expense

enum MoneyEntryKind { payment, expense }

/// Records a payment (or, for treasurers, an expense).
Future<void> showMoneyEntrySheet(
  BuildContext context, {
  required Collection collection,
  required MoneyEntryKind kind,
  bool treasurer = false,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => MoneyEntrySheet(collection: collection, kind: kind, treasurer: treasurer),
);

class MoneyEntrySheet extends ConsumerStatefulWidget {
  const MoneyEntrySheet({required this.collection, required this.kind, this.treasurer = false, super.key});

  final Collection collection;
  final MoneyEntryKind kind;
  final bool treasurer;

  @override
  ConsumerState<MoneyEntrySheet> createState() => _MoneyEntrySheetState();
}

class _MoneyEntrySheetState extends ConsumerState<MoneyEntrySheet> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _text = TextEditingController();
  var _date = DateTime.now();
  String? _payer; // null = me
  (Uint8List, String)? _receipt;
  bool _busy = false;

  bool get _expense => widget.kind == MoneyEntryKind.expense;

  @override
  void initState() {
    super.initState();
    // Suggest what is still owed on my per-member target.
    final me = ref.read(currentUserIdProvider);
    final c = widget.collection;
    if (!_expense && me != null) {
      final target = c.targets.where((t) => t.userId == me).firstOrNull;
      final left = target == null ? 0 : target.amount - c.paidBy(me) - c.pendingBy(me);
      if (left > 0) _amount.text = amountText(left);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt() async {
    final action = await choosePhotoAction(context, hasPhoto: _receipt != null);
    if (action == null || !mounted) return;
    if (action == PhotoAction.remove) {
      setState(() => _receipt = null);
      return;
    }
    final picked = await pickTreeImage(context, action, maxWidth: 1600);
    if (picked != null) setState(() => _receipt = picked);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final repo = ref.read(collectionsRepositoryProvider);
    try {
      if (_expense) {
        await repo.recordExpense(
          collection: widget.collection,
          amount: parseAmount(_amount.text)!,
          description: _text.text,
          spentOn: _date,
          receipt: _receipt,
        );
      } else {
        await repo.recordPayment(
          collection: widget.collection,
          amount: parseAmount(_amount.text)!,
          paidOn: _date,
          note: _text.text,
          payerId: _payer,
          receipt: _receipt,
        );
      }
      ref.invalidate(collectionProvider(widget.collection.id));
      ref.invalidate(collectionSummariesProvider);
      if (mounted) {
        final l10n = context.l10n;
        context.showMessage(
          _expense
              ? l10n.collectionExpenseSaved
              : widget.treasurer
              ? l10n.collectionPaymentConfirmedSaved
              : l10n.collectionPaymentPendingSaved,
        );
        Navigator.of(context).pop();
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
    final theme = Theme.of(context);
    final c = widget.collection;
    final me = ref.watch(currentUserIdProvider);
    final members = (ref.watch(familyMembersProvider(c.familyId)).value ?? const <FamilyMember>[])
        .where((m) => m.status == MemberStatus.active)
        .toList();
    final payers = <String, String>{
      for (final m in members) m.userId: m.displayName,
      for (final t in c.targets) t.userId: t.name ?? '?',
    }..remove(me);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _form,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
          children: [
            Text(_expense ? l10n.collectionAddExpense : l10n.collectionPay, style: theme.textTheme.titleLarge),
            if (!_expense)
              Text(
                widget.treasurer ? l10n.collectionPayTreasurerHint : l10n.collectionPayMemberHint,
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: AppSpacing.sm),
            if (!_expense && widget.treasurer)
              DropdownButtonFormField<String?>(
                key: const Key('payment.payer'),
                initialValue: _payer,
                decoration: InputDecoration(labelText: l10n.collectionPayer),
                items: [
                  DropdownMenuItem(value: null, child: Text(l10n.you)),
                  for (final e in payers.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _payer = v),
              ),
            TextFormField(
              key: const Key('money.amount'),
              controller: _amount,
              autofocus: _amount.text.isEmpty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _moneyDecoration(l10n.collectionAmount),
              validator: (v) => _amountError(context, v),
            ),
            TextFormField(
              key: const Key('money.text'),
              controller: _text,
              maxLength: 300,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: _expense ? l10n.collectionExpenseWhat : l10n.collectionNote),
              validator: (v) => _expense && (v ?? '').trim().isEmpty ? l10n.validationRequired : null,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(context.formatDate(_date)),
              onTap: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(now.year - 2),
                  lastDate: now,
                );
                if (d != null) setState(() => _date = d);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _receipt == null
                  ? const Icon(Icons.receipt_long_outlined)
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(_receipt!.$1, width: 40, height: 40, fit: BoxFit.cover),
                    ),
              title: Text(_receipt == null ? l10n.collectionAddReceipt : l10n.collectionReceiptAdded),
              subtitle: Text(l10n.collectionReceiptOptional),
              onTap: _pickReceipt,
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              key: const Key('money.save'),
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Text(l10n.actionSave),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for an optional reason when rejecting a payment. Null = cancelled.
Future<String?> askRejectReason(BuildContext context) {
  final ctrl = TextEditingController();
  final l10n = context.l10n;
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.collectionRejectTitle),
      content: TextField(
        controller: ctrl,
        maxLength: 300,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.collectionRejectReason),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.actionCancel)),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text), child: Text(l10n.reject)),
      ],
    ),
  );
}
