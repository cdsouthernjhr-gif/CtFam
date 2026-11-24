import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../domain/tree_models.dart';

/// Days from [today] (date only) to [birthday].
int daysUntil(DateTime today, DateTime birthday) => DateTime(
  birthday.year,
  birthday.month,
  birthday.day,
).difference(DateTime(today.year, today.month, today.day)).inDays;

/// Birthdays this close (or closer) blink on the dashboard.
const birthdayBlinkDays = 7;

/// One upcoming birthday. Within [birthdayBlinkDays] days it pulses (a soft
/// highlight behind the row and the cake icon) and shows a countdown.
/// With "reduce motion" on, it is highlighted without animating.
class BirthdayTile extends StatelessWidget {
  const BirthdayTile({required this.person, required this.birthday, required this.today, this.onTap, super.key});

  final TreePerson person;
  final DateTime birthday;
  final DateTime today;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final days = daysUntil(today, birthday);
    final age = person.ageOn(birthday);
    final date = context.formatDate(birthday);
    final subtitle = switch (days) {
      0 => l10n.birthdayToday(age),
      1 => l10n.birthdayTomorrow(date, age),
      <= birthdayBlinkDays => l10n.birthdayInDays(days, date, age),
      _ => l10n.birthdayOn(date, age),
    };
    final tile = ListTile(
      leading: const Icon(Icons.cake_outlined),
      title: Text(
        person.fullName,
        style: days <= birthdayBlinkDays ? const TextStyle(fontWeight: FontWeight.w700) : null,
      ),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
    if (days > birthdayBlinkDays) return tile;
    return BirthdayBlink(key: ValueKey('blink-${person.id}'), today: days == 0, child: tile);
  }
}

/// Pulsing highlight. Faster on the day itself.
class BirthdayBlink extends StatefulWidget {
  const BirthdayBlink({required this.child, this.today = false, super.key});

  final Widget child;
  final bool today;

  @override
  State<BirthdayBlink> createState() => _BirthdayBlinkState();
}

class _BirthdayBlinkState extends State<BirthdayBlink> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.today ? 700 : 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the system "reduce motion / remove animations" setting.
    if (MediaQuery.of(context).disableAnimations) {
      _ctrl
        ..stop()
        ..value = 1;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = widget.today ? scheme.tertiaryContainer : scheme.primaryContainer;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Color.lerp(base.withValues(alpha: 0.15), base, t),
            borderRadius: BorderRadius.circular(12),
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: Color.lerp(scheme.outline, scheme.primary, t), size: 24 + 4 * t),
            child: child!,
          ),
        );
      },
      child: widget.child,
    );
  }
}
