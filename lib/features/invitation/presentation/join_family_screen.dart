import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/invite_code.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/providers/session_controller.dart';
import '../../authentication/presentation/auth_screens.dart';
import '../data/invitation_repository.dart';
import '../domain/invitation_models.dart';

String redeemMessage(AppLocalizations l10n, RedeemStatus s) => switch (s) {
  RedeemStatus.joined => l10n.redeemJoined,
  RedeemStatus.pendingApproval => l10n.redeemPending,
  RedeemStatus.alreadyMember => l10n.redeemAlready,
  RedeemStatus.invalid => l10n.redeemInvalid,
  RedeemStatus.expired => l10n.redeemExpired,
  RedeemStatus.exhausted => l10n.redeemExhausted,
  RedeemStatus.revoked => l10n.redeemRevoked,
  RedeemStatus.suspended => l10n.redeemSuspended,
  RedeemStatus.familyFull => l10n.redeemFamilyFull,
  RedeemStatus.rateLimited => l10n.redeemRateLimited,
};

class JoinFamilyScreen extends ConsumerStatefulWidget {
  const JoinFamilyScreen({this.initialCode, super.key});

  final String? initialCode;

  @override
  ConsumerState<JoinFamilyScreen> createState() => _JoinFamilyScreenState();
}

class _JoinFamilyScreenState extends ConsumerState<JoinFamilyScreen> with SubmittingState {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(
    text: widget.initialCode == null ? '' : InviteCode.format(widget.initialCode!),
  );
  InvitationPreview? _preview;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    // The deep-link code has been consumed into this screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(sessionControllerProvider.notifier).clearPendingInvite();
      if (widget.initialCode != null && InviteCode.isWellFormed(widget.initialCode!)) _check();
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String? get _normalized => InviteCode.extract(_code.text);

  void _check() {
    if (!_form.currentState!.validate()) return;
    submit(() async {
      final preview = await ref.read(invitationRepositoryProvider).preview(_normalized!);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _checked = true;
      });
    });
  }

  void _join() => submit(() async {
    final result = await ref.read(invitationRepositoryProvider).redeem(_normalized!);
    if (!mounted) return;
    final l10n = context.l10n;
    context.showMessage(redeemMessage(l10n, result.status), error: !result.status.isSuccess);
    if (!result.status.isSuccess) return;
    final session = ref.read(sessionControllerProvider.notifier);
    await session.refresh();
    if (result.status != RedeemStatus.pendingApproval && result.familyId != null) {
      await session.switchFamily(result.familyId!);
    }
    if (mounted) context.go(Routes.home);
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.joinTitle)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(l10n.joinBody),
            const SizedBox(height: AppSpacing.lg),
            TextFormField(
              key: const Key('join.code'),
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.2),
              decoration: InputDecoration(
                labelText: l10n.fieldInviteCode,
                hintText: 'XXXX-XXXX-XXXX-XXXX',
                prefixIcon: const Icon(Icons.vpn_key_outlined),
              ),
              onChanged: (_) {
                if (!_checked) return;
                setState(() {
                  _checked = false;
                  _preview = null;
                });
              },
              validator: (v) => InviteCode.extract(v ?? '') == null ? l10n.validationInviteCode : null,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_checked && preview == null)
              Card(
                child: ListTile(
                  leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
                  title: Text(l10n.redeemInvalid),
                ),
              ),
            if (preview != null) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.family_restroom_rounded, size: 36),
                  title: Text(preview.familyName, style: Theme.of(context).textTheme.titleMedium),
                  subtitle: Text(
                    [
                      l10n.memberCountLabel(preview.memberCount),
                      if (preview.requiresApproval) l10n.joinRequiresApproval,
                    ].join('\n'),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              SubmitButton(label: l10n.joinFamilyNamed(preview.familyName), onPressed: _join, busy: submitting),
            ] else
              SubmitButton(label: l10n.checkCode, onPressed: _check, busy: submitting),
          ],
        ),
      ),
    );
  }
}
