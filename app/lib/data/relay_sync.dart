import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sembast/sembast.dart';

import 'api.dart';
import 'local_db.dart';
import 'models.dart';
import 'offline.dart';
import 'relay_client.dart';
import 'relay_crypto.dart';
import 'sync.dart';

/// Collections both phones share in relay mode. Private notes
/// (entry_details) and alerts never leave the phone.
const relayShared = ['households', 'users', 'goals', 'alert_messages', 'entries'];

/// Last writer wins: whether [a] is a newer version of a record than [b].
/// `updated` is the writing phone's clock, `_by` its device id breaks ties.
bool relayNewer(Map<String, Object?> a, Map<String, Object?> b) {
  final byTime = (a['updated'] as String? ?? '').compareTo(b['updated'] as String? ?? '');
  if (byTime != 0) return byTime > 0;
  return (a['_by'] as String? ?? '').compareTo(b['_by'] as String? ?? '') > 0;
}

/// Relay mode sync: the data lives on the two phones only. Local writes are
/// queued in the outbox, encrypted and handed to the relay server, which
/// keeps them until the partner's phone picks them up.
///
/// Messages (before encryption):
///   {"t": "hello" | "changes" | "snapshot", "m": sender member id,
///    "r": [{"c": collection, "r": record}, …], "last": true (snapshot end)}
/// A phone that joins says hello; its partner answers with a snapshot of
/// everything shared, so a reinstalled phone gets its own records back too.
class RelaySync implements SyncEngine {
  RelaySync({
    required this.db,
    required this.transport,
    required this.keys,
    required this.deviceId,
    required this.alerts,
  });

  final LocalDb db;
  final RelayTransport transport;
  final RelayKeys keys;
  final String deviceId;

  /// Evaluates budget alerts for [memberId] whenever data changes.
  final LocalAlerts alerts;

  /// My member id; empty while a reinstalled phone is being restored.
  String get memberId => alerts.userId;

  @override
  final status = ValueNotifier(const SyncStatus());

  @override
  Stream<AlertItem> get newAlerts => alerts.newAlerts;

  /// Member id of the partner's phone, once it has sent anything.
  final partnerMember = ValueNotifier('');

  static const cursorKey = 'relay:cursor';
  static const helloKey = 'relay:hello_sent';
  static const snapshotDueKey = 'relay:snapshot_due';
  static const partnerKey = 'relay:partner_member';

  /// Records per message and messages per request: keeps every request
  /// far below the server's 512 KB limit.
  static const _perMessage = 200;
  static const _perRequest = 10;

  Timer? _timer;
  Timer? _retry;
  Timer? _relisten;
  StreamSubscription<void>? _events;
  int _retryDelay = 5;
  bool _running = false;
  bool _syncing = false;
  bool _again = false;
  bool _joined = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    partnerMember.value = await db.getSetting<String>(partnerKey) ?? '';
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => syncNow());
    await syncNow();
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _retry?.cancel();
    _retry = null;
    _relisten?.cancel();
    _relisten = null;
    await _events?.cancel();
    _events = null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await stop();
    transport.close();
    await alerts.dispose();
    status.dispose();
    partnerMember.dispose();
  }

  /// Queues a local write for the partner's phone.
  Future<void> publish(String collection, Map<String, Object?> record) => db.enqueue(collection, _shareable(record));

  /// Leaves the room on the server (best effort).
  Future<void> leave() async {
    try {
      await transport.leave().timeout(const Duration(seconds: 10));
    } on Object catch (e) {
      debugPrint('relay leave failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // event stream

  void _listen() {
    if (!_running || _events != null) return;
    _events = transport.events().listen(
      (_) {
        status.value = status.value.copyWith(online: true);
        syncNow();
      },
      onError: (Object e) => _dropped(),
      onDone: _dropped,
      cancelOnError: true,
    );
  }

  void _dropped() {
    _events = null;
    if (!_running) return;
    _relisten?.cancel();
    _relisten = Timer(const Duration(seconds: 30), _listen);
  }

  // ---------------------------------------------------------------------------
  // sync

  /// Sends queued writes, then fetches what the partner sent. Safe to call often.
  @override
  Future<void> syncNow() async {
    if (_disposed) return;
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    status.value = status.value.copyWith(syncing: true);
    try {
      await _syncOnce().timeout(const Duration(seconds: 90));
      if (_disposed) return;
      status.value = status.value.copyWith(online: true, lastSync: DateTime.now(), clearError: true);
      _retryDelay = 5;
      _listen();
    } on Object catch (e) {
      if (_disposed) return;
      // dropped by the server after a long absence: join again next round
      if (e is RelayException && (e.code == 'not_joined' || e.code == 'room_not_found')) _joined = false;
      final offline = _isNetworkError(e) || !_joined;
      status.value = status.value.copyWith(online: !offline, lastError: offline ? null : describeError(e));
      if (offline) _scheduleRetry();
    } finally {
      _syncing = false;
      if (!_disposed) {
        status.value = status.value.copyWith(syncing: false);
        if (_again) {
          _again = false;
          unawaited(syncNow());
        }
      }
    }
  }

  static bool _isNetworkError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is HttpException ||
      // the proxy is up but the relay service is not (restarting)
      (e is RelayException && (e.status == 502 || e.status == 503 || e.status == 504));

  void _scheduleRetry() {
    if (!_running || (_retry?.isActive ?? false)) return;
    _retry = Timer(Duration(seconds: _retryDelay), () {
      _retry = null;
      syncNow();
    });
    _retryDelay = (_retryDelay * 2).clamp(5, 60);
  }

  Future<void> _syncOnce() async {
    if (!_joined) {
      // a room nobody used for half a year is gone; both phones still hold
      // the secret, so simply open it again
      final registered = await transport.join(create: true);
      _joined = true;
      // the server forgot this phone, and what was waiting for it: ask the
      // partner for everything again (pairing itself registers the phone)
      if (registered) await db.setSetting(helloKey, null);
    }
    if (await db.getSetting<bool>(helloKey) != true) {
      await _sendHello();
      await db.setSetting(helloKey, true);
    }
    await _flushOutbox();
    final changed = await _pull();
    if (await db.getSetting<bool>(snapshotDueKey) == true) {
      await _sendSnapshot();
      await db.setSetting(snapshotDueKey, null);
    }
    if (changed) unawaited(alerts.evaluate());
  }

  static Map<String, Object?> _shareable(Map<String, Object?> r) => {
    for (final e in r.entries)
      if (e.key != '_pending') e.key: e.value,
  };

  Future<void> _send(List<Map<String, Object?>> messages) async {
    for (var i = 0; i < messages.length; i += _perRequest) {
      final chunk = messages.sublist(i, min(i + _perRequest, messages.length));
      final items = <String>[];
      for (final m in chunk) {
        items.add(await keys.seal(m, deviceId));
      }
      await transport.send(items);
    }
  }

  List<Map<String, Object?>> _messages(String type, List<Map<String, Object?>> records) => [
    for (var i = 0; i < records.length; i += _perMessage)
      {'t': type, 'm': memberId, 'r': records.sublist(i, min(i + _perMessage, records.length))},
  ];

  Future<void> _sendHello() async {
    final mine = <Map<String, Object?>>[];
    if (memberId.isNotEmpty) {
      final me = await db.members.record(memberId).get(db.db);
      if (me != null) mine.add({'c': 'users', 'r': _shareable(me)});
    }
    await _send([
      {'t': 'hello', 'm': memberId, 'r': mine},
    ]);
  }

  Future<void> _sendSnapshot() async {
    final records = <Map<String, Object?>>[
      for (final c in relayShared)
        for (final s in await db.storeFor(c).find(db.db)) {'c': c, 'r': _shareable(s.value)},
    ];
    final messages = _messages('snapshot', records);
    if (messages.isEmpty) messages.add({'t': 'snapshot', 'm': memberId, 'r': const []});
    messages.last['last'] = true;
    await _send(messages);
  }

  Future<void> _flushOutbox() async {
    while (true) {
      final ops = await db.pendingOps();
      if (ops.isEmpty) return;
      final take = ops.take(_perMessage * _perRequest).toList();
      // only the latest version of each record matters
      final latest = <String, Map<String, Object?>>{};
      for (final op in take) {
        final c = op.value['collection'] as String;
        final r = Map<String, Object?>.from(op.value['body'] as Map);
        latest.remove('$c/${r['id']}');
        latest['$c/${r['id']}'] = {'c': c, 'r': r};
      }
      await _send(_messages('changes', latest.values.toList()));
      for (final op in take) {
        await db.removeOp(op.key);
      }
    }
  }

  /// Fetches, applies and acknowledges (= deletes on the server) everything
  /// waiting for this phone. Returns whether any record changed.
  Future<bool> _pull() async {
    var cursor = await db.getSetting<int>(cursorKey) ?? 0;
    var changed = false;
    while (true) {
      final batch = await transport.receive(cursor);
      for (final d in batch.items) {
        try {
          changed = await _handle(await keys.open(d.data, d.from)) || changed;
        } on RelayCryptoException {
          debugPrint('relay: dropped a message we cannot read');
        }
        cursor = d.seq;
      }
      if (batch.items.isNotEmpty) {
        await db.setSetting(cursorKey, cursor);
        await transport.ack(cursor);
      }
      if (!batch.more) return changed;
    }
  }

  Future<bool> _handle(Map<String, dynamic> message) async {
    final from = message['m'] as String? ?? '';
    if (from.isNotEmpty && from != memberId && from != partnerMember.value) {
      partnerMember.value = from;
      await db.setSetting(partnerKey, from);
    }
    final records = [
      for (final r in message['r'] as List? ?? const [])
        if (r is Map) Map<String, Object?>.from(r),
    ];
    final changed = await apply(records);
    if (message['t'] == 'hello') await db.setSetting(snapshotDueKey, true);
    return changed;
  }

  /// Merges records from the partner (newest version wins). Anything
  /// outside the shared collections is ignored.
  @visibleForTesting
  Future<bool> apply(List<Map<String, Object?>> items) async {
    var changed = false;
    await db.db.transaction((txn) async {
      for (final item in items) {
        final c = item['c'];
        final r = item['r'];
        if (c is! String || !relayShared.contains(c) || r is! Map) continue;
        final rec = Map<String, Object?>.from(r)..remove('_pending');
        final id = rec['id'];
        if (id is! String || id.isEmpty) continue;
        final record = db.storeFor(c).record(id);
        final existing = await record.get(txn);
        if (existing != null && !relayNewer(rec, existing)) continue;
        await record.put(txn, rec);
        changed = true;
      }
    });
    return changed;
  }
}
