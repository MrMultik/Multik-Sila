// Приложение целиком, с настоящим MyApp: свежая установка открывает мастер,
// выбор языка доезжает до следующего экрана и сохраняется в настройки.
//
// Здесь раньше лежал шаблонный тест Flutter про счётчик, которого в
// приложении нет, — он падал с первого коммита, и `flutter test` был красным
// всегда. Главный экран отсюда не проверить: его initState поднимает трей,
// окно, ходит на GitHub и пишет файлы рядом с исполняемым файлом.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/l10n.dart';
import 'package:proxy_app_test/main.dart';
import 'package:proxy_app_test/prefs_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => appLang.value = 'ru');

  testWidgets('fresh install: the language picked in the wizard is applied and saved',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    appLang.value = 'ru';

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    // Первый шаг мастера — выбор языка.
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Русский'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(appLang.value, 'en');
    expect(find.text('Terms of use'), findsOneWidget);
    expect(find.text('Условия использования'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    final settings =
        jsonDecode(prefs.getString(kSettingsPrefsKey)!) as Map<String, dynamic>;
    expect(settings['language'], 'en');
  });
}
