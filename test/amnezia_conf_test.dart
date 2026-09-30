// Разбор клиентских конфигов AmneziaWG: `.conf` и ссылки `vpn://`.
// Тексты собраны так же, как их собирает 3x-ui (amneziaWGConfigText в его
// исходниках). Тесты зовут настоящие функции из main.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

// Ключи — просто 32 байта в base64, настоящими им быть незачем.
final _priv = base64.encode(List<int>.generate(32, (i) => i + 1));
final _pub = base64.encode(List<int>.generate(32, (i) => 200 - i));
final _psk = base64.encode(List<int>.generate(32, (i) => i * 3 % 251));
final _hp = base64.encode(List<int>.generate(32, (i) => 255 - i * 2));

/// Конфиг AmneziaWG 3.1 в том виде, в каком его выдаёт 3x-ui.
String conf31() => '''
[Interface]
PrivateKey = $_priv
Address = 10.8.1.2/32, fd00:8:1::2/128
DNS = 1.1.1.1, 8.8.8.8
MTU = 1264
Jc = 4
Jmin = 10
Jmax = 50
S1 = 30
S2 = 45
S3 = 20
S4 = 16
H1 = 100000-200000
H2 = 300000-400000
H3 = 500000-600000
H4 = 700000-800000
I1 = <r 148>
HeaderProtectionKey = $_hp
ContentPaddingAddition = 0-32
RekeyAfterTime = 100-140
RandomTrailers = on

# awg-in - phone
[Peer]
PublicKey = $_pub
PresharedKey = $_psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25''';

String vpnLink(String text) => 'vpn://${base64Url.encode(utf8.encode(text)).replaceAll('=', '')}';

void main() {
  test('a 3.1 config from 3x-ui becomes a server for the bridge', () {
    final s = parseAmneziaConf(conf31())!;
    expect(s.engine, 'awg');
    expect(s.protocol, 'amneziawg');
    expect(s.name, 'awg-in - phone');
    final o = s.outbound;
    expect(o['private_key'], _priv);
    expect(o['public_key'], _pub);
    expect(o['preshared_key'], _psk);
    expect(o['addresses'], ['10.8.1.2/32', 'fd00:8:1::2/128']);
    expect(o['dns'], ['1.1.1.1', '8.8.8.8']);
    expect(o['mtu'], 1264);
    expect(o['endpoint'], 'vpn.example.com:51820');
    expect(o['keepalive'], 25);
    expect(o['allowed_ips'], ['0.0.0.0/0', '::/0']);
    expect(o['params'], {
      'Jc': '4', 'Jmin': '10', 'Jmax': '50',
      'S1': '30', 'S2': '45', 'S3': '20', 'S4': '16',
      'H1': '100000-200000', 'H2': '300000-400000', 'H3': '500000-600000', 'H4': '700000-800000',
      'I1': '<r 148>',
      'HeaderProtectionKey': _hp,
      'ContentPaddingAddition': '0-32',
      'RekeyAfterTime': '100-140',
      'RandomTrailers': 'on',
    });
  });

  test('a vpn:// link from a 3x-ui subscription gives the same server', () {
    final fromLink = parseVpnLink(vpnLink(conf31()))!;
    final fromConf = parseAmneziaConf(conf31())!;
    expect(fromLink.name, fromConf.name);
    expect(jsonEncode(fromLink.outbound), jsonEncode(fromConf.outbound));
    // Имя после «#» в ссылке важнее комментария в конфиге.
    expect(parseVpnLink('${vpnLink(conf31())}#My%20phone')!.name, 'My phone');
  });

  test('a key shared by the AmneziaVPN app (compressed JSON) is read too', () {
    final payload = jsonEncode({
      'description': 'Home server',
      'containers': [
        {
          'container': 'amnezia-awg',
          'awg': {
            'last_config': jsonEncode({'config': conf31(), 'mtu': '1264'}),
          },
        }
      ],
    });
    // qCompress из Qt: четыре байта длины исходных данных, затем поток zlib.
    final raw = utf8.encode(payload);
    final header = ByteData(4)..setUint32(0, raw.length);
    final bytes = [...header.buffer.asUint8List(), ...zlib.encode(raw)];
    final s = parseVpnLink('vpn://${base64Url.encode(bytes).replaceAll('=', '')}')!;
    expect(s.name, 'Home server');
    expect(s.outbound['endpoint'], 'vpn.example.com:51820');
    expect((s.outbound['params'] as Map)['HeaderProtectionKey'], _hp);
  });

  test('a 2.0 config (no 3.1 lines) is an AmneziaWG server as well', () {
    final s = parseAmneziaConf('''
[Interface]
PrivateKey = $_priv
Address = 10.8.1.3/32
Jc = 5
Jmin = 10
Jmax = 50
S1 = 30
S2 = 45
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = $_pub
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.7:443
''')!;
    expect(s.protocol, 'amneziawg');
    expect(s.name, 'AmneziaWG 203.0.113.7:443');
    expect((s.outbound['params'] as Map).keys, ['Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'H1', 'H2', 'H3', 'H4']);
    expect(s.outbound.containsKey('preshared_key'), isFalse);
    expect(s.outbound.containsKey('keepalive'), isFalse);
  });

  test('a plain WireGuard config goes through the same engine', () {
    final s = parseAmneziaConf('''
[Interface]
PrivateKey = $_priv
Address = 10.0.0.2/32
ListenPort = 51820
PostUp = iptables -A FORWARD -i %i -j ACCEPT

[Peer]
PublicKey = $_pub
Endpoint = [2001:db8::1]:51820
AllowedIPs = 0.0.0.0/0
''')!;
    expect(s.protocol, 'wireguard');
    expect(s.engine, 'awg');
    expect(s.outbound['endpoint'], '[2001:db8::1]:51820');
    // Команды wg-quick про системный адаптер до моста не доходят.
    expect(s.outbound.containsKey('params'), isFalse);
  });

  test('1.5-only decoys are dropped, an unknown line is handed to the bridge', () {
    final s = parseAmneziaConf('''
[Interface]
PrivateKey = $_priv
Address = 10.0.0.2/32
Jc = 3
J1 = <b 0x01>
Itime = 60
FutureOption = 7

[Peer]
PublicKey = $_pub
Endpoint = 203.0.113.7:443
''')!;
    expect(s.outbound['params'], {'Jc': '3', 'FutureOption': '7'});
  });

  test('configs that cannot work are rejected', () {
    String drop(String key) =>
        conf31().split('\n').where((l) => !l.startsWith('$key =')).join('\n');
    expect(parseAmneziaConf(drop('Endpoint')), isNull);
    expect(parseAmneziaConf(drop('PrivateKey')), isNull);
    expect(parseAmneziaConf(drop('PublicKey')), isNull);
    expect(parseAmneziaConf(drop('Address')), isNull);
    // Два узла — уже не клиентский конфиг.
    expect(parseAmneziaConf('${conf31()}\n\n[Peer]\nPublicKey = $_pub\nEndpoint = 203.0.113.8:1\n'), isNull);
    expect(parseVpnLink('vpn://not-base64-at-all!'), isNull);
    expect(parseVpnLink('vless://x@y:1'), isNull);
  });

  group('the bridge config the app writes', () {
    ParsedServer server(String tag, String endpoint) {
      final s = parseAmneziaConf(conf31().replaceFirst('vpn.example.com:51820', endpoint))!;
      s.outbound['tag'] = tag;
      return s;
    }

    test('every server gets its loopback port and keeps the .conf fields', () {
      final config = buildAwgBridgeConfig(
        [server('srv_2', 'vpn.example.com:51820'), server('srv_5', '203.0.113.9:443')],
        portOf: (tag) => tag == 'srv_2' ? 1340 : 1343,
      );
      final servers = config['servers'] as List;
      expect(servers.map((s) => '${s['tag']} ${s['listen']}'), ['srv_2 127.0.0.1:1340', 'srv_5 127.0.0.1:1343']);
      final first = servers.first as Map;
      expect(first['private_key'], _priv);
      expect(first['public_key'], _pub);
      expect(first['mtu'], 1264);
      expect((first['params'] as Map)['HeaderProtectionKey'], _hp);
      // Служебное поле приложения до моста не доходит.
      expect(first.containsKey('protocol'), isFalse);
      // Сам сервер из списка при этом не изменился.
      expect(server('srv_2', 'vpn.example.com:51820').outbound.containsKey('listen'), isFalse);
    });

    test('a resolved address replaces the name, the port stays', () {
      final config = buildAwgBridgeConfig(
        [server('srv_0', 'vpn.example.com:51820'), server('srv_1', 'six.example.com:51820')],
        portOf: (_) => 1338,
        resolved: {'vpn.example.com': '203.0.113.7', 'six.example.com': '2001:db8::7'},
      );
      expect((config['servers'] as List).map((s) => s['endpoint']),
          ['203.0.113.7:51820', '[2001:db8::7]:51820']);
      // Имя, которое не разрешилось, остаётся как есть — мост попробует сам.
      final kept = buildAwgBridgeConfig([server('srv_0', 'vpn.example.com:51820')],
          portOf: (_) => 1338, resolved: {'vpn.example.com': null});
      expect((kept['servers'] as List).single['endpoint'], 'vpn.example.com:51820');
    });

    test('the endpoint is split into host and port', () {
      expect(awgEndpoint({'endpoint': 'vpn.example.com:51820'}), ('vpn.example.com', 51820));
      expect(awgEndpoint({'endpoint': '[2001:db8::1]:443'}), ('2001:db8::1', 443));
      expect(awgEndpoint({'endpoint': 'no-port'}), isNull);
      expect(awgEndpoint({'endpoint': 'host:0'}), isNull);
      expect(awgEndpoint({}), isNull);
    });

    test('a refusal names the server, and that server is dropped', () {
      final rejection = awgBridgeRejection(
          'server srv_5: config rejected: IPC error -22: failed to merge with device: headers must not overlap\n')!;
      expect(rejection.tag, 'srv_5');
      expect(rejection.reason, contains('headers must not overlap'));
      expect(awgBridgeRejection('open awg_bridge.json: The system cannot find the file specified.'), isNull);

      final config = buildAwgBridgeConfig(
          [server('srv_2', '203.0.113.7:1'), server('srv_5', '203.0.113.9:1')], portOf: (_) => 1338);
      dropFromAwgConfig(config, 'srv_5');
      expect((config['servers'] as List).map((s) => s['tag']), ['srv_2']);
    });

    test('AmneziaWG servers count as bridged, like Xray ones', () {
      expect(isBridgedServer(server('srv_0', '203.0.113.7:1')), isTrue);
      expect(isBridgedServer(parseVless('vless://11111111-1111-1111-1111-111111111111@a.example.com:443?type=xhttp&security=tls#X')!), isTrue);
      expect(isBridgedServer(parseTrojan('trojan://p@b.example.com:443#T')!), isFalse);
    });
  });

  test('a .conf is recognised as such and not mistaken for JSON', () {
    expect(looksLikeWireGuardConf(conf31()), isTrue);
    expect(looksLikeWireGuardConf('  [interface]  \nPrivateKey = x'), isTrue);
    expect(looksLikeWireGuardConf('[{"outbounds": []}]'), isFalse);
    expect(looksLikeWireGuardConf('vless://a@b:1#[Interface]'), isFalse);
  });
}
