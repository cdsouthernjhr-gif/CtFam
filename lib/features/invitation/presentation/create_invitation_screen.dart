import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/invite_code.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../shared/providers/session_controller.dart';
import '../../authentication/presentation/auth_screens.dart';
import '../../family/presentation/family_providers.dart';
import '../data/invitation_repository.dart';
import '../domain/invitation_models.dart';

class CreateInvitationScreen extends ConsumerStatefulWidget {
  const CreateInvitationScreen({super.key});

  @override
  ConsumerState<CreateInvitationScreen> createState() => _CreateInvitationScreenState();
}

class _CreateInvitationScreenState extends ConsumerState<CreateInvitationScreen> with SubmittingState {
  static const _usesOptions = [1, 5, 10, 25, 50];
  static const _expiryOptions = [24, 72, 168, 720];

  final _note = TextEditingController();
  int _maxUses = 1;
  int _expiresInHours = 72;
  bool? _requiresApproval;
  CreatedInvitation? _created;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _create(String familyId) => submit(() async {
    final inv = await ref
        .read(invitationRepositoryProvider)
        .create(
          familyId: familyId,
          maxUses: _maxUses,
          expiresInHours: _expiresInHours,
          requiresApproval: _requiresApproval,
          note: _note.text.trim().isEmpty ? null : _note.text,
        );
    ref.invalidate(invitationsProvider(familyId));
    if (mounted) setState(() => _created = inv);
  });

  String _expiryLabel(int hours) {
    final l10n = context.l10n;
    return switch (hours) {
      24 => l10n.hours24,
      72 => l10n.days3,
      168 => l10n.days7,
      _ => l10n.days30,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final familyId = ref.watch(activeFamilyIdProvider);
    final family = familyId == null ? null : ref.watch(familyProvider(familyId)).value;
    final created = _created;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.inviteTitle)),
      body: familyId == null || family == null
          ? const Center(child: CircularProgressIndicator())
          : created != null
          ? _InvitationResult(invitation: created, familyName: family.name)
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                Text(l10n.inviteUses, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    for (final n in _usesOptions)
                      ChoiceChip(
                        label: Text(n == 1 ? l10n.inviteSingleUse : l10n.inviteMultiUse(n)),
                        selected: _maxUses == n,
                        onSelected: (_) => setState(() => _maxUses = n),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(l10n.inviteExpiry, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    for (final h in _expiryOptions)
                      ChoiceChip(
                        label: Text(_expiryLabel(h)),
                        selected: _expiresInHours == h,
                        onSelected: (_) => setState(() => _expiresInHours = h),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.inviteRequireApproval),
                  value: _requiresApproval ?? family.requireInviteApproval,
                  onChanged: (v) => setState(() => _requiresApproval = v),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _note,
                  maxLength: 120,
                  decoration: InputDecoration(labelText: l10n.inviteNote, hintText: l10n.inviteNoteHint),
                ),
                const SizedBox(height: AppSpacing.lg),
                SubmitButton(label: l10n.generateInvite, onPressed: () => _create(familyId), busy: submitting),
              ],
            ),
    );
  }
}

class _InvitationResult extends StatelessWidget {
  const _InvitationResult({required this.invitation, required this.familyName});

  final CreatedInvitation invitation;
  final String familyName;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final link = AppConfig.inviteLink(invitation.code).toString();
    final display = InviteCode.format(invitation.code);
    final expires = context.formatDateTime(invitation.expiresAt);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(l10n.inviteReadyTitle, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.sm),
        Text(l10n.inviteReadyBody, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: QrImageView(
              data: link,
              size: 220,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: AppColors.navy),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: AppColors.navy,
              ),
              semanticsLabel: l10n.inviteScanHint,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(l10n.inviteScanHint, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpacing.lg),
        Card(
          child: ListTile(
            title: SelectableText(
              display,
              style: theme.textTheme.titleLarge?.copyWith(fontFamily: 'monospace', letterSpacing: 1.5),
            ),
            subtitle: Text(l10n.inviteExpiresOn(expires)),
            trailing: IconButton(
              tooltip: l10n.actionCopy,
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: display));
                if (context.mounted) context.showMessage(l10n.copied);
              },
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton.icon(
          icon: const Icon(Icons.share),
          label: Text(l10n.actionShare),
          onPressed: () =>
              SharePlus.instance.share(ShareParams(text: l10n.inviteShareText(familyName, display, link, expires))),
        ),
      ],
    );
  }
}
