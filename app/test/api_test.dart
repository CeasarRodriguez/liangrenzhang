import 'package:couple_ledger/data/api.dart';
import 'package:flutter_test/flutter_test.dart';

// self-signed test certificate; fingerprint from
//   openssl x509 -noout -fingerprint -sha256
const _pem = '''-----BEGIN CERTIFICATE-----
MIIBdDCCARmgAwIBAgIUK3I5x8JeDoB5AJzMsHwqJbtwMwQwCgYIKoZIzj0EAwIw
DzENMAsGA1UEAwwEdGVzdDAeFw0yNjEwMTMwNzI5MjVaFw0yNjEwMTQwNzI5MjVa
MA8xDTALBgNVBAMMBHRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASQ/qeL
ZoygS3CFwvMzeNxPu15NTMSJ+EMAkM562HIAbKIZZ1Eyms1oITHWy4gL7K9xiKZ3
ZTUy2V8PmouL1+lUo1MwUTAdBgNVHQ4EFgQUWp3ofI0g5gqpAXQ/Hteg7WShPZ8w
HwYDVR0jBBgwFoAUWp3ofI0g5gqpAXQ/Hteg7WShPZ8wDwYDVR0TAQH/BAUwAwEB
/zAKBggqhkjOPQQDAgNJADBGAiEA7ISMjaRe66P2A5ROmn4eT8cnZgWp5okd9ea4
GhpMs+gCIQDbG3pXD5VfLHbEsExu3FfUnoeL4+Dlae0MEP8L4sY0tA==
-----END CERTIFICATE-----
''';
const _opensslFingerprint =
    '4F:B1:97:DF:0D:A7:AA:EF:21:E9:F3:16:7C:89:1D:E2:8B:0C:36:94:CF:0B:57:95:30:3F:BF:2A:DC:1E:A9:FF';

void main() {
  test('fingerprints match what openssl prints on the server', () {
    expect(formatFingerprint(pemSha256(_pem)), _opensslFingerprint);
    final e = UntrustedCertificateException([_pem], changed: false);
    expect(e.fingerprints, [_opensslFingerprint]);
  });

  test('PEM line endings do not change the fingerprint', () {
    expect(pemSha256(_pem.replaceAll('\n', '\r\n')), pemSha256(_pem));
  });
}
