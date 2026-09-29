// Общий мост Xray: один процесс на все Xray-серверы профиля. Серверы, которые
// ядро не принимает, выкидываются из общего конфига по одному — иначе один
// такой роняет его целиком. Тест зовёт настоящие функции из main.dart.
//
// Живая половина проверки — вне Dart: на бесплатной подписке igareck
// (89 Xray-серверов) общий конфиг без двух отвергнутых принял `xray run -test`,
// один процесс открыл все 87 портов за 0,3 с и занял 25 МБ против 2034 МБ у
// 87 процессов по серверу.

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

Map<String, dynamic> _vless(String address, {String security = 'reality', String encryption = 'none'}) => {
      'tag': 'srv_1',
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': address,
            'port': 443,
            'users': [
              {'id': '7f17c09d-46f8-4993-9a30-cbbfd0c774f5', 'encryption': encryption},
            ],
          },
        ],
      },
      'streamSettings': {'network': 'xhttp', 'security': security},
    };

void main() {
  group('xrayConfigRejection', () {
    test('the exact message Xray 26.9.9 printed for the free list', () {
      const out = 'Failed to start: main: failed to load config files: '
          '[C:/dev/avd-work/free/bridges/combined.json] > infra/conf: failed to build '
          'outbound config with tag srv_53 > infra/conf: vless without TLS or other '
          'encryption is prohibited unless the server address is a private IP or domain';
      final r = xrayConfigRejection(out)!;
      expect(r.tag, 'srv_53');
      expect(r.reason, startsWith('vless without TLS or other encryption is prohibited'));
    });
    test('an error that names no server gives nothing to drop', () {
      expect(xrayConfigRejection('Failed to start: main: failed to listen TCP on 1338'), isNull);
      expect(xrayConfigRejection('Configuration OK.'), isNull);
    });
  });

  group('xrayRejectsOutbound', () {
    test('plain VLESS to a public IP is rejected', () {
      expect(isPlainVlessOutbound(_vless('203.0.113.7', security: 'none')), isTrue);
      expect(xrayRejectsOutbound(_vless('203.0.113.7', security: 'none')), isTrue);
    });
    test('a domain or a private address is allowed, as Xray says', () {
      expect(xrayRejectsOutbound(_vless('example.com', security: 'none')), isFalse);
      expect(xrayRejectsOutbound(_vless('192.168.1.10', security: 'none')), isFalse);
      expect(xrayRejectsOutbound(_vless('10.0.0.1', security: 'none')), isFalse);
    });
    test('TLS, REALITY or VLESS encryption are fine', () {
      expect(xrayRejectsOutbound(_vless('203.0.113.7')), isFalse);
      expect(xrayRejectsOutbound(_vless('203.0.113.7', security: 'tls')), isFalse);
      expect(xrayRejectsOutbound(_vless('203.0.113.7', security: 'none', encryption: 'mlkem768x25519plus.native.0rtt.x')), isFalse);
    });
    test('other protocols are not this rule', () {
      expect(isPlainVlessOutbound({'protocol': 'trojan', 'settings': {}}), isFalse);
    });
  });

  test('dropFromXrayConfig removes one server and leaves the rest', () {
    Map<String, dynamic> inbound(String tag) => {'tag': tag, 'port': 1};
    final config = <String, dynamic>{
      'inbounds': [inbound('in_srv_1'), inbound('in_srv_2'), inbound('probe_in_srv_1')],
      'outbounds': [
        {'tag': 'srv_1'},
        {'tag': 'srv_2'},
        {'tag': 'frag', 'protocol': 'freedom'},
      ],
      'routing': {
        'rules': [
          {'inboundTag': ['in_srv_1'], 'outboundTag': 'srv_1'},
          {'inboundTag': ['in_srv_2'], 'outboundTag': 'srv_2'},
        ],
      },
    };
    dropFromXrayConfig(config, 'srv_1');
    expect((config['outbounds'] as List).map((o) => o['tag']), ['srv_2', 'frag']);
    expect((config['inbounds'] as List).map((i) => i['tag']), ['in_srv_2']);
    expect((config['routing']['rules'] as List).map((r) => r['outboundTag']), ['srv_2']);
  });
}
