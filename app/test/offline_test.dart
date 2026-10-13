import 'dart:io';

import 'package:couple_ledger/core/alert_copy.dart';
import 'package:couple_ledger/core/budget.dart';
import 'package:couple_ledger/data/local_db.dart';
import 'package:couple_ledger/data/models.dart';
import 'package:couple_ledger/data/offline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test('default alert copy matches the server', () {
    final goSource = File('../server/internal/alertcopy/alertcopy.go').readAsStringSync();
    for (final level in allLevels) {
      for (final text in defaultAlertMessages[level]!) {
        expect(goSource, contains('"$text"'));
      }
      expect(goSource, contains('"${fallbackAlertMessages[level]}"'));
    }
  });

  group('offline backend', () {
    late LocalDb db;
    late OfflineBackend backend;
    final month = Month.of(DateTime.now());
    final day = '$month-01';

    setUp(() async {
      db = LocalDb(await newDatabaseFactoryMemory().openDatabase('t.db'));
      backend = OfflineBackend(db);
      await backend.ensureSeeded();
      // two-month goal: 2000 yuan to spend, so 1000 this month
      await db.putLocal('goals', {
        'id': 'g1',
        'household': offlineHouseholdId,
        'start_month': '$month',
        'end_month': '${month.add(1)}',
        'planned_income': 300000,
        'savings_target': 100000,
      });
    });

    Future<void> spend(String id, int cents) => db.putLocal(
      'entries',
      Entry(
        id: id,
        household: offlineHouseholdId,
        owner: offlineUserId,
        type: typeExpense,
        amount: cents,
        category: '餐饮',
        occurredOn: day,
      ).toLocal(),
    );

    Future<List<AlertItem>> alerts() async =>
        (await db.alerts.find(db.db)).map((s) => AlertItem.fromJson(Map.of(s.value))).toList();

    test('seeds both members and the default copy once', () async {
      await backend.ensureSeeded();
      expect(await db.members.count(db.db), 2);
      final total = defaultAlertMessages.values.fold<int>(0, (n, l) => n + l.length);
      expect(await db.alertMessages.count(db.db), total);
    });

    test('announces only the top newly crossed level, once', () async {
      final announced = <AlertItem>[];
      backend.newAlerts.listen(announced.add);

      await spend('e1', 50000);
      await backend.evaluate();
      expect(await alerts(), isEmpty);

      await spend('e2', 60000); // 110%
      await backend.evaluate();
      await backend.evaluate();
      await Future<void>.delayed(Duration.zero);

      final all = await alerts();
      expect(all.map((a) => a.kind).toSet(), {levelMonth80, levelMonth100});
      expect(all.firstWhere((a) => a.kind == levelMonth80).read, isTrue);
      expect(all.firstWhere((a) => a.kind == levelMonth100).read, isFalse);
      expect(announced.map((a) => a.kind), [levelMonth100]);
      expect(announced.single.body, isNot(contains('{')));
    });

    test('falls back when every message of a level is disabled', () async {
      for (final s in await db.alertMessages.find(db.db)) {
        await db.putLocal('alert_messages', {...s.value, 'enabled': false});
      }
      await spend('e1', 85000);
      await backend.evaluate();
      expect((await alerts()).single.body, '本月预算已用掉 80%，还剩 ¥150。');
    });

    test('reset clears data and reseeds', () async {
      await spend('e1', 85000);
      await backend.evaluate();
      await backend.reset();
      expect(await db.entries.count(db.db), 0);
      expect(await db.alerts.count(db.db), 0);
      expect(await db.members.count(db.db), 2);
    });
  });
}
