import 'dart:io';

import 'package:couple_ledger/core/alert_copy.dart';
import 'package:couple_ledger/core/budget.dart';
import 'package:couple_ledger/data/local_db.dart';
import 'package:couple_ledger/data/models.dart';
import 'package:couple_ledger/data/native.dart';
import 'package:couple_ledger/data/offline.dart';
import 'package:couple_ledger/data/repository.dart';
import 'package:couple_ledger/data/services.dart';
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

  group('reservations', () {
    late AppServices services;
    late Repository repo;

    setUp(() async {
      final db = LocalDb(await newDatabaseFactoryMemory().openDatabase('r.db'));
      services = AppServices(
        env: AppEnv(native: NativeBridge(), platform: 'android', dir: Directory.systemTemp.path, caPem: null),
        mode: AppMode.offline,
        db: db,
      );
      await services.init();
      repo = Repository(services);
    });

    Future<List<Entry>> entries() async =>
        (await services.db.entries.find(services.db.db)).map((s) => Entry.fromJson(Map.of(s.value))).toList();

    test('buying turns the reservation into the purchase, without a second entry', () async {
      final r = await repo.reserve(amount: 599900, category: '购物', title: '新手机', note: '黑色');
      expect(r.reserved, isTrue);
      expect(r.isExpense, isTrue);

      final bought = await repo.confirmReservation(r, occurredOn: '2026-11-02', amount: 589900);
      final all = await entries();
      expect(all, hasLength(1));
      expect(all.single.id, r.id);
      expect(all.single.reserved, isFalse);
      expect(all.single.title, '新手机');
      expect(all.single.amount, 589900);
      expect(all.single.occurredOn, '2026-11-02');
      expect(bought.category, '购物');
      expect((await services.db.notes.record(r.id).get(services.db.db))?['note'], '黑色');
    });

    test('giving up removes it from the budget', () async {
      final r = await repo.reserve(amount: 100000, category: '购物', title: '耳机');
      await repo.deleteEntry(r);
      expect((await entries()).single.deleted, isTrue);
    });
  });
}
