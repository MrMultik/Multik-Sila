// VLESS+REALITY уходит с sing-box на Xray (см. realityViaXray в main.dart).
// Тест зовёт НАСТОЯЩИЕ функции разбора и перевода, а не их копию.
//
// Живая половина проверки — вне Dart: переведённый outbound поднимался в
// Xray 26.9.9 против сервера Xray 26.9.9 с REALITY и давал HTTP 204, тогда как
// sing-box 1.14.2 на том же сервере падал с `reality verification failed`.

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

const _uuid = '7f17c09d-46f8-4993-9a30-cbbfd0c774f5';
const _pbk = '8XOG1coVzNW9J_PWR9AKRzhQu2BYyRAtABP2GjwNHgw';

ParsedServer _fromLink(String link) {
  final s = parseVless(link)!;
  s.link = link;
  return s;
}

Map<String, dynamic> _reality(ParsedServer s) =>
    (s.outbound['streamSettings'] as Map)['realitySettings'] as Map<String, dynamic>;

void main() {
  test('ссылка VLESS+REALITY переезжает на Xray со всеми полями', () {
    final s = realityViaXray(_fromLink(
        'vless://$_uuid@example.com:443?type=tcp&security=reality&sni=www.microsoft.com'
        '&fp=firefox&pbk=$_pbk&sid=1965b8e0bd&spx=%2Fabc&pqv=PQVKEY&flow=xtls-rprx-vision#R'));

    expect(s.engine, 'xray');
    expect(s.name, 'R');
    expect(s.link, startsWith('vless://'), reason: 'ссылка нужна для QR-кода');
    expect(s.outbound['protocol'], 'vless');

    final vnext = ((s.outbound['settings'] as Map)['vnext'] as List).first as Map;
    expect(vnext['address'], 'example.com');
    expect(vnext['port'], 443);
    final user = (vnext['users'] as List).first as Map;
    expect(user['id'], _uuid);
    expect(user['flow'], 'xtls-rprx-vision');
    expect(user['encryption'], 'none');

    final stream = s.outbound['streamSettings'] as Map;
    expect(stream['network'], 'tcp');
    expect(stream['security'], 'reality');
    final r = _reality(s);
    expect(r['serverName'], 'www.microsoft.com');
    expect(r['fingerprint'], 'firefox');
    expect(r['publicKey'], _pbk);
    expect(r['shortId'], '1965b8e0bd');
    expect(r['spiderX'], '/abc', reason: 'в outbound sing-box spx нет — берётся из ссылки');
    expect(r['mldsa65Verify'], 'PQVKEY', reason: 'ключ ML-DSA-65 — тоже только из ссылки');
  });

  test('REALITY поверх grpc: сеть и имя сервиса сохраняются', () {
    final s = realityViaXray(_fromLink(
        'vless://$_uuid@example.com:443?type=grpc&serviceName=svc&security=reality'
        '&sni=a.com&pbk=$_pbk&sid=ab#G'));
    final stream = s.outbound['streamSettings'] as Map;
    expect(s.engine, 'xray');
    expect(stream['network'], 'grpc');
    expect((stream['grpcSettings'] as Map)['serviceName'], 'svc');
    expect(_reality(s)['fingerprint'], 'chrome', reason: 'умолчание, как у ссылок без fp');
  });

  test('REALITY из Clash YAML тоже уходит на Xray', () {
    final servers = parseClashYaml('''
proxies:
  - name: "Reality VLESS"
    type: vless
    server: example.com
    port: 443
    uuid: $_uuid
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: image.samsung.com
    client-fingerprint: chrome
    reality-opts:
      public-key: $_pbk
      short-id: 1965b8e0bd
''');
    final s = realityViaXray(servers.single);
    expect(s.engine, 'xray');
    expect(_reality(s)['serverName'], 'image.samsung.com');
    expect(_reality(s)['publicKey'], _pbk);
    expect(_reality(s).containsKey('mldsa65Verify'), isFalse);
  });

  test('обычный TLS и VLESS без шифрования остаются на sing-box', () {
    final tls = _fromLink('vless://$_uuid@example.com:443?type=tcp&security=tls&sni=a.com#T');
    final plain = _fromLink('vless://$_uuid@example.com:80?type=tcp&security=none#P');
    expect(identical(realityViaXray(tls), tls), isTrue);
    expect(identical(realityViaXray(plain), plain), isTrue);
    expect(realityViaXray(tls).engine, 'singbox');
  });

  test('сервер, уже идущий через Xray (xhttp), не трогается', () {
    final x = _fromLink('vless://$_uuid@example.com:443?type=xhttp&path=%2Fx&security=reality'
        '&sni=a.com&pbk=$_pbk&sid=ab&pqv=PQ#X');
    expect(x.engine, 'xray');
    expect(identical(realityViaXray(x), x), isTrue);
    expect(_reality(x)['mldsa65Verify'], 'PQ', reason: 'xhttp+REALITY тоже понимает pqv');
  });
}
