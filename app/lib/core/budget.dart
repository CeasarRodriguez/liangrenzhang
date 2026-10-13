// Savings-goal math. Mirrors server/internal/budget (Go); both are tested
// against shared/budget_cases.json, so keep them in sync.

const typeIncome = 'income';
const typeExpense = 'expense';

const levelMonth80 = 'month_80';
const levelMonth100 = 'month_100';
const levelMonth120 = 'month_120';
const levelPeriodOver = 'period_over';
const allLevels = [levelMonth80, levelMonth100, levelMonth120, levelPeriodOver];

const usedPercentOverflow = 999;

class Month implements Comparable<Month> {
  const Month(this.year, this.month);

  final int year;
  final int month; // 1..12

  static Month parse(String s) {
    final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(s);
    if (m == null) throw FormatException('invalid month', s);
    final month = int.parse(m.group(2)!);
    if (month < 1 || month > 12) throw FormatException('invalid month', s);
    return Month(int.parse(m.group(1)!), month);
  }

  static Month? tryParse(String s) {
    try {
      return parse(s);
    } on FormatException {
      return null;
    }
  }

  static Month ofDate(String date) => parse(date.substring(0, 7));

  factory Month.of(DateTime t) => Month(t.year, t.month);

  int get index => year * 12 + month - 1;

  int get daysIn => DateTime.utc(year, month + 1, 0).day;

  Month add(int months) {
    final i = index + months;
    return Month(i ~/ 12, i % 12 + 1);
  }

  /// Inclusive count of months from this to [other].
  int monthsUntil(Month other) => other.index - index + 1;

  @override
  String toString() => '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';

  String get label => '$year年$month月';

  @override
  int compareTo(Month other) => index.compareTo(other.index);

  @override
  bool operator ==(Object other) => other is Month && other.year == year && other.month == month;

  @override
  int get hashCode => index;
}

class Goal {
  const Goal({
    required this.startMonth,
    required this.endMonth,
    required this.plannedIncome,
    required this.savingsTarget,
  });

  final Month startMonth;
  final Month endMonth;
  final int plannedIncome;
  final int savingsTarget;

  int get totalMonths => startMonth.monthsUntil(endMonth);

  bool contains(Month m) => m.index >= startMonth.index && m.index <= endMonth.index;
}

class BudgetEntry {
  const BudgetEntry({required this.type, required this.amount, required this.date});

  final String type;
  final int amount;
  final String date; // YYYY-MM-DD
}

class Snapshot {
  const Snapshot({
    required this.month,
    required this.inPeriod,
    required this.budget,
    required this.spentBefore,
    required this.monthsLeft,
    required this.monthLimit,
    required this.monthSpent,
    required this.monthIncome,
    required this.monthRemaining,
    required this.usedPercent,
    required this.periodSpent,
    required this.periodIncome,
    required this.saved,
    required this.toTarget,
    required this.expectedSaved,
    required this.periodOver,
    required this.daysLeft,
    required this.dailyAllowance,
  });

  final String month;
  final bool inPeriod;
  final int budget;
  final int spentBefore;
  final int monthsLeft;
  final int monthLimit;
  final int monthSpent;
  final int monthIncome;
  final int monthRemaining;
  final int usedPercent;
  final int periodSpent;
  final int periodIncome;
  final int saved;
  final int toTarget;
  final int expectedSaved;
  final bool periodOver;
  final int daysLeft;
  final int dailyAllowance;

  Map<String, Object> toJson() => {
    'month': month,
    'in_period': inPeriod,
    'budget': budget,
    'spent_before': spentBefore,
    'months_left': monthsLeft,
    'month_limit': monthLimit,
    'month_spent': monthSpent,
    'month_income': monthIncome,
    'month_remaining': monthRemaining,
    'used_percent': usedPercent,
    'period_spent': periodSpent,
    'period_income': periodIncome,
    'saved': saved,
    'to_target': toTarget,
    'expected_saved': expectedSaved,
    'period_over': periodOver,
    'days_left': daysLeft,
    'daily_allowance': dailyAllowance,
  };
}

/// Computes the budget snapshot of [month] from all (non-deleted) household
/// entries. [today] is the local calendar date.
Snapshot computeSnapshot(Goal g, Iterable<BudgetEntry> entries, Month month, DateTime today) {
  final inPeriod = g.contains(month);
  final budget = g.plannedIncome - g.savingsTarget;

  var monthSpent = 0, monthIncome = 0, periodSpent = 0, periodIncome = 0, spentBefore = 0;

  for (final e in entries) {
    final Month em;
    try {
      em = Month.ofDate(e.date);
    } on Object {
      continue;
    }
    if (em == month) {
      if (e.type == typeExpense) {
        monthSpent += e.amount;
      } else if (e.type == typeIncome) {
        monthIncome += e.amount;
      }
    }
    if (!g.contains(em) || em.index > month.index) continue;
    if (e.type == typeExpense) {
      periodSpent += e.amount;
      if (em.index < month.index) spentBefore += e.amount;
    } else if (e.type == typeIncome) {
      periodIncome += e.amount;
    }
  }

  var monthsLeft = 0, monthLimit = 0, expectedSaved = 0;
  if (inPeriod) {
    monthsLeft = g.endMonth.index - month.index + 1;
    final left = budget - spentBefore;
    if (left > 0) monthLimit = left ~/ monthsLeft;
    final elapsed = month.index - g.startMonth.index + 1;
    expectedSaved = g.savingsTarget * elapsed ~/ g.totalMonths;
  }

  final monthRemaining = monthLimit - monthSpent;
  var usedPercent = 0;
  if (monthLimit > 0) {
    usedPercent = monthSpent * 100 ~/ monthLimit;
  } else if (monthSpent > 0) {
    usedPercent = usedPercentOverflow;
  }

  final saved = periodIncome - periodSpent;
  final toTarget = g.savingsTarget - saved < 0 ? 0 : g.savingsTarget - saved;
  final periodOver = inPeriod && periodSpent > (budget > 0 ? budget : 0);

  final todayMonth = Month.of(today);
  var daysLeft = 0;
  if (month == todayMonth) {
    daysLeft = month.daysIn - today.day + 1;
  } else if (month.index > todayMonth.index) {
    daysLeft = month.daysIn;
  }
  final dailyAllowance = monthRemaining > 0 && daysLeft > 0 ? monthRemaining ~/ daysLeft : 0;

  return Snapshot(
    month: month.toString(),
    inPeriod: inPeriod,
    budget: budget,
    spentBefore: spentBefore,
    monthsLeft: monthsLeft,
    monthLimit: monthLimit,
    monthSpent: monthSpent,
    monthIncome: monthIncome,
    monthRemaining: monthRemaining,
    usedPercent: usedPercent,
    periodSpent: periodSpent,
    periodIncome: periodIncome,
    saved: saved,
    toTarget: toTarget,
    expectedSaved: expectedSaved,
    periodOver: periodOver,
    daysLeft: daysLeft,
    dailyAllowance: dailyAllowance,
  );
}

/// Alert levels reached by [s], in ascending severity.
List<String> crossedLevels(Snapshot s) {
  if (!s.inPeriod) return const [];
  final levels = <String>[];
  for (final (level, percent) in const [(levelMonth80, 80), (levelMonth100, 100), (levelMonth120, 120)]) {
    if (s.monthSpent > 0 && s.monthSpent * 100 >= percent * s.monthLimit) {
      levels.add(level);
    }
  }
  if (s.periodOver) levels.add(levelPeriodOver);
  return levels;
}
