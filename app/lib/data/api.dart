import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/io_client.dart';
import 'package:pocketbase/pocketbase.dart';

/// Creates the PocketBase client. Besides the system roots it trusts our
/// own root CA, so a self-signed server reachable by IP works securely, and
/// the certificates the user confirmed by fingerprint ([pins], PEM).
PocketBase createClient(String baseUrl, {required AuthStore authStore, String? caPem, List<String> pins = const []}) {
  return PocketBase(
    baseUrl,
    lang: 'zh-CN',
    authStore: authStore,
    httpClientFactory: () => IOClient(createHttpClient(caPem, pins: pins)),
  );
}

HttpClient createHttpClient(String? caPem, {List<String> pins = const []}) {
  final ctx = SecurityContext(withTrustedRoots: true);
  if (caPem != null && caPem.trim().isNotEmpty) {
    ctx.setTrustedCertificatesBytes(utf8.encode(caPem));
  }
  final client = HttpClient(context: ctx)
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);
  if (pins.isNotEmpty) {
    final pinned = pins.map(pemSha256).toSet();
    // only called when normal verification fails
    client.badCertificateCallback = (cert, host, port) => pinned.contains(certSha256(cert));
  }
  return client;
}

/// SHA-256 of the certificate's DER encoding, lowercase hex.
String certSha256(X509Certificate cert) => sha256.convert(cert.der).toString();

String pemSha256(String pem) {
  final body = pem.replaceAll(RegExp(r'-----(BEGIN|END) CERTIFICATE-----'), '').replaceAll(RegExp(r'\s'), '');
  return sha256.convert(base64.decode(body)).toString();
}

/// `AB:CD:…` – the format `openssl x509 -fingerprint -sha256` prints.
String formatFingerprint(String hex) {
  final pairs = <String>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    pairs.add(hex.substring(i, i + 2).toUpperCase());
  }
  return pairs.join(':');
}

/// The server presented a certificate nobody vouches for yet; the user can
/// compare [fingerprints] with the server and pin [pems].
class UntrustedCertificateException implements Exception {
  UntrustedCertificateException(this.pems, {required this.changed});

  final List<String> pems;

  /// A different certificate was trusted for this server before.
  final bool changed;

  List<String> get fingerprints => pems.map((p) => formatFingerprint(pemSha256(p))).toList();
}

/// The address answered, but not like a 两人账 server.
class NotLedgerServerException implements Exception {
  NotLedgerServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Checks that [baseUrl] is a reachable 两人账 server whose certificate we
/// trust. Returns the SHA-256 of the pinned certificates the server needed
/// (none when a CA vouches for it). Throws [UntrustedCertificateException]
/// with the certificates seen when the only problem is an unknown certificate.
Future<Set<String>> probeServer(String baseUrl, {String? caPem, List<String> pins = const []}) async {
  final pinned = pins.map(pemSha256).toSet();
  final seen = <String, String>{}; // sha256 -> pem, in the order presented
  final client = createHttpClient(caPem)
    ..badCertificateCallback = (cert, host, port) {
      final sha = certSha256(cert);
      seen.putIfAbsent(sha, () => cert.pem);
      return pinned.contains(sha);
    };
  try {
    final req = await client.getUrl(Uri.parse('$baseUrl/api/health')).timeout(const Duration(seconds: 15));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200 || !body.contains('healthy')) {
      throw NotLedgerServerException('这个地址不是两人账服务器（HTTP ${res.statusCode}）');
    }
    return seen.keys.where(pinned.contains).toSet();
  } on HandshakeException {
    final unknown = seen.entries.where((e) => !pinned.contains(e.key)).map((e) => e.value).toList();
    if (unknown.isNotEmpty) throw UntrustedCertificateException(unknown, changed: pinned.isNotEmpty);
    rethrow;
  } finally {
    client.close(force: true);
  }
}

/// No HTTP response at all. The SDK reports dropped connections as
/// `isAbort` too (we never cancel requests), so that counts as offline.
bool isNetworkError(Object e) => e is ClientException && e.statusCode == 0;

const _fieldNames = {
  'username': '用户名',
  'password': '密码',
  'passwordConfirm': '确认密码',
  'name': '昵称',
  'amount': '金额',
  'category': '分类',
  'occurred_on': '日期',
  'start_month': '开始月份',
  'end_month': '结束月份',
  'text': '文案',
  'note': '备注',
};

const _codeMessages = {
  'validation_not_unique': '已经被占用了',
  'validation_required': '不能为空',
  'validation_min_text_constraint': '太短了',
  'validation_max_text_constraint': '太长了',
  'validation_invalid_format': '格式不对',
  'validation_values_mismatch': '两次输入不一致',
  'validation_length_out_of_range': '长度不对',
};

/// Turns any error into a short Chinese message for the UI.
String describeError(Object e) {
  if (e is NotLedgerServerException) return e.message;
  if (e is HandshakeException || e is TlsException) return '和服务器的加密连接失败，请检查地址是否正确';
  if (e is SocketException || e is TimeoutException) return '连不上服务器，请检查地址、端口和网络';
  if (e is! ClientException) return '出错了：$e';
  if (e.statusCode == 0) {
    final original = e.originalError;
    if (original is HandshakeException || original is TlsException) {
      return '服务器证书校验失败。如果服务器换过证书，请到「我的 → 服务器地址」重新确认';
    }
    return '连不上服务器，请检查网络或服务器地址';
  }

  final data = e.response['data'];
  if (data is Map && data.isNotEmpty) {
    final entry = data.entries.first;
    final field = _fieldNames[entry.key] ?? entry.key;
    final detail = entry.value;
    if (detail is Map) {
      final code = detail['code'] as String? ?? '';
      final msg = _codeMessages[code] ?? (detail['message'] as String? ?? '').replaceAll(RegExp(r'\.$'), '');
      return '$field$msg';
    }
  }

  final message = (e.response['message'] as String? ?? '').replaceAll(RegExp(r'\.$'), '');
  if (e.statusCode == 400 && message.startsWith('Failed to authenticate')) return '用户名或密码不对';
  if (e.statusCode == 401) return '登录已过期，请重新登录';
  if (e.statusCode == 429) return '操作太频繁了，请稍后再试';
  if (message.isNotEmpty && RegExp(r'[一-龥]').hasMatch(message)) return message;
  return '请求失败（${e.statusCode}）';
}
