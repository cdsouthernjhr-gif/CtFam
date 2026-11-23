import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/chat_repository.dart';
import 'chat_providers.dart';

/// Pick a member for a private chat, or create a group. Returns the
/// conversation id to open.
Future<String?> showNewChatSheet(BuildContext context, {required String familyId}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => _NewChatSheet(familyId: familyId),
);

class _NewChatSheet extends ConsumerStatefulWidget {
  const _NewChatSheet({required this.familyId});

  final String familyId;

  @override
  ConsumerState<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends ConsumerState<_NewChatSheet> {
  bool _group = false;
  bool _busy = false;
  final _name = TextEditingController();
  final Set<String> _selected = {};
  final _groupId = newChatId(); // stable across retries (idempotent create)

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    try {
      final id = await action();
      ref.invalidate(conversationSummariesProvider(widget.familyId));
      nav.pop(id);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final me = ref.watch(currentUserIdProvider);
    final repo = ref.read(chatRepositoryProvider);
    final members = (ref.watch(familyMembersProvider(widget.familyId)).value ?? const <FamilyMember>[])
        .where((m) => m.status == MemberStatus.active && m.userId != me)
        .toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, scroll) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, icon: const Icon(Icons.person_outline), label: Text(l10n.privateChat)),
                  ButtonSegment(value: true, icon: const Icon(Icons.groups_outlined), label: Text(l10n.newGroup)),
                ],
                selected: {_group},
                onSelectionChanged: (s) => setState(() => _group = s.first),
              ),
            ),
            if (_group)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
                child: TextField(
                  key: const Key('newGroup.name'),
                  controller: _name,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: l10n.groupName, hintText: l10n.groupNameHint),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: members.isEmpty
                  ? Center(child: Text(l10n.noOtherMembers))
                  : ListView.builder(
                      controller: scroll,
                      itemCount: members.length,
                      itemBuilder: (_, i) {
                        final m = members[i];
                        final avatar = StorageAvatar(initials: m.profile?.initials ?? '?', path: m.profile?.avatarPath);
                        if (_group) {
                          return CheckboxListTile(
                            value: _selected.contains(m.userId),
                            secondary: avatar,
                            title: Text(m.displayName),
                            onChanged: (v) =>
                                setState(() => v == true ? _selected.add(m.userId) : _selected.remove(m.userId)),
                          );
                        }
                        return ListTile(
                          leading: avatar,
                          title: Text(m.displayName),
                          enabled: !_busy,
                          onTap: () => _run(() => repo.openDirect(widget.familyId, m.userId)),
                        );
                      },
                    ),
            ),
            if (_group)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: FilledButton(
                    key: const Key('newGroup.create'),
                    onPressed: _busy || _name.text.trim().isEmpty || _selected.isEmpty
                        ? null
                        : () => _run(
                            () => repo.createGroup(
                              id: _groupId,
                              familyId: widget.familyId,
                              name: _name.text,
                              memberIds: _selected.toList(),
                            ),
                          ),
                    child: Text(l10n.createGroupWithCount(_selected.length)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
