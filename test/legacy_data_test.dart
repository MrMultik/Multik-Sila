// Перенос профилей из папки старого ProductName. Однажды смена ProductName
// уже «потеряла» все профили: они остались в старой папке, а приложение
// смотрело в новую, пустую. Здесь проверяется, что перенос копирует всё,
// не трогает старое и не затирает новые данные при повторном запуске.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/legacy_data.dart';

void main() {
  late Directory root;
  late Directory company;
  late Directory oldDir;
  late Directory newDir;

  String read(Directory dir, String name) =>
      File('${dir.path}${Platform.pathSeparator}$name').readAsStringSync();
  void write(Directory dir, String name, String text) {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('legacy_data_test');
    company = Directory('${root.path}${Platform.pathSeparator}com.example');
    newDir = Directory('${company.path}${Platform.pathSeparator}Multik Sila');
    oldDir = legacyDataDirFor(newDir);
    oldDir.createSync(recursive: true);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('the old folder sits next to the new one', () {
    expect(oldDir.path,
        '${company.path}${Platform.pathSeparator}proxy_app_test');
  });

  test('copies everything and leaves the old folder untouched', () {
    write(oldDir, kPrefsFileName, '{"flutter.profiles":"old"}');
    write(oldDir, 'shared_preferences.json.bak-135829', 'backup');
    write(oldDir, 'nested${Platform.pathSeparator}note.txt', 'nested');

    final result = migrateLegacyData(newDir, oldDir);

    expect(result.outcome, LegacyDataOutcome.copied);
    expect(result.files, 3);
    expect(read(newDir, kPrefsFileName), '{"flutter.profiles":"old"}');
    expect(read(newDir, 'shared_preferences.json.bak-135829'), 'backup');
    expect(read(newDir, 'nested${Platform.pathSeparator}note.txt'), 'nested');
    // Временного файла после переноса быть не должно.
    expect(File('${newDir.path}${Platform.pathSeparator}$kPrefsFileName.migrating')
        .existsSync(), isFalse);
    // Старая папка — резервная копия, она остаётся как была.
    expect(read(oldDir, kPrefsFileName), '{"flutter.profiles":"old"}');
    expect(oldDir.listSync(recursive: true).whereType<File>().length, 3);
  });

  test('a second start does not overwrite newer data', () {
    write(oldDir, kPrefsFileName, '{"flutter.profiles":"old"}');
    expect(migrateLegacyData(newDir, oldDir).outcome, LegacyDataOutcome.copied);

    // Приложение уже работает с новой папкой и что-то в ней поменяло.
    write(newDir, kPrefsFileName, '{"flutter.profiles":"new"}');

    expect(migrateLegacyData(newDir, oldDir).outcome, LegacyDataOutcome.notNeeded);
    expect(read(newDir, kPrefsFileName), '{"flutter.profiles":"new"}');
  });

  test('a fresh install has nothing to copy', () {
    expect(migrateLegacyData(newDir, oldDir).outcome, LegacyDataOutcome.notNeeded);
    expect(newDir.existsSync(), isFalse);
  });

  test('an interrupted copy is repeated on the next start', () {
    write(oldDir, kPrefsFileName, '{"flutter.profiles":"old"}');
    // Прошлая попытка успела разложить часть файлов и оставить временный,
    // но до переименования не дошла — файла настроек в новой папке нет.
    write(newDir, '$kPrefsFileName.migrating', '{"flutter.prof');

    expect(migrateLegacyData(newDir, oldDir).outcome, LegacyDataOutcome.copied);
    expect(read(newDir, kPrefsFileName), '{"flutter.profiles":"old"}');
  });

  test('same folder means the product name did not change', () {
    write(oldDir, kPrefsFileName, '{}');
    expect(migrateLegacyData(oldDir, oldDir).outcome, LegacyDataOutcome.notNeeded);
  });
}
