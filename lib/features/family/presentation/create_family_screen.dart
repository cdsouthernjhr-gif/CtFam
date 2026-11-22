import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/providers/session_controller.dart';
import '../../authentication/presentation/auth_screens.dart';
import '../data/family_repository.dart';

class CreateFamilyScreen extends ConsumerStatefulWidget {
  const CreateFamilyScreen({super.key});

  @override
  ConsumerState<CreateFamilyScreen> createState() => _CreateFamilyScreenState();
}

class _CreateFamilyScreenState extends ConsumerState<CreateFamilyScreen> with SubmittingState {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _create() {
    if (!_form.currentState!.validate()) return;
    submit(() async {
      final id = await ref
          .read(familyRepositoryProvider)
          .createFamily(name: _name.text, description: _description.text.trim().isEmpty ? null : _description.text);
      final session = ref.read(sessionControllerProvider.notifier);
      await session.refresh();
      await session.switchFamily(id);
      if (!mounted) return;
      context.showMessage(context.l10n.familyCreated);
      context.go(Routes.home);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.createFamilyTitle)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              maxLength: 80,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: l10n.fieldFamilyName, hintText: l10n.fieldFamilyNameHint),
              validator: (v) => l10n.validation(Validators.familyName(v)),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _description,
              maxLength: 500,
              maxLines: 3,
              minLines: 2,
              decoration: InputDecoration(labelText: l10n.fieldDescription),
            ),
            const SizedBox(height: AppSpacing.lg),
            SubmitButton(label: l10n.createFamily, onPressed: _create, busy: submitting),
          ],
        ),
      ),
    );
  }
}
