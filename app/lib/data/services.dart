import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import 'api.dart';
import 'local_db.dart';
import 'native.dart';
import 'offline.dart';
import 'sync.dart';

/// Server address baked in at build time:
///   flutter build apk --dart-define=LEDGER_SERVER=https://1.2.3.4:8443
const defaultServerUrl = String.fromEnvironment('LEDGER_SERVER', defaultValue: 'https://127.0.0.1:8443');

enum SessionStage { loggedOut, needsHousehold, ready }

class Session {
  const Session(this.stage, {this.userId = '', this.householdId = ''});

  final SessionStage stage;
  final String userId;
  final String householdId;
}

/// Owns the API client, the local cache and the sync engine, and drives the
/// login → household → ready lifecycle.
class AppServices {
  AppServices({required this.db, required this.native, required this.caPem, required this.platform});

  final LocalDb db;
  final NativeBridge native;
  final String? caPem;

  /// "android" or "ohos"
  final String platform;

  late PocketBase pb;
  late String serverUrl;
  SyncService? sync;

  /// Set in the offline trial build, which never talks to a server.
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
    if (offlineMode) {
      serverUrl = '';
      pb = PocketBase('http://127.0.0.1');
      offline = OfflineBackend(db);
      await offline!.ensureSeeded();
      session.value = const Session(SessionStage.ready, userId: offlineUserId, householdId: offlineHouseholdId);
      return;
    }

    serverUrl = await db.getSetting<String>('server_url') ?? defaultServerUrl;
    final authStore = AsyncAuthStore(
      initial: await db.getSetting<String>('auth'),
      save: (data) => db.setSetting('auth', data),
      clear: () => db.setSetting('auth', null),
    );
    pb = createClient(serverUrl, authStore: authStore, caPem: caPem);

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

  /// Points the app at another server (e.g. after a migration). The account
  /// and its token stay valid because the data moved with the server.
  Future<void> changeServer(String url) async {
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    final probe = createClient(normalized, authStore: AuthStore(), caPem: caPem);
    await probe.health.check();

    await _stopSync();
    await db.setSetting('server_url', normalized);
    serverUrl = normalized;
    pb = createClient(normalized, authStore: pb.authStore, caPem: caPem);
    session.value = const Session(SessionStage.loggedOut);
    _updateSession();
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
        await native.startAlertService(baseUrl: serverUrl, token: pb.authStore.token, userId: userId, caPem: caPem);
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
