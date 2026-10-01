// Узнать новейший релиз на GitHub, не трогая его API.
//
// API без входа даёт 60 запросов в час на адрес. За VPN-сервером адрес один
// на всех его клиентов, а приложение при старте спрашивает GitHub о себе и о
// двух ядрах — при паре десятков человек лимит кончается, и обновления
// перестают находиться (отказ 403). Обычные страницы GitHub этим лимитом не
// считаются: перенаправление `releases/latest` даёт тег последнего
// стабильного релиза, лента `releases.atom` — все свежие теги, включая
// предрелизы, а файлы релиза лежат по предсказуемым адресам.

/// `владелец/репозиторий` из адреса фида обновлений, если это GitHub:
/// `https://api.github.com/repos/O/R/releases/latest` (так он записан в
/// настройках у всех, кто ставил приложение до 1.0.17) или
/// `https://github.com/O/R/releases/latest`. Иначе null — это свой фид.
String? githubRepoOfFeed(String url) {
  final m = RegExp(r'^https://(?:api\.github\.com/repos|github\.com)/([^/\s]+)/([^/\s]+)/releases/latest/?$')
      .firstMatch(url.trim());
  return m == null ? null : '${m.group(1)}/${m.group(2)}';
}

/// Тег из перенаправления `releases/latest`:
/// `https://github.com/O/R/releases/tag/v1.0.16` → `v1.0.16`.
String? tagFromReleaseLocation(String? location) {
  if (location == null) return null;
  final m = RegExp(r'/releases/tag/([^/?#\s]+)').firstMatch(location);
  return m == null ? null : Uri.decodeComponent(m.group(1)!);
}

/// Теги всех релизов из ленты `releases.atom`, без повторов, в порядке ленты.
List<String> tagsFromReleasesAtom(String atom) {
  final tags = <String>[];
  // Ссылки на релиз стоят в <link href> каждой записи; в описании те же
  // адреса встречаются экранированными — их отсекает требование кавычки
  // сразу после тега.
  for (final m in RegExp(r'/releases/tag/([^"&<>\s]+)"').allMatches(atom)) {
    final tag = Uri.decodeComponent(m.group(1)!);
    if (!tags.contains(tag)) tags.add(tag);
  }
  return tags;
}

/// Сравнение версий по числам: «26.9.30» больше «26.9.9».
int compareVersionNumbers(String a, String b) {
  final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Тег с наибольшим ЧИСТЫМ номером (`v26.9.30`, `1.14.2`); альфы и беты
/// (`v1.15.0-alpha.9`) пропускаются — людей на них тащить нельзя.
String? newestCleanTag(Iterable<String> tags) {
  String? best;
  String? bestVersion;
  for (final tag in tags) {
    final v = tag.replaceFirst(RegExp(r'^v'), '');
    if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(v)) continue;
    if (bestVersion == null || compareVersionNumbers(v, bestVersion) > 0) {
      best = tag;
      bestVersion = v;
    }
  }
  return best;
}

/// Адрес файла релиза: `https://github.com/O/R/releases/download/<тег>/<имя>`.
String githubAssetUrl(String repo, String tag, String name) =>
    'https://github.com/$repo/releases/download/$tag/$name';

/// Имена файлов приложения в нашем релизе (их задаёт tools/release.ps1).
String appApkName(String version, String abi) => 'MultikSila-$version-android-$abi.apk';
String appSetupName(String version) => 'MultikSila-$version-setup.exe';
String appZipName(String version) => 'MultikSila-$version-windows-x64.zip';

/// Имя архива ядра для Windows в релизе его репозитория, или null, если
/// репозиторий не знаем. sing-box кладёт версию в имя, Xray — нет.
String? coreWindowsAssetName(String repo, String version) => switch (repo) {
      'SagerNet/sing-box' => 'sing-box-$version-windows-amd64.zip',
      'XTLS/Xray-core' => 'Xray-windows-64.zip',
      _ => null,
    };
