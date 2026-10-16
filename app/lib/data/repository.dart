import 'dart:async';

import 'package:sembast/sembast.dart';

import '../core/budget.dart';
import '../core/dates.dart';
import '../core/ids.dart';
import 'models.dart';
import 'relay_sync.dart';
import 'services.dart';

/// Write operations. With a server, entries and notes work offline through
/// the outbox; goals and settings-like changes need a connection. In the
/// offline trial and relay mode everything is written locally first; relay
/// mode then queues the change (never the private note) for the partner.
class Repository {
  Repository(this.s);

  final AppServices s;

  bool get _local => s.isLocalFirst;
  RelaySync? get _relay => s.relay;

  void _kick() {
    unawaited(s.localAlerts?.evaluate());
    unawaited(s.sync?.syncNow());
  }

  /// Local-first modes: writes a record as the final version and, in relay
  /// mode, sends it to the partner's phone.
  Future<Json> _putLocal(String collection, Json body) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final store = s.db.storeFor(collection);
    final id = body['id'] as String? ?? newRecordId();
    final existing = await store.record(id).get(s.db.db) ?? const {};
    final rec = {
      ...existing,
      ...body,
      'id': id,
      'created': existing['created'] ?? now,
      'updated': now,
      '_by': ?_relay?.deviceId,
    }..remove('_pending');
    await s.db.putLocal(collection, rec);
    await _relay?.publish(collection, rec);
    return rec;
  }

  /// Local-first modes: the offline trial simply deletes; relay mode leaves
  /// a tombstone so the partner's phone deletes its copy too.
  Future<void> _deleteLocal(String collection, String id) async {
    final relay = _relay;
    if (relay == null) return s.db.deleteRemote(collection, id);
    final now = DateTime.now().toUtc().toIso8601String();
    final tombstone = {'id': id, '_deleted': true, 'updated': now, '_by': relay.deviceId};
    await s.db.storeFor(collection).record(id).put(s.db.db, tombstone);
    await relay.publish(collection, tombstone);
  }

  Future<Entry> saveEntry({
    String? id,
    String? owner,
    required String type,
    required int amount,
    required String category,
    required String occurredOn,
    String? note,
    bool? reserved,
    String? title,
  }) async {
    final existing = id == null ? null : await s.db.getEntry(id);
    var entry = Entry(
      id: id ?? newRecordId(),
      household: existing?.household ?? s.householdId,
      owner: existing?.owner ?? owner ?? s.userId,
      type: type,
      amount: amount,
      category: category,
      occurredOn: occurredOn,
      reserved: reserved ?? existing?.reserved ?? false,
      title: title ?? existing?.title ?? '',
      created: existing?.created ?? DateTime.now().toUtc().toIso8601String(),
      updated: existing?.updated ?? '',
      pending: !_local,
    );
    if (_local) {
      entry = Entry.fromJson(await _putLocal('entries', entry.toLocal()));
    } else {
      await s.db.putLocal('entries', entry.toLocal());
      await s.db.enqueue('entries', entry.toApi());
    }

    // the simulated partner's notes would be private to them anyway; in
    // relay mode notes stay on this phone, they are never published
    if (note != null && entry.owner == s.userId) {
      final hadNote = await s.db.notes.record(entry.id).exists(s.db.db);
      if (note.isNotEmpty || hadNote) {
        final body = {'id': entry.id, 'entry': entry.id, 'owner': entry.owner, 'note': note};
        await s.db.putLocal('entry_details', {...body, '_pending': !_local});
        if (!_local) await s.db.enqueue('entry_details', body);
      }
    }

    _kick();
    return entry;
  }

  /// Pre-deducts a planned purchase: it counts as spent today until it is
  /// bought ([confirmReservation]) or given up ([deleteEntry]).
  Future<Entry> reserve({
    required int amount,
    required String category,
    required String title,
    String? owner,
    String? note,
  }) {
    final now = DateTime.now();
    return saveEntry(
      owner: owner,
      type: typeExpense,
      amount: amount,
      category: category,
      occurredOn: isoDate(DateTime(now.year, now.month, now.day)),
      note: note,
      reserved: true,
      title: title,
    );
  }

  /// Turns a reservation into the actual purchase, so it is never recorded
  /// twice. Null arguments keep the reservation's values.
  Future<Entry> confirmReservation(
    Entry e, {
    required String occurredOn,
    required int amount,
    String? category,
    String? title,
    String? note,
  }) => saveEntry(
    id: e.id,
    type: typeExpense,
    amount: amount,
    category: category ?? e.category,
    occurredOn: occurredOn,
    note: note,
    reserved: false,
    title: title,
  );

  Future<void> deleteEntry(Entry e) async {
    final deleted = e.copyWith(deleted: true, pending: !_local);
    if (_local) {
      await _putLocal('entries', deleted.toLocal());
    } else {
      await s.db.putLocal('entries', deleted.toLocal());
      await s.db.enqueue('entries', deleted.toApi());
    }
    _kick();
  }

  /// Alerts are per phone in the local-first modes; read state stays local.
  Future<void> markAlertRead(AlertItem a) async {
    final raw = await s.db.alerts.record(a.id).get(s.db.db);
    if (raw == null) return;
    if (_local) {
      await s.db.putLocal('alerts', {...raw, 'read': true});
      return;
    }
    await s.db.putLocal('alerts', {...raw, 'read': true, '_pending': true});
    await s.db.enqueue('alerts', {'id': a.id, 'read': true});
    _kick();
  }

  Future<void> saveGoal({
    String? id,
    required Month start,
    required Month end,
    required Map<String, int> incomePlan,
    required int savingsTarget,
  }) async {
    final months = start.monthsUntil(end);
    final body = {
      'household': s.householdId,
      'start_month': start.toString(),
      'end_month': end.toString(),
      // the combined total keeps pre-1.2 apps working
      'planned_income': incomePlan.values.fold(0, (a, b) => a + b) * months,
      'income_plan': incomePlan,
      'savings_target': savingsTarget,
    };
    if (_local) {
      await _putLocal('goals', {...body, 'id': ?id});
      _kick();
      return;
    }
    final rec = id == null
        ? await s.pb.collection('goals').create(body: body)
        : await s.pb.collection('goals').update(id, body: body);
    await s.db.putLocal('goals', rec.toJson());
  }

  Future<void> deleteGoal(String id) async {
    if (_local) {
      await _deleteLocal('goals', id);
      return _kick();
    }
    await s.pb.collection('goals').delete(id);
    await s.db.deleteRemote('goals', id);
  }

  Future<void> addAlertMessage(String level, String text) async {
    final body = {'household': s.householdId, 'level': level, 'text': text, 'enabled': true, 'created_by': s.userId};
    if (_local) {
      await _putLocal('alert_messages', {...body, 'is_default': false});
      return _kick();
    }
    final rec = await s.pb.collection('alert_messages').create(body: body);
    await s.db.putLocal('alert_messages', rec.toJson());
  }

  Future<void> updateAlertMessage(AlertMessage m, {String? text, bool? enabled}) async {
    final body = {'text': ?text, 'enabled': ?enabled};
    if (_local) {
      await _putLocal('alert_messages', {...body, 'id': m.id});
      return _kick();
    }
    final rec = await s.pb.collection('alert_messages').update(m.id, body: body);
    await s.db.putLocal('alert_messages', rec.toJson());
  }

  Future<void> deleteAlertMessage(AlertMessage m) async {
    if (_local) {
      await _deleteLocal('alert_messages', m.id);
      return _kick();
    }
    await s.pb.collection('alert_messages').delete(m.id);
    await s.db.deleteRemote('alert_messages', m.id);
  }

  Future<void> updateProfile({String? name, String? color}) async {
    final body = {'name': ?name, 'color': ?color};
    if (_local) {
      await _putLocal('users', {...body, 'id': s.userId});
      return _kick();
    }
    final rec = await s.pb.collection('users').update(s.userId, body: body);
    await s.db.putLocal('users', rec.toJson());
  }

  Future<void> renameHousehold(String name) async {
    if (_local) {
      await _putLocal('households', {'id': s.householdId, 'name': name});
      return _kick();
    }
    final rec = await s.pb.collection('households').update(s.householdId, body: {'name': name});
    await s.db.putLocal('households', rec.toJson());
  }
}
