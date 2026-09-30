// Обновление подписки посреди сеанса: когда список для ядра тот же и когда
// выбранный сервер надо найти в новом списке. Тесты зовут настоящие функции.

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

const _a = 'vless://11111111-1111-1111-1111-111111111111@a.example.com:443?security=tls&type=tcp#Alpha';
const _b = 'trojan://secret@b.example.com:443?security=tls#Beta';
const _c = 'vless://22222222-2222-2222-2222-222222222222@c.example.com:443?security=tls&type=tcp#Gamma';

/// Разбор списка ссылок так же, как это делает приложение: тег по порядку и
/// отпечаток сразу после разбора.
List<ParsedServer> _parse(List<String> links) {
  final out = <ParsedServer>[];
  for (final link in links) {
    final s = (parseVless(link) ?? parseTrojan(link))!;
    s.link = link;
    out.add(s);
  }
  for (var i = 0; i < out.length; i++) {
    out[i].outbound['tag'] = 'srv_$i';
    out[i].coreKey = serverCoreKey(out[i]);
  }
  return out;
}

void main() {
  test('the same subscription fetched again is the same list for the core', () {
    expect(sameServersForCore(_parse([_a, _b]), _parse([_a, _b])), isTrue);
  });

  test('a renamed server is still the same list for the core', () {
    final renamed = _a.replaceFirst('#Alpha', '#Alpha%20%E2%8F%B3%2027%20days');
    expect(sameServersForCore(_parse([_a, _b]), _parse([renamed, _b])), isTrue);
  });

  test('added, removed, reordered or changed servers make it a different list', () {
    final base = _parse([_a, _b]);
    expect(sameServersForCore(base, _parse([_a, _b, _c])), isFalse);
    expect(sameServersForCore(base, _parse([_a])), isFalse);
    expect(sameServersForCore(base, _parse([_b, _a])), isFalse);
    expect(sameServersForCore(base, _parse([_a.replaceFirst(':443', ':8443'), _b])), isFalse);
  });

  test('an address baked into the outbound later does not make the list look changed', () {
    // _bakeServerIps кладёт IP прямо в outbound работающего списка. Отпечаток
    // снят до этого, поэтому свежий разбор той же подписки с ним совпадает.
    final running = _parse([_a, _b]);
    running[0].outbound['server'] = '203.0.113.7';
    expect(sameServersForCore(running, _parse([_a, _b])), isTrue);
  });

  test('a REALITY short id picked anew by the panel is still the same list', () {
    // Панель на каждую выдачу подставляет случайный shortId (и spiderX) из
    // разрешённых сервером: две выдачи одной подписки подряд ими различаются.
    String reality(String sid, String spx) =>
        'vless://33333333-3333-3333-3333-333333333333@r.example.com:443?security=reality&type=tcp'
        '&sni=s.example.com&fp=chrome&pbk=PUBKEY&sid=$sid&spx=$spx&flow=xtls-rprx-vision#R';
    List<ParsedServer> list(String link) {
      final s = realityViaXray(parseVless(link)!..link = link);
      s.outbound['tag'] = 'srv_0';
      s.coreKey = serverCoreKey(s);
      return [s];
    }

    expect(sameServersForCore(list(reality('aa11', '%2Fone')), list(reality('bb22cc', '%2Ftwo'))), isTrue);
    // А другой ключ сервера — уже другой сервер.
    expect(
        sameServersForCore(
            list(reality('aa11', '%2Fone')), list(reality('aa11', '%2Fone').replaceFirst('PUBKEY', 'OTHER'))),
        isFalse);
  });

  test('servers without a fingerprint are never treated as unchanged', () {
    final bare = _parse([_a])..first.coreKey = '';
    expect(sameServersForCore(bare, bare), isFalse);
  });

  test('the selected server is found in the new list by its link, wherever it moved', () {
    final old = _parse([_a, _b]);
    final fresh = _parse([_c, _b, _a]);
    expect(findSameServer(old[0], fresh)!.outbound['tag'], 'srv_2');
    expect(findSameServer(old[1], fresh)!.outbound['tag'], 'srv_1');
  });

  test('without a link the server is found by name and protocol', () {
    final old = _parse([_a, _b])..first.link = '';
    final fresh = _parse([_b, _a]);
    expect(findSameServer(old[0], fresh)!.name, 'Alpha');
    expect(findSameServer(old[0], fresh)!.outbound['tag'], 'srv_1');
  });

  test('a server that is gone is not found', () {
    final old = _parse([_a, _b]);
    expect(findSameServer(old[0], _parse([_b, _c])), isNull);
    expect(findSameServer(null, _parse([_b])), isNull);
  });
}
