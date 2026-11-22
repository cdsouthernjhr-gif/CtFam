import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/coming_soon.dart';

/// Phase 3 — private and group chat. Not implemented yet.
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      ComingSoonScreen(title: context.l10n.navChat, message: context.l10n.comingSoonChat, icon: Icons.forum_outlined);
}
