import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/quic_probe.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('blake2b256 matches the reference implementation', () {
    // Values from Go's golang.org/x/crypto/blake2b.Sum256 and b2sum -l 256.
    test('empty input', () {
      expect(hex(blake2b256(const [])),
          '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8');
    });
    test('"abc"', () {
      expect(hex(blake2b256(utf8.encode('abc'))),
          'bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319');
    });
    // Bytes 0, 1, 2, … — exactly one block, one byte over, several blocks.
    test('one block and more', () {
      List<int> bytes(int n) => List<int>.generate(n, (i) => i & 0xff);
      expect(hex(blake2b256(bytes(128))),
          'c3582f71ebb2be66fa5dd750f80baae97554f3b015663c8be377cfcb2488c1d1');
      expect(hex(blake2b256(bytes(129))),
          'f7f3c46ba2564ff4c4c162da1f5b605f9f1c4aa6a20652a9f9a337c1a2f5b9c9');
      expect(hex(blake2b256(bytes(300))),
          '3a486e3fe3ee414853000269ac020030aeef748cb05cd62ba85939ec298ef25c');
    });
  });

  test('salamander wraps and unwraps back to the same packet', () {
    final rnd = Random(1);
    final password = utf8.encode('rg-test-password');
    final packet = quicVersionProbe(rnd);
    final wrapped = salamanderWrap(password, packet, rnd);
    expect(wrapped.length, packet.length + 8);
    expect(wrapped.sublist(8), isNot(equals(packet)));
    expect(salamanderUnwrap(password, wrapped), packet);
    expect(salamanderUnwrap(utf8.encode('wrong'), wrapped), isNot(equals(packet)));
  });

  group('quicProbeTarget', () {
    test('hysteria2 with salamander', () {
      final t = quicProbeTarget({
        'type': 'hysteria2',
        'server': '203.0.113.5',
        'server_port': 13674,
        'obfs': {'type': 'salamander', 'password': 'pw'},
      });
      expect(t?.host, '203.0.113.5');
      expect(t?.port, 13674);
      expect(t?.salamander, utf8.encode('pw'));
    });
    test('hysteria2 with port hopping takes the first port', () {
      expect(quicProbeTarget({'type': 'hysteria2', 'server': 'h', 'server_ports': ['20000:30000']})?.port,
          20000);
    });
    test('tuic without obfuscation', () {
      final t = quicProbeTarget({'type': 'tuic', 'server': 'h', 'server_port': 443});
      expect(t?.port, 443);
      expect(t?.salamander, isNull);
    });
    test('what it cannot measure is left to the probe core', () {
      expect(quicProbeTarget({'type': 'vless', 'server': 'h', 'server_port': 443}), isNull);
      expect(quicProbeTarget({'type': 'hysteria', 'server': 'h', 'server_port': 443}), isNull);
      expect(
          quicProbeTarget({
            'type': 'hysteria2',
            'server': 'h',
            'server_port': 443,
            'obfs': {'type': 'other', 'password': 'pw'},
          }),
          isNull);
      expect(quicProbeTarget({'type': 'hysteria2', 'server': 'h'}), isNull);
    });
  });

  test('the probe is a 1200-byte long-header packet with a reserved version', () {
    final p = quicVersionProbe(Random(2));
    expect(p.length, 1200);
    expect(p[0] & 0xC0, 0xC0);
    expect(p.sublist(1, 5), [0x1a, 0x2a, 0x3a, 0x4a]);
    expect(isQuicVersionNegotiation(p), isFalse);
    expect(isQuicVersionNegotiation([0x80, 0, 0, 0, 0, 8, 0, 0]), isTrue);
  });
}
