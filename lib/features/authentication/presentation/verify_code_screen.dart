import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../data/auth_repository.dart';
import 'auth_screens.dart';

/// Validates an emailed one-time code: digits only, 6–10 long (the length is
/// a project setting in Supabase Auth).
bool isPlausibleOtp(String value) => RegExp(r'^\d{6,10}$').hasMatch(value.trim());

/// Code-based verification for sign-up confirmation and password reset.
///
/// Using the code typed into the app (instead of the link in the email) keeps
/// the whole flow inside FamilySync and does not depend on deep links or the
/// project's Site URL.
class VerifyCodeScreen extends ConsumerStatefulWidget {
  const VerifyCodeScreen({required this.email, required this.recovery, super.key});

  final String email;

  /// true = password reset, false = sign-up confirmation.
  final bool recovery;

  @override
  ConsumerState<VerifyCodeScreen> createState() => _VerifyCodeScreenState();
}

class _VerifyCodeScreenState extends ConsumerState<VerifyCodeScreen> with SubmittingState {
  static const _cooldown = 60;
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  Timer? _timer;
  int _secondsLeft = _cooldown;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _secondsLeft = _cooldown);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) t.cancel();
    });
  }

  void _verify() {
    if (!_form.currentState!.validate()) return;
    final repo = ref.read(authRepositoryProvider);
    submit(() async {
      if (widget.recovery) {
        // Session status becomes passwordRecovery → router opens "new password".
        await repo.verifyRecoveryCode(email: widget.email, code: _code.text);
      } else {
        await repo.verifySignupCode(email: widget.email, code: _code.text);
        if (mounted) context.showMessage(context.l10n.emailVerified);
      }
    });
  }

  void _resend() {
    final repo = ref.read(authRepositoryProvider);
    submit(() async {
      if (widget.recovery) {
        await repo.sendPasswordReset(widget.email);
      } else {
        await repo.resendSignupCode(widget.email);
      }
      if (!mounted) return;
      context.showMessage(context.l10n.codeResent);
      _startCooldown();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return AuthScaffold(
      showBack: true,
      title: l10n.enterCodeTitle,
      subtitle: l10n.enterCodeBody(widget.email),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('verify.code'),
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
              style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 6, fontWeight: FontWeight.w600),
              decoration: InputDecoration(labelText: l10n.fieldCode, counterText: ''),
              validator: (v) => isPlausibleOtp(v ?? '') ? null : l10n.validationCode,
              onFieldSubmitted: (_) => _verify(),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.codeEmailHint,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            SubmitButton(label: l10n.verifyCodeButton, onPressed: _verify, busy: submitting),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: submitting || _secondsLeft > 0 ? null : _resend,
              child: Text(_secondsLeft > 0 ? l10n.resendIn(_secondsLeft) : l10n.resendCode),
            ),
          ],
        ),
      ),
    );
  }
}
