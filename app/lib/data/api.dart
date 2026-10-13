import 'dart:convert';
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:pocketbase/pocketbase.dart';

/// Creates the PocketBase client. Besides the system roots it trusts our
/// own root CA, so a self-signed server reachable by IP works securely.
PocketBase createClient(String baseUrl, {required AuthStore authStore, String? caPem}) {
  return PocketBase(
    baseUrl,
    lang: 'zh-CN',
    authStore: authStore,
    httpClientFactory: () => IOClient(createHttpClient(caPem)),
  );
}

HttpClient createHttpClient(String? caPem) {
  final ctx = SecurityContext(withTrustedRoots: true);
  if (caPem != null && caPem.trim().isNotEmpty) {
    ctx.setTrustedCertificatesBytes(utf8.encode(caPem));
  }
  return HttpClient(context: ctx)
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);
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
  if (e is! ClientException) return '出错了：$e';
  if (e.statusCode == 0) {
    final original = e.originalError;
    if (original is HandshakeException || original is TlsException) {
      return '服务器证书校验失败，请确认服务器地址是否正确';
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
