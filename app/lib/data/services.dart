import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sembast/sembast_io.dart';

import 'api.dart';
import 'local_db.dart';
import 'native.dart';
import 'offline.dart';
import 'sync.dart';

/// Server address baked in by a build for one particular server:
///   flutter build apk --dart-define=LEDGER_SERVER=https://1.2.3.4:8443
/// The public build leaves it empty; its users try the app offline or enter
/// the address of a server they deployed themselves.
const bakedServerUrl = String.fromEnvironment('LEDGER_SERVER');
const isPublicBuild = bakedServerUrl == '';

/// Offline trial (data stays on the phone, simulated partner) or a server.
enum AppMode { online, offline }

/// Platform facts shared by every [AppServices] instance.
class AppEnv {
  const AppEnv({required this.native, required this.platform, required this.dir, required this.caPem});

  final NativeBridge native;

  /// "android" or "ohos"
  final String platform;

  /// App-private directory for the local databases.
  final String dir;

  /// Root CA baked into the app, if any.
  final String? caPem;

  File get _modeFile => File('$dir/app_mode');

  /// A build for one particular server always uses it.
  Future<AppMode> readMode() async {
    if (!isPublicBuild) return AppMode.online;
    try {
      return (await _modeFile.readAsString()).trim() == AppMode.offline.name ? AppMode.offline : AppMode.online;
    } on FileSystemException {
      return AppMode.online;
    }
  }

  Future<void> writeMode(AppMode mode) => _modeFile.writeAsString(mode.name);
}

enum SessionStage { needsServer, loggedOut, needsHousehold, ready }

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
    // trial data is kept apart so it never mixes with a real account
    final file = mode == AppMode.offline ? 'ledger-offline.db' : 'ledger.db';
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
  SyncService? sync;

  /// Set in the offline trial, which never talks to a server.
  OfflineBackend? offline;

  final session = ValueNotifier(const Session(SessionStage.loggedOut));
  final _syncChanged = StreamController<SyncService?>.broadcast();
  Stream<SyncService?> get syncChanges => _syncChanged.stream;

  bool get isAndroid => platform == 'android';
  bool get isHarmony => platform == 'ohos';

  String get userId => offline != null ? offlineUserId : pb.authStore.record?.id ?? '';
  String get householdId =>
      offline != null ? offlineHouseholdId : pb.authStore.record?.getStringValue('household') ?? '';

  Future<void> init() async {
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
    sync = SyncService(pb: pb, db: db);
    _syncChanged.add(sync);
    await sync!.start();
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
    await offline?.dispose();
    await _syncChanged.close();
    await db.db.close();
  }

  // ---------------------------------------------------------------------------
  // background alerts

  /// Android: keeps a long-lived connection for alerts.
  /// HarmonyOS: registers the Push Kit token with the server.
  Future<void> registerDevice() async {
    if (offline != null || session.value.stage != SessionStage.ready) return;
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
    if (!isAndroid) return;
    if (enabled) {
      await registerDevice();
    } else {
      await native.stopAlertService();
    }
  }
}
