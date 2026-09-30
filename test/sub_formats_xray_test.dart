// Два формата, которые раньше не читались: xhttp в Clash YAML и подписка
// Xray JSON. Тесты зовут настоящие функции из main.dart.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

void main() {
  group('Clash YAML with xhttp', () {
    test('vless + REALITY + xhttp gives the same Xray outbound as the link', () {
      final fromClash = parseClashYaml('''
proxies:
- name: X
  type: vless
  server: edge.example.com
  port: 57181
  uuid: $_uuid
  network: xhttp
  tls: true
  udp: true
  servername: cdn.example.com
  client-fingerprint: safari
  reality-opts:
    public-key: PUBKEY
    short-id: abcd
    support-x25519mlkem768: true
  xhttp-opts:
    mode: auto
    path: /api/v1
    x-padding-bytes: 100-1000
''');
      final fromLink = parseVless(
          'vless://$_uuid@edge.example.com:57181?type=xhttp&security=reality&sni=cdn.example.com'
          '&fp=safari&pbk=PUBKEY&sid=abcd&path=%2Fapi%2Fv1&mode=auto&x_padding_bytes=100-1000#X')!;

      expect(fromClash, hasLength(1));
      expect(fromClash.single.engine, 'xray');
      expect(fromClash.single.name, 'X');
      expect(jsonEncode(fromClash.single.outbound), jsonEncode(fromLink.outbound));
    });

    test('vless + TLS + xhttp with alpn and host gives the same outbound as the link', () {
      final fromClash = parseClashYaml('''
proxies:
- name: T
  type: vless
  server: edge.example.com
  port: 24887
  uuid: $_uuid
  network: xhttp
  tls: true
  servername: cdn.example.com
  client-fingerprint: firefox
  alpn:
  - h2
  xhttp-opts:
    mode: packet-up
    path: /x
    host: front.example.com
''');
      final fromLink = parseVless(
          'vless://$_uuid@edge.example.com:24887?type=xhttp&security=tls&sni=cdn.example.com'
          '&fp=firefox&alpn=h2&path=%2Fx&mode=packet-up&host=front.example.com#T')!;
      expect(jsonEncode(fromClash.single.outbound), jsonEncode(fromLink.outbound));
    });

    test('trojan over xhttp goes to Xray too, other transports stay with sing-box', () {
      final out = parseClashYaml('''
proxies:
- {name: TX, type: trojan, server: a.example.com, port: 443, password: secret, network: xhttp, sni: a.example.com, xhttp-opts: {path: /t}}
- {name: WS, type: vless, server: b.example.com, port: 443, uuid: $_uuid, network: ws, tls: true, ws-opts: {path: /ws}}
''');
      expect(out.map((s) => '${s.name}:${s.engine}'), ['TX:xray', 'WS:singbox']);
      final stream = out.first.outbound['streamSettings'] as Map;
      expect(stream['network'], 'xhttp');
      expect(stream['security'], 'tls');
      expect((out.first.outbound['settings'] as Map)['servers'][0]['password'], 'secret');
    });
  });

  group('Xray JSON subscription', () {
    Map<String, dynamic> config(String remarks, Map<String, dynamic> proxy) => {
          'remarks': remarks,
          'log': {'loglevel': 'warning'},
          'inbounds': [
            {'port': 10808, 'protocol': 'socks'}
          ],
          'outbounds': [
            proxy,
            {'protocol': 'freedom', 'tag': 'direct'},
            {'protocol': 'blackhole', 'tag': 'block'},
          ],
        };

    final vless = {
      'protocol': 'vless',
      'tag': 'proxy',
      'settings': {
        'vnext': [
          {
            'address': 'one.example.com',
            'port': 443,
            'users': [
              {'id': _uuid, 'encryption': 'none', 'flow': 'xtls-rprx-vision'}
            ],
          }
        ],
      },
      'streamSettings': {
        'network': 'tcp',
        'security': 'reality',
        'realitySettings': {'serverName': 'sni.example.com', 'publicKey': 'PUB', 'shortId': 'ab', 'fingerprint': 'chrome'},
        'sockopt': {'dialerProxy': 'fragment'},
      },
      'proxySettings': {'tag': 'chain'},
    };
    final trojan = {
      'protocol': 'trojan',
      'tag': 'proxy',
      'settings': {
        'servers': [
          {'address': 'two.example.com', 'port': 8443, 'password': 'secret'}
        ],
      },
      'streamSettings': {
        'network': 'ws',
        'security': 'tls',
        'wsSettings': {'path': '/ws'},
      },
    };

    test('an array of configs gives one Xray server per config, named by remarks', () {
      final out = parseXrayJson(jsonEncode([config('One', vless), config('Two', trojan)]));
      expect(out.map((s) => '${s.name}|${s.protocol}|${s.engine}'),
          ['One|vless|xray', 'Two|trojan|xray']);
      expect(xrayOutboundAddress(out[0].outbound), 'one.example.com');
      expect(xrayOutboundAddress(out[1].outbound), 'two.example.com');
      // Служебные outbound-ы (freedom, blackhole) серверами не становятся.
      expect(out, hasLength(2));
    });

    test('links to neighbouring outbounds are removed, the rest is kept as is', () {
      final o = parseXrayJson(jsonEncode([config('One', vless)])).single.outbound;
      expect(o.containsKey('proxySettings'), isFalse);
      final stream = o['streamSettings'] as Map;
      expect(stream.containsKey('sockopt'), isFalse);
      expect(stream['security'], 'reality');
      expect((stream['realitySettings'] as Map)['publicKey'], 'PUB');
      expect(o['settings']['vnext'][0]['users'][0]['flow'], 'xtls-rprx-vision');
      // Исходный документ не тронут: outbound — своя копия.
      expect(vless.containsKey('proxySettings'), isTrue);
    });

    test('a single config object and a bare outbound are read too', () {
      expect(parseXrayJson(jsonEncode(config('Solo', trojan))).single.name, 'Solo');
      final bare = parseXrayJson(jsonEncode([trojan])).single;
      expect(bare.engine, 'xray');
      expect(bare.name, 'trojan two.example.com');
    });

    test('several servers in one config are told apart by their tags', () {
      final balanced = {
        'remarks': 'Auto',
        'outbounds': [
          {...vless, 'tag': 'de'},
          {...trojan, 'tag': 'nl'},
          {'protocol': 'freedom', 'tag': 'direct'},
        ],
      };
      expect(parseXrayJson(jsonEncode([balanced])).map((s) => s.name), ['Auto · de', 'Auto · nl']);
    });

    test('flat settings are brought to the vnext / servers form', () {
      final flatVless = {
        'protocol': 'vless',
        'settings': {'address': 'flat.example.com', 'port': 443, 'id': _uuid, 'encryption': 'none'},
        'streamSettings': {'network': 'tcp', 'security': 'tls'},
      };
      final flatSs = {
        'protocol': 'shadowsocks',
        'settings': {'address': 'ss.example.com', 'port': '8388', 'method': 'aes-256-gcm', 'password': 'p'},
      };
      final out = parseXrayJson(jsonEncode([config('V', flatVless), config('S', flatSs)]));
      final vnext = out[0].outbound['settings']['vnext'][0] as Map;
      expect(vnext['address'], 'flat.example.com');
      expect(vnext['port'], 443);
      expect(vnext['users'][0], {'id': _uuid, 'encryption': 'none'});
      final server = out[1].outbound['settings']['servers'][0] as Map;
      expect(server['address'], 'ss.example.com');
      expect(server['port'], 8388);
      expect(server['method'], 'aes-256-gcm');
    });

    test('a sing-box config is not mistaken for an Xray one, and the other way round', () {
      final singbox = jsonEncode({
        'outbounds': [
          {'type': 'vless', 'tag': 'a', 'server': 'a.example.com', 'server_port': 443, 'uuid': _uuid},
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      expect(parseXrayJson(singbox), isEmpty);
      expect(parseSingboxJson(singbox), hasLength(1));
      expect(parseSingboxJson(jsonEncode([config('One', vless)])), isEmpty);
    });

    test('an outbound without a server address is skipped, garbage gives nothing', () {
      final broken = {'protocol': 'vless', 'settings': {'vnext': []}};
      expect(parseXrayJson(jsonEncode([config('B', broken), config('Two', trojan)])).map((s) => s.name), ['Two']);
      expect(parseXrayJson('not json'), isEmpty);
      expect(parseXrayJson('[]'), isEmpty);
    });
  });
}
