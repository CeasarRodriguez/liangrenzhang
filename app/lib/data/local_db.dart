import 'package:sembast/sembast.dart';

import 'models.dart';

/// Local cache of everything the app shows, so it works offline and
/// renders instantly. The server stays the source of truth.
class LocalDb {
  LocalDb(this.db);

  final Database db;

  final entries = stringMapStoreFactory.store('entries');
  final notes = stringMapStoreFactory.store('notes');
  final goals = stringMapStoreFactory.store('goals');
  final members = stringMapStoreFactory.store('members');
  final households = stringMapStoreFactory.store('households');
  final alerts = stringMapStoreFactory.store('alerts');
  final alertMessages = stringMapStoreFactory.store('alert_messages');
  final settings = StoreRef<String, Object?>('settings');

  /// Offline write queue, processed in key order.
  final outbox = intMapStoreFactory.store('outbox');

  StoreRef<String, Map<String, Object?>> storeFor(String collection) => switch (collection) {
    'entries' => entries,
    'entry_details' => notes,
    'goals' => goals,
    'users' => members,
    'households' => households,
    'alerts' => alerts,
    'alert_messages' => alertMessages,
    _ => throw ArgumentError('unknown collection $collection'),
  };

  // ---------------------------------------------------------------------------
  // settings

  Future<T?> getSetting<T>(String key) async => await settings.record(key).get(db) as T?;

  Future<void> setSetting(String key, Object? value) =>
      value == null ? settings.record(key).delete(db) : settings.record(key).put(db, value);

  // ---------------------------------------------------------------------------
  // remote upserts

  /// Writes server records, except over local records with unsent changes.
  Future<void> upsertRemote(String collection, List<Json> records) async {
    if (records.isEmpty) return;
    final store = storeFor(collection);
    await db.transaction((txn) async {
      for (final r in records) {
        final id = r['id'] as String;
        final existing = await store.record(id).get(txn);
        if (existing != null && existing['_pending'] == true) continue;
        await store.record(id).put(txn, _clean(r));
      }
    });
  }

  Future<void> deleteRemote(String collection, String id) => storeFor(collection).record(id).delete(db);

  Future<void> putLocal(String collection, Json record) =>
      storeFor(collection).record(record['id'] as String).put(db, _clean(record));

  static Map<String, Object?> _clean(Json r) {
    final out = <String, Object?>{};
    for (final e in r.entries) {
      // drop expand/collection metadata we never use
      if (e.key == 'expand' || e.key == 'collectionId' || e.key == 'collectionName') continue;
      out[e.key] = e.value;
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // outbox

  Future<void> enqueue(String collection, Json body) =>
      outbox.add(db, {'collection': collection, 'body': body, 'queued_at': DateTime.now().toIso8601String()});

  Future<List<RecordSnapshot<int, Map<String, Object?>>>> pendingOps() =>
      outbox.find(db, finder: Finder(sortOrders: [SortOrder(Field.key)]));

  Future<void> removeOp(int key) => outbox.record(key).delete(db);

  Stream<int> watchOutboxCount() => outbox.query().onCount(db);

  // ---------------------------------------------------------------------------
  // queries

  Stream<List<Entry>> watchEntries() => entries
      .query(finder: Finder(filter: Filter.notEquals('deleted', true)))
      .onSnapshots(db)
      .map(
        (list) => list.map((s) => Entry.fromJson(Map.of(s.value))).toList()
          ..sort((a, b) {
            final byDate = b.occurredOn.compareTo(a.occurredOn);
            return byDate != 0 ? byDate : b.created.compareTo(a.created);
          }),
      );

  Future<Entry?> getEntry(String id) async {
    final v = await entries.record(id).get(db);
    return v == null ? null : Entry.fromJson(Map.of(v));
  }

  Stream<Map<String, String>> watchNotes() =>
      notes.query().onSnapshots(db).map((list) => {for (final s in list) s.key: (s.value['note'] as String?) ?? ''});

  Stream<List<GoalRecord>> watchGoals() => goals
      .query()
      .onSnapshots(db)
      .map(
        (list) =>
            list.map((s) => GoalRecord.fromJson(Map.of(s.value))).whereType<GoalRecord>().toList()
              ..sort((a, b) => a.startMonth.compareTo(b.startMonth)),
      );

  Stream<List<Member>> watchMembers() =>
      members.query().onSnapshots(db).map((list) => list.map((s) => Member.fromJson(Map.of(s.value))).toList());

  Stream<Household?> watchHousehold(String id) =>
      households.record(id).onSnapshot(db).map((s) => s == null ? null : Household.fromJson(Map.of(s.value)));

  Stream<List<AlertItem>> watchAlerts() => alerts
      .query()
      .onSnapshots(db)
      .map(
        (list) =>
            list.map((s) => AlertItem.fromJson(Map.of(s.value))).toList()
              ..sort((a, b) => b.created.compareTo(a.created)),
      );

  Stream<List<AlertMessage>> watchAlertMessages() => alertMessages
      .query()
      .onSnapshots(db)
      .map(
        (list) =>
            list.map((s) => AlertMessage.fromJson(Map.of(s.value))).toList()
              ..sort((a, b) => a.created.compareTo(b.created)),
      );

  /// Clears everything except app settings such as the server address.
  Future<void> clearAccountData() async {
    await db.transaction((txn) async {
      for (final store in [entries, notes, goals, members, households, alerts, alertMessages]) {
        await store.delete(txn);
      }
      await outbox.delete(txn);
      final keys = await settings.findKeys(txn);
      for (final k in keys) {
        if (k.startsWith('sync:') || k == 'auth') await settings.record(k).delete(txn);
      }
    });
  }
}
