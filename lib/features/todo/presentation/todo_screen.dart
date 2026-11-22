import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/coming_soon.dart';

/// Phase 2 — real-time shared to-do lists. Not implemented yet.
class TodoScreen extends StatelessWidget {
  const TodoScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      ComingSoonScreen(title: context.l10n.navTodo, message: context.l10n.comingSoonTodo, icon: Icons.task_alt_rounded);
}
