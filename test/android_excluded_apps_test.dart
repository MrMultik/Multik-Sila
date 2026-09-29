// Какие приложения на Android выходят из VPN целиком (exclude_package).
// Тест зовёт настоящую функцию из main.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

void main() {
  test('in "Russian sites direct" mode Russian apps bypass the VPN by themselves', () {
    final out = androidExcludedPackages({}, ruDirect: true);
    expect(out, containsAll(['ru.ozon.app.android', 'com.vkontakte.android', 'ru.rostel',
        'ru.sberbankmobile', 'com.wildberries.ru']));
  });

  test('in "all through VPN" mode only the user\'s own "direct" apps are excluded', () {
    final out = androidExcludedPackages({'org.example.app': 'direct'}, ruDirect: false);
    expect(out, ['org.example.app']);
  });

  test('the user\'s own choice wins over the built-in list', () {
    final out = androidExcludedPackages({
      'ru.ozon.app.android': 'proxy',
      'com.vkontakte.android': 'block',
      'ru.rostel': 'default',
    }, ruDirect: true);
    expect(out, isNot(contains('ru.ozon.app.android')));
    expect(out, isNot(contains('com.vkontakte.android')));
    expect(out, contains('ru.rostel'));
  });

  test('an app marked "direct" by the user and also built in is listed once', () {
    final out = androidExcludedPackages({'ru.ozon.app.android': 'direct'}, ruDirect: true);
    expect(out.where((p) => p == 'ru.ozon.app.android').length, 1);
  });

  test('no browsers and no apps that need the VPN in the built-in list', () {
    for (final p in [
      'com.yandex.browser',
      'com.android.chrome',
      'org.mozilla.firefox',
      'org.telegram.messenger',
      'com.whatsapp',
      'com.instagram.android',
      'com.google.android.youtube',
    ]) {
      expect(kRuDirectApps, isNot(contains(p)), reason: p);
    }
    expect(kRuDirectApps.toSet().length, kRuDirectApps.length, reason: 'duplicates');
  });
}
