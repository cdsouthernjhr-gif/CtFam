import 'package:material_ui/material_ui.dart';

import '../utils/l10n_ext.dart';
import 'state_views.dart';

/// Honest placeholder for modules scheduled in later phases.
class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({required this.title, required this.message, required this.icon, super.key});

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: MessageView(icon: icon, title: context.l10n.comingSoonTitle, message: message),
  );
}
