import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sembast/sembast.dart';

import 'api.dart';
import 'local_db.dart';
import 'models.dart';

class SyncStatus {
  const SyncStatus({this.online = false, this.syncing = false, this.lastSync, this.lastError});

  final bool online;
  final bool syncing;
  final DateTime? lastSync;
  final String? lastError;

  SyncStatus copyWith({bool? online, bool? syncing, DateTime? lastSync, String? lastError, bool clearError = false}) =>
      SyncStatus(
        online: online ?? this.online,
        syncing: syncing ?? this.syncing,
        lastSync: lastSync ?? this.lastSync,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );
}

/// Keeps the local cache in sync with the server: pushes the offline
/// outbox, pulls changes incrementally and applies realtime events.
class SyncService {
  SyncService({required this.pb, required this.db});

  final PocketBase pb;
  final LocalDb db;

  final status = ValueNotifier(const SyncStatus());

  /// Fires for every alert that arrives unread while the app is running.
  final _newAlerts = StreamController<AlertItem>.broadcast();
  Stream<AlertItem> get newAlerts => _newAlerts.stream;

  /// Pulled incrementally by `updated`.
  static const _incremental = ['households', 'users', 'entries', 'entry_details', 'alerts'];

  /// Small collections where rows may be hard-deleted: always fully replaced.
  static const _full = ['goals', 'alert_messages'];

  static const _realtime = [..._incremental, ..._full];

  final _unsubscribers = <UnsubscribeFunc>[];
  Timer? _timer;
  Timer? _retry;
  int _retryDelay = 5;
  bool _running = false;
  bool _syncing = false;
  bool _again = false;
  bool _connectedOnce = false;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => syncNow());
    await syncNow();
    unawaited(_subscribe());
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _retry?.cancel();
    _retry = null;
    for (final unsub in _unsubscribers) {
      try {
        await unsub();
      } on Object {
        // already disconnected
      }
    }
    _unsubscribers.clear();
    pb.realtime.onDisconnect = null;
  }

  Future<void> dispose() async {
    await stop();
    await _newAlerts.close();
    status.dispose();
  }

  Future<void> _subscribe() async {
    try {
      pb.realtime.onDisconnect = (subs) {
        if (_running && subs.isNotEmpty) status.value = status.value.copyWith(online: false);
      };
      _unsubscribers.add(
        await pb.realtime.subscribe('PB_CONNECT', (_) {
          status.value = status.value.copyWith(online: true);
          // catch up on anything missed while disconnected
          if (_connectedOnce) syncNow();
          _connectedOnce = true;
        }),
      );
      for (final c in _realtime) {
        _unsubscribers.add(await pb.collection(c).subscribe('*', (e) => _onEvent(c, e)));
      }
    } on Object catch (e) {
      debugPrint('realtime subscribe failed: $e');
      // retried by the periodic sync below
      if (_running) {
        Future.delayed(const Duration(seconds: 30), () {
          if (_running && _unsubscribers.isEmpty) _subscribe();
        });
      }
    }
  }

  Future<void> _onEvent(String collection, RecordSubscriptionEvent e) async {
    final record = e.record;
    if (record == null) return;
    if (e.action == 'delete') {
      await db.deleteRemote(collection, record.id);
      return;
    }
    final json = record.toJson();
    await db.upsertRemote(collection, [json]);
    if (collection == 'alerts' && e.action == 'create' && json['read'] != true) {
      _newAlerts.add(AlertItem.fromJson(json));
    }
  }

  /// Pushes the outbox, then pulls server changes. Safe to call often.
  Future<void> syncNow() async {
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    status.value = status.value.copyWith(syncing: true);
    try {
      // a connection dropped mid-request can hang forever; don't let it block syncing
      await _syncOnce().timeout(const Duration(seconds: 90));
      status.value = status.value.copyWith(online: true, lastSync: DateTime.now(), clearError: true);
      _retryDelay = 5;
    } on Object catch (e) {
      final offline = isNetworkError(e) || e is TimeoutException;
      status.value = status.value.copyWith(online: !offline, lastError: offline ? null : describeError(e));
      if (offline) _scheduleRetry();
    } finally {
      _syncing = false;
      status.value = status.value.copyWith(syncing: false);
      if (_again) {
        _again = false;
        unawaited(syncNow());
      }
    }
  }

  Future<void> _syncOnce() async {
    await flushOutbox();
    for (final c in _incremental) {
      await _pullIncremental(c);
    }
    for (final c in _full) {
      await _pullFull(c);
    }
  }

  /// Retries soon after a network failure (5s, 10s, … up to 1 min), so
  /// offline entries go up shortly after the connection comes back.
  void _scheduleRetry() {
    if (!_running || (_retry?.isActive ?? false)) return;
    _retry = Timer(Duration(seconds: _retryDelay), () {
      _retry = null;
      syncNow();
    });
    _retryDelay = (_retryDelay * 2).clamp(5, 60);
  }

  Future<void> _pullIncremental(String collection) async {
    final key = 'sync:$collection';
    final since = await db.getSetting<String>(key);
    final records = await pb
        .collection(collection)
        .getFullList(batch: 500, sort: 'updated', filter: since == null ? null : 'updated >= "$since"');
    await db.upsertRemote(collection, [for (final r in records) r.toJson()]);
    if (records.isNotEmpty) await db.setSetting(key, records.last.get<String>('updated'));
  }

  Future<void> _pullFull(String collection) async {
    final records = await pb.collection(collection).getFullList(batch: 500);
    final store = db.storeFor(collection);
    final keep = {for (final r in records) r.id};
    final existing = await store.findKeys(db.db);
    for (final id in existing) {
      if (!keep.contains(id)) await store.record(id).delete(db.db);
    }
    await db.upsertRemote(collection, [for (final r in records) r.toJson()]);
  }

  /// Sends queued offline writes in order. Network errors leave the rest of
  /// the queue for later; a rejected write is dropped and the local copy is
  /// reset to the server's version.
  Future<void> flushOutbox() async {
    await _requeueOrphans();
    final ops = await db.pendingOps();
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i];
      final collection = op.value['collection'] as String;
      final body = Map<String, dynamic>.from(op.value['body'] as Map);
      final id = body['id'] as String;

      try {
        final saved = await _upsert(collection, id, body);
        await db.removeOp(op.key);
        final laterEdits = ops
            .skip(i + 1)
            .any((o) => o.value['collection'] == collection && (o.value['body'] as Map)['id'] == id);
        if (!laterEdits) await db.putLocal(collection, {...saved.toJson(), '_pending': false});
      } on ClientException catch (e) {
        if (isNetworkError(e)) rethrow;
        await db.removeOp(op.key);
        status.value = status.value.copyWith(lastError: describeError(e));
        await _resetFromServer(collection, id);
      }
    }
  }

  /// Local records marked pending whose outbox entry is gone (e.g. lost by
  /// an older app version) are queued again instead of staying stuck.
  Future<void> _requeueOrphans() async {
    final queued = {
      for (final op in await db.pendingOps()) '${op.value['collection']}/${(op.value['body'] as Map)['id']}',
    };
    for (final collection in const ['entries', 'entry_details', 'alerts']) {
      final pending = await db
          .storeFor(collection)
          .find(db.db, finder: Finder(filter: Filter.equals('_pending', true)));
      for (final r in pending) {
        if (queued.contains('$collection/${r.key}')) continue;
        final v = r.value;
        final body = switch (collection) {
          'entries' => Entry.fromJson(Map.of(v)).toApi(),
          'entry_details' => {'id': r.key, 'entry': v['entry'], 'owner': v['owner'], 'note': v['note'] ?? ''},
          _ => {'id': r.key, 'read': v['read'] ?? true},
        };
        await db.enqueue(collection, body);
      }
    }
  }

  Future<RecordModel> _upsert(String collection, String id, Map<String, dynamic> body) async {
    final update = Map<String, dynamic>.of(body)..remove('id');
    try {
      return await pb.collection(collection).update(id, body: update);
    } on ClientException catch (e) {
      if (e.statusCode != 404) rethrow;
      return pb.collection(collection).create(body: body);
    }
  }

  Future<void> _resetFromServer(String collection, String id) async {
    try {
      final r = await pb.collection(collection).getOne(id);
      await db.putLocal(collection, r.toJson());
    } on ClientException catch (e) {
      if (e.statusCode == 404) await db.deleteRemote(collection, id);
    }
  }
}
