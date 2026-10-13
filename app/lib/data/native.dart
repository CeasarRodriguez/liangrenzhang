import 'dart:io';

import 'package:flutter/services.dart';

/// Thin bridge to the platform code (Kotlin on Android, ArkTS on HarmonyOS).
/// We avoid third-party plugins so the same Dart code runs on both.
class NativeBridge {
  static const _channel = MethodChannel('couple_ledger/native');

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// "android" or "ohos".
  Future<String> platform() async {
    final p = await _call<String>('platform');
    if (p != null) return p;
    return Platform.operatingSystem;
  }

  /// App-private directory for the local database.
  Future<String> filesDir() async {
    final dir = await _call<String>('filesDir');
    if (dir == null) throw StateError('filesDir unavailable');
    return dir;
  }

  Future<String> appVersion() async => await _call<String>('appVersion') ?? '';

  Future<bool> requestNotificationPermission() async => await _call<bool>('requestNotificationPermission') ?? false;

  Future<bool> notificationsEnabled() async => await _call<bool>('notificationsEnabled') ?? false;

  // ---- Android: long-lived alert connection -------------------------------

  Future<void> startAlertService({
    required String baseUrl,
    required String token,
    required String userId,
    String? caPem,
  }) => _call<void>('startAlertService', {'baseUrl': baseUrl, 'token': token, 'userId': userId, 'caPem': caPem ?? ''});

  Future<void> stopAlertService() => _call<void>('stopAlertService');

  Future<bool> isIgnoringBatteryOptimizations() async => await _call<bool>('isIgnoringBatteryOptimizations') ?? false;

  Future<void> requestIgnoreBatteryOptimizations() => _call<void>('requestIgnoreBatteryOptimizations');

  Future<void> openAppSettings() => _call<void>('openAppSettings');

  // ---- HarmonyOS: Push Kit ------------------------------------------------

  Future<String?> pushToken() => _call<String>('pushToken');
}
