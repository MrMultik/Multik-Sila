// Разбор форматов подписки. Тест зовёт НАСТОЯЩИЕ функции из main.dart, а не
// их копию: копия расходится с оригиналом на первой же правке, и тогда
// зелёный тест означает только то, что копия сама себе не противоречит.
//
// Вторая половина проверки живёт вне Dart: тест складывает разобранные
// outbound-ы в готовый конфиг `build/test_sub_formats.json`, а `sing-box.exe
// check -c` по нему говорит, принимает ли их ядро на самом деле. Пройденный
// разбор и принятый ядром конфиг — разные утверждения (см. CLAUDE.md).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

const _clashYaml = '''
port: 7890
mode: rule
proxies:
  - name: "Reality VLESS"
    type: vless
    server: example.com
    port: 443
    uuid: 7f17c09d-46f8-4993-9a30-cbbfd0c774f5
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: image.samsung.com
    client-fingerprint: chrome
    reality-opts:
      public-key: 8XOG1coVzNW9J_PWR9AKRzhQu2BYyRAtABP2GjwNHgw
      short-id: 1965b8e0bd
  - name: "Trojan WS"
    type: trojan
    server: example.com
    port: 25783
    password: hnrqlawujwcfcpos
    network: ws
    skip-cert-verify: true
    sni: example.com
    alpn:
      - h2
      - http/1.1
    ws-opts:
      path: /ws
      headers:
        Host: cdn.example.com
  - name: "SS node"
    type: ss
    server: example.com
    port: 8388
    cipher: aes-256-gcm
    password: sspassword123
  - name: "Hy2 node"
    type: hysteria2
    server: example.com
    port: 13674
    password: g84lc9x4faxacz1n
    obfs: salamander
    obfs-password: rg7to9appwos618g
    sni: example.com
  - name: "VMess gRPC"
    type: vmess
    server: example.com
    port: 2096
    uuid: 11111111-2222-3333-4444-555555555555
    alterId: 0
    cipher: auto
    tls: true
    network: grpc
    grpc-opts:
      grpc-service-name: mygrpc
  - name: "Unsupported"
    type: snell
    server: example.com
    port: 1234
    psk: whatever
''';

const _singboxJson = '''
{
  "outbounds": [
    {"type": "vless", "tag": "from-json", "server": "example.com",
     "server_port": 443, "uuid": "99999999-8888-7777-6666-555555555555"},
    {"type": "direct", "tag": "direct"},
    {"type": "selector", "tag": "proxy", "outbounds": ["from-json"]}
  ]
}
''';

void main() {
  group('Clash YAML', () {
    final servers = parseClashYaml(_clashYaml);

    test('берёт все поддержанные записи и пропускает незнакомую', () {
      // Шесть записей в YAML, snell мы не умеем — значит пять.
      expect(servers.length, 5);
      expect(servers.map((s) => s.name), isNot(contains('Unsupported')));
    });

    test('vless: reality, flow и отпечаток переезжают целиком', () {
      final o = servers.first.outbound;
      expect(o['type'], 'vless');
      expect(o['uuid'], '7f17c09d-46f8-4993-9a30-cbbfd0c774f5');
      expect(o['flow'], 'xtls-rprx-vision');
      final tls = o['tls'] as Map;
      expect(tls['server_name'], 'image.samsung.com');
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
      expect((tls['reality'] as Map)['short_id'], '1965b8e0bd');
    });

    test('trojan: TLS включается без ключа tls, ws-заголовки на месте', () {
      final o = servers[1].outbound;
      expect(o['type'], 'trojan');
      // В Clash-записи ключа `tls:` нет вовсе — у trojan это часть протокола.
      final tls = o['tls'] as Map;
      expect(tls['enabled'], true);
      expect(tls['insecure'], true);
      expect(tls['alpn'], ['h2', 'http/1.1']);
      final tr = o['transport'] as Map;
      expect(tr['type'], 'ws');
      expect(tr['path'], '/ws');
      expect((tr['headers'] as Map)['Host'], 'cdn.example.com');
    });

    test('ss: cipher становится method', () {
      final o = servers[2].outbound;
      expect(o['type'], 'shadowsocks');
      expect(o['method'], 'aes-256-gcm');
      expect(o['password'], 'sspassword123');
    });

    test('hysteria2: obfs собирается в блок', () {
      final o = servers[3].outbound;
      expect(o['type'], 'hysteria2');
      expect((o['obfs'] as Map)['type'], 'salamander');
      expect((o['obfs'] as Map)['password'], 'rg7to9appwos618g');
    });

    test('vmess: alterId и cipher переименованы под sing-box', () {
      final o = servers[4].outbound;
      expect(o['type'], 'vmess');
      expect(o['alter_id'], 0);
      expect(o['security'], 'auto');
      expect((o['transport'] as Map)['service_name'], 'mygrpc');
    });

    test('обычная подписка ссылками за Clash не принимается', () {
      expect(looksLikeClash('vless://uuid@host:443#name'), isFalse);
      // Слово proxies в комментарии — не повод считать файл Clash-конфигом.
      expect(looksLikeClash('# my proxies: list\nvless://x@y:443'), isFalse);
      expect(looksLikeClash(_clashYaml), isTrue);
    });
  });

  group('ss://', () {
    test('SIP002: base64 только у пары метод:пароль', () {
      final cred = base64.encode(utf8.encode('aes-256-gcm:pass word'));
      final s = parseShadowsocks('ss://$cred@1.2.3.4:8388#%D0%9C%D0%BE%D0%B9');
      expect(s, isNotNull);
      expect(s!.outbound['method'], 'aes-256-gcm');
      expect(s.outbound['password'], 'pass word');
      expect(s.outbound['server'], '1.2.3.4');
      expect(s.outbound['server_port'], 8388);
      expect(s.name, 'Мой');
    });

    test('старая форма: в base64 упаковано всё целиком', () {
      final all = base64.encode(utf8.encode('chacha20-ietf-poly1305:pw@host.tld:443'));
      final s = parseShadowsocks('ss://$all#Old');
      expect(s, isNotNull);
      expect(s!.outbound['method'], 'chacha20-ietf-poly1305');
      expect(s.outbound['password'], 'pw');
      expect(s.outbound['server'], 'host.tld');
      expect(s.outbound['server_port'], 443);
    });

    test('url-safe base64 без добивки тоже читается', () {
      // Пара, дающая символы - и _ в url-safe алфавите и длину не кратную 4.
      final raw = utf8.encode('aes-128-gcm:a>b?c');
      final urlSafe = base64.encode(raw).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      final s = parseShadowsocks('ss://$urlSafe@h.tld:1234');
      expect(s, isNotNull);
      expect(s!.outbound['password'], 'a>b?c');
    });

    test('IPv6 приезжает без скобок — их sing-box не ждёт', () {
      final cred = base64.encode(utf8.encode('aes-128-gcm:pw'));
      final s = parseShadowsocks('ss://$cred@[2001:db8::1]:8388');
      expect(s, isNotNull);
      expect(s!.outbound['server'], '2001:db8::1');
      expect(s.outbound['server_port'], 8388);
    });

    test('плагин разбирается на имя и опции', () {
      final cred = base64.encode(utf8.encode('aes-128-gcm:pw'));
      final s = parseShadowsocks(
          'ss://$cred@h.tld:443?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dbing.com');
      expect(s, isNotNull);
      expect(s!.outbound['plugin'], 'obfs-local');
      expect(s.outbound['plugin_opts'], 'obfs=http;obfs-host=bing.com');
    });

    test('мусор не притворяется сервером', () {
      expect(parseShadowsocks('ss://'), isNull);
      expect(parseShadowsocks('ss://@@@'), isNull);
      expect(parseShadowsocks('vless://x@y:443'), isNull);
    });
  });

  group('sing-box JSON', () {
    test('служебные outbound-ы отсеиваются, серверы берутся как есть', () {
      final servers = parseSingboxJson(_singboxJson);
      expect(servers.length, 1);
      expect(servers.first.name, 'from-json');
      expect(servers.first.outbound['uuid'], '99999999-8888-7777-6666-555555555555');
    });
  });

  // Складываем всё разобранное в настоящий конфиг: дальше его проверяет
  // `sing-box.exe check -c` — единственный судья тому, годятся ли outbound-ы.
  test('готовим конфиг для sing-box check', () async {
    final servers = [
      ...parseClashYaml(_clashYaml),
      ...parseSingboxJson(_singboxJson),
    ];
    final cred = base64.encode(utf8.encode('aes-256-gcm:sspw'));
    servers.add(parseShadowsocks('ss://$cred@example.com:8388#SS-link')!);

    for (var i = 0; i < servers.length; i++) {
      servers[i].outbound['tag'] = 'srv_$i';
    }

    final config = {
      "log": {"level": "warn"},
      "dns": {
        "servers": [
          {"type": "udp", "tag": "dns-direct", "server": "1.1.1.1"}
        ]
      },
      "inbounds": [
        {
          "type": "mixed",
          "tag": "mixed-in",
          "listen": "127.0.0.1",
          "listen_port": 17399
        }
      ],
      "outbounds": [
        ...servers.map((s) => s.outbound),
        {"type": "direct", "tag": "direct"},
      ],
      "route": {"default_domain_resolver": "dns-direct"},
    };

    final out = File('build/test_sub_formats.json');
    await out.parent.create(recursive: true);
    await out.writeAsString(const JsonEncoder.withIndent('  ').convert(config));
    expect(servers.length, 7);
  });
}
