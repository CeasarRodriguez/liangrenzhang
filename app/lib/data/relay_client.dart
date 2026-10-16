import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';
import 'relay_crypto.dart';

/// The relay server refused a request (see server/internal/relay).
class RelayException implements Exception {
  const RelayException(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => switch (code) {
    'room_not_found' => '配对码不对，或者对方已经解除了配对',
    'unauthorized' => '配对码不对',
    'room_full' => '这个配对码已经有 4 台手机在用了。先在不用的手机上解除配对，或等 30 天后再试',
    'storage_full' => '对方很久没打开 App，转发服务器上待送达的数据满了。请让对方打开一次 App',
    'rate_limited' => '操作太频繁了，请稍后再试',
    'too_large' => '一次发送的数据太多了',
    _ => '转发服务器出错了（$status）',
  };
}

class RelayDelivery {
  const RelayDelivery({required this.seq, required this.from, required this.data});

  final int seq;

  /// Sending device.
  final String from;

  /// Ciphertext (see [RelayKeys.seal]).
  final String data;
}

class RelayBatch {
  const RelayBatch(this.items, {required this.more});

  final List<RelayDelivery> items;
  final bool more;
}

/// What [RelaySync] needs from the relay server; faked in tests.
abstract class RelayTransport {
  /// Registers this device in the room. With [create] the room is created
  /// if needed; otherwise a missing room is a `room_not_found` error.
  /// Returns whether the device was not registered before (new, or dropped
  /// by the server after a long absence and so missing messages).
  Future<bool> join({required bool create});

  /// Queues ciphertexts for every other device (nobody there yet: nothing
  /// is kept).
  Future<void> send(List<String> items);

  Future<RelayBatch> receive(int after);

  /// Deletes everything up to [seq] that was delivered to this device.
  Future<void> ack(int seq);

  Future<void> leave();

  /// Emits whenever messages may be waiting (also once on connect); ends
  /// when the connection drops.
  Stream<void> events();

  void close();
}

/// HTTP client of the relay server. Trusts the system CAs plus [caPem],
/// the root CA of the author's server (baked into the public build), for
/// this connection only.
class RelayClient implements RelayTransport {
  RelayClient({required this.baseUrl, required this.keys, required this.device, this.caPem})
    : _http = createHttpClient(caPem);

  final String baseUrl;
  final RelayKeys keys;
  final String device;
  final String? caPem;
  final HttpClient _http;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl/relay/v1/rooms/${keys.roomId}$path').replace(queryParameters: query);

  Future<Map<String, dynamic>> _request(String method, String path, {Object? body, Map<String, String>? query}) async {
    final req = await _http.openUrl(method, _uri(path, query)).timeout(const Duration(seconds: 15));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${keys.authToken}');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 60));
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      json = null;
    }
    final map = json is Map<String, dynamic> ? json : const <String, dynamic>{};
    if (res.statusCode != HttpStatus.ok) {
      throw RelayException(res.statusCode, map['error'] as String? ?? '');
    }
    return map;
  }

  @override
  Future<bool> join({required bool create}) async {
    final res = await _request('POST', '/join', body: {'device': device, 'create': create});
    return res['joined'] == true;
  }

  @override
  Future<void> send(List<String> items) => _request('POST', '/messages', body: {'device': device, 'items': items});

  @override
  Future<RelayBatch> receive(int after) async {
    final res = await _request('GET', '/messages', query: {'device': device, 'after': '$after', 'limit': '100'});
    final items = [
      for (final i in (res['items'] as List? ?? const []).cast<Map<String, dynamic>>())
        RelayDelivery(seq: (i['seq'] as num).toInt(), from: i['from'] as String, data: i['data'] as String),
    ];
    return RelayBatch(items, more: res['more'] == true);
  }

  @override
  Future<void> ack(int seq) => _request('POST', '/ack', body: {'device': device, 'seq': seq});

  @override
  Future<void> leave() => _request('POST', '/leave', body: {'device': device});

  @override
  Stream<void> events() {
    HttpClient? client;
    late final StreamController<void> controller;
    controller = StreamController<void>(
      onListen: () async {
        try {
          final c = client = createHttpClient(caPem);
          final req = await c.getUrl(_uri('/events', {'device': device})).timeout(const Duration(seconds: 15));
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${keys.authToken}');
          req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          final res = await req.close().timeout(const Duration(seconds: 15));
          if (res.statusCode != HttpStatus.ok) {
            Object? json;
            try {
              json = jsonDecode(await res.transform(utf8.decoder).join());
            } on FormatException {
              json = null;
            }
            throw RelayException(res.statusCode, json is Map ? json['error'] as String? ?? '' : '');
          }
          await for (final line in res.transform(utf8.decoder).transform(const LineSplitter())) {
            if (line == 'event: ready' || line == 'event: message') controller.add(null);
          }
        } on Object catch (e, st) {
          if (controller.hasListener) controller.addError(e, st);
        } finally {
          client?.close(force: true);
          if (!controller.isClosed) unawaited(controller.close());
        }
      },
      // a long-lived response never ends by itself: drop the connection
      onCancel: () => client?.close(force: true),
    );
    return controller.stream;
  }

  @override
  void close() {
    _http.close(force: true);
  }
}
