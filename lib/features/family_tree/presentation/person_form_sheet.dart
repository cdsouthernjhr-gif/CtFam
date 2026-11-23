import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../data/tree_repository.dart';
import '../domain/tree_models.dart';
import 'tree_providers.dart';

/// Create or edit a person. [linkSelf] creates the signed-in member's own
/// record. Returns the saved person.
Future<TreePerson?> showPersonForm(
  BuildContext context, {
  required String familyId,
  TreePerson? person,
  bool linkSelf = false,
  String? initialName,
}) => showModalBottomSheet<TreePerson>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => PersonFormSheet(familyId: familyId, person: person, linkSelf: linkSelf, initialName: initialName),
);

class PersonFormSheet extends ConsumerStatefulWidget {
  const PersonFormSheet({required this.familyId, this.person, this.linkSelf = false, this.initialName, super.key});

  final String familyId;
  final TreePerson? person;
  final bool linkSelf;
  final String? initialName;

  @override
  ConsumerState<PersonFormSheet> createState() => _PersonFormSheetState();
}

class _PersonFormSheetState extends ConsumerState<PersonFormSheet> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.person?.fullName ?? widget.initialName ?? '');
  late final _notes = TextEditingController(text: widget.person?.notes ?? '');
  late Gender _gender = widget.person?.gender ?? Gender.male;
  late DateTime? _birth = widget.person?.birthDate;
  late DateTime? _death = widget.person?.deathDate;
  late bool _deceased = widget.person?.isDeceased ?? false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime? initial, {DateTime? first}) => showDatePicker(
    context: context,
    initialDate: initial ?? DateTime(DateTime.now().year - 30),
    firstDate: first ?? DateTime(1800),
    lastDate: DateTime.now(),
    initialEntryMode: DatePickerEntryMode.calendarOnly,
  );

  Future<void> _save() async {
    final l10n = context.l10n;
    if (!_form.currentState!.validate()) return;
    if (_birth == null) {
      context.showMessage(l10n.treeBirthRequired, error: true);
      return;
    }
    if (_deceased && _death != null && _death!.isBefore(_birth!)) {
      context.showMessage(l10n.treeDeathBeforeBirth, error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final saved = await ref
          .read(treeRepositoryProvider)
          .upsertPerson(
            id: widget.person?.id ?? newTreeId(),
            familyId: widget.familyId,
            fullName: _name.text,
            gender: _gender,
            birthDate: _birth!,
            deathDate: _deceased ? _death : null,
            notes: _notes.text.trim().isEmpty ? null : _notes.text,
            linkSelf: widget.linkSelf,
            expectedRevision: widget.person?.revision,
          );
      ref.invalidate(treeDataProvider(widget.familyId));
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.md,
      ),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.linkSelf
                    ? l10n.treeMyProfile
                    : widget.person == null
                    ? l10n.treeAddPerson
                    : l10n.treeEditPerson,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _name,
                maxLength: 100,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: l10n.treeFullName),
                validator: (v) => (v ?? '').trim().isEmpty ? l10n.validationRequired : null,
              ),
              SegmentedButton<Gender>(
                segments: [
                  ButtonSegment(value: Gender.male, label: Text(l10n.treeMale), icon: const Icon(Icons.male)),
                  ButtonSegment(value: Gender.female, label: Text(l10n.treeFemale), icon: const Icon(Icons.female)),
                ],
                selected: {_gender},
                onSelectionChanged: (s) => setState(() => _gender = s.first),
              ),
              const SizedBox(height: AppSpacing.sm),
              ListTile(
                key: const Key('tree.birth'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cake_outlined),
                title: Text(l10n.treeBirthDate),
                subtitle: Text(_birth == null ? l10n.treeRequired : context.formatDate(_birth!)),
                onTap: () async {
                  final d = await _pick(_birth);
                  if (d != null) setState(() => _birth = d);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.treeDeceased),
                value: _deceased,
                onChanged: widget.linkSelf ? null : (v) => setState(() => _deceased = v),
              ),
              if (_deceased)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: Text(l10n.treeDeathDate),
                  subtitle: Text(_death == null ? l10n.treeUnknown : context.formatDate(_death!)),
                  onTap: () async {
                    final d = await _pick(_death ?? DateTime.now(), first: _birth);
                    if (d != null) setState(() => _death = d);
                  },
                ),
              TextFormField(
                controller: _notes,
                maxLength: 500,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(labelText: l10n.treeNotes),
              ),
              const SizedBox(height: AppSpacing.sm),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n.actionSave),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
