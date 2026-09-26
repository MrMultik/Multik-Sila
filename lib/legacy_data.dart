import 'dart:io';

/// Перенос профилей и настроек из папки, где их держали версии до смены
/// `ProductName`.
///
/// `shared_preferences`/`path_provider` на Windows строят путь к данным как
/// `%APPDATA%\<CompanyName>\<ProductName>\`, беря оба значения из
/// VERSIONINFO самого .exe. По 1.0.10 включительно в `ProductName` стояло
/// `proxy_app_test`, теперь `Multik Sila` — этого требует SignPath для
/// подписи кода. Без переноса приложение открылось бы с пустым списком
/// профилей: так уже было однажды, когда `ProductName` меняли при
/// ребрендинге (см. CLAUDE.md, грабля №1).
///
/// Правила, и каждое здесь не просто так:
/// - только КОПИРУЕМ. Старая папка остаётся нетронутой — это и резервная
///   копия, и путь назад, если человек вернётся на старую версию;
/// - копируем, только если в новой папке ещё нет `shared_preferences.json`,
///   а в старой он есть. Поэтому второй запуск не копирует ничего и не
///   может затереть новые данные старыми;
/// - `shared_preferences.json` кладётся ПОСЛЕДНИМ и атомарно (временный
///   файл + переименование). Его появление и есть признак «перенос
///   завершён», и копирование, оборванное на середине, не должно выглядеть
///   завершённым — иначе следующий запуск его не повторит.

/// Файл, в котором `shared_preferences` на Windows держит все значения.
const String kPrefsFileName = 'shared_preferences.json';

/// `ProductName`, с которым выходили версии по 1.0.10 включительно. Имя
/// папки данных старых версий — ровно оно.
const String kLegacyProductName = 'proxy_app_test';

enum LegacyDataOutcome {
  /// Переносить нечего или уже перенесено.
  notNeeded,

  /// Данные скопированы в новую папку.
  copied,

  /// Копирование не удалось. Старая папка цела, следующий запуск попробует
  /// снова — если к тому времени в новой не появится свой файл настроек.
  failed,
}

class LegacyDataMigration {
  const LegacyDataMigration(this.outcome, this.from, this.to,
      {this.files = 0, this.error});

  final LegacyDataOutcome outcome;
  final String from;
  final String to;

  /// Сколько файлов скопировано, вместе с самим файлом настроек.
  final int files;
  final Object? error;
}

/// Папка данных старых версий: соседняя с [newDir] внутри той же папки
/// `CompanyName`. Считается от нового пути, а не собирается из `%APPDATA%`
/// заново, — так обе папки гарантированно лежат там, где их ищет плагин.
Directory legacyDataDirFor(Directory newDir) =>
    Directory('${newDir.parent.path}${Platform.pathSeparator}$kLegacyProductName');

/// Скопировать [oldDir] в [newDir], если это нужно. Не бросает исключений:
/// сбой переноса не должен мешать запуску приложения.
LegacyDataMigration migrateLegacyData(Directory newDir, Directory oldDir) {
  final sep = Platform.pathSeparator;
  final from = oldDir.absolute.path;
  final to = newDir.absolute.path;
  final newPrefs = File('$to$sep$kPrefsFileName');
  final oldPrefs = File('$from$sep$kPrefsFileName');

  // Отдельно сравнивать пути не нужно: если это одна и та же папка, файл
  // настроек в ней либо есть (и тогда он «уже в новой»), либо его нет
  // (и тогда нечего копировать).
  if (newPrefs.existsSync() || !oldPrefs.existsSync()) {
    return LegacyDataMigration(LegacyDataOutcome.notNeeded, from, to);
  }

  try {
    newDir.createSync(recursive: true);
    var files = 0;
    // Сначала всё, кроме файла настроек: резервные копии рядом с ним и
    // что угодно ещё, что когда-нибудь окажется в этой папке.
    for (final entity in oldDir.listSync(recursive: true, followLinks: false)) {
      final relative = entity.absolute.path.substring(from.length + 1);
      if (relative.toLowerCase() == kPrefsFileName) continue;
      final target = '$to$sep$relative';
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        File(target).parent.createSync(recursive: true);
        entity.copySync(target);
        files++;
      }
    }
    // Файл настроек — последним и через временное имя: см. правила выше.
    final staging = File('${newPrefs.path}.migrating');
    oldPrefs.copySync(staging.path);
    staging.renameSync(newPrefs.path);
    files++;
    return LegacyDataMigration(LegacyDataOutcome.copied, from, to, files: files);
  } catch (e) {
    return LegacyDataMigration(LegacyDataOutcome.failed, from, to, error: e);
  }
}
