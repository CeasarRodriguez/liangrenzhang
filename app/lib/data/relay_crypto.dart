import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:cryptography/cryptography.dart' show Mac, SecretBox, SecretBoxAuthenticationError, SecretKeyData;
import 'package:cryptography/dart.dart' show DartAesGcm;

/// End-to-end encryption of relay mode.
///
/// One phone creates a random 16-byte secret and shows it as the pairing
/// code; the partner types (or pastes) it. Everything else is derived from
/// the secret on the phones, so the relay server only ever sees a room id,
/// the hash of a room key and ciphertext.

final _random = Random.secure();

List<int> _randomBytes(int n) => List.generate(n, (_) => _random.nextInt(256));

/// 16 random bytes: the shared secret behind a pairing code.
List<int> newPairingSecret() => _randomBytes(16);

/// Random id of this installation, as the relay server knows it.
String newDeviceId() => _b64(_randomBytes(16));

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

// -----------------------------------------------------------------------------
// pairing code: Crockford base32 (no I, L, O, U) plus two check characters

const _base32 = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const _secretLength = 16;
const _codeLength = 28; // 26 data + 2 check characters

String _encode32(List<int> bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in bytes) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_base32[(buffer >> bits) & 31]);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_base32[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

List<int>? _decode32(String s) {
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final ch in s.split('')) {
    final v = _base32.indexOf(ch);
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
    buffer &= (1 << bits) - 1;
  }
  return buffer == 0 ? out : null;
}

String _check(List<int> secret) {
  final h = sha256.convert(secret).bytes;
  return _base32[h[0] & 31] + _base32[h[1] & 31];
}

/// `XXXX-XXXX-…` (7 groups of 4) for showing and copying.
String formatPairingCode(List<int> secret) {
  final raw = _encode32(secret) + _check(secret);
  return [for (var i = 0; i < raw.length; i += 4) raw.substring(i, i + 4)].join('-');
}

/// The secret behind a pairing code, or null when the code is mistyped.
/// Accepts lowercase, spaces and dashes, and the usual look-alikes.
List<int>? parsePairingCode(String input) {
  final s = input
      .toUpperCase()
      .replaceAll(RegExp(r'[\s\-_]'), '')
      .replaceAll('O', '0')
      .replaceAll('I', '1')
      .replaceAll('L', '1');
  if (s.length != _codeLength) return null;
  final secret = _decode32(s.substring(0, _codeLength - 2));
  if (secret == null || secret.length != _secretLength) return null;
  return _check(secret) == s.substring(_codeLength - 2) ? secret : null;
}

// -----------------------------------------------------------------------------
// keys and messages

List<int> _hkdf(List<int> secret, String info, int length) {
  final prk = Hmac(sha256, utf8.encode('liangrenzhang-relay-v1')).convert(secret).bytes;
  final out = <int>[];
  var t = <int>[];
  for (var i = 1; out.length < length; i++) {
    t = Hmac(sha256, prk).convert([...t, ...utf8.encode(info), i]).bytes;
    out.addAll(t);
  }
  return out.sublist(0, length);
}

/// The pairing code was mistyped (its check characters do not match).
class PairingCodeException implements Exception {
  const PairingCodeException();

  @override
  String toString() => '配对码不对，请检查一下有没有输错';
}

/// A message we cannot read: not from our partner, or damaged.
class RelayCryptoException implements Exception {
  const RelayCryptoException();

  @override
  String toString() => '无法解密转发的数据';
}

class RelayKeys {
  RelayKeys(List<int> secret)
    : roomId = _b64(_hkdf(secret, 'room', 16)),
      authToken = _b64(_hkdf(secret, 'auth', 32)),
      householdId = _hkdf(
        secret,
        'household',
        8,
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, 15),
      _key = SecretKeyData(_hkdf(secret, 'encrypt', 32));

  /// Room id the relay server files our messages under.
  final String roomId;

  /// Proves to the server that we may use the room; it stores only a hash.
  final String authToken;

  /// Id of the shared household record, the same on both phones.
  final String householdId;

  final SecretKeyData _key;

  static const _version = 1;
  static final _aes = DartAesGcm.with256bits();

  List<int> _aad(String sender) => utf8.encode('$roomId/$sender');

  /// Compresses and encrypts [message] (AES-256-GCM). Bound to the sending
  /// device, so the server cannot pass one device's message off as another's.
  Future<String> seal(Map<String, dynamic> message, String sender) async {
    final clear = gzip.encode(utf8.encode(jsonEncode(message)));
    final box = await _aes.encrypt(clear, secretKey: _key, nonce: _randomBytes(12), aad: _aad(sender));
    return base64.encode([_version, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Map<String, dynamic>> open(String data, String sender) async {
    final List<int> raw;
    try {
      raw = base64.decode(data);
    } on FormatException {
      throw const RelayCryptoException();
    }
    if (raw.length < 1 + 12 + 16 || raw[0] != _version) throw const RelayCryptoException();
    final box = SecretBox(
      raw.sublist(13, raw.length - 16),
      nonce: raw.sublist(1, 13),
      mac: Mac(raw.sublist(raw.length - 16)),
    );
    try {
      final clear = await _aes.decrypt(box, secretKey: _key, aad: _aad(sender));
      return jsonDecode(utf8.decode(gzip.decode(clear))) as Map<String, dynamic>;
    } on SecretBoxAuthenticationError {
      throw const RelayCryptoException();
    } on FormatException {
      throw const RelayCryptoException();
    }
  }
}
