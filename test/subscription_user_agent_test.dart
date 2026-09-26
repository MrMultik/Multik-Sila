// User-Agent запроса подписки. Панель выбирает по нему формат ответа (см.
// kSubscriptionUserAgent в main.dart), поэтому проверяется то, что РЕАЛЬНО
// доходит до сервера: запрос идёт настоящей fetchSubscription на локальный
// сервер, а тот записывает заголовок. Иначе зелёный тест не отличил бы наш
// заголовок от стандартного `Dart/… (dart:io)`, который http-клиент ставит сам.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

void main() {
  late HttpServer server;
  late Uri uri;
  final seen = <String?>[];

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}/sub');
    server.listen((req) {
      seen.add(req.headers.value(HttpHeaders.userAgentHeader));
      req.response
        ..write('ok')
        ..close();
    });
  });

  tearDown(() => server.close(force: true));

  SubscriptionProfile profile({String userAgent = ''}) =>
      SubscriptionProfile(id: '1', name: 'p', url: uri.toString(), userAgent: userAgent);

  test('by default the app introduces itself, not as dart:io', () async {
    final resp = await fetchSubscription(uri, profile());
    expect(resp.statusCode, 200);
    expect(seen, ['MultikSila/$kAppVersion']);
    expect(kSubscriptionUserAgent, 'MultikSila/$kAppVersion');
  });

  test('a profile\'s own User-Agent is sent as typed, trimmed', () async {
    await fetchSubscription(uri, profile(userAgent: '  v2rayN/7.13.8 '));
    expect(seen, ['v2rayN/7.13.8']);
  });

  test('a blank field means the default, not an empty header', () async {
    await fetchSubscription(uri, profile(userAgent: '   '));
    expect(seen, [kSubscriptionUserAgent]);
  });

  test('profiles saved before the field existed load with the default', () {
    final old = SubscriptionProfile.fromJson({'id': '1', 'name': 'p', 'url': 'https://x'});
    expect(old.userAgent, '');
    expect(old.effectiveUserAgent, kSubscriptionUserAgent);
  });

  test('a chosen User-Agent survives saving and loading', () {
    final saved = profile(userAgent: 'Happ/2.9.0').toJson();
    expect(SubscriptionProfile.fromJson(saved).effectiveUserAgent, 'Happ/2.9.0');
  });

  test('every preset is a real header value', () {
    for (final ua in kSubscriptionUserAgentPresets.values) {
      expect(ua.trim(), ua);
      expect(ua, isNotEmpty);
      expect(ua, isNot(contains('\n')));
    }
  });
}
