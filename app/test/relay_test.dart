import 'dart:async';
import 'dart:io';

import 'package:couple_ledger/core/budget.dart';
import 'package:couple_ledger/data/local_db.dart';
import 'package:couple_ledger/data/models.dart';
import 'package:couple_ledger/data/native.dart';
import 'package:couple_ledger/data/offline.dart';
import 'package:couple_ledger/data/relay_client.dart';
import 'package:couple_ledger/data/relay_crypto.dart';
import 'package:couple_ledger/data/relay_sync.dart';
import 'package:couple_ledger/data/repository.dart';
import 'package:couple_ledger/data/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

/// In-memory stand-in for server/internal/relay: one copy per other device,
/// deleted on ack. Records every ciphertext it was handed.
class FakeRelay {
  final _rooms = <String, _Room>{};
  var _seq = 0;

  /// (sending device, ciphertext) of everything ever sent.
  final log = <(String, String)>[];

  RelayTransport connect(RelayKeys keys, String device) => _FakeTransport(this, keys, device);

  Set<String> devicesIn(RelayKeys keys) => _rooms[keys.roomId]?.queues.keys.toSet() ?? const {};
}

class _Room {
  _Room(this.auth);

  final String auth;
  final queues = <String, List<RelayDelivery>>{};
  final events = <String, StreamController<void>>{};
}

class _FakeTransport implements RelayTransport {
  _FakeTransport(this.relay, this.keys, this.device);

  final FakeRelay relay;
  final RelayKeys keys;
  final String device;

  _Room _room() {
    final room = relay._rooms[keys.roomId];
    if (room == null) throw const RelayException(404, 'room_not_found');
    if (room.auth != keys.authToken) throw const RelayException(401, 'unauthorized');
    if (!room.queues.containsKey(device)) throw const RelayException(403, 'not_joined');
    return room;
  }

  @override
  Future<bool> join({required bool create}) async {
    var room = relay._rooms[keys.roomId];
    if (room == null) {
      if (!create) throw const RelayException(404, 'room_not_found');
      room = relay._rooms[keys.roomId] = _Room(keys.authToken);
    }
    if (room.auth != keys.authToken) throw const RelayException(401, 'unauthorized');
    if (room.queues.containsKey(device)) return false;
    room.queues[device] = [];
    return true;
  }

  @override
  Future<void> send(List<String> items) async {
    final room = _room();
    final others = room.queues.keys.where((d) => d != device).toList();
    for (final item in items) {
      relay.log.add((device, item));
      for (final to in others) {
        room.queues[to]!.add(RelayDelivery(seq: ++relay._seq, from: device, data: item));
      }
    }
    for (final to in others) {
      room.events[to]?.add(null);
    }
  }

  @override
  Future<RelayBatch> receive(int after) async =>
      RelayBatch(_room().queues[device]!.where((d) => d.seq > after).toList(), more: false);

  @override
  Future<void> ack(int seq) async => _room().queues[device]!.removeWhere((d) => d.seq <= seq);

  @override
  Future<void> leave() async => relay._rooms[keys.roomId]?.queues.remove(device);

  @override
  Stream<void> events() {
    final room = _room();
    final c = room.events[device] = StreamController<void>.broadcast();
    scheduleMicrotask(() => c.add(null));
    return c.stream;
  }

  @override
  void close() {}
}

Future<AppServices> newPhone(FakeRelay relay) async {
  final db = LocalDb(await newDatabaseFactoryMemory().openDatabase('${DateTime.now().microsecondsSinceEpoch}.db'));
  final s = AppServices(
    env: AppEnv(native: NativeBridge(), platform: 'android', dir: Directory.systemTemp.path, caPem: null),
    mode: AppMode.relay,
    db: db,
  );
  s.relayUrl = 'https://relay.test';
  s.relayTransport = relay.connect;
  await s.init();
  s.relayUrl = 'https://relay.test';
  return s;
}

/// Lets every phone push and pull until nothing moves anymore.
Future<void> settle(List<AppServices> phones) async {
  for (var round = 0; round < 4; round++) {
    for (final p in phones) {
      await p.sync?.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
  for (final p in phones) {
    await p.localAlerts?.evaluate();
  }
}

Future<List<Entry>> entriesOf(AppServices s) async =>
    (await s.db.entries.find(s.db.db)).map((r) => Entry.fromJson(Map.of(r.value))).toList();

void main() {
  group('pairing code', () {
    test('round trips and tolerates formatting', () {
      for (var i = 0; i < 50; i++) {
        final secret = newPairingSecret();
        final code = formatPairingCode(secret);
        expect(code, matches(RegExp(r'^([0-9A-Z]{4}-){6}[0-9A-Z]{4}$')));
        expect(parsePairingCode(code), secret);
        expect(parsePairingCode(code.toLowerCase().replaceAll('-', ' ')), secret);
      }
    });

    test('catches typos', () {
      final code = formatPairingCode(newPairingSecret());
      var caught = 0;
      for (var i = 0; i < code.length; i++) {
        if (code[i] == '-') continue;
        final typo = code.replaceRange(i, i + 1, code[i] == 'A' ? 'B' : 'A');
        if (parsePairingCode(typo) == null) caught++;
      }
      // two check characters: an occasional typo may slip through
      expect(caught, greaterThanOrEqualTo(26));
      expect(parsePairingCode(code.substring(0, code.length - 1)), isNull);
    });
  });

  group('keys', () {
    test('both phones derive the same ids, nothing reveals the secret', () {
      final secret = newPairingSecret();
      final a = RelayKeys(secret);
      final b = RelayKeys(List.of(secret));
      expect(a.roomId, b.roomId);
      expect(a.authToken, b.authToken);
      expect(a.householdId, b.householdId);
      expect(a.roomId, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(a.authToken, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(a.householdId, matches(RegExp(r'^[0-9a-f]{15}$')));
      expect(RelayKeys(newPairingSecret()).roomId, isNot(a.roomId));
    });

    test('messages only open with the same key and sender', () async {
      final keys = RelayKeys(newPairingSecret());
      final sealed = await keys.seal({'t': 'changes', 'note': '只给你看'}, 'deviceA');
      expect(sealed, isNot(contains('只给你看')));
      expect((await keys.open(sealed, 'deviceA'))['note'], '只给你看');
      await expectLater(keys.open(sealed, 'deviceB'), throwsA(isA<RelayCryptoException>()));
      await expectLater(RelayKeys(newPairingSecret()).open(sealed, 'deviceA'), throwsA(isA<RelayCryptoException>()));
      await expectLater(keys.open('garbage', 'deviceA'), throwsA(isA<RelayCryptoException>()));
    });
  });

  test('newest version wins', () async {
    final db = LocalDb(await newDatabaseFactoryMemory().openDatabase('lww.db'));
    final sync = RelaySync(
      db: db,
      transport: FakeRelay().connect(RelayKeys(newPairingSecret()), 'x'),
      keys: RelayKeys(newPairingSecret()),
      deviceId: 'x',
      alerts: LocalAlerts(db, userId: 'me', householdId: 'h'),
    );
    Map<String, Object?> goal(String updated, int target, [String by = 'a']) => {
      'c': 'goals',
      'r': {'id': 'g1', 'savings_target': target, 'updated': updated, '_by': by},
    };
    await sync.apply([goal('2026-10-01T10:00:00.000Z', 1)]);
    await sync.apply([goal('2026-10-01T09:00:00.000Z', 2)]); // older: ignored
    expect((await db.goals.record('g1').get(db.db))!['savings_target'], 1);
    await sync.apply([goal('2026-10-01T10:00:00.000Z', 3, 'b')]); // same time: device id decides
    expect((await db.goals.record('g1').get(db.db))!['savings_target'], 3);
    // never accepted from the partner
    await sync.apply([
      {
        'c': 'entry_details',
        'r': {'id': 'e1', 'note': 'x'},
      },
      {
        'c': 'alerts',
        'r': {'id': 'a1'},
      },
    ]);
    expect(await db.notes.count(db.db), 0);
    expect(await db.alerts.count(db.db), 0);
  });

  group('two phones', () {
    late FakeRelay relay;
    late AppServices a;
    late AppServices b;

    setUp(() async {
      relay = FakeRelay();
      a = await newPhone(relay);
      expect(a.session.value.stage, SessionStage.needsPairing);
      await a.createPair(name: '小明', householdName: '我们的家');
      expect(a.session.value.stage, SessionStage.ready);

      b = await newPhone(relay);
      await b.joinPair(a.pairingCode!.toLowerCase(), name: '小红');
      expect(b.session.value.stage, SessionStage.ready);
      await settle([a, b]);
    });

    tearDown(() async {
      for (final p in [a, b]) {
        try {
          await p.close();
        } on Object {
          // already closed by the test
        }
      }
    });

    test('pairing shares the household and both members', () async {
      expect(a.householdId, b.householdId);
      for (final p in [a, b]) {
        expect(await p.db.members.count(p.db.db), 2);
        final home = await p.db.households.record(p.householdId).get(p.db.db);
        expect(home?['name'], '我们的家');
      }
      expect(b.pairingCode, a.pairingCode);
    });

    test('records sync both ways; private notes never leave the phone', () async {
      final day = '${Month.of(DateTime.now())}-01';
      await Repository(a).saveEntry(type: typeExpense, amount: 1200, category: '餐饮', occurredOn: day, note: '秘密礼物');
      await Repository(b).saveEntry(type: typeIncome, amount: 900000, category: '工资', occurredOn: day);
      await settle([a, b]);

      for (final p in [a, b]) {
        final all = await entriesOf(p);
        expect(all.map((e) => e.amount).toSet(), {1200, 900000});
      }
      expect(await a.db.notes.count(a.db.db), 1);
      expect(await b.db.notes.count(b.db.db), 0);

      final keys = RelayKeys(parsePairingCode(a.pairingCode!)!);
      expect(relay.log, isNotEmpty);
      for (final (from, data) in relay.log) {
        expect(data, isNot(contains('1200')));
        final clear = (await keys.open(data, from)).toString();
        expect(clear, isNot(contains('秘密礼物')));
        expect(clear, isNot(contains('entry_details')));
      }
    });

    test('delivered messages are gone from the relay', () async {
      await Repository(a).renameHousehold('新家');
      await settle([a, b]);
      final home = await b.db.households.record(b.householdId).get(b.db.db);
      expect(home?['name'], '新家');
      expect(relay._rooms.values.single.queues.values.every((q) => q.isEmpty), isTrue);
      expect(await a.db.outbox.count(a.db.db), 0);
    });

    test('edits and deletions of shared settings reach the partner', () async {
      final month = Month.of(DateTime.now());
      await Repository(a).saveGoal(start: month, end: month.add(1), incomePlan: {'*': 150000}, savingsTarget: 100000);
      await settle([a, b]);
      final goals = await b.db.watchGoals().first;
      expect(goals.single.savingsTarget, 100000);

      await Repository(
        b,
      ).saveGoal(id: goals.single.id, start: month, end: month.add(1), incomePlan: {'*': 150000}, savingsTarget: 80000);
      await settle([a, b]);
      expect((await a.db.watchGoals().first).single.savingsTarget, 80000);

      await Repository(a).deleteGoal(goals.single.id);
      final messages = await a.db.watchAlertMessages().first;
      await Repository(a).deleteAlertMessage(messages.first);
      await settle([a, b]);
      expect(await b.db.watchGoals().first, isEmpty);
      expect((await b.db.watchAlertMessages().first).length, messages.length - 1);
    });

    test('each phone raises budget alerts for its own member', () async {
      final month = Month.of(DateTime.now());
      await Repository(a).saveGoal(start: month, end: month.add(1), incomePlan: {'*': 150000}, savingsTarget: 100000);
      await Repository(a).saveEntry(type: typeExpense, amount: 85000, category: '餐饮', occurredOn: '$month-01');
      await settle([a, b]);
      for (final p in [a, b]) {
        final alerts = (await p.db.alerts.find(p.db.db)).map((r) => r.value).toList();
        expect(alerts.map((x) => x['kind']), [levelMonth80]);
        expect(alerts.single['recipient'], p.userId);
      }
    });

    test('a reinstalled phone gets its records back from the partner', () async {
      final day = '${Month.of(DateTime.now())}-02';
      await Repository(b).saveEntry(type: typeExpense, amount: 3300, category: '交通', occurredOn: day, note: '打车');
      await settle([a, b]);
      final oldMember = b.userId;
      final code = b.pairingCode!;
      await b.close(); // lost the phone: never says goodbye

      final c = await newPhone(relay);
      await c.joinPair(code);
      expect(c.session.value.stage, SessionStage.restoring);
      await settle([a, c]);
      expect(c.relay!.partnerMember.value, a.userId);
      await c.adoptMember(oldMember);
      expect(c.session.value.stage, SessionStage.ready);

      final mine = (await entriesOf(c)).where((e) => e.owner == oldMember).toList();
      expect(mine.single.amount, 3300);
      // the note was only on the lost phone
      expect(await c.db.notes.count(c.db.db), 0);
      await c.close();
    });

    test('a phone the relay forgot asks for everything again', () async {
      final keys = RelayKeys(parsePairingCode(a.pairingCode!)!);
      // b stayed away so long that the server dropped it, and with it what
      // was waiting for it
      relay._rooms[keys.roomId]!.queues.remove(b.relay!.deviceId);
      await Repository(a).saveEntry(type: typeExpense, amount: 4200, category: '日用', occurredOn: '2026-10-05');
      await settle([a]);
      expect(await b.db.entries.count(b.db.db), 0);

      await settle([b, a]);
      expect((await entriesOf(b)).single.amount, 4200);
      expect(b.relay!.status.value.lastError, isNull);
    });

    test('unpairing leaves the room and clears the phone', () async {
      final keys = RelayKeys(parsePairingCode(a.pairingCode!)!);
      await b.unpair();
      expect(b.session.value.stage, SessionStage.needsPairing);
      expect(b.pairingCode, isNull);
      expect(await b.db.entries.count(b.db.db), 0);
      expect(await b.db.members.count(b.db.db), 0);
      expect(relay.devicesIn(keys), hasLength(1));
    });
  });

  test('joining checks the code before touching the relay', () async {
    final relay = FakeRelay();
    final phone = await newPhone(relay);
    await expectLater(phone.joinPair('ABCD'), throwsA(isA<PairingCodeException>()));
    // well-formed but nobody created it
    await expectLater(
      phone.joinPair(formatPairingCode(newPairingSecret()), name: '小红'),
      throwsA(isA<RelayException>().having((e) => e.code, 'code', 'room_not_found')),
    );
    expect(phone.session.value.stage, SessionStage.needsPairing);
    await phone.close();
  });
}
