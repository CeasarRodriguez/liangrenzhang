import 'package:couple_ledger/core/badges.dart';
import 'package:couple_ledger/core/budget.dart';
import 'package:couple_ledger/core/purchase.dart';
import 'package:flutter_test/flutter_test.dart';

BudgetEntry spend(int cents, String date) => BudgetEntry(owner: 'alice', type: typeExpense, amount: cents, date: date);
BudgetEntry earn(String owner, int cents, String date) =>
    BudgetEntry(owner: owner, type: typeIncome, amount: cents, date: date);

void main() {
  group('simulatePurchase', () {
    // 30,000 expected, 15,000 to save: 5,000 a month; 1,000 spent so far
    const goal = Goal(
      startMonth: Month(2026, 10),
      endMonth: Month(2026, 12),
      plannedIncome: 3000000,
      savingsTarget: 1500000,
      incomePlan: {'alice': 1000000},
    );
    final entries = [
      spend(100000, '2026-10-05'),
      // before the goal: only used as the recent-spending reference
      spend(600000, '2026-09-10'),
      spend(400000, '2026-08-10'),
    ];
    final today = DateTime(2026, 10, 12);
    PurchaseImpact simulate(int price) => simulatePurchase(goal, entries, const Month(2026, 10), today, price);

    test('fits in this month', () {
      final i = simulate(300000);
      expect(i.fit, PurchaseFit.thisMonth);
      expect(i.fromThisMonth, 300000);
      expect(i.remainingAfter, 100000);
      expect(i.laterMonths, 2);
      expect(i.laterLimitBefore, 500000);
      expect(i.laterLimitAfter, 500000);
      expect(i.goalShrink, 0);
      expect(i.projectedSavings, 1500000);
      expect(i.recentAverageSpend, 500000);
      expect(i.tight, isFalse);
    });

    test('spreads the rest over the later months', () {
      final i = simulate(700000);
      expect(i.fit, PurchaseFit.laterMonths);
      expect(i.fromThisMonth, 400000);
      expect(i.spillover, 300000);
      expect(i.laterLimitAfter, 350000);
      expect(i.goalShrink, 0);
      expect(i.savedAfter, -800000);
      // 3,500 a month is well below the usual 5,000
      expect(i.tight, isTrue);
    });

    test('shrinks the target beyond what the period can spend', () {
      final i = simulate(2000000);
      expect(i.fit, PurchaseFit.overGoal);
      expect(i.laterLimitAfter, 0);
      expect(i.goalShrink, 600000);
      expect(i.projectedSavings, 900000);
    });

    test('in the last month everything beyond the limit hits the target', () {
      final i = simulatePurchase(goal, entries, const Month(2026, 12), DateTime(2026, 12, 20), 2000000);
      expect(i.laterMonths, 0);
      expect(i.fit, PurchaseFit.overGoal);
      expect(i.fromThisMonth, 1400000);
      expect(i.goalShrink, i.spillover);
    });
  });

  group('badges', () {
    // 40,000 expected, 20,000 to save: 5,000 a month, 5,000 saved per month
    const goal = Goal(
      startMonth: Month(2026, 9),
      endMonth: Month(2026, 12),
      plannedIncome: 4000000,
      savingsTarget: 2000000,
      incomePlan: {'alice': 1000000},
    );
    final entries = [
      earn('alice', 1000000, '2026-09-10'),
      spend(400000, '2026-09-12'), // within 5,000, saved 6,000 >= 5,000
      earn('alice', 1000000, '2026-10-10'),
      spend(600000, '2026-10-12'), // over October's 5,333.33
    ];

    test('needs both the limit and the savings pace', () {
      expect(monthAchieved(goal, entries, const Month(2026, 9)), isTrue);
      expect(monthAchieved(goal, entries, const Month(2026, 10)), isFalse);
      // kept the limit, but nothing saved without income
      expect(monthAchieved(goal, entries.where((e) => e.type == typeExpense), const Month(2026, 9)), isFalse);
      expect(monthAchieved(goal, entries, const Month(2026, 8)), isFalse);
    });

    test('only finished months count', () {
      expect(earnedBadges([goal], entries, const Month(2026, 9)), isEmpty);
      expect(earnedBadges([goal], entries, const Month(2026, 11)), [const Month(2026, 9)]);
    });

    test('levels are not defined yet', () {
      expect(badgeLevel([const Month(2026, 9)]), isNull);
    });
  });

  test('missingIncome lists who recorded nothing', () {
    const goal = Goal(
      startMonth: Month(2026, 10),
      endMonth: Month(2026, 12),
      plannedIncome: 5400000,
      savingsTarget: 2000000,
      incomePlan: {'alice': 1000000, 'bob': 800000},
    );
    final entries = [earn('alice', 900000, '2026-10-15')];
    expect(missingIncome(goal, entries, const Month(2026, 10)), ['bob']);
    expect(missingIncome(goal, entries, const Month(2026, 9)), isEmpty);

    const legacy = Goal(
      startMonth: Month(2026, 10),
      endMonth: Month(2026, 12),
      plannedIncome: 3000000,
      savingsTarget: 0,
    );
    expect(missingIncome(legacy, const [], const Month(2026, 10)), [othersKey]);
    expect(missingIncome(legacy, entries, const Month(2026, 10)), isEmpty);
  });
}
