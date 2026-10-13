import 'dart:async';
import 'dart:math';

import 'package:sembast/sembast.dart';

import '../core/alert_copy.dart';
import '../core/budget.dart';
import '../core/ids.dart';
import 'local_db.dart';
import 'models.dart';

/// Offline trial build (`--dart-define=LEDGER_OFFLINE=true`): no server, no
/// login. Everything lives in the local database, the partner is simulated,
/// and budget alerts are evaluated on the phone the same way the server does
/// (server/internal/ledger/alerts.go).
const offlineMode = bool.fromEnvironment('LEDGER_OFFLINE');

const offlineUserId = 'offlineme000001';
const offlinePartnerId = 'offlineta000001';
const offlineHouseholdId = 'offlinehome0001';

class OfflineBackend {
  OfflineBackend(this.db);

  final LocalDb db;
  final _random = Random();
  final _newAlerts = StreamController<AlertItem>.broadcast();

  /// Alerts created by [evaluate], for the in-app dialog.
  Stream<AlertItem> get newAlerts => _newAlerts.stream;

  String _now() => DateTime.now().toUtc().toIso8601String();

  /// Creates the local household, both members and the default alert copy.
  Future<void> ensureSeeded() async {
    if (await db.households.record(offlineHouseholdId).exists(db.db)) return;
    final now = _now();
    await db.putLocal('households', {'id': offlineHouseholdId, 'name': '我们的家', 'invite_code': ''});
    await db.putLocal('users', {'id': offlineUserId, 'username': 'me', 'name': '我', 'household': offlineHouseholdId});
    await db.putLocal('users', {
      'id': offlinePartnerId,
      'username': 'ta',
      'name': 'TA（模拟）',
      'household': offlineHouseholdId,
    });
    for (final level in allLevels) {
      for (final text in defaultAlertMessages[level]!) {
        await db.putLocal('alert_messages', {
          'id': newRecordId(),
          'household': offlineHouseholdId,
          'level': level,
          'text': text,
          'is_default': true,
          'enabled': true,
          'created': now,
        });
      }
    }
  }

  Future<void> reset() async {
    await db.clearAccountData();
    await ensureSeeded();
  }

  /// Creates the alert levels newly crossed this month. Only the most severe
  /// one is announced; lower ones are stored as read.
  Future<void> evaluate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final month = Month.of(today);

    final goals = (await db.goals.find(db.db))
        .map((s) => GoalRecord.fromJson(Map.of(s.value)))
        .whereType<GoalRecord>()
        .where((g) => g.goal.contains(month))
        .toList();
    if (goals.isEmpty) return;
    final goal = goals.first;

    final entries = (await db.entries.find(
      db.db,
    )).map((s) => Entry.fromJson(Map.of(s.value))).where((e) => !e.deleted).map((e) => e.toBudget());
    final snap = computeSnapshot(goal.goal, entries, month, today);

    String periodKey(String level) => level == levelPeriodOver ? 'goal:${goal.id}' : month.toString();

    final existing = (await db.alerts.find(db.db)).map((s) => AlertItem.fromJson(Map.of(s.value))).toList();
    final newLevels = crossedLevels(
      snap,
    ).where((level) => !existing.any((a) => a.kind == level && a.periodKey == periodKey(level))).toList();
    if (newLevels.isEmpty) return;

    final messages = (await db.alertMessages.find(db.db)).map((s) => AlertMessage.fromJson(Map.of(s.value))).toList();
    final top = newLevels.last;
    AlertItem? announced;
    for (final level in newLevels) {
      final enabled = messages.where((m) => m.level == level && m.enabled).toList();
      final template = enabled.isEmpty ? fallbackAlertMessages[level]! : enabled[_random.nextInt(enabled.length)].text;
      final json = {
        'id': newRecordId(),
        'household': offlineHouseholdId,
        'recipient': offlineUserId,
        'kind': level,
        'period_key': periodKey(level),
        'title': alertTitles[level]!,
        'body': renderAlert(template, snap, goal.savingsTarget),
        'read': level != top,
        'created': _now(),
      };
      await db.putLocal('alerts', json);
      if (level == top) announced = AlertItem.fromJson(json);
    }
    if (announced != null) _newAlerts.add(announced);
  }
}
