import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../domain/todo_models.dart';

IconData categoryIcon(TodoCategory c) => switch (c) {
  TodoCategory.shopping => Icons.shopping_bag_outlined,
  TodoCategory.grocery => Icons.local_grocery_store_outlined,
  TodoCategory.household => Icons.home_repair_service_outlined,
  TodoCategory.school => Icons.school_outlined,
  TodoCategory.familyActivities => Icons.celebration_outlined,
  TodoCategory.bills => Icons.receipt_long_outlined,
  TodoCategory.travel => Icons.flight_takeoff_outlined,
  TodoCategory.personal => Icons.person_outline,
  TodoCategory.custom => Icons.label_outline,
};

String categoryLabel(AppLocalizations l, TodoCategory c) => switch (c) {
  TodoCategory.shopping => l.catShopping,
  TodoCategory.grocery => l.catGrocery,
  TodoCategory.household => l.catHousehold,
  TodoCategory.school => l.catSchool,
  TodoCategory.familyActivities => l.catFamilyActivities,
  TodoCategory.bills => l.catBills,
  TodoCategory.travel => l.catTravel,
  TodoCategory.personal => l.catPersonal,
  TodoCategory.custom => l.catCustom,
};

String priorityLabel(AppLocalizations l, TodoPriority p) => switch (p) {
  TodoPriority.low => l.priorityLow,
  TodoPriority.normal => l.priorityNormal,
  TodoPriority.high => l.priorityHigh,
  TodoPriority.urgent => l.priorityUrgent,
};

Color? priorityColor(ColorScheme s, TodoPriority p) => switch (p) {
  TodoPriority.urgent => s.error,
  TodoPriority.high => const Color(0xFFE08A00),
  TodoPriority.low => s.outline,
  TodoPriority.normal => null,
};

String recurrenceLabel(AppLocalizations l, TodoRecurrence r) => switch (r) {
  TodoRecurrence.none => l.repeatNone,
  TodoRecurrence.daily => l.repeatDaily,
  TodoRecurrence.weekly => l.repeatWeekly,
  TodoRecurrence.monthly => l.repeatMonthly,
  TodoRecurrence.yearly => l.repeatYearly,
};

/// "Hari ini 17:00", "Esok", "12 Dis" …
String dueLabel(AppLocalizations l, DateTime due, DateTime now) {
  final d = DateTime(due.year, due.month, due.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = d.difference(today).inDays;
  final hasTime = due.hour != 0 || due.minute != 0;
  final time = hasTime ? ' ${DateFormat.Hm(l.localeName).format(due)}' : '';
  if (diff == 0) return '${l.dueToday}$time';
  if (diff == 1) return '${l.dueTomorrow}$time';
  if (diff == -1) return '${l.dueYesterday}$time';
  return '${DateFormat.MMMd(l.localeName).format(due)}$time';
}
