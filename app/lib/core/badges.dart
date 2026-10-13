// Monthly badges (app only). A goal month earns one when its spending
// stayed within its limit and the savings kept up with the plan. Badges are
// derived from the records, so both partners always see the same ones.

import 'budget.dart';

/// Badge level. The rules come in a later version; until then nobody has
/// a level and the badge page shows a placeholder.
class BadgeLevel {
  const BadgeLevel({required this.level, required this.name});

  final int level;
  final String name;
}

BadgeLevel? badgeLevel(List<Month> badges) => null;

/// [month] as it stood on its last day, i.e. the limit the couple saw then.
Snapshot monthEndSnapshot(Goal g, Iterable<BudgetEntry> entries, Month month) =>
    computeSnapshot(g, entries, month, DateTime(month.year, month.month, month.daysIn));

bool monthAchieved(Goal g, Iterable<BudgetEntry> entries, Month month) {
  if (!g.contains(month)) return false;
  final s = monthEndSnapshot(g, entries, month);
  return s.monthSpent <= s.monthLimit && s.saved >= s.expectedSaved;
}

/// Every finished goal month before [current] that earned a badge, newest
/// first.
List<Month> earnedBadges(Iterable<Goal> goals, Iterable<BudgetEntry> entries, Month current) {
  final list = entries.toList();
  final out = <Month>[];
  for (final g in goals) {
    for (var m = g.startMonth; m.index <= g.endMonth.index && m.index < current.index; m = m.add(1)) {
      if (monthAchieved(g, list, m)) out.add(m);
    }
  }
  return out..sort((a, b) => b.compareTo(a));
}
