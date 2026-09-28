// Проверка маршрута: разбор того, что человек вставил, сверка адреса со
// списками так, как их понимает ядро, и перевод правила из Clash API.
// Тест зовёт настоящие функции из route_check.dart. Сама проба (соединение
// через ядро и чтение /connections) проверялась вживую на sing-box — см.
// CLAUDE.md, раздел о проверке маршрута.

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/l10n.dart';
import 'package:proxy_app_test/route_check.dart';

void main() {
  tearDown(() => appLang.value = 'ru');

  group('parseRouteTarget', () {
    test('a domain gets port 443 and is lower-cased', () {
      expect(parseRouteTarget('  YouTube.com '), ('youtube.com', 443));
    });
    test('a whole link: scheme gives the port, the path is dropped', () {
      expect(parseRouteTarget('https://www.Wikipedia.org/wiki/X'), ('www.wikipedia.org', 443));
      expect(parseRouteTarget('http://example.com/a'), ('example.com', 80));
      expect(parseRouteTarget('https://example.com:8443/'), ('example.com', 8443));
    });
    test('host:port and a bare path', () {
      expect(parseRouteTarget('mail.example.com:993'), ('mail.example.com', 993));
      expect(parseRouteTarget('ya.ru/search'), ('ya.ru', 443));
    });
    test('IPv4 and IPv6, with and without a port', () {
      expect(parseRouteTarget('1.1.1.1'), ('1.1.1.1', 443));
      expect(parseRouteTarget('192.168.1.1:80'), ('192.168.1.1', 80));
      expect(parseRouteTarget('2606:4700:4700::1111'), ('2606:4700:4700::1111', 443));
      expect(parseRouteTarget('[2606:4700:4700::1111]:53'), ('2606:4700:4700::1111', 53));
    });
    test('rubbish is not a target', () {
      expect(parseRouteTarget(''), isNull);
      expect(parseRouteTarget('не сайт'), isNull);
      expect(parseRouteTarget('example..com'), isNull);
      expect(parseRouteTarget('example.com:70000'), isNull);
      expect(parseRouteTarget('[zz::1]'), isNull);
    });
  });

  group('routeEntryMatches', () {
    test('a domain entry covers the domain and its subdomains only', () {
      expect(routeEntryMatches('youtube.com', 'youtube.com'), isTrue);
      expect(routeEntryMatches('www.youtube.com', 'youtube.com'), isTrue);
      expect(routeEntryMatches('notyoutube.com', 'youtube.com'), isFalse);
      expect(routeEntryMatches('YouTube.COM', ' YouTube.com '), isTrue);
    });
    test('comments and blank lines match nothing', () {
      expect(routeEntryMatches('example.com', '# example.com'), isFalse);
      expect(routeEntryMatches('example.com', '   '), isFalse);
    });
    test('an IP entry and a subnet', () {
      expect(routeEntryMatches('10.1.2.3', '10.1.2.3'), isTrue);
      expect(routeEntryMatches('10.1.2.4', '10.1.2.3'), isFalse);
      expect(routeEntryMatches('10.1.200.9', '10.1.0.0/16'), isTrue);
      expect(routeEntryMatches('10.2.0.1', '10.1.0.0/16'), isFalse);
      expect(routeEntryMatches('2001:db8::5', '2001:db8::/32'), isTrue);
      expect(routeEntryMatches('2001:db9::5', '2001:db8::/32'), isFalse);
    });
    test('a domain never matches an address entry, and v4 never matches v6', () {
      expect(routeEntryMatches('example.com', '10.0.0.0/8'), isFalse);
      expect(routeEntryMatches('10.0.0.1', '::/0'), isFalse);
    });
  });

  group('describeCoreRule', () {
    // Строки — ровно такие, какие sing-box 1.14.2 вернул в /connections на
    // живом конфиге пользователя.
    test('the rules the core actually reported', () {
      appLang.value = 'en';
      expect(describeCoreRule('rule_set=[geosite-ru geoip-ru] => route(direct)'),
          'Rule set: Russian sites, Russian IP addresses');
      expect(describeCoreRule('ip_is_private=true => route(direct)'), 'Local network');
      expect(describeCoreRule('final'), 'No rule matched — the default route');
    });
    test('lists, per-app rules and anything unknown', () {
      appLang.value = 'en';
      expect(describeCoreRule('domain_suffix=[youtube.com] => route(proxy)'),
          startsWith('A list of domains'));
      expect(describeCoreRule('process_path=[C:\\x.exe] => route(direct)'), 'A per-app rule');
      expect(describeCoreRule('network=udp => reject'), 'network=udp => reject');
    });
    test('translated, not frozen in one language', () {
      appLang.value = 'ru';
      expect(describeCoreRule('final'), startsWith('Ни одно правило'));
    });
  });
}
