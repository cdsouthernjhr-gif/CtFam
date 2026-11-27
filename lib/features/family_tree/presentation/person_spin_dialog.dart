import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../shared/providers/session_controller.dart';
import '../data/tree_repository.dart';
import '../domain/tree_models.dart';
import 'birthday_tile.dart';
import 'person_screen.dart';
import 'tree_photo.dart';
import 'tree_providers.dart';

/// Opens the spinning 3D photo card for [person].
Future<void> showPersonSpin(BuildContext context, TreeData tree, TreePerson person) => showDialog<void>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.7),
  builder: (_) => PersonSpinDialog(tree: tree, person: person),
);

/// A photo card turning in 3D. Tap: it slows down, stops facing you and the
/// person's details appear. Tap the card again to spin again.
/// With "remove animations" on it does not spin and shows the details at once.
class PersonSpinDialog extends ConsumerStatefulWidget {
  const PersonSpinDialog({required this.tree, required this.person, super.key});

  final TreeData tree;
  final TreePerson person;

  static const turn = Duration(milliseconds: 3600);

  @override
  ConsumerState<PersonSpinDialog> createState() => _PersonSpinDialogState();
}

class _PersonSpinDialogState extends ConsumerState<PersonSpinDialog> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: PersonSpinDialog.turn);
  var _stopped = false;
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _stopped = true;
    } else {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (MediaQuery.of(context).disableAnimations) return;
    if (_stopped) {
      setState(() => _stopped = false);
      _spin.repeat();
      return;
    }
    setState(() => _stopped = true);
    // Ease to the front (the end of the current turn).
    final left = 1 - _spin.value;
    await _spin.animateTo(1, duration: PersonSpinDialog.turn * (0.35 + left * 0.6), curve: Curves.easeOutCubic);
    if (mounted && _stopped) _spin.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final size = MediaQuery.sizeOf(context);
    final cardW = math.min(240.0, size.width * 0.62);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(AppSpacing.md),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: const ValueKey('spin-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Semantics(
              button: true,
              label: _stopped ? l10n.treeSpinResume : l10n.treeSpinStop,
              child: GestureDetector(
                key: const ValueKey('spin-card'),
                onTap: _toggle,
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (context, _) {
                    final angle = _spin.value * 2 * math.pi;
                    final back = angle > math.pi / 2 && angle < 3 * math.pi / 2;
                    return Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0014)
                        ..rotateY(angle),
                      child: back
                          ? Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.rotationY(math.pi), // keep the back readable
                              child: _Back(person: widget.person, width: cardW),
                            )
                          : _Front(person: widget.person, width: cardW),
                    );
                  },
                ),
              ),
            ),
            if (!MediaQuery.of(context).disableAnimations) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _stopped ? l10n.treeSpinResume : l10n.treeSpinStop,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: _stopped
                  ? Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: _Details(tree: widget.tree, person: widget.person),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class _Front extends StatelessWidget {
  const _Front({required this.person, required this.width});

  final TreePerson person;
  final double width;

  @override
  Widget build(BuildContext context) {
    final accent = person.gender == Gender.male ? Colors.blue : Colors.pink;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: width * 1.3,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white, width: 4),
        boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 24, spreadRadius: 2)],
        color: scheme.surfaceContainerHighest,
      ),
      clipBehavior: Clip.antiAlias,
      child: person.photoPath != null
          ? TreeImage(path: person.photoPath!)
          : Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [accent.shade200, accent.shade600],
                ),
              ),
              child: Text(
                person.initials,
                style: TextStyle(fontSize: width * 0.33, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ),
    );
  }
}

class _Back extends StatelessWidget {
  const _Back({required this.person, required this.width});

  final TreePerson person;
  final double width;

  @override
  Widget build(BuildContext context) {
    final accent = person.gender == Gender.male ? Colors.blue : Colors.pink;
    final years = person.isDeceased
        ? '${person.birthDate.year} – ${person.deathDate!.year}'
        : '${person.birthDate.year}';
    return Container(
      width: width,
      height: width * 1.3,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white, width: 4),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.shade700, accent.shade900],
        ),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.account_tree, color: Colors.white70, size: 32),
          const SizedBox(height: AppSpacing.sm),
          Text(
            person.fullName,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(years, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _Details extends ConsumerWidget {
  const _Details({required this.tree, required this.person});

  final TreeData tree;
  final TreePerson person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final familyId = ref.watch(activeFamilyIdProvider);
    final me = ref.watch(currentUserIdProvider);
    final isMe = person.userId != null && person.userId == me;
    final rel = isMe || familyId == null
        ? null
        : ref.watch(relationshipProvider((familyId: familyId, personId: person.id)));
    final now = DateTime.now();
    final relText = isMe
        ? l10n.treeThisIsYou
        : rel == null || rel.isLoading
        ? '…'
        : rel.hasError
        ? context.errorText(rel.error!)
        : switch (rel.requireValue.kind) {
            'none' => l10n.treeNoRelation,
            'no_profile' => l10n.treeNeedOwnProfile,
            _ => relationshipText(l10n, tree, rel.requireValue) ?? l10n.treeNoRelation,
          };
    String names(List<TreePerson> list) => list.map((p) => p.fullName).join(', ');
    final today = DateTime(now.year, now.month, now.day);
    final thisYear = birthdayIn(person.birthDate, now.year);
    final next = person.isDeceased
        ? null
        : thisYear.isBefore(today)
        ? birthdayIn(person.birthDate, now.year + 1)
        : thisYear;
    final rows = <(IconData, String, String)>[
      (Icons.cake_outlined, context.formatDate(person.birthDate), ''),
      if (next != null)
        (
          Icons.celebration_outlined,
          switch (daysUntil(now, next)) {
            0 => l10n.birthdayToday(person.ageOn(next)),
            1 => l10n.birthdayTomorrow(context.formatDate(next), person.ageOn(next)),
            final d => l10n.birthdayInDays(d, context.formatDate(next), person.ageOn(next)),
          },
          '',
        ),
      if (tree.parentsOf(person.id).isNotEmpty) (Icons.north, l10n.treeParents, names(tree.parentsOf(person.id))),
      if (tree.spousesOf(person.id).isNotEmpty)
        (Icons.favorite_outline, l10n.treeSpouses, names(tree.spousesOf(person.id))),
      if (tree.childrenOf(person.id).isNotEmpty) (Icons.south, l10n.treeChildren, names(tree.childrenOf(person.id))),
    ];
    return Card(
      key: const ValueKey('spin-details'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                StorageAvatar(
                  radius: 20,
                  bucket: TreeRepository.photoBucket,
                  path: person.photoPath,
                  initials: person.initials,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(person.fullName, style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        person.isDeceased
                            ? l10n.treeDeceasedLabel(
                                person.gender == Gender.male ? l10n.treeLateMale : l10n.treeLateFemale,
                              )
                            : l10n.treeAge(person.ageOn(now)),
                        style: TextStyle(color: scheme.outline),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  Icon(Icons.diversity_3_outlined, size: 18, color: scheme.onPrimaryContainer),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      relText,
                      style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            for (final (icon, title, value) in rows)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18, color: scheme.outline),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: title,
                              style: value.isEmpty ? null : const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (value.isNotEmpty) TextSpan(text: ': $value'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              key: const ValueKey('spin-open-profile'),
              icon: const Icon(Icons.person_outline),
              label: Text(l10n.treeOpenProfile),
              onPressed: () {
                final router = GoRouter.of(context);
                Navigator.of(context).pop();
                router.push(Routes.treePerson(person.id));
              },
            ),
          ],
        ),
      ),
    );
  }
}
