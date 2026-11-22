import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/providers/session_controller.dart';
import '../data/auth_repository.dart';

/// Shared centred layout for unauthenticated screens.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({required this.title, required this.child, this.subtitle, this.showBack = false, super.key});

  final String title;
  final String? subtitle;
  final Widget child;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: showBack ? AppBar() : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!showBack) ...[
                    Icon(Icons.family_restroom_rounded, size: 64, color: theme.colorScheme.primary),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  Text(
                    title,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    textAlign: showBack ? TextAlign.start : TextAlign.center,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      textAlign: showBack ? TextAlign.start : TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PasswordField extends StatefulWidget {
  const PasswordField({
    required this.controller,
    required this.label,
    this.validator,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.autofillHints = const [AutofillHints.password],
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final FormFieldValidator<String>? validator;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String> autofillHints;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    obscureText: _obscure,
    validator: widget.validator,
    textInputAction: widget.textInputAction,
    onFieldSubmitted: widget.onSubmitted,
    autofillHints: widget.autofillHints,
    decoration: InputDecoration(
      labelText: widget.label,
      prefixIcon: const Icon(Icons.lock_outline),
      suffixIcon: IconButton(
        tooltip: widget.label,
        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    ),
  );
}

/// Mixin for screens with a submit button that shows progress and errors.
mixin SubmittingState<T extends StatefulWidget> on State<T> {
  bool submitting = false;

  Future<void> submit(Future<void> Function() action) async {
    if (submitting) return;
    setState(() => submitting = true);
    try {
      await action();
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }
}

class SubmitButton extends StatelessWidget {
  const SubmitButton({required this.label, required this.onPressed, required this.busy, super.key});

  final String label;
  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy ? null : onPressed,
    child: busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
        : Text(label),
  );
}

// ---------------------------------------------------------------------------

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> with SubmittingState {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _signIn() {
    if (!_form.currentState!.validate()) return;
    submit(() async {
      try {
        await ref.read(authRepositoryProvider).signIn(email: _email.text, password: _password.text);
      } on AppFailure catch (f) {
        // Unconfirmed account: send a fresh code and let the user enter it.
        if (f.kind != FailureKind.emailNotConfirmed || !mounted) rethrow;
        final email = _email.text.trim();
        context.showMessage(context.l10n.errorEmailNotConfirmed);
        await ref.read(authRepositoryProvider).resendSignupCode(email).catchError((_) {});
        if (mounted) unawaited(context.push(Routes.verifyCodeFor(email, recovery: false)));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AuthScaffold(
      title: l10n.authWelcomeTitle,
      subtitle: l10n.authWelcomeSubtitle,
      child: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('signIn.email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: l10n.fieldEmail, prefixIcon: const Icon(Icons.mail_outline)),
                validator: (v) => l10n.validation(Validators.email(v)),
              ),
              const SizedBox(height: AppSpacing.md),
              PasswordField(
                key: const Key('signIn.password'),
                controller: _password,
                label: l10n.fieldPassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _signIn(),
                validator: (v) => (v ?? '').isEmpty ? l10n.validationRequired : null,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.push(Routes.forgotPassword),
                  child: Text(l10n.forgotPassword),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SubmitButton(label: l10n.signIn, onPressed: _signIn, busy: submitting),
              const SizedBox(height: AppSpacing.md),
              TextButton(onPressed: () => context.go(Routes.signUp), child: Text(l10n.noAccount)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> with SubmittingState {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    for (final c in [_name, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  void _signUp() {
    if (!_form.currentState!.validate()) return;
    submit(() async {
      final outcome = await ref
          .read(authRepositoryProvider)
          .signUp(email: _email.text, password: _password.text, displayName: _name.text);
      if (outcome == SignUpOutcome.confirmationEmailSent && mounted) {
        context.go(Routes.verifyCodeFor(_email.text.trim(), recovery: false));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AuthScaffold(
      title: l10n.signUpTitle,
      subtitle: l10n.authWelcomeSubtitle,
      child: AutofillGroup(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.next,
                maxLength: 60,
                decoration: InputDecoration(
                  labelText: l10n.fieldDisplayName,
                  prefixIcon: const Icon(Icons.person_outline),
                ),
                validator: (v) => l10n.validation(Validators.displayName(v)),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: l10n.fieldEmail, prefixIcon: const Icon(Icons.mail_outline)),
                validator: (v) => l10n.validation(Validators.email(v)),
              ),
              const SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _password,
                label: l10n.fieldPassword,
                autofillHints: const [AutofillHints.newPassword],
                validator: (v) => l10n.validation(Validators.password(v)),
              ),
              const SizedBox(height: AppSpacing.md),
              PasswordField(
                controller: _confirm,
                label: l10n.fieldConfirmPassword,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _signUp(),
                validator: (v) => l10n.validation(Validators.confirmPassword(v, _password.text)),
              ),
              const SizedBox(height: AppSpacing.lg),
              SubmitButton(label: l10n.signUp, onPressed: _signUp, busy: submitting),
              const SizedBox(height: AppSpacing.md),
              TextButton(onPressed: () => context.go(Routes.signIn), child: Text(l10n.haveAccount)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> with SubmittingState {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _send() {
    if (!_form.currentState!.validate()) return;
    submit(() async {
      await ref.read(authRepositoryProvider).sendPasswordReset(_email.text);
      if (mounted) unawaited(context.push(Routes.verifyCodeFor(_email.text.trim(), recovery: true)));
    });
  }

  void _haveCode() {
    if (!_form.currentState!.validate()) return;
    context.push(Routes.verifyCodeFor(_email.text.trim(), recovery: true));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AuthScaffold(
      showBack: true,
      title: l10n.forgotPasswordTitle,
      subtitle: l10n.forgotPasswordBody,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(labelText: l10n.fieldEmail, prefixIcon: const Icon(Icons.mail_outline)),
              validator: (v) => l10n.validation(Validators.email(v)),
              onFieldSubmitted: (_) => _send(),
            ),
            const SizedBox(height: AppSpacing.lg),
            SubmitButton(label: l10n.sendResetCode, onPressed: _send, busy: submitting),
            const SizedBox(height: AppSpacing.sm),
            TextButton(onPressed: submitting ? null : _haveCode, child: Text(l10n.haveCodeAlready)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Shown after opening a recovery link (session status = passwordRecovery),
/// and reachable from Profile to change the password while signed in.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> with SubmittingState {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    submit(() async {
      await ref.read(authRepositoryProvider).updatePassword(_password.text);
      if (!mounted) return;
      context.showMessage(context.l10n.passwordUpdated);
      final recovering = ref.read(sessionControllerProvider).status == SessionStatus.passwordRecovery;
      if (recovering) {
        await ref.read(sessionControllerProvider.notifier).refresh();
      } else if (mounted && context.canPop()) {
        context.pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AuthScaffold(
      showBack: context.canPop(),
      title: l10n.newPasswordTitle,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PasswordField(
              controller: _password,
              label: l10n.fieldPassword,
              autofillHints: const [AutofillHints.newPassword],
              validator: (v) => l10n.validation(Validators.password(v)),
            ),
            const SizedBox(height: AppSpacing.md),
            PasswordField(
              controller: _confirm,
              label: l10n.fieldConfirmPassword,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              validator: (v) => l10n.validation(Validators.confirmPassword(v, _password.text)),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: AppSpacing.lg),
            SubmitButton(label: l10n.newPasswordSave, onPressed: _save, busy: submitting),
          ],
        ),
      ),
    );
  }
}
