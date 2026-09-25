// Единица объёма выбирается по величине. Раньше потолком у главного экрана
// были мегабайты, и израсходованный трафик подписки выходил как
// «333509.4 МБ» вместо «325.7 ГБ».

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/l10n.dart';
import 'package:proxy_app_test/main.dart';

void main() {
  tearDown(() => appLang.value = 'ru');

  test('unit follows the size', () {
    appLang.value = 'en';
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    // Ровно то, что было на экране: 333509.4 МБ.
    expect(formatBytes(333509.4 * 1024 * 1024), '325.7 GB');
    expect(formatBytes(3 * 1024 * 1024 * 1024 * 1024), '3.0 TB');
    // Выше терабайтов единиц нет — остаёмся в них, а не теряем число.
    expect(formatBytes(2048 * 1024 * 1024 * 1024 * 1024), '2048.0 TB');
  });

  test('no "1024.0" at the unit boundary', () {
    appLang.value = 'en';
    expect(formatBytes(1024 * 1024 - 1), '1.0 MB');
    expect(formatBytes(1024 * 1024 * 1024 - 1), '1.0 GB');
  });

  test('units are translated', () {
    appLang.value = 'ru';
    expect(formatBytes(512), '512 Б');
    expect(formatBytes(333509.4 * 1024 * 1024), '325.7 ГБ');
    expect(formatBytes(3 * 1024 * 1024 * 1024 * 1024), '3.0 ТБ');
  });
}
