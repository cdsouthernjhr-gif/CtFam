import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/widgets/coming_soon.dart';

/// Phase 5 — family calendar. Not implemented yet.
class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) => ComingSoonScreen(
    title: context.l10n.navCalendar,
    message: context.l10n.comingSoonCalendar,
    icon: Icons.event_note_outlined,
  );
}
