import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/state_views.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/providers/session_controller.dart';
import '../domain/family_models.dart';
import 'family_providers.dart';

String activityText(AppLocalizations l10n, ActivityEntry e) {
  final actor = (e.actorName?.trim().isNotEmpty ?? false) ? e.actorName! : l10n.someone;
  return switch (e.action) {
    'family.created' => l10n.activityFamilyCreated(actor),
    'family.deleted' => l10n.activityFamilyDeleted(actor),
    'family.ownership_transferred' => l10n.activityOwnershipTransferred(actor),
    'member.joined' => l10n.activityMemberJoined(actor),
    'member.requested' => l10n.activityMemberRequested(actor),
    'member.approved' => l10n.activityMemberApproved(actor),
    'member.rejected' => l10n.activityMemberRejected(actor),
    'member.role_changed' => l10n.activityRoleChanged(actor),
    'member.left' => l10n.activityMemberLeft(actor),
    'member.removed' => l10n.activityMemberRemoved(actor),
    'member.suspended' => l10n.activityMemberSuspended(actor),
    'member.active' => l10n.activityMemberReactivated(actor),
    'invitation.created' => l10n.activityInvitationCreated(actor),
    'invitation.revoked' => l10n.activityInvitationRevoked(actor),
    'family.announcement' => l10n.activityAnnouncement(actor, (e.details['title'] as String?) ?? ''),
    'event.created' => l10n.activityEventCreated(actor, (e.details['title'] as String?) ?? ''),
    'event.updated' => l10n.activityEventUpdated(actor, (e.details['title'] as String?) ?? ''),
    'event.deleted' => l10n.activityEventDeleted(actor, (e.details['title'] as String?) ?? ''),
    'tree.person_added' => l10n.activityTreePersonAdded(actor, (e.details['name'] as String?) ?? ''),
    'tree.person_removed' => l10n.activityTreePersonRemoved(actor, (e.details['name'] as String?) ?? ''),
    _ => l10n.activityGeneric(actor, e.action),
  };
}

IconData _iconFor(String action) => action == 'family.announcement'
    ? Icons.campaign_outlined
    : switch (action.split('.').first) {
        'invitation' => Icons.mail_outline,
        'family' => Icons.home_outlined,
        'event' => Icons.event_outlined,
        'tree' => Icons.account_tree_outlined,
        _ => Icons.person_outline,
      };

class ActivityTile extends StatelessWidget {
  const ActivityTile({required this.entry, super.key});

  final ActivityEntry entry;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(_iconFor(entry.action)),
    title: Text(activityText(context.l10n, entry)),
    subtitle: Text(context.formatDateTime(entry.createdAt)),
  );
}

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final familyId = ref.watch(activeFamilyIdProvider);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.activityTitle)),
      body: familyId == null
          ? const LoadingView()
          : AsyncValueView(
              value: ref.watch(familyActivityProvider(familyId)),
              onRetry: () => ref.invalidate(familyActivityProvider(familyId)),
              data: (entries) => entries.isEmpty
                  ? MessageView(icon: Icons.history, title: l10n.dashboardNoActivity)
                  : RefreshIndicator(
                      onRefresh: () async => ref.refresh(familyActivityProvider(familyId).future),
                      child: ListView.separated(
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) => ActivityTile(entry: entries[i]),
                      ),
                    ),
            ),
    );
  }
}
