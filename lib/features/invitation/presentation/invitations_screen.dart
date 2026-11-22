import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../shared/providers/session_controller.dart';
import '../../family/presentation/family_providers.dart';
import '../data/invitation_repository.dart';
import '../domain/invitation_models.dart';

class InvitationsScreen extends ConsumerWidget {
  const InvitationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final familyId = ref.watch(activeFamilyIdProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.invitationsTitle)),
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.generateInvite,
        onPressed: () => context.push(Routes.invite),
        child: const Icon(Icons.add),
      ),
      body: familyId == null
          ? const LoadingView()
          : AsyncValueView(
              value: ref.watch(invitationsProvider(familyId)),
              onRetry: () => ref.invalidate(invitationsProvider(familyId)),
              data: (list) => list.isEmpty
                  ? MessageView(icon: Icons.mail_outline, title: l10n.invitationsEmpty)
                  : RefreshIndicator(
                      onRefresh: () async => ref.refresh(invitationsProvider(familyId).future),
                      child: ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) => _InvitationTile(invitation: list[i], familyId: familyId),
                      ),
                    ),
            ),
    );
  }
}

class _InvitationTile extends ConsumerWidget {
  const _InvitationTile({required this.invitation, required this.familyId});

  final Invitation invitation;
  final String familyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final state = invitation.stateAt(DateTime.now());
    final (label, color) = switch (state) {
      InvitationState.active => (l10n.invitationActive, scheme.secondary),
      InvitationState.expired => (l10n.invitationExpired, scheme.outline),
      InvitationState.exhausted => (l10n.invitationExhausted, scheme.outline),
      InvitationState.revoked => (l10n.invitationRevoked, scheme.error),
    };
    final subtitle = [
      l10n.invitationUsage(invitation.useCount, invitation.maxUses),
      l10n.inviteExpiresOn(context.formatDateTime(invitation.expiresAt)),
      if (invitation.note != null) invitation.note!,
    ].join(' · ');

    return ListTile(
      leading: Icon(Icons.confirmation_number_outlined, color: color),
      title: Text(l10n.invitationEnding(invitation.tokenHint)),
      subtitle: Text(subtitle),
      trailing: state == InvitationState.active
          ? TextButton(
              onPressed: () async {
                final ok = await confirmDialog(
                  context,
                  title: l10n.confirmRevokeTitle,
                  message: l10n.confirmRevokeBody,
                  destructive: true,
                );
                if (!ok) return;
                try {
                  await ref.read(invitationRepositoryProvider).revoke(invitation.id);
                  ref.invalidate(invitationsProvider(familyId));
                } catch (e) {
                  if (context.mounted) context.showError(e);
                }
              },
              child: Text(l10n.revoke),
            )
          : Text(label, style: TextStyle(color: color)),
    );
  }
}
