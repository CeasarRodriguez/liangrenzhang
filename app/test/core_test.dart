import 'dart:convert';
import 'dart:io';

import 'package:couple_ledger/core/alert_copy.dart';
import 'package:couple_ledger/core/budget.dart';
import 'package:couple_ledger/core/ids.dart';
import 'package:couple_ledger/core/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shared budget fixtures', () {
    final raw = File('../shared/budget_cases.json').readAsStringSync();
    final cases = (jsonDecode(raw) as Map<String, dynamic>)['cases'] as List;

    for (final c in cases.cast<Map<String, dynamic>>()) {
      test(c['name'], () {
        final g = c['goal'] as Map<String, dynamic>;
        final goal = Goal(
          startMonth: Month.parse(g['start_month']),
          endMonth: Month.parse(g['end_month']),
          plannedIncome: g['planned_income'],
          savingsTarget: g['savings_target'],
        );
        final entries = (c['entries'] as List).cast<Map<String, dynamic>>().map(
          (e) => BudgetEntry(type: e['type'], amount: e['amount'], date: e['date']),
        );
        final today = DateTime.parse(c['today']);

        final snap = computeSnapshot(goal, entries, Month.parse(c['month']), today);
        expect(snap.toJson(), c['expect']);
        expect(crossedLevels(snap), (c['levels'] as List).cast<String>());
      });
    }
  });

  test('formatYuan mirrors the Go implementation', () {
    expect(formatYuan(0), '0');
    expect(formatYuan(5), '0.05');
    expect(formatYuan(50), '0.50');
    expect(formatYuan(123456), '1,234.56');
    expect(formatYuan(100000), '1,000');
    expect(formatYuan(1234567890), '12,345,678.90');
    expect(formatYuan(-66667), '-666.67');
  });

  test('parseYuan', () {
    expect(parseYuan('12'), 1200);
    expect(parseYuan('12.5'), 1250);
    expect(parseYuan('0.05'), 5);
    expect(parseYuan('1,234.56'), 123456);
    expect(parseYuan(' 3. '), 300);
    expect(parseYuan('1.234'), isNull);
    expect(parseYuan('abc'), isNull);
    expect(parseYuan('-1'), isNull);
    expect(parseYuan(''), isNull);
    expect(centsToInput(123450), '1234.5');
    expect(centsToInput(100), '1');
    expect(centsToInput(105), '1.05');
  });

  test('renderAlert mirrors the Go implementation', () {
    const s = Snapshot(
      month: '2026-10',
      inPeriod: true,
      budget: 0,
      spentBefore: 0,
      monthsLeft: 3,
      monthLimit: 333333,
      monthSpent: 400000,
      monthIncome: 0,
      monthRemaining: -66667,
      usedPercent: 120,
      periodSpent: 0,
      periodIncome: 0,
      saved: -400000,
      toTarget: 2400000,
      expectedSaved: 0,
      periodOver: false,
      daysLeft: 20,
      dailyAllowance: 0,
    );
    expect(
      renderAlert('超出 ¥{超出金额}，剩 ¥{本月剩余}，限额 ¥{限额}，还差 ¥{还差}，{剩余天数} 天，{未知}', s, 2000000),
      '超出 ¥666.67，剩 ¥0，限额 ¥3,333.33，还差 ¥24,000，20 天，{未知}',
    );
    expect(unknownPlaceholders('a {限额} b {未知} {还差}'), ['{未知}']);
  });

  test('record ids match the PocketBase id format', () {
    final ids = List.generate(200, (_) => newRecordId()).toSet();
    expect(ids.length, 200);
    for (final id in ids) {
      expect(RegExp(r'^[a-z0-9]{15}$').hasMatch(id), isTrue, reason: id);
    }
  });

  test('Month arithmetic', () {
    expect(Month.parse('2026-12').add(1), const Month(2027, 1));
    expect(Month.parse('2026-01').add(-1), const Month(2025, 12));
    expect(Month.parse('2026-10').monthsUntil(Month.parse('2026-12')), 3);
    expect(Month.tryParse('2026-13'), isNull);
  });
}
