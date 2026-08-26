import 'package:flutter/foundation.dart';

/// Текущий язык интерфейса. Через ValueNotifier, а не через состояние
/// страницы: MaterialApp стоит выше всех экранов, и переключение должно
/// доходить до них без перезапуска приложения — ровно как с темой.
final ValueNotifier<String> appLang = ValueNotifier('ru');

const Map<String, String> languageNames = {
  'ru': 'Русский',
  'en': 'English',
};

/// Строка по ключу на текущем языке.
///
/// Если перевода нет, возвращается русский вариант, а не пустота и не сам
/// ключ: недопереведённый экран должен оставаться читаемым.
/// НИКОГДА не бросает исключение. Раньше здесь стоял `assert(false, ...)` на
/// отсутствующий ключ — и одна опечатка в имени ключа положила весь экран
/// красной страницей, из которой пользователь не мог даже выйти. Цена ошибки
/// перевода не должна быть выше, чем «показали не тот текст».
String t(String key) {
  final entry = _strings[key];
  if (entry == null) {
    if (kDebugMode) debugPrint('l10n: нет строки для ключа "$key"');
    // Отдаём хвост ключа: "section.dns" -> "dns". Читается хуже перевода,
    // но экран остаётся рабочим.
    return key.contains('.') ? key.split('.').last : key;
  }
  return entry[appLang.value] ?? entry['ru'] ?? key;
}

/// Строка по ключу с подстановками: `tp('log.x', {'name': 'Vless'})`
/// заменит в шаблоне все вхождения `{name}`.
///
/// Отдельная функция, а не интерполяция в месте вызова: у лога перевод
/// обязан быть цельной строкой, иначе куски фразы («включён»/«выключен»,
/// «мс», «недоступен») остаются русскими внутри английского предложения —
/// ровно на этом уже спотыкались в UI.
String tp(String key, Map<String, Object?> args) {
  var s = t(key);
  args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

/// Словарь: ключ -> {язык -> строка}.
///
/// Ключи именуются по месту использования (`nav.`, `home.`, `settings.`),
/// чтобы при правке экрана не искать строку по всему файлу.
const Map<String, Map<String, String>> _strings = {
  // --- Навигация и общее ---
  'app.title': {'ru': 'Multik Sila', 'en': 'Multik Sila'},
  'nav.connection': {'ru': 'Подключение', 'en': 'Connection'},
  'nav.servers': {'ru': 'Серверы', 'en': 'Servers'},
  'nav.routes': {'ru': 'Маршруты', 'en': 'Routing'},
  'nav.promo': {'ru': 'VPN', 'en': 'VPN'},
  'promo.title': {'ru': 'Нужен VPN?', 'en': 'Need a VPN?'},
  'promo.text': {
    'ru': 'Подписка на серверы для Multik Sila — в телеграм-боте. '
        'Там же продление и поддержка.',
    'en': 'Server subscriptions for Multik Sila are handled by our Telegram '
        'bot — renewals and support included.',
  },
  'promo.open': {'ru': 'Открыть бота', 'en': 'Open the bot'},
  'promo.copy': {'ru': 'Скопировать ссылку', 'en': 'Copy the link'},
  'promo.copied': {'ru': 'Ссылка скопирована', 'en': 'Link copied'},
  'promo.openFailed': {
    'ru': 'Не удалось открыть Telegram — ссылка скопирована в буфер',
    'en': 'Could not open Telegram — the link has been copied instead',
  },

  'common.save': {'ru': 'Сохранить', 'en': 'Save'},
  'common.cancel': {'ru': 'Отмена', 'en': 'Cancel'},
  'common.add': {'ru': 'Добавить', 'en': 'Add'},
  'common.back': {'ru': 'Назад', 'en': 'Back'},
  'common.empty': {'ru': 'Пусто', 'en': 'Empty'},
  'common.notFound': {'ru': 'Ничего не найдено', 'en': 'Nothing found'},
  'common.ms': {'ru': 'мс', 'en': 'ms'},

  // --- Мастер первого запуска ---
  //
  // Текст соглашения — ЧЕРНОВИК, написанный по фактическому поведению
  // приложения (логи и настройки не покидают устройство, серверы приложение
  // не предоставляет, ядра — чужой открытый код). Перед публикацией его
  // должен вычитать человек: это юридический текст, а не строка интерфейса.
  'onb.licenseTitle': {
    'ru': 'Условия использования',
    'en': 'Terms of use',
  },
  'onb.licenseText': {
    'ru': 'Правообладатель: Multik\n\n'
        'Multik Sila — клиент для подключения к прокси-серверам, которые '
        'выбираете вы сами. Приложение не предоставляет серверы, не входит в '
        'состав каких-либо сервисов и не имеет отношения к содержимому '
        'передаваемого трафика.\n\n'
        '1. Программа предоставляется «как есть», без гарантий работоспособности '
        'и пригодности для конкретных задач. Правообладатель не отвечает за '
        'убытки, связанные с её использованием.\n\n'
        '2. Вы самостоятельно отвечаете за соблюдение законодательства своей '
        'страны и условий сервисов, к которым подключаетесь.\n\n'
        '3. Приложение не собирает и никуда не передаёт персональные данные. '
        'Профили, настройки и журнал работы хранятся только на этом устройстве.\n\n'
        '4. В состав входят сторонние программы с открытым исходным кодом '
        '(sing-box, Xray-core), распространяемые на условиях их собственных '
        'лицензий.\n\n'
        'Нажимая «Принимаю», вы подтверждаете согласие с этими условиями.',
    'en': 'Copyright holder: Multik\n\n'
        'Multik Sila is a client for connecting to proxy servers that you '
        'choose yourself. The application does not provide servers, is not part '
        'of any service, and has no relation to the contents of the traffic '
        'passing through it.\n\n'
        '1. The software is provided "as is", without warranty of any kind, '
        'including fitness for a particular purpose. The copyright holder is '
        'not liable for any damages arising from its use.\n\n'
        '2. You are solely responsible for complying with the laws of your '
        'country and with the terms of the services you connect to.\n\n'
        '3. The application collects no personal data and sends none anywhere. '
        'Profiles, settings and the activity log stay on this device only.\n\n'
        '4. It bundles third-party open-source software (sing-box, Xray-core) '
        'distributed under their own licenses.\n\n'
        'By pressing "Accept" you confirm your agreement with these terms.',
  },
  'onb.accept': {'ru': 'Принимаю', 'en': 'Accept'},
  'onb.decline': {'ru': 'Не согласен — выйти', 'en': 'Decline and quit'},
  'onb.profileTitle': {'ru': 'Добавьте профиль', 'en': 'Add a profile'},
  'onb.profileHint': {
    'ru': 'Вставьте ссылку на подписку — приложение само загрузит список '
        'серверов. Ссылку выдаёт ваш провайдер VPN.',
    'en': 'Paste your subscription link — the app will fetch the server list '
        'itself. The link comes from your VPN provider.',
  },
  'onb.profileUrlLabel': {'ru': 'Ссылка на подписку', 'en': 'Subscription link'},
  // Название теперь обязательно, и подпись обязана это отражать. Пока в ней
  // стояло «(необязательно)», интерфейс прямо противоречил собственной
  // проверке: поле подсвечивалось красным ровно за то, что подпись разрешала.
  'onb.profileNameLabel': {
    'ru': 'Название профиля',
    'en': 'Profile name',
  },
  'onb.profileDefaultName': {'ru': 'Профиль 1', 'en': 'Profile 1'},
  'onb.profileUrlBad': {
    'ru': 'Ссылка должна начинаться с http:// или https://',
    'en': 'The link must start with http:// or https://',
  },
  'onb.profileAdd': {'ru': 'Добавить и продолжить', 'en': 'Add and continue'},
  'onb.profileSkip': {'ru': 'Пропустить — добавлю позже', 'en': 'Skip, I will add it later'},

  // --- Шапка ---
  'bar.connections': {'ru': 'Активные соединения', 'en': 'Active connections'},
  'bar.diagnostics': {'ru': 'Диагностика и тест скорости', 'en': 'Diagnostics and speed test'},
  'bar.log': {'ru': 'Лог ядра', 'en': 'Core log'},
  'bar.settings': {'ru': 'Настройки', 'en': 'Settings'},

  // --- Главный экран ---
  'home.protectedOn': {'ru': 'Защита включена', 'en': 'Protected'},
  'home.protectedOff': {'ru': 'Защита выключена', 'en': 'Not protected'},
  // Формулировка намеренно называет, ЧТО не покрыто, а не «работает не всегда».
  // Расплывчатое предупреждение человек пролистывает, конкретное — проверяет.
  'home.proxyModeCoverage': {
    'ru': 'Обычный режим подменяет системный прокси: через VPN идут браузеры и '
        'программы, которые его читают. Игры и часть приложений ходят напрямую. '
        'Для всего трафика включите TUN.',
    'en': 'Normal mode replaces the system proxy: browsers and apps that honour '
        'it go through the VPN. Games and some apps connect directly. '
        'Turn on TUN to cover all traffic.',
  },
  'home.connect': {'ru': 'Подключить VPN', 'en': 'Connect VPN'},
  'home.disconnect': {'ru': 'Отключить VPN', 'en': 'Disconnect VPN'},
  'home.noData': {'ru': 'Нет данных', 'en': 'No data'},
  'home.connecting': {'ru': 'Подключение…', 'en': 'Connecting…'},
  'home.disconnecting': {'ru': 'Отключение…', 'en': 'Disconnecting…'},
  'home.tunHintShort': {
    'ru': 'Весь трафик системы, без настройки прокси',
    'en': 'All system traffic, no proxy setup',
  },
  'home.tunNeedAdminShort': {
    'ru': 'Потребуется перезапуск от администратора',
    'en': 'Requires a restart as administrator',
  },
  'home.noEncryption': {'ru': 'без шифрования', 'en': 'no encryption'},

  // --- Серверы ---
  'servers.searchHint': {'ru': 'Поиск сервера', 'en': 'Search server'},
  'servers.sortDefault': {'ru': 'По порядку', 'en': 'Default order'},
  'servers.sortLatency': {'ru': 'По задержке', 'en': 'By latency'},
  'servers.sortName': {'ru': 'По имени', 'en': 'By name'},
  'servers.favAdd': {'ru': 'В избранное', 'en': 'Add to favorites'},
  'servers.favRemove': {'ru': 'Убрать из избранного', 'en': 'Remove from favorites'},
  'servers.test': {'ru': 'Тест задержки', 'en': 'Latency test'},
  'servers.testing': {'ru': 'Тестирую…', 'en': 'Testing…'},
  'servers.auto': {'ru': 'Авто-выбор', 'en': 'Auto-select'},

  // --- Профили ---
  'profile.choose': {'ru': 'Выберите профиль', 'en': 'Choose a profile'},
  'profile.add': {'ru': 'Добавить профиль', 'en': 'Add profile'},
  'profile.edit': {'ru': 'Изменить профиль', 'en': 'Edit profile'},
  'profile.refresh': {'ru': 'Обновить подписку', 'en': 'Refresh subscription'},
  'profile.delete': {'ru': 'Удалить профиль', 'en': 'Delete profile'},
  'profile.addNone': {'ru': 'Добавь профиль подписки', 'en': 'Add a subscription profile'},

  // --- Маршрутизация ---
  'routing.tun': {'ru': 'TUN-режим (системный VPN)', 'en': 'TUN mode (system-wide VPN)'},
  'routing.tunOn': {
    'ru': 'Весь трафик компьютера, не только приложение',
    'en': 'All computer traffic, not just this app',
  },
  'routing.tunNeedAdmin': {
    'ru': 'Потребует перезапуска с правами администратора',
    'en': 'Requires restart with administrator rights',
  },
  'routing.label': {'ru': 'Маршрутизация', 'en': 'Routing'},
  'routing.global': {'ru': 'Весь трафик через VPN', 'en': 'All traffic through VPN'},
  'routing.bypassRu': {'ru': 'Российские сайты — напрямую', 'en': 'Russian sites — direct'},
  'color.violet': {'ru': 'Фиолетовый', 'en': 'Violet'},
  'color.blue': {'ru': 'Синий', 'en': 'Blue'},
  'color.teal': {'ru': 'Бирюзовый', 'en': 'Teal'},
  'color.green': {'ru': 'Зелёный', 'en': 'Green'},
  'color.orange': {'ru': 'Оранжевый', 'en': 'Orange'},
  'color.pink': {'ru': 'Розовый', 'en': 'Pink'},
  'color.graphite': {'ru': 'Графитовый', 'en': 'Graphite'},
  'routing.blockAds': {'ru': 'Блокировать рекламу и трекеры', 'en': 'Block ads and trackers'},
  'routing.serviceRules': {'ru': 'Правила для сервисов', 'en': 'Per-service rules'},
  'routing.customRules': {'ru': 'Свои правила маршрутизации', 'en': 'Custom routing rules'},

  // --- Действия над правилами ---
  'action.default': {'ru': 'По общему правилу', 'en': 'Follow general rule'},
  'action.proxy': {'ru': 'Через VPN', 'en': 'Through VPN'},
  'action.direct': {'ru': 'Напрямую', 'en': 'Direct'},
  'action.block': {'ru': 'Блокировать', 'en': 'Block'},

  // --- Разделы настроек ---
  'section.launch': {'ru': 'Запуск и автоматика', 'en': 'Startup and automation'},
  'section.launchHint': {'ru': 'Автозапуск, трей, автоподключение', 'en': 'Autostart, tray, auto-connect'},
  'section.look': {'ru': 'Внешний вид', 'en': 'Appearance'},
  'section.lookHint': {'ru': 'Тема, цвет и язык', 'en': 'Theme, color and language'},
  'section.sub': {'ru': 'Подписка', 'en': 'Subscription'},
  'section.subHint': {'ru': 'Автообновление серверов', 'en': 'Automatic server updates'},
  'section.latency': {'ru': 'Тест задержки', 'en': 'Latency test'},
  'section.latencyHint': {'ru': 'Что и как измеряем', 'en': 'What and how we measure'},
  'section.autoselect': {'ru': 'Авто-выбор сервера', 'en': 'Automatic server selection'},
  'section.autoselectHint': {'ru': 'Интервал, фильтр, допуск', 'en': 'Interval, filter, tolerance'},
  'section.tls': {'ru': 'Обход блокировок', 'en': 'Censorship circumvention'},
  'section.tlsHint': {'ru': 'Фрагментация TLS', 'en': 'TLS fragmentation'},
  'section.proxy': {'ru': 'Локальный прокси', 'en': 'Local proxy'},
  'section.proxyHint': {'ru': 'Порт и доступ из сети', 'en': 'Port and network access'},
  'section.dns': {'ru': 'DNS', 'en': 'DNS'},
  'section.dnsHint': {'ru': 'Серверы и автоподбор', 'en': 'Servers and auto-pick'},
  'section.tun': {'ru': 'TUN — системный VPN', 'en': 'TUN — system-wide VPN'},
  'section.tunHint': {'ru': 'Адаптер, стек, MTU', 'en': 'Adapter, stack, MTU'},
  'section.mux': {'ru': 'MUX', 'en': 'MUX'},
  'section.muxHint': {
    'ru': 'Несколько потоков в одном соединении',
    'en': 'Several streams in one connection',
  },
  // --- Обновление самого приложения ---
  'set.updateFeed': {'ru': 'Ссылка на обновления', 'en': 'Update feed URL'},
  'hint.updateFeed': {
    'ru': 'Адрес JSON вида {"version": "1.0.1", "url": "https://…/сборка.zip"}. '
        'Подойдёт GitHub Releases, свой сервер — что угодно, отдающее файл. '
        'Пусто — приложение обновлений не ищет и в сеть за ними не ходит.',
    'en': 'URL of a JSON like {"version": "1.0.1", "url": "https://…/build.zip"}. '
        'GitHub Releases, your own server — anything that serves a file. '
        'Leave empty and the app will not look for updates at all.',
  },
  'set.autoUpdateApp': {
    'ru': 'Проверять обновления приложения',
    'en': 'Check for app updates',
  },
  'hint.autoUpdateApp': {
    'ru': 'Проверка при запуске. Обновление НИКОГДА не ставится молча: '
        'перезапуск рвёт соединение, поэтому приложение сначала спросит.',
    'en': 'Checked at startup. An update is NEVER installed silently: a restart '
        'drops the connection, so the app asks first.',
  },
  'about.checkApp': {
    'ru': 'Проверить обновление приложения',
    'en': 'Check for an app update',
  },
  'app.updateFailed': {
    'ru': 'Обновиться не удалось — скачайте установщик со страницы релизов',
    'en': 'The update failed — download the installer from the releases page',
  },
  'app.noFeed': {
    'ru': 'Ссылка на обновления не задана — настройки, раздел «Обновления»',
    'en': 'No update feed set — see Settings, “Updates”',
  },
  'app.upToDate': {'ru': 'Установлена последняя версия', 'en': 'You have the latest version'},
  'app.updateTitle': {'ru': 'Вышло обновление', 'en': 'An update is available'},
  'app.updateText': {
    'ru': 'Версия {v} (у вас {cur}). Приложение скачает её, закроется и '
        'запустится заново — соединение на это время прервётся. Текущая '
        'сборка сохранится в папке backup_{cur}.',
    'en': 'Version {v} (you have {cur}). The app will download it, close and '
        'start again — the connection will drop meanwhile. The current build '
        'is kept in the backup_{cur} folder.',
  },
  'app.updateNow': {'ru': 'Обновить', 'en': 'Update'},

  'set.autoUpdateCores': {
    'ru': 'Обновлять ядра самому',
    'en': 'Update cores automatically',
  },
  'hint.autoUpdateCores': {
    'ru': 'Скачивает новую версию sing-box и Xray и применяет её при следующем '
        'запуске приложения — заменить работающий файл Windows не даёт. '
        'Понижения версии не будет: сравнивается то, что бинарь сам о себе '
        'сообщает. Если версия не определяется, ядро не трогается.',
    'en': 'Downloads a new sing-box and Xray build and applies it on the next app '
        'start — Windows will not let a running file be replaced. It never '
        'downgrades: the comparison uses the version the binary reports itself. '
        'If the version cannot be read, the core is left alone.',
  },
  // --- Просмотр конфигов ядер ---
  'cfg.title': {'ru': 'Конфиги ядер', 'en': 'Core configs'},
  'cfg.none': {
    'ru': 'Конфигов пока нет — они создаются при первом запуске ядра. '
        'Нажмите «Запустить» и загляните сюда снова.',
    'en': 'No configs yet — they are created the first time a core starts. '
        'Press “Start” and come back here.',
  },

  // --- Сетевые интерфейсы и маршруты ---
  'net.title': {'ru': 'Интерфейсы и маршруты', 'en': 'Interfaces and routes'},
  'net.refresh': {'ru': 'Обновить', 'en': 'Refresh'},
  'net.failed': {
    'ru': 'Не удалось получить данные о сети.',
    'en': 'Could not read the network data.',
  },
  'net.defaultRoutes': {'ru': 'Маршруты по умолчанию', 'en': 'Default routes'},
  'net.noRoutes': {'ru': 'Маршрутов не найдено', 'en': 'No routes found'},
  'net.interfaces': {'ru': 'Интерфейсы', 'en': 'Interfaces'},
  'net.gateway': {'ru': 'шлюз', 'en': 'gateway'},
  'net.metric': {'ru': 'метрика', 'en': 'metric'},
  'net.contested': {
    'ru': 'За маршрут по умолчанию борются несколько адаптеров с одинаковой '
        'метрикой. Обычно это значит, что рядом работает другой VPN со своим '
        'туннелем. В таком состоянии трафик может уходить в чужой туннель, '
        'а TUN-режим — вести себя непредсказуемо.',
    'en': 'Several adapters share the lowest metric for the default route. This '
        'usually means another VPN with its own tunnel is running alongside. In '
        'that state traffic may leave through the other tunnel, and TUN mode can '
        'behave unpredictably.',
  },

  'section.about': {'ru': 'О программе', 'en': 'About'},
  'section.aboutHint': {
    'ru': 'Версии ядер, пути, обновления',
    'en': 'Core versions, paths, updates',
  },
  'about.app': {'ru': 'Приложение', 'en': 'Application'},
  'about.build': {'ru': 'Сборка', 'en': 'Build'},
  'stats.apiStatus': {
    'ru': 'Ядро отвечает отказом на запрос статистики: HTTP {code}',
    'en': 'The core refuses the statistics request: HTTP {code}',
  },
  'about.folder': {'ru': 'Папка', 'en': 'Folder'},
  'about.logFile': {'ru': 'Файл лога', 'en': 'Log file'},
  'about.checkCores': {
    'ru': 'Проверить обновления ядер',
    'en': 'Check for core updates',
  },
  'about.unknownVersion': {'ru': 'версия не определяется', 'en': 'version unavailable'},
  'about.unknownHint': {
    'ru': 'Ядро собрано без номера версии, поэтому автообновление его не трогает: '
        'сравнивать не с чем и можно откатиться на более старое. Положите рядом '
        'с приложением официальную сборку — дальше оно будет обновляться само.',
    'en': 'This core was built without a version number, so auto-update leaves it '
        'alone: there is nothing to compare against and it could be downgraded. '
        'Put an official build next to the app and it will update itself from then on.',
  },
  'about.sources': {
    'ru': 'Ядра и наборы правил — открытые проекты:',
    'en': 'The cores and rule sets are open-source projects:',
  },
  'section.rules': {'ru': 'Наборы правил', 'en': 'Rule sets'},
  'section.rulesHint': {'ru': 'GeoSite, GeoIP, ACL', 'en': 'GeoSite, GeoIP, ACL'},
  'section.ntp': {'ru': 'NTP — сверка времени', 'en': 'NTP — time sync'},
  'section.ntpHint': {
    'ru': 'Лечит обрывы из-за сбитых часов',
    'en': 'Fixes drops caused by a wrong clock',
  },
  'section.updates': {'ru': 'Обновления', 'en': 'Updates'},
  'section.updatesHint': {'ru': 'Ядра и наборы правил', 'en': 'Cores and rule sets'},
  'section.misc': {'ru': 'Служебное', 'en': 'Advanced'},
  'section.miscHint': {'ru': 'Порт Clash API', 'en': 'Clash API port'},

  // --- Внешний вид ---
  'look.theme': {'ru': 'Тема', 'en': 'Theme'},
  'look.themeDark': {'ru': 'Тёмная', 'en': 'Dark'},
  'look.themeLight': {'ru': 'Светлая', 'en': 'Light'},
  'look.themeSystem': {'ru': 'Как в системе', 'en': 'Follow system'},
  'look.accent': {'ru': 'Акцентный цвет', 'en': 'Accent color'},
  'look.language': {'ru': 'Язык интерфейса', 'en': 'Interface language'},

  // --- Соединения ---
  'conn.title': {'ru': 'Соединения', 'en': 'Connections'},
  'conn.filter': {'ru': 'Фильтр по адресу', 'en': 'Filter by address'},
  'conn.closeAll': {'ru': 'Разорвать все', 'en': 'Close all'},
  'conn.none': {'ru': 'Нет активных соединений', 'en': 'No active connections'},
  'conn.direct': {'ru': 'напрямую', 'en': 'direct'},
  'conn.rule': {'ru': 'правило', 'en': 'rule'},
  'conn.noCore': {
    'ru': 'Ядро не отвечает — запущено ли соединение?',
    'en': 'Core is not responding — is the connection running?',
  },

  // --- Запуск и автоматика ---
  'set.autostart': {'ru': 'Запускать при входе в систему', 'en': 'Launch at system startup'},
  'set.autostartHint': {
    'ru': 'Запись в реестре пользователя, без прав администратора',
    'en': 'Written to the user registry, no administrator rights needed',
  },
  'set.autoConnect': {'ru': 'Подключаться сразу после запуска', 'en': 'Connect right after launch'},
  'set.hideAfterLaunch': {'ru': 'Скрывать окно после запуска', 'en': 'Hide window after launch'},
  'set.hideAfterLaunchHint': {'ru': 'Приложение стартует сразу в трей', 'en': 'App starts directly to tray'},
  'set.closeToTray': {'ru': 'Крестик сворачивает в трей', 'en': 'Close button minimizes to tray'},
  'set.closeToTrayHint': {
    'ru': 'Иначе закрытие окна полностью выключает VPN',
    'en': 'Otherwise closing the window turns the VPN off completely',
  },
  'set.disconnectOnQuit': {'ru': 'Отключать VPN при выходе', 'en': 'Disconnect VPN on exit'},
  'set.autoRestart': {'ru': 'Поднимать ядро, если оно упало', 'en': 'Restart the core if it crashes'},
  'set.autoRestartHint': {
    'ru': 'До трёх попыток подряд. Если падает раз за разом — перестаёт пытаться '
        'и пишет в лог: перезапуск не лечит ошибку в настройках.',
    'en': 'Up to three attempts in a row. If it keeps crashing it stops and writes '
        'to the log: restarting does not fix a broken configuration.',
  },

  // --- Подписка ---
  'set.subAuto': {'ru': 'Обновлять подписку автоматически', 'en': 'Update subscription automatically'},
  'set.subInterval': {'ru': 'Интервал обновления, часов', 'en': 'Update interval, hours'},
  'set.subIntervalHint': {
    'ru': '0 — использовать значение, которое присылает панель',
    'en': '0 — use the value sent by the panel',
  },

  // --- Тест задержки ---
  'set.latencyWhat': {'ru': 'Что мерить', 'en': 'What to measure'},
  'set.latencyProxy': {'ru': 'Сквозной путь через прокси', 'en': 'Full path through the proxy'},
  'set.latencyWarm': {'ru': 'Запрос по готовому соединению', 'en': 'Request over an established connection'},
  'hint.latencyWarm': {
    'ru': 'Соединение поднимается вне замера, секундомер идёт только на самом запросе. '
        'Так меряет Karing — цифры получаются в разы меньше и сравнимы с ним напрямую.',
    'en': 'The connection is established outside the measurement, the timer covers only '
        'the request itself. This is how Karing measures — the numbers are much smaller '
        'and directly comparable with it.',
  },
  'set.latencyConnect': {
    'ru': 'До сервера — как в v2rayN и Karing',
    'en': 'To the server — as in v2rayN and Karing',
  },
  'set.latencyUrl': {'ru': 'URL проверки', 'en': 'Check URL'},
  'set.latencyTimeout': {'ru': 'Таймаут, мс', 'en': 'Timeout, ms'},
  'set.latencyWarmup': {'ru': 'Прогревочный запрос', 'en': 'Warm-up request'},
  'set.presets': {'ru': 'Готовые варианты', 'en': 'Presets'},

  // --- Авто-выбор ---
  'set.autoOnConnect': {
    'ru': 'Выбирать самый быстрый при подключении',
    'en': 'Pick the fastest server when connecting',
  },
  'set.autoInterval': {'ru': 'Интервал перепроверки, мин', 'en': 'Re-check interval, min'},
  'set.tolerance': {'ru': 'Допуск, мс', 'en': 'Tolerance, ms'},
  'set.autoFilter': {'ru': 'Фильтр по названию', 'en': 'Filter by name'},
  'set.autoLimit': {'ru': 'Ограничить число серверов', 'en': 'Limit number of servers'},
  'set.favFirst': {'ru': 'Избранные первыми', 'en': 'Favorites first'},

  // --- Обход блокировок ---
  'set.tlsFragment': {'ru': 'Фрагментация TLS', 'en': 'TLS fragmentation'},
  'set.tlsRecordFragment': {'ru': 'Дробление TLS-записей', 'en': 'TLS record fragmentation'},
  'set.tlsInsecure': {'ru': 'Не проверять сертификат', 'en': 'Skip certificate verification'},

  // --- Локальный прокси ---
  'set.port': {'ru': 'Порт', 'en': 'Port'},
  'set.allowLan': {'ru': 'Доступ из локальной сети', 'en': 'Allow access from local network'},
  'set.systemProxy': {'ru': 'Настраивать системный прокси', 'en': 'Configure system proxy'},
  'set.bypassList': {'ru': 'Не пускать через прокси', 'en': 'Bypass the proxy for'},

  // --- DNS ---
  'set.dnsDirect': {'ru': 'Прямой DNS', 'en': 'Direct DNS'},
  'set.dnsRemote': {'ru': 'DNS через туннель', 'en': 'DNS through the tunnel'},
  'set.dnsAutoPick': {'ru': 'Подобрать DNS автоматически', 'en': 'Pick DNS automatically'},
  'set.dnsPicking': {'ru': 'Опрашиваю серверы…', 'en': 'Querying servers…'},
  'set.dnsHijack': {'ru': 'Перехватывать DNS в TUN', 'en': 'Hijack DNS in TUN'},
  'set.dnsFakeIp': {'ru': 'FakeIP', 'en': 'FakeIP'},
  'set.reset': {
    'ru': 'Сбросить настройки',
    'en': 'Reset settings',
  },
  'hint.reset': {
    'ru': 'Вернуть все значения по умолчанию. Профили и подписки останутся',
    'en': 'Restore every value to its default. Profiles and subscriptions stay',
  },
  'dlg.resetText': {
    'ru': 'Все настройки вернутся к значениям по умолчанию: DNS, TUN, '
        'маршрутизация, автозапуск и остальное.\n\nПрофили, подписки и '
        'сохранённые серверы НЕ затрагиваются.\n\nПродолжить?',
    'en': 'Every setting goes back to its default: DNS, TUN, routing, '
        'startup behaviour and the rest.\n\nProfiles, subscriptions and saved '
        'servers are NOT affected.\n\nContinue?',
  },
  'set.dnsProxyResolve': {
    'ru': 'Способ разрешения в DNS',
    'en': 'DNS resolution method',
  },
  'dns.mode.current': {'ru': 'Текущий сервер', 'en': 'Current server'},
  'dns.mode.direct': {'ru': 'Напрямую', 'en': 'Direct'},
  'dns.mode.fakeip': {'ru': 'FakeIP', 'en': 'FakeIP'},
  // Подпись меняется вместе с выбором: у каждого способа своя цена, и знать
  // её человек должен до того, как переключит, а не после.
  'hint.dnsProxyResolve.current': {
    'ru': 'Домены резолвит активный сервер. Адрес приходит тот же, что увидит '
        'сервер при подключении — самый предсказуемый вариант.',
    'en': 'Domains are resolved by the active server, so the address matches '
        'what the server will see — the most predictable option.',
  },
  'hint.dnsProxyResolve.direct': {
    'ru': 'Домены резолвятся мимо туннеля. Быстрее, но провайдер видит, что вы '
        'запрашиваете, а в TUN-режиме этот путь может не работать вовсе.',
    'en': 'Domains are resolved outside the tunnel. Faster, but your ISP sees '
        'the queries, and in TUN mode this path may not work at all.',
  },
  'hint.dnsProxyResolve.fakeip': {
    'ru': 'Адрес выдаётся мгновенно, настоящий узнаётся уже при подключении — '
        'убирает ожидание DNS перед каждым запросом. Домены, которым нужен '
        'настоящий адрес (обход РФ, ваши списки), резолвятся честно.',
    'en': 'The address is returned instantly and the real one is resolved when '
        'connecting, removing the DNS wait before every request. Domains that '
        'need a real address (RU bypass, your own lists) still resolve honestly.',
  },
  'set.dnsTtl': {'ru': 'Переписывать TTL, секунд', 'en': 'Rewrite TTL, seconds'},
  'set.dnsEcs': {'ru': 'ECS — подсеть клиента', 'en': 'ECS — client subnet'},
  'set.dnsHosts': {'ru': 'Статические записи', 'en': 'Static entries'},
  'set.dnsStrategy': {'ru': 'Режим IPv6', 'en': 'IPv6 mode'},
  // Подписи стратегий по-человечески: пользователю решать «нужен ли IPv6»,
  // а не вспоминать, чем prefer_ipv4 отличается от ipv4_only.
  'ipv6.ipv4_only': {'ru': 'Выключен (только IPv4)', 'en': 'Off (IPv4 only)'},
  'ipv6.prefer_ipv4': {
    'ru': 'Включён, сначала IPv4',
    'en': 'On, IPv4 first',
  },
  'ipv6.prefer_ipv6': {
    'ru': 'Включён, сначала IPv6',
    'en': 'On, IPv6 first',
  },
  'ipv6.ipv6_only': {'ru': 'Только IPv6', 'en': 'IPv6 only'},

  // --- TUN ---
  'set.tunName': {'ru': 'Имя адаптера', 'en': 'Adapter name'},
  'set.tunIpv4': {'ru': 'IPv4-адрес адаптера', 'en': 'Adapter IPv4 address'},
  'set.tunIpv6': {'ru': 'IPv6-адрес адаптера', 'en': 'Adapter IPv6 address'},
  'set.tunIpv6On': {'ru': 'Перехватывать IPv6', 'en': 'Capture IPv6'},
  'set.tunStack': {'ru': 'Сетевой стек', 'en': 'Network stack'},
  'set.tunStackHint': {
    'ru': 'system — быстрее, gvisor — совместимее',
    'en': 'system — faster, gvisor — more compatible',
  },
  'set.tunMtu': {'ru': 'MTU', 'en': 'MTU'},
  'set.strictRoute': {'ru': 'Строгая маршрутизация', 'en': 'Strict routing'},

  // --- Mux ---
  'set.muxOn': {'ru': 'Включить MUX', 'en': 'Enable MUX'},
  'set.muxProtocol': {'ru': 'Протокол', 'en': 'Protocol'},
  'set.muxStreams': {'ru': 'Потоков в одном соединении', 'en': 'Streams per connection'},
  'set.muxPadding': {'ru': 'Заполнение', 'en': 'Padding'},

  // --- Обновления ---
  'set.checkCores': {'ru': 'Проверять обновления ядер', 'en': 'Check for core updates'},
  'set.ruleSetDays': {'ru': 'Обновлять наборы правил, дней', 'en': 'Refresh rule sets, days'},
  'set.clashPort': {'ru': 'Порт Clash API', 'en': 'Clash API port'},

  // --- Пояснения под полями ---
  'hint.tlsIntro': {
    'ru': 'Помогает, когда соединение опознают по первому пакету. Не поможет, '
        'если сам сервер недоступен по сети — это решается на его стороне.',
    'en': 'Helps when the connection is identified by its first packet. Will not help '
        'if the server itself is unreachable — that is solved on the server side.',
  },
  'hint.tlsFragment': {
    'ru': 'Приветствие TLS дробится на части, и опознать его целиком сложнее',
    'en': 'The TLS hello is split into pieces, making it harder to identify as a whole',
  },
  'hint.tlsRecordFragment': {
    'ru': 'Отдельный приём, работает независимо от фрагментации',
    'en': 'A separate technique, works independently of fragmentation',
  },
  'hint.tlsInsecure': {
    'ru': 'Снимает защиту от подмены сертификата. Включайте только если сервер '
        'иначе не подключается и вы ему доверяете.',
    'en': 'Removes protection against certificate spoofing. Enable only if the server '
        'will not connect otherwise and you trust it.',
  },
  'hint.dnsHijack': {
    'ru': 'Разворачивает на наш сервер запросы программ с зашитым DNS. Без этого '
        'они ходят мимо туннеля, и разделение трафика для них не работает.',
    'en': 'Redirects queries from apps with hard-coded DNS to our server. Without it '
        'they bypass the tunnel and split routing does not work for them.',
  },
  'hint.dnsFakeIp': {
    'ru': 'Адрес выдаётся мгновенно, настоящий узнаётся при подключении — убирает '
        'ожидание DNS перед каждым запросом. Домены, которым нужен настоящий адрес '
        '(обход РФ, ваши списки), система резолвит честно.',
    'en': 'The address is returned instantly, the real one is resolved when connecting — '
        'this removes the DNS wait before every request. Domains that need a real '
        'address (Russia bypass, your own lists) are still resolved honestly.',
  },
  'hint.muxFull': {
    'ru': 'Много логических соединений внутри одного физического. Требует поддержки '
        'на СТОРОНЕ СЕРВЕРА — если её нет, соединение просто перестаёт работать. '
        'Проверено на вашей подписке: с MUX сервер отвечает обрывом (без MUX — 0.4 с, '
        'с MUX — обрыв через 2.4 с). Включайте только если провайдер подтвердил '
        'поддержку, и сразу проверяйте кнопкой «Тест задержки».',
    'en': 'Many logical connections inside one physical connection. Requires SERVER-SIDE '
        'support — without it the connection simply stops working. '
        'Measured on your subscription: with MUX the server replies with a drop '
        '(without MUX — 0.4 s, with MUX — dropped after 2.4 s). Enable only if your '
        'provider confirmed support, and check right away with the latency test.',
  },
  'hint.muxVision': {
    'ru': 'К серверам с flow xtls-rprx-vision MUX не применяется: Vision сам управляет '
        'потоком, и MUX поверх него ломает соединение. Такие серверы продолжат работать без него.',
    'en': 'MUX is not applied to servers with flow xtls-rprx-vision: Vision manages the '
        'stream itself and MUX on top of it breaks the connection. Such servers keep working without it.',
  },
  'hint.ruleSetsBuiltIn': {
    'ru': 'Наборы правил (РФ, реклама) вшиты в приложение, поэтому работают и без '
        'интернета — обновление лишь освежает их.',
    'en': 'Rule sets (Russia, ads) are bundled with the app, so they work without internet — '
        'refreshing only brings them up to date.',
  },
  'sub.parsed': {'ru': 'Распознано серверов', 'en': 'Servers recognised'},
  'sub.skipped': {'ru': 'пропущено', 'en': 'skipped'},
  'sub.used': {'ru': 'Израсходовано', 'en': 'Used'},
  'sub.of': {'ru': 'из', 'en': 'of'},
  'sub.expired': {'ru': 'срок истёк', 'en': 'expired'},
  'sub.noExpiry': {'ru': 'без ограничения по сроку', 'en': 'no expiry'},
  'sub.unlimited': {'ru': 'безлимит', 'en': 'unlimited'},
  'sub.updated': {'ru': 'обновлено', 'en': 'updated'},
  'sub.at': {'ru': 'в', 'en': 'at'},
  'sub.cached': {'ru': 'серверов', 'en': 'servers'},
  'sub.loading': {'ru': 'Загружаю подписку', 'en': 'Loading subscription'},
  'sub.readFail': {'ru': 'Не удалось прочитать файл профиля', 'en': 'Could not read the profile file'},
  'sub.httpError': {'ru': 'Ошибка загрузки: HTTP', 'en': 'Download error: HTTP'},
  'sub.error': {'ru': 'Ошибка', 'en': 'Error'},
  'sub.profile': {'ru': 'Профиль', 'en': 'Profile'},
  'hint.dnsStrategy': {
    'ru': 'Выключите, если сервер не выпускает IPv6 наружу. «Сначала IPv4» не спасает: '
        'AAAA всё равно отдаётся, и Windows берёт IPv6. Отдельно от этого переключается '
        'перехват IPv6 адаптером TUN.',
    'en': 'Turn it off if the server has no IPv6 egress. “IPv4 first” does not help: '
        'AAAA is still returned and Windows picks IPv6. Capturing IPv6 on the TUN '
        'adapter is a separate switch.',
  },
  'cr.title': {'ru': 'Свои правила', 'en': 'Custom rules'},
  'cr.intro1': {
    'ru': 'По одной записи в строке: домен или IP-адрес с подсетью. Домен ловит и все '
        'поддомены: запись «example.com» покроет и «www.example.com».',
    'en': 'One entry per line: a domain or an IP address with a subnet. A domain also '
        'covers its subdomains: "example.com" also matches "www.example.com".',
  },
  'cr.intro2': {
    'ru': 'Эти списки важнее готовых наборов — если сайт попал и сюда, и в «Российские '
        'сайты», победит ваш выбор.',
    'en': 'These lists take priority over the built-in sets — if a site is both here and '
        'in "Russian sites", your choice wins.',
  },
  'cr.direct': {'ru': 'Напрямую, мимо VPN', 'en': 'Direct, bypassing the VPN'},
  'cr.directHint': {
    'ru': 'Банки, госуслуги, локальная сеть — всё, что должно видеть ваш настоящий адрес.',
    'en': 'Banks, government services, local network — anything that must see your real address.',
  },
  'cr.proxy': {'ru': 'Обязательно через VPN', 'en': 'Always through the VPN'},
  'cr.proxyHint': {
    'ru': 'Перебивает обход: пригодится, когда сайт ошибочно считается российским.',
    'en': 'Overrides the bypass: useful when a site is wrongly treated as Russian.',
  },
  'cr.block': {'ru': 'Блокировать', 'en': 'Block'},
  'cr.blockHint': {
    'ru': 'Соединение обрывается сразу. Пригодится для рекламы и трекеров сверх готового списка.',
    'en': 'The connection is dropped immediately. Useful for ads and trackers beyond the built-in list.',
  },
  'diag.title': {'ru': 'Диагностика', 'en': 'Diagnostics'},
  'diag.run': {'ru': 'Запустить проверку', 'en': 'Run check'},
  'diag.running': {'ru': 'Проверяю…', 'en': 'Checking…'},
  'diag.coreRunning': {'ru': 'Ядро запущено', 'en': 'Core is running'},
  'diag.tunMode': {'ru': 'Режим TUN', 'en': 'TUN mode'},
  'diag.localProxy': {'ru': 'Локальный прокси отвечает', 'en': 'Local proxy responds'},
  'diag.clashApi': {'ru': 'Clash API отвечает', 'en': 'Clash API responds'},
  'diag.dns': {'ru': 'DNS резолвит имена', 'en': 'DNS resolves names'},
  'diag.server': {'ru': 'Прокси-сервер доступен', 'en': 'Proxy server reachable'},
  'diag.internet': {'ru': 'Интернет через туннель', 'en': 'Internet through the tunnel'},
  'diag.exitIp': {'ru': 'Внешний адрес', 'en': 'External address'},
  'diag.notRunning': {'ru': 'ядро не запущено — нажмите щит на главном экране', 'en': 'core is not running — tap the shield on the main screen'},
  'diag.works': {'ru': 'работает', 'en': 'running'},
  'diag.tunNote': {'ru': 'системный VPN, локальный прокси не используется', 'en': 'system-wide VPN, the local proxy is not used'},
  'diag.portOk': {'ru': 'порт принимает соединения', 'en': 'port accepts connections'},
  'diag.noServer': {'ru': 'сервер не выбран', 'en': 'no server selected'},
  'diag.code': {'ru': 'код', 'en': 'code'},
  'diag.in': {'ru': 'за', 'en': 'in'},
  'diag.speedTitle': {'ru': 'Тест скорости', 'en': 'Speed test'},
  'diag.speedNote': {
    'ru': 'Скачивает 20 МБ через активное соединение. Показывает реальную пропускную '
        'способность туннеля, а не задержку.',
    'en': 'Downloads 20 MB through the active connection. Shows the real throughput of '
        'the tunnel, not the latency.',
  },
  'diag.speedRun': {'ru': 'Измерить скорость', 'en': 'Measure speed'},
  'diag.speedRunning': {'ru': 'Качаю…', 'en': 'Downloading…'},
  'diag.mbits': {'ru': 'Мбит/с', 'en': 'Mbit/s'},
  'diag.mb': {'ru': 'МБ', 'en': 'MB'},
  'diag.sec': {'ru': 'с', 'en': 's'},
  'diag.speedFail': {'ru': 'Не удалось', 'en': 'Failed'},
  'hint.clashPort': {'ru': 'Через него переключаются серверы без рестарта', 'en': 'Used to switch servers without restarting the core'},
  'hint.dnsTtl': {'ru': '0 — оставлять как есть', 'en': '0 — leave unchanged'},
  'hint.dnsEcs': {
    'ru': 'Например 95.24.0.0/16. Пусто — не отправлять. Помогает получать адреса '
        'ближайших серверов, но раскрывает вашу примерную сеть.',
    'en': 'For example 95.24.0.0/16. Empty — do not send. Helps to get addresses of '
        'nearby servers, but reveals your approximate network.',
  },
  'hint.dnsHosts': {
    'ru': 'По строке на запись: домен=адрес. Отвечают мгновенно, без сети.',
    'en': 'One entry per line: domain=address. Answered instantly, without network.',
  },
  'hint.dnsDirect': {'ru': 'Для доменов в обход туннеля', 'en': 'For domains bypassing the tunnel'},
  'hint.dnsRemote': {'ru': 'Для всего остального', 'en': 'For everything else'},
  'hint.presetsDirect': {
    'ru': 'Готовые варианты — прямой DNS',
    'en': 'Presets — direct DNS',
  },
  'hint.presetsRemote': {
    'ru': 'Готовые варианты — DNS через туннель',
    'en': 'Presets — DNS through the tunnel',
  },
  'hint.allowLan': {
    'ru': 'Прокси станет виден другим устройствам в сети',
    'en': 'The proxy becomes visible to other devices on the network',
  },
  'hint.systemProxy': {
    'ru': 'Без этого в обычном режиме трафик идёт мимо туннеля: браузер и Telegram '
        'про наш прокси не знают. Прежнее значение возвращается при остановке.',
    'en': 'Without it, in normal mode traffic bypasses the tunnel: the browser and '
        'Telegram do not know about our proxy. The previous value is restored on stop.',
  },
  'hint.bypassList': {
    'ru': 'Через точку с запятой. Без этого списка роутер, принтеры, сетевые диски '
        'и localhost пойдут в туннель и перестанут отвечать.',
    'en': 'Semicolon-separated. Without this list the router, printers, network drives '
        'and localhost go through the tunnel and stop responding.',
  },
  'hint.port': {'ru': 'HTTP и SOCKS на одном порту (mixed)', 'en': 'HTTP and SOCKS on one port (mixed)'},
  'hint.tunIpv6': {
    'ru': 'Без этого IPv6-трафик уходит мимо туннеля, и браузер долго ждёт таймаута',
    'en': 'Without it IPv6 traffic bypasses the tunnel and the browser waits for a long timeout',
  },
  'hint.strictRoute': {
    'ru': 'Не даёт трафику утекать мимо туннеля',
    'en': 'Prevents traffic from leaking outside the tunnel',
  },
  'hint.autoOnConnect': {
    'ru': 'Если задержки ещё не измерены — тест запустится сам. Когда цифры уже есть, '
        'повторно не гоняется.',
    'en': 'If latencies are not measured yet, the test runs automatically. When numbers '
        'already exist, it is not repeated.',
  },
  'hint.autoInterval': {'ru': '0 — не проверять по расписанию', 'en': '0 — no scheduled checks'},
  'hint.tolerance': {
    'ru': 'Не переключаться, если текущий сервер отстаёт меньше чем на столько',
    'en': 'Do not switch if the current server lags behind by less than this',
  },
  'hint.autoFilter': {'ru': 'Пусто — участвуют все серверы', 'en': 'Empty — all servers take part'},
  'hint.autoLimit': {'ru': '0 — без ограничения', 'en': '0 — no limit'},
  'hint.favFirst': {
    'ru': 'Помеченные звёздочкой имеют приоритет при авто-выборе',
    'en': 'Starred servers take priority in automatic selection',
  },
  'hint.latencyWarmup': {
    'ru': 'Точнее для xhttp-серверов, но тест идёт вдвое дольше',
    'en': 'More accurate for xhttp servers, but the test takes twice as long',
  },
  'hint.muxStreams': {'ru': 'Обычно 4–16', 'en': 'Usually 4–16'},
  'hint.muxPadding': {
    'ru': 'Маскирует характерный размер пакетов',
    'en': 'Masks the characteristic packet size',
  },
  'hint.subAuto': {
    'ru': 'Интервал берётся из заголовка, который присылает сама панель',
    'en': 'The interval is taken from the header sent by the panel itself',
  },
  'hint.checkCores': {
    'ru': 'Только уведомление. Файлы ядер приложение само не подменяет: Windows не даёт '
        'перезаписать работающий файл, а замена оборвала бы соединение.',
    'en': 'Notification only. The app does not replace core files itself: Windows will not '
        'overwrite a running file, and replacing it would drop the connection.',
  },
  'hint.ruleSetDays': {
    'ru': '0 — не обновлять. При неудачной загрузке остаётся прежний набор.',
    'en': '0 — do not refresh. If the download fails, the previous set is kept.',
  },

  // --- Трей ---
  'tray.show': {'ru': 'Показать окно', 'en': 'Show window'},
  'tray.connect': {'ru': 'Подключить', 'en': 'Connect'},
  'tray.disconnect': {'ru': 'Отключить', 'en': 'Disconnect'},
  'tray.quit': {'ru': 'Выход', 'en': 'Quit'},

  // --- Диалоги профиля ---
  'dlg.name': {'ru': 'Название', 'en': 'Name'},
  'dlg.subUrl': {'ru': 'Ссылка на подписку', 'en': 'Subscription link'},
  'dlg.newProfile': {'ru': 'Новый профиль', 'en': 'New profile'},
  'dlg.pasteContent': {'ru': 'Вставить содержимое', 'en': 'Paste content'},
  'dlg.pasteHint': {
    'ru': 'Ссылки серверов или содержимое подписки',
    'en': 'Server links or subscription content',
  },
  'dlg.fileConfigs': {'ru': 'Подписки и конфиги', 'en': 'Subscriptions and configs'},
  'dlg.fileAll': {'ru': 'Все файлы', 'en': 'All files'},

  // --- Прочие подписи ---
  'set.tlsDelay': {'ru': 'Задержка отката, sing-box', 'en': 'Fallback delay, sing-box'},
  'set.fragLength': {'ru': 'Размер фрагмента, Xray', 'en': 'Fragment size, Xray'},
  'set.fragInterval': {'ru': 'Пауза между фрагментами, Xray', 'en': 'Fragment interval, Xray'},
  'hint.example500ms': {'ru': 'Например 500ms', 'en': 'For example 500ms'},
  'hint.range100': {'ru': 'Диапазон, например 100-200', 'en': 'A range, for example 100-200'},
  'hint.example1020': {'ru': 'Например 10-20', 'en': 'For example 10-20'},

  // --- Правила для сервисов ---
  'svc.title': {'ru': 'Правила для сервисов', 'en': 'Per-service rules'},
  'svc.search': {'ru': 'Поиск сервиса', 'en': 'Search service'},
  'svc.resetAll': {'ru': 'Сбросить все', 'en': 'Reset all'},
  'svc.intro': {
    'ru': 'Эти правила важнее режима маршрутизации, но уступают вашим личным '
        'спискам в «Своих правилах».',
    'en': 'These rules take priority over the routing mode, but yield to your own '
        'lists in "Custom rules".',
  },

  // --- Статус на главном экране ---
  'stat.server': {'ru': 'Сервер', 'en': 'Server'},
  'stat.connections': {'ru': 'Активных соединений', 'en': 'Active connections'},
  'stat.down': {'ru': 'Скачано', 'en': 'Downloaded'},
  'stat.up': {'ru': 'Отправлено', 'en': 'Uploaded'},

  // --- Диалоги ---
  'dlg.autostartTitle': {
    'ru': 'Запускать вместе с Windows?',
    'en': 'Start with Windows?',
  },
  'dlg.autostartText': {
    'ru': 'Приложение будет запускаться при входе в систему и подключаться '
        'само — VPN окажется готов к моменту, когда он понадобится. '
        'Переключить можно в настройках, в разделе «Запуск и автоматика».',
    'en': 'The app will start when you sign in and connect on its own, so the '
        'VPN is ready by the time you need it. You can change this later in '
        'Settings, under “Startup and automation”.',
  },
  'dlg.autostartYes': {'ru': 'Запускать', 'en': 'Start with Windows'},
  'dlg.autostartNo': {'ru': 'Не надо', 'en': 'No thanks'},
  'dlg.needAdmin': {'ru': 'Нужны права администратора', 'en': 'Administrator rights required'},
  'dlg.needAdminText': {
    'ru': 'TUN-режим (системный VPN на весь компьютер) требует прав администратора. '
        'Перезапустить приложение с повышенными правами?',
    'en': 'TUN mode (system-wide VPN) requires administrator rights. '
        'Restart the application with elevated rights?',
  },
  'dlg.restart': {'ru': 'Перезапустить', 'en': 'Restart'},
  'dlg.restoreTitle': {'ru': 'Восстановить из копии?', 'en': 'Restore from backup?'},
  'dlg.restoreText': {
    'ru': 'Текущие настройки, профили и избранное будут заменены.',
    'en': 'Current settings, profiles and favorites will be replaced.',
  },
  'dlg.restore': {'ru': 'Восстановить', 'en': 'Restore'},

  // --- Пояснения к тесту задержки ---
  'hint.latencyConnect': {
    'ru': 'Путь до самого сервера, без выхода наружу — 25–40 мс, те же цифры, '
        'что показывают v2rayN и Karing. Успех означает, что порт принимает '
        'соединения: сломанный прокси так не поймать, поэтому работоспособность '
        'проверяется отдельно, в момент подключения. Если все серверы подписки '
        'на одном хосте, цифры у них совпадут — тогда выбирайте сквозной режим.',
    'en': 'The path to the server itself, without going out — 25–40 ms, the same '
        'numbers v2rayN and Karing show. Success means the port accepts '
        'connections: a broken proxy is not caught this way, so whether it works '
        'is checked separately, on connect. If every server of the subscription '
        'shares one host their numbers will match — then pick the full-path mode.',
  },
  'hint.latencyProxy': {
    'ru': 'Медленнее, цифры больше (100–200 мс) — это реальное время до сайта и обратно. '
        'Зато нерабочий сервер сразу виден как «недоступен».',
    'en': 'Slower, bigger numbers (100–200 ms) — this is the real round trip to a site. '
        'On the other hand a dead server is immediately shown as unavailable.',
  },
  'hint.latencyUrl': {
    'ru': 'Чем ближе адрес к прокси-серверу, тем меньше цифра: замерено через один '
        'и тот же сервер — Cloudflare 82 мс, Google 117 мс, Gstatic 416 мс. '
        'Оставляйте https: обычный HTTP рвёт соединение после прогрева.',
    'en': 'The closer the address is to the proxy server, the smaller the number: measured '
        'through the same server — Cloudflare 82 ms, Google 117 ms, Gstatic 416 ms. '
        'Keep https: plain HTTP drops the connection after the warm-up request.',
  },

  // --- Лог ---
  'log.title': {'ru': 'Лог ядра', 'en': 'Core log'},
  'log.copy': {'ru': 'Скопировать', 'en': 'Copy'},
  'log.copied': {'ru': 'Лог скопирован', 'en': 'Log copied'},

  // --- Наборы правил и NTP ---
  'rules.intro': {
    'ru': 'Наборы, по которым работает режим «Российские сайты — напрямую». '
        'Выключенный набор просто не попадает в конфиг ядра — трафик по нему '
        'идёт через VPN, как обычно.',
    'en': 'The sets behind the “Russian sites go direct” mode. A disabled set is '
        'simply left out of the core config — its traffic goes through the VPN as usual.',
  },
  'rules.geosite': {'ru': 'GeoSite — по доменам', 'en': 'GeoSite — by domain'},
  'rules.geositeHint': {
    'ru': 'Список российских доменов. Работает всегда, но только для того, '
        'что пришло доменом, а не голым адресом.',
    'en': 'The list of Russian domains. Always works, but only for traffic that '
        'arrives as a domain rather than a bare address.',
  },
  'rules.geoip': {'ru': 'GeoIP — по адресам', 'en': 'GeoIP — by address'},
  'rules.geoipHint': {
    'ru': 'Ловит и голый IP, но заставляет ядро резолвить каждый домен, чтобы '
        'узнать страну. На медленном DNS выключение заметно ускоряет открытие сайтов.',
    'en': 'Also catches bare IPs, but makes the core resolve every domain to learn '
        'its country. On a slow DNS, turning it off noticeably speeds up page loads.',
  },
  'rules.aclNote': {
    'ru': 'ACL — набор блокировки рекламы и трекеров. Он не зависит от режима '
        'маршрутизации и включается галочкой «Блокировать рекламу» на главном экране.',
    'en': 'ACL is the ad and tracker blocklist. It does not depend on the routing '
        'mode and is toggled by “Block ads” on the main screen.',
  },
  // --- Правила для приложений ---
  'app.title2': {'ru': 'Правила для программ', 'en': 'Per-app rules'},
  'app.intro': {
    'ru': 'Отдельное правило для программы: всегда через VPN, всегда напрямую '
        'или совсем без сети. Правило привязано к пути файла, а не к имени '
        'процесса — под одним именем в системе могут работать разные программы. '
        'Эти правила сильнее всех остальных.',
    'en': 'A dedicated rule for a program: always through the VPN, always direct, '
        'or no network at all. The rule is bound to the file path, not the process '
        'name — different programs can share a name. These rules override all others.',
  },
  // Тот же экран на Android: программа опознаётся именем пакета, а список
  // даёт система целиком — «запущенные» там ни при чём.
  'app.introAndroid': {
    'ru': 'Отдельное правило для приложения: всегда через VPN, всегда напрямую '
        'или совсем без сети. Правило привязано к имени пакета. Эти правила '
        'сильнее всех остальных.',
    'en': 'A dedicated rule for an app: always through the VPN, always direct, or '
        'no network at all. The rule is bound to the package name. These rules '
        'override all others.',
  },
  'app.listInstalled': {'ru': 'Показать приложения', 'en': 'Show apps'},
  'app.installed': {'ru': 'Установленные', 'en': 'Installed'},
  'app.exeFiles': {'ru': 'Программы', 'en': 'Programs'},
  'app.listRunning': {'ru': 'Показать запущенные', 'en': 'Show running'},
  'app.addByFile': {'ru': 'Выбрать .exe', 'en': 'Pick an .exe'},
  'app.running': {'ru': 'Запущенные сейчас', 'en': 'Running now'},
  'app.none': {
    'ru': 'Правил пока нет. Выберите программу ниже.',
    'en': 'No rules yet. Pick a program below.',
  },
  'app.versionedPathNote': {
    'ru': 'Некоторые программы (Discord, Teams) держат файл в папке с номером '
        'версии. После их обновления путь меняется, и правило перестаёт '
        'срабатывать — его нужно задать заново.',
    'en': 'Some programs (Discord, Teams) keep their file in a folder named after '
        'the version. After such a program updates, the path changes and the rule '
        'stops matching — set it again.',
  },

  // --- QR-коды ---
  'qr.copied': {'ru': 'Ссылка скопирована', 'en': 'Link copied'},
  'qr.tooLong': {
    'ru': 'Ссылка слишком длинная для QR-кода — скопируйте её кнопкой ниже.',
    'en': 'The link is too long for a QR code — copy it with the button below.',
  },
  'qr.importedName': {'ru': 'Профиль из QR', 'en': 'Profile from QR'},
  'qr.profile': {'ru': 'QR-код подписки', 'en': 'Subscription QR code'},
  'qr.hint': {
    'ru': 'Долгое нажатие на сервере в списке показывает его QR-код.',
    'en': 'Long-press a server in the list to see its QR code.',
  },

  // --- Статистика ---
  'stats.title': {'ru': 'Статистика', 'en': 'Statistics'},
  'stats.speedDown': {'ru': 'Скачивание', 'en': 'Download'},
  'stats.speedUp': {'ru': 'Отдача', 'en': 'Upload'},
  'stats.lastMinute': {'ru': 'Скорость за последнюю минуту', 'en': 'Speed over the last minute'},
  'stats.totalDown': {'ru': 'Скачано', 'en': 'Downloaded'},
  'stats.totalUp': {'ru': 'Отправлено', 'en': 'Uploaded'},
  'stats.active': {'ru': 'Соединений', 'en': 'Connections'},
  'stats.topHosts': {'ru': 'Больше всего трафика', 'en': 'Heaviest hosts'},
  'stats.note': {
    'ru': 'Счётчики ведёт само ядро и обнуляет их при каждом перезапуске. '
        'Работает только с ядром sing-box: у Xray нет Clash API.',
    'en': 'The counters are kept by the core itself and reset on every restart. '
        'Works with the sing-box core only: Xray has no Clash API.',
  },

  'ntp.enable': {'ru': 'Сверять время', 'en': 'Sync time'},
  'ntp.hint': {
    'ru': 'Reality и VMess рвут соединение, если часы разошлись больше чем на пару '
        'минут. Ядро держит своё время, системные часы не трогаются — права '
        'администратора не нужны.',
    'en': 'Reality and VMess drop the connection if the clock is off by more than a '
        'couple of minutes. The core keeps its own time; the system clock is left '
        'alone — no administrator rights needed.',
  },
  'ntp.presets': {'ru': 'Готовые серверы', 'en': 'Preset servers'},
  'ntp.server': {'ru': 'Сервер времени', 'en': 'Time server'},
  'ntp.port': {'ru': 'Порт', 'en': 'Port'},
  'ntp.interval': {'ru': 'Как часто сверять', 'en': 'Sync interval'},
  'ntp.intervalHint': {
    'ru': 'Например 30m или 1h',
    'en': 'For example 30m or 1h',
  },

  // --- Мелочи UI, добавленные позже основного перевода ---
  'core.updateAvailable': {
    'ru': 'Вышло обновление ядра: {list}',
    'en': 'A core update is available: {list}',
  },
  'core.upToDate': {'ru': 'Ядра актуальны', 'en': 'Cores are up to date'},
  'backup.saved': {'ru': 'Резервная копия сохранена', 'en': 'Backup saved'},
  'backup.badFile': {'ru': 'Файл не подошёл: {e}', 'en': 'Unsuitable file: {e}'},
  'dlg.pastedProfile': {'ru': 'Вставленный профиль', 'en': 'Pasted profile'},
  'home.noProfiles': {
    'ru': 'Нет профилей — добавь подписку',
    'en': 'No profiles — add a subscription',
  },
  'set.customValue': {'ru': 'Свой вариант', 'en': 'Custom value'},
  'set.muxDefault': {'ru': 'h2mux — по умолчанию', 'en': 'h2mux — default'},
  'conn.via': {'ru': 'через {name}', 'en': 'via {name}'},
  'sub.untilDate': {
    'ru': 'до {date} (осталось {days} дн.)',
    'en': 'until {date} ({days} days left)',
  },
  'sub.formatLinks': {'ru': 'список ссылок', 'en': 'link list'},
  'sub.unknownFormat': {
    'ru': 'Формат подписки не распознан. Понимаем: список ссылок '
        '(vless, vmess, trojan, hysteria2, ss), Clash YAML и конфиг sing-box.',
    'en': 'Subscription format not recognised. Supported: a link list '
        '(vless, vmess, trojan, hysteria2, ss), Clash YAML and a sing-box config.',
  },
  'sub.revoked': {
    'ru': 'Доступ по этой подписке отозван ({reason})',
    'en': 'This subscription has been revoked ({reason})',
  },
  'sub.revokedStillUp': {
    'ru': 'соединение пока работает на прежних кредах',
    'en': 'the tunnel still works on the old credentials',
  },
  'sub.revokedBadge': {'ru': 'отозвана', 'en': 'revoked'},
  // Единицы. Отдельными ключами, а не внутри фраз: используются в десятке
  // мест форматирования, и дублировать перевод в каждом было бы хуже.
  'unit.b': {'ru': 'Б', 'en': 'B'},
  'unit.kb': {'ru': 'КБ', 'en': 'KB'},
  'unit.mb': {'ru': 'МБ', 'en': 'MB'},
  'unit.gb': {'ru': 'ГБ', 'en': 'GB'},
  'unit.s': {'ru': 'с', 'en': 's'},
  'unit.m': {'ru': 'м', 'en': 'm'},

  'dlg.importName': {'ru': 'Импорт', 'en': 'Import'},
  'stats.xrayNoApi': {
    'ru': 'Сервер: {name}\n(ядро Xray — статистика соединений недоступна)',
    'en': 'Server: {name}\n(Xray core — connection statistics are unavailable)',
  },
  'stats.apiDown': {'ru': 'API недоступен: {e}', 'en': 'API unavailable: {e}'},
  'lat.failed': {'ru': 'замер не удался', 'en': 'measurement failed'},
  'dns.pickNoReply': {
    'ru': 'Ни один сервер не ответил — проверьте соединение',
    'en': 'No server responded — check your connection',
  },
  'dns.pickResult': {'ru': 'Выбран {name} — {list}', 'en': 'Picked {name} — {list}'},
  'dns.backup': {'ru': 'запасной', 'en': 'secondary'},
  // Не адрес, а «спросить Windows». Подпись объясняет, почему это дефолт:
  // публичный адрес может быть закрыт у провайдера, и тогда под TUN не
  // резолвится даже хост самого прокси-сервера.
  'dns.system': {
    'ru': 'Системный — как настроена сеть (надёжнее всего)',
    'en': 'System — as the network is configured (most reliable)',
  },
  'dns.blocksMalware': {
    'ru': 'режет вредоносные домены',
    'en': 'blocks malicious domains',
  },
  'dns.blocksAds': {'ru': 'режет рекламу', 'en': 'blocks ads'},
  'dns.noFilter': {'ru': 'без фильтра', 'en': 'unfiltered'},
  'dns.safe': {'ru': 'безопасный', 'en': 'safe'},
  'dns.yandex': {'ru': 'Яндекс', 'en': 'Yandex'},
  'lat.closest': {'ru': 'ближе всего к серверу', 'en': 'closest to the server'},
  'lat.connCheck': {'ru': 'проверка связи', 'en': 'connectivity check'},
  'lat.farther': {'ru': 'дальше, цифры выше', 'en': 'farther away, higher numbers'},
  'addp.title': {'ru': 'Добавить профиль', 'en': 'Add a profile'},
  'addp.link': {'ru': 'Добавление подписки', 'en': 'Add a subscription'},
  'addp.linkSub': {'ru': 'Ссылка от провайдера', 'en': 'A link from your provider'},
  'addp.paste': {'ru': 'Импорт из буфера обмена', 'en': 'Import from the clipboard'},
  'addp.pasteSub': {
    'ru': 'Ссылка подписки или ссылки серверов',
    'en': 'A subscription link or server links',
  },
  'addp.file': {'ru': 'Импорт файла конфигурации', 'en': 'Import a config file'},
  'addp.fileSub': {'ru': 'txt, yaml, json, conf', 'en': 'txt, yaml, json, conf'},
  'addp.export': {'ru': 'Сохранить резервную копию', 'en': 'Save a backup'},
  'addp.exportSub': {
    'ru': 'Настройки, профили и избранное в один файл',
    'en': 'Settings, profiles and favourites in one file',
  },
  'addp.import': {'ru': 'Восстановить из копии', 'en': 'Restore from a backup'},
  'addp.importSub': {
    'ru': 'Текущие настройки будут заменены',
    'en': 'Your current settings will be replaced',
  },
  'addp.backupWarn': {
    'ru': 'В копии есть ссылки ваших подписок — храните файл так же бережно, '
        'как сами ссылки.',
    'en': 'The backup contains your subscription links — keep the file as safe '
        'as the links themselves.',
  },
  'addp.qr': {'ru': 'QR-код из картинки', 'en': 'QR code from an image'},
  'addp.qrSub': {
    'ru': 'Скриншот или фото с кодом',
    'en': 'A screenshot or photo with the code',
  },
  'addp.scan': {'ru': 'Сканировать QR-код', 'en': 'Scan a QR code'},
  'addp.scanSub': {
    'ru': 'Навести камеру на код',
    'en': 'Point the camera at the code',
  },
  'dlg.fileImages': {'ru': 'Картинки', 'en': 'Images'},

  // --- Сканер QR камерой ---
  'qr.scanTitle': {'ru': 'Сканирование кода', 'en': 'Scanning a code'},
  'qr.torch': {'ru': 'Подсветка', 'en': 'Torch'},
  'qr.scanHint': {
    'ru': 'Наведите камеру на QR-код — он распознается сам',
    'en': 'Point the camera at the QR code — it is recognised on its own',
  },
  'qr.cameraFailed': {
    'ru': 'Камера недоступна. Проверьте, что вы разрешили приложению её '
        'использовать и что её не занимает другая программа.',
    'en': 'The camera is unavailable. Check that you allowed the app to use it '
        'and that no other program is holding it.',
  },

  // --- Содержимое лога ---
  // Подстановки в фигурных скобках, вставляются через tp().
  'log.on': {'ru': 'включён', 'en': 'on'},
  'log.off': {'ru': 'выключен', 'en': 'off'},
  'log.onF': {'ru': 'включена', 'en': 'on'},
  'log.offF': {'ru': 'выключена', 'en': 'off'},
  'log.ms': {'ru': '{v} мс', 'en': '{v} ms'},
  'log.unreachable': {'ru': 'недоступен', 'en': 'unreachable'},

  'log.restartHint': {
    'ru': ' — нажми «Запустить», чтобы применить',
    'en': ' — press “Start” to apply',
  },
  'log.trayFailed': {
    'ru': 'Не удалось создать значок в трее: {e}',
    'en': 'Could not create the tray icon: {e}',
  },
  'log.adminState': {
    'ru': 'Права администратора: {admin}. TUN включён при старте: {tun}',
    'en': 'Administrator rights: {admin}. TUN enabled at start: {tun}',
  },
  'log.elevationCancelled': {
    'ru': 'Запуск с правами администратора отменён — остаёмся без TUN',
    'en': 'Elevated start cancelled — staying without TUN',
  },
  'log.elevationFailed': {
    'ru': 'Не удалось запросить права администратора: {e}',
    'en': 'Could not request administrator rights: {e}',
  },
  'log.elevationRequested': {
    'ru': 'Запрошен перезапуск с правами администратора для TUN-режима',
    'en': 'Requested a restart with administrator rights for TUN mode',
  },
  'log.tunMode': {'ru': 'TUN-режим: {state}', 'en': 'TUN mode: {state}'},
  'log.routingMode': {'ru': 'Маршрутизация: {mode}{hint}', 'en': 'Routing: {mode}{hint}'},
  'log.settingsSaved': {
    'ru': 'Настройки сохранены{hint}',
    'en': 'Settings saved{hint}',
  },
  'log.sysProxyOn': {
    'ru': 'Системный прокси включён: 127.0.0.1:{port}',
    'en': 'System proxy enabled: 127.0.0.1:{port}',
  },
  'log.sysProxyOnFailed': {
    'ru': 'Не удалось включить системный прокси: {e}',
    'en': 'Could not enable the system proxy: {e}',
  },
  'log.tunStackFallback': {
    'ru': 'Ядро собрано без gVisor — беру системный сетевой стек. Чтобы '
        'пользоваться gVisor, нужна сборка sing-box с тегом with_gvisor.',
    'en': 'The core is built without gVisor — falling back to the system stack. '
        'Using gVisor requires a sing-box build with the with_gvisor tag.',
  },
  'log.sysProxyRestored': {
    'ru': 'Системный прокси возвращён в прежнее состояние',
    'en': 'System proxy restored to its previous state',
  },
  // Диагностика WinINET. Формулировки намеренно называют конкретную причину:
  // «не удалось» без деталей уже стоило раунда отладки вслепую.
  'log.sysProxySetFailed': {
    'ru': 'WinINET отклонил вызов InternetSetOption, код Windows {code}',
    'en': 'WinINET rejected InternetSetOption, Windows error {code}',
  },
  'log.sysProxyMismatch': {
    'ru': 'вызов прошёл, но система осталась на: {state}',
    'en': 'the call succeeded, but the system stayed on: {state}',
  },
  'log.sysProxyDirect': {
    'ru': 'прямом подключении, без прокси',
    'en': 'a direct connection, no proxy',
  },
  'log.sysProxyUnreadable': {
    'ru': 'состояние не читается',
    'en': 'state cannot be read',
  },
  'log.sysProxyBypassDropped': {
    'ru': 'WinINET не принял список исключений — прокси включён без него. '
        'Локальная сеть пойдёт через туннель.',
    'en': 'WinINET did not accept the bypass list — the proxy is on without it. '
        'Local network traffic will go through the tunnel.',
  },
  'log.sysProxyRestoreDegraded': {
    'ru': 'Прежние настройки прокси вернулись НЕ полностью: список исключений '
        'или PAC-скрипт придётся восстановить вручную в параметрах сети.',
    'en': 'The previous proxy settings were NOT fully restored: the bypass list '
        'or the PAC script has to be restored manually in network settings.',
  },
  'log.regWriteFailed': {
    'ru': 'запись в реестр не прошла (reg вернул {code}): {err}',
    'en': 'registry write failed (reg returned {code}): {err}',
  },
  'log.sysProxyRestoreFailed': {
    'ru': 'Не удалось вернуть системный прокси: {e}',
    'en': 'Could not restore the system proxy: {e}',
  },
  'log.sysProxyRecovering': {
    'ru': 'Прошлый сеанс не завершился штатно — возвращаю системный прокси',
    'en': 'The previous session did not exit cleanly — restoring the system proxy',
  },
  'log.coreUpToDate': {
    'ru': '{core}: обновлений нет (последний релиз {tag})',
    'en': '{core}: no updates (latest release {tag})',
  },
  'log.appDownloading': {
    'ru': 'Качаю обновление приложения {v}...',
    'en': 'Downloading app update {v}...',
  },
  'log.appStaged': {
    'ru': 'Обновление {v} распаковано, применяю',
    'en': 'Update {v} unpacked, applying',
  },
  'log.appApplying': {
    'ru': 'Закрываюсь для установки обновления — приложение запустится само',
    'en': 'Closing to install the update — the app will start again by itself',
  },
  'log.appUpdateBad': {
    'ru': 'В скачанном архиве нет сборки приложения — обновление отменено',
    'en': 'The downloaded archive has no app build — the update was cancelled',
  },
  'log.appUpdateFailed': {
    'ru': 'Не удалось обновить приложение: {e}',
    'en': 'Could not update the app: {e}',
  },
  'log.coreDownloading': {
    'ru': 'Качаю новое ядро {core} {tag}...',
    'en': 'Downloading the new {core} core {tag}...',
  },
  'log.coreStaged': {
    'ru': 'Ядро {core} {tag} скачано — применится при следующем запуске приложения',
    'en': 'Core {core} {tag} downloaded — it will be applied on the next app start',
  },
  'log.coreUpdated': {
    'ru': 'Ядро {core} обновлено до {tag}',
    'en': 'Core {core} updated to {tag}',
  },
  'log.coreRejectsConfig': {
    'ru': 'Ядро {core} {tag} не принимает наш конфиг — обновление отменено, '
        'работаем на прежнем',
    'en': 'Core {core} {tag} rejects our config — the update was cancelled, '
        'keeping the current one',
  },
  'log.coreUpdateBad': {
    'ru': 'Скачанное ядро {core} не запустилось — оставляю прежнее',
    'en': 'The downloaded {core} core did not run — keeping the old one',
  },
  'log.coreUpdateFailed': {
    'ru': 'Не удалось обновить ядро {core}: {e}',
    'en': 'Could not update the {core} core: {e}',
  },
  'log.coreUpdatesAuto': {
    'ru': 'Вышли новые версии ядер: {list}. Скачаются сами и применятся при '
        'следующем запуске приложения.',
    'en': 'New core versions are available: {list}. They will be downloaded '
        'automatically and applied on the next app start.',
  },
  'log.coreUpdates': {
    'ru': 'Вышли новые версии ядер: {list}. Автообновление их не возьмёт — '
        'версия установленного ядра не определяется. Скачайте с GitHub и '
        'положите рядом с .exe.',
    'en': 'New core versions are available: {list}. Auto-update will skip them — '
        'the installed core does not report its version. Download them from '
        'GitHub and put them next to the .exe.',
  },
  'log.autostart': {
    'ru': 'Автозапуск с системой: {state}',
    'en': 'Start with the system: {state}',
  },
  'log.autostartFailed': {
    'ru': 'Не удалось изменить автозапуск: {e}',
    'en': 'Could not change the autostart setting: {e}',
  },
  'log.autoConnect': {
    'ru': 'Автоподключение после запуска...',
    'en': 'Connecting automatically after startup...',
  },
  'onb.profileHow': {
    'ru': 'Как добавить профиль?',
    'en': 'How would you like to add a profile?',
  },
  'onb.profileHowHint': {
    'ru': 'Ссылку на подписку выдаёт ваш провайдер VPN. Если она уже '
        'скопирована или пришла картинкой с кодом — не набирайте руками.',
    'en': 'Your VPN provider issues the subscription link. If you already '
        'copied it, or received it as a QR image, there is no need to type it.',
  },
  'onb.fromClipboard': {
    'ru': 'Вставить из буфера обмена',
    'en': 'Paste from clipboard',
  },
  'onb.fromClipboardHint': {
    'ru': 'Если вы только что скопировали ссылку',
    'en': 'If you have just copied the link',
  },
  'sub.notAUrl': {
    'ru': 'В профиле не ссылка подписки. Она начинается с http:// или https:// '
        'и содержит адрес сайта — проверьте, что скопировалась вся строка '
        'целиком. Если у вас на руках сами серверы (vless://, vmess://), '
        'заводите профиль через «Импорт из буфера обмена».',
    'en': 'This profile does not hold a subscription link. A link starts with '
        'http:// or https:// and contains a site address — check that the whole '
        'string was copied. If what you have is the servers themselves '
        '(vless://, vmess://), add the profile through "Import from the '
        'clipboard" instead.',
  },
  'check.running': {
    'ru': 'Проверяю, выходит ли трафик наружу…',
    'en': 'Checking whether traffic gets out…',
  },
  'check.ok': {
    'ru': 'Проверено: через сервер выходит',
    'en': 'Checked: traffic gets through',
  },
  'check.failed': {
    'ru': 'Соединение поднято, но наружу через него не выходит — выберите '
        'другой сервер',
    'en': 'The connection is up but nothing gets out through it — pick another '
        'server',
  },
  'servers.testStop': {'ru': 'Остановить тест', 'en': 'Stop the test'},
  'log.latencyCancelled': {
    'ru': 'Тест задержки остановлен',
    'en': 'Latency test stopped',
  },
  'log.startCancelled': {
    'ru': 'Подключение отменено',
    'en': 'Connection cancelled',
  },
  'servers.hideDead': {
    'ru': 'Скрывать серверы, не прошедшие проверку',
    'en': 'Hide servers that failed the check',
  },
  'servers.hideDeadCount': {
    'ru': 'Скрывать не прошедшие проверку — скрыто: {n}',
    'en': 'Hide servers that failed the check — hidden: {n}',
  },
  'onb.scanQr': {'ru': 'Сканировать QR-код', 'en': 'Scan a QR code'},
  'onb.scanQrHint': {
    'ru': 'Код показан на другом экране или на бумаге',
    'en': 'The code is on another screen or on paper',
  },
  'onb.fromQr': {'ru': 'QR-код из картинки', 'en': 'QR code from an image'},
  'onb.fromQrHint': {
    'ru': 'Картинка с кодом: скриншот, фотография, сохранённое изображение',
    'en': 'An image with the code: screenshot, photo, saved picture',
  },
  'onb.manual': {'ru': 'Ввести ссылку вручную', 'en': 'Type the link myself'},
  'onb.manualHint': {
    'ru': 'Длинный адрес, начинается с https://',
    'en': 'A long address starting with https://',
  },
  'onb.clipboardEmpty': {
    'ru': 'В буфере обмена нет ссылки. Скопируйте её и попробуйте снова.',
    'en': 'No link in the clipboard. Copy it and try again.',
  },
  'onb.qrNotFound': {
    'ru': 'В картинке не нашлось QR-кода',
    'en': 'No QR code found in the image',
  },
  'onb.nameRequired': {
    'ru': 'Придумайте название — по нему вы будете узнавать профиль в списке',
    'en': 'Give it a name — you will recognise the profile by it in the list',
  },
  'log.latencyUdpSkipped': {
    'ru': 'Серверов на UDP-протоколах пропущено: {n}. Их порт не принимает '
        'TCP-подключений, а без работающего туннеля измерить их нечем — '
        'подключитесь и повторите тест.',
    'en': 'Skipped {n} UDP-protocol servers. Their port accepts no TCP '
        'connections, and without a running tunnel there is nothing to measure '
        'them with — connect and run the test again.',
  },
  'log.androidVpnDenied': {
    'ru': 'Система не дала разрешение на VPN. Без него туннель не поднять — '
        'нажмите щит ещё раз и подтвердите запрос.',
    'en': 'The system did not grant VPN permission. The tunnel cannot start '
        'without it — press the shield again and confirm the request.',
  },
  'log.androidBridges': {
    'ru': 'Мостов Xray для xhttp-серверов: {n}',
    'en': 'Xray bridges for xhttp servers: {n}',
  },
  'log.healthFailed': {
    'ru': 'Проверка сервера «{name}» не прошла (подряд: {n})',
    'en': 'Health check failed for "{name}" (in a row: {n})',
  },
  'log.healthRestart': {
    'ru': 'Связи нет несколько проверок подряд — перезапускаю ядро',
    'en': 'No connectivity for several checks in a row — restarting the core',
  },
  'log.healthRecovered': {
    'ru': 'Проверка сервера снова проходит',
    'en': 'The server passes the health check again',
  },
  'log.healthSwitching': {
    'ru': 'Сервер «{from}» не пропускает трафик — переключаюсь на «{to}»',
    'en': 'Server "{from}" does not pass traffic — switching to "{to}"',
  },
  'log.healthAllBad': {
    'ru': 'Проверку не прошёл ни один сервер — похоже, дело не в них. '
        'Остаюсь на текущем.',
    'en': 'No server passed the check — the cause is probably elsewhere. '
        'Staying on the current one.',
  },
  'set.healthCheck': {
    'ru': 'Проверять, что сервер реально работает',
    'en': 'Check that the server actually works',
  },
  'set.healthCheckSub': {
    'ru': 'Пинг показывает только, что сервер отзывается. Проверка ходит к '
        'настоящему сайту и ловит серверы, у которых задержка отличная, а '
        'YouTube не открывается.',
    'en': 'Latency only shows that the server responds. This check requests a '
        'real site and catches servers with great latency that still fail to '
        'open YouTube.',
  },
  'set.healthCheckUrl': {'ru': 'Адрес проверки', 'en': 'Check address'},
  'set.healthCheckInterval': {
    'ru': 'Как часто проверять, секунд',
    'en': 'How often to check, seconds',
  },
  'set.healthCheckSwitch': {
    'ru': 'Переключать сервер самому, если проверка провалилась дважды',
    'en': 'Switch the server automatically after two failed checks',
  },
  'log.noAutoConnectAfterOnboarding': {
    'ru': 'Профиль добавлен. Автоподключение пропущено — нажмите щит, '
        'когда будете готовы. Со следующего запуска оно сработает само.',
    'en': 'Profile added. Skipped connecting automatically — press the shield '
        'when you are ready. It will work as usual from the next launch.',
  },
  'log.blockAds': {
    'ru': 'Блокировка рекламы: {state}{hint}',
    'en': 'Ad blocking: {state}{hint}',
  },
  'log.importEmpty': {
    'ru': 'Импорт профиля: пусто, нечего добавлять',
    'en': 'Profile import: empty, nothing to add',
  },
  'log.profileImported': {
    'ru': 'Профиль "{name}" импортирован',
    'en': 'Profile "{name}" imported',
  },
  'log.backupSaved': {
    'ru': 'Резервная копия сохранена: {path}',
    'en': 'Backup saved: {path}',
  },
  'log.backupFailed': {
    'ru': 'Не удалось сохранить резервную копию: {e}',
    'en': 'Could not save the backup: {e}',
  },
  'log.backupRestored': {
    'ru': 'Настройки восстановлены из резервной копии',
    'en': 'Settings restored from the backup',
  },
  'log.backupRestoreFailed': {
    'ru': 'Не удалось восстановить копию: {e}',
    'en': 'Could not restore the backup: {e}',
  },
  'log.qrNoImage': {
    'ru': 'QR: не удалось прочитать картинку',
    'en': 'QR: could not read the image',
  },
  'log.qrNotFound': {
    'ru': 'QR-код на картинке не найден',
    'en': 'No QR code found in the image',
  },
  'log.qrDecoded': {
    'ru': 'QR-код прочитан ({n} символов)',
    'en': 'QR code decoded ({n} characters)',
  },
  'log.qrFailed': {'ru': 'QR: {e}', 'en': 'QR: {e}'},
  'log.fileImportFailed': {
    'ru': 'Не удалось импортировать файл: {e}',
    'en': 'Could not import the file: {e}',
  },
  'log.rulesetRefreshed': {
    'ru': 'Набор {file} обновлён (был старше {days} дн.)',
    'en': 'Rule set {file} refreshed (it was older than {days} d.)',
  },
  'log.rulesetBundled': {
    'ru': 'Набор {file} взят из комплекта приложения',
    'en': 'Rule set {file} taken from the app bundle',
  },
  'log.rulesetDownloading': {
    'ru': 'Качаю набор правил {file}...',
    'en': 'Downloading rule set {file}...',
  },
  'log.rulesetReady': {
    'ru': 'Набор {file} готов ({bytes} Б)',
    'en': 'Rule set {file} ready ({bytes} B)',
  },
  'log.rulesetFailed': {
    'ru': 'Не удалось скачать {file}: {e} — правило пропущено',
    'en': 'Could not download {file}: {e} — the rule is skipped',
  },
  'log.resolveBypassFailed': {
    'ru': 'Не удалось резолвить {host} для bypass-правила — пропускаю',
    'en': 'Could not resolve {host} for the bypass rule — skipping',
  },
  'log.killedOwn': {
    'ru': 'Добил свой процесс {name} (PID {pid})',
    'en': 'Finished off our own process {name} (PID {pid})',
  },
  'log.killOwnFailed': {
    'ru': 'Не удалось добить {name} (PID {pid}) — вероятно, он с правами администратора',
    'en': 'Could not finish off {name} (PID {pid}) — it is probably running as administrator',
  },
  'log.killedOnPort': {
    'ru': 'Убрал зависший процесс на нашем порту (PID {pid})',
    'en': 'Removed a stuck process on our port (PID {pid})',
  },
  'log.killOnPortFailed': {
    'ru': 'Не удалось убрать PID {pid} — похоже, он запущен от администратора. '
        'Порт останется занят.',
    'en': 'Could not remove PID {pid} — it looks like it runs as administrator. '
        'The port will stay busy.',
  },
  'log.coreExitedNoRestart': {
    'ru': 'Ядро завершилось само (код {code}). Автоподъём выключен в настройках.',
    'en': 'The core exited on its own (code {code}). Auto-restart is disabled in settings.',
  },
  'log.coreCrashLoop': {
    'ru': 'Ядро падает раз за разом (код {code}) — больше не поднимаю. '
        'Загляните в лог: скорее всего, дело в конфигурации, и перезапуск не поможет.',
    'en': 'The core keeps crashing (code {code}) — not restarting it any more. '
        'Check the log: most likely it is a configuration problem, and a restart will not help.',
  },
  'log.coreExitedRestarting': {
    'ru': 'Ядро завершилось само (код {code}). Поднимаю заново, попытка {n} из 3...',
    'en': 'The core exited on its own (code {code}). Restarting it, attempt {n} of 3...',
  },
  'log.noSubscription': {
    'ru': 'Сначала загрузи подписку',
    'en': 'Load a subscription first',
  },
  'log.autoSelectBeforeConnect': {
    'ru': 'Автовыбор перед подключением: измеряю задержки...',
    'en': 'Auto-select before connecting: measuring latency...',
  },
  'log.autoSelectPicked': {
    'ru': 'Автовыбор: {name} — {ms} мс',
    'en': 'Auto-select: {name} — {ms} ms',
  },
  'log.startSummary': {
    'ru': 'Старт: сервер={name}, движок={engine}, tag={tag}, TUN={tun}, admin={admin}',
    'en': 'Start: server={name}, engine={engine}, tag={tag}, TUN={tun}, admin={admin}',
  },
  'log.bridgesStarting': {
    'ru': 'Поднимаю мосты Xray для xhttp-серверов...',
    'en': 'Starting Xray bridges for xhttp servers...',
  },
  'log.noSingboxServers': {
    'ru': 'В этом профиле нет серверов, совместимых с sing-box (все — xhttp)',
    'en': 'This profile has no sing-box compatible servers (all of them are xhttp)',
  },
  'log.generatingConfig': {
    'ru': 'Генерирую config.json...',
    'en': 'Generating config.json...',
  },
  'log.startingSingbox': {'ru': 'Запускаю sing-box...', 'en': 'Starting sing-box...'},
  'log.generatingXrayConfig': {
    'ru': 'Генерирую конфиг для Xray ({name})...',
    'en': 'Generating the Xray config ({name})...',
  },
  'log.startingXray': {
    'ru': 'Запускаю xray (движок для xhttp-серверов)...',
    'en': 'Starting xray (the engine for xhttp servers)...',
  },
  'log.bridgeDied': {
    'ru': 'Мост Xray для {name} завершился (код {code})',
    'en': 'The Xray bridge for {name} exited (code {code})',
  },
  'log.bridgeRestart': {
    'ru': 'Мост Xray для {name} не отвечает на порту {port} — поднимаю заново',
    'en': 'The Xray bridge for {name} is not answering on port {port} — restarting it',
  },
  'log.bridgeReady': {
    'ru': 'Мост Xray для {name} готов на порту {port}',
    'en': 'Xray bridge for {name} is ready on port {port}',
  },
  'log.bridgeNotReady': {
    'ru': 'Мост Xray для {name} не поднялся за 5с — возможны сбои первого соединения',
    'en': 'Xray bridge for {name} did not come up within 5 s — the first connection may fail',
  },
  'log.coreStopped': {'ru': 'Ядро остановлено', 'en': 'Core stopped'},
  'log.quitStarted': {
    'ru': 'Выход: останавливаю ядро и возвращаю системный прокси',
    'en': 'Exit: stopping the core and restoring the system proxy',
  },
  'log.quitClosing': {
    'ru': 'Выход: закрываю окно',
    'en': 'Exit: closing the window',
  },
  'log.stopTimeout': {
    'ru': 'Остановка затянулась — закрываюсь, остатки снимет следующий запуск',
    'en': 'Shutdown is taking too long — exiting, leftovers will be cleaned on next start',
  },
  'log.switching': {'ru': 'Переключаюсь на {name}...', 'en': 'Switching to {name}...'},
  'log.serverPicked': {
    'ru': 'Выбран сервер {name} — нажмите щит, чтобы подключиться',
    'en': 'Server {name} selected — press the shield to connect',
  },
  'log.active': {'ru': 'Активен: {name}', 'en': 'Active: {name}'},
  'log.clashApiStatus': {
    'ru': 'Clash API вернул {code}, перезапускаю ядро',
    'en': 'Clash API returned {code}, restarting the core',
  },
  'log.clashApiUnreachable': {
    'ru': 'Не достучался до Clash API: {e} — перезапускаю ядро',
    'en': 'Could not reach the Clash API: {e} — restarting the core',
  },
  'log.latencyStart': {
    'ru': 'Тест задержки: старт для {n} серверов',
    'en': 'Latency test: starting for {n} servers',
  },
  'log.latencyDone': {
    'ru': 'Тест задержки: готово — {summary}',
    'en': 'Latency test: done — {summary}',
  },
  'log.latencyError': {
    'ru': 'Тест задержки [{name}]: {e}',
    'en': 'Latency test [{name}]: {e}',
  },
  'log.probePortBusy': {
    'ru': 'Тест задержки: пробное ядро не заняло порт {port}',
    'en': 'Latency test: the probe core did not take port {port}',
  },
  'log.probeFailed': {
    'ru': 'Тест задержки: пробное ядро не запустилось: {e}',
    'en': 'Latency test: the probe core did not start: {e}',
  },
  'log.probeSingboxPortBusy': {
    'ru': 'Тест задержки: пробное ядро sing-box не заняло порт {port}',
    'en': 'Latency test: the sing-box probe core did not take port {port}',
  },
  'log.probeXrayPortBusy': {
    'ru': 'Тест задержки [{name}]: пробное ядро Xray не заняло порт {port}',
    'en': 'Latency test [{name}]: the Xray probe core did not take port {port}',
  },
  'log.autoSelectNoMatch': {
    'ru': 'Авто-выбор: под фильтр "{filter}" не подошёл ни один сервер',
    'en': 'Auto-select: no server matched the filter "{filter}"',
  },
  'log.autoSelectNoReply': {
    'ru': 'Авто-выбор: ни один сервер не ответил',
    'en': 'Auto-select: no server responded',
  },
  'log.autoSelectKeep': {
    'ru': 'Авто-выбор: оставляю {name} ({ms} мс) — лучший {best} ({bestMs} мс) '
        'выигрывает меньше допуска {tol} мс',
    'en': 'Auto-select: keeping {name} ({ms} ms) — the best one, {best} ({bestMs} ms), '
        'wins by less than the {tol} ms tolerance',
  },
  'log.autoSelectResult': {
    'ru': 'Авто-выбор: {name} — {ms} мс',
    'en': 'Auto-select: {name} — {ms} ms',
  },
  'log.autoSelectScheduled': {
    'ru': 'Авто-выбор по расписанию (каждые {min} мин)',
    'en': 'Scheduled auto-select (every {min} min)',
  },
  'log.subAutoUpdate': {
    'ru': 'Автообновление подписки "{name}" (раз в {hours} ч)',
    'en': 'Auto-updating subscription "{name}" (every {hours} h)',
  },
  'log.networkGone': {
    'ru': 'Сети нет — жду её возвращения, серверы тут ни при чём',
    'en': 'No network — waiting for it to return; the servers are not at fault',
  },
  'log.networkBack': {
    'ru': 'Сеть вернулась — перезапускаю ядро',
    'en': 'Network is back — restarting the core',
  },
  'log.autoSelectNoNetwork': {
    'ru': 'Авто-выбор пропущен: сети нет',
    'en': 'Auto-select skipped: no network',
  },
  'log.autoSelectSkipBad': {
    'ru': 'Автовыбор: пропущено серверов без связи — {n}',
    'en': 'Auto-select: {n} unreachable server(s) skipped',
  },
  'log.subFormat': {
    'ru': 'Подписка разобрана как {format}: серверов {count}, пропущено {skipped}',
    'en': 'Subscription parsed as {format}: {count} servers, {skipped} skipped',
  },
  'log.subRevoked': {
    'ru': 'Подписка "{name}": доступ отозван ({reason})',
    'en': 'Subscription "{name}": access revoked ({reason})',
  },
  'log.subRevokedStillUp': {
    'ru': 'Соединение при этом живо — ссылку сменили, а креды сервера прежние. '
        'Ядро не глушим, но профиль помечен: обновите ссылку подписки.',
    'en': 'The tunnel is still up — the link changed but the server credentials '
        'did not. Keeping the core running; update the subscription link.',
  },
};
