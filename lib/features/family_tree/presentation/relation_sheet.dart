import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../data/tree_repository.dart';
import '../domain/tree_models.dart';
import 'person_form_sheet.dart';
import 'tree_providers.dart';

/// What the other person is to [TreeRelationSheet.person].
enum RelationChoice { parent, child, spouse }

/// Adds (admin) or proposes (member) a link between [person] and someone.
Future<void> showRelationSheet(
  BuildContext context, {
  required String familyId,
  required TreePerson person,
  required TreeData tree,
  required bool isAdmin,
  RelationChoice initial = RelationChoice.child,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => TreeRelationSheet(familyId: familyId, person: person, tree: tree, isAdmin: isAdmin, initial: initial),
);

class TreeRelationSheet extends ConsumerStatefulWidget {
  const TreeRelationSheet({
    required this.familyId,
    required this.person,
    required this.tree,
    required this.isAdmin,
    this.initial = RelationChoice.child,
    super.key,
  });

  final String familyId;
  final TreePerson person;
  final TreeData tree;
  final bool isAdmin;
  final RelationChoice initial;

  @override
  ConsumerState<TreeRelationSheet> createState() => _TreeRelationSheetState();
}

class _TreeRelationSheetState extends ConsumerState<TreeRelationSheet> {
  late RelationChoice _choice = widget.initial;
  String? _otherId;
  bool _adoptive = false;
  bool _busy = false;
  String _query = '';

  Future<void> _newPerson() async {
    final created = await showPersonForm(context, familyId: widget.familyId);
    if (created != null && mounted) await _save(created.id);
  }

  Future<void> _save([String? otherId]) async {
    final l10n = context.l10n;
    final other = otherId ?? _otherId;
    if (other == null) return;
    setState(() => _busy = true);
    try {
      final me = widget.person.id;
      await ref
          .read(treeRepositoryProvider)
          .proposeRelation(
            id: newTreeId(),
            familyId: widget.familyId,
            kind: _choice == RelationChoice.spouse ? RelationKind.spouse : RelationKind.parent,
            personA: _choice == RelationChoice.parent ? other : me,
            personB: _choice == RelationChoice.parent ? me : other,
            adoptive: _choice != RelationChoice.spouse && _adoptive,
          );
      ref.invalidate(treeDataProvider(widget.familyId));
      if (!mounted) return;
      final saved = ref.read(treeDataProvider(widget.familyId)).value;
      final crossFamily = saved?.persons[other]?.familyId != widget.person.familyId;
      context.showMessage(
        widget.isAdmin && !crossFamily
            ? l10n.treeRelationAdded
            : crossFamily
            ? l10n.treeRelationCrossFamily
            : l10n.treeRelationProposed,
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final candidates =
        widget.tree.persons.values
            .where((p) => p.id != widget.person.id)
            .where((p) => _query.isEmpty || p.fullName.toLowerCase().contains(_query.toLowerCase()))
            .toList()
          ..sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.treeAddRelationFor(widget.person.fullName), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          SegmentedButton<RelationChoice>(
            segments: [
              ButtonSegment(value: RelationChoice.parent, label: Text(l10n.treeChoiceParent)),
              ButtonSegment(value: RelationChoice.child, label: Text(l10n.treeChoiceChild)),
              ButtonSegment(value: RelationChoice.spouse, label: Text(l10n.treeChoiceSpouse)),
            ],
            selected: {_choice},
            onSelectionChanged: (s) => setState(() => _choice = s.first),
          ),
          if (_choice != RelationChoice.spouse)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _adoptive,
              onChanged: (v) => setState(() => _adoptive = v ?? false),
              title: Text(l10n.treeAdoptive),
            ),
          TextField(
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: l10n.treeSearchPerson),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.35),
            child: RadioGroup<String>(
              groupValue: _otherId,
              onChanged: (v) => setState(() => _otherId = v),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in candidates)
                    RadioListTile<String>(
                      value: p.id,
                      title: Text(p.fullName),
                      subtitle: Text(
                        [
                          '${p.birthDate.year}${p.isDeceased ? ' – ${p.deathDate!.year}' : ''}',
                          if (p.familyId != widget.person.familyId) ?widget.tree.familyNames[p.familyId],
                        ].join(' · '),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (widget.isAdmin)
            TextButton.icon(
              onPressed: _busy ? null : _newPerson,
              icon: const Icon(Icons.person_add_alt),
              label: Text(l10n.treeNewPersonForRelation),
            ),
          if (!widget.isAdmin)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(l10n.treeProposalHint, style: Theme.of(context).textTheme.bodySmall),
            ),
          FilledButton(
            onPressed: _busy || _otherId == null ? null : _save,
            child: Text(widget.isAdmin ? l10n.treeAddRelation : l10n.treeProposeRelation),
          ),
        ],
      ),
    );
  }
}
