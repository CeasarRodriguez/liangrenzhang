// Big-purchase planning (app only): what buying something now does to this
// month, the later months of the goal and the savings target.

import 'budget.dart';

enum PurchaseFit {
  /// This month's remaining limit covers it.
  thisMonth,

  /// The rest is spread over the later months; the target is safe.
  laterMonths,

  /// More than the period has left to spend: the target shrinks.
  overGoal,
}

class PurchaseImpact {
  const PurchaseImpact({
    required this.price,
    required this.snapshot,
    required this.fromThisMonth,
    required this.laterMonths,
    required this.laterLimitBefore,
    required this.laterLimitAfter,
    required this.goalShrink,
    required this.projectedSavings,
    required this.recentAverageSpend,
  });

  final int price;

  /// This month before buying.
  final Snapshot snapshot;

  /// Part of the price this month's remaining limit covers.
  final int fromThisMonth;

  /// Goal months after this one.
  final int laterMonths;

  /// Monthly limit of the later months, assuming this month ends exactly at
  /// its limit (or where it already is, if over).
  final int laterLimitBefore;
  final int laterLimitAfter;

  /// How much less would be saved by the end of the period because of it.
  final int goalShrink;

  /// Savings at the end of the period after buying, if every later limit
  /// is kept.
  final int projectedSavings;

  /// Average monthly spending of up to three recent months; 0 without data.
  final int recentAverageSpend;

  /// Part of the price left for the later months or the target.
  int get spillover => price - fromThisMonth;

  int get remainingAfter => snapshot.monthRemaining - price;

  int get savedAfter => snapshot.saved - price;

  PurchaseFit get fit => spillover == 0
      ? PurchaseFit.thisMonth
      : goalShrink == 0
      ? PurchaseFit.laterMonths
      : PurchaseFit.overGoal;

  /// The later limit falls clearly below what the couple usually spends.
  bool get tight => laterMonths > 0 && recentAverageSpend > 0 && laterLimitAfter * 5 < recentAverageSpend * 4;
}

/// Simulates spending [price] today in [month], which must lie in [g].
PurchaseImpact simulatePurchase(Goal g, Iterable<BudgetEntry> entries, Month month, DateTime today, int price) {
  final list = entries.toList();
  final s = computeSnapshot(g, list, month, today);

  final remaining = s.monthRemaining > 0 ? s.monthRemaining : 0;
  final fromThisMonth = price < remaining ? price : remaining;

  int monthTotal(int spent) => spent > s.monthLimit ? spent : s.monthLimit;
  final laterMonths = s.monthsLeft > 0 ? s.monthsLeft - 1 : 0;
  final leftBefore = s.budget - s.spentBefore - monthTotal(s.monthSpent);
  final leftAfter = s.budget - s.spentBefore - monthTotal(s.monthSpent + price);
  int laterLimit(int left) => laterMonths > 0 && left > 0 ? left ~/ laterMonths : 0;
  int shrink(int left) => left < 0 ? -left : 0;

  return PurchaseImpact(
    price: price,
    snapshot: s,
    fromThisMonth: fromThisMonth,
    laterMonths: laterMonths,
    laterLimitBefore: laterLimit(leftBefore),
    laterLimitAfter: laterLimit(leftAfter),
    goalShrink: shrink(leftAfter) - shrink(leftBefore),
    projectedSavings: g.savingsTarget - shrink(leftAfter),
    recentAverageSpend: recentAverageSpend(list, month),
  );
}

/// Average monthly spending over the (up to) three months before [month]
/// that have any records.
int recentAverageSpend(Iterable<BudgetEntry> entries, Month month, {int months = 3}) {
  final from = month.add(-months).index;
  final spent = <int, int>{};
  for (final e in entries) {
    final Month em;
    try {
      em = Month.ofDate(e.date);
    } on Object {
      continue;
    }
    if (em.index < from || em.index >= month.index) continue;
    spent[em.index] = (spent[em.index] ?? 0) + (e.type == typeExpense ? e.amount : 0);
  }
  if (spent.isEmpty) return 0;
  return spent.values.fold(0, (a, b) => a + b) ~/ spent.length;
}
