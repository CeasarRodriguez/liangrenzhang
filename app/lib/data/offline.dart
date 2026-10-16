import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sembast/sembast.dart';

import '../core/alert_copy.dart';
import '../core/budget.dart';
import '../core/ids.dart';
import 'local_db.dart';
import 'models.dart';

/// Offline trial (public build): no server, no login. Everything lives in
/// the local database, the partner is simulated, and budget alerts are
/// evaluated on the phone (see [LocalAlerts]).

const offlineUserId = 'offlineme000001';
const offlinePartnerId = 'offlineta000001';
const offlineHouseholdId = 'offlinehome0001';

/// Writes the default reminder copy. The ids and timestamps are fixed, so
/// both phones in relay mode seed the very same records and an edit on one
/// phone simply wins over the untouched default on the other.
Future<void> seedDefaultAlertMessages(LocalDb db, String householdId) async {
  var n = 0;
  for (final level in allLevels) {
    final texts = defaultAlertMessages[level]!;
    for (var i = 0; i < texts.length; i++, n++) {
      final id = 'default-$level-$i';
      if (await db.alertMessages.record(id).exists(db.db)) continue;
      await db.putLocal('alert_messages', {
        'id': id,
        'household': householdId,
        'level': level,
        'text': texts[i],
        'is_default': true,
        'enabled': true,
        'created': DateTime.utc(2000, 1, 1, 0, 0, n).toIso8601String(),
        'updated': '',
      });
    }
  }
}

/// Budget alerts evaluated on the phone the same way the server does
/// (server/internal/ledger/alerts.go): in the offline trial, and in relay
/// mode, where the server cannot see the numbers.
class LocalAlerts {
  LocalAlerts(this.db, {required this.userId, required this.householdId});

  final LocalDb db;

  /// Recipient of the alerts this phone creates.
  String userId;
  final String householdId;

  final _random = Random();
  final _newAlerts = StreamController<AlertItem>.broadcast();
  Future<void> _queue = Future.value();

  /// Alerts created by [evaluate], for the in-app dialog.
  Stream<AlertItem> get newAlerts => _newAlerts.stream;

  String _now() => DateTime.now().toUtc().toIso8601String();

  Future<void> dispose() => _newAlerts.close();

  /// Creates the alert levels newly crossed this month. Only the most severe
  /// one is announced; lower ones are stored as read. Calls are serialized,
  /// so overlapping triggers never create an alert twice.
  Future<void> evaluate() => _queue = _queue.then((_) => _evaluate()).catchError((Object e) {
    debugPrint('local alert evaluation failed: $e');
  });

  Future<void> _evaluate() async {
    if (userId.isEmpty) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final month = Month.of(today);

    final goals = (await db.goals.find(db.db))
        .where((s) => s.value['_deleted'] != true)
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

    final messages = (await db.alertMessages.find(
      db.db,
    )).where((s) => s.value['_deleted'] != true).map((s) => AlertMessage.fromJson(Map.of(s.value))).toList();
    final top = newLevels.last;
    AlertItem? announced;
    for (final level in newLevels) {
      final enabled = messages.where((m) => m.level == level && m.enabled).toList();
      final template = enabled.isEmpty ? fallbackAlertMessages[level]! : enabled[_random.nextInt(enabled.length)].text;
      final json = {
        'id': newRecordId(),
        'household': householdId,
        'recipient': userId,
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
    if (announced != null && !_newAlerts.isClosed) _newAlerts.add(announced);
  }
}

class OfflineBackend extends LocalAlerts {
  OfflineBackend(super.db) : super(userId: offlineUserId, householdId: offlineHouseholdId);

  /// Creates the local household, both members and the default alert copy.
  Future<void> ensureSeeded() async {
    if (await db.households.record(offlineHouseholdId).exists(db.db)) return;
    await db.putLocal('households', {'id': offlineHouseholdId, 'name': '我们的家', 'invite_code': ''});
    await db.putLocal('users', {'id': offlineUserId, 'username': 'me', 'name': '我', 'household': offlineHouseholdId});
    await db.putLocal('users', {
      'id': offlinePartnerId,
      'username': 'ta',
      'name': 'TA（模拟）',
      'household': offlineHouseholdId,
    });
    await seedDefaultAlertMessages(db, offlineHouseholdId);
  }

  Future<void> reset() async {
    await db.clearAccountData();
    await ensureSeeded();
  }
}
