import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sembast/sembast_io.dart';

import '../core/ids.dart';
import 'api.dart';
import 'local_db.dart';
import 'native.dart';
import 'offline.dart';
import 'relay_client.dart';
import 'relay_crypto.dart';
import 'relay_sync.dart';
import 'sync.dart';

/// Server address baked in by a build for one particular server:
///   flutter build apk --dart-define=LEDGER_SERVER=https://1.2.3.4:8443
/// The public build leaves it empty; its users try the app offline or enter
/// the address of a server they deployed themselves.
const bakedServerUrl = String.fromEnvironment('LEDGER_SERVER');
const isPublicBuild = bakedServerUrl == '';

/// Relay server of the author, baked into the public build:
///   --dart-define=LEDGER_RELAY=https://1.2.3.4:8443
/// Empty: relay mode is not offered.
const bakedRelayUrl = String.fromEnvironment('LEDGER_RELAY');

/// How this phone keeps its data:
/// - [offline]: trial, data stays on the phone, the partner is simulated;
/// - [relay]: data on both phones only, end-to-end encrypted through the
///   author's relay server, which cannot read it;
/// - [online]: the couple's own server.
enum AppMode { online, offline, relay }

/// Platform facts shared by every [AppServices] instance.
class AppEnv {
  const AppEnv({required this.native, required this.platform, required this.dir, required this.caPem, this.relayCaPem});

  final NativeBridge native;

  /// "android" or "ohos"
  final String platform;

  /// App-private directory for the local databases.
  final String dir;

  /// Root CA baked into the app, if any.
  final String? caPem;

  /// Root CA of the default relay server (public build), trusted for the
  /// relay connection only.
  final String? relayCaPem;

  File get _modeFile => File('$dir/app_mode');

  /// A build for one particular server always uses it.
  Future<AppMode> readMode() async {
    if (!isPublicBuild) return AppMode.online;
    try {
      final name = (await _modeFile.readAsString()).trim();
      return AppMode.values.where((m) => m.name == name).firstOrNull ?? AppMode.online;
    } on FileSystemException {
      return AppMode.online;
    }
  }

  Future<void> writeMode(AppMode mode) => _modeFile.writeAsString(mode.name);
}

enum SessionStage {
  needsServer,
  loggedOut,
  needsHousehold,

  /// Relay mode: create a pairing or enter the partner's code.
  needsPairing,

  /// Relay mode: a reinstalled phone waits for its data and picks who it is.
  restoring,
  ready,
}

class Session {
  const Session(this.stage, {this.userId = '', this.householdId = ''});

  final SessionStage stage;
  final String userId;
  final String householdId;
}

/// Owns the API client, the local cache and the sync engine, and drives the
/// server → login → household → ready lifecycle.
class AppServices {
  AppServices({required this.env, required this.mode, required this.db});

  /// Opens the local database of the current mode and restores the session.
  static Future<AppServices> open(AppEnv env) async {
    final mode = await env.readMode();
    // each mode has its own data, so trial data never mixes with a real account
    final file = switch (mode) {
      AppMode.offline => 'ledger-offline.db',
      AppMode.relay => 'ledger-relay.db',
      AppMode.online => 'ledger.db',
    };
    final services = AppServices(
      env: env,
      mode: mode,
      db: LocalDb(await databaseFactoryIo.openDatabase('${env.dir}/$file')),
    );
    await services.init();
    return services;
  }

  final AppEnv env;
  final AppMode mode;
  final LocalDb db;

  NativeBridge get native => env.native;
  String? get caPem => env.caPem;
  String get platform => env.platform;

  late PocketBase pb;
  late String serverUrl;

  /// Certificates of [serverUrl] the user confirmed by fingerprint (PEM).
  List<String> pins = const [];
  SyncEngine? sync;

  /// Set in the offline trial, which never talks to a server.
  OfflineBackend? offline;

  /// Set in relay mode once paired (also available as [sync]).
  RelaySync? relay;
  String relayUrl = '';
  List<int>? _relaySecret;

  /// Creates the connection to the relay server; replaced in tests.
  late RelayTransport Function(RelayKeys keys, String device) relayTransport = (keys, device) =>
      RelayClient(baseUrl: relayUrl, keys: keys, device: device, caPem: env.relayCaPem);

  /// Budget alerts evaluated on this phone (offline trial and relay mode).
  LocalAlerts? get localAlerts => offline ?? relay?.alerts;

  /// Writes land in the local database first and need no server round trip.
  bool get isLocalFirst => mode != AppMode.online;

  final session = ValueNotifier(const Session(SessionStage.loggedOut));
  final _syncChanged = StreamController<SyncEngine?>.broadcast();
  Stream<SyncEngine?> get syncChanges => _syncChanged.stream;

  bool get isAndroid => platform == 'android';
  bool get isHarmony => platform == 'ohos';

  String get userId => switch (mode) {
    AppMode.offline => offlineUserId,
    AppMode.relay => relay?.memberId ?? '',
    AppMode.online => pb.authStore.record?.id ?? '',
  };

  String get householdId => switch (mode) {
    AppMode.offline => offlineHouseholdId,
    AppMode.relay => relay?.keys.householdId ?? '',
    AppMode.online => pb.authStore.record?.getStringValue('household') ?? '',
  };

  Future<void> init() async {
    if (mode == AppMode.relay) return _initRelay();
    if (mode == AppMode.offline) {
      serverUrl = '';
      pb = PocketBase('http://127.0.0.1');
      offline = OfflineBackend(db);
      await offline!.ensureSeeded();
      session.value = const Session(SessionStage.ready, userId: offlineUserId, householdId: offlineHouseholdId);
      return;
    }

    serverUrl = await db.getSetting<String>('server_url') ?? bakedServerUrl;
    pins = List.of((await db.getSetting<List>('server_pins') ?? const []).cast<String>());
    final authStore = AsyncAuthStore(
      initial: await db.getSetting<String>('auth'),
      save: (data) => db.setSetting('auth', data),
      clear: () => db.setSetting('auth', null),
    );
    // until the public build has a server, the client is never used
    pb = createClient(
      serverUrl.isEmpty ? 'https://127.0.0.1' : serverUrl,
      authStore: authStore,
      caPem: caPem,
      pins: pins,
    );

    if (serverUrl.isEmpty) {
      session.value = const Session(SessionStage.needsServer);
      return;
    }
    if (!pb.authStore.isValid) {
      session.value = const Session(SessionStage.loggedOut);
      return;
    }

    // refresh in the background; work offline with the cached record meanwhile
    _updateSession();
    unawaited(_refreshAuth());
  }

  Future<void> _refreshAuth() async {
    try {
      await pb.collection('users').authRefresh();
      _updateSession();
    } on ClientException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 404) await logout();
    }
  }

  void _updateSession() {
    final Session next;
    if (!pb.authStore.isValid) {
      next = const Session(SessionStage.loggedOut);
    } else if (householdId.isEmpty) {
      next = Session(SessionStage.needsHousehold, userId: userId);
    } else {
      next = Session(SessionStage.ready, userId: userId, householdId: householdId);
    }
    final prev = session.value;
    session.value = next;
    if (next.stage == SessionStage.ready && prev.stage != SessionStage.ready) {
      unawaited(_startSync());
    }
  }

  Future<void> _startSync() async {
    await sync?.dispose();
    final s = SyncService(pb: pb, db: db);
    sync = s;
    _syncChanged.add(s);
    await s.start();
    unawaited(registerDevice());
  }

  Future<void> _stopSync() async {
    await sync?.dispose();
    sync = null;
    _syncChanged.add(null);
  }

  // ---------------------------------------------------------------------------
  // account

  Future<void> login(String username, String password) async {
    await pb.collection('users').authWithPassword(username.trim().toLowerCase(), password);
    _updateSession();
  }

  Future<void> register({required String username, required String password, required String name}) async {
    final u = username.trim().toLowerCase();
    await pb
        .collection('users')
        .create(body: {'username': u, 'name': name.trim(), 'password': password, 'passwordConfirm': password});
    await login(u, password);
  }

  Future<void> createHousehold(String name) async {
    await pb.send('/api/ledger/household', method: 'POST', body: {'name': name});
    await pb.collection('users').authRefresh();
    _updateSession();
  }

  Future<void> joinHousehold(String code) async {
    await pb.send('/api/ledger/household/join', method: 'POST', body: {'code': code.trim()});
    await pb.collection('users').authRefresh();
    _updateSession();
  }

  Future<void> logout() async {
    if (offline != null) return offline!.reset();
    if (mode == AppMode.relay) return unpair();
    await _stopSync();
    if (isAndroid) await native.stopAlertService();
    pb.authStore.clear();
    await db.clearAccountData();
    session.value = const Session(SessionStage.loggedOut);
  }

  /// Points the app at a server: the first one, or a new address after a
  /// migration (the account and its token stay valid because the data moved
  /// with the server). [trust] are certificates the user just confirmed by
  /// fingerprint. Throws [UntrustedCertificateException] when the server's
  /// certificate needs that confirmation first.
  Future<void> changeServer(String url, {List<String> trust = const []}) async {
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    // confirmed certificates only count for the address they were confirmed for
    final candidates = {if (normalized == serverUrl) ...pins, ...trust}.toList();
    final used = await probeServer(normalized, caPem: caPem, pins: candidates);
    // drop certificates the server no longer presents (e.g. after re-issuing)
    final kept = candidates.where((p) => used.contains(pemSha256(p))).toList();

    await _stopSync();
    await db.setSetting('server_url', normalized);
    await db.setSetting('server_pins', kept.isEmpty ? null : kept);
    serverUrl = normalized;
    pins = kept;
    pb = createClient(normalized, authStore: pb.authStore, caPem: caPem, pins: pins);
    session.value = const Session(SessionStage.loggedOut);
    _updateSession();
  }

  /// Releases the database and connections before the app switches mode.
  Future<void> close() async {
    await _stopSync();
    relay = null;
    await offline?.dispose();
    await _syncChanged.close();
    await db.db.close();
  }

  // ---------------------------------------------------------------------------
  // relay mode

  static const _relayUrlKey = 'relay:url';
  static const _relaySecretKey = 'relay:secret';
  static const _relayDeviceKey = 'relay:device';
  static const _relayMemberKey = 'relay:member';

  /// The code the partner enters to pair (relay mode).
  String? get pairingCode => _relaySecret == null ? null : formatPairingCode(_relaySecret!);

  static String _now() => DateTime.now().toUtc().toIso8601String();

  Future<void> _initRelay() async {
    serverUrl = '';
    pb = PocketBase('http://127.0.0.1');
    // the address baked into this build wins, so a new release can move the
    // relay to another server; the pairing works there unchanged
    relayUrl = bakedRelayUrl.isNotEmpty ? bakedRelayUrl : await db.getSetting<String>(_relayUrlKey) ?? '';
    final secret = await db.getSetting<String>(_relaySecretKey);
    final device = await db.getSetting<String>(_relayDeviceKey);
    if (secret == null || device == null || relayUrl.isEmpty) {
      session.value = const Session(SessionStage.needsPairing);
      return;
    }
    _startRelay(base64.decode(secret), device, await db.getSetting<String>(_relayMemberKey) ?? '');
  }

  void _startRelay(List<int> secret, String device, String member) {
    final keys = RelayKeys(secret);
    _relaySecret = secret;
    final r = relay = RelaySync(
      db: db,
      transport: relayTransport(keys, device),
      keys: keys,
      deviceId: device,
      alerts: LocalAlerts(db, userId: member, householdId: keys.householdId),
    );
    sync = r;
    _syncChanged.add(r);
    _updateRelaySession();
    unawaited(r.start());
  }

  void _updateRelaySession() {
    final r = relay;
    if (r == null) {
      session.value = const Session(SessionStage.needsPairing);
    } else if (r.memberId.isEmpty) {
      session.value = Session(SessionStage.restoring, householdId: r.keys.householdId);
    } else {
      session.value = Session(SessionStage.ready, userId: r.memberId, householdId: r.keys.householdId);
    }
  }

  Future<void> _saveRelay(List<int> secret, String device, String member) async {
    await db.setSetting(_relayUrlKey, relayUrl);
    await db.setSetting(_relaySecretKey, base64.encode(secret));
    await db.setSetting(_relayDeviceKey, device);
    await db.setSetting(_relayMemberKey, member.isEmpty ? null : member);
  }

  Map<String, Object?> _memberRecord(String id, String name, String householdId, String device) => {
    'id': id,
    'username': '',
    'name': name.trim(),
    'color': '',
    'household': householdId,
    'created': _now(),
    'updated': _now(),
    '_by': device,
  };

  /// Relay mode: opens a new room on the relay server for this couple.
  /// Show [pairingCode] to the partner afterwards.
  Future<void> createPair({required String name, required String householdName}) async {
    final secret = newPairingSecret();
    final keys = RelayKeys(secret);
    final device = newDeviceId();
    final probe = relayTransport(keys, device);
    try {
      await probe.join(create: true);
    } finally {
      probe.close();
    }
    final member = newRecordId();
    await db.putLocal('households', {
      'id': keys.householdId,
      'name': householdName.trim(),
      'invite_code': '',
      'created': _now(),
      'updated': _now(),
      '_by': device,
    });
    await db.putLocal('users', _memberRecord(member, name, keys.householdId, device));
    await seedDefaultAlertMessages(db, keys.householdId);
    await _saveRelay(secret, device, member);
    _startRelay(secret, device, member);
  }

  /// Relay mode: joins the partner's room. Without [name] the phone restores
  /// an existing member (reinstalled app): it waits for the partner's data
  /// and then [adoptMember] picks who this is.
  Future<void> joinPair(String code, {String? name}) async {
    final secret = parsePairingCode(code);
    if (secret == null) throw const PairingCodeException();
    final keys = RelayKeys(secret);
    final device = newDeviceId();
    final probe = relayTransport(keys, device);
    try {
      // a typo that still passes the check must not open an empty room
      await probe.join(create: false);
    } finally {
      probe.close();
    }
    final member = name == null ? '' : newRecordId();
    if (name != null) await db.putLocal('users', _memberRecord(member, name, keys.householdId, device));
    await seedDefaultAlertMessages(db, keys.householdId);
    await _saveRelay(secret, device, member);
    _startRelay(secret, device, member);
  }

  /// Relay mode, restoring: this phone continues as member [id].
  Future<void> adoptMember(String id) async {
    final r = relay;
    if (r == null) return;
    await db.setSetting(_relayMemberKey, id);
    r.alerts.userId = id;
    _updateRelaySession();
    unawaited(r.syncNow());
  }

  /// Relay mode, restoring: nothing to restore, join as a new member.
  Future<void> joinAsNewMember(String name) async {
    final r = relay;
    if (r == null) return;
    final record = _memberRecord(newRecordId(), name, r.keys.householdId, r.deviceId);
    await db.putLocal('users', record);
    await r.publish('users', record);
    await adoptMember(record['id']! as String);
  }

  /// Relay mode: leaves the room and deletes this phone's data. The
  /// partner's phone keeps its copy.
  Future<void> unpair() async {
    await relay?.leave();
    await _stopSync();
    relay = null;
    _relaySecret = null;
    await db.clearAccountData();
    session.value = const Session(SessionStage.needsPairing);
  }

  // ---------------------------------------------------------------------------
  // background alerts

  /// Android: keeps a long-lived connection for alerts.
  /// HarmonyOS: registers the Push Kit token with the server.
  Future<void> registerDevice() async {
    if (mode != AppMode.online || session.value.stage != SessionStage.ready) return;
    if (isAndroid) {
      final enabled = await db.getSetting<bool>('bg_alerts') ?? true;
      if (enabled) {
        // the service trusts these as well as the system CAs
        final trusted = [?caPem, ...pins].where((p) => p.trim().isNotEmpty).join('\n');
        await native.startAlertService(baseUrl: serverUrl, token: pb.authStore.token, userId: userId, caPem: trusted);
      }
      return;
    }
    if (!isHarmony) return;

    final token = await native.pushToken();
    if (token == null || token.isEmpty) return;
    try {
      final version = await native.appVersion();
      final existing = await pb.collection('devices').getFullList();
      final match = existing.where((d) => d.getStringValue('push_token') == token).firstOrNull;
      if (match == null) {
        await pb
            .collection('devices')
            .create(body: {'user': userId, 'platform': 'harmony', 'push_token': token, 'app_version': version});
      } else if (match.getStringValue('app_version') != version) {
        await pb.collection('devices').update(match.id, body: {'app_version': version});
      }
    } on ClientException catch (e) {
      debugPrint('register device failed: ${describeError(e)}');
    }
  }

  Future<void> setBackgroundAlerts(bool enabled) async {
    await db.setSetting('bg_alerts', enabled);
    if (!isAndroid || mode != AppMode.online) return;
    if (enabled) {
      await registerDevice();
    } else {
      await native.stopAlertService();
    }
  }
}
