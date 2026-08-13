import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:archive/archive.dart';
import 'android_vpn.dart';
import 'diagnostics.dart';
import 'l10n.dart';
import 'onboarding.dart';
import 'platform_env.dart';
import 'prefs_keys.dart';
import 'qr_import.dart';
import 'system_proxy.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

// Замок «одна копия приложения». Порт на петле, а не мьютекс: копии могут
// работать с РАЗНЫМИ правами (обычная и перезапущенная от администратора для
// TUN), а именованный мьютекс между уровнями целостности так просто не виден.
// TCP на 127.0.0.1 виден всем и заодно даёт канал: вторая копия стучится в
// него, первая по этому стуку показывает своё окно и выходит вторая.
//
// Зачем вообще: две копии дерутся за порт 1337, Clash API, файлы конфигов,
// системный прокси и TUN-адаптер. Пользователь поймал именно это — два окна,
// в одном «Protected», в другом «Not protected».
const int kSingleInstancePort = 17999;
ServerSocket? _instanceLock;


/// Команда, по которой приложение закрывается ШТАТНО — с остановкой ядра,
/// возвратом системного прокси и снятием TUN-адаптера.
const String kQuitCommand = 'quit';

/// Стук второй копии: «покажи окно». Раньше она не присылала ничего и рвала
/// соединение — этого хватало, пока ответ никого не интересовал.
const String kShowCommand = 'show';

/// Ответ первой копии: окно ПОКАЗАНО. Отправляется строго после `show()`,
/// поэтому его получение — доказательство, а не предположение.
const String kShownAck = 'shown';

/// Отдельный маленький журнал только про захват замка.
///
/// Нужен потому, что копия, решившая «приложение уже работает», выходит из
/// `main()` до создания экрана — то есть до того, как появляется `app_log.txt`.
/// Сеанс, в котором «ничего не произошло», не оставлял вообще никаких следов,
/// и разбирать было нечего.
String? _startupLogPathCache;
String _startupLogPath() {
  final cached = _startupLogPathCache;
  if (cached != null) return cached;
  // Та же развилка, что у _workDir на экране: рядом с .exe, если туда можно
  // писать, иначе в профиль. Продублирована намеренно — _workDir живёт в
  // состоянии экрана, которого здесь ещё нет.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  try {
    final probe = File('$exeDir${Platform.pathSeparator}.write_test');
    probe.writeAsStringSync('x', flush: true);
    probe.deleteSync();
    _startupLogPathCache = '$exeDir${Platform.pathSeparator}startup_log.txt';
  } catch (_) {
    final appData = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        exeDir;
    final dir = '$appData${Platform.pathSeparator}Multik Sila';
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {}
    _startupLogPathCache = '$dir${Platform.pathSeparator}startup_log.txt';
  }
  return _startupLogPathCache!;
}

void _startupLog(String text) {
  try {
    final file = File(_startupLogPath());
    // Файл пишут ВСЕ копии сразу, поэтому он только дописывается и никогда не
    // перезаписывается при старте — иначе копия, выходящая первой, стёрла бы
    // запись той, что осталась работать. Обрезаем по размеру, а не по запуску.
    if (file.existsSync() && file.lengthSync() > 64 * 1024) {
      final tail = file.readAsStringSync();
      file.writeAsStringSync(tail.substring(tail.length ~/ 2), flush: true);
    }
    file.writeAsStringSync(
      '[${DateTime.now().toIso8601String()}] pid=$pid $text\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // Диагностика не имеет права мешать запуску.
  }
}

/// Штатный выход, выставляется главным экраном. Нужен установщику: тот не может
/// просто убить процесс. Во-первых, приложение в TUN-режиме работает от
/// администратора, а установщик — от обычного пользователя (`PrivilegesRequired=lowest`),
/// и Windows такой taskkill запрещает. Во-вторых, убийство оставило бы в системе
/// подменённый прокси и осиротевшие процессы ядра, держащие порт и адаптер.
///
/// Канал — тот же сокет одной копии: он на петле, а не в реестре и не в
/// мьютексе, поэтому доступен между разными уровнями целостности.
Future<void> Function()? appQuitHandler;

Future<bool> _claimSingleInstance() async {
  // Несколько попыток: при перезапуске от администратора старая копия ещё
  // закрывается, и порт освобождается не мгновенно. Без ретраев новая копия
  // решила бы, что «уже запущено», и вышла — приложение исчезло бы совсем.
  for (var attempt = 0; attempt < 12; attempt++) {
    try {
      _instanceLock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, kSingleInstancePort);
      _startupLog('замок занят нами, запускаемся');
      _instanceLock!.listen((socket) {
        // Читаем, ЧТО пришло: `show` (или пустой стук от старой копии) —
        // «покажи окно», `quit` — «закройся по-нормальному». Без чтения
        // отличить их нельзя, а установщику нужен именно второй случай.
        //
        // Разбираем по подписке, а не через fold: fold ждёт конца потока,
        // то есть закрытия соединения ДРУГОЙ стороной, — а нам нужно на это
        // же соединение ответить. Таймер на 700 мс страхует от копии,
        // которая соединилась и не прислала ничего.
        final buffer = <int>[];
        late StreamSubscription<List<int>> sub;
        var handled = false;

        Future<void> handle() async {
          if (handled) return;
          handled = true;
          final command = String.fromCharCodes(buffer).trim();
          if (command == kQuitCommand) {
            await sub.cancel();
            socket.destroy();
            final quit = appQuitHandler;
            if (quit != null) {
              await quit();
            } else {
              // Экран ещё не поднялся — уборке нечего делать, но уйти обязаны:
              // иначе установщик упрётся в занятый .exe.
              exit(0);
            }
            return;
          }
          try {
            await windowManager.show();
            await windowManager.focus();
            // Подтверждение отправляем ТОЛЬКО после показа: в нём весь смысл.
            // Вторая копия по нему отличает «окно показали» от «порт открыт,
            // а копия висит», и во втором случае не уходит молча.
            socket.write(kShownAck);
            await socket.flush();
            _startupLog('стук обработан, окно показано');
          } catch (e) {
            _startupLog('стук пришёл, но показать окно не вышло: $e');
          }
          await sub.cancel();
          socket.destroy();
        }

        sub = socket.listen(
          (chunk) {
            buffer.addAll(chunk);
            handle();
          },
          onDone: handle,
          onError: (_) => handle(),
          cancelOnError: false,
        );
        Timer(const Duration(milliseconds: 700), handle);
      });
      return true;
    } catch (_) {
      // Занято — стучимся: если там живая копия, она покажет окно.
      try {
        final shown = await _knock();
        if (shown) {
          _startupLog('копия показала окно, выходим');
          return false;
        }
        // Соединение прошло, а подтверждения нет. Это НЕ значит «копия
        // работает»: соединение на петле завершает ядро Windows из очереди
        // прослушивания, поэтому connect удаётся и к намертво зависшему
        // процессу. Раньше здесь стоял безусловный выход — и человек, дважды
        // щёлкнув по ярлыку, не получал ровно ничего.
        _startupLog('порт занят, подтверждения нет — попытка ${attempt + 1}');
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (_) {
        // Порт занят, но соединение не устанавливается — вероятно, прошлая
        // копия ещё не отпустила сокет. Ждём и пробуем снова.
        _startupLog('порт занят, соединения нет — попытка ${attempt + 1}');
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }
  // Ни занять, ни добиться ответа. Запускаемся: две копии — беда, но копия,
  // которая не отвечает на стук, окна и не покажет, а невидимое приложение
  // человек чинить не может в принципе.
  _startupLog('ответа так и нет — запускаемся без замка');
  return true;
}

/// Стук в работающую копию. `true` — она подтвердила, что показала окно.
Future<bool> _knock() async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    kSingleInstancePort,
    timeout: const Duration(milliseconds: 400),
  );
  final answered = Completer<bool>();
  final reply = <int>[];
  void settle() {
    if (!answered.isCompleted) {
      answered.complete(String.fromCharCodes(reply).trim() == kShownAck);
    }
  }

  socket.listen(
    (chunk) {
      reply.addAll(chunk);
      settle();
    },
    onDone: settle,
    onError: (_) => settle(),
    cancelOnError: false,
  );
  socket.write(kShowCommand);
  await socket.flush();
  // Полторы секунды: живая копия отвечает за миллисекунды, а ждать дольше
  // значит держать человека перед пустым экраном.
  final acked = await answered.future
      .timeout(const Duration(milliseconds: 1500), onTimeout: () => false);
  socket.destroy();
  return acked;
}

/// Отпустить замок перед намеренным перезапуском самих себя.
Future<void> releaseSingleInstanceLock() async {
  try {
    await _instanceLock?.close();
  } catch (_) {}
  _instanceLock = null;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android уходит здесь и дальше в настольную часть не заглядывает.
  //
  // Всё, что ниже, — окно, его размеры и положение, замок «одна копия» —
  // существует только на рабочем столе. На телефоне окно одно и его размером
  // распоряжается система, а вторую копию приложения Android не запустит в
  // принципе: замок на порту 17999 там решал бы несуществующую задачу и при
  // этом занимал порт.
  if (!Env.hasWindowAndTray) {
    // Рабочий каталог узнаём ДО первого кадра: дальше он нужен синхронно —
    // логу, конфигам, наборам правил, — а система отдаёт его только через
    // ожидание.
    Env.workDirOverride = await Env.androidWorkDir();
    runApp(const MyApp());
    return;
  }

  await windowManager.ensureInitialized();
  if (!await _claimSingleInstance()) {
    // Окно уже показала работающая копия — тихо уходим.
    exit(0);
  }
  // Перехватываем закрытие окна сами — иначе крестик убьёт процесс вместе с
  // ядром, а нам нужно свернуть в трей и продолжить держать соединение.
  await windowManager.setPreventClose(true);
  // Рабочая область экрана — то, что остаётся за вычетом панели задач. Всё
  // остальное считается ОТ НЕЁ, а не от жёстких чисел.
  //
  // Причина: раньше окно открывалось фиксированными 480x880, а на ноутбуке
  // 1536x864 рабочая область по высоте всего 816 — окно физически не
  // помещалось на экран, и нижняя часть уходила под край. На больших мониторах
  // этого не видно, поэтому и прожило долго.
  //
  // visibleSize может не отдаться (несколько мониторов, экзотические драйверы) —
  // тогда откатываемся на полный размер экрана, а если и его нет, на прежние
  // константы. Ошибка тут не должна мешать приложению запуститься вообще.
  Size work = const Size(1280, 800);
  try {
    final display = await screenRetriever.getPrimaryDisplay();
    work = display.visibleSize ?? display.size;
  } catch (_) {}

  // Минимум задаём с оглядкой на экран: на маленьком ноутбуке жёсткие 660
  // сами по себе не дали бы окну поместиться. Главный экран это переживает —
  // блок щита лежит в SingleChildScrollView и на низком окне прокручивается,
  // а не переливается через край жёлто-чёрной полосой.
  final minH = math.min(620.0, work.height - 40);
  final minW = math.min(420.0, work.width - 40);
  await windowManager.setMinimumSize(Size(minW, minH));

  // Размер по умолчанию — рабочий, а не минимальный: раньше окно открывалось
  // ровно в minimumSize, и всё выглядело зажатым. Но не выше рабочей области.
  Size size = Size(
    math.min(480.0, work.width - 40),
    math.min(860.0, work.height - 40),
  );
  Offset? position;
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(windowBoundsPrefsKey);
    if (raw != null) {
      final b = jsonDecode(raw) as Map<String, dynamic>;
      // Ограничиваем сверху размерами экрана, а не константой: если окно
      // когда-то разворачивали, в память попал размер во весь экран, и
      // приложение потом каждый раз открывалось распахнутым. Снизу — минимумом,
      // иначе всё зажимается.
      final w = (b['w'] as num).toDouble().clamp(minW, work.width);
      final h = (b['h'] as num).toDouble().clamp(minH, work.height);
      size = Size(w, h);
      final x = (b['x'] as num).toDouble();
      final y = (b['y'] as num).toDouble();
      // Окно должно оказаться на экране целиком. Отрицательные координаты либо
      // выход за правый/нижний край означают, что монитор с тех пор отключили
      // или сменили разрешение, — тогда лучше открыться по центру, чем за краем.
      if (x >= 0 && y >= 0 && x + w <= work.width && y + h <= work.height) {
        position = Offset(x, y);
      }
    }
  } catch (_) {
    // битые координаты не должны мешать запуску — откроемся с дефолтом
  }

  // Штатная последовательность window_manager: размер задаётся ДО показа окна,
  // иначе оно успевает мелькнуть в стандартном виде, а setBounds до show
  // применяется ненадёжно.
  await windowManager.waitUntilReadyToShow(
    WindowOptions(size: size, center: position == null, title: 'Multik Sila'),
    () async {
      if (position != null) await windowManager.setPosition(position);
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(const MyApp());
}

class ParsedServer {
  final String name;
  final String protocol;
  final Map<String, dynamic> outbound;
  // 'singbox' или 'xray' — какое ядро умеет поднять этот outbound.
  // xhttp-транспорт sing-box не поддерживает вообще, такие серверы уходят
  // через отдельно запускаемый xray.exe.
  final String engine;
  // Исходная ссылка из подписки — нужна, чтобы показать QR-код и отдать
  // сервер на телефон. Заполняется в одном месте, после разбора строки:
  // раскладывать её по семи веткам парсеров смысла нет.
  String link = '';

  ParsedServer({
    required this.name,
    required this.protocol,
    required this.outbound,
    this.engine = 'singbox',
  });
}

// streamSettings для Xray (VLESS/VMess/Trojan) при транспорте xhttp.
// Общий для всех трёх протоколов, т.к. блок tls/reality/xhttp одинаковый.
Map<String, dynamic> _buildXhttpStreamSettings(Map<String, String> params, String server) {
  final security = params['security'] ?? 'none';
  final sni = params['sni'] ?? server;
  final fp = params['fp'] ?? 'chrome';

  final xhttpSettings = <String, dynamic>{
    "path": (params['path']?.isNotEmpty == true) ? params['path'] : '/',
    "mode": (params['mode']?.isNotEmpty == true) ? params['mode'] : 'auto',
    // Здесь был xmux-тюнинг (maxConcurrency/cMaxReuseTimes/hMaxRequestTimes)
    // как гипотеза про обрывы под TUN. Гипотеза не подтвердилась: настоящей
    // причиной была петля маршрутизации (см. route.rules в _writeConfig), а
    // xmux делал только хуже — он заставляет xray чаще переустанавливать
    // xhttp-сессию, и каждое такое переподключение попадало в петлю.
    // Оставляем дефолты Xray. Проверено отдельно: мост с дефолтным xmux
    // тянет 3 МБ на ~4.7 МБ/с.
  };
  final host = params['host'];
  if (host != null && host.isNotEmpty) xhttpSettings['host'] = host;
  final padding = params['x_padding_bytes'];
  if (padding != null && padding.isNotEmpty) {
    xhttpSettings['extra'] = {'xPaddingBytes': padding};
  }

  final streamSettings = <String, dynamic>{
    "network": "xhttp",
    "security": security,
    "xhttpSettings": xhttpSettings,
  };

  if (security == 'reality') {
    streamSettings['realitySettings'] = {
      "serverName": sni,
      "fingerprint": fp,
      "publicKey": params['pbk'],
      "shortId": params['sid'] ?? '',
      if ((params['spx'] ?? '').isNotEmpty) "spiderX": params['spx'],
    };
  } else {
    final alpnParam = params['alpn'];
    streamSettings['tlsSettings'] = {
      "serverName": sni,
      "fingerprint": fp,
      if (alpnParam != null && alpnParam.isNotEmpty) "alpn": alpnParam.split(','),
    };
  }

  return streamSettings;
}

// Режим маршрутизации. global — всё в туннель (как было всегда).
// bypassRu — российские домены и IP идут напрямую, мимо VPN: и быстрее,
// и банки/госуслуги не видят иностранный IP.
enum RoutingMode { global, bypassRu }

// Готовые бинарные rule-set'ы sing-box (.srs) от SagerNet. Качаем один раз
// в подпапку rulesets рядом с .exe и подключаем как "type": "local".
// Именно local, а не remote: remote sing-box тянет сам при каждом старте и
// падает целиком, если GitHub недоступен — а у пользователя он через раз.
// Осторожно с тегами: geosite-ru НЕ существует (404), нужен category-ru.
class RuleSetSpec {
  final String tag;
  final String file;
  final String url;
  const RuleSetSpec(this.tag, this.file, this.url);
}

const _rsGeositeRu = RuleSetSpec('geosite-ru', 'geosite-category-ru.srs',
    'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs');
const _rsGeoipRu = RuleSetSpec('geoip-ru', 'geoip-ru.srs',
    'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs');
const _rsAds = RuleSetSpec('geosite-ads', 'geosite-category-ads-all.srs',
    'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs');

// Всё, что раньше было захардкожено в _writeConfig. Дефолты подобраны так,
// чтобы в точности повторять прежнее поведение — свежая установка ведёт себя
// ровно как до появления этого экрана настроек.
class AppSettings {
  String dnsDirect;
  String dnsRemote;
  String dnsStrategy;
  int localPort;
  bool allowLan;
  int clashApiPort;
  String tunName;
  String tunIpv4;
  String tunIpv6;
  bool tunIpv6Enabled;
  String tunStack;
  int tunMtu;
  bool strictRoute;
  // Блок «включил и забыл»: автозапуск с системой, автоподключение,
  // сворачивание в трей вместо выхода.
  bool launchAtStartup;
  bool autoConnectAfterLaunch;
  bool hideAfterLaunch;
  bool closeToTray;
  bool disconnectWhenQuit;
  // Тест задержки и авто-выбор.
  // 'proxy'   — сквозной замер: поднимаем пробное ядро и идём через прокси до
  //             latencyUrl. Медленно и цифры большие, зато мёртвый сервер видно.
  // 'connect' — только TCP-подключение к самому серверу, как меряет Karing.
  //             Быстро и цифры маленькие, но успех НЕ доказывает, что прокси жив.
  String latencyMode;
  String latencyUrl;
  int latencyTimeoutMs;
  bool latencyWarmup;
  int tolerance;
  int autoSelectIntervalMin;
  String autoSelectFilter;
  int autoSelectLimit;
  bool autoSelectFavFirst;

  /// Прятать из списка серверы, которые тест признал нерабочими.
  ///
  /// В подписках по полтора десятка серверов, и часть из них не работает
  /// всегда: порт закрыт у провайдера, транспорт не проходит. Листать их
  /// каждый раз, чтобы вспомнить, какие именно не отвечают, — работа, которую
  /// приложение уже сделало за человека при тесте задержки.
  ///
  /// Непроверенные НЕ прячутся: про них ничего не известно, и спрятать их
  /// значило бы соврать.
  bool hideUnavailable;

  // Перед подключением прогнать тест и взять самый быстрый сервер.
  bool autoSelectOnConnect;
  // В обычном режиме без этого приложение бесполезно: поднимает прокси на
  // 127.0.0.1, о котором никто не знает. TUN системный прокси не использует.
  bool autoSetSystemProxy;
  bool autoUpdateSubscription;
  // 0 — брать интервал из заголовка панели. Иначе свой, в часах.
  int subUpdateIntervalHours;
  // Проверка обновлений ядер и обновление наборов правил.
  bool checkCoreUpdates;
  // Скачивать новые ядра самому. Применяется при следующем старте приложения:
  // работающий .exe Windows заменить не даст. Обновляет только ВПЕРЁД и только
  // если установленная версия читается — см. _stageCoreUpdate.
  bool autoUpdateCores;
  // Самообновление приложения. Источник задаётся URL'ом, а не вшит: своего
  // места публикации у проекта пока нет, и привязываться к чьему-то одному
  // (GitHub) незачем — сгодится любой хостинг, отдающий JSON и zip.
  // Пусто — механизм выключен целиком, никаких запросов в сеть.
  String updateFeedUrl;
  bool autoUpdateApp;
  int ruleSetRefreshDays;
  // Наборы правил по отдельности, как в Karing (GeoSite / GeoIP / ACL).
  // Раньше режим «РФ напрямую» включал geosite и geoip разом. Это разные
  // инструменты: geosite ловит домен (работает всегда, но только для того,
  // что пришло доменом), geoip — адрес (ловит и голый IP, но заставляет
  // ядро резолвить КАЖДЫЙ домен, чтобы узнать страну). На медленном DNS
  // выключенный geoip заметно оживляет открытие сайтов.
  // ACL — это набор блокировки рекламы, живёт в _blockAds рядом с режимом
  // маршрутизации: он не зависит от «РФ напрямую» и нужен в обоих режимах.
  bool geoSiteEnabled;
  bool geoIpEnabled;
  // NTP. Reality и VMess завязаны на время: расхождение системных часов
  // больше пары минут сервер считает попыткой повтора и рвёт соединение.
  // sing-box умеет держать своё время, не трогая системные часы (для этого
  // не нужны права администратора).
  bool ntpEnabled;
  String ntpServer;
  int ntpPort;
  String ntpInterval;
  // Расширенный DNS. Все поля проверены на нашей сборке sing-box.
  // Мультиплексирование: много логических соединений в одном физическом.
  bool muxEnabled;
  String muxProtocol; // h2mux | smux | yamux
  int muxMaxStreams;
  bool muxPadding;
  // Что НЕ пускать через системный прокси. Без этого списка локальная сеть,
  // роутер, принтеры и localhost идут в туннель, и половина домашних
  // устройств перестаёт отвечать.
  String proxyBypassList;
  bool autoRestartCore;

  /// Проверка, что сервер не просто отзывается, а РЕАЛЬНО пропускает трафик.
  ///
  /// Задержка меряется до `latencyUrl` — короткого эндпоинта, который отдаёт
  /// 204 и почти всегда доступен. Сервер может честно показывать 80 мс и при
  /// этом не открывать YouTube: провайдер режет конкретные направления,
  /// упирается в лимит, или шифрование в чужом профиле подобрано так, что
  /// живёт ровно до первого настоящего запроса. Пинг про это не знает.
  ///
  /// Поэтому проверка ходит по ОТДЕЛЬНОМУ адресу — по умолчанию к YouTube,
  /// на тот же `generate_204` (страницу целиком качать незачем).
  bool healthCheckEnabled;
  String healthCheckUrl;
  int healthCheckIntervalSec;

  /// Переключаться самим на следующий сервер, когда проверка провалилась
  /// дважды подряд. Дважды, а не один раз: одиночный промах бывает от
  /// заминки сети, и дёргать сервер под человеком из-за него нельзя.
  bool healthCheckAutoSwitch;
  /// Чем резолвятся домены, которые идут ЧЕРЕЗ прокси. Три способа, как в
  /// Karing («Способ разрешения в DNS» для трафика прокси):
  ///
  ///  * `current` — активным сервером. Резолв и соединение идут одним путём,
  ///    поэтому адрес приходит тот же, что увидит сервер. Значение по умолчанию.
  ///  * `direct`  — мимо туннеля. Быстрее, но провайдер видит, какие домена
  ///    запрашиваются, а под TUN этот путь может не работать вовсе.
  ///  * `fakeip`  — выдуманный адрес мгновенно, настоящий узнаётся уже при
  ///    подключении. Убирает ожидание DNS перед каждым запросом.
  ///
  /// Раньше это была галочка «FakeIP» плюс жёстко зашитый выбор сервера, и
  /// поменять способ было нельзя.
  String dnsProxyResolve; // current | direct | fakeip
  bool get dnsFakeIp => dnsProxyResolve == 'fakeip';
  bool dnsHijack;
  int dnsTtl; // 0 — не переписывать TTL
  String dnsClientSubnet; // пусто — не отправлять ECS
  List<String> dnsHosts; // строки вида "домен=адрес"
  String themeMode; // system | dark | light
  String language; // ru | en
  int accentColor; // ARGB, из чего строится вся палитра Material 3
  // Свои правила маршрутизации: по строке на запись, домен или IP/подсеть.
  // Имеют приоритет над готовыми наборами (geosite/geoip), поэтому ставятся
  // выше них в route.rules — иначе «РФ напрямую» перебивало бы личный выбор.
  List<String> customDirect;
  List<String> customProxy;
  List<String> customBlock;
  // Сервис -> proxy | direct | block. Отсутствие записи означает «по общему
  // правилу», поэтому храним только осознанно выбранное, а не все 24 сервиса.
  Map<String, String> serviceRules;
  // Полный путь к .exe -> proxy | direct | block. Именно путь, а не имя
  // процесса: под одним именем в системе легко живут два разных приложения
  // (у пользователя, например, свой xray.exe от v2rayN), и правило по имени
  // молча зацепило бы чужое. Проверено запуском в обычном режиме, не только
  // в TUN: правило на конкретный curl.exe отрезало именно его, а другой
  // curl.exe по соседнему пути продолжал ходить.
  Map<String, String> appRules;
  // Обход блокировок на уровне TLS. Проверено на наших сборках ядер:
  // sing-box понимает fragment / record_fragment / fragment_fallback_delay /
  // insecure; mixed_case_sni — НЕ понимает (это добавка форка Karing).
  // Xray делает фрагментацию иначе — отдельным freedom-outbound.
  bool tlsFragment;
  bool tlsRecordFragment;
  String tlsFragmentDelay;
  bool tlsInsecure;
  String xrayFragLength;
  String xrayFragInterval;

  // Значение `local` = системный резолвер Windows, а не конкретный адрес.
  // Это ЕДИНСТВЕННЫЙ вариант, который работает на любой сети, поэтому он и
  // стоит по умолчанию: см. историю в комментарии к `dnsDirect` ниже.
  static const String kSystemDns = 'local';

  AppSettings({
    // Обычный публичный адрес, а НЕ системный резолвер (`kSystemDns`).
    //
    // Через `dns-direct` резолвятся РОССИЙСКИЕ домены — те, что по режиму
    // «РФ напрямую» идут мимо туннеля. Системный резолвер для этого не
    // годится: под TUN запрос к нему сам заходит в туннель и упирается в
    // перехват DNS, то есть в круг. Я один раз поставил сюда `local` — и
    // зарубежные сайты открывались, а yandex.ru, mail.ru и gosuslugi.ru
    // висели по 12 секунд и не открывались вовсе. Замерено: у зарубежных
    // `dns=0.12 s`, у российских `dns=0.000` и таймаут.
    //
    // Тот резолв, ради которого затевался `local` — адрес самого
    // прокси-сервера, — больше не нужен вообще: адреса запекаются в конфиг
    // заранее (см. _bakeServerIps). Выбрать системный резолвер вручную
    // по-прежнему можно, он остаётся в списке.
    this.dnsDirect = '1.1.1.1',
    this.dnsRemote = '8.8.8.8',
    // ipv4_only, а НЕ prefer_ipv4. prefer_ipv4 означает лишь «предпочитать
    // A-запись», но AAAA всё равно отдаётся клиенту — и Windows выбирает IPv6.
    // Замерено под TUN: 50 из 56 соединений уходили на IPv6-адреса, а сервер
    // подписки IPv6 наружу не выпускает, поэтому всё вставало намертво
    // (0 байт за 22 с при 3 МБ за 0.6 с по IPv4 через тот же сервер).
    // ipv4_only убирает AAAA из ответа — строить IPv6-соединение просто не из чего.
    this.dnsStrategy = 'ipv4_only',
    this.localPort = 1337,
    this.allowLan = false,
    this.clashApiPort = 9090,
    this.tunName = 'SilaTUN',
    this.tunIpv4 = '172.19.0.1/30',
    this.tunIpv6 = 'fdfe:dcba:9876::1/126',
    this.tunIpv6Enabled = true,
    // `system` — потому что ЛЕЖАЩЕЕ В КОМПЛЕКТЕ ядро другого не умеет.
    //
    // Karing на Windows ставит `gvisor` (и ссылается на
    // https://github.com/SagerNet/sing-box/issues/1592), но он раздаёт свою
    // сборку sing-box. Наша собрана с `Tags: with_quic,with_utls,with_clash_api`
    // — без `with_gvisor`, и на этом стеке падает намертво:
    //   FATAL start inbound/tun: gVisor is not included in this build
    // Я один раз поменял дефолт «как у Karing», не проверив тег, и приложение
    // перестало подключаться совсем. Дефолт обязан работать с тем ядром,
    // которое лежит рядом, а не с идеальным.
    //
    // `mixed` — системный стек для TCP и gVisor для UDP. Берёт лучшее от
    // обоих: скорость системного на потоках и устойчивость gVisor на UDP.
    // Требует ядра, собранного с `with_gvisor`; официальные релизы SagerNet
    // такие, и именно они теперь идут в комплекте.
    //
    // Если ядро окажется без этого тега (самосборный бинарник, подложенный
    // руками), приложение не упадёт: оно спросит у ядра, что оно умеет, и
    // возьмёт `system`, написав об этом в лог. Один раз я поставил сюда
    // `gvisor`, не проверив тег, и приложение перестало подключаться совсем —
    // ядро падало на старте с `gVisor is not included in this build`.
    this.tunStack = 'mixed',
    // 4064, а не 9000 (дефолт sing-box). Внутри туннель идёт по TCP через
    // интернет, где MTU около 1500: при 9000 система отдаёт в туннель куски,
    // которые приходится резать по дороге, и на долгих передачах это
    // оборачивается обрывами. Значение взято у Karing — там оно выставлено
    // явно, а не оставлено дефолтным.
    this.tunMtu = 4064,
    this.strictRoute = true,
    this.launchAtStartup = false,
    // ВЫКЛЮЧЕНО по умолчанию, и это исправление, а не смена вкуса.
    //
    // Рассуждение было такое: приложение запускают ради того, чтобы оно
    // работало, а не чтобы каждый раз нажимать «Запустить». На практике вышло
    // иначе — человек сидит за компьютером, а VPN у него включается сам, и не
    // по одному разу: при запуске, при возврате из трея, после восстановления
    // упавшего ядра. Включение VPN само по себе рвёт живые соединения
    // (браузер, мессенджеры переустанавливают их), то есть незваное
    // подключение это не «удобство», а вмешательство в то, что человек делает
    // прямо сейчас.
    //
    // Восстановление после ОБРЫВА этим не отменяется и не должно: там человек
    // уже нажал «Запустить», и вернуть упавшее — продолжение его решения, а не
    // самостоятельное. Разница ровно в том, было ли соединение до этого.
    this.autoConnectAfterLaunch = false,
    this.hideAfterLaunch = false,
    this.closeToTray = true,
    this.disconnectWhenQuit = true,
    // http, а НЕ https: Clash и Karing по умолчанию берут именно http-эндпоинт.
    // С https каждый замер дополнительно платит за полное TLS-рукопожатие до
    // gstatic, и цифра выходит в разы больше, чем у других клиентов, — при
    // одинаковом качестве связи. Это и была причина "высокого пинга".
    // Пинг меряем ДО СЕРВЕРА — так же, как v2rayN и Karing.
    //
    // Это осознанный возврат к 'connect'. Раньше стоял сквозной замер: он идёт
    // через сам протокол до проверочного сайта и потому честнее — но даёт
    // 130–500 мс там, где другие клиенты показывают 25–40, и человек
    // естественно читает это как «у вашего приложения плохая связь». Обе
    // цифры верны, просто это разные величины: наша включала весь путь
    // наружу, их — только до сервера.
    //
    // Довод против 'connect' был такой: на подписке, где ВСЕ серверы живут на
    // одном хосте и отличаются лишь портом, TCP-рукопожатие у всех одинаковое
    // и выбирать не из чего. Довод верный, но узкий: на подписках из сотни с
    // лишним серверов, ради которых всё это и затевалось, хосты разные, и
    // цифры различаются нормально.
    //
    // Чем платим и чем это закрыто: успешное TCP-подключение означает только,
    // что порт принимает соединения, — сломанный прокси таким тестом не
    // ловится. Раньше это было бы потерей проверки, теперь нет: работоспособ-
    // ность проверяется отдельно и по делу — сквозным запросом в момент
    // подключения (`_verifyConnection`), который прямо говорит, выходит ли
    // трафик наружу. То есть быстрый список и честный вердикт разведены.
    //
    // Протоколы поверх UDP (Hysteria2, TUIC) TCP-проверкой не измеряются в
    // принципе — их порт TCP не принимает. Для них замер и дальше идёт через
    // пробное ядро, см. `_udpOnlyProtocols`.
    this.latencyMode = 'connect',
    // ИМЕННО https. Была попытка перейти на http «как в Clash» — обычный HTTP
    // через прокси Xray не держит соединение живым, и замерочный запрос,
    // идущий по тому же HttpClient следом за прогревочным, падал с
    // "Connection closed before full header was received": все xhttp-серверы
    // показывались недоступными. Замерено на живом ядре:
    //   http  + прогрев -> обрыв          http  без прогрева -> 204 за 436 мс
    //   https + прогрев -> 204 за 100 мс  https без прогрева -> 204 за 350 мс
    // То есть https с прогревом ещё и самый быстрый вариант.
    // cp.cloudflare.com, а не gstatic: это anycast-адрес, он отдаётся из
    // дата-центра РЯДОМ с прокси-сервером, поэтому в замер почти не попадает
    // «второе плечо» — путь от сервера до проверочного сайта. Замерено через
    // один и тот же сервер: gstatic 416 мс, google 117 мс, cloudflare 82 мс.
    // Различие между серверами при этом сохраняется — запрос всё равно идёт
    // через сам протокол, а не мимо него (в отличие от режима 'connect').
    this.latencyUrl = 'https://cp.cloudflare.com/generate_204',
    this.latencyTimeoutMs = 5000,
    this.latencyWarmup = true,
    this.tolerance = 30,
    // Раз в 15 минут, а не «никогда». Сервер, самый быстрый на момент
    // подключения, через час может им уже не быть: провайдер меняет нагрузку,
    // маршруты плавают. Смысл авто-выбора теряется, если он срабатывает
    // ровно один раз за сеанс. Переключение при этом не дёргает соединение
    // попусту — есть допуск (tolerance), ниже которого сервер не меняется.
    this.autoSelectIntervalMin = 15,
    this.autoSelectFilter = '',
    this.autoSelectLimit = 0,
    this.autoSelectFavFirst = false,
    this.hideUnavailable = true,
    this.autoSelectOnConnect = true,
    this.tlsFragment = false,
    this.tlsRecordFragment = false,
    this.tlsFragmentDelay = '500ms',
    this.tlsInsecure = false,
    this.xrayFragLength = '100-200',
    this.xrayFragInterval = '10-20',
    this.autoSetSystemProxy = true,
    this.autoUpdateSubscription = true,
    // 12 часов. Ноль означал «взять интервал из заголовка панели», и это
    // выглядело разумно, пока не выяснилось, что заголовок присылают не все
    // панели: у кого его нет — подписка не обновлялась вообще никогда, и
    // список серверов тихо устаревал. Явное число работает у всех, а тот,
    // кому важен интервал панели, по-прежнему может поставить 0.
    this.subUpdateIntervalHours = 12,
    this.checkCoreUpdates = true,
    this.autoUpdateCores = true,
    // Свои же релизы на GitHub. Раньше тут было пусто — «своего места
    // публикации у проекта пока нет», — и самообновление не делало ничего:
    // людям приходилось следить за выходом версий вручную. Место появилось,
    // так что адрес по умолчанию прописан. Поле остаётся редактируемым:
    // сгодится любой хостинг, отдающий JSON (см. _fetchAppUpdate — он
    // понимает и формат GitHub, и простой манифест `{version, url}`).
    this.updateFeedUrl =
        'https://api.github.com/repos/MrMultik/Multik-Sila/releases/latest',
    this.autoUpdateApp = true,
    this.ruleSetRefreshDays = 1,
    this.geoSiteEnabled = true,
    this.geoIpEnabled = true,
    this.ntpEnabled = false,
    // time.windows.com — тот же сервер, что использует сама Windows, поэтому
    // заведомо доступен там, где работает система.
    this.ntpServer = 'time.windows.com',
    this.ntpPort = 123,
    this.ntpInterval = '30m',
    this.muxEnabled = false,
    this.muxProtocol = 'h2mux',
    this.muxMaxStreams = 8,
    this.muxPadding = false,
    // Значения по умолчанию покрывают петлю, локальные имена и все частные
    // подсети — то, что заведомо не должно ходить через VPN.
    //
    // ТОКЕНА `<-loopback>` ЗДЕСЬ БЫТЬ НЕ ДОЛЖНО. Он выглядит как «исключить
    // петлю», а означает ровно обратное: минус отменяет встроенное правило
    // Windows «localhost мимо прокси» и загоняет петлевой трафик В ТУННЕЛЬ.
    // Это тот токен, который советуют добавлять, когда петлю надо ПЕРЕХВАТИТЬ
    // (например, снифферам). Пока системный прокси фактически не включался,
    // строка лежала мёртвым грузом; как только включение заработало, через
    // туннель пошло общение программ с их же локальными службами — снаружи
    // это выглядит как «приложение вдруг перестало видеть свой сервер».
    //
    // IPv6-петлю (`::1`, `[::1]`) сюда ПИСАТЬ НЕЛЬЗЯ, хотя и хочется:
    // WinINET такой записи не принимает и отвергает ВЕСЬ набор опций целиком —
    // `InternetSetOption` возвращает отказ, и прокси не включается вовсе.
    // Наружу это вышло как «Chrome работает, а всё остальное нет»: плоские
    // значения реестра Chromium читает сам, а WinINET остаётся на «прямом
    // подключении». Отдельные записи для петли и не нужны: как только из
    // списка убран `<-loopback>`, Windows освобождает петлю сама, оба семейства.
    //
    // Каждая восьмёрка 172.16–172.31 выписана отдельной строкой. Сокращения
    // вида `172.2*` здесь НЕЛЬЗЯ: маска WinINET сравнивает текст, и `172.2*`
    // ловит не только частные 172.20–172.29, но и вполне публичные 172.2xx —
    // в том числе 172.217.*.* и 172.253.*.* (Google/YouTube) и 172.224.*.*
    // (Akamai). Всё, к чему обращаются по голому IP из этих диапазонов, тихо
    // уходило мимо туннеля.
    // Список намеренно отличается от заведомо рабочего ровно двумя вещами:
    // убран `<-loopback>` и развёрнута маска `172.2*`. Ничего «заодно» сюда
    // добавлять нельзя — каждая новая запись это риск, что WinINET отвергнет
    // набор целиком, а отказ у него молчаливый (см. историю с `::1`).
    this.proxyBypassList = '<local>;localhost;*.local;127.*;10.*;'
        '172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;'
        '172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;'
        '172.30.*;172.31.*;192.168.*',
    this.autoRestartCore = true,
    this.healthCheckEnabled = true,
    // Именно YouTube: это и есть тот случай, из-за которого проверка
    // заведена, и одновременно самый строгий из массовых — он идёт к Google,
    // требует живого TLS и первым отваливается на проблемном сервере.
    this.healthCheckUrl = 'https://www.youtube.com/generate_204',
    // Минута: чаще — лишний трафик и шум в логе, реже — человек успевает
    // упереться в неработающий сервер раньше проверки.
    this.healthCheckIntervalSec = 60,
    this.healthCheckAutoSwitch = true,
    // FakeIP по умолчанию: адрес выдаётся мгновенно, и ожидание DNS перед
    // каждым запросом исчезает совсем. Домены, которым нужен НАСТОЯЩИЙ адрес
    // (обход РФ по geoip, личные списки «напрямую», хосты прокси-серверов),
    // резолвятся честно — правило FakeIP стоит последним, уже после них.
    this.dnsProxyResolve = 'fakeip',
    this.dnsHijack = true,
    this.dnsTtl = 0,
    this.dnsClientSubnet = '',
    List<String>? dnsHosts,
    this.themeMode = 'dark',
    this.language = 'ru',
    this.accentColor = 0xFF7C4DFF,
    List<String>? customDirect,
    List<String>? customProxy,
    List<String>? customBlock,
    Map<String, String>? serviceRules,
    Map<String, String>? appRules,
  })  : appRules = appRules ?? {},
        customDirect = customDirect ?? [],
        customProxy = customProxy ?? [],
        customBlock = customBlock ?? [],
        serviceRules = serviceRules ?? {},
        dnsHosts = dnsHosts ?? [];

  // Копия с точечной заменой полей — чтобы экран, правящий одну секцию,
  // не собирал весь объект заново и не терял настройки соседних разделов.
  factory AppSettings.from(
    AppSettings s, {
    List<String>? customDirect,
    List<String>? customProxy,
    List<String>? customBlock,
    Map<String, String>? serviceRules,
    Map<String, String>? appRules,
  }) {
    final copy = AppSettings.fromJson(s.toJson());
    if (appRules != null) copy.appRules = appRules;
    if (customDirect != null) copy.customDirect = customDirect;
    if (customProxy != null) copy.customProxy = customProxy;
    if (customBlock != null) copy.customBlock = customBlock;
    if (serviceRules != null) copy.serviceRules = serviceRules;
    return copy;
  }

  // Готовые варианты, чтобы не вспоминать адреса наизусть. Порядок — от
  // самых обычных к специальным.
  // Геттер, а не const: подписи содержат переводимые слова («запасной»,
  // «режет рекламу»), а const-карта вызов t() внутрь не пускает. Ключи —
  // сами адреса, они от языка не зависят и в настройках хранятся как есть.
  static Map<String, String> get dnsPresets => {
        kSystemDns: t('dns.system'),
        '1.1.1.1': 'Cloudflare — 1.1.1.1',
        '1.0.0.1': 'Cloudflare ${t('dns.backup')} — 1.0.0.1',
        '8.8.8.8': 'Google — 8.8.8.8',
        '8.8.4.4': 'Google ${t('dns.backup')} — 8.8.4.4',
        '9.9.9.9': 'Quad9 — 9.9.9.9 (${t('dns.blocksMalware')})',
        '149.112.112.112': 'Quad9 ${t('dns.backup')} — 149.112.112.112',
        '94.140.14.14': 'AdGuard — 94.140.14.14 (${t('dns.blocksAds')})',
        '94.140.14.140': 'AdGuard ${t('dns.noFilter')} — 94.140.14.140',
        '208.67.222.222': 'OpenDNS — 208.67.222.222',
        '77.88.8.8': '${t('dns.yandex')} — 77.88.8.8',
        '77.88.8.88': '${t('dns.yandex')} ${t('dns.safe')} — 77.88.8.88',
        '80.80.80.80': 'Freenom — 80.80.80.80',
      };

  // Домены популярных сервисов — для правил «этот сервис всегда так».
  // Списки свои, собраны по фактическим доменам сервисов.
  static const serviceDomains = <String, List<String>>{
    'YouTube': ['youtube.com', 'youtu.be', 'ytimg.com', 'googlevideo.com', 'yt3.ggpht.com'],
    'Google': ['google.com', 'gstatic.com', 'googleapis.com', 'googleusercontent.com', 'withgoogle.com'],
    'Telegram': ['telegram.org', 't.me', 'telesco.pe', 'telegram.me', 'tdesktop.com'],
    'Discord': ['discord.com', 'discordapp.com', 'discord.gg', 'discordapp.net'],
    'WhatsApp': ['whatsapp.com', 'whatsapp.net', 'wa.me'],
    'Instagram': ['instagram.com', 'cdninstagram.com', 'ig.me'],
    'Facebook': ['facebook.com', 'fbcdn.net', 'fb.com', 'messenger.com'],
    'X (Twitter)': ['twitter.com', 'x.com', 'twimg.com', 't.co'],
    'Netflix': ['netflix.com', 'nflxvideo.net', 'nflximg.net', 'nflxext.com'],
    'Twitch': ['twitch.tv', 'ttvnw.net', 'jtvnw.net'],
    'OpenAI / ChatGPT': ['openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com'],
    'Claude': ['claude.ai', 'anthropic.com'],
    'GitHub': ['github.com', 'githubusercontent.com', 'githubassets.com', 'ghcr.io'],
    'Spotify': ['spotify.com', 'scdn.co', 'spotifycdn.com'],
    'Steam': ['steampowered.com', 'steamcommunity.com', 'steamstatic.com'],
    'Microsoft': ['microsoft.com', 'live.com', 'office.com', 'windowsupdate.com'],
    'Apple': ['apple.com', 'icloud.com', 'mzstatic.com'],
    'Яндекс': ['yandex.ru', 'yandex.net', 'yastatic.net', 'ya.ru'],
    'VK': ['vk.com', 'vk.ru', 'userapi.com', 'vk-cdn.net'],
    'Сбербанк': ['sberbank.ru', 'sber.ru', 'sberbank.com'],
    'Госуслуги': ['gosuslugi.ru', 'gosuslugi.gov.ru'],
    'Тинькофф': ['tinkoff.ru', 'tbank.ru'],
    'Ozon': ['ozon.ru', 'ozone.ru', 'ozon.travel'],
    'Wildberries': ['wildberries.ru', 'wb.ru', 'wbbasket.ru'],
  };

  // Значки по смыслу сервиса и фирменные цвета кружка. Логотипы брендов
  // намеренно не используем — тянуть чужую графику в приложение незачем,
  // а по значку и цвету сервис узнаётся не хуже.
  static const serviceIcons = <String, (IconData, int)>{
    'YouTube': (Icons.play_circle_fill, 0xFFFF0000),
    'Google': (Icons.search, 0xFF4285F4),
    'Telegram': (Icons.send, 0xFF229ED9),
    'Discord': (Icons.forum, 0xFF5865F2),
    'WhatsApp': (Icons.chat_bubble, 0xFF25D366),
    'Instagram': (Icons.photo_camera, 0xFFE1306C),
    'Facebook': (Icons.facebook, 0xFF1877F2),
    'X (Twitter)': (Icons.close, 0xFF71767B),
    'Netflix': (Icons.movie, 0xFFE50914),
    'Twitch': (Icons.videogame_asset, 0xFF9146FF),
    'OpenAI / ChatGPT': (Icons.auto_awesome, 0xFF10A37F),
    'Claude': (Icons.psychology, 0xFFD97757),
    'GitHub': (Icons.code, 0xFF8B949E),
    'Spotify': (Icons.music_note, 0xFF1DB954),
    'Steam': (Icons.sports_esports, 0xFF66C0F4),
    'Microsoft': (Icons.window, 0xFF00A4EF),
    'Apple': (Icons.apple, 0xFFA2AAAD),
    'Яндекс': (Icons.travel_explore, 0xFFFC3F1D),
    'VK': (Icons.people, 0xFF0077FF),
    'Сбербанк': (Icons.account_balance, 0xFF21A038),
    'Госуслуги': (Icons.assured_workload, 0xFF0D4CD3),
    'Тинькофф': (Icons.credit_card, 0xFFFFDD2D),
    'Ozon': (Icons.shopping_bag, 0xFF005BFF),
    'Wildberries': (Icons.shopping_cart, 0xFFCB11AB),
  };

  static const serviceActions = <String, String>{
    'default': 'action.default',
    'proxy': 'action.proxy',
    'direct': 'action.direct',
    'block': 'action.block',
  };

  // Готовые NTP-серверы. Первый — тот же, что использует сама Windows.
  static const ntpPresets = <String, String>{
    'time.windows.com': 'time.windows.com — Windows',
    'time.google.com': 'time.google.com — Google',
    'time.cloudflare.com': 'time.cloudflare.com — Cloudflare',
    'pool.ntp.org': 'pool.ntp.org — NTP Pool',
    // Латиницей: карта const, вызов t() внутрь не поставить, а название
    // института в английском интерфейсе кириллицей выглядело бы ошибкой.
    'ntp1.vniiftri.ru': 'ntp1.vniiftri.ru — VNIIFTRI (RU)',
  };

  static Map<String, String> get latencyUrlPresets => {
        'https://cp.cloudflare.com/generate_204': 'Cloudflare — ${t('lat.closest')}',
        'https://www.google.com/generate_204': 'Google',
        'https://connectivitycheck.gstatic.com/generate_204': 'Google (${t('lat.connCheck')})',
        'https://www.gstatic.com/generate_204': 'Gstatic — ${t('lat.farther')}',
      };

  static const stacks = ['system', 'gvisor', 'mixed'];
  static const strategies = ['prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'];

  Map<String, dynamic> toJson() => {
        'dnsDirect': dnsDirect,
        'dnsRemote': dnsRemote,
        'dnsStrategy': dnsStrategy,
        'localPort': localPort,
        'allowLan': allowLan,
        'clashApiPort': clashApiPort,
        'tunName': tunName,
        'tunIpv4': tunIpv4,
        'tunIpv6': tunIpv6,
        'tunIpv6Enabled': tunIpv6Enabled,
        'tunStack': tunStack,
        'tunMtu': tunMtu,
        'strictRoute': strictRoute,
        'launchAtStartup': launchAtStartup,
        'autoConnectAfterLaunch': autoConnectAfterLaunch,
        'hideAfterLaunch': hideAfterLaunch,
        'closeToTray': closeToTray,
        'disconnectWhenQuit': disconnectWhenQuit,
        'latencyMode': latencyMode,
        'latencyUrl': latencyUrl,
        'latencyTimeoutMs': latencyTimeoutMs,
        'latencyWarmup': latencyWarmup,
        'tolerance': tolerance,
        'autoSelectIntervalMin': autoSelectIntervalMin,
        'autoSelectFilter': autoSelectFilter,
        'autoSelectLimit': autoSelectLimit,
        'autoSelectFavFirst': autoSelectFavFirst,
        'hideUnavailable': hideUnavailable,
        'autoSelectOnConnect': autoSelectOnConnect,
        'autoSetSystemProxy': autoSetSystemProxy,
        'autoUpdateSubscription': autoUpdateSubscription,
        'subUpdateIntervalHours': subUpdateIntervalHours,
        'checkCoreUpdates': checkCoreUpdates,
        'autoUpdateCores': autoUpdateCores,
        'updateFeedUrl': updateFeedUrl,
        'autoUpdateApp': autoUpdateApp,
        'ruleSetRefreshDays': ruleSetRefreshDays,
        'geoSiteEnabled': geoSiteEnabled,
        'geoIpEnabled': geoIpEnabled,
        'ntpEnabled': ntpEnabled,
        'ntpServer': ntpServer,
        'ntpPort': ntpPort,
        'ntpInterval': ntpInterval,
        'muxEnabled': muxEnabled,
        'muxProtocol': muxProtocol,
        'muxMaxStreams': muxMaxStreams,
        'muxPadding': muxPadding,
        'proxyBypassList': proxyBypassList,
        'autoRestartCore': autoRestartCore,
        'healthCheckEnabled': healthCheckEnabled,
        'healthCheckUrl': healthCheckUrl,
        'healthCheckIntervalSec': healthCheckIntervalSec,
        'healthCheckAutoSwitch': healthCheckAutoSwitch,
        'dnsProxyResolve': dnsProxyResolve,
        'dnsHijack': dnsHijack,
        'dnsTtl': dnsTtl,
        'dnsClientSubnet': dnsClientSubnet,
        'dnsHosts': dnsHosts,
        'themeMode': themeMode,
        'language': language,
        'accentColor': accentColor,
        'customDirect': customDirect,
        'customProxy': customProxy,
        'customBlock': customBlock,
        'serviceRules': serviceRules,
        'appRules': appRules,
        'tlsFragment': tlsFragment,
        'tlsRecordFragment': tlsRecordFragment,
        'tlsFragmentDelay': tlsFragmentDelay,
        'tlsInsecure': tlsInsecure,
        'xrayFragLength': xrayFragLength,
        'xrayFragInterval': xrayFragInterval,
      };

  // Чинит списки исключений, сохранённые прежними версиями. Смена дефолта
  // сама по себе не лечит НИКОГО: список у всех уже лежит в настройках.
  //
  //  * `<-loopback>` — выкидываем. Он загонял петлевой трафик в туннель
  //    (см. комментарий у дефолта), из-за чего программы теряли связь со
  //    своими же локальными службами.
  //  * `172.2*` — разворачиваем в честные восьмёрки 172.20–172.29: маска
  //    сравнивается текстом и задевала публичные 172.2xx, включая Google.
  //  * `::1`/`[::1]` — ВЫКИДЫВАЕМ, если кто-то их вписал (я и вписал, в
  //    промежуточной версии). WinINET на такой записи отвергает весь набор
  //    опций, и системный прокси не включается вовсе — см. дефолт выше.
  static const Set<String> _badBypassEntries = {'<-loopback>', '::1', '[::1]'};

  static String _fixLegacyBypassList(String list) => list
      .split(';')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && !_badBypassEntries.contains(e))
      .expand((e) =>
          e == '172.2*' ? [for (var i = 20; i <= 29; i++) '172.$i.*'] : [e])
      .join(';');

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final d = AppSettings();
    return AppSettings(
      // Откат моей же неудачной правки: значение `local` попало в настройки
      // автоматической миграцией, а не выбором человека, и ломало резолв
      // российских доменов под TUN. Возвращаем на публичный адрес.
      dnsDirect: () {
        final v = j['dnsDirect'] as String? ?? d.dnsDirect;
        return v == AppSettings.kSystemDns ? d.dnsDirect : v;
      }(),
      dnsRemote: j['dnsRemote'] as String? ?? d.dnsRemote,
      dnsStrategy: j['dnsStrategy'] as String? ?? d.dnsStrategy,
      localPort: j['localPort'] as int? ?? d.localPort,
      allowLan: j['allowLan'] as bool? ?? d.allowLan,
      clashApiPort: j['clashApiPort'] as int? ?? d.clashApiPort,
      tunName: j['tunName'] as String? ?? d.tunName,
      tunIpv4: j['tunIpv4'] as String? ?? d.tunIpv4,
      tunIpv6: j['tunIpv6'] as String? ?? d.tunIpv6,
      tunIpv6Enabled: j['tunIpv6Enabled'] as bool? ?? d.tunIpv6Enabled,
      tunStack: j['tunStack'] as String? ?? d.tunStack,
      // Прежний дефолт MTU (9000) переводим на 4064. Это было НАШЕ значение,
      // а не выбор человека. Кто выставил своё — сохранит: остальные не трогаем.
      tunMtu: () {
        final v = j['tunMtu'] as int? ?? d.tunMtu;
        return v == 9000 ? d.tunMtu : v;
      }(),
      strictRoute: j['strictRoute'] as bool? ?? d.strictRoute,
      launchAtStartup: j['launchAtStartup'] as bool? ?? d.launchAtStartup,
      autoConnectAfterLaunch: j['autoConnectAfterLaunch'] as bool? ?? d.autoConnectAfterLaunch,
      hideAfterLaunch: j['hideAfterLaunch'] as bool? ?? d.hideAfterLaunch,
      closeToTray: j['closeToTray'] as bool? ?? d.closeToTray,
      disconnectWhenQuit: j['disconnectWhenQuit'] as bool? ?? d.disconnectWhenQuit,
      latencyMode: j['latencyMode'] as String? ?? d.latencyMode,
      latencyUrl: j['latencyUrl'] as String? ?? d.latencyUrl,
      latencyTimeoutMs: j['latencyTimeoutMs'] as int? ?? d.latencyTimeoutMs,
      latencyWarmup: j['latencyWarmup'] as bool? ?? d.latencyWarmup,
      tolerance: j['tolerance'] as int? ?? d.tolerance,
      // Ноль был НАШИМ прежним дефолтом («не перепроверять по расписанию»), и
      // из-за него авто-выбор срабатывал ровно один раз за сеанс. Переводим на
      // новое значение — как и остальные наши неудачные умолчания. Кому нужно
      // «никогда», выставит 0 заново, и оно сохранится: сравниваем с прежним
      // дефолтом только при чтении, а записанное руками уже не трогаем.
      autoSelectIntervalMin: () {
        final v = j['autoSelectIntervalMin'] as int? ?? d.autoSelectIntervalMin;
        return v == 0 ? d.autoSelectIntervalMin : v;
      }(),
      autoSelectFilter: j['autoSelectFilter'] as String? ?? d.autoSelectFilter,
      autoSelectLimit: j['autoSelectLimit'] as int? ?? d.autoSelectLimit,
      autoSelectFavFirst: j['autoSelectFavFirst'] as bool? ?? d.autoSelectFavFirst,
      hideUnavailable: j['hideUnavailable'] as bool? ?? d.hideUnavailable,
      autoSelectOnConnect: j['autoSelectOnConnect'] as bool? ?? d.autoSelectOnConnect,
      autoSetSystemProxy: j['autoSetSystemProxy'] as bool? ?? d.autoSetSystemProxy,
      autoUpdateSubscription: j['autoUpdateSubscription'] as bool? ?? d.autoUpdateSubscription,
      // Ноль означал «взять интервал из заголовка панели», но заголовок
      // присылают не все — у таких подписка не обновлялась вообще никогда.
      // Это тоже наш прежний дефолт, переводим на явные 12 часов.
      subUpdateIntervalHours: () {
        final v = j['subUpdateIntervalHours'] as int? ?? d.subUpdateIntervalHours;
        return v == 0 ? d.subUpdateIntervalHours : v;
      }(),
      checkCoreUpdates: j['checkCoreUpdates'] as bool? ?? d.checkCoreUpdates,
      autoUpdateCores: j['autoUpdateCores'] as bool? ?? d.autoUpdateCores,
      // Пустая строка в сохранённых настройках — это НЕ выбор человека, а
      // прежний дефолт «источника нет». Тем, у кого он остался, подставляем
      // новый адрес: иначе самообновление у них так и не включится никогда.
      // Кто вписал свой хостинг — сохранит его, пустым он не бывает.
      updateFeedUrl: () {
        final v = (j['updateFeedUrl'] as String? ?? '').trim();
        return v.isEmpty ? d.updateFeedUrl : v;
      }(),
      autoUpdateApp: j['autoUpdateApp'] as bool? ?? d.autoUpdateApp,
      ruleSetRefreshDays: j['ruleSetRefreshDays'] as int? ?? d.ruleSetRefreshDays,
      geoSiteEnabled: j['geoSiteEnabled'] as bool? ?? d.geoSiteEnabled,
      geoIpEnabled: j['geoIpEnabled'] as bool? ?? d.geoIpEnabled,
      ntpEnabled: j['ntpEnabled'] as bool? ?? d.ntpEnabled,
      ntpServer: j['ntpServer'] as String? ?? d.ntpServer,
      ntpPort: j['ntpPort'] as int? ?? d.ntpPort,
      ntpInterval: j['ntpInterval'] as String? ?? d.ntpInterval,
      muxEnabled: j['muxEnabled'] as bool? ?? d.muxEnabled,
      muxProtocol: j['muxProtocol'] as String? ?? d.muxProtocol,
      muxMaxStreams: j['muxMaxStreams'] as int? ?? d.muxMaxStreams,
      muxPadding: j['muxPadding'] as bool? ?? d.muxPadding,
      proxyBypassList: _fixLegacyBypassList(
          j['proxyBypassList'] as String? ?? d.proxyBypassList),
      autoRestartCore: j['autoRestartCore'] as bool? ?? d.autoRestartCore,
      healthCheckEnabled: j['healthCheckEnabled'] as bool? ?? d.healthCheckEnabled,
      healthCheckUrl: j['healthCheckUrl'] as String? ?? d.healthCheckUrl,
      healthCheckIntervalSec:
          j['healthCheckIntervalSec'] as int? ?? d.healthCheckIntervalSec,
      healthCheckAutoSwitch:
          j['healthCheckAutoSwitch'] as bool? ?? d.healthCheckAutoSwitch,
      // Старая галочка превращается в способ: включённый FakeIP так и
      // остаётся FakeIP, выключенный — «активным сервером».
      dnsProxyResolve: j['dnsProxyResolve'] as String? ??
          ((j['dnsFakeIp'] as bool? ?? false) ? 'fakeip' : d.dnsProxyResolve),
      dnsHijack: j['dnsHijack'] as bool? ?? d.dnsHijack,
      dnsTtl: j['dnsTtl'] as int? ?? d.dnsTtl,
      dnsClientSubnet: j['dnsClientSubnet'] as String? ?? d.dnsClientSubnet,
      dnsHosts: (j['dnsHosts'] as List?)?.cast<String>(),
      themeMode: j['themeMode'] as String? ?? d.themeMode,
      language: j['language'] as String? ?? d.language,
      accentColor: j['accentColor'] as int? ?? d.accentColor,
      customDirect: (j['customDirect'] as List?)?.cast<String>(),
      customProxy: (j['customProxy'] as List?)?.cast<String>(),
      customBlock: (j['customBlock'] as List?)?.cast<String>(),
      serviceRules: (j['serviceRules'] as Map?)?.map((k, v) => MapEntry('$k', '$v')),
      appRules: (j['appRules'] as Map?)?.map((k, v) => MapEntry('$k', '$v')),
      tlsFragment: j['tlsFragment'] as bool? ?? d.tlsFragment,
      tlsRecordFragment: j['tlsRecordFragment'] as bool? ?? d.tlsRecordFragment,
      tlsFragmentDelay: j['tlsFragmentDelay'] as String? ?? d.tlsFragmentDelay,
      tlsInsecure: j['tlsInsecure'] as bool? ?? d.tlsInsecure,
      xrayFragLength: j['xrayFragLength'] as String? ?? d.xrayFragLength,
      xrayFragInterval: j['xrayFragInterval'] as String? ?? d.xrayFragInterval,
    );
  }
}

ParsedServer? parseVless(String line) {
  if (!line.startsWith('vless://')) return null;

  try {
    final uri = Uri.parse(line);
    final uuid = uri.userInfo;
    final server = uri.host;
    final port = uri.port;
    final params = uri.queryParameters;

    final security = params['security'] ?? 'none';
    final flow = params['flow'] ?? '';
    final sni = params['sni'] ?? server;
    final name = Uri.decodeComponent(uri.fragment.isNotEmpty ? uri.fragment : 'VLESS $server:$port');
    final netType = params['type'] ?? 'tcp';

    if (netType == 'xhttp') {
      final xrayOutbound = {
        "protocol": "vless",
        "tag": "proxy",
        "settings": {
          "vnext": [
            {
              "address": server,
              "port": port,
              "users": [
                {
                  "id": uuid,
                  "encryption": "none",
                  if (flow.isNotEmpty) "flow": flow,
                }
              ],
            }
          ],
        },
        "streamSettings": _buildXhttpStreamSettings(params, server),
      };
      return ParsedServer(name: name, protocol: 'vless', outbound: xrayOutbound, engine: 'xray');
    }

    final Map<String, dynamic> outbound = {
      "type": "vless",
      "tag": "proxy",
      "server": server,
      "server_port": port,
      "uuid": uuid,
      if (flow.isNotEmpty) "flow": flow,
    };

    if (security == 'tls' || security == 'reality') {
      final tls = <String, dynamic>{
        "enabled": true,
        "server_name": sni,
        // uTLS-маскировка теперь включена всегда, а не только для Reality —
        // этот провайдер явно рассчитывает на неё для любого TLS-соединения
        "utls": {
          "enabled": true,
          "fingerprint": params['fp'] ?? 'chrome',
        },
      };

      final alpnParam = params['alpn'];
      if (alpnParam != null && alpnParam.isNotEmpty) {
        tls["alpn"] = alpnParam.split(',');
      }

      if (security == 'reality') {
        tls["reality"] = {
          "enabled": true,
          "public_key": params['pbk'],
          "short_id": params['sid'] ?? '',
        };
      }

      outbound["tls"] = tls;
    }

    if (netType == 'grpc') {
      outbound["transport"] = {
        "type": "grpc",
        "service_name": params['serviceName'] ?? '',
      };
    } else if (netType == 'ws') {
      outbound["transport"] = {
        "type": "ws",
        "path": params['path'] ?? '/',
      };
    }

    return ParsedServer(name: name, protocol: 'vless', outbound: outbound);
  } catch (e) {
    return null;
  }
}

ParsedServer? parseVmess(String line) {
  if (!line.startsWith('vmess://')) return null;

  try {
    final raw = line.substring('vmess://'.length);
    final jsonStr = utf8.decode(base64.decode(raw));
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;

    final server = data['add'] as String;
    final port = int.parse(data['port'].toString());
    final uuid = data['id'] as String;
    final network = (data['net'] ?? 'tcp') as String;
    final tlsMode = (data['tls'] ?? '') as String;
    final sni = (data['sni'] as String?)?.isNotEmpty == true ? data['sni'] as String : server;
    final name = (data['ps'] as String?) ?? 'VMess $server:$port';
    final alpnRaw = data['alpn'] as String?;
    final fp = (data['fp'] as String?) ?? 'chrome';

    if (network == 'xhttp') {
      final xhttpParams = <String, String>{
        'security': tlsMode,
        'sni': sni,
        'fp': fp,
        'path': (data['path'] as String?) ?? '/',
        'mode': (data['mode'] as String?) ?? 'auto',
        'host': (data['host'] as String?) ?? '',
        'x_padding_bytes': (data['xPaddingBytes'] as String?) ?? (data['x_padding_bytes'] as String?) ?? '',
        'alpn': alpnRaw ?? '',
      };
      final xrayOutbound = {
        "protocol": "vmess",
        "tag": "proxy",
        "settings": {
          "vnext": [
            {
              "address": server,
              "port": port,
              "users": [
                {"id": uuid, "security": (data['scy'] as String?) ?? 'auto'}
              ],
            }
          ],
        },
        "streamSettings": _buildXhttpStreamSettings(xhttpParams, server),
      };
      return ParsedServer(name: name, protocol: 'vmess', outbound: xrayOutbound, engine: 'xray');
    }

    // sing-box, если security=auto и включён TLS, сам тихо переключается на
    // "zero" (без шифрования VMess-заголовка, полагаясь на TLS) — часть
    // серверов (например, панели на базе Xray) такие соединения молча рвут,
    // хотя обычный TLS-хендшейк с ними при этом проходит нормально.
    // Форсим реальный шифр, чтобы обойти этот авто-даунгрейд.
    final rawSecurity = (data['scy'] as String?) ?? 'auto';
    final security = (rawSecurity == 'auto' && tlsMode == 'tls') ? 'aes-128-gcm' : rawSecurity;

    final Map<String, dynamic> outbound = {
      "type": "vmess",
      "tag": "proxy",
      "server": server,
      "server_port": port,
      "uuid": uuid,
      "security": security,
    };

    if (tlsMode == 'tls') {
      outbound["tls"] = {
        "enabled": true,
        "server_name": sni,
        // та же маскировка отпечатка, что и для VLESS — иначе тихо режется
        "utls": {
          "enabled": true,
          "fingerprint": fp,
        },
        if (alpnRaw != null && alpnRaw.isNotEmpty) "alpn": alpnRaw.split(','),
      };
    }

    if (network == 'ws') {
      outbound["transport"] = {
        "type": "ws",
        "path": (data['path'] as String?) ?? '/',
        if ((data['host'] as String?)?.isNotEmpty == true)
          "headers": {"Host": data['host']},
      };
    } else if (network == 'grpc') {
      outbound["transport"] = {
        "type": "grpc",
        "service_name": (data['path'] as String?) ?? '',
      };
    }

    return ParsedServer(name: name, protocol: 'vmess', outbound: outbound);
  } catch (e) {
    return null;
  }
}

ParsedServer? parseTrojan(String line) {
  if (!line.startsWith('trojan://')) return null;

  try {
    final uri = Uri.parse(line);
    // пароль в userInfo приходит percent-encoded (например "=" как %3D) —
    // без decodeComponent sing-box получит невалидный пароль и молча отклонит подключение
    final password = Uri.decodeComponent(uri.userInfo);
    final server = uri.host;
    final port = uri.port;
    final params = uri.queryParameters;

    // трояновские ссылки обычно вообще не пишут security=tls явно —
    // протокол всегда поверх TLS, поэтому дефолт tls, а не none
    final security = params['security'] ?? 'tls';
    final sni = params['sni'] ?? server;
    final name = Uri.decodeComponent(uri.fragment.isNotEmpty ? uri.fragment : 'Trojan $server:$port');
    final netType = params['type'] ?? 'tcp';

    if (netType == 'xhttp') {
      final xrayOutbound = {
        "protocol": "trojan",
        "tag": "proxy",
        "settings": {
          "servers": [
            {"address": server, "port": port, "password": password}
          ],
        },
        "streamSettings": _buildXhttpStreamSettings(params, server),
      };
      return ParsedServer(name: name, protocol: 'trojan', outbound: xrayOutbound, engine: 'xray');
    }

    final Map<String, dynamic> outbound = {
      "type": "trojan",
      "tag": "proxy",
      "server": server,
      "server_port": port,
      "password": password,
    };

    if (security == 'tls' || security == 'reality') {
      final tls = <String, dynamic>{
        "enabled": true,
        "server_name": sni,
        "utls": {
          "enabled": true,
          "fingerprint": params['fp'] ?? 'chrome',
        },
      };

      final alpnParam = params['alpn'];
      if (alpnParam != null && alpnParam.isNotEmpty) {
        tls["alpn"] = alpnParam.split(',');
      }

      if (security == 'reality') {
        tls["reality"] = {
          "enabled": true,
          "public_key": params['pbk'],
          "short_id": params['sid'] ?? '',
        };
      }

      outbound["tls"] = tls;
    }

    if (netType == 'grpc') {
      outbound["transport"] = {
        "type": "grpc",
        "service_name": params['serviceName'] ?? '',
      };
    } else if (netType == 'ws') {
      outbound["transport"] = {
        "type": "ws",
        "path": params['path'] ?? '/',
      };
    }

    return ParsedServer(name: name, protocol: 'trojan', outbound: outbound);
  } catch (e) {
    return null;
  }
}

ParsedServer? parseHysteria2(String line) {
  if (!line.startsWith('hysteria2://') && !line.startsWith('hy2://')) return null;

  try {
    final uri = Uri.parse(line);
    final password = Uri.decodeComponent(uri.userInfo);
    final server = uri.host;
    final port = uri.port;
    final params = uri.queryParameters;

    final sni = params['sni'] ?? server;
    final name = Uri.decodeComponent(uri.fragment.isNotEmpty ? uri.fragment : 'Hysteria2 $server:$port');

    final Map<String, dynamic> outbound = {
      "type": "hysteria2",
      "tag": "proxy",
      "server": server,
      "server_port": port,
      "password": password,
      // hysteria2 всегда поверх TLS/QUIC — это не опция, а часть протокола
      "tls": {
        "enabled": true,
        "server_name": sni,
      },
    };

    final alpnParam = params['alpn'];
    if (alpnParam != null && alpnParam.isNotEmpty) {
      (outbound["tls"] as Map<String, dynamic>)["alpn"] = alpnParam.split(',');
    }

    final obfsType = params['obfs'];
    if (obfsType != null && obfsType.isNotEmpty) {
      outbound["obfs"] = {
        "type": obfsType,
        "password": params['obfs-password'] ?? '',
      };
    }

    return ParsedServer(name: name, protocol: 'hysteria2', outbound: outbound);
  } catch (e) {
    return null;
  }
}

class SubscriptionProfile {
  final String id;
  String name;
  String url;

  // Данные из заголовков ответа подписки. Панели отдают их почти всегда:
  // Subscription-Userinfo: upload=..; download=..; total=..; expire=..
  // total=0 означает безлимит, expire=0 — бессрочно. Поэтому «остаток» и
  // «срок» показываем только когда там ненулевые значения, а не рисуем
  // «осталось 0 Б» на безлимитном тарифе.
  int upload;
  int download;
  int total;
  int expire; // unix-время, 0 = бессрочно
  int updateIntervalHours; // Profile-Update-Interval, подсказка сервера
  int lastUpdated; // unix-время последнего успешного обновления

  SubscriptionProfile({
    required this.id,
    required this.name,
    required this.url,
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
    this.updateIntervalHours = 0,
    this.lastUpdated = 0,
  });

  bool get hasQuota => total > 0;
  bool get hasExpiry => expire > 0;
  int get used => upload + download;
  int get remaining => hasQuota ? (total - used).clamp(0, total) : 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire,
        'updateIntervalHours': updateIntervalHours,
        'lastUpdated': lastUpdated,
      };

  factory SubscriptionProfile.fromJson(Map<String, dynamic> json) => SubscriptionProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        upload: json['upload'] as int? ?? 0,
        download: json['download'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        expire: json['expire'] as int? ?? 0,
        updateIntervalHours: json['updateIntervalHours'] as int? ?? 0,
        lastUpdated: json['lastUpdated'] as int? ?? 0,
      );

  // "upload=123; download=456; total=0; expire=0" — порядок и набор полей
  // у разных панелей отличается, поэтому разбираем по именам, а не по позиции.
  void applyUserInfo(String? header) {
    if (header == null || header.isEmpty) return;
    for (final part in header.split(';')) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final value = int.tryParse(kv[1].trim());
      if (value == null) continue;
      switch (kv[0].trim().toLowerCase()) {
        case 'upload':
          upload = value;
        case 'download':
          download = value;
        case 'total':
          total = value;
        case 'expire':
          expire = value;
      }
    }
  }
}

// Тема живёт в ValueNotifier, а не в состоянии страницы: MaterialApp стоит выше
// CoreControlPage, и иначе переключение из настроек не дошло бы до него без
// перезапуска приложения.
const String windowBoundsPrefsKey = 'window_bounds';

final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.dark);
final ValueNotifier<Color> appAccent = ValueNotifier(const Color(0xFF7C4DFF));

// Палитра акцентов для выбора в настройках. Material 3 строит из одного
// «семени» всю схему, поэтому достаточно хранить один цвет.
const Map<int, String> accentPalette = {
  0xFF7C4DFF: 'color.violet',
  0xFF2196F3: 'color.blue',
  0xFF00BFA5: 'color.teal',
  0xFF43A047: 'color.green',
  0xFFF4511E: 'color.orange',
  0xFFE91E63: 'color.pink',
  0xFF607D8B: 'color.graphite',
};

ThemeMode themeModeFromName(String name) => switch (name) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Тройная подписка: тема, акцент и язык живут выше MaterialApp, иначе
    // переключение любого из них не дошло бы до экранов без перезапуска.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => ValueListenableBuilder<Color>(
        valueListenable: appAccent,
        builder: (context, seed, _) => ValueListenableBuilder<String>(
          valueListenable: appLang,
          builder: (context, _, _) => MaterialApp(
            title: t('app.title'),
            debugShowCheckedModeBanner: false,
            themeMode: mode,
            theme: _theme(seed, Brightness.light),
            darkTheme: _theme(seed, Brightness.dark),
            home: const _StartGate(),
          ),
        ),
      ),
    );
  }

  ThemeData _theme(Color seed, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Скруглённые карточки и кнопки вместо плоских прямоугольников —
      // основная разница между «формой на Flutter» и приложением.
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ),
    );
  }
}

/// Что показать при старте: мастер первого запуска или главный экран.
///
/// Отдельной прослойкой, а не проверкой внутри CoreControlPage: главный экран
/// в `initState` поднимает трей, читает профили, чинит системный прокси и
/// может сразу подключиться — на свежей установке всё это должно случиться
/// ПОСЛЕ того, как человек принял условия и завёл профиль, а не параллельно
/// с мастером.
class _StartGate extends StatefulWidget {
  const _StartGate();

  @override
  State<_StartGate> createState() => _StartGateState();
}

class _StartGateState extends State<_StartGate> {
  bool? _needOnboarding;

  // Мастер только что закрылся — значит, ссылку подписки вставили секунду
  // назад, прямо у нас на глазах. Подключаться в этот момент самим нельзя:
  // человек добавил профиль, а не просил поднять VPN, и молча уходить в
  // туннель сразу после ввода ссылки — решение за него. Со следующего
  // запуска автоподключение работает как обычно, по своей настройке.
  bool _cameFromOnboarding = false;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final prefs = await SharedPreferences.getInstance();
    // Язык поднимаем ДО показа мастера: обычно его читает CoreControlPage, но
    // до неё дело ещё не дошло, и мастер иначе открылся бы по-русски у того,
    // кто в прошлый раз выбрал английский.
    final raw = prefs.getString(kSettingsPrefsKey);
    if (raw != null) {
      try {
        final lang = (jsonDecode(raw) as Map<String, dynamic>)['language'];
        if (lang is String && languageNames.containsKey(lang)) {
          appLang.value = lang;
        }
      } catch (_) {
        // Битые настройки не должны мешать первому запуску.
      }
    }
    // Уже работающая установка мастер не видит. Признак — заведённый профиль
    // (в том числе по старой однопрофильной схеме): без этой поблажки после
    // обновления людям с настроенным приложением снова предложили бы принять
    // условия и вставить ссылку, которая у них давно вставлена.
    final done = prefs.getBool(kOnboardingPrefsKey) ??
        (prefs.getString(kProfilesPrefsKey) != null ||
            prefs.getString(kLegacySubscriptionUrlKey) != null);
    if (!mounted) return;
    setState(() => _needOnboarding = !done);
  }

  @override
  Widget build(BuildContext context) {
    if (_needOnboarding == null) {
      // Пустой экран, а не колесо: чтение SharedPreferences занимает
      // миллисекунды, и мелькнувший индикатор выглядит хуже, чем ничего.
      return const Scaffold(body: SizedBox.shrink());
    }
    if (_needOnboarding!) {
      return OnboardingScreen(
        onDone: () => setState(() {
          _needOnboarding = false;
          _cameFromOnboarding = true;
        }),
      );
    }
    return CoreControlPage(autoConnectOnStart: !_cameFromOnboarding);
  }
}

class CoreControlPage extends StatefulWidget {
  /// Разрешено ли автоподключение при этом открытии главного экрана.
  /// Ложь ровно в одном случае — экран открылся сразу после мастера первого
  /// запуска, см. `_StartGateState._cameFromOnboarding`. Настройку
  /// `autoConnectAfterLaunch` это не отменяет и не переписывает.
  final bool autoConnectOnStart;

  const CoreControlPage({super.key, this.autoConnectOnStart = true});

  @override
  State<CoreControlPage> createState() => _CoreControlPageState();
}

class _CoreControlPageState extends State<CoreControlPage> with WindowListener, TrayListener {
  List<SubscriptionProfile> _profiles = [];
  SubscriptionProfile? _activeProfile;
  final Map<String, List<ParsedServer>> _serverCache = {};

  List<ParsedServer> _servers = [];
  String _subStatus = "";
  ParsedServer? _selectedServer;

  // ключ — тег outbound'а сервера; отсутствие ключа значит "ещё не тестировали",
  // null значит "протестировали, недоступен"
  final Map<String, int?> _latencyMs = {};
  bool _testingLatency = false;

  Process? _coreProcess; // sing-box
  Process? _xrayProcess; // xray — обычный режим (не-TUN), единственный процесс на 1337
  // TUN-режим: у каждого xhttp-сервера СВОЙ постоянный мост на своём порту,
  // поднятый заранее и живущий весь сеанс TUN — переключение между ними тогда
  // чистый Clash API selector switch без убийства процессов (см. историю
  // с "connection refused"/"forcibly closed" при попытке шарить один порт).
  final Map<String, Process> _xrayBridgeProcesses = {};
  static const int _xrayBridgeBasePort = 1338;
  // 'singbox' | 'xray' | null — какое ядро сейчас реально держит порт 1337.
  //
  // Через сеттер, а не голым полем: опрос статистики обязан жить ровно столько,
  // сколько живёт ядро, и связывать их вручную в каждом месте присваивания —
  // способ однажды забыть. Уже забыли: на Android ядро поднимает служба, а
  // таймер заводился только в windows-ветке старта, и панель навсегда
  // оставалась с надписью «Нет данных» при рабочем туннеле. Теперь место
  // присваивания одно, и завести таймер мимо него нельзя.
  String? get _runningEngine => _runningEngineValue;
  set _runningEngine(String? value) {
    if (_runningEngineValue == value) return;
    _runningEngineValue = value;
    _rescheduleStats();
    _verifyConnection();
  }

  /// Что показала проверка соединения. Пусто — не проверяли.
  String _connectionCheck = '';

  /// Прошла ли последняя проверка. Нужно только для цвета подписи.
  bool _connectionOk = false;

  /// Проверяет, что через поднятое соединение действительно что-то ходит.
  ///
  /// «Подключено» до сих пор означало «ядро запустилось» — и только. Ядро
  /// стартует за сотые доли секунды даже к мёртвому серверу: щит зеленеет,
  /// а соединений ноль, скачано ноль, задержка «— мс». Человек при этом
  /// уверен, что защищён, и узнаёт правду от первого не открывшегося сайта.
  ///
  /// Запрос идёт СКВОЗЬ выбранный сервер (тем же путём, что и проверка связи),
  /// то есть проверяет не «порт открыт», а «наружу выходит».
  ///
  /// Результат только показывается. Переключать сервер самостоятельно здесь
  /// нельзя: человек нажал «Подключить» к КОНКРЕТНОМУ серверу, и подменять
  /// его выбор без спроса — ровно то поведение, на которое он уже жаловался.
  Future<void> _verifyConnection() async {
    if (_runningEngineValue == null) {
      if (mounted) setState(() => _connectionCheck = '');
      return;
    }
    if (mounted) {
      setState(() {
        _connectionCheck = t('check.running');
        _connectionOk = false;
      });
    }
    final ok = await _probeActiveServer();
    if (!mounted || _runningEngineValue == null) return;
    setState(() {
      _connectionOk = ok;
      _connectionCheck = ok ? t('check.ok') : t('check.failed');
    });
    _appendLog(ok ? t('check.ok') : t('check.failed'));
  }

  String? _runningEngineValue;

  /// Ядро живо и им можно управлять через Clash API.
  ///
  /// Раньше здесь везде стояло `_coreProcess != null`, и на Windows это верно.
  /// На Android дочернего процесса нет никогда — ядро вкомпилировано в
  /// приложение, — поэтому условие было ЛОЖНЫМ ВСЕГДА. Мгновенное
  /// переключение сервера через Clash API не срабатывало ни разу, и код
  /// уходил на полный перезапуск: поднимал туннель поверх уже работающего,
  /// тот упирался в занятые порты и умирал. Наружу это выглядело как
  /// «сменил сервер — и подключение пропало совсем».
  bool get _coreIsLive =>
      Env.coreRunsAsProcess ? _coreProcess != null : _runningEngine != null;
  String _log = "";
  String _statsText = "";
  Timer? _statsTimer;

  // Сколько опросов подряд не удались. Один промах — заминка (ядро только
  // стартовало и ещё не слушает), и писать о нём на экран значит показать
  // ошибку там, где через две секунды всё в порядке.
  int _statsFails = 0;

  /// Тест задержки просят прекратить.
  ///
  /// Нужен отмене подключения: с включённым автовыбором старт начинается с
  /// прогона по всем серверам, и на подписке из двух сотен это заметные
  /// секунды. Без этого флага «отмена» гасила бы только то, что после теста, а
  /// сам тест продолжал бы идти — со стороны кнопка выглядела бы сломанной.
  bool _cancelLatency = false;

  // TUN (системный VPN) вместо локального прокси на 1337. Требует прав
  // администратора — вместо elevation отдельного дочернего процесса (что
  // ломает kill()/логи и просит UAC дважды — на старт и на стоп) перезапускаем
  // само приложение целиком с повышенными правами, тогда дочерние sing-box/xray
  // наследуют elevation автоматически и весь остальной код не меняется.
  bool _tunMode = false;
  bool _isAdmin = false;
  static const String _tunModePrefsKey = 'tun_mode_requested';

  // Раздельное туннелирование. Применяется на этапе генерации конфига, поэтому
  // смена режима требует перезапуска ядра — на лету через Clash API правила
  // маршрутизации не подменить (в отличие от выбора сервера).
  // Дефолт — именно «РФ напрямую», а не «всё через VPN». Сценарий, ради
  // которого приложение существует: вставил ссылку подписки, нажал
  // «Запустить» и забыл. Российские сайты через зарубежный сервер работают
  // медленнее и часть из них просто отказывает зарубежным адресам, так что
  // «всё через VPN» дефолтом делает первое впечатление хуже, чем есть.
  RoutingMode _routingMode = RoutingMode.bypassRu;
  bool _blockAds = false;
  static const String _routingModePrefsKey = 'routing_mode';
  static const String _blockAdsPrefsKey = 'block_ads';
  static const String _autostartAskedPrefsKey = 'autostart_asked';

  AppSettings _settings = AppSettings();
  // Имена ключей — из prefs_keys.dart: их читает и пишет не только этот экран
  // (мастер первого запуска заводит профиль до того, как экран существует).
  // Короткие приватные псевдонимы оставлены, чтобы не править сотню обращений.
  static const String _settingsPrefsKey = kSettingsPrefsKey;
  Timer? _autoSelectTimer;
  Timer? _subUpdateTimer;
  // Проверка живости активного сервера: таймер, счётчик подряд идущих
  // провалов и список тех, кто проверку уже завалил. Список — по ИМЕНИ, как
  // и избранное: теги srv_N раздаются по порядку в подписке и после её
  // обновления могут указывать на другие серверы.
  Timer? _healthTimer;
  int _healthFails = 0;
  final Set<String> _unhealthy = {};
  // Взводится при нажатии «Остановить». Старт, начатый раньше, обязан
  // проверить его перед включением системного прокси — иначе включение
  // придёт уже после остановки и оставит систему с мёртвым прокси.
  bool _stopRequested = false;
  // Идёт запуск или остановка. Пока true, щит не принимает нажатия и
  // показывает индикатор: без этого старт с автовыбором выглядел как
  // «клик не сработал», и человек жал повторно, плодя параллельные запуски.
  bool _busy = false;
  // 0 — подключение (только щит), 1 — серверы и профили, 2 — маршрутизация.
  // Раньше всё это жило одной колонкой и на узком окне переливалось через край.
  int _tab = 0;

  // Избранное хранится по ИМЕНИ сервера, а не по тегу: теги вида srv_N
  // раздаются по порядку в подписке, и стоит провайдеру переставить серверы
  // местами — избранное уехало бы на чужие. Имена стабильны.
  Set<String> _favorites = {};
  static const String _favoritesPrefsKey = 'favorite_servers';
  String _serverSearch = '';
  String _serverSort = 'default'; // default | latency | name
  static const String _serverSortPrefsKey = 'server_sort';
  // Строка поиска намеренно НЕ сохраняется: это разовый фильтр «где тут
  // Trojan», и восстановить его при запуске значило бы показать человеку
  // урезанный список без видимой причины. Порядок сортировки — наоборот,
  // выбирается один раз и надолго.
  static const Set<String> _serverSortValues = {'default', 'latency', 'name'};

  Future<void> _setServerSort(String value) async {
    if (!_serverSortValues.contains(value)) return;
    setState(() => _serverSort = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverSortPrefsKey, value);
  }

  String get _clashApiBase => 'http://127.0.0.1:${_settings.clashApiPort}';
  static const String _profilesPrefsKey = kProfilesPrefsKey;
  static const String _activeProfilePrefsKey = kActiveProfilePrefsKey;

  @override
  void initState() {
    super.initState();
    try {
      // Прошлый лог сохраняем как app_log.prev.txt, а не затираем. Разбор
      // проблем выхода упирался ровно в это: приложение пишет в лог, ЧТО и
      // на каком шаге оно закрывает, но следующий же запуск стирал файл — и
      // от сеанса, который «завис при выходе», не оставалось ни строчки.
      final current = File(_logFilePath);
      if (current.existsSync()) {
        try {
          current.copySync('$_logFilePath.prev.txt');
        } catch (_) {}
      }
      current.writeAsStringSync(
        // Без перевода: файл создаётся в initState, а язык приезжает из
        // SharedPreferences позже — t() здесь всегда вернул бы русский.
        '=== Multik Sila :: ${DateTime.now().toIso8601String()} ===\n',
        mode: FileMode.write,
        flush: true,
      );
    } catch (_) {}
    // Окно, трей, реестр и подмена ядер — всё это настольное и на Android
    // не просто бесполезно, а падает: плагинов там нет, и вызов уходит в
    // MissingPluginException прямо на первом кадре.
    if (Env.hasWindowAndTray) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      // Отдаём установщику способ закрыть нас по-человечески: с остановкой
      // ядра, возвратом системного прокси и снятием TUN. Убить процесс он не
      // может — в TUN-режиме мы работаем от администратора, а он от
      // пользователя.
      appQuitHandler = _quitApp;
      _initTray();
    }
    if (Env.isAndroid) {
      // Служба туннеля живёт дольше экрана: её могли не остановить при
      // сворачивании, и при возврате в приложение состояние щита надо взять
      // у неё, а не гадать.
      _bindAndroidVpn();
    }
    _loadTunPreference();
    _loadProfiles();
    if (Env.needsSystemProxy) _recoverSystemProxyIfNeeded();
    if (Env.coresUpdateSeparately) _checkCoreUpdates();
    // Намеренно без await: обновление наборов правил не должно задерживать
    // ни показ окна, ни автоподключение. Результат ляжет рядом как <файл>.new
    // и применится при следующем старте ядра.
    _refreshRuleSetsInBackground();
    // Проверка обновления самого приложения. Без URL-фида не делает ничего
    // и в сеть не ходит; найдя новую версию, СПРАШИВАЕТ — перезапуск рвёт
    // соединение, молча такое делать нельзя.
    _checkAppUpdate();
    // Тоже без await и тоже с отложенным применением: качать 20 МБ на старте
    // и заставлять человека ждать этого ради подключения — ровно то, чего мы
    // избегали с наборами правил. На Android ядро вкомпилировано в APK и
    // обновляется вместе с приложением — качать нечего.
    if (Env.coresUpdateSeparately) _autoUpdateCores();
  }

  StreamSubscription<AndroidVpnStatus>? _androidVpnSub;

  /// Подписка на состояние андроидной службы туннеля.
  ///
  /// Служба переживает закрытие экрана, поэтому источник правды о том,
  /// поднят ли туннель, — она, а не наши поля. Без этого возврат в приложение
  /// показывал бы выключенный щит при работающем VPN — та же ложь, что на
  /// Windows однажды выдавал рассинхрон UI с реальностью.
  void _bindAndroidVpn() {
    _androidVpnSub = AndroidVpn.statusStream().listen((status) {
      if (!mounted) return;
      // Опрос статистики заводится и гасится сеттером `_runningEngine`.
      setState(() => _runningEngine = status.running ? 'singbox' : null);
      final error = status.error;
      if (error != null && error.isNotEmpty) _appendLog(error);
      _rescheduleHealthCheck();
    });
    AndroidVpn.isRunning().then((running) {
      if (mounted && running) {
        setState(() => _runningEngine = 'singbox');
      }
    });
  }

  /// Опрос Clash API под состояние ядра.
  ///
  /// На Windows таймер заводится прямо в `_startSingboxCore`/`_startXrayCore` —
  /// там момент старта ядра известен точно. На Android ядро поднимает служба, и
  /// «поднялось» приезжает отдельным событием ПОЗЖЕ возврата из `_startCore`.
  /// Таймер там не заводился вообще, и панель статистики навсегда оставалась с
  /// подписью «Нет данных» при полностью рабочем туннеле: цифры есть, спросить
  /// их некому.
  void _rescheduleStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _statsFails = 0;
    // У Xray нет Clash API вообще, спрашивать не у кого. Подпись об этом ставит
    // сам `_startXrayCore`, и затирать её ошибкой опроса — врать про поломку
    // там, где просто нечего опрашивать.
    if (_runningEngineValue == 'xray') return;
    if (_runningEngineValue != null) {
      _statsTimer =
          Timer.periodic(const Duration(seconds: 2), (_) => _fetchStats());
    }
    // Через микрозадачу, а не прямым вызовом: сеттер `_runningEngine` часто
    // стоит ВНУТРИ setState, а `_fetchStats` вызывает setState сам. Вложенный
    // setState — способ получить перестроение посреди перестроения. Задержка
    // тут исчезающая, а первый опрос всё равно происходит сразу, не дожидаясь
    // первого тика таймера: без него первые две секунды после подключения на
    // экране висело бы «Нет данных» при уже отвечающем ядре.
    Future.microtask(_fetchStats);
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('Multik Sila');
      await _refreshTrayMenu();
    } catch (e) {
      _appendLog(tp('log.trayFailed', {'e': e}));
    }
    // Меню строится в initState, когда язык ещё дефолтный: настройки
    // приезжают из SharedPreferences асинхронно и позже. Без этой подписки
    // трей навсегда оставался на языке, который был при старте — у
    // пользователя интерфейс стал английским, а меню трея так и осталось
    // русским. Пересобираем на каждое изменение языка, а не только при
    // смене состояния ядра.
    appLang.addListener(_refreshTrayMenu);
  }

  // Пункт «Подключить/Отключить» должен отражать текущее состояние, поэтому
  // меню пересобирается при каждом старте и остановке ядра.
  Future<void> _refreshTrayMenu() async {
    final running = _runningEngine != null;
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: t('tray.show')),
        MenuItem.separator(),
        MenuItem(
          key: running ? 'stop' : 'start',
          label: running ? t('tray.disconnect') : t('tray.connect'),
        ),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: t('tray.quit')),
      ]));
    } catch (_) {}
  }

  // Размер и положение окна сохраняем с задержкой: во время перетаскивания
  // события сыплются десятками в секунду, и писать на диск на каждое — лишнее.
  Timer? _boundsSaveTimer;

  void _scheduleBoundsSave() {
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      try {
        // Размер развёрнутого окна запоминать нельзя: иначе после одного
        // разворота приложение навсегда начинает открываться во весь экран.
        if (await windowManager.isMaximized()) return;
        final b = await windowManager.getBounds();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          windowBoundsPrefsKey,
          jsonEncode({'x': b.left, 'y': b.top, 'w': b.width, 'h': b.height}),
        );
      } catch (_) {}
    });
  }

  @override
  void onWindowResized() => _scheduleBoundsSave();

  @override
  void onWindowMoved() => _scheduleBoundsSave();

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show':
        _showWindow();
      case 'start':
        _startCore();
      case 'stop':
        _stopCore();
      case 'quit':
        _quitApp();
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // Крестик по умолчанию прячет в трей, а не выходит — иначе «включил и забыл»
  // не работает: пользователь закрывает окно и остаётся без VPN.
  @override
  void onWindowClose() async {
    if (_settings.closeToTray) {
      await windowManager.hide();
    } else {
      await _quitApp();
    }
  }

  Future<void> _quitApp() async {
    _appendLog(t('log.quitStarted'));
    // Окно убираем СРАЗУ, до всякой уборки. Раньше оно висело на экране всё
    // время остановки — а таймауты в сумме давали до 19 секунд, и это ровно
    // то, что пользователь описывал как «нажал Выход, приложение зависло».
    // Человек нажал «Выход»: для него приложение должно исчезнуть немедленно,
    // а ядро, мосты и реестр доводятся следом, уже без окна.
    try {
      await windowManager.hide().timeout(const Duration(milliseconds: 700));
    } catch (_) {}
    if (_settings.disconnectWhenQuit) {
      // Именно await: без него окно закрывается раньше, чем прокси вернётся,
      // и система остаётся указывать на мёртвый порт.
      //
      // Но НЕ бесконечно. Остановка трогает пять мостов, ядро и реестр, а под
      // TUN всё это ещё и elevated — пользователь видел «нажал Выход, окно
      // висит». Пять секунд хватает на честную остановку; если не уложились,
      // всё равно идём дальше: возврат прокси и закрытие окна важнее, чем
      // дождаться каждого процесса. Недобитые процессы всё равно снимет
      // следующий запуск (_killOurProcessesByPath).
      await _stopCore().timeout(
        const Duration(seconds: 3),
        onTimeout: () => _appendLog(t('log.stopTimeout')),
      );
    }
    // Даже если ядро не останавливаем — системный прокси вернуть обязаны,
    // иначе после выхода вся система останется указывать на мёртвый порт.
    await _restoreSystemProxy().timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () => _appendLog(t('log.stopTimeout')),
    );
    // Каждый шаг выхода пишем в файл: пользователь сообщал, что «выход через
    // трей подвешивает приложение», а по логу видно только то, что было до.
    // Теперь по последней строке сразу ясно, на каком шаге встало.
    _appendLog(t('log.quitClosing'));
    try {
      await trayManager.destroy().timeout(const Duration(seconds: 1));
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false).timeout(const Duration(seconds: 1));
      await windowManager.destroy().timeout(const Duration(seconds: 1));
    } catch (_) {}
    // Страховка. destroy() у window_manager на elevated-процессе иногда не
    // доводит дело до конца, и окно исчезает, а процесс остаётся висеть в
    // памяти — снаружи это и выглядит как «приложение зависло при выходе».
    // Пользователь нажал «Выход» явно, поэтому добить себя тут — правильно.
    await Future.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  Future<bool> _isElevated() async {
    try {
      final result = await Process.run('net', ['session'], runInShell: true);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadTunPreference() async {
    final admin = await _isElevated();
    final prefs = await SharedPreferences.getInstance();
    final requested = prefs.getBool(_tunModePrefsKey) ?? false;
    final savedRouting = prefs.getString(_routingModePrefsKey);
    final savedBlockAds = prefs.getBool(_blockAdsPrefsKey) ?? false;
    final rawSettings = prefs.getString(_settingsPrefsKey);
    final savedFavorites = prefs.getStringList(_favoritesPrefsKey) ?? [];
    // Значение сверяем со списком допустимых: DropdownButton падает утверждением,
    // если его value не совпадает ни с одним пунктом, а в настройках может
    // лежать что угодно — от старого имени режима до правки файла руками.
    final savedSort = prefs.getString(_serverSortPrefsKey);
    if (!mounted) return;
    setState(() {
      if (savedSort != null && _serverSortValues.contains(savedSort)) {
        _serverSort = savedSort;
      }
      _favorites = savedFavorites.toSet();
      if (rawSettings != null) {
        try {
          _settings = AppSettings.fromJson(jsonDecode(rawSettings) as Map<String, dynamic>);
          appThemeMode.value = themeModeFromName(_settings.themeMode);
          appAccent.value = Color(_settings.accentColor);
          appLang.value = _settings.language;
        } catch (_) {
          // Битые настройки не должны мешать приложению стартовать —
          // молча откатываемся на дефолты, они равны прежнему поведению.
        }
      }
      // orElse срабатывает и на свежей установке (сохранённого значения ещё
      // нет), поэтому здесь тот же дефолт, что и у поля, — иначе «РФ
      // напрямую» включался бы только со второго запуска.
      _routingMode = RoutingMode.values.firstWhere(
        (m) => m.name == savedRouting,
        orElse: () => RoutingMode.bypassRu,
      );
      _blockAds = savedBlockAds;
      _isAdmin = admin;
      // На Android туннель — единственный режим работы, и «включить TUN» там
      // не выбор пользователя, а устройство системы: VpnService и есть TUN.
      // Прав администратора он не требует, диалога о перезапуске тоже.
      _tunMode = Env.isAndroid ? true : (requested && admin);
    });
    _appendLog(tp('log.adminState', {'admin': admin, 'tun': _tunMode}));
  }

  // Elevation отдельного дочернего процесса ломает и kill(), и живые логи,
  // и требует второй UAC на остановку — вместо этого перезапускаем само
  // приложение целиком с правами администратора.
  Future<void> _restartElevated() async {
    final exePath = Platform.resolvedExecutable;
    // Отпускаем замок ДО запуска новой копии: иначе она упрётся в занятый
    // порт, решит, что приложение уже работает, и выйдет — а мы следом
    // закроемся сами, и на экране не останется ничего.
    await releaseSingleInstanceLock();
    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-Command', "Start-Process -FilePath '$exePath' -Verb RunAs"],
    );
    if (result.exitCode == 0) {
      exit(0);
    } else {
      _appendLog(t('log.elevationCancelled'));
    }
  }

  Future<void> _toggleTunMode(bool value) async {
    if (value && !_isAdmin) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('dlg.needAdmin')),
          content: Text(t('dlg.needAdminText')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('common.cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('dlg.restart'))),
          ],
        ),
      );
      if (confirmed != true) return;

      _appendLog(t('log.elevationRequested'));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_tunModePrefsKey, true);
      await _restartElevated();
      return;
    }

    setState(() => _tunMode = value);
    _appendLog(tp('log.tunMode', {'state': t(value ? 'log.on' : 'log.off')}));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_tunModePrefsKey, value);
  }

  Future<void> _toggleFavorite(String name) async {
    setState(() {
      if (!_favorites.remove(name)) _favorites.add(name);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favoritesPrefsKey, _favorites.toList());
  }

  // Список серверов для показа: поиск по имени, сортировка, избранное наверх.
  // Недоступные (задержка null после теста) всегда уезжают в конец — иначе при
  // сортировке по задержке они бы заняли первые места как "нулевые".
  /// Сколько серверов спрятано как недоступные. Для подписи под списком:
  /// молча исчезнувшие строки выглядят как потерянная подписка.
  int _hiddenUnavailable = 0;

  /// Сервер ПРОВЕРЕН и не работает.
  ///
  /// Не «нет задержки»: у непроверенного её тоже нет, и прятать его нельзя —
  /// про него просто ничего не известно. Прячем только те, по которым тест
  /// отработал и вернул пусто.
  ///
  /// Что именно проверяет тест, тут важно: в режиме `proxy` он идёт СКВОЗЬ
  /// сервер до проверочного адреса, то есть ловит не только «порт не
  /// отвечает», но и «сервер жив, а наружу через него не выходит» — ровно тот
  /// случай, ради которого это и заведено.
  bool _isKnownDead(ParsedServer s) {
    final tag = s.outbound['tag'];
    return _latencyMs.containsKey(tag) && _latencyMs[tag] == null;
  }

  List<ParsedServer> _visibleServers() {
    final query = _serverSearch.trim().toLowerCase();
    var list = query.isEmpty
        ? List<ParsedServer>.from(_servers)
        : _servers.where((s) => s.name.toLowerCase().contains(query)).toList();

    _hiddenUnavailable = 0;
    if (_settings.hideUnavailable) {
      final alive = list.where((s) => !_isKnownDead(s)).toList();
      // Если живых не осталось ни одного — показываем всё.
      //
      // Причина такого обвала почти всегда общая (пропал интернет, отвалилась
      // подписка), а не «все серверы разом умерли». Пустой список в этот момент
      // — худшее, что можно показать: выбрать нечего, а понять почему нельзя.
      // Всегда оставляем видимым и текущий сервер: человек смотрит на экран,
      // где написано, что подключён именно к нему.
      if (alive.isNotEmpty) {
        _hiddenUnavailable = list.length - alive.length;
        list = alive;
        final selected = _selectedServer;
        if (selected != null &&
            _isKnownDead(selected) &&
            !list.contains(selected) &&
            (query.isEmpty || selected.name.toLowerCase().contains(query))) {
          list.insert(0, selected);
          _hiddenUnavailable--;
        }
      }
    }

    int byLatency(ParsedServer a, ParsedServer b) {
      final x = _latencyMs[a.outbound['tag']];
      final y = _latencyMs[b.outbound['tag']];
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return x.compareTo(y);
    }

    switch (_serverSort) {
      case 'latency':
        list.sort(byLatency);
      case 'name':
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    final favorites = list.where((s) => _favorites.contains(s.name)).toList();
    final rest = list.where((s) => !_favorites.contains(s.name)).toList();
    return [...favorites, ...rest];
  }

  String _routingModeLabel(RoutingMode mode) => switch (mode) {
        RoutingMode.global => t('routing.global'),
        RoutingMode.bypassRu => t('routing.bypassRu'),
      };

  // Правила маршрутизации запекаются в конфиг ядра при старте, через Clash API
  // их не подменить (в отличие от выбора сервера) — поэтому если ядро уже
  // работает, честно говорим, что нужен перезапуск, а не молчим.
  String get _restartHint => _runningEngine != null ? t('log.restartHint') : '';

  Future<void> _setRoutingMode(RoutingMode mode) async {
    setState(() => _routingMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_routingModePrefsKey, mode.name);
    _appendLog(tp('log.routingMode',
        {'mode': _routingModeLabel(mode), 'hint': _restartHint}));
  }

  Future<void> _saveSettings(AppSettings s) async {
    final autostartChanged = s.launchAtStartup != _settings.launchAtStartup;
    setState(() => _settings = s);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsPrefsKey, jsonEncode(s.toJson()));
    if (autostartChanged) await _applyLaunchAtStartup(s.launchAtStartup);
    appThemeMode.value = themeModeFromName(s.themeMode);
    appAccent.value = Color(s.accentColor);
    appLang.value = s.language;
    _rescheduleAutoSelect();
    _rescheduleSubscriptionUpdate();
    _rescheduleHealthCheck();
    _appendLog(tp('log.settingsSaved', {'hint': _restartHint}));
  }

  // Автозапуск — запись в пользовательскую ветку реестра (HKCU), не
  // системную: не требует прав администратора и касается только этого
  // пользователя. Путь в кавычках — иначе пробелы в пути ломают команду.
  static const String _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _runValue = 'MultikSila';

  // --- Системный прокси Windows ---
  //
  // Без этого обычный (не-TUN) режим бесполезен: ядро слушает 127.0.0.1, но
  // ни Windows, ни браузер, ни Telegram про этот адрес не знают, и трафик идёт
  // мимо туннеля. Именно поэтому «IP поменялся, а сайт не открывается».
  //
  // Предыдущее значение обязательно запоминаем и возвращаем при остановке:
  // если оставить ProxyEnable=1 с нашим мёртвым портом, у пользователя
  // отвалится интернет во всех приложениях — и чинить он это будет
  // перезагрузкой, не понимая причины.
  static const String _inetKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  // Резерв держим в SharedPreferences, а не в памяти. Память умирает вместе с
  // процессом: при падении или снятии через Диспетчер задач восстановление не
  // отрабатывало, прежние значения терялись, и система оставалась с
  // ProxyEnable=1 на наш мёртвый порт — весь интернет ложился во всех
  // программах сразу. Пользователь чинил это перезагрузкой (после неё v2rayN
  // при старте прописывает прокси на себя), не понимая причины.
  static const String _proxyBackupPrefsKey = 'system_proxy_backup';

  Future<String?> _regRead(String key, String value) async {
    try {
      final r = await Process.run('reg', ['query', key, '/v', value]);
      if (r.exitCode != 0) return null;
      final match = RegExp(r'REG_\w+\s+(\S.*)$', multiLine: true).firstMatch(r.stdout as String);
      return match?.group(1)?.trim();
    } catch (_) {
      return null;
    }
  }

  // Плоские значения реестра — зеркало для «Параметров сети» и для тех
  // программ, что читают их напрямую. ДЕЙСТВУЮЩУЮ конфигурацию Windows держит
  // не здесь, а в бинарном блобе `Connections\DefaultConnectionSettings`, и
  // пишется она только через WinINET (см. system_proxy.dart) — поэтому одной
  // записи в реестр мало, но и без неё нельзя: иначе окно системных настроек
  // показывает пользователю не то, что происходит на самом деле.
  //
  // Пустое значение УДАЛЯЕМ, а не пропускаем. Пропуск (как было раньше)
  // оставлял наш `127.0.0.1:<порт>` в системе навсегда у тех, у кого своего
  // прокси не было: стоило потом чему угодно выставить ProxyEnable=1 — и
  // интернет ложился во всех программах разом, на мёртвый порт.
  Future<void> _writeProxyRegistry({
    required bool enable,
    required String server,
    required String bypass,
    required String pac,
  }) async {
    Future<void> put(String value, String data) => data.isEmpty
        ? Process.run('reg', ['delete', _inetKey, '/v', value, '/f'])
        : Process.run('reg',
            ['add', _inetKey, '/v', value, '/t', 'REG_SZ', '/d', data, '/f']);
    await put('ProxyServer', server);
    await put('ProxyOverride', bypass);
    await put('AutoConfigURL', pac);
    // Код возврата проверяем только у этого ключа — он решающий, и его отказ
    // означает, что процессу вообще не дают писать в свою ветку реестра
    // (так бывает, когда приложение запущено из ограниченного окружения).
    // Молчаливый провал тут стоил целого раунда отладки.
    final r = await Process.run('reg', [
      'add', _inetKey, '/v', 'ProxyEnable', '/t', 'REG_DWORD',
      '/d', enable ? '1' : '0', '/f',
    ]);
    if (r.exitCode != 0) {
      _appendLog(tp('log.sysProxyOnFailed',
          {'e': tp('log.regWriteFailed', {'code': r.exitCode, 'err': r.stderr})}));
    }
  }

  Future<void> _enableSystemProxy() async {
    if (!_settings.autoSetSystemProxy || _tunMode) return;
    // Пока мы сюда шли, пользователь мог нажать «Остановить» — включать
    // прокси задним числом нельзя, это и оставляло систему с мёртвым портом.
    if (_stopRequested || _runningEngine == null) return;
    final prefs = await SharedPreferences.getInstance();
    // Если резерв уже лежит — значит прокси наш ещё с прошлого раза, и
    // перезаписывать резерв нельзя: затрём настоящие значения пользователя.
    if (prefs.getString(_proxyBackupPrefsKey) == null) {
      await prefs.setString(
        _proxyBackupPrefsKey,
        jsonEncode({
          'enable': await _regRead(_inetKey, 'ProxyEnable') ?? '0x0',
          'server': await _regRead(_inetKey, 'ProxyServer') ?? '',
          // Список исключений тоже принадлежит пользователю (у него он от
          // v2rayN) — вернуть обязаны и его, иначе после нас локальная сеть
          // останется настроенной по-нашему.
          'override': await _regRead(_inetKey, 'ProxyOverride') ?? '',
          // PAC-скрипт имеет приоритет над фиксированным адресом прокси:
          // пока он стоит, наш адрес не действует вообще. Мы его снимаем —
          // и обязаны вернуть, иначе тихо сломаем корпоративную сеть.
          'pac': await _regRead(_inetKey, 'AutoConfigURL') ?? '',
        }),
      );
    }
    try {
      final server = '127.0.0.1:${_settings.localPort}';
      final bypass = _settings.proxyBypassList.trim();
      await _writeProxyRegistry(
          enable: true, server: server, bypass: bypass, pac: '');
      // Вот это и есть настоящее включение. Без него ядро работало, лог писал
      // «системный прокси включён», а на порт не приходило ни одного
      // соединения: Windows продолжала считать подключение прямым.
      final applied = WinInetProxy.enable(server, bypass);
      // Читаем обратно и сверяем. «Вызов вернул успех» и «система реально
      // переключилась» — разные утверждения, и расхождение между ними уже
      // стоило дня отладки: в логе стояло «прокси включён», а Windows
      // оставалась на прямом подключении.
      final actual = WinInetProxy.current();
      if (applied && actual != null && actual.proxyOn && actual.server == server) {
        _appendLog(tp('log.sysProxyOn', {'port': _settings.localPort}));
        if (WinInetProxy.bypassDropped) _appendLog(t('log.sysProxyBypassDropped'));
      } else if (applied) {
        // Вызов прошёл, а система осталась при своём. Пишем, НА ЧЁМ именно
        // она осталась: без этой цифры отказ выглядит беспричинным, а с ней
        // сразу видно, чужой ли там прокси или прямое подключение.
        _appendLog(tp('log.sysProxyOnFailed', {
          'e': tp('log.sysProxyMismatch', {
            'state': actual == null
                ? t('log.sysProxyUnreadable')
                : (actual.proxyOn ? actual.server : t('log.sysProxyDirect')),
          }),
        }));
      } else {
        _appendLog(tp('log.sysProxyOnFailed', {
          'e': tp('log.sysProxySetFailed', {'code': WinInetProxy.lastError}),
        }));
      }
    } catch (e) {
      _appendLog(tp('log.sysProxyOnFailed', {'e': e}));
    }
  }

  Future<void> _restoreSystemProxy() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_proxyBackupPrefsKey);
    if (raw == null) return;
    try {
      final backup = jsonDecode(raw) as Map<String, dynamic>;
      // reg query отдаёт 0x0/0x1.
      final enabled =
          (backup['enable'] as String? ?? '0x0').toLowerCase().endsWith('1');
      final server = backup['server'] as String? ?? '';
      final override = backup['override'] as String? ?? '';
      final pac = backup['pac'] as String? ?? '';
      await _writeProxyRegistry(
          enable: enabled, server: server, bypass: override, pac: pac);
      final applied = WinInetProxy.restore(
        enabled: enabled,
        server: server,
        bypass: override,
        autoConfigUrl: pac,
      );
      if (!applied) {
        _appendLog(tp('log.sysProxyRestoreFailed',
            {'e': tp('log.sysProxySetFailed', {'code': WinInetProxy.lastError})}));
      } else {
        _appendLog(t('log.sysProxyRestored'));
        // Прокси мы сняли, но часть чужих настроек вернуть не смогли. Молчать
        // об этом нельзя: человек должен знать, что его список исключений или
        // PAC придётся восстановить руками, а не искать потом, почему в
        // локальной сети что-то ходит не туда.
        if (WinInetProxy.restoreDegraded) {
          _appendLog(t('log.sysProxyRestoreDegraded'));
        }
      }
    } catch (e) {
      _appendLog(tp('log.sysProxyRestoreFailed', {'e': e}));
    } finally {
      // Резерв снимаем только после попытки восстановления — иначе при сбое
      // потеряем настоящие значения пользователя безвозвратно.
      await prefs.remove(_proxyBackupPrefsKey);
    }
  }

  // Вызывается при старте. Если резерв на месте — прошлый сеанс завершился
  // ненормально (падение, снятие через Диспетчер задач, выключение питания),
  // и в системе остался наш прокси. Возвращаем всё как было, не дожидаясь,
  // пока пользователь пойдёт перезагружать компьютер.
  Future<void> _recoverSystemProxyIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_proxyBackupPrefsKey) == null) return;
    _appendLog(t('log.sysProxyRecovering'));
    await _restoreSystemProxy();
  }

  // --- Обновление ядер ---
  //
  // Только ПРОВЕРКА и уведомление, без автоматической подмены файлов.
  // Причины, по которым молча качать и подменять .exe нельзя:
  //  1) Windows не даёт перезаписать работающий файл — надо сначала
  //     остановить ядро, то есть оборвать пользователю соединение;
  //  2) наша сборка Xray (26.7.28) НОВЕЕ последнего опубликованного релиза
  //     (v26.3.27), и наивное сравнение предложило бы «обновиться» назад;
  //  3) `sing-box version` отвечает "unknown" — сравнивать не с чем вообще,
  //     поэтому для него запоминаем тег, а не разбираем версию из бинарника.
  static const String _coreTagPrefsKey = 'known_core_tags';

  Future<String?> _latestTag(String repo) async {
    try {
      final r = await http
          .get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      return (jsonDecode(r.body) as Map<String, dynamic>)['tag_name'] as String?;
    } catch (_) {
      return null;
    }
  }

  // Версия УСТАНОВЛЕННОГО ядра — спрашиваем сам бинарь, а не помним тег.
  // Причина конкретная: у пользователя стоял Xray 26.7.28, а GitHub на
  // /releases/latest отдаёт последний СТАБИЛЬНЫЙ — 26.3.27, потому что все
  // свежие релизы Xray помечены pre-release. Обновление «по отличию тега»
  // откатило бы рабочее ядро назад.
  // sing-box может ответить «version unknown» (так собран бинарь, который
  // лежал у нас изначально) — тогда возвращаем null и НЕ трогаем ядро
  // автоматически: сравнивать не с чем.
  Future<String?> _installedCoreVersion(String exePath) async {
    try {
      if (!await File(exePath).exists()) return null;
      final r = await Process.run(exePath, ['version']).timeout(const Duration(seconds: 10));
      final out = '${r.stdout}';
      // Строго после имени ядра. Просто «первое число вида x.y.z» брать
      // НЕЛЬЗЯ: старый sing-box печатает «sing-box version unknown», а следом
      // «Environment: go1.26.5» — и наивный поиск вернул бы версию Go,
      // выдав неизвестную версию ядра за известную.
      final m = RegExp(r'(?:sing-box version|Xray)\s+(\d+\.\d+\.\d+)').firstMatch(out);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  // Сравнение версий по числам, а не строкой: «26.7.28» строкой меньше
  // «26.3.27» ровно до первой различающейся цифры, и лексикографика тут врёт.
  int _compareVersions(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < math.max(pa.length, pb.length); i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  // Качает релиз, достаёт из архива один нужный .exe и кладёт рядом как
  // <файл>.new. Подменять работающий бинарь на ходу нельзя, поэтому замена
  // отложена до следующего старта приложения — тот же приём, что с наборами
  // правил. Возвращает true, если обновление подготовлено.
  Future<bool> _stageCoreUpdate({
    required String repo,
    required String exePath,
    required bool Function(String assetName) pickAsset,
    required String exeInArchive,
  }) async {
    try {
      final r = await http
          .get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return false;
      final release = jsonDecode(r.body) as Map<String, dynamic>;
      final tag = (release['tag_name'] as String?)?.replaceAll(RegExp(r'^v'), '');
      if (tag == null) return false;

      final installed = await _installedCoreVersion(exePath);
      // Версия не читается — молча не трогаем: возможен откат на более старое.
      if (installed == null) return false;
      if (_compareVersions(tag, installed) <= 0) return false;

      final assets = (release['assets'] as List?) ?? [];
      final asset = assets.cast<Map<String, dynamic>>().firstWhere(
            (a) => pickAsset('${a['name']}'),
            orElse: () => <String, dynamic>{},
          );
      final url = asset['browser_download_url'] as String?;
      if (url == null) return false;

      _appendLog(tp('log.coreDownloading', {'core': repo, 'tag': tag}));
      final zip = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 5));
      if (zip.statusCode != 200 || zip.bodyBytes.length < 1024 * 1024) return false;

      final archive = ZipDecoder().decodeBytes(zip.bodyBytes);
      final entry = archive.files.firstWhere(
        (f) => f.isFile && f.name.split('/').last.toLowerCase() == exeInArchive,
        orElse: () => ArchiveFile('', 0, <int>[]),
      );
      if (entry.name.isEmpty) return false;

      final staged = File('$exePath.new');
      await staged.writeAsBytes(entry.readBytes() ?? <int>[], flush: true);

      // Скачанный файл ОБЯЗАН запуститься и назвать свою версию. Битую или
      // не ту сборку лучше выбросить сейчас, чем обнаружить её тем, что
      // приложение перестало подключаться.
      final check = await _installedCoreVersion(staged.path);
      if (check == null || _compareVersions(check, installed) <= 0) {
        await staged.delete();
        _appendLog(tp('log.coreUpdateBad', {'core': repo}));
        return false;
      }

      // Мало того, что бинарь запускается — он обязан принять НАШ конфиг.
      // Реальный случай: sing-box 1.13.16 стартует и называет версию, но
      // конфиг без `route.default_domain_resolver` отвергает намертво
      // (в 1.12 это был депрекейт, дальше стало фатальным). Без этой
      // проверки автообновление тихо заменило бы рабочее ядро на такое,
      // с которым приложение перестаёт подключаться.
      final cfg = File(_configPath);
      if (await cfg.exists()) {
        try {
          final verdict = await Process.run(staged.path, ['check', '-c', _configPath])
              .timeout(const Duration(seconds: 30));
          if (verdict.exitCode != 0) {
            await staged.delete();
            _appendLog(tp('log.coreRejectsConfig', {'core': repo, 'tag': check}));
            return false;
          }
        } catch (_) {
          await staged.delete();
          _appendLog(tp('log.coreRejectsConfig', {'core': repo, 'tag': check}));
          return false;
        }
      }
      _appendLog(tp('log.coreStaged', {'core': repo, 'tag': check}));
      return true;
    } catch (e) {
      _appendLog(tp('log.coreUpdateFailed', {'core': repo, 'e': e}));
      return false;
    }
  }

  // Подмена скачанных ядер. Строго при остановленном ядре и до автоподключения:
  // работающий .exe Windows заменить не даст, да и рвать живое соединение
  // ради обновления незачем.
  Future<void> _applyPendingCores() async {
    if (_runningEngine != null) return;
    for (final exePath in [_singBoxPath, _xrayPath]) {
      final staged = File('$exePath.new');
      try {
        if (!await staged.exists() || await staged.length() < 1024 * 1024) continue;
        await staged.copy(exePath);
        await staged.delete();
        _appendLog(tp('log.coreUpdated', {
          'core': exePath.split(Platform.pathSeparator).last,
          'tag': await _installedCoreVersion(exePath) ?? '?',
        }));
      } catch (e) {
        _appendLog(tp('log.coreUpdateFailed', {'core': exePath, 'e': e}));
      }
    }
  }

  // --- Самообновление приложения ---
  //
  // Заменить работающий .exe Windows не даст, а Flutter-сборка это не один
  // файл, а папка (exe + dll + data). Поэтому схема такая: скачиваем zip,
  // распаковываем РЯДОМ в update_staging, а подменяет папку внешний .bat уже
  // после выхода приложения — он же и запускает новую версию. Тот же принцип,
  // что с ядрами (<файл>.new), только применение вынесено наружу.
  String get _stagingDir => '$_workDir${Platform.pathSeparator}update_staging';

  /// Забирает манифест и возвращает (версия, ссылка на zip), если там что-то
  /// новее установленного.
  ///
  /// Понимает ДВА формата, и различает их по содержимому ответа, а не по
  /// адресу — чтобы человек мог подставить свой хостинг, не меняя код:
  ///
  ///  * свой манифест: `{"version": "1.0.1", "url": "https://.../app.zip"}`
  ///  * ответ GitHub `/releases/latest` — там версия лежит в `tag_name`
  ///    (с ведущей `v`), а ссылка на файл — в списке `assets`.
  ///
  /// Из ассетов берётся ZIP, а НЕ установщик: механизм применения обновления
  /// распаковывает папку рядом и подменяет её батником после выхода
  /// приложения (см. _stageAppUpdate / _applyAppUpdateAndRestart). Запускать
  /// установщик из работающего приложения нельзя — он первым делом попросит
  /// это самое приложение закрыться.
  Future<(String, String)?> _fetchAppUpdate() async {
    final feed = _settings.updateFeedUrl.trim();
    if (feed.isEmpty) return null;
    try {
      final r = await http.get(
        Uri.parse(feed),
        // GitHub без Accept отдаёт HTML-страницу вместо JSON.
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;

      String version;
      String url;
      if (j['tag_name'] != null) {
        version = '${j['tag_name']}'.trim();
        if (version.startsWith('v')) version = version.substring(1);
        final assets = (j['assets'] as List?) ?? const [];
        final zip = assets.cast<Map<String, dynamic>>().where((a) {
          final name = '${a['name'] ?? ''}'.toLowerCase();
          return name.endsWith('.zip');
        }).toList();
        if (zip.isEmpty) return null;
        url = '${zip.first['browser_download_url'] ?? ''}'.trim();
      } else {
        version = '${j['version'] ?? ''}'.trim();
        url = '${j['url'] ?? ''}'.trim();
      }

      if (version.isEmpty || url.isEmpty) return null;
      if (_compareVersions(version, kAppVersion) <= 0) return null;
      return (version, url);
    } catch (_) {
      return null;
    }
  }

  /// Качает и распаковывает обновление в update_staging. Ничего не заменяет.
  Future<bool> _stageAppUpdate(String version, String url) async {
    try {
      _appendLog(tp('log.appDownloading', {'v': version}));
      final zip = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 10));
      if (zip.statusCode != 200 || zip.bodyBytes.length < 1024 * 1024) return false;

      final staging = Directory(_stagingDir);
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);

      final archive = ZipDecoder().decodeBytes(zip.bodyBytes);
      // Архив может быть как «файлы в корне», так и «одна папка внутри».
      // Определяем общий префикс, иначе распакуется лишний уровень вложенности
      // и .bat скопирует папку внутрь папки.
      final names = archive.files.where((f) => f.isFile).map((f) => f.name).toList();
      if (names.isEmpty) return false;
      var prefix = '';
      final first = names.first.split('/');
      if (first.length > 1 && names.every((n) => n.startsWith('${first.first}/'))) {
        prefix = '${first.first}/';
      }

      for (final f in archive.files) {
        if (!f.isFile) continue;
        final rel = f.name.substring(prefix.length);
        if (rel.isEmpty) continue;
        final out = File('$_stagingDir${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(f.readBytes() ?? <int>[], flush: true);
      }

      // Без нашего .exe это не сборка приложения — что бы там ни лежало.
      final exeName = File(Platform.resolvedExecutable).uri.pathSegments.last;
      if (!await File('$_stagingDir${Platform.pathSeparator}$exeName').exists()) {
        await staging.delete(recursive: true);
        _appendLog(t('log.appUpdateBad'));
        return false;
      }
      _appendLog(tp('log.appStaged', {'v': version}));
      return true;
    } catch (e) {
      _appendLog(tp('log.appUpdateFailed', {'e': e}));
      return false;
    }
  }

  /// Пишет .bat, который дожидается выхода приложения, делает копию текущей
  /// сборки, накатывает новую и запускает её. Затем выходит из приложения.
  Future<void> _applyAppUpdateAndRestart() async {
    final exe = Platform.resolvedExecutable;
    final batPath = '$_workDir${Platform.pathSeparator}apply_update.bat';
    // Резерв — РЯДОМ с папкой приложения, а не внутри неё: копировать папку в
    // собственную подпапку значит просить xcopy о цикле, на котором он
    // останавливается с «Cannot perform a cyclic copy», и до подмены дело уже
    // не доходит. Записывается относительным путём от `%~dp0`, чтобы в тексте
    // скрипта не появилось ни одного не-ASCII символа (см. ниже).
    const backupName = r'%APP%..\MultikSila_backup';
    // pid — из dart:io, идентификатор текущего процесса: .bat должен ждать
    // именно нас, а не любой процесс с тем же именем.
    final ownPid = pid;

    // ТЕЛО СКРИПТА — ТОЛЬКО ASCII. Все пути приходят аргументами.
    //
    // Это не вкусовщина, а единственная причина, по которой обновление
    // вообще работает. Раньше пути подставлялись в текст .bat, файл писался
    // в UTF-8, и у пользователя с кириллицей в имени папки профиля
    // (`C:\Users\<Имя Фамилия>\...`) cmd разъезжался по смещениям: он читает
    // .bat побайтово в кодировке консоли, а каждая кириллическая буква в
    // UTF-8 занимает два байта. После этого разбор шёл с середины слова.
    // Симптом, снятый на стенде дословно:
    //
    //   'ut' is not recognized as an internal or external command
    //
    // — это распиленное пополам `timeout`. Наружу выходило так: обновление
    // скачано и распаковано, приложение честно закрылось «для установки», а
    // подмена не произошла: update_staging остался лежать, версия прежняя,
    // приложение не вернулось. Аргументы же приходят из командной строки,
    // которую Windows передаёт в Unicode, и никакой перекодировки не требуют.
    //
    // `ping` вместо `timeout`: у отсоединённого процесса нет консольного
    // ввода, а `timeout` в этом случае отказывается работать вовсе
    // («Input redirection is not supported»).
    //
    // Резерв кладётся ВНЕ папки приложения. Копировать папку в собственную
    // подпапку — цикл, xcopy на нём останавливается с «Cannot perform a
    // cyclic copy», и до самой подмены дело уже не доходило.
    // Пути скрипт берёт от СВОЕГО расположения (`%~dp0`), а не получает
    // текстом и не получает аргументами.
    //
    // Аргументы — вторая ловушка, проверенная на стенде: `cmd /c` разбирает
    // хвост команды по своим правилам, и путь с пробелом («Multik Sila»)
    // разваливается пополам:
    //
    //   "C:\Users\Абилова " не является внутренней или внешней командой
    //
    // `%~dp0` берётся из того, что cmd и так знает о запущенном файле, минуя
    // и разбор кавычек, и перекодировку. Единственное, что осталось внутри
    // текста, — номер процесса и имя .exe: и то и другое ASCII по определению
    // (имя исполняемого файла менять нельзя, см. CLAUDE.md). Комментариев
    // внутри скрипта нет и быть не должно по той же причине: `rem` по-русски
    // возвращает в файл ровно те байты, из-за которых всё и ломалось.
    //
    // ТОЧКА в конце пути назначения (`"%APP%."`) тоже обязательна: `%~dp0`
    // кончается обратной косой, а в записи `"%APP%"` эта косая экранирует
    // закрывающую кавычку — аргумент разъезжается, и xcopy молча ничего не
    // копирует. Стенд показывал это так: скрипт доходит до конца, резерв
    // создан, staging удалён, а версия прежняя.
    final exeName = File(exe).uri.pathSegments.last;
    final bat = '''
@echo off
:wait
tasklist /FI "PID eq $ownPid" 2>nul | find "$ownPid" >nul
if not errorlevel 1 (
  ping -n 2 127.0.0.1 >nul
  goto wait
)
set "APP=%~dp0"
if not exist "$backupName" mkdir "$backupName"
xcopy "%APP%*" "$backupName\\." /E /Y /I /Q >nul
xcopy "%APP%update_staging\\*" "%APP%." /E /Y /I /Q >nul
rmdir /S /Q "%APP%update_staging"
start "" "%APP%$exeName"
del "%~f0"
''';
    await File(batPath).writeAsString(bat, flush: true);
    _appendLog(t('log.appApplying'));
    await Process.start('cmd', ['/c', batPath],
        mode: ProcessStartMode.detached);
    await _quitApp();
  }

  /// Полный цикл: проверить, скачать, применить. silent=false — с ответом
  /// пользователю даже когда обновлений нет (вызывается кнопкой).
  Future<void> _checkAppUpdate({bool silent = true}) async {
    if (silent && !_settings.autoUpdateApp) return;
    final found = await _fetchAppUpdate();
    if (found == null) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t(_settings.updateFeedUrl.trim().isEmpty
              ? 'app.noFeed'
              : 'app.upToDate'))),
        );
      }
      return;
    }
    final (version, url) = found;
    if (!mounted) return;
    // Обновление приложения перезапускает его и рвёт соединение, поэтому
    // молча этого не делаем НИКОГДА — только с явного согласия.
    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('app.updateTitle')),
        content: Text(tp('app.updateText', {'v': version, 'cur': kAppVersion})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t('common.cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t('app.updateNow'))),
        ],
      ),
    );
    if (agreed != true) return;
    if (await _stageAppUpdate(version, url)) {
      await _applyAppUpdateAndRestart();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('log.appUpdateBad'))),
      );
    }
  }

  // Фоновая подготовка обновлений обоих ядер.
  Future<void> _autoUpdateCores() async {
    if (!_settings.autoUpdateCores) return;
    await _stageCoreUpdate(
      repo: 'SagerNet/sing-box',
      exePath: _singBoxPath,
      // Строго amd64 и НЕ legacy: в релизе рядом лежат 386, arm64 и сборка
      // для Windows 7, и любая из них подошла бы под наивную проверку
      // «имя содержит windows».
      pickAsset: (n) => n.endsWith('-windows-amd64.zip') && !n.contains('legacy'),
      exeInArchive: 'sing-box.exe',
    );
    await _stageCoreUpdate(
      repo: 'XTLS/Xray-core',
      exePath: _xrayPath,
      pickAsset: (n) => n == 'Xray-windows-64.zip',
      exeInArchive: 'xray.exe',
    );
  }

  Future<void> _checkCoreUpdates({bool silent = true}) async {
    if (!_settings.checkCoreUpdates && silent) return;
    final prefs = await SharedPreferences.getInstance();
    final known = <String, dynamic>{};
    try {
      known.addAll(jsonDecode(prefs.getString(_coreTagPrefsKey) ?? '{}') as Map<String, dynamic>);
    } catch (_) {}

    final found = <String>[];
    for (final entry in const {
      'Xray-core': 'XTLS/Xray-core',
      'sing-box': 'SagerNet/sing-box',
    }.entries) {
      final tag = await _latestTag(entry.value);
      if (tag == null) continue;
      final seen = known[entry.key] as String?;
      if (seen == null) {
        // Первый запуск: просто запоминаем текущий тег, чтобы не сообщать
        // об «обновлении», которого пользователь не пропускал.
        known[entry.key] = tag;
      } else if (seen != tag) {
        known[entry.key] = tag;
        found.add('${entry.key} $tag');
      } else if (!silent) {
        _appendLog(tp('log.coreUpToDate', {'core': entry.key, 'tag': tag}));
      }
    }
    await prefs.setString(_coreTagPrefsKey, jsonEncode(known));

    if (found.isNotEmpty) {
      // Текст зависит от того, дойдут ли руки у автообновления. Оно пропускает
      // ядро, версию которого не удаётся прочитать (сравнивать не с чем), и
      // обещать в этом случае «обновится само» — значит соврать: человек будет
      // ждать, а ничего не произойдёт.
      final canAuto = _settings.autoUpdateCores &&
          await _installedCoreVersion(_singBoxPath) != null &&
          await _installedCoreVersion(_xrayPath) != null;
      _appendLog(tp(canAuto ? 'log.coreUpdatesAuto' : 'log.coreUpdates',
          {'list': found.join(', ')}));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tp('core.updateAvailable', {'list': found.join(', ')})),
          duration: const Duration(seconds: 8),
        ));
      }
    } else if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('core.upToDate'))),
      );
    }
  }

  Future<void> _applyLaunchAtStartup(bool enabled) async {
    try {
      final result = enabled
          ? await Process.run('reg', [
              'add', _runKey, '/v', _runValue, '/t', 'REG_SZ',
              '/d', '"${Platform.resolvedExecutable}"', '/f',
            ])
          : await Process.run('reg', ['delete', _runKey, '/v', _runValue, '/f']);
      if (result.exitCode == 0) {
        _appendLog(tp('log.autostart', {'state': t(enabled ? 'log.on' : 'log.off')}));
      } else {
        _appendLog(tp('log.autostartFailed', {'e': result.stderr}));
      }
    } catch (e) {
      _appendLog(tp('log.autostartFailed', {'e': e}));
    }
  }

  // Автозапуск с системой спрашиваем ОДИН раз и только когда есть что
  // запускать: пустое приложение без подписки в автозапуске бесполезно, а
  // вопрос при самом первом старте задаётся раньше, чем человек понял, чем
  // вообще пользуется. Молча прописываться в реестр не хочется: это
  // изменение системы, и антивирусы к незаявленным записям в Run
  // относятся настороженно.
  Future<void> _maybeAskAutostart() async {
    // На Android спрашивать нечего: автозапуск здесь — запись в реестр
    // Windows, которого нет. Диалог «Запускать вместе с Windows?» на телефоне
    // выглядел ровно так, как читается, — вопросом не про эту систему.
    // Андроидный автозапуск (приёмник BOOT_COMPLETED) — отдельная задача,
    // и до неё дело ещё не дошло.
    if (!Env.hasWindowAndTray) return;
    if (!mounted || _servers.isEmpty || _settings.launchAtStartup) return;
    // Окно спрятано в трей — диалога никто не увидит. Флаг «уже спрашивали»
    // при этом НЕ ставим: спросим при следующем видимом запуске.
    if (_settings.hideAfterLaunch) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_autostartAskedPrefsKey) == true) return;
    if (!mounted) return;

    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('dlg.autostartTitle')),
        content: Text(t('dlg.autostartText')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('dlg.autostartNo'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('dlg.autostartYes'))),
        ],
      ),
    );
    // Флаг ставим ТОЛЬКО после реального ответа. Если приложение закрыли или
    // сняли с висящим диалогом, вопрос не считается заданным и повторится —
    // иначе один прерванный запуск навсегда лишает человека автозапуска.
    if (agreed == null) return;
    await prefs.setBool(_autostartAskedPrefsKey, true);
    if (!agreed) return;
    await _saveSettings(AppSettings.fromJson(
      _settings.toJson()..['launchAtStartup'] = true,
    ));
  }

  // Применяется один раз при старте: спрятать окно и/или сразу подключиться.
  Future<void> _applyLaunchBehaviour() async {
    if (_settings.hideAfterLaunch) {
      await windowManager.hide();
    }
    if (!widget.autoConnectOnStart) {
      // Пишем в лог, а не молчим: иначе человек, у которого автоподключение
      // включено, увидит на первом запуске выключенный щит и решит, что
      // настройка не работает.
      if (_settings.autoConnectAfterLaunch && _servers.isNotEmpty) {
        _appendLog(t('log.noAutoConnectAfterOnboarding'));
      }
    } else if (_settings.autoConnectAfterLaunch &&
        _servers.isNotEmpty &&
        _runningEngine == null) {
      _appendLog(t('log.autoConnect'));
      await _startCore();
    }
    // Строго после подключения: диалог ждёт ответа человека, и держать
    // из-за него поднятие VPN нельзя.
    await _maybeAskAutostart();
  }

  Future<void> _setBlockAds(bool value) async {
    setState(() => _blockAds = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_blockAdsPrefsKey, value);
    _appendLog(tp('log.blockAds',
        {'state': t(value ? 'log.onF' : 'log.offF'), 'hint': _restartHint}));
  }

  Future<void> _loadProfiles() async {
    // Скачанные в прошлый раз ядра подменяем ЗДЕСЬ: ядро ещё не запущено
    // (автоподключение живёт в _applyLaunchBehaviour, в самом конце этой
    // функции), а работающий .exe Windows заменить не даст.
    await _applyPendingCores();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilesPrefsKey);
    List<SubscriptionProfile> profiles;

    if (raw != null) {
      final list = jsonDecode(raw) as List;
      profiles = list.map((e) => SubscriptionProfile.fromJson(e as Map<String, dynamic>)).toList();
    } else {
      // миграция со старой однопрофильной схемы хранения (один subscription_url)
      final oldUrl = prefs.getString('subscription_url');
      profiles = oldUrl != null && oldUrl.isNotEmpty
          ? [SubscriptionProfile(id: 'default', name: '${t('sub.profile')} 1', url: oldUrl)]
          : [];
    }

    final activeId = prefs.getString(_activeProfilePrefsKey);
    SubscriptionProfile? active;
    if (profiles.isNotEmpty) {
      active = profiles.firstWhere((p) => p.id == activeId, orElse: () => profiles.first);
    }

    setState(() {
      _profiles = profiles;
      _activeProfile = active;
      if (active == null) _subStatus = t('profile.addNone');
    });

    if (raw == null && profiles.isNotEmpty) {
      await _saveProfiles();
    }
    if (active != null) {
      await _loadSubscription(active);
    }
    // Только после того, как подписка разобрана и список серверов заполнен —
    // иначе автоподключению нечего было бы запускать.
    await _applyLaunchBehaviour();
    _rescheduleAutoSelect();
    _rescheduleSubscriptionUpdate();
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profilesPrefsKey, jsonEncode(_profiles.map((p) => p.toJson()).toList()));
    if (_activeProfile != null) {
      await prefs.setString(_activeProfilePrefsKey, _activeProfile!.id);
    }
  }

  Future<void> _loadSubscription(SubscriptionProfile profile) async {
    setState(() => _subStatus = "${t('sub.loading')} \"${profile.name}\"...");

    // Локальный профиль: содержимое лежит файлом рядом с .exe, сети не нужно.
    // Заголовков с квотой у него нет по определению — просто читаем и парсим.
    if (profile.url.startsWith('file:')) {
      try {
        final content = await File(Uri.parse(profile.url).toFilePath()).readAsString();
        _applySubscriptionContent(profile, content);
      } catch (e) {
        if (_activeProfile?.id == profile.id) {
          setState(() => _subStatus = '${t('sub.readFail')}: $e');
        }
      }
      return;
    }

    // Проверяем, что это вообще адрес, ДО запроса.
    //
    // Иначе `http.get` падает с дартовым «Invalid argument(s): No host
    // specified in URI», и эта строка уезжает человеку на экран как есть. Она
    // не врёт, но и не помогает: по ней не понять, что в профиль попала не
    // ссылка, а, например, её обрывок или просто набранное имя. Проверяем и
    // схему, и наличие хоста — `Uri.parse('test1')` разбирается без единой
    // жалобы, просто оба поля выходят пустыми.
    final uri = Uri.tryParse(profile.url.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      if (_activeProfile?.id == profile.id) {
        setState(() => _subStatus = t('sub.notAUrl'));
      }
      return;
    }

    try {
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        if (_activeProfile?.id == profile.id) {
          setState(() => _subStatus = "${t('sub.httpError')} ${resp.statusCode}");
        }
        return;
      }

      // Заголовки с квотой и сроком панели отдают в разном регистре —
      // http-пакет приводит их к нижнему, но подстрахуемся поиском по обоим.
      profile.applyUserInfo(
          resp.headers['subscription-userinfo'] ?? resp.headers['Subscription-Userinfo']);
      final intervalHeader =
          resp.headers['profile-update-interval'] ?? resp.headers['Profile-Update-Interval'];
      final interval = int.tryParse(intervalHeader?.trim() ?? '');
      if (interval != null && interval > 0) profile.updateIntervalHours = interval;
      profile.lastUpdated = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _saveProfiles();

      _applySubscriptionContent(profile, resp.body);
    } catch (e) {
      if (_activeProfile?.id == profile.id) {
        setState(() => _subStatus = "${t('sub.error')}: $e");
      }
    }
  }

  // Разбор содержимого подписки — общий для сетевой загрузки и локального файла.
  void _applySubscriptionContent(SubscriptionProfile profile, String raw) {
    String decoded;
    try {
      decoded = utf8.decode(base64.decode(raw.trim()));
    } catch (_) {
      decoded = raw;
    }

    final lines = decoded
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final parsed = <ParsedServer>[];
    int skipped = 0;
    for (final line in lines) {
      final server = parseVless(line) ?? parseVmess(line) ?? parseTrojan(line) ?? parseHysteria2(line);
      if (server != null) {
        server.link = line;
        parsed.add(server);
      } else {
        skipped++;
      }
    }

    // уникальный тег на сервер: нужен, чтобы грузить все серверы профиля
    // в sing-box разом (через selector) и тестировать/переключать их
    // по отдельности через Clash API, не перезапуская ядро
    for (var i = 0; i < parsed.length; i++) {
      parsed[i].outbound['tag'] = 'srv_$i';
    }

    _serverCache[profile.id] = parsed;

    // пока грузилась подписка, юзер мог переключиться на другой профиль —
    // тогда этот результат больше не актуален для текущего экрана
    if (_activeProfile?.id != profile.id) return;

    // теги переехали на новый список — старые мосты (если были подняты)
    // указывают на серверы, которых по этим тегам больше нет
    _stopAllXrayBridges();
    setState(() {
      _servers = parsed;
      _selectedServer = parsed.isNotEmpty ? parsed.first : null;
      _latencyMs.clear();
      _subStatus = "${t('sub.parsed')}: ${parsed.length} (VLESS+VMess+Trojan+Hysteria2) — ${t('sub.skipped')}: $skipped";
    });
  }

  Future<void> _switchProfile(SubscriptionProfile profile) async {
    _stopAllXrayBridges();
    setState(() => _activeProfile = profile);
    await _saveProfiles();

    final cached = _serverCache[profile.id];
    if (cached != null) {
      setState(() {
        _servers = cached;
        _selectedServer = cached.isNotEmpty ? cached.first : null;
        _latencyMs.clear();
        _subStatus = '${t('sub.profile')} "${profile.name}": '
            '${t('sub.cached')} — ${cached.length}';
      });
    } else {
      setState(() {
        _servers = [];
        _selectedServer = null;
        _latencyMs.clear();
      });
      await _loadSubscription(profile);
    }
  }

  // Профиль без ссылки (импортированный из файла или вставленный текстом)
  // хранит содержимое рядом с .exe, а в url кладёт путь со схемой file:.
  // Так весь остальной код — загрузка, обновление, переключение — работает
  // с ним ровно как с обычной подпиской, без отдельной ветки.
  String _localProfilePath(String id) => '$_workDir${Platform.pathSeparator}profile_$id.txt';

  /// Имя, которого ещё нет среди профилей. Занятое дополняется номером:
  /// «Профиль 1» -> «Профиль 1 (2)».
  ///
  /// Одинаковые имена ломают ровно то, ради чего профили и заведены —
  /// понять, какой из них сейчас активен. В выпадающем списке два «Профиль 1»
  /// неразличимы, а переключение между ними выглядит как «ничего не
  /// произошло». Внутри всё живёт по `id`, так что технически дубли
  /// работали, — тем неприятнее, что путался только человек.
  ///
  /// Сравнение без учёта регистра: «профиль 1» и «Профиль 1» человек читает
  /// как одно и то же имя.
  ///
  /// `exceptId` — профиль, который сейчас переименовывают: собственное имя
  /// не должно считаться занятым, иначе правка «Дом» -> «Дом» превратила бы
  /// его в «Дом (2)».
  ///
  /// Дополняем номером, а не отказываем: имя приезжает и из QR-кода, и из
  /// файла, где показать ошибку негде и человек остался бы без профиля
  /// вообще.
  String _uniqueProfileName(String desired, {String? exceptId}) {
    // Имя по умолчанию считается от длины списка, поэтому после удаления
    // профиля оно само по себе может оказаться занятым — этот случай тоже
    // проходит через проверку ниже.
    final base = desired.trim().isEmpty
        ? '${t('sub.profile')} ${_profiles.length + 1}'
        : desired.trim();
    final taken = _profiles
        .where((p) => p.id != exceptId)
        .map((p) => p.name.trim().toLowerCase())
        .toSet();
    if (!taken.contains(base.toLowerCase())) return base;
    for (var n = 2;; n++) {
      final candidate = '$base ($n)';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  // Профиль по обычной ссылке подписки. Вынесено из диалога, потому что
  // тем же путём заводится профиль из QR-кода.
  /// Имя профиля по его содержимому.
  ///
  /// Для ссылки берём АДРЕС САЙТА, а не первые символы строки: любая подписка
  /// начинается с `https`, и по такому имени профили не отличить друг от друга
  /// вообще — а именно ради различения имя и нужно. Из адреса выбрасываем
  /// `www.` и служебные поддомены вроде `sub.`: `sub.example.com` -> `example`.
  ///
  /// Для всего остального (вставили сами ссылки серверов) — первые символы,
  /// потому что осмысленного имени там просто нет.
  ///
  /// Имя в любом случае предложение, а не приговор: поле в диалоге открыто на
  /// правку, а занятость проверит `_uniqueProfileName`.
  String _suggestProfileName(String content) {
    final trimmed = content.trim();
    final firstLine = trimmed.split('\n').first.trim();
    final uri = Uri.tryParse(firstLine);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      var host = uri.host.toLowerCase();
      for (final prefix in const ['www.', 'sub.', 'subscribe.', 'api.']) {
        if (host.startsWith(prefix)) host = host.substring(prefix.length);
      }
      // У голого адреса резать нечего: `1.2.3.4` по первой точке превращается
      // в «1». Проверено прогоном — на этом и попались.
      final isIpLiteral =
          RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host) || host.contains(':');
      if (isIpLiteral) return host;
      // Домен верхнего уровня в имени не нужен: `example.com` и `example.net`
      // от одной панели человек всё равно назовёт по-своему, а лишний хвост
      // только удлиняет строку в списке.
      final label = host.split('.').first;
      if (label.isNotEmpty) return label;
    }
    final compact = trimmed.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return t('dlg.pastedProfile');
    return compact.substring(0, compact.length < 5 ? compact.length : 5);
  }

  /// Заводит профиль по тому, ЧТО именно принесли: ссылку подписки или сами
  /// серверы.
  ///
  /// Одно место на все три способа ввода — вставка из буфера, QR-картинка,
  /// сканирование камерой. Раньше различал только QR, а вставка из буфера
  /// всегда звала `_createLocalProfile`: вставленная туда ссылка подписки
  /// ложилась на диск как «содержимое профиля», парсер честно не находил в ней
  /// ни одного сервера, и на экране появлялось нечто, не имеющее отношения к
  /// подписке. Пункт при этом называется «Импорт из буфера обмена» — то есть
  /// ровно то, что человек в него и вставляет.
  ///
  /// Ссылкой считаем содержимое из ОДНОЙ строки со схемой http(s). Список
  /// серверов — тоже строки со схемами (`vless://`, `vmess://`), поэтому
  /// проверять надо и схему, и то, что строка одна.
  Future<void> _createProfileFromContent(String name, String content) async {
    final trimmed = content.trim();
    final singleLine = !trimmed.contains('\n') && !trimmed.contains(RegExp(r'\s'));
    if (singleLine &&
        (trimmed.startsWith('http://') || trimmed.startsWith('https://'))) {
      await _createProfileFromUrl(name, trimmed);
      return;
    }
    await _createLocalProfile(name, content);
  }

  Future<void> _createProfileFromUrl(String name, String url) async {
    final unique = _uniqueProfileName(name);
    final profile = SubscriptionProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: unique,
      url: url,
    );
    setState(() {
      _profiles.add(profile);
      _activeProfile = profile;
      _servers = [];
      _selectedServer = null;
      _latencyMs.clear();
    });
    await _saveProfiles();
    _appendLog(tp('log.profileImported', {'name': unique}));
    await _loadSubscription(profile);
  }

  Future<void> _createLocalProfile(String name, String content) async {
    if (content.trim().isEmpty) {
      _appendLog(t('log.importEmpty'));
      return;
    }
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final path = _localProfilePath(id);
    await File(path).writeAsString(content, flush: true);
    final unique = _uniqueProfileName(name);
    final profile = SubscriptionProfile(id: id, name: unique, url: Uri.file(path).toString());
    setState(() {
      _profiles.add(profile);
      _activeProfile = profile;
    });
    await _saveProfiles();
    _appendLog(tp('log.profileImported', {'name': unique}));
    await _loadSubscription(profile);
  }

  // Резервная копия: настройки, профили и избранное одним файлом.
  // Ссылки подписок внутри — по сути секрет, поэтому предупреждаем об этом
  // прямо в интерфейсе, а не прячем мелким шрифтом.
  Future<void> _exportBackup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final backup = {
        'version': 1,
        'created': DateTime.now().toIso8601String(),
        'settings': _settings.toJson(),
        'profiles': _profiles.map((p) => p.toJson()).toList(),
        'activeProfileId': _activeProfile?.id,
        'favorites': _favorites.toList(),
        'routingMode': _routingMode.name,
        'blockAds': _blockAds,
        'tunRequested': prefs.getBool(_tunModePrefsKey) ?? false,
      };
      final location = await getSaveLocation(
        suggestedName: 'multik-sila-backup.json',
        acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])],
      );
      if (location == null) return;
      await File(location.path)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(backup), flush: true);
      _appendLog(tp('log.backupSaved', {'path': location.path}));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('backup.saved'))),
        );
      }
    } catch (e) {
      _appendLog(tp('log.backupFailed', {'e': e}));
    }
  }

  Future<void> _importBackup() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])],
      );
      if (file == null) return;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // Между выбором файла и диалогом был await — экран мог уже закрыться.
      if (!mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('dlg.restoreTitle')),
          content: Text('${data['created'] ?? ''}\n\n${t('dlg.restoreText')}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('common.cancel'))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('dlg.restore'))),
          ],
        ),
      );
      if (confirmed != true) return;

      final prefs = await SharedPreferences.getInstance();
      if (data['settings'] is Map) {
        final restored = AppSettings.fromJson((data['settings'] as Map).cast<String, dynamic>());
        await prefs.setString(_settingsPrefsKey, jsonEncode(restored.toJson()));
        setState(() => _settings = restored);
        appThemeMode.value = themeModeFromName(restored.themeMode);
        appAccent.value = Color(restored.accentColor);
      }
      if (data['profiles'] is List) {
        final list = (data['profiles'] as List)
            .map((e) => SubscriptionProfile.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
        setState(() {
          _profiles = list;
          _activeProfile = list.isEmpty
              ? null
              : list.firstWhere((p) => p.id == data['activeProfileId'], orElse: () => list.first);
        });
        await _saveProfiles();
      }
      if (data['favorites'] is List) {
        setState(() => _favorites = (data['favorites'] as List).cast<String>().toSet());
        await prefs.setStringList(_favoritesPrefsKey, _favorites.toList());
      }
      if (data['routingMode'] is String) {
        final mode = RoutingMode.values.firstWhere(
          (m) => m.name == data['routingMode'],
          orElse: () => RoutingMode.global,
        );
        setState(() => _routingMode = mode);
        await prefs.setString(_routingModePrefsKey, mode.name);
      }
      if (data['blockAds'] is bool) {
        setState(() => _blockAds = data['blockAds'] as bool);
        await prefs.setBool(_blockAdsPrefsKey, _blockAds);
      }

      _appendLog(t('log.backupRestored'));
      if (_activeProfile != null) await _loadSubscription(_activeProfile!);
    } catch (e) {
      _appendLog(tp('log.backupRestoreFailed', {'e': e}));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tp('backup.badFile', {'e': e}))),
        );
      }
    }
  }

  void _showAddProfileScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddProfileScreen(
          onLink: () => _showProfileDialog(),
          onFile: _importProfileFromFile,
          onText: _importProfileFromText,
          onQr: () => _importProfileFromQr(),
          // Пункта «сканировать» на рабочем столе нет вовсе, а не выключенный:
          // строка, которая никогда не нажмётся, только занимает место и
          // заставляет гадать, чего не хватает системе.
          onScan: Env.hasCameraScanner
              ? () => _importProfileFromQr(camera: true)
              : null,
          onExport: _exportBackup,
          onImport: _importBackup,
        ),
      ),
    );
  }

  Future<void> _importProfileFromFile() async {
    try {
      final file = await openFile(acceptedTypeGroups: [
        XTypeGroup(
          label: t('dlg.fileConfigs'),
          extensions: const ['txt', 'yaml', 'yml', 'json', 'conf'],
        ),
        XTypeGroup(label: t('dlg.fileAll'), extensions: const []),
      ]);
      if (file == null) return;
      final content = await file.readAsString();
      final name = file.name.replaceAll(RegExp(r'\.[^.]+$'), '');
      await _createLocalProfile(name.isEmpty ? t('dlg.importName') : name, content);
    } catch (e) {
      _appendLog(tp('log.fileImportFailed', {'e': e}));
    }
  }

  // Импорт из QR-кода: камерой (телефон) или из картинки (везде).
  // Разбор — в `qr_import.dart`: тем же кодом пользуется мастер первого
  // запуска, и две копии успели бы разойтись раньше, чем это кто-нибудь
  // заметил.
  Future<void> _importProfileFromQr({bool camera = false}) async {
    try {
      final text = camera
          ? await QrImport.scanWithCamera(context)
          : await QrImport.pickAndDecode();
      // null — экран сканера или выбор файла закрыли, говорить нечего.
      if (text == null) return;
      if (text.isEmpty) {
        _appendLog(t('log.qrNotFound'));
        return;
      }
      _appendLog(tp('log.qrDecoded', {'n': text.length}));
      // В QR может лежать и ссылка на подписку, и сами ссылки серверов —
      // разбирается с этим `_createProfileFromContent`, общий для всех
      // способов ввода.
      await _createProfileFromContent(t('qr.importedName'), text);
    } catch (e) {
      // NotFoundException от zxing2 при отсутствии кода — самый частый случай,
      // отдельного сообщения он не заслуживает, но и молчать нельзя.
      _appendLog(tp('log.qrFailed', {'e': e}));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('log.qrNotFound'))),
        );
      }
    }
  }

  Future<void> _importProfileFromText() async {
    final nameController = TextEditingController();
    final contentController = TextEditingController();
    // Пункт называется «Импорт из буфера обмена», значит буфер надо прочитать,
    // а не просить вставить руками. Молча подставляем содержимое: поле остаётся
    // редактируемым, и если там оказалось не то, человек это видит до нажатия
    // «Добавить», а не после.
    var suggestedName = t('dlg.pastedProfile');
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clip?.text?.trim() ?? '';
      if (text.isNotEmpty) {
        contentController.text = text;
        suggestedName = _suggestProfileName(text);
      }
    } catch (_) {
      // Буфер недоступен — поле просто останется пустым. Ронять из-за этого
      // импорт нельзя: вставить руками по-прежнему можно.
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('dlg.pasteContent')),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Предложенное имя стоит ПОДСКАЗКОЙ, а не текстом в поле.
              //
              // Текстом оно заставляет сначала стереть чужое и только потом
              // писать своё — на каждый профиль лишнее действие, и первое, что
              // человек делает, открыв диалог, это уборка за приложением.
              // Подсказка решает обе задачи разом: поле пустое, печатать можно
              // сразу, а если ничего не напечатали — берётся предложенное.
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: t('dlg.name'),
                  hintText: suggestedName,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(
                  labelText: t('dlg.pasteHint'),
                  hintText: 'vless://...\nvmess://...\ntrojan://...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('common.cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('common.add'))),
        ],
      ),
    );
    if (ok == true) {
      // Пустое поле — значит человек согласился с подсказкой, а не оставил
      // профиль без имени.
      final typed = nameController.text.trim();
      await _createProfileFromContent(
          typed.isEmpty ? suggestedName : typed, contentController.text);
    }
  }

  /// Кнопки «Тест задержки» и «Авто-выбор».
  ///
  /// Идущий тест останавливается ТОЙ ЖЕ кнопкой. Раньше она на время прогона
  /// просто гасла: на подписке в две сотни серверов это больше минуты без
  /// выхода — оставалось ждать конца того, что уже не нужно. Кнопка, которая
  /// умеет начать, но не прекратить, — не защита от повторного нажатия, а
  /// отсутствие выхода.
  Widget _serverActionButtons() => Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _servers.isEmpty
                  ? null
                  : (_testingLatency ? _cancelLatencyTest : _testAllLatencies),
              icon: Icon(_testingLatency ? Icons.stop : Icons.speed, size: 18),
              label: Text(
                  _testingLatency ? t('servers.testStop') : t('servers.test')),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed:
                  _servers.isEmpty || _testingLatency ? null : _autoSelectBest,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(t('servers.auto')),
            ),
          ),
        ],
      );

  /// Окно выбора профиля. Ничего не меняет, если выбрали тот же самый.
  Future<void> _chooseProfile() async {
    final picked = await showDialog<SubscriptionProfile>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t('profile.choose')),
        children: _profiles.map((p) {
          final active = p.id == _activeProfile?.id;
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, p),
            child: Row(
              children: [
                Icon(active ? Icons.radio_button_checked : Icons.radio_button_off,
                    size: 18,
                    color: active ? Theme.of(ctx).colorScheme.primary : null),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(p.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.normal)),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
    if (picked != null && picked.id != _activeProfile?.id) {
      await _switchProfile(picked);
    }
  }

  Future<void> _showProfileDialog({SubscriptionProfile? editing}) async {
    final nameController = TextEditingController(text: editing?.name ?? '');
    final urlController = TextEditingController(text: editing?.url ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(editing == null ? t('dlg.newProfile') : t('profile.edit')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(labelText: t('dlg.name')),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlController,
              decoration: InputDecoration(labelText: t('dlg.subUrl')),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('common.cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('common.save'))),
        ],
      ),
    );

    if (saved != true || urlController.text.trim().isEmpty) return;

    var url = urlController.text.trim();
    // Ссылку без схемы дополняем сами.
    //
    // Панели дают адрес и в виде `sub.example.com/link/abc`, и такую строку
    // человек вставляет ровно так же. Без схемы `Uri.parse` разбирает её как
    // путь, хост выходит пустым, и профиль заводится заведомо нерабочим.
    // Дополнять до `https://`, а не до `http://`: подписки живут по TLS, а
    // ошибиться в эту сторону безопаснее.
    if (!url.contains('://') && !url.startsWith('file:')) {
      url = 'https://$url';
    }
    // Пустое поле отдаём помощнику как есть: имя по умолчанию он строит сам
    // и там же проверяет, не занято ли оно.
    final name = _uniqueProfileName(nameController.text, exceptId: editing?.id);

    if (editing != null) {
      setState(() {
        editing.name = name;
        editing.url = url;
      });
      _serverCache.remove(editing.id);
      await _saveProfiles();
      if (_activeProfile?.id == editing.id) {
        await _loadSubscription(editing);
      }
    } else {
      final profile = SubscriptionProfile(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        url: url,
      );
      setState(() {
        _profiles.add(profile);
        _activeProfile = profile;
        _servers = [];
        _selectedServer = null;
        _latencyMs.clear();
      });
      await _saveProfiles();
      await _loadSubscription(profile);
    }
  }

  Future<void> _deleteActiveProfile() async {
    final profile = _activeProfile;
    if (profile == null) return;

    _stopAllXrayBridges();
    setState(() {
      _profiles.removeWhere((p) => p.id == profile.id);
      _serverCache.remove(profile.id);
      _activeProfile = _profiles.isNotEmpty ? _profiles.first : null;
      _servers = _activeProfile != null ? (_serverCache[_activeProfile!.id] ?? []) : [];
      _selectedServer = _servers.isNotEmpty ? _servers.first : null;
      _latencyMs.clear();
      if (_activeProfile == null) _subStatus = t('profile.addNone');
    });
    await _saveProfiles();

    if (_activeProfile != null && _serverCache[_activeProfile!.id] == null) {
      await _loadSubscription(_activeProfile!);
    }
  }

  // Рабочий каталог процесса не гарантированно совпадает с папкой .exe
  // (например, при запуске не из папки проекта) — поэтому и sing-box.exe,
  // и config.json резолвим относительно реального пути исполняемого файла.
  /// Папка, где лежат САМИ ядра. Только чтение — их кладёт установщик.
  String get _appDir => File(Platform.resolvedExecutable).parent.path;

  /// Папка для РАБОЧИХ файлов: конфиги ядра, лог, наборы правил, мосты.
  ///
  /// Раньше всё это писалось рядом с .exe, и после установки в Program Files
  /// приложение молча переставало работать: без прав администратора туда
  /// писать нельзя, config.json не создавался, ядро не стартовало вовсе.
  /// Симптом со стороны: «включаю — Not protected, ничего не происходит»,
  /// причём в TUN-режиме всё работало (там процесс уже elevated).
  ///
  /// Поэтому: если рядом с .exe писать можно (портативный запуск, сборка из
  /// исходников) — работаем там, как раньше. Если нельзя — уходим в
  /// %APPDATA%\Multik Sila, куда права есть всегда.
  static String? _workDirCache;
  String get _workDir {
    // На Android каталог узнаётся у системы, а спросить её можно только
    // асинхронно — поэтому значение кладётся сюда ещё в main(), до первого
    // кадра. Геттер остаётся синхронным: он вызывается из десятков мест, и
    // делать его Future значило бы переписать половину файла ради одной
    // платформы.
    final resolved = Env.workDirOverride;
    if (resolved != null) return resolved;
    final cached = _workDirCache;
    if (cached != null) return cached;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    try {
      final probe = File('$exeDir${Platform.pathSeparator}.write_test');
      probe.writeAsStringSync('x', flush: true);
      probe.deleteSync();
      _workDirCache = exeDir;
      return exeDir;
    } catch (_) {
      final appData = Platform.environment['APPDATA'] ??
          Platform.environment['LOCALAPPDATA'] ??
          exeDir;
      final dir = '$appData${Platform.pathSeparator}Multik Sila';
      try {
        Directory(dir).createSync(recursive: true);
      } catch (_) {}
      _workDirCache = dir;
      return dir;
    }
  }

  String get _singBoxPath => '$_appDir${Platform.pathSeparator}sing-box.exe';

  String get _configPath => '$_workDir${Platform.pathSeparator}config.json';

  String get _xrayPath => '$_appDir${Platform.pathSeparator}xray.exe';

  // Лог только в памяти пропадает, если пришлось убивать процессы вручную
  // через Диспетчер задач (например, TUN-режим что-то подвесил и UI не
  // достучаться) — поэтому дублируем всё в файл рядом с .exe, с флашем
  // на каждой строке, чтобы данные точно попали на диск даже при жёстком килле.
  String get _logFilePath => '$_workDir${Platform.pathSeparator}app_log.txt';

  void _appendLog(String text) {
    final line = '[${DateTime.now().toIso8601String()}] $text';
    setState(() => _log += '\n$text');
    try {
      File(_logFilePath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  // Для мест, где UI-панель лога сбрасывается на новый прогон — в файл при
  // этом всё равно пишем (с разделителем), историю на диске не теряем.
  void _resetLog(String text) {
    final line = '[${DateTime.now().toIso8601String()}] --- $text';
    setState(() => _log = text);
    try {
      File(_logFilePath).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  String get _xrayConfigPath => '$_workDir${Platform.pathSeparator}xray_config.json';

  // У каждого постоянного моста TUN-режима свой файл конфига — процессы
  // теперь работают одновременно, общий файл конфига им не подходит.
  String _xrayBridgeConfigPath(String tag) => '$_workDir${Platform.pathSeparator}xray_bridge_$tag.json';

  // Порт локального моста: в TUN-режиме xhttp-серверы (движок Xray, который
  // TUN не умеет вообще) идут через отдельный headless-Xray на этом порту,
  // а sing-box (держащий TUN-адаптер) просто форвардит на него как на обычный
  // HTTP-прокси — ровно так же, как это делает сам v2rayN под капотом.
  //
  // Каждый xhttp-сервер получает свой ПОСТОЯННЫЙ порт моста (не общий и не
  // перевыделяемый) — так все мосты можно поднять заранее и держать живыми
  // весь TUN-сеанс, и переключение между xhttp-серверами становится чистым
  // Clash API selector switch, без убийства/рестарта каких-либо процессов.
  int _bridgePortFor(String tag) {
    final xrayTags = _servers.where((s) => s.engine == 'xray').map((s) => s.outbound['tag'] as String).toList();
    final index = xrayTags.indexOf(tag);
    return _xrayBridgeBasePort + (index >= 0 ? index : 0);
  }

  String get _ruleSetDir => '$_workDir${Platform.pathSeparator}rulesets';

  String _ruleSetPath(RuleSetSpec rs) => '$_ruleSetDir${Platform.pathSeparator}${rs.file}';

  // Возвращает только те наборы, которые реально лежат на диске и годны.
  // Недокачанный набор молча пропускаем: отправить трафик через VPN целиком —
  // мягкая деградация, а вот не запустить туннель вообще из-за недоступного
  // GitHub — нет. Проверка на размер обязательна: на несуществующий тег
  // raw.githubusercontent отдаёт бодрую 14-байтную страничку "404: Not Found",
  // и без неё она легла бы на диск как валидный набор правил.
  // Путь для скачанного, но ещё не применённого набора.
  String _pendingRuleSetPath(RuleSetSpec rs) => '${_ruleSetPath(rs)}.new';

  // Подменяет набор скачанным фоном обновлением. Вызывается только перед
  // стартом ядра, когда файл заведомо никем не читается.
  Future<void> _applyPendingRuleSet(RuleSetSpec rs) async {
    final pending = File(_pendingRuleSetPath(rs));
    try {
      if (!await pending.exists() || await pending.length() < 1024) return;
      await pending.copy(_ruleSetPath(rs));
      await pending.delete();
      _appendLog(tp('log.rulesetRefreshed',
          {'file': rs.file, 'days': _settings.ruleSetRefreshDays}));
    } catch (_) {
      // Не смогли заменить — работаем на прежнем наборе. Устаревшие правила
      // лучше, чем отсутствие правил и молчаливое вырождение «РФ напрямую».
    }
  }

  // Обновление наборов ФОНОМ, при старте приложения, а не перед запуском ядра.
  // Раньше это делалось прямо в _ensureRuleSets с таймаутом 30 с на набор:
  // со второго дня работы, если GitHub недоступен (то есть ровно тогда, когда
  // VPN и нужен), подключение ждало до полутора минут на трёх наборах.
  // Скачанное кладётся рядом как <файл>.new и применяется при следующем
  // старте ядра — см. _applyPendingRuleSet.
  Future<void> _refreshRuleSetsInBackground() async {
    final days = _settings.ruleSetRefreshDays;
    if (days <= 0) return;
    for (final rs in const [_rsGeositeRu, _rsGeoipRu, _rsAds]) {
      final file = File(_ruleSetPath(rs));
      try {
        // Обновляем только то, что уже использовалось: качать набор рекламы
        // тому, кто её не блокирует, незачем.
        if (!await file.exists()) continue;
        if (await File(_pendingRuleSetPath(rs)).exists()) continue;
        final age = DateTime.now().difference(await file.lastModified()).inDays;
        if (age < days) continue;
        final resp =
            await http.get(Uri.parse(rs.url)).timeout(const Duration(seconds: 20));
        if (resp.statusCode == 200 && resp.bodyBytes.length > 1024) {
          await File(_pendingRuleSetPath(rs))
              .writeAsBytes(resp.bodyBytes, flush: true);
        }
      } catch (_) {
        // Молча: обновление наборов — не то, ради чего стоит тревожить лог
        // при каждом старте без интернета.
      }
    }
  }

  Future<List<RuleSetSpec>> _ensureRuleSets(List<RuleSetSpec> needed) async {
    final ready = <RuleSetSpec>[];
    for (final rs in needed) {
      final file = File(_ruleSetPath(rs));
      // Скачанное фоном обновление применяется ЗДЕСЬ, до старта ядра, а не в
      // момент загрузки: sing-box читает .srs при запуске, и перезапись файла
      // под ним — гонка. Ядро ещё не стартовало, заменить безопасно.
      await _applyPendingRuleSet(rs);
      if (await file.exists() && await file.length() > 1024) {
        ready.add(rs);
        continue;
      }
      // Сначала — копия, вшитая в приложение. GitHub может быть недоступен
      // ровно тогда, когда VPN нужнее всего, и тянуть оттуда на старте — значит
      // молча выродить режим «РФ напрямую» в «всё через VPN».
      try {
        final bundled = await rootBundle.load('assets/rulesets/${rs.file}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bundled.buffer.asUint8List(), flush: true);
        _appendLog(tp('log.rulesetBundled', {'file': rs.file}));
        ready.add(rs);
        continue;
      } catch (_) {
        // в комплекте нет — пробуем сеть
      }
      try {
        // Сюда попадаем, только если набора нет ни на диске, ни в комплекте.
        // Таймаут короткий: это путь перед стартом ядра, и ждать здесь минуту
        // хуже, чем стартовать без правила (режим мягко деградирует).
        _appendLog(tp('log.rulesetDownloading', {'file': rs.file}));
        final resp = await http.get(Uri.parse(rs.url)).timeout(const Duration(seconds: 10));
        if (resp.statusCode != 200 || resp.bodyBytes.length < 1024) {
          throw Exception('HTTP ${resp.statusCode}, ${resp.bodyBytes.length} ${t('unit.b')}');
        }
        await file.parent.create(recursive: true);
        await file.writeAsBytes(resp.bodyBytes, flush: true);
        _appendLog(tp('log.rulesetReady',
            {'file': rs.file, 'bytes': resp.bodyBytes.length}));
        ready.add(rs);
      } catch (e) {
        _appendLog(tp('log.rulesetFailed', {'file': rs.file, 'e': e}));
      }
    }
    return ready;
  }

  // Хост прокси-сервера у Xray-outbound лежит по-разному в зависимости от
  // протокола: vless/vmess кладут его в settings.vnext[], trojan — в
  // settings.servers[]. У sing-box-outbound он просто в outbound['server'].
  String? _xrayOutboundHost(Map<String, dynamic> outbound) {
    final settings = outbound['settings'];
    if (settings is! Map) return null;
    for (final key in const ['vnext', 'servers']) {
      final list = settings[key];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final address = (list.first as Map)['address'];
        if (address is String && address.isNotEmpty) return address;
      }
    }
    return null;
  }

  // Резолвим адреса прокси-серверов заранее, на этапе генерации конфига:
  // когда TUN уже поднят, спрашивать DNS поздно — запрос сам поедет в туннель.
  // Нужно для bypass-правила по IP (см. _writeConfig).
  Future<List<String>> _resolveToCidrs(Iterable<String> hosts) async {
    final cidrs = <String>{};
    for (final host in hosts) {
      if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) {
        cidrs.add('$host/32');
        continue;
      }
      try {
        final addresses = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
        for (final a in addresses) {
          cidrs.add(a.type == InternetAddressType.IPv6 ? '${a.address}/128' : '${a.address}/32');
        }
      } catch (_) {
        _appendLog(tp('log.resolveBypassFailed', {'host': host}));
      }
    }
    return cidrs.toList();
  }

  // Кэш «хост -> IPv4», чтобы не резолвить один и тот же адрес по разу на
  // каждый сервер: вся подписка обычно живёт на одном хосте.
  final Map<String, String?> _hostIpCache = {};

  // Умеет ли лежащее рядом ядро сетевой стек gvisor. Спрашиваем у самого
  // бинарника, а не предполагаем: сборки sing-box отличаются набором тегов, и
  // `gvisor` есть далеко не в каждой. Конфиг с неподдерживаемым стеком не
  // ругается предупреждением, а роняет ядро на старте:
  //   FATAL start inbound/tun: gVisor is not included in this build
  // На этом приложение однажды перестало подключаться совсем — дефолт был
  // выставлен «как у Karing», а тот раздаёт собственную сборку ядра.
  bool? _coreHasGvisor;

  Future<bool> _coreSupportsGvisor() async {
    if (_coreHasGvisor != null) return _coreHasGvisor!;
    // На Android спрашивать не у кого и незачем: ядро там не отдельный файл,
    // а вкомпилированная в приложение библиотека, и собираем её мы сами —
    // с тегом with_gvisor. Проверка ниже запускает `sing-box.exe version`,
    // которого на Android нет; она честно падала в catch и писала в лог
    // «ядро собрано без gVisor», то есть ровно наоборот.
    if (!Env.coreRunsAsProcess) {
      _coreHasGvisor = true;
      return true;
    }
    try {
      final r = await Process.run(_singBoxPath, ['version'])
          .timeout(const Duration(seconds: 5));
      _coreHasGvisor = '${r.stdout}'.contains('with_gvisor');
    } catch (_) {
      // Не спросили — считаем, что не умеет: system поддерживают все сборки,
      // и ошибиться в эту сторону безопаснее.
      _coreHasGvisor = false;
    }
    return _coreHasGvisor!;
  }

  /// Подставляет в outbound'ы IP вместо имени хоста.
  ///
  /// Это лечение самой упрямой поломки TUN-режима: ядро не может подключиться
  /// к прокси-серверу, потому что не знает его адрес, а узнать не может,
  /// потому что DNS-запрос сам едет в ещё не поднятый туннель. Круг замкнут,
  /// и наружу он выходит как «включаю VPN — не открывается ни один сайт»,
  /// при полностью исправном туннеле. В логе ядра:
  ///   ERROR connection: ... lookup <хост>: context deadline exceeded  (10 с)
  /// и так по кругу на каждое соединение.
  ///
  /// Разорвать его выбором резолвера НЕЛЬЗЯ, проверено обоими вариантами:
  /// публичный адрес (1.1.1.1) под TUN уходит по физическому каналу и может
  /// быть закрыт у провайдера; системный резолвер сам ходит через туннель и
  /// попадает в тот же круг. Единственный надёжный выход — не резолвить в
  /// рантайме вовсе: адрес известен ЗАРАНЕЕ, на этапе генерации конфига,
  /// когда туннеля ещё нет и сеть обычная.
  ///
  /// Имя хоста при этом не теряется: оно нужно TLS для SNI и проверки
  /// сертификата, поэтому перед подменой обязательно проставляется в
  /// `tls.server_name` (если его там ещё нет). Без этого сервер увидит
  /// подключение без SNI и оборвёт рукопожатие.
  ///
  /// Не удалось отрезолвить — оставляем имя как было: пусть ядро попробует
  /// само, это не хуже, чем не подключиться совсем.
  Future<void> _bakeServerIps(List<ParsedServer> servers) async {
    for (final s in servers) {
      final host = s.outbound['server'];
      if (host is! String || host.isEmpty) continue;
      if (RegExp(r'^[\d.]+$').hasMatch(host) || host.contains(':')) continue;

      if (!_hostIpCache.containsKey(host)) {
        try {
          final addrs = await InternetAddress.lookup(host, type: InternetAddressType.IPv4)
              .timeout(const Duration(seconds: 5));
          _hostIpCache[host] = addrs.isEmpty ? null : addrs.first.address;
        } catch (_) {
          _hostIpCache[host] = null;
        }
      }
      final ip = _hostIpCache[host];
      if (ip == null) {
        _appendLog(tp('log.resolveBypassFailed', {'host': host}));
        continue;
      }

      final tls = s.outbound['tls'];
      if (tls is Map && tls['enabled'] == true) {
        final sni = tls['server_name'];
        if (sni is! String || sni.isEmpty) tls['server_name'] = host;
      }
      s.outbound['server'] = ip;
    }
  }

  // Серверы с engine == 'xray' (xhttp-транспорт) sing-box поднять сам не может —
  // в обычном режиме они просто не попадают в его конфиг (см. _startXrayCore).
  // В TUN-режиме для них добавляется bridge-outbound на локальный Xray.
  // Все sing-box-совместимые серверы грузятся разом, обёрнутые в один
  // selector-outbound с тегом "proxy" — это даёт Clash API возможность
  // тестировать задержку и переключать активный сервер (PUT /proxies/proxy)
  // без рестарта процесса.
  // Дописывает антиблокировочные поля в tls-секцию sing-box-outbound.
  // Правим копию: исходный outbound переиспользуется тестом задержки и
  // мостами, и мутировать его — значит незаметно менять их поведение.
  // Mux несовместим с flow: xtls-rprx-vision — Vision сам управляет потоком,
  // и мультиплексирование поверх него ломает соединение. Такие серверы
  // пропускаем молча: включать Mux глобально и получать один нерабочий
  // сервер из четырнадцати хуже, чем не применить его там, где нельзя.
  void _applyMux(Map<String, dynamic> outbound) {
    if (!_settings.muxEnabled) return;
    if (outbound['flow'] != null && '${outbound['flow']}'.isNotEmpty) return;
    outbound['multiplex'] = {
      "enabled": true,
      "protocol": _settings.muxProtocol,
      "max_streams": _settings.muxMaxStreams,
      if (_settings.muxPadding) "padding": true,
    };
  }

  Map<String, dynamic> _withTlsTweaks(Map<String, dynamic> outbound) {
    final hasTlsTweaks =
        _settings.tlsFragment || _settings.tlsRecordFragment || _settings.tlsInsecure;
    if (!hasTlsTweaks && !_settings.muxEnabled) return outbound;

    final copy = jsonDecode(jsonEncode(outbound)) as Map<String, dynamic>;
    // Mux применим и к outbound'ам без TLS (например, обычный VMess),
    // поэтому он вне проверки на наличие tls-секции.
    _applyMux(copy);

    final t = copy['tls'];
    if (hasTlsTweaks && t is Map<String, dynamic>) {
      if (_settings.tlsInsecure) t['insecure'] = true;
      if (_settings.tlsFragment) {
        t['fragment'] = true;
        if (_settings.tlsFragmentDelay.trim().isNotEmpty) {
          t['fragment_fallback_delay'] = _settings.tlsFragmentDelay.trim();
        }
      }
      if (_settings.tlsRecordFragment) t['record_fragment'] = true;
    }
    return copy;
  }

  Future<void> _writeConfig() async {
    final singboxServers = _servers.where((s) => s.engine == 'singbox').toList();
    final xraySeversForBridge = _tunMode ? _servers.where((s) => s.engine == 'xray').toList() : <ParsedServer>[];

    // socks, а не http — HTTP-прокси в принципе не переносит UDP, а браузеры
    // часто сначала пробуют HTTP/3 (QUIC поверх UDP). VLESS сам по себе UDP
    // поддерживает, ограничение было именно в транспорте моста.
    final bridgeOutbounds = xraySeversForBridge
        .map((s) => {
              "type": "socks",
              "tag": s.outbound['tag'],
              "server": "127.0.0.1",
              "server_port": _bridgePortFor(s.outbound['tag'] as String),
            })
        .toList();

    final selectorTags = [
      ...singboxServers.map((s) => s.outbound['tag'] as String),
      ...bridgeOutbounds.map((o) => o['tag'] as String),
    ];
    final defaultTag = selectorTags.contains(_selectedServer?.outbound['tag'])
        ? _selectedServer!.outbound['tag'] as String
        : selectorTags.first;

    final selector = {
      "type": "selector",
      "tag": "proxy",
      "outbounds": selectorTags,
      "default": defaultTag,
    };

    // Имена хостов прокси-серверов ЗАПОМИНАЕМ ДО подмены на IP: ниже они
    // нужны как домены для DNS-правил («хосты серверов резолвим напрямую»),
    // а после подмены в outbound'ах лежат уже адреса.
    final proxyHostNames = <String>{
      ...singboxServers.map((s) => s.outbound['server'] as String),
      ...xraySeversForBridge.map((s) => _xrayOutboundHost(s.outbound)).whereType<String>(),
    };

    // И только теперь — подмена. Обязательно ДО сборки config["outbounds"]:
    // там значения уже копируются в конфиг, и правка после этой строки в
    // готовый JSON не попадёт. На это я один раз наступил.
    await _bakeServerIps(singboxServers);

    final Map<String, dynamic> config = {
      "log": {
        "level": "info",
        // На Android лог ядра надо явно направить в файл.
        //
        // На Windows ядро — отдельный процесс, и его вывод читается из
        // stdout/stderr прямо в наш журнал. Здесь ядро внутри приложения, и
        // его лог по умолчанию не видно НИГДЕ: ни в журнале приложения, ни в
        // системном, ни в stderr (туда попадают только паники Go).
        //
        // Цена этой слепоты уже заплачена: туннель поднимался, пакеты в него
        // шли, наружу не выходило ничего, и ни одной строки о причине —
        // разбирать было нечем.
        if (!Env.coreRunsAsProcess)
          "output": '$_workDir${Platform.pathSeparator}core_log.txt',
      },
      "experimental": {
        "clash_api": {"external_controller": "127.0.0.1:${_settings.clashApiPort}"}
      },
      // Своё время для ядра: Reality и VMess отвергают соединение, если часы
      // клиента ушли больше чем на пару минут. Системные часы при этом НЕ
      // трогаются — правами администратора для этого обзаводиться не нужно.
      //
      // БЕЗ "detour". Первая версия ставила сюда "detour": "direct" (казалось
      // логичным: за временем идти мимо туннеля) — ядро на старте пишет
      // `ntp: initialize time: detour to an empty direct outbound makes no
      // sense` и НТП молча не работает, хотя сам прокси продолжает жить.
      // Ровно та же ловушка, что с dns-direct. `sing-box check` её не видит.
      // Проверено запуском, A/B с контролем: без ntp — HTTP 204; с detour —
      // HTTP 204, но ERROR и никакой сверки; без detour — HTTP 204 и
      // `ntp: updated time` в логе. Без детура ядро идёт напрямую само,
      // а под TUN его собственный трафик и так исключён auto_detect_interface.
      if (_settings.ntpEnabled)
        "ntp": {
          "enabled": true,
          "server": _settings.ntpServer,
          "server_port": _settings.ntpPort,
          "interval": _settings.ntpInterval,
        },
      "outbounds": [
        ...singboxServers.map((s) => _withTlsTweaks(s.outbound)),
        ...bridgeOutbounds,
        selector,
      ],
    };
    (config["outbounds"] as List).add({"type": "direct", "tag": "direct"});

    // Наборы правил нужны обоим режимам: раздельное туннелирование одинаково
    // осмысленно и для системного VPN, и для локального прокси на 1337.
    final ruMode = _routingMode == RoutingMode.bypassRu;
    final wantGeoSite = ruMode && _settings.geoSiteEnabled;
    final wantGeoIp = ruMode && _settings.geoIpEnabled;
    // Набор geosite скачивается и когда роутинг по нему выключен, а geoip
    // включён: по нему строится DNS-правило «RU-домены резолвим местным
    // резолвером». Без этого правила geoip промахивается — зарубежный DNS
    // на российский сайт отдаёт не тот адрес, что видит местный.
    final readySets = await _ensureRuleSets([
      if (wantGeoSite || wantGeoIp) _rsGeositeRu,
      if (wantGeoIp) _rsGeoipRu,
      if (_blockAds) _rsAds,
    ]);
    final adsReady = readySets.contains(_rsAds);
    final geoSiteReady = readySets.contains(_rsGeositeRu);
    final geoIpReady = readySets.contains(_rsGeoipRu);
    final ruTags = <String>[
      // В маршрутные правила geosite попадает только если он включён именно
      // как способ маршрутизации, а не подтянут ради DNS.
      if (wantGeoSite && geoSiteReady) _rsGeositeRu.tag,
      if (geoIpReady) _rsGeoipRu.tag,
    ];
    final ruleSetDecls = readySets
        .map((r) => {"type": "local", "tag": r.tag, "format": "binary", "path": _ruleSetPath(r)})
        .toList();

    // Одна запись списка — либо домен, либо IP/подсеть. Домены кладём в
    // domain_suffix: запись "example.com" должна ловить и сам домен, и все его
    // поддомены, иначе пользователю пришлось бы перечислять их вручную.
    // Голому IP дописываем /32 — sing-box ждёт именно CIDR.
    Map<String, dynamic>? ruleFromList(List<String> entries, Map<String, dynamic> action) {
      final domains = <String>[];
      final cidrs = <String>[];
      for (final raw in entries) {
        final e = raw.trim();
        if (e.isEmpty || e.startsWith('#')) continue;
        if (RegExp(r'^[0-9a-fA-F:.]+(/\d{1,3})?$').hasMatch(e) && e.contains(RegExp(r'[:.]'))) {
          final looksIpv4 = RegExp(r'^\d+\.\d+\.\d+\.\d+(/\d{1,2})?$').hasMatch(e);
          final looksIpv6 = e.contains(':');
          if (looksIpv4 || looksIpv6) {
            cidrs.add(e.contains('/') ? e : (looksIpv6 ? '$e/128' : '$e/32'));
            continue;
          }
        }
        domains.add(e.toLowerCase());
      }
      if (domains.isEmpty && cidrs.isEmpty) return null;
      return {
        if (domains.isNotEmpty) "domain_suffix": domains,
        if (cidrs.isNotEmpty) "ip_cidr": cidrs,
        ...action,
      };
    }

    final userBlock = ruleFromList(_settings.customBlock, {"action": "reject"});
    final userDirect = ruleFromList(_settings.customDirect, {"outbound": "direct"});
    final userProxy = ruleFromList(_settings.customProxy, {"outbound": "proxy"});

    // Правила для сервисов. Домены всех сервисов с одинаковым назначением
    // собираем в ОДНО правило: sing-box проверяет список правил по порядку,
    // и два десятка отдельных правил он бы перебирал на каждое соединение.
    final byAction = <String, List<String>>{};
    _settings.serviceRules.forEach((service, action) {
      final domains = AppSettings.serviceDomains[service];
      if (domains == null || action == 'default') return;
      byAction.putIfAbsent(action, () => []).addAll(domains);
    });
    final serviceRules = <Map<String, dynamic>>[
      if (byAction['block'] != null)
        {"domain_suffix": byAction['block'], "action": "reject"},
      if (byAction['direct'] != null)
        {"domain_suffix": byAction['direct'], "outbound": "direct"},
      if (byAction['proxy'] != null)
        {"domain_suffix": byAction['proxy'], "outbound": "proxy"},
    ];

    // Порядок важен — правила проверяются сверху вниз, побеждает первое
    // совпавшее. Личные списки идут ВЫШЕ готовых наборов: иначе режим
    // «РФ напрямую» перебивал бы явный выбор пользователя. Реклама режется до
    // RU-обхода: иначе ad.ozone.ru как российский домен ушёл бы в direct
    // и благополучно загрузился.
    // GeoIP сравнивает АДРЕС, а в обычном режиме соединение приходит доменом
    // (браузер отдаёт хост прямо в SOCKS/HTTP-запросе) — и правило по IP к
    // нему не применяется вообще. Проверено запуском: с одним лишь geoip-ru
    // yandex.ru и mail.ru уходили в прокси, хотя набор подключён и загружен;
    // с `{"action":"resolve"}` перед правилом оба ушли в direct.
    // В TUN этого не нужно: туда соединение приходит уже голым адресом.
    // Резолв стоит денег (запрос перед каждым новым соединением), поэтому
    // добавляется только когда geoip реально включён.
    final needsResolve = !_tunMode && geoIpReady;

    // Правила по приложениям. Собираем в одно правило на действие: sing-box
    // перебирает список сверху вниз на каждое соединение, и десяток отдельных
    // правил на десяток программ он бы перебирал целиком.
    final appsByAction = <String, List<String>>{};
    _settings.appRules.forEach((path, action) {
      if (action == 'default' || path.trim().isEmpty) return;
      appsByAction.putIfAbsent(action, () => []).add(path);
    });
    // Ключ правила зависит от платформы: на рабочем столе программа опознаётся
    // путём к .exe, на Android — именем пакета. Разные поля, а не разные
    // значения одного: `process_path` с именем пакета не совпадёт НИКОГДА, то
    // есть все правила пользователя молча не работали бы, а он видел бы их
    // список на экране и считал настроенными. Проверено по исходникам ядра:
    // на Android оно ищет владельца соединения в любом случае
    // (`C.IsAndroid && platformInterface != nil` -> `needFindProcess = true`),
    // так что цена правила здесь только в самом сравнении.
    final appRuleKey = Env.appRulesUsePaths ? "process_path" : "package_name";
    final appRules = <Map<String, dynamic>>[
      if (appsByAction['block'] != null)
        {appRuleKey: appsByAction['block'], "action": "reject"},
      if (appsByAction['direct'] != null)
        {appRuleKey: appsByAction['direct'], "outbound": "direct"},
      if (appsByAction['proxy'] != null)
        {appRuleKey: appsByAction['proxy'], "outbound": "proxy"},
    ];

    // «Только IPv4» обязано означать «IPv6 не пробовать», а не «не спрашивать
    // AAAA у DNS».
    //
    // Разница вылезает на телефоне. У TUN-адаптера есть IPv6-адрес (так и
    // задумано — иначе IPv6-трафик уходит мимо туннеля), поэтому система
    // сообщает приложениям, что IPv6 в наличии. Приложениям с зашитыми
    // IPv6-адресами (Telegram — ровно такое) наш DNS не указ: они идут по
    // IPv6 напрямую, соединение уходит в туннель, а на выходе у большинства
    // прокси-серверов IPv6 нет вовсе. Пакет уходит в тишину, и приложение ждёт
    // таймаута вместо того, чтобы за миллисекунды откатиться на IPv4.
    // Снаружи: «интернет есть, а Telegram пишет нет соединения», при этом
    // обычные сайты открываются.
    //
    // `reject` отвечает отказом сразу, и Happy Eyeballs честно переключается на
    // IPv4. Правило действует ТОЛЬКО в режиме «Только IPv4»: человек уже сказал,
    // что IPv6 ему не нужен, — а в остальных режимах трогать его нельзя.
    final rejectIpv6 = _settings.dnsStrategy == 'ipv4_only';

    List<Map<String, dynamic>> splitRules() => [
          {"ip_is_private": true, "outbound": "direct"},
          if (rejectIpv6) {"ip_version": 6, "action": "reject"},
          // Выше всего остального: «эта программа — всегда так» — самое
          // конкретное указание, какое пользователь может дать, и спорить
          // с ним доменным правилам незачем.
          ...appRules,
          ?userBlock,
          ?userDirect,
          ?userProxy,
          // Правила сервисов ниже личных списков, но выше готовых наборов:
          // явная запись пользователя должна побеждать шаблон, а шаблон —
          // общий режим «РФ напрямую».
          ...serviceRules,
          if (adsReady) {"rule_set": [_rsAds.tag], "action": "reject"},
          // Именно здесь, а не выше: всё, что решается по домену (личные
          // списки, сервисы, реклама), уже разобрано и резолва не потребовало.
          if (needsResolve) {"action": "resolve"},
          if (ruTags.isNotEmpty) {"rule_set": ruTags, "outbound": "direct"},
        ];

    // Домены самих прокси-серверов должны резолвиться напрямую — иначе
    // циклическая зависимость: чтобы подключиться к серверу, надо узнать
    // его IP, а DNS-запрос сам едет через ещё не поднятый до сервера туннель.
    // Для xhttp-серверов это тоже обязательно: в конфиг sing-box они попадают
    // как мост на 127.0.0.1, но реальный коннект до сервера делает отдельный
    // процесс xray.exe, и резолвить хост он будет через системный DNS.
    // Берём сохранённые ИМЕНА, а не текущее содержимое outbound'ов: там уже
    // подставлены IP (см. _bakeServerIps выше).
    final proxyHosts = proxyHostNames;
    final bypassDomains =
        proxyHosts.where((h) => !RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(h)).toList();
    // Хост NTP резолвим напрямую по той же причине, что и прокси-серверы:
    // ядро идёт к нему в обход туннеля (detour: direct), и ответ зарубежного
    // DNS через туннель тут только мешает — а под TUN это ещё и курица с яйцом.
    if (_settings.ntpEnabled) {
      final ntpHost = _settings.ntpServer.trim();
      if (ntpHost.isNotEmpty &&
          !RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ntpHost) &&
          !bypassDomains.contains(ntpHost)) {
        bypassDomains.add(ntpHost);
      }
    }


    // DNS идёт через АКТИВНЫЙ сервер (selector), а не через фиксированный
    // первый, и по TCP, а не по UDP.
    //
    // Раньше detour был прибит к `singboxServers.first`: xhttp-мост не несёт
    // UDP, и DNS к нему отваливался с «invalid argument». Побочный эффект
    // оказался хуже болезни — если тормозил именно первый сервер подписки,
    // ложился резолв ЦЕЛИКОМ, хотя человек сидел на другом, живом сервере.
    // Пользователь поймал это как «половина зарубежных сайтов не грузится»,
    // Discord — ERR_CONNECTION_RESET; в логе:
    //   dns: lookup failed for cp.cloudflare.com: context deadline exceeded (10.0s)
    // При этом через активный сервер шло 178 соединений, а через первый — 6,
    // и все шесть были DNS.
    //
    // DNS детурится через ФИКСИРОВАННЫЙ сервер, а не через активный selector.
    // Это выстрадано: попытка пустить DNS через selector сломала резолв
    // напрочь, стоило автовыбору встать на gRPC-сервер. Замеры на живом
    // приложении, активный сервер VLESS GRPC:
    //   UDP  через selector — 0 из 3 сайтов, 3 ошибки резолва
    //   DoH  через selector — 2 из 3, 1 ошибка
    //   UDP  через фиксированный — работает стабильно (как было всегда)
    // Причина: транспорт сервера может не переносить UDP (gRPC, xhttp), и
    // тогда ложится ВЕСЬ резолв, а не отдельный сайт.
    //
    // Но «первый попавшийся» тоже не годится: если тормозит именно он,
    // DNS ложится, хотя человек сидит на другом, живом сервере. Пользователь
    // поймал это как «половина зарубежных сайтов не грузится», в логе:
    //   dns: lookup failed for cp.cloudflare.com: context deadline exceeded (10.0s)
    // Поэтому берём первый сервер с ПРОСТЫМ транспортом: у такого UDP
    // проходит гарантированно. gRPC/WebSocket/HTTP-транспорты пропускаем.
    // ЭТО ОПИСАНИЕ ОСТАВЛЕНО КАК ИСТОРИЯ: фиксированный детур убран, теперь
    // способ выбирает человек («Способ разрешения в DNS», см. ниже), и по
    // умолчанию DNS идёт через активный сервер — как в Karing.
    //
    // Замер 2026-08-05 на всех девяти серверах подписки показал, что UDP
    // несут ВСЕ, включая gRPC-транспорт: DNS через каждый из них отдаёт 204
    // за 0.2–0.5 с. То есть причина, по которой детур когда-то прибили к
    // фиксированному серверу, к нынешней сборке ядра не относится.
    // Если она вернётся, симптом будет прежний — «половина зарубежных сайтов
    // не грузится» и `dns: lookup failed ... context deadline exceeded` в
    // логе, — и лечится он переключением способа на «Напрямую».

    // DNS задаём В ОБОИХ режимах, а не только в TUN. В обычном режиме его
    // раньше не было вовсе, и резолв шёл через системный. С включённым geoip-ru
    // sing-box обязан резолвить КАЖДЫЙ домен, чтобы понять, российский ли адрес,
    // — и любая заминка системного резолвера вешала сразу весь трафик, а не
    // отдельные сайты. Своим DNS эта зависимость снимается.
    // Статические записи вида "домен=адрес". Отдельным сервером типа hosts,
    // а не правилом: так они отвечают мгновенно и не ходят в сеть вовсе.
    final hosts = <String, List<String>>{};
    for (final line in _settings.dnsHosts) {
      final parts = line.split('=');
      if (parts.length != 2) continue;
      final domain = parts[0].trim();
      final addr = parts[1].trim();
      if (domain.isEmpty || addr.isEmpty) continue;
      hosts.putIfAbsent(domain, () => []).add(addr);
    }

    // `local` — это тип сервера в sing-box, а не адрес: он спрашивает
    // резолвер операционной системы. ПОД TUN ЭТО ЛОВУШКА: запрос системного
    // резолвера сам заходит в туннель и упирается в перехват DNS. Поэтому
    // такой сервер появляется в конфиге, только если человек выбрал его
    // сознательно, и никогда не ставится по умолчанию.
    Map<String, Object> dnsServer(String tag, String value, {String? detour}) =>
        value == AppSettings.kSystemDns
            ? {"type": "local", "tag": tag}
            : {
                "type": "udp",
                "tag": tag,
                "server": value,
                // `?` перед значением — запись попадёт в карту, только если
                // оно не null.
                "detour": ?detour,
              };

    // Каким сервером резолвить то, что ПОЙДЁТ МИМО туннеля (RU-домены, личные
    // списки «напрямую», хосты прокси-серверов). См. длинный комментарий ниже:
    // под TUN запрос мимо туннеля не доходит никуда, поэтому резолвим через
    // туннель, а маршрутизацию оставляем прежней.
    final directDnsTag = _tunMode ? 'dns-remote' : 'dns-direct';

    // Способ разрешения для трафика прокси (настройка «Способ разрешения в
    // DNS», как в Karing). Меняется только ДЕТУР сервера dns-remote и то,
    // добавляется ли FakeIP:
    //
    //  * current — через АКТИВНЫЙ сервер (селектор `proxy`). Резолв и
    //    соединение идут одним путём, поэтому и адрес приходит тот же,
    //    что увидит сервер. Раньше детур был жёстко прибит к первому серверу
    //    с простым транспортом, и при переключении сервера DNS продолжал
    //    ходить через старый — незаметно и неверно.
    //  * direct — мимо туннеля. Быстро, но провайдер видит запрашиваемые
    //    домены, а под TUN этот путь может не работать вовсе.
    //  * fakeip — адрес выдаётся мгновенно, настоящий узнаётся при коннекте.
    final proxyResolve = _settings.dnsProxyResolve;
    final remoteDetour = proxyResolve == 'direct' ? null : 'proxy';

    config["dns"] = {
      "servers": [
        dnsServer("dns-direct", _settings.dnsDirect),
        dnsServer("dns-remote", _settings.dnsRemote, detour: remoteDetour),
        if (hosts.isNotEmpty) {"type": "hosts", "tag": "dns-hosts", "predefined": hosts},
        // FakeIP отдаёт выдуманный адрес мгновенно, а настоящий узнаётся уже
        // при подключении — это убирает ожидание DNS перед каждым запросом.
        if (_settings.dnsFakeIp)
          {
            "type": "fakeip",
            "tag": "dns-fake",
            "inet4_range": "198.18.0.0/15",
            "inet6_range": "fc00::/18",
          },
      ],
      "rules": [
        if (hosts.isNotEmpty) {"domain": hosts.keys.toList(), "server": "dns-hosts"},
        if (bypassDomains.isNotEmpty)
          {
            "domain": bypassDomains,
            "server": directDnsTag,
            if (_settings.dnsTtl > 0) "rewrite_ttl": _settings.dnsTtl,
          },
      ],
      // FakeIP подключается ПРАВИЛОМ, а не через final: sing-box отказывается
      // стартовать с "default server cannot be fakeip". Правило добавляется
      // последним (см. ниже), уже после всех dns-direct — так домены, которым
      // нужен настоящий адрес, успевают уйти на честный резолв, иначе geoip
      // сравнивал бы выдуманный адрес и всегда промахивался.
      "final": "dns-remote",
      "strategy": _settings.dnsStrategy,
      // Раздельный кэш обязателен при FakeIP: иначе выдуманные и настоящие
      // ответы для одного домена перемешиваются в общем кэше.
      if (_settings.dnsFakeIp) "independent_cache": true,
      if (_settings.dnsClientSubnet.trim().isNotEmpty)
        "client_subnet": _settings.dnsClientSubnet.trim(),
    };
    // dns-direct СПЕЦИАЛЬНО без detour. Была попытка проставить ему
    // "detour": "direct" — sing-box падает на старте с "detour to an empty
    // direct outbound makes no sense": DNS-сервер без детура и так дозванивается
    // напрямую, а детур на пустой direct-outbound ядро считает бессмыслицей.
    // ВАЖНО: `sing-box check` эту ошибку НЕ ловит — она возникает при старте
    // сервиса, а не при разборе конфига. Проверять только реальным запуском.
    //
    // ПОД TUN «резолвить напрямую» НЕ РАБОТАЕТ, и это отдельная беда.
    // Замерено на живой машине: через туннель `cp.cloudflare.com` даёт 204 за
    // 0.1 с, а `yandex.ru` висит 11 секунд с `dns=0.000` — то есть DNS-запрос
    // мимо туннеля не доходит вообще, ни к 1.1.1.1, ни к 77.88.8.8, ни к
    // 8.8.8.8. `strict_route` тут ни при чём: A/B с ним и без него дал
    // одинаковый результат.
    //
    // При этом сам outbound `direct` ЖИВ — по нему ядро ходит до
    // прокси-сервера, и туннель поднимается. Не работает именно DNS.
    //
    // Отсюда развязка: «резолвить» и «маршрутизировать» — разные вещи, и
    // связывать их не обязано. Под TUN резолвим ВСЁ через туннель (он
    // заведомо работает), а трафик по-прежнему пускаем мимо по route.rules.
    // Российский сайт получит адрес от зарубежного DNS, но пойдёт к нему
    // напрямую — а это ровно то, что нужно.
    //
    // Цена: geoip-ru может промахнуться, если зарубежный DNS отдаст не тот
    // адрес, что видит местный резолвер. Доменное правило geosite-ru при этом
    // работает как прежде, а промах по IP несравнимо дешевле, чем нынешнее
    // «российские сайты не открываются вовсе».
    if (geoSiteReady) {
      (config["dns"]["rules"] as List).add({
        "rule_set": [_rsGeositeRu.tag],
        "server": directDnsTag,
      });
    }
    // То же и для личного списка «напрямую»: без этого домен уходит мимо
    // туннеля, а его DNS-запрос — через туннель. Смысл обхода теряется.
    final userDirectDomains = (userDirect?['domain_suffix'] as List?)?.cast<String>();
    if (userDirectDomains != null && userDirectDomains.isNotEmpty) {
      (config["dns"]["rules"] as List).add({
        "domain_suffix": userDirectDomains,
        "server": directDnsTag,
      });
    }
    // Сервисы, помеченные «напрямую», тоже резолвим настоящим DNS. При
    // включённом FakeIP без этого они получили бы выдуманный адрес, и
    // правило маршрутизации по IP до них не добралось бы.
    final directServices = byAction['direct'];
    if (directServices != null && directServices.isNotEmpty) {
      (config["dns"]["rules"] as List).add({
        "domain_suffix": directServices,
        "server": directDnsTag,
      });
    }
    // FakeIP — САМЫМ последним правилом, когда всё, что требует настоящего
    // адреса, уже разобрано правилами выше.
    if (_settings.dnsFakeIp) {
      (config["dns"]["rules"] as List).add({
        "query_type": ["A", "AAAA"],
        "server": "dns-fake",
      });
    }

    if (_tunMode) {
      // Стек сверяем с возможностями ядра. Конфиг с неподдерживаемым стеком
      // не даёт предупреждения — он роняет ядро на старте, и приложение
      // перестаёт подключаться вообще. Лучше молча взять рабочий и сказать
      // об этом в лог, чем оставить человека без сети.
      // `mixed` тоже требует gVisor — он использует его для UDP.
      var tunStack = _settings.tunStack;
      if ((tunStack == 'gvisor' || tunStack == 'mixed') &&
          !await _coreSupportsGvisor()) {
        _appendLog(t('log.tunStackFallback'));
        tunStack = 'system';
      }
      config["inbounds"] = [
        {
          "type": "tun",
          "tag": "tun-in",
          "interface_name": _settings.tunName,
          // Без IPv6-адреса адаптер не перехватывает IPv6 вообще — такой
          // трафик уходит напрямую мимо туннеля, и если IPv6 к конкретному
          // сайту не работает (нередкая ситуация), браузер по Happy Eyeballs
          // долго ждёт таймаута IPv6, прежде чем откатиться на IPv4 (который
          // у нас через туннель отрабатывает нормально) — выглядит как
          // "жуткий пинг"/зависание, хотя сам туннель ни при чём.
          "address": [
            _settings.tunIpv4,
            if (_settings.tunIpv6Enabled) _settings.tunIpv6,
          ],
          "auto_route": true,
          "strict_route": _settings.strictRoute,
          "stack": tunStack,
          "mtu": _settings.tunMtu,
        }
      ];
      // Свой xray.exe (мосты для xhttp-серверов) ходит до прокси-сервера как
      // обычный процесс — и auto_route заворачивает его собственный коннект
      // обратно в TUN. Если при этом активен как раз xhttp-сервер, sing-box по
      // final:"proxy" отправляет этот коннект в socks-мост, то есть ОБРАТНО В
      // ТОТ ЖЕ xray: получается петля, трафик ходит по кругу и наружу не
      // выходит вообще (в UI это видно как "Отправлено" растёт, "Скачано" = 0,
      // в браузере — ERR_CONNECTION_RESET). Своё ядро sing-box из туннеля
      // исключает само (auto_detect_interface), но про чужой процесс не знает.
      //
      // Исключаем по ПУТИ процесса, а не по имени: под именем xray.exe у
      // пользователя работает личный v2rayN, и уводить его трафик мимо VPN
      // молча мы не вправе. Плюс страховка по IP самих серверов — на случай,
      // если process-матчинг на Windows не отработает.
      final bypassCidrs = await _resolveToCidrs(proxyHosts);
      config["route"] = {
        if (ruleSetDecls.isNotEmpty) "rule_set": ruleSetDecls,
        "rules": [
          // TUN отдаёт роутеру голый IP — без sniff доменные правила (geosite,
          // реклама) применять просто не к чему, домен берётся из TLS SNI.
          {"action": "sniff"},
          // Перехват DNS: запросы приложений к любому серверу разворачиваются
          // на наш. Без этого программы с зашитым DNS (а таких много) ходят
          // мимо туннеля, и разделение трафика для них не работает вовсе.
          if (_settings.dnsHijack) {"protocol": "dns", "action": "hijack-dns"},
          // Вывод собственного моста Xray из туннеля — ТОЛЬКО на рабочем столе.
          //
          // Там мост это отдельный процесс `xray.exe`, и `auto_route`
          // заворачивает в туннель трафик всех процессов машины, включая его.
          // Его коннект до прокси-сервера уходил обратно в тот же туннель —
          // замкнутый круг, наружу не выходило ничего.
          //
          // На Android правила быть не должно, и дело не в том, что путь к
          // .exe там бессмыслен и просто никогда не совпадёт. Вред тоньше:
          // САМО НАЛИЧИЕ правила по процессу заставляет роутер определять
          // владельца КАЖДОГО соединения — то есть звать
          // `findConnectionOwner` в нашей службе, который для неопознанных
          // соединений честно бросает исключение. Туннель при этом поднят,
          // а трафик не идёт.
          //
          // Петля здесь невозможна и без правила: мосты работают внутри
          // нашего же процесса, а он исключён из туннеля целиком
          // (`addDisallowedApplication` в openTun).
          if (Env.coreRunsAsProcess)
            {
              "process_path": [_xrayPath],
              "outbound": "direct",
            },
          if (bypassCidrs.isNotEmpty) {"ip_cidr": bypassCidrs, "outbound": "direct"},
          ...splitRules(),
        ],
        "final": "proxy",
        "auto_detect_interface": true,
        // Чем резолвить домены, встреченные в полях подключения (адрес
        // сервера у outbound). Без этого ключа sing-box 1.12+ ругается
        // депрекейтом, а начиная с 1.13.16 просто ОТКАЗЫВАЕТСЯ стартовать:
        // «to continuing using this feature, set ENABLE_DEPRECATED_MISSING_
        // DOMAIN_RESOLVER=true». Поймано при проверке кандидата на
        // автообновление — с текущим ядром конфиг работал, а с новым падал.
        //
        // ИМЕННО системный резолвер, а не dns-direct и тем более не
        // dns-remote. Этим ключом ядро узнаёт адрес самого прокси-сервера —
        // то есть резолвит ДО того, как поднялся хоть какой-то туннель, по
        // голому физическому каналу. Публичный адрес тут ставить нельзя: у
        // провайдера он может быть закрыт, и тогда всё встаёт намертво —
        // без резолва нет прокси, без прокси нет DNS. Поймано debug-логом:
        //   dns: lookup failed for <хост сервера>: context deadline exceeded
        // по 10 секунд и по кругу, при полностью исправном туннеле.
        // dns-direct, а не системный резолвер: под TUN системный сам ходит
        // через туннель. Резолвить тут по сути нечего — адреса серверов уже
        // подставлены в конфиг (_bakeServerIps), — но ключ обязателен, без
        // него свежие ядра не стартуют.
        "default_domain_resolver": "dns-direct",
      };
    } else {
      config["inbounds"] = [
        {
          "type": "mixed",
          "tag": "mixed-in",
          // 0.0.0.0 открывает прокси для других устройств в локальной сети —
          // ровно то, что в Karing называется "разрешить доступ из локальной сети".
          "listen": _settings.allowLan ? "0.0.0.0" : "127.0.0.1",
          "listen_port": _settings.localPort,
        }
      ];
      // Здесь sniff не нужен: домен приходит прямо в SOCKS/HTTP-запросе
      // от браузера, ничего вынюхивать из TLS не требуется.
      config["route"] = {
        if (ruleSetDecls.isNotEmpty) "rule_set": ruleSetDecls,
        "rules": splitRules(),
        "final": "proxy",
        // См. комментарий в TUN-ветке: без этого ключа свежие ядра не
        // стартуют, а резолвить адрес прокси-сервера обязан системный
        // резолвер — единственный, который работает на любой сети.
        // dns-direct, а не системный резолвер: под TUN системный сам ходит
        // через туннель. Резолвить тут по сути нечего — адреса серверов уже
        // подставлены в конфиг (_bakeServerIps), — но ключ обязателен, без
        // него свежие ядра не стартуют.
        "default_domain_resolver": "dns-direct",
      };
    }

    final file = File(_configPath);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(config));
  }

  // В обычном (не-TUN) режиме переключение серверов на движке Xray идёт через
  // полный рестарт процесса на порту 1337 — протокол http, т.к. это системная
  // настройка HTTP-прокси в Windows. В TUN-режиме конфиг пишется для
  // постоянного моста конкретного сервера — protocol socks+udp (см. _writeConfig
  // про то, почему не http) на его собственный выделенный порт и свой файл.
  // Копия outbound'а с sockopt.dialerProxy на фрагментирующий freedom.
  // Именно копия: тот же объект используют тест задержки и другие мосты.
  Map<String, dynamic> _xrayOutboundViaFragment(Map<String, dynamic> outbound) {
    final copy = jsonDecode(jsonEncode(outbound)) as Map<String, dynamic>;
    final stream = (copy['streamSettings'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final sockopt = (stream['sockopt'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    sockopt['dialerProxy'] = 'frag';
    stream['sockopt'] = sockopt;
    copy['streamSettings'] = stream;
    return copy;
  }

  Future<void> _writeXrayConfig(ParsedServer server, {required int port, required bool isBridge, required String configPath}) async {
    final config = {
      "log": {"loglevel": "warning"},
      "inbounds": [
        {
          "listen": "127.0.0.1",
          "port": port,
          "protocol": isBridge ? "socks" : "http",
          if (isBridge) "settings": {"auth": "noauth", "udp": true},
        }
      ],
      // Xray фрагментирует не полем в tls, а отдельным freedom-outbound:
      // основной outbound дозванивается «через» него (sockopt.dialerProxy).
      "outbounds": [
        if (_settings.tlsFragment) _xrayOutboundViaFragment(server.outbound) else server.outbound,
        if (_settings.tlsFragment)
          {
            "protocol": "freedom",
            "tag": "frag",
            "settings": {
              "fragment": {
                // tlshello — режется только приветствие TLS, дальше данные
                // идут как обычно. Резать весь поток заметно дороже и обычно
                // не нужно: опознают соединение именно по первому пакету.
                "packets": "tlshello",
                "length": _settings.xrayFragLength,
                "interval": _settings.xrayFragInterval,
              }
            }
          },
      ],
    };
    final file = File(configPath);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(config));
  }

  // Порты, которые занимает НАШЕ хозяйство: локальный прокси, Clash API и
  // по мосту на каждый xhttp-сервер.
  Set<int> _ourPorts() {
    final xrayCount = _servers.where((s) => s.engine == 'xray').length;
    return {
      _settings.localPort,
      _settings.clashApiPort,
      for (var i = 0; i < xrayCount; i++) _xrayBridgeBasePort + i,
    };
  }

  // Убираем зависшие с прошлого раза процессы — ТОЛЬКО владельцев наших портов
  // и ТОЛЬКО по PID.
  //
  // Раньше здесь был `taskkill /IM xray.exe /F` (и такой же для sing-box.exe).
  // Убивать по имени категорически нельзя: под именем xray.exe работает личный
  // v2rayN пользователя — его единственный канал в интернет, — и такой taskkill
  // сносил его вместе с нашим ядром при каждом запуске xhttp-сервера.
  //
  // Осиротевшие процессы, запущенные elevated-экземпляром приложения, обычным
  // taskkill не убиваются (Mandatory Integrity Control). Это не молчаливый сбой:
  // пишем в лог, иначе потом непонятно, почему мост не поднялся — порт занят.
  // Добивание по ПУТИ исполняемого файла. Нужно там, где порт не спасает:
  // sing-box в TUN-режиме держит адаптер SilaTUN, и если прошлый экземпляр
  // не умер, новый падает с "configure tun interface: Cannot create a file
  // when that file already exists" — а Clash API он к тому моменту мог и не
  // успеть занять, так что по портам его не найти.
  //
  // Сравнение именно по полному пути, а не по имени: v2rayN пользователя
  // запускает свой xray.exe из другого каталога и задет быть не должен.
  Future<void> _killOurProcessesByPath() async {
    // Свои живые процессы исключаем по PID. Мосты Xray запускаются ТЕМ ЖЕ
    // xray.exe из нашей папки, поэтому «убить всё с нашим путём» означало бы
    // расстрелять только что поднятые мосты — см. комментарий в
    // _killStrayOnOurPorts про самоубийство на портах 1338+.
    final ours = <String>{
      for (final p in _xrayBridgeProcesses.values) '${p.pid}',
      if (_coreProcess != null) '${_coreProcess!.pid}',
      if (_xrayProcess != null) '${_xrayProcess!.pid}',
    };
    for (final exe in [_singBoxPath, _xrayPath]) {
      try {
        final name = exe.split(Platform.pathSeparator).last;
        final escaped = exe.replaceAll("'", "''");
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "Get-CimInstance Win32_Process -Filter \"Name='$name'\" | "
              "Where-Object { \$_.ExecutablePath -eq '$escaped' } | "
              "ForEach-Object { \$_.ProcessId }",
        ]);
        for (final line in (result.stdout as String).split('\n')) {
          final pid = line.trim();
          if (pid.isEmpty || int.tryParse(pid) == null) continue;
          if (ours.contains(pid)) continue; // свой живой процесс — не трогаем
          final killed = await Process.run('taskkill', ['/PID', pid, '/F']);
          _appendLog(tp(
              killed.exitCode == 0 ? 'log.killedOwn' : 'log.killOwnFailed',
              {'name': name, 'pid': pid}));
        }
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 300));
  }

  Future<void> _killStrayOnOurPorts() async {
    try {
      final ports = _ourPorts();
      final result = await Process.run('netstat', ['-ano', '-p', 'tcp']);
      // PID'ы СВОИХ живых процессов. Без этого списка функция стреляла себе
      // в ногу: в TUN-режиме _startCore сначала поднимает мосты Xray на
      // портах 1338+, а потом зовёт этот киллер — и он честно находил на
      // «наших» портах владельцев и убивал их. В логе это выглядело так:
      //   16:02:25.701 Мост Xray для Trojan XR готов на порту 1342
      //   16:02:25.942 Убрал зависший процесс на нашем порту (PID 23356)
      // Пять мостов поднято, пять тут же расстреляно. Наружу баг выходил
      // не сразу: пока активен singbox-сервер, мосты не нужны, а при
      // переключении на любой xhttp-сервер всё падало с
      // `dial tcp 127.0.0.1:134x: connection refused`.
      final ours = <String>{
        for (final p in _xrayBridgeProcesses.values) '${p.pid}',
        if (_coreProcess != null) '${_coreProcess!.pid}',
        if (_xrayProcess != null) '${_xrayProcess!.pid}',
      };
      final pids = <String>{};
      for (final line in (result.stdout as String).split('\n')) {
        if (!line.contains('LISTENING')) continue;
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 5) continue;
        final local = parts[1];
        final colon = local.lastIndexOf(':');
        if (colon < 0) continue;
        final port = int.tryParse(local.substring(colon + 1));
        if (port == null || !ports.contains(port)) continue;
        if (ours.contains(parts.last)) continue; // свой живой процесс — не трогаем
        pids.add(parts.last);
      }
      for (final pid in pids) {
        final killed = await Process.run('taskkill', ['/PID', pid, '/F']);
        if (killed.exitCode == 0) {
          _appendLog(tp('log.killedOnPort', {'pid': pid}));
        } else {
          _appendLog(tp('log.killOnPortFailed', {'pid': pid}));
        }
      }
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
  }

  // Сколько раз подряд ядро уже перезапускали. Сбрасывается при ручном
  // старте: иначе после нескольких падений подряд автоподъём замолкает
  // навсегда, даже когда проблема давно ушла.
  int _restartAttempts = 0;

  // Присматриваем за ядром: если процесс умер сам (не по кнопке «Отключить»),
  // поднимаем его заново. Без этого «включил и забыл» не работает — падение
  // ядра пользователь замечает только когда перестают открываться сайты.
  void _watchCore(Process process) {
    process.exitCode.then((code) async {
      // Плановая остановка — ничего не делаем.
      if (_stopRequested || _runningEngine == null) return;
      // Убедимся, что умер именно тот процесс, за которым следим: за время
      // ожидания могли успеть перезапустить ядро вручную.
      if (!identical(process, _coreProcess) && !identical(process, _xrayProcess)) return;
      if (!_settings.autoRestartCore) {
        _appendLog(tp('log.coreExitedNoRestart', {'code': code}));
        return;
      }
      if (_restartAttempts >= 3) {
        _appendLog(tp('log.coreCrashLoop', {'code': code}));
        return;
      }
      _restartAttempts++;
      _appendLog(tp('log.coreExitedRestarting',
          {'code': code, 'n': _restartAttempts}));
      // Небольшая пауза: если причина в занятом порте, мгновенный перезапуск
      // упрётся в него же.
      await Future.delayed(const Duration(seconds: 2));
      if (_stopRequested) return;
      await _startCore(isAutoRestart: true);
    });
  }

  /// Прервать идущее подключение.
  ///
  /// Флаг `_stopRequested` уже проверяется по всему пути старта (он появился,
  /// чтобы запоздавший старт не включил системный прокси после остановки) —
  /// здесь мы им пользуемся по прямому назначению. Плюс гасим тест задержки:
  /// при включённом автовыборе подключение начинается именно с него, и без
  /// этого «отмена» выглядела бы как ничего не делающая кнопка ещё секунд
  /// десять.
  void _cancelStart() {
    if (!_busy) return;
    _stopRequested = true;
    _cancelLatency = true;
    _appendLog(t('log.startCancelled'));
  }

  /// Пробные ядра текущего прогона. Нужны, чтобы отмена была мгновенной.
  final List<Process> _probeProcesses = [];

  /// Тащит из вывода пробного ядра ТОЛЬКО строки об ошибках.
  ///
  /// Пробное ядро — единственный, кто знает настоящую причину неудачи. Дартовой
  /// стороне достаётся общее «не удалось соединиться», и по нему нельзя
  /// отличить «сервер выключен» от «ключ REALITY больше не тот».
  void _watchProbeErrors(Process probe, String label) {
    void handle(String data) {
      for (final line in data.split('\n')) {
        final text = line.trim();
        if (text.isEmpty) continue;
        // Предупреждения о депрекейтах ядро печатает при каждом старте, и в
        // журнале от них один шум.
        if (!text.contains('[Error]') && !text.contains('ERROR')) continue;
        _appendLog('[$label] $text');
      }
    }

    probe.stdout.transform(const SystemEncoding().decoder).listen(handle);
    probe.stderr.transform(const SystemEncoding().decoder).listen(handle);
  }

  /// DNS и маршрутизация для ПРОБНОГО ядра.
  ///
  /// Пробный конфиг обязан разрешать имена так же, как рабочий. Раньше он не
  /// разрешал их вообще: секции `dns` не было, `default_domain_resolver` тоже,
  /// а `route` состоял из одного `final`. Сравнение файлов с диска показало,
  /// что сами outbound'ы в обоих конфигах побайтово одинаковы — расходится
  /// только это окружение.
  ///
  /// Наружу это выходило как ложь про серверы: те, чей адрес в рабочем конфиге
  /// уже запечён как IP (`_bakeServerIps`), мерились нормально, а те, у кого в
  /// поле осталось имя, пробному ядру резолвить было нечем — и они показывались
  /// недоступными, прекрасно работая при подключении. Пять серверов из
  /// четырнадцати у пользователя, три прогона подряд, один и тот же набор.
  ///
  /// Значения берём из настроек, а не прибиваем: замер должен отвечать на
  /// вопрос «как будет работать», а не «как работало бы при других настройках».
  Map<String, Object> _probeDnsAndRoute() => {
        "dns": {
          "servers": [
            {"type": "udp", "tag": "dns-direct", "server": _settings.dnsDirect},
          ],
          "final": "dns-direct",
          "strategy": _settings.dnsStrategy,
        },
        "route": {
          "final": "probe",
          "auto_detect_interface": true,
          // Без этого ключа свежие ядра вообще отказываются стартовать, а с
          // ним — знают, чем разрешать адреса серверов подключения.
          "default_domain_resolver": "dns-direct",
        },
      };

  /// Прервать тест задержки, запущенный кнопкой (без подключения).
  ///
  /// Отдельно от `_cancelStart`: тот завязан на `_busy`, а он поднимается
  /// только на время подключения. Тест, запущенный вручную, идёт при `_busy`
  /// == false, и отменять его было нечем.
  ///
  /// Одного флага НЕ ХВАТАЕТ, и это была моя ошибка в прошлой правке. Флаг
  /// останавливает разбор очереди, но уже начатые проверки продолжают ждать
  /// свой таймаут — по умолчанию шесть секунд, и до двенадцати штук разом.
  /// Человек жмёт «Остановить», а тест идёт дальше: снаружи кнопка выглядит
  /// сломанной. Поэтому здесь же гасим пробные ядра — висящие на них запросы
  /// падают сразу, а не по таймауту, — и СРАЗУ перерисовываем экран, не
  /// дожидаясь, пока догорят хвосты.
  void _cancelLatencyTest() {
    if (!_testingLatency) return;
    _cancelLatency = true;
    for (final probe in _probeProcesses) {
      try {
        probe.kill();
      } catch (_) {}
    }
    _probeProcesses.clear();
    _appendLog(t('log.latencyCancelled'));
    if (mounted) setState(() => _testingLatency = false);
  }

  Future<void> _startCore({bool isAutoRestart = false}) async {
    // Защита от повторных нажатий. С включённым автовыбором старт сначала
    // гоняет тест по всем серверам — это несколько секунд, в течение которых
    // щит внешне не менялся, и человек естественно жал ещё раз. Каждое
    // нажатие запускало ВТОРОЙ параллельный старт: два ядра на одном порту,
    // взаимные killStray и перезапуски. Теперь второй клик просто игнорируется,
    // а щит на это время показывает, что занят (см. _busy в _shieldBlock).
    if (_busy) return;
    if (!isAutoRestart) _restartAttempts = 0;
    if (_servers.isEmpty) {
      _resetLog(t('log.noSubscription'));
      return;
    }
    if (mounted) setState(() => _busy = true);
    try {
      await _startCoreInner(isAutoRestart: isAutoRestart);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startCoreInner({bool isAutoRestart = false}) async {
    // Снимаем флаг предыдущей остановки — иначе после первого «Остановить»
    // системный прокси больше никогда бы не включился.
    _stopRequested = false;

    // Перед подключением выбираем самый быстрый сервер. Тест гоняем только
    // если задержки ещё не измерены: гонять его на каждое нажатие — это
    // лишние секунды ожидания там, где цифры уже есть.
    if (_settings.autoSelectOnConnect && _servers.length > 1) {
      final measured = _servers.where((s) => _latencyMs.containsKey(s.outbound['tag'])).length;
      if (measured < _servers.length) {
        _appendLog(t('log.autoSelectBeforeConnect'));
        await _testAllLatencies();
      }
      final candidates = _autoSelectCandidates()
          .where((s) => _latencyMs[s.outbound['tag']] != null)
          .toList();
      if (candidates.isNotEmpty) {
        candidates.sort((a, b) =>
            _latencyMs[a.outbound['tag']]!.compareTo(_latencyMs[b.outbound['tag']]!));
        final best = candidates.first;
        if (best.outbound['tag'] != _selectedServer?.outbound['tag']) {
          setState(() => _selectedServer = best);
          _appendLog(tp('log.autoSelectPicked',
              {'name': best.name, 'ms': _latencyMs[best.outbound['tag']]}));
        }
      }
      if (_stopRequested) return;
    }
    // Последняя проверка перед тем, как что-то поднимать.
    //
    // Отмена, нажатая во время автовыбора, до сих пор помогала только если
    // успевала попасть между шагами теста. Дальше по пути проверок не было, и
    // ядро всё равно стартовало — то есть «отменил», а через секунду видишь
    // «подключено». Здесь проходит граница: выше — только измерения, ниже
    // начинается запуск.
    if (_stopRequested) {
      _appendLog(t('log.startCancelled'));
      return;
    }
    _selectedServer ??= _servers.first;
    _appendLog(tp('log.startSummary', {
      'name': _selectedServer!.name,
      'engine': _selectedServer!.engine,
      'tag': _selectedServer!.outbound['tag'],
      'tun': _tunMode,
      'admin': _isAdmin,
    }));

    if (Env.isAndroid) {
      await _startAndroidTunnel();
      return;
    }

    if (!_tunMode && _selectedServer!.engine == 'xray') {
      // обычный режим: Xray сам держит локальный прокси на 1337, sing-box не нужен
      await _startXrayCore(_selectedServer!);
      return;
    }

    // TUN-режим: sing-box всегда держит адаптер. Поднимаем мосты для ВСЕХ
    // xhttp-серверов профиля заранее (если ещё не подняты) — тогда любое
    // последующее переключение между ними уже не требует рестарта процессов.
    if (_tunMode && _servers.any((s) => s.engine == 'xray')) {
      _resetLog(t('log.bridgesStarting'));
      await _ensureAllXrayBridgesRunning();
    }
    await _startSingboxCore();
  }

  /// Запуск туннеля на Android.
  ///
  /// Конфиги — те же самые. Их собирает `_writeConfig` и `_writeXrayConfig`,
  /// общие с Windows-версией: генератор один, и разойтись поведению двух
  /// платформ неоткуда. Отличие в том, куда эти конфиги едут: не в командную
  /// строку дочернего процесса, а в службу через канал, потому что ядро здесь
  /// вкомпилировано в приложение.
  Future<void> _startAndroidTunnel() async {
    // Разрешение спрашиваем перед КАЖДЫМ запуском, а не один раз при первом:
    // Android отзывает его, стоит человеку включить другой клиент VPN —
    // активным может быть только один.
    if (!await AndroidVpn.prepare()) {
      _appendLog(t('log.androidVpnDenied'));
      return;
    }

    _resetLog(t('log.generatingConfig'));
    await _writeConfig();
    final config = await File(_configPath).readAsString();

    // Мосты для xhttp-серверов. Порты берём той же функцией `_bridgePortFor`,
    // которой пользовался `_writeConfig`, — иначе socks-outbound'ы в конфиге
    // ядра указывали бы на порты, которых никто не слушает.
    final bridges = <String>[];
    for (final server in _servers.where((s) => s.engine == 'xray')) {
      final tag = server.outbound['tag'] as String;
      final path = '$_workDir${Platform.pathSeparator}xray_bridge_$tag.json';
      await _writeXrayConfig(server,
          port: _bridgePortFor(tag), isBridge: true, configPath: path);
      bridges.add(await File(path).readAsString());
    }
    if (bridges.isNotEmpty) {
      _appendLog(tp('log.androidBridges', {'n': bridges.length}));
    }

    await AndroidVpn.start(config: config, bridges: bridges);
    // Состояние щита придёт от службы через поток — здесь его не трогаем,
    // иначе на экране будет «подключено» раньше, чем ядро действительно
    // поднялось.
  }

  Future<void> _startSingboxCore() async {
    final singboxServers = _servers.where((s) => s.engine == 'singbox').toList();
    final hasBridgeCandidate = _tunMode && _servers.any((s) => s.engine == 'xray');
    if (singboxServers.isEmpty && !hasBridgeCandidate) {
      _resetLog(t('log.noSingboxServers'));
      return;
    }

    // Предыдущее ядро гасим ПЕРЕД киллерами и сразу обнуляем ссылки.
    //
    // Оба киллера намеренно пропускают PID'ы из _coreProcess/_xrayProcess —
    // иначе они расстреливали бы собственные мосты. Но пока ссылка указывает
    // на ещё ЖИВОЕ старое ядро, эта защита работает против нас: старый
    // процесс остаётся сидеть на порту 1337 (и на Clash API, и на адаптере
    // SilaTUN), новое ядро на них не встаёт и умирает, а UI при этом
    // рапортует «подключено» — трафик продолжает идти через прежний сервер.
    // Путь: _switchServer зовёт _startCore БЕЗ остановки — то есть при любой
    // смене движка (xhttp <-> sing-box) и при недоступном Clash API.
    // Валим только зависший sing-box — мост на Xray (если только что подняли
    // для TUN-режима) трогать нельзя, иначе он погибнет вместе с ним.
    _coreProcess?.kill();
    _xrayProcess?.kill();
    _coreProcess = null;
    _xrayProcess = null;
    await _killStrayOnOurPorts();
    await _killOurProcessesByPath();

    _resetLog(t('log.generatingConfig'));
    await _writeConfig();

    _appendLog(t('log.startingSingbox'));

    final process = await Process.start(_singBoxPath, ['run', '-c', _configPath]);
    _coreProcess = process;
    _runningEngine = 'singbox';
    _rescheduleHealthCheck();
    _refreshTrayMenu();
    _enableSystemProxy();
    _watchCore(process);

    // sing-box пишет INFO/DEBUG-строки в stderr наравне с реальными ошибками —
    // метка [stderr] тут про поток, а не про факт ошибки
    process.stdout.transform(SystemEncoding().decoder).listen((data) {
      _appendLog(data);
    });
    process.stderr.transform(SystemEncoding().decoder).listen((data) {
      _appendLog('[stderr] $data');
    });
    // Таймер статистики здесь НЕ заводится: его завёл сеттер `_runningEngine`
    // выше. Второе место завода — это ровно то, чего мы избавились: одно из
    // них однажды и забыли.
  }

  Future<void> _startXrayCore(ParsedServer server) async {
    // То же, что и в _startSingboxCore: сначала гасим предыдущее ядро и
    // обнуляем ссылки, и только потом зовём киллеров — иначе они пропустят
    // ещё живой процесс как «свой», и Xray не сможет занять порт.
    _coreProcess?.kill();
    _xrayProcess?.kill();
    _coreProcess = null;
    _xrayProcess = null;
    await _killStrayOnOurPorts();
    await _killOurProcessesByPath();

    _resetLog(tp('log.generatingXrayConfig', {'name': server.name}));
    await _writeXrayConfig(server, port: _settings.localPort, isBridge: false, configPath: _xrayConfigPath);

    _appendLog(t('log.startingXray'));

    final process = await Process.start(_xrayPath, ['run', '-c', _xrayConfigPath]);
    _xrayProcess = process;
    _runningEngine = 'xray';
    _rescheduleHealthCheck();
    _refreshTrayMenu();
    _enableSystemProxy();
    _watchCore(process);

    process.stdout.transform(SystemEncoding().decoder).listen((data) {
      _appendLog(data);
    });
    process.stderr.transform(SystemEncoding().decoder).listen((data) {
      _appendLog('[stderr] $data');
    });

    // Опрос уже выключен сеттером `_runningEngine` (у Xray Clash API нет),
    // остаётся только сказать об этом на экране.
    setState(() => _statsText = tp('stats.xrayNoApi', {'name': server.name}));
  }

  // Ждём, пока порт реально начнёт принимать соединения — вместо того чтобы
  // гадать с фиксированной паузой (именно так один раз и словили гонку:
  // пауза была добавлена в одном месте запуска моста, но не в другом).
  Future<bool> _waitForPort(int port, {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 300));
        socket.destroy();
        return true;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    return false;
  }

  // Поднимает постоянный мост для ОДНОГО xhttp-сервера (если ещё не поднят) —
  // не трогает мосты других серверов и не трогает sing-box вообще. Убивает и
  // поднимает только свой собственный процесс по хендлу, не по имени.
  // Возвращается только когда порт моста реально готов принимать соединения.
  Future<void> _ensureXrayBridge(ParsedServer server) async {
    // На Android мостов-процессов не существует: Xray там вкомпилирован в
    // приложение, и мосты поднимает служба туннеля разом при старте.
    // `Process.start` здесь не «ничего не делает», а БРОСАЕТ ProcessException —
    // запуск сторонних исполняемых файлов там запрещён. Ловить исключение
    // некому: `_switchServer` зовёт эту функцию первой строкой, и переключение
    // на xhttp-сервер обрывалось целиком, не дойдя до Clash API. Тем же путём
    // ходит автопереключение по проверке связи — то есть после первой же
    // заминки сети приложение могло остаться на мёртвом сервере.
    if (!Env.coreRunsAsProcess) return;
    final tag = server.outbound['tag'] as String;
    final port = _bridgePortFor(tag);
    final existing = _xrayBridgeProcesses[tag];
    if (existing != null) {
      // Наличие объекта Process НЕ значит, что мост жив. Раньше здесь стоял
      // голый `if (existing != null) return`, и умерший мост навсегда
      // оставался «поднятым»: переключение на его сервер молча проходило,
      // а каждое соединение падало с `dial tcp 127.0.0.1:134x: connection
      // refused`. Ровно так в логе легли 8 запросов к Telegram и Microsoft
      // после переключения на Trojan XR. Спрашиваем порт, а не словарь.
      if (await _waitForPort(port, timeout: const Duration(milliseconds: 400))) {
        return;
      }
      _appendLog(tp('log.bridgeRestart', {'name': server.name, 'port': port}));
      existing.kill();
      _xrayBridgeProcesses.remove(tag);
    }

    final configPath = _xrayBridgeConfigPath(tag);
    await _writeXrayConfig(server, port: port, isBridge: true, configPath: configPath);
    final process = await Process.start(_xrayPath, ['run', '-c', configPath]);
    _xrayBridgeProcesses[tag] = process;

    // Смерть моста должна попадать в лог и в словарь. Без этого падение
    // проходило совершенно бесшумно: в UI сервер выглядел рабочим, а трафик
    // до него не доходил вовсе.
    unawaited(process.exitCode.then((code) {
      if (!identical(_xrayBridgeProcesses[tag], process)) return;
      _xrayBridgeProcesses.remove(tag);
      _appendLog(tp('log.bridgeDied', {'name': server.name, 'code': code}));
    }));

    process.stdout.transform(SystemEncoding().decoder).listen((data) {
      _appendLog('[xray:$tag] $data');
    });
    process.stderr.transform(SystemEncoding().decoder).listen((data) {
      _appendLog('[xray:$tag stderr] $data');
    });

    final ready = await _waitForPort(port);
    _appendLog(tp(ready ? 'log.bridgeReady' : 'log.bridgeNotReady',
        {'name': server.name, 'port': port}));
  }

  // Поднимает мосты для ВСЕХ xhttp-серверов профиля разом — вызывается перед
  // стартом sing-box в TUN-режиме, чтобы дальнейшее переключение между
  // xhttp-серверами было чистым Clash API selector switch без единого килла.
  Future<void> _ensureAllXrayBridgesRunning() async {
    final xrayServers = _servers.where((s) => s.engine == 'xray').toList();
    for (final server in xrayServers) {
      await _ensureXrayBridge(server);
    }
  }

  void _stopAllXrayBridges() {
    for (final process in _xrayBridgeProcesses.values) {
      process.kill();
    }
    _xrayBridgeProcesses.clear();
  }

  // Остановка обязана быть асинхронной и дожидаться возврата прокси.
  // Раньше она запускала восстановление вдогонку, и в логе получалось:
  //   Ядро остановлено -> Системный прокси ВКЛЮЧЁН -> прокси возвращён,
  // потому что включение из ещё не завершившегося старта приходило уже после
  // остановки. Со стороны это и выглядело как «нажал Остановить, а не
  // остановилось»: ядро умирало, но система оставалась с нашим прокси.
  Future<void> _stopCore() async {
    if (mounted) setState(() => _busy = true);
    try {
      await _stopCoreInner();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopCoreInner() async {
    _stopRequested = true;
    if (Env.isAndroid) {
      await AndroidVpn.stop();
      // Опрос статистики гасит сеттер `_runningEngine`.
      _runningEngine = null;
      _unhealthy.clear();
      _rescheduleHealthCheck();
      _appendLog(t('log.coreStopped'));
      if (mounted) setState(() => _statsText = "");
      return;
    }
    _coreProcess?.kill();
    _xrayProcess?.kill();
    _stopAllXrayBridges();
    _runningEngine = null;
    // Метки «плохой сервер» живут в пределах сеанса: причина могла быть
    // временной, и тащить приговор в следующее подключение незачем.
    _unhealthy.clear();
    _rescheduleHealthCheck();
    _refreshTrayMenu();
    await _restoreSystemProxy();
    _appendLog(t('log.coreStopped'));
    if (mounted) setState(() => _statsText = "");
  }

  Future<void> _switchServer(ParsedServer newServer) async {
    setState(() => _selectedServer = newServer);

    // Выбор в списке — это ВЫБОР, а не команда подключиться.
    //
    // Раньше нажатие на сервер при выключенном щите доходило до `_startCore()`
    // и поднимало соединение. Человек листает список, чтобы посмотреть или
    // отметить сервер на будущее, — а приложение молча включает VPN, рвя
    // живые соединения браузера и мессенджеров. Подключение начинается по
    // нажатию на щит, и ни от чего другого.
    //
    // Когда ядро УЖЕ работает, смысл нажатия обратный: человек просит
    // перевести текущее соединение на другой сервер, и это ниже.
    if (_runningEngine == null) {
      _appendLog(tp('log.serverPicked', {'name': newServer.name}));
      return;
    }

    _appendLog(tp('log.switching', {'name': newServer.name}));

    if (_tunMode) {
      // TUN держит sing-box с адаптером живым постоянно, а мосты для ВСЕХ
      // xhttp-серверов уже подняты заранее (см. _startCore) — переключение
      // между ЛЮБЫМИ серверами идёт через Clash API selector, без единого
      // рестарта процессов. Эта проверка — просто подстраховка на случай,
      // если конкретный мост почему-то не поднялся или упал.
      if (newServer.engine == 'xray') {
        await _ensureXrayBridge(newServer);
      }
      if (_runningEngine == 'singbox' && _coreIsLive) {
        final tag = newServer.outbound['tag'] as String;
        try {
          final resp = await http
              .put(
                Uri.parse('$_clashApiBase/proxies/proxy'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'name': tag}),
              )
              .timeout(const Duration(seconds: 3));
          if (resp.statusCode == 204 || resp.statusCode == 200) {
            _appendLog(tp('log.active', {'name': newServer.name}));
            return;
          }
          _appendLog(tp('log.clashApiStatus', {'code': resp.statusCode}));
        } catch (e) {
          _appendLog(tp('log.clashApiUnreachable', {'e': e}));
        }
      }
      await _startCore();
      return;
    }

    // мгновенное переключение через Clash API работает только когда уже
    // крутится sing-box и новый сервер тоже на sing-box — иначе (первый
    // запуск, переход между движками) нужен полный рестарт нужного ядра
    if (_runningEngine == 'singbox' && newServer.engine == 'singbox' && _coreIsLive) {
      final tag = newServer.outbound['tag'] as String;
      try {
        final resp = await http
            .put(
              Uri.parse('$_clashApiBase/proxies/proxy'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'name': tag}),
            )
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode == 204 || resp.statusCode == 200) {
          _appendLog(tp('log.active', {'name': newServer.name}));
          return;
        }
        _appendLog(tp('log.clashApiStatus', {'code': resp.statusCode}));
      } catch (e) {
        _appendLog(tp('log.clashApiUnreachable', {'e': e}));
      }
    }

    await _startCore();
  }

  Future<void> _fetchStats() async {
    // Ядро не работает — спрашивать нечего и жаловаться не на что. Без этой
    // проверки после падения ядра на экране повисало красное «API недоступен:
    // TimeoutException», хотя человек видел выключенный щит: сообщение об
    // ошибке там, где ошибки нет, только сбивает с толку.
    if (_runningEngine == null) {
      _statsTimer?.cancel();
      _statsTimer = null;
      if (mounted && _statsText.isNotEmpty) setState(() => _statsText = '');
      return;
    }
    try {
      final versionResp = await http.get(Uri.parse('$_clashApiBase/version')).timeout(const Duration(seconds: 2));
      final connectionsResp = await http.get(Uri.parse('$_clashApiBase/connections')).timeout(const Duration(seconds: 2));

      // Ответ есть, но не 200 — это НЕ повод молчать.
      //
      // Раньше здесь стоял голый `if` без ветки else: ядро отвечает отказом, а
      // панель остаётся пустой, то есть показывает «Нет данных» — ровно то же,
      // что и при неподнятом опросе. Два разных состояния выглядели одинаково,
      // и разобрать по экрану, что именно сломалось, было нельзя.
      if (versionResp.statusCode != 200 || connectionsResp.statusCode != 200) {
        final code = versionResp.statusCode != 200
            ? versionResp.statusCode
            : connectionsResp.statusCode;
        if (mounted) {
          setState(() => _statsText = tp('stats.apiStatus', {'code': code}));
        }
        return;
      }
      {
        final connectionsJson = jsonDecode(connectionsResp.body);
        final downloadTotal = connectionsJson['downloadTotal'] ?? 0;
        final uploadTotal = connectionsJson['uploadTotal'] ?? 0;
        final activeConnections = (connectionsJson['connections'] as List?)?.length ?? 0;
        _statsFails = 0;
        if (!mounted) return;

        setState(() {
          // Одной строкой, а не четырьмя: имя сервера уже написано под щитом,
          // а четыре строки на низком окне выдавливали переключатель TUN за
          // край и заставляли прокручивать главный экран.
          _statsText = '${t('stat.connections')}: $activeConnections   '
              '↓ ${_formatBytes(downloadTotal)}   ↑ ${_formatBytes(uploadTotal)}';
        });
      }
    } catch (e) {
      // Первый промах молчим: опрос заводится в тот же миг, когда ядро
      // объявлено запущенным, а слушать порт оно начинает чуть позже — и на
      // экране успевала мигнуть ошибка там, где через две секунды всё в
      // порядке. Со второго промаха подряд это уже состояние, а не заминка.
      _statsFails++;
      if (_statsFails < 2 || !mounted) return;
      setState(() => _statsText = tp('stats.apiDown', {'e': e}));
    }
  }

  // Тест задержки ВСЕГДА идёт через отдельные пробные процессы на служебных
  // портах (17390+), а не через основной 1337 — иначе тест бы убивал и
  // перезапускал уже рабочее соединение пользователя (ровно так один раз
  // и сломалось на живую при ручном тестировании).
  // Протоколы поверх UDP/QUIC — их порт TCP-подключений не принимает,
  // поэтому режим «до сервера» к ним неприменим.
  static const Set<String> _udpOnlyProtocols = {'hysteria2', 'hysteria', 'tuic'};

  /// Сколько проверок держим одновременно.
  ///
  /// Раньше тест запускался по всем серверам разом (`Future.wait` по всему
  /// списку). На подписке из десятка это незаметно, а на подписке из двух сотен
  /// — двести одновременных соединений через одно пробное ядро: они мешают друг
  /// другу, половина упирается в таймаут, и живые серверы объявляются
  /// недоступными. Само по себе это было «неточно», а вместе со скрытием
  /// непрошедших проверку становится прямым враньём: рабочий сервер исчезает
  /// из списка.
  ///
  /// Двенадцать — компромисс: 200 серверов при таймауте по умолчанию
  /// проверяются заметно быстрее, чем по одному, и при этом не толкаются.
  static const int _latencyConcurrency = 12;

  /// `Future.wait` с ограничением на число одновременных задач.
  Future<void> _runLimited<T>(
      Iterable<T> items, Future<void> Function(T) body) async {
    final queue = items.toList();
    var next = 0;
    Future<void> worker() async {
      while (true) {
        // Отмену проверяем ЗДЕСЬ, между задачами, а не внутри каждой проверки:
        // уже начатая доигрывается до своего таймаута (оборвать её на середине
        // нечем), а очередь дальше не разбирается. На двух сотнях серверов это
        // разница между «отменилось сразу» и «отменится через минуту».
        if (_cancelLatency) return;
        final index = next++;
        if (index >= queue.length) return;
        await body(queue[index]);
      }
    }

    final workers = <Future<void>>[];
    final count =
        queue.length < _latencyConcurrency ? queue.length : _latencyConcurrency;
    for (var i = 0; i < count; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
  }

  Future<void> _testAllLatencies() async {
    if (_servers.isEmpty || _testingLatency) return;

    // Флаг снимаем на входе, а не на выходе: прошлый прогон мог завершиться
    // отменой, и оставленный флаг погасил бы следующий тест на первой же
    // задаче — кнопка «Тест задержки» переставала бы работать вовсе.
    _cancelLatency = false;
    _appendLog(tp('log.latencyStart', {'n': _servers.length}));

    setState(() {
      _testingLatency = true;
      for (final s in _servers) {
        _latencyMs[s.outbound['tag'] as String] = null;
      }
    });

    if (!Env.canSpawnProbeCores) {
      await _testLatenciesWithoutProbes();
    } else if (_settings.latencyMode == 'warm') {
      await _testLatenciesWarm(_servers);
    } else if (_settings.latencyMode == 'connect') {
      // Hysteria2 работает поверх QUIC, то есть по UDP: его порт TCP-соединения
      // не принимает вообще (проверено — connect к нему падает мгновенно, тогда
      // как к VLESS проходит за 0.1 с). Такие серверы TCP-проверкой не измерить
      // в принципе, поэтому для них поднимаем пробное ядро, как в сквозном режиме.
      final udpOnly = _servers.where((s) => _udpOnlyProtocols.contains(s.protocol)).toList();
      final tcpAble = _servers.where((s) => !_udpOnlyProtocols.contains(s.protocol)).toList();
      await Future.wait([
        if (tcpAble.isNotEmpty) _testLatenciesByConnect(tcpAble),
        if (udpOnly.isNotEmpty) _testSingboxLatencies(udpOnly),
      ]);
    } else {
      final singboxServers = _servers.where((s) => s.engine == 'singbox').toList();
      final xrayServers = _servers.where((s) => s.engine == 'xray').toList();

      await Future.wait([
        if (singboxServers.isNotEmpty) _testSingboxLatencies(singboxServers),
        if (xrayServers.isNotEmpty) _testXrayLatencies(xrayServers),
      ]);
    }

    if (mounted) setState(() => _testingLatency = false);
    final summary = _servers.map((s) {
      final v = _latencyMs[s.outbound['tag']];
      return '${s.name}=${v != null ? tp('log.ms', {'v': v}) : t('log.unreachable')}';
    }).join(', ');
    _appendLog(tp('log.latencyDone', {'summary': summary}));
  }

  /// Замер задержки там, где нельзя запустить пробное ядро (Android).
  ///
  /// На Windows тест поднимает служебные процессы на портах 17390+ и меряет
  /// сквозной путь, не трогая рабочее соединение. На Android чужие
  /// исполняемые файлы запускать нельзя вовсе, а ядро там одно и оно занято
  /// туннелем. Отсюда два пути, и выбор между ними не вопрос вкуса:
  ///
  /// 1. Туннель поднят — спрашиваем РАБОТАЮЩЕЕ ядро через Clash API. Это
  ///    честный сквозной замер через сам протокол, тот же, что даёт режим
  ///    `proxy` на Windows, и активное соединение он не рвёт.
  /// 2. Туннеля нет — меряем время TCP-подключения до сервера. Ядро для
  ///    этого не нужно совсем.
  ///
  /// Величины разные, и это надо понимать: первая включает работу протокола
  /// и путь до проверочного сайта (сотни миллисекунд), вторая — только
  /// сетевую доступность сервера (десятки). Сравнивать серверы между собой
  /// можно и той, и другой — лишь бы в пределах одного прогона.
  ///
  /// Протоколы поверх UDP (Hysteria2, TUIC) вторым способом не измеряются
  /// в принципе: их порт TCP-соединений не принимает. Без работающего ядра
  /// они останутся без цифры — это честнее, чем показать заведомо
  /// бессмысленное «недоступен».
  Future<void> _testLatenciesWithoutProbes() async {
    if (_runningEngine != null) {
      final timeoutMs = _settings.latencyTimeoutMs;
      final url = _settings.latencyUrl;
      await _runLimited(_servers, (s) async {
        final tag = s.outbound['tag'] as String;
        try {
          final resp = await http
              .get(Uri.parse('$_clashApiBase/proxies/$tag/delay'
                  '?url=${Uri.encodeComponent(url)}&timeout=$timeoutMs'))
              .timeout(Duration(milliseconds: timeoutMs + 1000));
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            if (mounted) setState(() => _latencyMs[tag] = data['delay'] as int);
          } else {
            // Неуспех Clash API раньше не писал в лог НИЧЕГО: исключения
            // ловились, а честный отказ ядра проходил молча. Три сервера из
            // пяти падали без единой строки, и на поиск причины ушёл лишний
            // круг — при том что ядро прямо в ответе объясняет, что не так.
            _appendLog(tp('log.latencyError',
                {'name': tag, 'e': 'HTTP ${resp.statusCode} ${resp.body.trim()}'}));
          }
        } catch (e) {
          _appendLog(tp('log.latencyError', {'name': s.name, 'e': e}));
        }
      });
      return;
    }

    final tcpAble =
        _servers.where((s) => !_udpOnlyProtocols.contains(s.protocol)).toList();
    final udpOnly =
        _servers.where((s) => _udpOnlyProtocols.contains(s.protocol)).toList();
    if (tcpAble.isNotEmpty) await _testLatenciesByConnect(tcpAble);
    if (udpOnly.isNotEmpty) {
      _appendLog(tp('log.latencyUdpSkipped', {'n': udpOnly.length}));
    }
  }

  // Хост и порт самого сервера. У sing-box-outbound лежат прямо в полях,
  // у Xray-outbound — внутри settings.vnext[] (vless/vmess) или
  // settings.servers[] (trojan).
  (String, int)? _serverEndpoint(ParsedServer s) {
    if (s.engine == 'singbox') {
      final host = s.outbound['server'];
      final port = s.outbound['server_port'];
      return (host is String && port is int) ? (host, port) : null;
    }
    final settings = s.outbound['settings'];
    if (settings is! Map) return null;
    for (final key in const ['vnext', 'servers']) {
      final list = settings[key];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final m = list.first as Map;
        final host = m['address'];
        final port = m['port'];
        if (host is String && port is int) return (host, port);
      }
    }
    return null;
  }

  // Режим "как в Karing": время TCP-рукопожатия до сервера. Не поднимает ни
  // одного процесса, поэтому тест всех серверов занимает доли секунды.
  Future<void> _testLatenciesByConnect(List<ParsedServer> servers) async {
    await _runLimited(servers, (s) async {
      final tag = s.outbound['tag'] as String;
      final endpoint = _serverEndpoint(s);
      if (endpoint == null) return;
      try {
        final sw = Stopwatch()..start();
        final socket = await Socket.connect(
          endpoint.$1,
          endpoint.$2,
          timeout: Duration(milliseconds: _settings.latencyTimeoutMs),
        );
        sw.stop();
        socket.destroy();
        if (mounted) setState(() => _latencyMs[tag] = sw.elapsedMilliseconds);
      } catch (e) {
        _appendLog(tp('log.latencyError', {'name': s.name, 'e': e}));
      }
    });
  }

  // Режим «как в Karing»: соединение устанавливается ВНЕ замера, секундомер
  // запускается только на самом запросе. Разобрано по их ядру — там start
  // сбрасывается после того, как соединение поднято, и запрос идёт методом
  // HEAD. Отсюда их 25 мс против наших 400: у нас в цифру входили рукопожатие
  // с сервером и TLS до проверочного адреса.
  //
  // Реализовано через один пробный sing-box со всеми серверами в селекторе:
  // переключаем селектор через Clash API и меряем по уже открытому каналу.
  Future<void> _testLatenciesWarm(List<ParsedServer> servers) async {
    const probePort = 17390;
    const probeApiPort = 17391;
    final singbox = servers.where((s) => s.engine == 'singbox').toList();
    final xray = servers.where((s) => s.engine == 'xray').toList();

    // Xray-серверы и так меряются по прогретому соединению — переиспользуем.
    if (xray.isNotEmpty) await _testXrayLatencies(xray);
    if (singbox.isEmpty) return;

    final probeConfigPath = '$_workDir${Platform.pathSeparator}singbox_probe.json';
    final tags = singbox.map((s) => s.outbound['tag'] as String).toList();
    final config = {
      "log": {"level": "warn"},
      "experimental": {
        "clash_api": {"external_controller": "127.0.0.1:$probeApiPort"}
      },
      "inbounds": [
        {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": probePort}
      ],
      "outbounds": [
        ...singbox.map((s) => s.outbound),
        {"type": "selector", "tag": "probe", "outbounds": tags, "default": tags.first},
        // direct нужен резолверу: без него `dns-direct` не к чему привязать.
        {"type": "direct", "tag": "direct"},
      ],
      ..._probeDnsAndRoute(),
    };
    await File(probeConfigPath).writeAsString(const JsonEncoder.withIndent('  ').convert(config));

    Process? probe;
    try {
      probe = await Process.start(_singBoxPath, ['run', '-c', probeConfigPath]);
      _probeProcesses.add(probe);
      _watchProbeErrors(probe, 'sing-box');
      if (!await _waitForPort(probeApiPort)) {
        _appendLog(tp('log.probePortBusy', {'port': probeApiPort}));
        return;
      }
      final timeout = Duration(milliseconds: _settings.latencyTimeoutMs + 1000);
      for (final server in singbox) {
        final tag = server.outbound['tag'] as String;
        try {
          await http
              .put(Uri.parse('http://127.0.0.1:$probeApiPort/proxies/probe'),
                  body: jsonEncode({'name': tag}))
              .timeout(const Duration(seconds: 4));

          final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$probePort';
          try {
            // Первый запрос поднимает канал и в замер НЕ входит.
            final warm = await client.getUrl(Uri.parse(_settings.latencyUrl)).timeout(timeout);
            await (await warm.close().timeout(timeout)).drain();

            final sw = Stopwatch()..start();
            final req = await client.getUrl(Uri.parse(_settings.latencyUrl)).timeout(timeout);
            await (await req.close().timeout(timeout)).drain();
            sw.stop();
            if (mounted) setState(() => _latencyMs[tag] = sw.elapsedMilliseconds);
          } finally {
            client.close(force: true);
          }
        } catch (e) {
          _appendLog(tp('log.latencyError', {'name': server.name, 'e': e}));
        }
      }
    } catch (e) {
      _appendLog(tp('log.probeFailed', {'e': e}));
    } finally {
      probe?.kill();

      if (probe != null) _probeProcesses.remove(probe);
    }
  }

  Future<void> _testSingboxLatencies(List<ParsedServer> servers) async {
    const probePort = 17390;
    const probeApiPort = 17391;
    final probeConfigPath = '$_workDir${Platform.pathSeparator}singbox_probe.json';
    final tags = servers.map((s) => s.outbound['tag'] as String).toList();

    final selector = {
      "type": "selector",
      "tag": "probe",
      "outbounds": tags,
      "default": tags.first,
    };
    final config = {
      "log": {"level": "warn"},
      "experimental": {
        "clash_api": {"external_controller": "127.0.0.1:$probeApiPort"}
      },
      "inbounds": [
        {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": probePort}
      ],
      "outbounds": [
        ...servers.map((s) => s.outbound),
        selector,
        // direct нужен резолверу: без него `dns-direct` не к чему привязать.
        {"type": "direct", "tag": "direct"},
      ],
      ..._probeDnsAndRoute(),
    };
    await File(probeConfigPath).writeAsString(const JsonEncoder.withIndent('  ').convert(config));

    Process? probe;
    try {
      probe = await Process.start(_singBoxPath, ['run', '-c', probeConfigPath]);
      _probeProcesses.add(probe);
      _watchProbeErrors(probe, 'sing-box');
      if (!await _waitForPort(probeApiPort)) {
        _appendLog(tp('log.probeSingboxPortBusy', {'port': probeApiPort}));
        return;
      }

      final testUrl = _settings.latencyUrl;
      final timeoutMs = _settings.latencyTimeoutMs;
      final httpTimeout = Duration(milliseconds: timeoutMs + 1000);
      Uri delayUri(String tag) => Uri.parse(
          'http://127.0.0.1:$probeApiPort/proxies/$tag/delay?url=${Uri.encodeComponent(testUrl)}&timeout=$timeoutMs');
      await _runLimited(tags, (tag) async {
        try {
          // Clash-эндпоинт /delay на каждый вызов открывает новое соединение,
          // так что "прогревать" тут почти нечего — прогон помогает разве что
          // резолвом DNS. Поэтому он отключаемый: без него тест вдвое быстрее.
          if (_settings.latencyWarmup) {
            await http.get(delayUri(tag)).timeout(httpTimeout);
          }
          final resp = await http.get(delayUri(tag)).timeout(httpTimeout);
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            if (mounted) setState(() => _latencyMs[tag] = data['delay'] as int);
          } else {
            // Неуспех Clash API раньше не писал в лог НИЧЕГО: исключения
            // ловились, а честный отказ ядра проходил молча. Три сервера из
            // пяти падали без единой строки, и на поиск причины ушёл лишний
            // круг — при том что ядро прямо в ответе объясняет, что не так.
            _appendLog(tp('log.latencyError',
                {'name': tag, 'e': 'HTTP ${resp.statusCode} ${resp.body.trim()}'}));
          }
        } catch (e) {
          _appendLog(tp('log.latencyError', {'name': tag, 'e': e}));
        }
      });
    } catch (_) {
      // пробное ядро не поднялось — все теги этой группы останутся null
    } finally {
      probe?.kill();

      if (probe != null) _probeProcesses.remove(probe);
    }
  }

  // Замер через уже поднятый HTTP-прокси на порту `port`. Вынесено из
  // _testXrayLatencies, потому что этим же кодом меряет и запасной путь
  // «по одному серверу», и общий пробный процесс.
  //
  // Прогрев здесь, в отличие от sing-box-ветки, работает по-настоящему:
  // HttpClient переиспользует соединение, поэтому первый запрос платит за
  // холодный хендшейк (TCP+Reality/TLS+XHTTP-сессия), а второй идёт по
  // готовому каналу и показывает задержку обычного сёрфинга.
  Future<int?> _measureViaHttpProxy(int port, String name) async {
    final testUrl = _settings.latencyUrl;
    final reqTimeout = Duration(milliseconds: _settings.latencyTimeoutMs + 1000);
    final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      if (_settings.latencyWarmup) {
        final warmupReq = await client.getUrl(Uri.parse(testUrl)).timeout(reqTimeout);
        final warmupResp = await warmupReq.close().timeout(reqTimeout);
        await warmupResp.drain();
      }

      // Замер с одной повторной попыткой на СВЕЖЕМ соединении. Прогрев
      // оставляет соединение открытым, но не всякий прокси его переживает
      // (обычный HTTP через Xray — не переживает), и тогда второй запрос
      // по тому же клиенту падает. Пересоздание клиента это лечит, поэтому
      // чужая ссылка в настройках больше не сможет обнулить весь тест.
      int? elapsed;
      Object? lastError;
      for (var attempt = 0; attempt < 2 && elapsed == null; attempt++) {
        final c = attempt == 0
            ? client
            : (HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port');
        try {
          final stopwatch = Stopwatch()..start();
          final req = await c.getUrl(Uri.parse(testUrl)).timeout(reqTimeout);
          final resp = await req.close().timeout(reqTimeout);
          await resp.drain();
          stopwatch.stop();
          elapsed = stopwatch.elapsedMilliseconds;
        } catch (e) {
          lastError = e;
        } finally {
          if (attempt > 0) c.close(force: true);
        }
      }
      if (elapsed == null) throw lastError ?? Exception(t('lat.failed'));
      return elapsed;
    } catch (e) {
      // Раньше ошибка глоталась молча, и «недоступен» ничего не объяснял —
      // на разбор одного такого случая ушёл целый заход. Теперь видно причину.
      _appendLog(tp('log.latencyError', {'name': name, 'e': e}));
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Все xray-серверы меряются ОДНИМ пробным процессом и одновременно.
  ///
  /// Раньше здесь был цикл: на каждый сервер поднимался свой `xray.exe` на
  /// общем порту 17392, замер, убийство процесса и 300 мс на остывание порта.
  /// Пять xhttp-серверов пользователя занимали так около шести секунд из
  /// семи, которые уходили на весь тест, — при том что sing-box-ветка рядом
  /// давно мерила свои девять серверов разом.
  ///
  /// Теперь конфиг один: у каждого сервера свой HTTP-вход на своём порту и
  /// правило маршрутизации `inboundTag -> outboundTag`. Процесс поднимается
  /// один раз, замеры идут параллельно. Это тот же приём, что у sing-box,
  /// только там роль отдельных входов играет переключаемый селектор.
  ///
  /// Побочный эффект честно оговорим: соединения устанавливаются
  /// одновременно и делят один канал, поэтому цифры могут оказаться чуть
  /// выше, чем при замере в одиночку. Сравнивать серверы между собой это не
  /// мешает — условия у всех одинаковые, — а sing-box-ветка так мерила всегда.
  static const int _xrayProbeBasePort = 17400;

  Future<void> _testXrayLatencies(List<ParsedServer> servers) async {
    final probeConfigPath = '$_workDir${Platform.pathSeparator}xray_probe.json';
    final ports = <String, int>{
      for (var i = 0; i < servers.length; i++)
        servers[i].outbound['tag'] as String: _xrayProbeBasePort + i,
    };

    final config = {
      "log": {"loglevel": "warning"},
      "inbounds": [
        for (final s in servers)
          {
            "listen": "127.0.0.1",
            "port": ports[s.outbound['tag']],
            "protocol": "http",
            "tag": "probe_in_${s.outbound['tag']}",
          }
      ],
      "outbounds": [...servers.map((s) => s.outbound)],
      "routing": {
        "rules": [
          for (final s in servers)
            {
              "type": "field",
              "inboundTag": ["probe_in_${s.outbound['tag']}"],
              "outboundTag": s.outbound['tag'],
            }
        ]
      },
    };
    await File(probeConfigPath)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(config));

    Process? probe;
    try {
      probe = await Process.start(_xrayPath, ['run', '-c', probeConfigPath]);
      _probeProcesses.add(probe);
      // Ошибки пробного ядра — В ЖУРНАЛ, а не в /dev/null.
      //
      // Дартовая сторона видит только `HandshakeException: Connection
      // terminated during handshake` — то есть «не получилось», без единого
      // слова о причине. А ядро в этот самый момент печатает у себя точную
      // формулировку:
      //
      //   [Error] transport/internet/reality: REALITY: received real
      //   certificate (potential MITM or redirection)
      //
      // На выяснение этой строки ушёл отдельный разбор с запуском ядра
      // вручную — при том что приложение держало её в руках и выбрасывало.
      // Берём только строки с ошибками: Xray на старте пишет несколько
      // предупреждений про устаревшие VMess/Trojan, и тащить их в журнал
      // при каждом тесте незачем.
      _watchProbeErrors(probe, 'xray');

      // Ждём входы параллельно, а не по очереди: последовательное ожидание
      // с таймаутом 5 с на порт вернуло бы ту же арифметику, от которой
      // мы здесь и уходим.
      final ready = <ParsedServer>[];
      await _runLimited(servers, (s) async {
        if (await _waitForPort(ports[s.outbound['tag']]!)) ready.add(s);
      });

      // Ни один вход не поднялся — почти наверняка ядро вообще не стартовало
      // (одного нерабочего outbound хватает, чтобы Xray отказался читать весь
      // конфиг). Тогда честно откатываемся на прежний путь по одному серверу:
      // он медленный, но у него сбоит ровно тот сервер, который сломан, а не
      // все сразу.
      if (ready.isEmpty) {
        probe.kill();
        probe = null;
        await Future.delayed(const Duration(milliseconds: 300));
        await _testXrayLatenciesOneByOne(servers);
        return;
      }

      for (final s in servers) {
        if (!ready.contains(s)) {
          _appendLog(tp('log.probeXrayPortBusy',
              {'name': s.name, 'port': ports[s.outbound['tag']]!}));
        }
      }

      await _runLimited(ready, (s) async {
        final tag = s.outbound['tag'] as String;
        final elapsed = await _measureViaHttpProxy(ports[tag]!, s.name);
        if (elapsed != null && mounted) {
          setState(() => _latencyMs[tag] = elapsed);
        }
      });
    } catch (e) {
      _appendLog(tp('log.latencyError', {'name': 'xray', 'e': e}));
    } finally {
      probe?.kill();

      if (probe != null) _probeProcesses.remove(probe);
    }
  }

  /// Запасной путь: по серверу за раз, каждый со своим процессом на общем
  /// порту. Держится ради изоляции сбоев — если общий конфиг не принимается
  /// ядром целиком, здесь отвалится только виновный сервер.
  Future<void> _testXrayLatenciesOneByOne(List<ParsedServer> servers) async {
    const probePort = 17392;
    final probeConfigPath = '$_workDir${Platform.pathSeparator}xray_probe_single.json';

    for (final server in servers) {
      final tag = server.outbound['tag'] as String;
      final config = {
        "log": {"loglevel": "warning"},
        "inbounds": [
          {"listen": "127.0.0.1", "port": probePort, "protocol": "http"}
        ],
        "outbounds": [server.outbound],
      };
      await File(probeConfigPath)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(config));

      Process? probe;
      try {
        probe = await Process.start(_xrayPath, ['run', '-c', probeConfigPath]);
      _probeProcesses.add(probe);
        if (!await _waitForPort(probePort)) {
          _appendLog(tp('log.probeXrayPortBusy',
              {'name': server.name, 'port': probePort}));
          continue;
        }
        final elapsed = await _measureViaHttpProxy(probePort, server.name);
        if (elapsed != null && mounted) {
          setState(() => _latencyMs[tag] = elapsed);
        }
      } catch (e) {
        _appendLog(tp('log.latencyError', {'name': server.name, 'e': e}));
      } finally {
        probe?.kill();

        if (probe != null) _probeProcesses.remove(probe);
        // Xray у xhttp иногда чуть задерживает освобождение сокета — даём
        // порту остыть перед следующим прогоном.
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  // Серверы, участвующие в авто-выборе: фильтр по подстроке в названии
  // (регистр не важен) и ограничение сверху. Пустой фильтр и лимит 0 —
  // значит участвуют все.
  List<ParsedServer> _autoSelectCandidates() {
    final filter = _settings.autoSelectFilter.trim().toLowerCase();
    var list = filter.isEmpty
        ? List<ParsedServer>.from(_servers)
        : _servers.where((s) => s.name.toLowerCase().contains(filter)).toList();
    // Избранные первыми — важно ДО применения лимита: иначе лимит мог бы
    // отрезать как раз те серверы, которые пользователь пометил звёздочкой.
    if (_settings.autoSelectFavFirst && _favorites.isNotEmpty) {
      final favorites = list.where((s) => _favorites.contains(s.name)).toList();
      final rest = list.where((s) => !_favorites.contains(s.name)).toList();
      list = [...favorites, ...rest];
    }
    final limit = _settings.autoSelectLimit;
    if (limit > 0 && list.length > limit) list = list.sublist(0, limit);
    return list;
  }

  Future<void> _autoSelectBest({bool silent = false}) async {
    await _testAllLatencies();

    final candidates = _autoSelectCandidates();
    if (candidates.isEmpty) {
      _appendLog(tp('log.autoSelectNoMatch',
          {'filter': _settings.autoSelectFilter}));
      return;
    }

    final reachable = candidates.where((s) => _latencyMs[s.outbound['tag']] != null).toList();
    if (reachable.isEmpty) {
      _appendLog(t('log.autoSelectNoReply'));
      return;
    }

    reachable.sort((a, b) => _latencyMs[a.outbound['tag']]!.compareTo(_latencyMs[b.outbound['tag']]!));
    final best = reachable.first;
    final bestMs = _latencyMs[best.outbound['tag']]!;

    // Допуск: если текущий сервер отстаёт от лучшего меньше чем на tolerance,
    // не дёргаем соединение ради пары миллисекунд — переключение рвёт живые
    // сессии, и на глаз это заметнее, чем выигрыш в задержке.
    final currentMs = _selectedServer != null ? _latencyMs[_selectedServer!.outbound['tag']] : null;
    if (_selectedServer != null &&
        currentMs != null &&
        currentMs - bestMs <= _settings.tolerance) {
      if (!silent) {
        _appendLog(tp('log.autoSelectKeep', {
          'name': _selectedServer!.name,
          'ms': currentMs,
          'best': best.name,
          'bestMs': bestMs,
          'tol': _settings.tolerance,
        }));
      }
      return;
    }

    _appendLog(tp('log.autoSelectResult', {'name': best.name, 'ms': bestMs}));
    await _switchServer(best);
  }

  // --- Проверка, что активный сервер реально работает ---
  //
  // Задача не та же, что у теста задержки. Тест меряет, ОТЗЫВАЕТСЯ ли сервер,
  // и делает это до короткого 204-эндпоинта. Здесь проверяется, проходит ли
  // через него настоящий запрос к настоящему сайту: сервер с прекрасным
  // пингом может не открывать YouTube — упирается в лимит, режет направление
  // или отваливается на первом же полноценном TLS.
  void _rescheduleHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _healthFails = 0;
    if (!_settings.healthCheckEnabled || _runningEngine == null) return;
    final secs = _settings.healthCheckIntervalSec;
    if (secs <= 0) return;
    _healthTimer =
        Timer.periodic(Duration(seconds: secs), (_) => _runHealthCheck());
  }

  Future<void> _runHealthCheck() async {
    // Во время запуска и остановки проверять нечего: ядро как раз меняется
    // под нами, и провал означал бы только это.
    if (_runningEngine == null || _busy || _stopRequested) return;

    if (await _probeActiveServer()) {
      if (_healthFails > 0) _appendLog(t('log.healthRecovered'));
      _healthFails = 0;
      return;
    }

    _healthFails++;
    _appendLog(tp('log.healthFailed', {
      'name': _selectedServer?.name ?? '-',
      'n': _healthFails,
    }));
    // Долгий провал лечится ПЕРЕЗАПУСКОМ ядра, а не сменой сервера.
    //
    // Случай, ради которого это заведено: машина надолго осталась без сети
    // (спящий режим, отключённый кабель, уехавший Wi-Fi). Ядро при этом живо,
    // порт слушает, UI показывает «подключено» — но его сокеты умерли вместе с
    // прежним каналом, и когда сеть возвращается, оно не поднимается само.
    // Смена сервера тут не помогает: ходить некуда ни через один, и
    // `_switchAwayFromUnhealthy` честно перебирает весь список, помечает все
    // плохими, снимает метки и остаётся на месте — то есть крутится вхолостую,
    // пока человек не нажмёт «Остановить» и «Запустить» руками.
    //
    // Порог выше, чем у смены сервера, и намеренно: сначала пробуем дешёвое
    // (другой сервер), и только если и это не помогло — дорогое.
    if (_healthFails >= 4) {
      final now = DateTime.now();
      final last = _lastHealthRestart;
      // Не чаще раза в две минуты. Без ограничителя приложение при
      // по-настоящему отсутствующей сети перезапускало бы ядро на каждой
      // проверке — то есть непрерывно рвало бы то, что и так не работает,
      // и не дало бы соединению подняться, когда сеть наконец вернётся.
      if (last == null || now.difference(last) > const Duration(minutes: 2)) {
        _lastHealthRestart = now;
        _healthFails = 0;
        _appendLog(t('log.healthRestart'));
        await _startCore();
        return;
      }
    }

    // Один промах — это заминка сети, а не приговор серверу. Дёргать
    // соединение под человеком из-за одного неудачного запроса нельзя.
    if (_healthFails < 2 || !_settings.healthCheckAutoSwitch) return;
    await _switchAwayFromUnhealthy();
  }

  /// Когда в последний раз перезапускали ядро по проверке связи.
  DateTime? _lastHealthRestart;

  /// Настоящий запрос через ТЕКУЩЕЕ соединение. `true` — сервер живой.
  Future<bool> _probeActiveServer() async {
    final url = _settings.healthCheckUrl;
    final timeout = Duration(milliseconds: _settings.latencyTimeoutMs + 1000);

    // sing-box спрашиваем через его же Clash API: запрос уходит по текущему
    // выбранному outbound, и в TUN-режиме, и в обычном. Отдельного процесса
    // и порта не нужно, живое соединение не трогается.
    if (_runningEngine == 'singbox') {
      try {
        final resp = await http
            .get(Uri.parse('$_clashApiBase/proxies/proxy/delay'
                '?url=${Uri.encodeComponent(url)}'
                '&timeout=${_settings.latencyTimeoutMs}'))
            .timeout(timeout);
        // 200 — прошло. Недоступный адрес Clash отдаёт как ошибку, и это
        // ровно то, что мы ловим.
        return resp.statusCode == 200;
      } catch (_) {
        return false;
      }
    }

    // У Xray Clash API нет вообще — идём через локальный порт соединения.
    // Это тот же путь, которым ходит браузер, то есть проверка честная.
    final client = HttpClient()
      ..findProxy = (_) => 'PROXY 127.0.0.1:${_settings.localPort}';
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final resp = await req.close().timeout(timeout);
      await resp.drain();
      return resp.statusCode >= 200 && resp.statusCode < 400;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _switchAwayFromUnhealthy() async {
    final current = _selectedServer;
    if (current != null) _unhealthy.add(current.name);

    // Кандидаты — всё, что ещё не завалило проверку, лучший по измеренной
    // задержке первым. Неизмеренные уходят в конец: про них ничего не
    // известно, но они всё же лучше заведомо плохого.
    final candidates =
        _servers.where((s) => !_unhealthy.contains(s.name)).toList()
          ..sort((a, b) {
            final la = _latencyMs[a.outbound['tag']];
            final lb = _latencyMs[b.outbound['tag']];
            if (la == null && lb == null) return 0;
            if (la == null) return 1;
            if (lb == null) return -1;
            return la.compareTo(lb);
          });

    if (candidates.isEmpty) {
      // Плохими оказались все — значит причина общая (упал интернет,
      // отвалилась подписка), а не в серверах. Метки снимаем и остаёмся где
      // были: сидеть на сомнительном сервере лучше, чем метаться по кругу.
      _appendLog(t('log.healthAllBad'));
      _unhealthy.clear();
      _healthFails = 0;
      return;
    }

    final next = candidates.first;
    _appendLog(tp('log.healthSwitching',
        {'from': current?.name ?? '-', 'to': next.name}));
    _healthFails = 0;
    await _switchServer(next);
  }

  // Периодический авто-выбор. Пересоздаём таймер при каждом сохранении
  // настроек, иначе новый интервал не применится до перезапуска.
  void _rescheduleAutoSelect() {
    _autoSelectTimer?.cancel();
    final minutes = _settings.autoSelectIntervalMin;
    if (minutes <= 0) return;
    _autoSelectTimer = Timer.periodic(Duration(minutes: minutes), (_) {
      if (_servers.isEmpty || _testingLatency) return;
      _appendLog(tp('log.autoSelectScheduled', {'min': minutes}));
      _autoSelectBest(silent: true);
    });
  }

  // Строка о подписке под списком профилей. Показываем только то, что панель
  // реально прислала: на безлимитном тарифе (total=0) рисовать полосу остатка
  // и «осталось 0 Б» было бы враньём.
  Widget _profileUsage(SubscriptionProfile p) {
    if (p.used == 0 && !p.hasQuota && !p.hasExpiry) return const SizedBox.shrink();

    final parts = <String>["${t('sub.used')} ${_formatBytes(p.used)}"];
    if (p.hasQuota) parts.add("${t('sub.of')} ${_formatBytes(p.total)}");
    if (p.hasExpiry) {
      final until = DateTime.fromMillisecondsSinceEpoch(p.expire * 1000);
      final days = until.difference(DateTime.now()).inDays;
      parts.add(days >= 0
          ? tp('sub.untilDate', {
              'date': '${until.day}.${until.month.toString().padLeft(2, '0')}.${until.year}',
              'days': days,
            })
          : t('sub.expired'));
    } else {
      parts.add(t('sub.noExpiry'));
    }
    if (!p.hasQuota) parts.add(t('sub.unlimited'));
    if (p.lastUpdated > 0) {
      // Имя tm, а не t: t — функция перевода, локальная переменная её бы
      // перекрыла, и вызвать перевод внутри этого блока стало бы нельзя.
      final tm = DateTime.fromMillisecondsSinceEpoch(p.lastUpdated * 1000);
      String two(int n) => n.toString().padLeft(2, '0');
      parts.add("${t('sub.updated')} ${two(tm.day)}.${two(tm.month)} ${t('sub.at')} ${two(tm.hour)}:${two(tm.minute)}");
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.hasQuota)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: LinearProgressIndicator(
                value: (p.used / p.total).clamp(0.0, 1.0),
                minHeight: 4,
              ),
            ),
          Text(parts.join(' · '), style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  // Автообновление подписки. Интервал берём из заголовка Profile-Update-Interval,
  // который прислала сама панель, — она лучше знает, как часто её опрашивать.
  void _rescheduleSubscriptionUpdate() {
    _subUpdateTimer?.cancel();
    // Свой интервал важнее подсказки панели: пользователь мог поставить его
    // осознанно, а панель присылает одно и то же значение на всех клиентов.
    final hours = _settings.subUpdateIntervalHours > 0
        ? _settings.subUpdateIntervalHours
        : (_activeProfile?.updateIntervalHours ?? 0);
    if (hours <= 0 || !_settings.autoUpdateSubscription) return;
    _subUpdateTimer = Timer.periodic(Duration(hours: hours), (_) {
      final p = _activeProfile;
      if (p == null) return;
      _appendLog(tp('log.subAutoUpdate', {'name': p.name, 'hours': hours}));
      _loadSubscription(p);
    });
  }

  // Какое шифрование реально применяется. Для sing-box-outbound смотрим в
  // tls/reality, для Xray — в streamSettings.security. Пользователю важно
  // именно это, а не то, что написано в названии сервера.
  String _securityLabel(ParsedServer s) {
    if (s.engine == 'xray') {
      final ss = s.outbound['streamSettings'];
      if (ss is Map) {
        final sec = (ss['security'] as String?) ?? 'none';
        final net = (ss['network'] as String?) ?? 'tcp';
        return '${sec == 'none' ? t('home.noEncryption') : sec.toUpperCase()} · $net';
      }
      return 'Xray';
    }
    final tls = s.outbound['tls'];
    final transport = s.outbound['transport'];
    final net = transport is Map ? (transport['type'] as String? ?? 'tcp') : 'tcp';
    if (tls is Map && tls['enabled'] == true) {
      final reality = tls['reality'];
      final isReality = reality is Map && reality['enabled'] == true;
      return '${isReality ? 'REALITY' : 'TLS'} · $net';
    }
    return '${t('home.noEncryption')} · $net';
  }

  Widget _shieldBlock(double available) {
    final running = _runningEngine != null;
    final server = _selectedServer;
    final ms = server != null ? _latencyMs[server.outbound['tag']] : null;
    final scheme = Theme.of(context).colorScheme;

    // Под подписи, задержку и переключатель TUN нужно ~150 px; остальное
    // отдаём щиту, но не больше исходных 196 и не меньше 96 — ниже он
    // перестаёт читаться как кнопка.
    final shield = (available - 150).clamp(96.0, 196.0);
    // На низком окне ужимаем и отступы: из них набегает ещё полсотни пикселей.
    final tight = available < 380;

    return Column(
      children: [
        SizedBox(height: tight ? 0 : 6),
        ShieldPower(
          active: running,
          height: shield,
          busy: _busy,
          // Нажатие во время подключения ПРЕРЫВАЕТ его.
          //
          // Раньше клик на занятом щите просто проглатывался — защита от
          // повторных нажатий, из-за которых когда-то запускались два ядра
          // разом. Но у неё оказалась обратная сторона: подключение с
          // автовыбором идёт секундами, и всё это время передумать было
          // нельзя вообще никак — оставалось ждать конца того, что тебе уже
          // не нужно. Отмена — это не повторный запуск, двух ядер она не
          // создаёт: `_stopRequested` останавливает начатый старт на
          // ближайшей же проверке.
          onTap: _busy
              ? _cancelStart
              : () => running ? _stopCore() : _startCore(),
        ),
        SizedBox(height: tight ? 6 : 12),
        Text(
          _busy
              ? (running ? t('home.disconnecting') : t('home.connecting'))
              : (running ? t('home.protectedOn') : t('home.protectedOff')),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: running ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
        // Итог проверки — сразу под словом «Подключено», а не в логе.
        //
        // Именно здесь человек читает, в каком он состоянии, и именно здесь
        // раньше стояло обещание, которого никто не проверял.
        if (running && _connectionCheck.isNotEmpty) ...[
          SizedBox(height: tight ? 2 : 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _connectionCheck,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: _connectionOk ? scheme.primary : scheme.error,
              ),
            ),
          ),
        ],
        SizedBox(height: tight ? 2 : 6),
        if (server != null)
          Text(
            server.name,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
        SizedBox(height: tight ? 4 : 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (server != null) ...[
              Icon(Icons.lock_outline, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(_securityLabel(server),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(width: 16),
            ],
            Icon(Icons.speed, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text(
              '${ms ?? '—'} ${t('common.ms')}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ms == null
                    ? scheme.onSurfaceVariant
                    : (ms < 100 ? Colors.greenAccent : (ms < 300 ? Colors.amberAccent : Colors.redAccent)),
              ),
            ),
          ],
        ),
        // Честная надпись про охват. Обычный режим подменяет СИСТЕМНЫЙ ПРОКСИ,
        // а его читают не все: браузеры и Telegram — да, а программы на Node,
        // игры и часть мессенджеров ходят напрямую и о прокси не спрашивают.
        // Щит при этом зелёный и написано «Защищено».
        //
        // Стоило целого дня отладки: пользователь включал приложение, видел
        // «Protected», а его чат-клиент шёл мимо туннеля — и мы искали ошибку
        // в системном прокси, которого тот клиент вообще не читает. Пока UI
        // молчит про охват режима, эта история повторится с любой программой.
        // Показываем только при работающем ядре и только без TUN: именно тогда
        // человек считает, что защищён весь трафик.
        if (running && !_tunMode) ...[
          SizedBox(height: tight ? 6 : 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: scheme.tertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t('home.proxyModeCoverage'),
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ],
        SizedBox(height: tight ? 8 : 14),
        // TUN прямо под щитком: это главный переключатель режима работы, а не
        // настройка «на один раз». Держать его только на вкладке маршрутизации
        // значило заставлять лезть туда каждый раз, когда нужен системный VPN.
        // Компактная строка, а не SwitchListTile: щиток стоит по центру, и
        // растянутый на всю ширину список рядом с ним смотрится чужеродно.
        //
        // На Android переключателя нет вовсе, и это не упрощение интерфейса.
        // Там `VpnService` И ЕСТЬ TUN — другого способа увести трафик системы
        // не существует, выключить его значило бы выключить приложение.
        // Подпись про перезапуск от администратора тем более бессмысленна:
        // администратора в Android нет как понятия. Переключатель, который
        // ничего не переключает, — обещание возможности, которой нет.
        if (Env.hasWindowAndTray)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.vpn_lock,
                  size: 16,
                  color: _tunMode ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t('routing.tun'),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    Text(
                      _isAdmin ? t('home.tunHintShort') : t('home.tunNeedAdminShort'),
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(value: _tunMode, onChanged: _toggleTunMode),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  String _formatBytes(dynamic bytes) {
    final b = (bytes is int) ? bytes : int.tryParse(bytes.toString()) ?? 0;
    if (b < 1024) return '$b ${t('unit.b')}';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} ${t('unit.kb')}';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} ${t('unit.mb')}';
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    appLang.removeListener(_refreshTrayMenu);
    _coreProcess?.kill();
    _xrayProcess?.kill();
    _stopAllXrayBridges();
    // Подписку на состояние службы снимаем обязательно: служба переживает
    // экран, и оставленный слушатель дёргал бы setState у мёртвого виджета.
    _androidVpnSub?.cancel();
    _statsTimer?.cancel();
    _autoSelectTimer?.cancel();
    _healthTimer?.cancel();
    _subUpdateTimer?.cancel();
    _boundsSaveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Multik Sila'),
        actions: [
          IconButton(
            icon: const Icon(Icons.insights_outlined),
            tooltip: t('stats.title'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StatsScreen(
                  apiBase: _clashApiBase,
                  serverName: _selectedServer?.name,
                  tagNames: {
                    for (final s in _servers) s.outbound['tag'] as String: s.name,
                  },
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.swap_vert),
            tooltip: t('bar.connections'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConnectionsScreen(
                  apiBase: _clashApiBase,
                  // Теги вида srv_11 пользователю ничего не говорят —
                  // подставляем человеческие имена серверов.
                  tagNames: {
                    for (final s in _servers) s.outbound['tag'] as String: s.name,
                  },
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.medical_services_outlined),
            tooltip: t('bar.diagnostics'),
            onPressed: () {
              final endpoint =
                  _selectedServer != null ? _serverEndpoint(_selectedServer!) : null;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DiagnosticsScreen(
                    apiBase: _clashApiBase,
                    localPort: _settings.localPort,
                    tunMode: _tunMode,
                    coreRunning: _runningEngine != null,
                    serverHost: endpoint?.$1,
                    serverPort: endpoint?.$2,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.article_outlined),
            tooltip: t('bar.log'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => LogScreen(log: _log)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: t('bar.settings'),
            onPressed: () async {
              final updated = await Navigator.push<AppSettings>(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    initial: _settings,
                    onCheckCores: () => _checkCoreUpdates(silent: false),
                    onCheckApp: () => _checkAppUpdate(silent: false),
                  ),
                ),
              );
              if (updated != null) await _saveSettings(updated);
            },
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.shield_outlined),
            selectedIcon: const Icon(Icons.shield),
            label: t('nav.connection'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.dns_outlined),
            selectedIcon: const Icon(Icons.dns),
            label: t('nav.servers'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.alt_route_outlined),
            selectedIcon: const Icon(Icons.alt_route),
            label: t('nav.routes'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_tab == 1) Row(
              children: [
                // Выбор профиля — ОТДЕЛЬНОЕ окно, а не выпадающий список.
                //
                // Любое меню, открытое от строки, ложится на то, что под ней, —
                // а под ней «Тест задержки» и «Авто-выбор». Сначала я поменял
                // `DropdownButton` (тот вдобавок ставит список так, чтобы
                // выбранный пункт оказался ровно на кнопке) на меню «строго
                // вниз», и стало ровнее, но суть осталась: список всё равно
                // накрывает кнопки, и непонятно, на что ты сейчас нажмёшь.
                //
                // Диалог этой двусмысленности не оставляет: он явно поверх
                // всего, с заголовком и своим фоном, а список внутри
                // прокручивается — на подписках, где профилей десяток, это
                // ещё и удобнее выпадашки на пол-экрана.
                Expanded(
                  child: InkWell(
                    onTap: _profiles.isEmpty ? null : _chooseProfile,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        isDense: true,
                        border: UnderlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _activeProfile?.name ?? t('home.noProfiles'),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: t('profile.add'),
                  onPressed: _showAddProfileScreen,
                ),
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: t('profile.edit'),
                  onPressed: _activeProfile == null ? null : () => _showProfileDialog(editing: _activeProfile),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: t('profile.refresh'),
                  onPressed: _activeProfile == null ? null : () => _loadSubscription(_activeProfile!),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code_2),
                  tooltip: t('qr.profile'),
                  // Локальный профиль хранится файлом рядом с .exe и в url
                  // держит путь со схемой file: — показывать такой QR
                  // бессмысленно, на другом устройстве этого файла нет.
                  onPressed: _activeProfile == null ||
                          _activeProfile!.url.startsWith('file:')
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => QrScreen(
                                title: _activeProfile!.name,
                                data: _activeProfile!.url,
                              ),
                            ),
                          ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: t('profile.delete'),
                  onPressed: _activeProfile == null ? null : _deleteActiveProfile,
                ),
              ],
            ),
            if (_tab == 1) const SizedBox(height: 4),
            if (_tab == 1) Text(_subStatus.isEmpty ? t('profile.addNone') : _subStatus),
            if (_tab == 1 && _activeProfile != null) _profileUsage(_activeProfile!),
            // Щит занимает всё свободное место и стоит по центру — это
            // единственное содержимое вкладки, прижимать его к верху незачем.
            // Размер щита считается от РЕАЛЬНО доступной высоты: при
            // масштабировании Windows 125–150 % логических пикселей мало,
            // и фиксированный щит выдавливал переключатель TUN за край,
            // заставляя прокручивать главный экран. Прокрутка оставлена
            // только на совсем узкий случай — при нормальном окне её нет.
            if (_tab == 0)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => Center(
                    child: SingleChildScrollView(
                      child: _shieldBlock(box.maxHeight),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (_tab == 1 && _servers.isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: t('servers.searchHint'),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _serverSearch = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _serverSort,
                    underline: const SizedBox.shrink(),
                    items: [
                      DropdownMenuItem(value: 'default', child: Text(t('servers.sortDefault'))),
                      DropdownMenuItem(value: 'latency', child: Text(t('servers.sortLatency'))),
                      DropdownMenuItem(value: 'name', child: Text(t('servers.sortName'))),
                    ],
                    onChanged: (v) {
                      if (v != null) _setServerSort(v);
                    },
                  ),
                ],
              ),
              // Отдельной строкой, а не значком в ряду сортировки: настройка
              // убирает строки с экрана, и человек должен видеть, что она
              // включена, не наводя ни на что курсор.
              Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: Checkbox(
                      value: _settings.hideUnavailable,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) async {
                        final updated = AppSettings.fromJson(_settings.toJson())
                          ..hideUnavailable = v ?? false;
                        await _saveSettings(updated);
                      },
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _hiddenUnavailable > 0
                          ? tp('servers.hideDeadCount', {'n': _hiddenUnavailable})
                          : t('servers.hideDead'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Кнопки НАД списком, а не под ним.
              //
              // Под списком они выглядели так, будто список на них наползает:
              // прокрутка режет последнюю строку ровно по их верхнему краю, и
              // обрезанная строка сервера читается как наложение. Никакого
              // наложения там не было — только край области прокрутки, — но
              // выглядело именно так, и трижды было доложено как ошибка.
              // Над списком резать нечего: он идёт до самого низа окна.
              _serverActionButtons(),
              const SizedBox(height: 8),
              // Список — главное содержимое экрана, поэтому Expanded, а не
              // фиксированная высота: при низком окне фиксированная как раз и
              // давала перелив снизу.
              //
              // Рамка вокруг него — не украшение. Прокрутка режет крайнюю
              // строку, и голый обрезок текста вплотную к кнопке читается как
              // «список наползает сверху»: об этом сообщали трижды, причём
              // дважды я двигал не то. Наложения нет и не было — есть край
              // области прокрутки, который нечем опознать. В рамке с
              // собственным фоном обрезанная строка читается как «список
              // продолжается», потому что видно, где он кончается.
              Expanded(
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Theme.of(context).dividerColor, width: 1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Builder(builder: (context) {
                  final visible = _visibleServers();
                  if (visible.isEmpty) {
                    return Center(child: Text(t('common.notFound')));
                  }
                  return ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final s = visible[i];
                      final tag = s.outbound['tag'] as String;
                      final ms = _latencyMs[tag];
                      final tested = _latencyMs.containsKey(tag);
                      final selected = _selectedServer?.outbound['tag'] == tag;
                      final favorite = _favorites.contains(s.name);

                      final Widget trailing;
                      if (_testingLatency && tested && ms == null) {
                        trailing = const SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
                      } else if (ms != null) {
                        trailing = Text('$ms ${t('common.ms')}',
                            style: TextStyle(
                              color: ms < 100
                                  ? Colors.greenAccent
                                  : (ms < 300 ? Colors.amberAccent : Colors.redAccent),
                              fontWeight: FontWeight.w600,
                            ));
                      } else if (tested) {
                        trailing = const Icon(Icons.warning_amber_rounded,
                            color: Colors.redAccent, size: 20);
                      } else {
                        trailing = const SizedBox.shrink();
                      }

                      return ListTile(
                        dense: true,
                        selected: selected,
                        selectedTileColor:
                            Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                        // Подсказка рисуется НАД кнопкой (`preferBelow: false`).
                        //
                        // По умолчанию она уходит вниз, а строки списка стоят
                        // до самого нижнего края окна — у последних подсказку
                        // обрезает краем, и от неё остаётся серый огрызок с
                        // обрубленным текстом. Выглядит как мусор на экране, и
                        // именно так и было доложено. Своего `preferBelow` у
                        // IconButton нет, поэтому подсказка задаётся обёрткой,
                        // а не его собственным параметром.
                        leading: Tooltip(
                          message: favorite
                              ? t('servers.favRemove')
                              : t('servers.favAdd'),
                          preferBelow: false,
                          child: IconButton(
                            icon: Icon(favorite ? Icons.star : Icons.star_border,
                                size: 20, color: favorite ? Colors.amber : null),
                            onPressed: () => _toggleFavorite(s.name),
                          ),
                        ),
                        title: Text(s.name,
                            style: TextStyle(
                                fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                        subtitle: Text(
                          s.engine == 'xray' ? '${s.protocol} · Xray' : s.protocol,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: trailing,
                        onTap: () => _switchServer(s),
                        // Долгое нажатие — QR со ссылкой сервера: обычный
                        // способ перекинуть конфиг на телефон, не пересылая
                        // себе ссылку через мессенджер.
                        onLongPress: s.link.isEmpty
                            ? null
                            : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => QrScreen(title: s.name, data: s.link),
                                  ),
                                ),
                      );
                    },
                  );
                  }),
                ),
              ),
            ],
            // Переключателя TUN на Android нет, и это не упрощение экрана.
            // Там другого режима не существует: локальный прокси на 1337
            // никуда не подключить, весь трафик идёт через интерфейс, который
            // выдаёт система. Тумблер был бы всегда включён и неотключаем, а
            // подпись под ним обещала бы «перезапуск с правами администратора»
            // — понятие, которого на телефоне нет вовсе.
            if (_tab == 2 && Env.hasWindowAndTray) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t('routing.tun')),
                subtitle: Text(
                  _isAdmin ? t('routing.tunOn') : t('routing.tunNeedAdmin'),
                  style: const TextStyle(fontSize: 12),
                ),
                value: _tunMode,
                onChanged: _toggleTunMode,
              ),
              const Divider(height: 8),
            ],
            // Подпись НАД полем, а не слева: на узком окне длинное название
            // режима переносилось на вторую строку и налезало на подчёркивание.
            if (_tab == 2)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: DropdownButtonFormField<RoutingMode>(
                  initialValue: _routingMode,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: t('routing.label'),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: RoutingMode.values
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(_routingModeLabel(m), overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (m) {
                    if (m != null && m != _routingMode) _setRoutingMode(m);
                  },
                ),
              ),
            // Кнопка под галочкой, а не рядом: рядом им вдвоём тесно, текст
            // галочки переносился и налезал на кнопку.
            if (_tab == 2)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(t('routing.blockAds')),
                value: _blockAds,
                onChanged: (v) => _setBlockAds(v ?? false),
              ),
            if (_tab == 2)
              OutlinedButton.icon(
                icon: const Icon(Icons.apps, size: 18),
                label: Builder(builder: (_) {
                  final n = _settings.serviceRules.length;
                  return Text(n == 0
                      ? t('routing.serviceRules')
                      : "${t('routing.serviceRules')} · $n");
                }),
                onPressed: () async {
                  final updated = await Navigator.push<AppSettings>(
                    context,
                    MaterialPageRoute(builder: (_) => ServiceRulesScreen(initial: _settings)),
                  );
                  if (updated != null) await _saveSettings(updated);
                },
              ),
            if (_tab == 2) const SizedBox(height: 8),
            if (_tab == 2)
              OutlinedButton.icon(
                icon: const Icon(Icons.desktop_windows_outlined, size: 18),
                label: Builder(builder: (_) {
                  final n = _settings.appRules.length;
                  return Text(n == 0 ? t('app.title2') : "${t('app.title2')} · $n");
                }),
                onPressed: () async {
                  final updated = await Navigator.push<AppSettings>(
                    context,
                    MaterialPageRoute(builder: (_) => AppRulesScreen(initial: _settings)),
                  );
                  if (updated != null) await _saveSettings(updated);
                },
              ),
            if (_tab == 2) const SizedBox(height: 8),
            if (_tab == 2)
              OutlinedButton.icon(
                icon: const Icon(Icons.rule, size: 18),
                label: Text(t('routing.customRules')),
                onPressed: () async {
                  final updated = await Navigator.push<AppSettings>(
                    context,
                    MaterialPageRoute(builder: (_) => CustomRulesScreen(initial: _settings)),
                  );
                  if (updated != null) await _saveSettings(updated);
                },
              ),
            if (_tab == 0) const SizedBox(height: 8),
            // Карточка вместо чёрного прямоугольника с зелёным моноширинным
            // текстом: на светлой теме тот выглядел инородно, да и «терминал
            // внутри приложения» — не то, что хочется видеть на главном экране.
            if (_tab == 0) Card(
              child: Padding(
                // Ужато с 14: карточка стоит внизу главного экрана, и лишние
                // отступы здесь напрямую отнимают высоту у щита.
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      _runningEngine != null ? Icons.shield_rounded : Icons.shield_outlined,
                      size: 28,
                      color: _runningEngine != null
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).disabledColor,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(_statsText.isEmpty ? t('home.noData') : _statsText,
                          style: const TextStyle(fontSize: 12, height: 1.45)),
                    ),
                  ],
                ),
              ),
            ),
            // 16 -> 8: нижний отступ идёт сразу над панелью навигации, где
            // и без него достаточно воздуха, а высота на главном экране в цене.
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
// Экран настроек. Значения, которые раньше были константами в _writeConfig:
// правки применяются к конфигу при следующем старте ядра, на лету sing-box их
// не подхватывает (см. _restartHint).
// Версия приложения. Держится тут, а не читается пакетом package_info_plus:
// ради одной строки тянуть зависимость незачем. МЕНЯТЬ ВМЕСТЕ с полем
// `version:` в pubspec.yaml — они не связаны автоматически.
const String kAppVersion = '1.0.0';

/// Когда собрана ЭТА сборка.
///
/// Между релизами версия не меняется — она поднимается решением человека, — и
/// две сборки одного номера отличить было нечем. Это уже стоило раунда
/// вслепую: пользователь сообщил о поломке, исправленной днём раньше, и
/// выяснить, стоит ли у него правка, оказалось невозможно ни по одному экрану.
/// Спрашивать «а посмотрите, есть ли там такой-то тумблер» — не диагностика.
///
/// Значение подставляется при сборке:
///   flutter build apk --dart-define=BUILD_STAMP=2026-08-10T16:20
/// Без ключа остаётся пусто, и строка просто не показывается — заставлять
/// собирать через один-единственный правильный набор ключей нельзя.
const String kBuildStamp = String.fromEnvironment('BUILD_STAMP');

// Блок «О программе»: версии приложения и обоих ядер, ручная проверка
// обновлений и пути, которые спрашивают первыми, когда что-то не работает.
// Версии ядер спрашиваем у самих бинарников — единственный честный источник
// (см. историю с pre-release Xray в CLAUDE.md).
class _AboutBlock extends StatefulWidget {
  final Future<void> Function() onCheckCores;
  final Future<void> Function() onCheckApp;
  const _AboutBlock({required this.onCheckCores, required this.onCheckApp});

  @override
  State<_AboutBlock> createState() => _AboutBlockState();
}

class _AboutBlockState extends State<_AboutBlock> {
  String? _singBox;
  String? _xray;
  bool _loading = true;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _dir => File(Platform.resolvedExecutable).parent.path;

  Future<String?> _version(String exe) async {
    try {
      final path = '$_dir${Platform.pathSeparator}$exe';
      if (!await File(path).exists()) return null;
      final r = await Process.run(path, ['version']).timeout(const Duration(seconds: 10));
      final m = RegExp(r'(?:sing-box version|Xray)\s+(\d+\.\d+\.\d+)')
          .firstMatch('${r.stdout}');
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final sb = await _version('sing-box.exe');
    final xr = await _version('xray.exe');
    if (!mounted) return;
    setState(() {
      _singBox = sb;
      _xray = xr;
      _loading = false;
    });
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 130, child: Text(label, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: SelectableText(value,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final unknown = t('about.unknownVersion');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(t('about.app'), 'Multik Sila $kAppVersion'),
        if (kBuildStamp.isNotEmpty) _row(t('about.build'), kBuildStamp),
        _row('sing-box', _loading ? '…' : (_singBox ?? unknown)),
        _row('Xray', _loading ? '…' : (_xray ?? unknown)),
        // Ядро без версии автообновление не трогает — сравнивать не с чем.
        // Молчать об этом нельзя: человек будет ждать обновлений, которых нет.
        if (!_loading && (_singBox == null || _xray == null))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(t('about.unknownHint'),
                style: const TextStyle(fontSize: 12, height: 1.35)),
          ),
        const Divider(height: 24),
        _row(t('about.folder'), _dir),
        _row(t('about.logFile'), 'app_log.txt'),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: _checking
              ? const SizedBox(
                  width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.system_update_alt, size: 18),
          label: Text(t('about.checkCores')),
          onPressed: _checking
              ? null
              : () async {
                  setState(() => _checking = true);
                  await widget.onCheckCores();
                  if (mounted) setState(() => _checking = false);
                },
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.download_for_offline_outlined, size: 18),
          label: Text(t('about.checkApp')),
          onPressed: widget.onCheckApp,
        ),
        const SizedBox(height: 16),
        Text(t('about.sources'), style: const TextStyle(fontSize: 12, height: 1.4)),
        const SelectableText(
          'https://github.com/SagerNet/sing-box\n'
          'https://github.com/XTLS/Xray-core\n'
          'https://github.com/SagerNet/sing-geosite\n'
          'https://github.com/SagerNet/sing-geoip',
          style: TextStyle(fontSize: 11, height: 1.5),
        ),
      ],
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final AppSettings initial;
  // Проверка обновлений живёт на главном экране (там лог и снекбары),
  // поэтому экран настроек её только дёргает.
  final Future<void> Function() onCheckCores;
  final Future<void> Function() onCheckApp;
  const SettingsScreen({
    super.key,
    required this.initial,
    required this.onCheckCores,
    required this.onCheckApp,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _dnsDirect;
  late final TextEditingController _dnsRemote;
  late final TextEditingController _localPort;
  late final TextEditingController _clashPort;
  late final TextEditingController _tunName;
  late final TextEditingController _tunIpv4;
  late final TextEditingController _tunIpv6;
  late final TextEditingController _tunMtu;
  late final TextEditingController _latencyUrl;
  late final TextEditingController _latencyTimeout;
  late final TextEditingController _tolerance;
  late final TextEditingController _autoInterval;
  late final TextEditingController _autoFilter;
  late final TextEditingController _autoLimit;
  late bool _latencyWarmup;
  late String _latencyMode;
  late bool _autoFavFirst;
  late bool _autoOnConnect;
  late bool _tlsFragment;
  late bool _tlsRecordFragment;
  late bool _tlsInsecure;
  late final TextEditingController _tlsDelay;
  late final TextEditingController _fragLength;
  late final TextEditingController _fragInterval;
  late bool _autoSystemProxy;
  late bool _autoUpdateSub;
  late final TextEditingController _subInterval;
  late final TextEditingController _ruleSetDays;
  late bool _geoSite;
  late bool _geoIp;
  late bool _ntpEnabled;
  late final TextEditingController _ntpServer;
  late final TextEditingController _ntpPort;
  late final TextEditingController _ntpInterval;
  late bool _checkCores;
  late bool _autoUpdateCores;
  late final TextEditingController _updateFeed;
  late bool _autoUpdateApp;
  late bool _autoRestart;
  late bool _healthCheck;
  late final TextEditingController _healthUrl;
  late final TextEditingController _healthInterval;
  late bool _healthSwitch;
  late final TextEditingController _bypassList;
  late bool _muxEnabled;
  late String _muxProtocol;
  late bool _muxPadding;
  late final TextEditingController _muxStreams;
  late String _dnsProxyResolve;
  late bool _dnsHijack;
  late final TextEditingController _dnsTtl;
  late final TextEditingController _dnsEcs;
  late final TextEditingController _dnsHostsCtl;
  late String _themeMode;
  late int _accent;
  late String _language;

  late String _strategy;
  late String _stack;
  late bool _allowLan;
  late bool _ipv6Enabled;
  late bool _strictRoute;
  late bool _launchAtStartup;
  late bool _autoConnect;
  late bool _hideAfterLaunch;
  late bool _closeToTray;
  late bool _disconnectWhenQuit;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _dnsDirect = TextEditingController(text: s.dnsDirect);
    _dnsRemote = TextEditingController(text: s.dnsRemote);
    _localPort = TextEditingController(text: '${s.localPort}');
    _clashPort = TextEditingController(text: '${s.clashApiPort}');
    _tunName = TextEditingController(text: s.tunName);
    _tunIpv4 = TextEditingController(text: s.tunIpv4);
    _tunIpv6 = TextEditingController(text: s.tunIpv6);
    _tunMtu = TextEditingController(text: '${s.tunMtu}');
    _latencyUrl = TextEditingController(text: s.latencyUrl);
    _latencyTimeout = TextEditingController(text: '${s.latencyTimeoutMs}');
    _tolerance = TextEditingController(text: '${s.tolerance}');
    _autoInterval = TextEditingController(text: '${s.autoSelectIntervalMin}');
    _autoFilter = TextEditingController(text: s.autoSelectFilter);
    _autoLimit = TextEditingController(text: '${s.autoSelectLimit}');
    _latencyWarmup = s.latencyWarmup;
    _latencyMode = s.latencyMode;
    _autoFavFirst = s.autoSelectFavFirst;
    _autoOnConnect = s.autoSelectOnConnect;
    _tlsFragment = s.tlsFragment;
    _tlsRecordFragment = s.tlsRecordFragment;
    _tlsInsecure = s.tlsInsecure;
    _tlsDelay = TextEditingController(text: s.tlsFragmentDelay);
    _fragLength = TextEditingController(text: s.xrayFragLength);
    _fragInterval = TextEditingController(text: s.xrayFragInterval);
    _autoSystemProxy = s.autoSetSystemProxy;
    _autoUpdateSub = s.autoUpdateSubscription;
    _subInterval = TextEditingController(text: '${s.subUpdateIntervalHours}');
    _ruleSetDays = TextEditingController(text: '${s.ruleSetRefreshDays}');
    _geoSite = s.geoSiteEnabled;
    _geoIp = s.geoIpEnabled;
    _ntpEnabled = s.ntpEnabled;
    _ntpServer = TextEditingController(text: s.ntpServer);
    _ntpPort = TextEditingController(text: '${s.ntpPort}');
    _ntpInterval = TextEditingController(text: s.ntpInterval);
    _checkCores = s.checkCoreUpdates;
    _autoUpdateCores = s.autoUpdateCores;
    _updateFeed = TextEditingController(text: s.updateFeedUrl);
    _autoUpdateApp = s.autoUpdateApp;
    _autoRestart = s.autoRestartCore;
    _healthCheck = s.healthCheckEnabled;
    _healthUrl = TextEditingController(text: s.healthCheckUrl);
    _healthInterval = TextEditingController(text: '${s.healthCheckIntervalSec}');
    _healthSwitch = s.healthCheckAutoSwitch;
    _bypassList = TextEditingController(text: s.proxyBypassList);
    _muxEnabled = s.muxEnabled;
    _muxProtocol = s.muxProtocol;
    _muxPadding = s.muxPadding;
    _muxStreams = TextEditingController(text: '${s.muxMaxStreams}');
    _dnsProxyResolve = s.dnsProxyResolve;
    _dnsHijack = s.dnsHijack;
    _dnsTtl = TextEditingController(text: '${s.dnsTtl}');
    _dnsEcs = TextEditingController(text: s.dnsClientSubnet);
    _dnsHostsCtl = TextEditingController(text: s.dnsHosts.join('\n'));
    _themeMode = s.themeMode;
    _accent = s.accentColor;
    _language = s.language;
    _strategy = s.dnsStrategy;
    _stack = s.tunStack;
    _allowLan = s.allowLan;
    _ipv6Enabled = s.tunIpv6Enabled;
    _strictRoute = s.strictRoute;
    _launchAtStartup = s.launchAtStartup;
    _autoConnect = s.autoConnectAfterLaunch;
    _hideAfterLaunch = s.hideAfterLaunch;
    _closeToTray = s.closeToTray;
    _disconnectWhenQuit = s.disconnectWhenQuit;
  }

  @override
  void dispose() {
    for (final c in [
      _dnsDirect, _dnsRemote, _localPort, _clashPort, _tunName, _tunIpv4, _tunIpv6, _tunMtu,
      _latencyUrl, _latencyTimeout, _tolerance, _autoInterval, _autoFilter, _autoLimit,
      _tlsDelay, _fragLength, _fragInterval, _subInterval, _ruleSetDays,
      _dnsTtl, _dnsEcs, _dnsHostsCtl, _muxStreams, _bypassList,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // Пустое или нечисловое поле не должно превращаться в порт 0 и ломать ядро —
  // откатываемся на прежнее значение.
  int _intOr(TextEditingController c, int fallback) {
    final v = int.tryParse(c.text.trim());
    return (v == null || v <= 0 || v > 65535 && fallback < 65536) ? fallback : v;
  }

  String _textOr(TextEditingController c, String fallback) =>
      c.text.trim().isEmpty ? fallback : c.text.trim();

  void _save() {
    final s = widget.initial;
    Navigator.pop(
      context,
      AppSettings(
        dnsDirect: _textOr(_dnsDirect, s.dnsDirect),
        dnsRemote: _textOr(_dnsRemote, s.dnsRemote),
        dnsStrategy: _strategy,
        localPort: _intOr(_localPort, s.localPort),
        allowLan: _allowLan,
        clashApiPort: _intOr(_clashPort, s.clashApiPort),
        tunName: _textOr(_tunName, s.tunName),
        tunIpv4: _textOr(_tunIpv4, s.tunIpv4),
        tunIpv6: _textOr(_tunIpv6, s.tunIpv6),
        tunIpv6Enabled: _ipv6Enabled,
        tunStack: _stack,
        tunMtu: int.tryParse(_tunMtu.text.trim()) ?? s.tunMtu,
        strictRoute: _strictRoute,
        latencyMode: _latencyMode,
        latencyUrl: _textOr(_latencyUrl, s.latencyUrl),
        latencyTimeoutMs: _intOr(_latencyTimeout, s.latencyTimeoutMs),
        latencyWarmup: _latencyWarmup,
        // Допуск и лимит могут быть нулём — это осмысленные значения
        // («переключаться всегда» / «без ограничения»), поэтому не через _intOr,
        // который ноль отбрасывает как некорректный порт.
        tolerance: int.tryParse(_tolerance.text.trim()) ?? s.tolerance,
        autoSelectIntervalMin: int.tryParse(_autoInterval.text.trim()) ?? s.autoSelectIntervalMin,
        autoSelectFilter: _autoFilter.text.trim(),
        autoSelectLimit: int.tryParse(_autoLimit.text.trim()) ?? s.autoSelectLimit,
        autoSelectFavFirst: _autoFavFirst,
        autoSelectOnConnect: _autoOnConnect,
        tlsFragment: _tlsFragment,
        tlsRecordFragment: _tlsRecordFragment,
        tlsInsecure: _tlsInsecure,
        tlsFragmentDelay: _textOr(_tlsDelay, s.tlsFragmentDelay),
        xrayFragLength: _textOr(_fragLength, s.xrayFragLength),
        xrayFragInterval: _textOr(_fragInterval, s.xrayFragInterval),
        autoSetSystemProxy: _autoSystemProxy,
        autoUpdateSubscription: _autoUpdateSub,
        // 0 — осмысленное значение («брать из панели»), поэтому не через
        // _intOr, который ноль отбрасывает.
        subUpdateIntervalHours: int.tryParse(_subInterval.text.trim()) ?? s.subUpdateIntervalHours,
        checkCoreUpdates: _checkCores,
        autoUpdateCores: _autoUpdateCores,
        updateFeedUrl: _updateFeed.text.trim(),
        autoUpdateApp: _autoUpdateApp,
        ruleSetRefreshDays: int.tryParse(_ruleSetDays.text.trim()) ?? s.ruleSetRefreshDays,
        geoSiteEnabled: _geoSite,
        geoIpEnabled: _geoIp,
        ntpEnabled: _ntpEnabled,
        ntpServer: _textOr(_ntpServer, s.ntpServer),
        ntpPort: int.tryParse(_ntpPort.text.trim()) ?? s.ntpPort,
        ntpInterval: _textOr(_ntpInterval, s.ntpInterval),
        autoRestartCore: _autoRestart,
        healthCheckEnabled: _healthCheck,
        healthCheckUrl: _textOr(_healthUrl, s.healthCheckUrl),
        // Ниже 15 секунд не опускаем: проверка ходит к настоящему сайту, и
        // чаще этого она превращается в собственный источник трафика.
        healthCheckIntervalSec: math.max(
            15, int.tryParse(_healthInterval.text.trim()) ?? s.healthCheckIntervalSec),
        healthCheckAutoSwitch: _healthSwitch,
        proxyBypassList: _bypassList.text.trim(),
        muxEnabled: _muxEnabled,
        muxProtocol: _muxProtocol,
        muxMaxStreams: int.tryParse(_muxStreams.text.trim()) ?? s.muxMaxStreams,
        muxPadding: _muxPadding,
        dnsProxyResolve: _dnsProxyResolve,
        dnsHijack: _dnsHijack,
        dnsTtl: int.tryParse(_dnsTtl.text.trim()) ?? s.dnsTtl,
        dnsClientSubnet: _dnsEcs.text.trim(),
        dnsHosts: _dnsHostsCtl.text
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList(),
        themeMode: _themeMode,
        accentColor: _accent,
        language: _language,
        launchAtStartup: _launchAtStartup,
        autoConnectAfterLaunch: _autoConnect,
        hideAfterLaunch: _hideAfterLaunch,
        closeToTray: _closeToTray,
        disconnectWhenQuit: _disconnectWhenQuit,
      ),
    );
  }

  // Выбор из готовых вариантов, который просто подставляет значение в поле.
  // Само поле остаётся редактируемым: пресеты — подсказка, а не ограничение.
  bool _pickingDns = false;
  String? _dnsPickResult;

  // Открытый раздел настроек. null — показываем список разделов.
  // Сделано через состояние, а не через Navigator: все поля живут в этом
  // State, и при переходе на отдельный маршрут пришлось бы тащить туда
  // полтора десятка контроллеров и собирать результат обратно.
  String? _openSection;

  // Порядок разделов и их значки. Названия и подсказки берутся из словаря
  // по ключам section.<id> и section.<id>Hint — так при смене языка меню
  // перестраивается само, без дублирования списка на каждый язык.
  static const _sectionIcons = <String, IconData>{
    'launch': Icons.rocket_launch_outlined,
    'look': Icons.palette_outlined,
    'sub': Icons.cloud_sync_outlined,
    'latency': Icons.speed,
    'autoselect': Icons.auto_awesome,
    'tls': Icons.enhanced_encryption_outlined,
    'proxy': Icons.lan_outlined,
    'dns': Icons.dns_outlined,
    'tun': Icons.vpn_lock_outlined,
    'mux': Icons.merge_type,
    'rules': Icons.rule_folder_outlined,
    'ntp': Icons.schedule,
    'updates': Icons.system_update_alt,
    'misc': Icons.build_outlined,
    // «О программе» — последним: это справка, а не настройка, и открывают её
    // редко. Порядок этой карты и есть порядок пунктов в меню настроек.
    'about': Icons.info_outline,
  };

  // Ключ обязателен. Меню разделов и содержимое открытого раздела — два
  // ListView на ОДНОМ месте дерева (см. `body:` ниже). Без ключей Flutter
  // считает их одним виджетом, переиспользует элемент и, главное, одну
  // позицию прокрутки на двоих: вход в раздел обнулял её под новое
  // содержимое, а возврат отдавал меню этот же ноль. Человек уходил в
  // «О программе» из конца списка и возвращался в начало.
  //
  // Разные PageStorageKey дают, во-первых, отдельные элементы, во-вторых —
  // сохранение и восстановление смещения средствами PageStorage.
  Widget _sectionMenu() => ListView(
        key: const PageStorageKey<String>('settings-menu'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          ..._sectionIcons.entries.map((e) => ListTile(
                leading: Icon(e.value),
                title: Text(t('section.${e.key}')),
                subtitle:
                    Text(t('section.${e.key}Hint'), style: const TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => setState(() => _openSection = e.key),
              )),
          const Divider(height: 24),
          // Сброс на заводские значения. Нужен потому, что настроек много и
          // взаимосвязанных: одна неудачная комбинация (не тот стек TUN, не
          // тот способ резолва) роняет подключение целиком, а вспомнить, что
          // именно менял, человек уже не может. Профили и подписки при этом
          // не трогаем — терять их из-за настроек было бы несоразмерно.
          ListTile(
            leading: Icon(Icons.restart_alt, color: Theme.of(context).colorScheme.error),
            title: Text(t('set.reset')),
            subtitle: Text(t('hint.reset'), style: const TextStyle(fontSize: 11)),
            onTap: _confirmReset,
          ),
        ],
      );

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('set.reset')),
        content: Text(t('dlg.resetText')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('common.cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('set.reset'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Возвращаем экран настроек с чистым объектом — сохранение и перезапись
    // файла делает главный экран, как и при обычном «Сохранить».
    Navigator.pop(context, AppSettings());
  }

  // Автоподбор: опрашиваем каждый DNS-сервер из списка и берём самый быстрый.
  // Меряем реальным DNS-запросом по UDP, а не пингом: ICMP многие провайдеры
  // режут или приоритизируют иначе, и цифра выходит не про DNS.
  Future<void> _autoPickDns(TextEditingController target) async {
    setState(() {
      _pickingDns = true;
      _dnsPickResult = null;
    });
    final results = <String, int>{};
    for (final server in AppSettings.dnsPresets.keys) {
      try {
        final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        // Минимальный DNS-запрос A-записи для example.com
        final query = <int>[
          0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
          7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0, 1,
        ];
        final sw = Stopwatch()..start();
        socket.send(query, InternetAddress(server), 53);
        final done = Completer<bool>();
        socket.listen((event) {
          if (event == RawSocketEvent.read && socket.receive() != null && !done.isCompleted) {
            done.complete(true);
          }
        });
        final ok = await done.future.timeout(const Duration(seconds: 2), onTimeout: () => false);
        sw.stop();
        socket.close();
        if (ok) results[server] = sw.elapsedMilliseconds;
      } catch (_) {
        // недоступен — просто не попадает в результаты
      }
    }
    if (!mounted) return;
    if (results.isEmpty) {
      setState(() {
        _pickingDns = false;
        _dnsPickResult = t('dns.pickNoReply');
      });
      return;
    }
    final sorted = results.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    setState(() {
      target.text = sorted.first.key;
      _pickingDns = false;
      _dnsPickResult = tp('dns.pickResult', {
        'name': sorted.first.key,
        'list': sorted.map((e) => "${e.key}: ${e.value} ${t('common.ms')}").join(', '),
      });
    });
  }

  Widget _presetPicker(String label, Map<String, String> presets, TextEditingController target) {
    final current = presets.containsKey(target.text.trim()) ? target.text.trim() : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownButtonFormField<String>(
        initialValue: current,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        hint: Text(t('set.customValue')),
        items: presets.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: (v) {
          if (v != null) setState(() => target.text = v);
        },
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {String? hint}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: c,
          decoration: InputDecoration(
            labelText: label,
            helperText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            _openSection == null ? t('bar.settings') : t('section.$_openSection')),
        leading: _openSection == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: t('common.back'),
                onPressed: () => setState(() => _openSection = null),
              ),
        actions: [
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check),
            label: Text(t('common.save')),
          ),
        ],
      ),
      body: _openSection == null
          ? _sectionMenu()
          : ListView(
        // Ключ на КАЖДЫЙ раздел свой: иначе все разделы делили бы одну
        // позицию, и, пролистав длинный «Маршрутизацию», человек открывал бы
        // короткий «NTP» уже прокрученным неизвестно куда.
        key: PageStorageKey<String>('settings-$_openSection'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          if (_openSection == 'launch') ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.autostart')),
            subtitle: Text(t('set.autostartHint'),
                style: TextStyle(fontSize: 12)),
            value: _launchAtStartup,
            onChanged: (v) => setState(() => _launchAtStartup = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.autoConnect')),
            value: _autoConnect,
            onChanged: (v) => setState(() => _autoConnect = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.hideAfterLaunch')),
            subtitle: Text(t('set.hideAfterLaunchHint'),
                style: TextStyle(fontSize: 12)),
            value: _hideAfterLaunch,
            onChanged: (v) => setState(() => _hideAfterLaunch = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.closeToTray')),
            subtitle: Text(t('set.closeToTrayHint'),
                style: TextStyle(fontSize: 12)),
            value: _closeToTray,
            onChanged: (v) => setState(() => _closeToTray = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.disconnectOnQuit')),
            value: _disconnectWhenQuit,
            onChanged: (v) => setState(() => _disconnectWhenQuit = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.autoRestart')),
            subtitle: Text(
                t('set.autoRestartHint'),
                style: const TextStyle(fontSize: 12)),
            value: _autoRestart,
            onChanged: (v) => setState(() => _autoRestart = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.healthCheck')),
            subtitle: Text(t('set.healthCheckSub'),
                style: const TextStyle(fontSize: 12)),
            value: _healthCheck,
            onChanged: (v) => setState(() => _healthCheck = v),
          ),
          if (_healthCheck) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: TextField(
                controller: _healthUrl,
                decoration: InputDecoration(
                  labelText: t('set.healthCheckUrl'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: TextField(
                controller: _healthInterval,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t('set.healthCheckInterval'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('set.healthCheckSwitch')),
              value: _healthSwitch,
              onChanged: (v) => setState(() => _healthSwitch = v),
            ),
          ],
          ],
          if (_openSection == 'look') ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DropdownButtonFormField<String>(
              initialValue: _themeMode,
              decoration: InputDecoration(
                labelText: t('look.theme'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                DropdownMenuItem(value: 'dark', child: Text(t('look.themeDark'))),
                DropdownMenuItem(value: 'light', child: Text(t('look.themeLight'))),
                DropdownMenuItem(value: 'system', child: Text(t('look.themeSystem'))),
              ],
              onChanged: (v) => setState(() => _themeMode = v ?? _themeMode),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DropdownButtonFormField<String>(
              initialValue: _language,
              decoration: InputDecoration(
                labelText: t('look.language'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: languageNames.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              // Применяем сразу, не дожидаясь «Сохранить»: иначе непонятно,
              // сработало ли переключение, — экран остаётся на прежнем языке.
              onChanged: (v) => setState(() {
                _language = v ?? _language;
                appLang.value = _language;
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(t('look.accent'), style: const TextStyle(fontSize: 12)),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: accentPalette.entries.map((e) {
              final selected = _accent == e.key;
              return Tooltip(
                message: t(e.value),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => setState(() => _accent = e.key),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Color(e.key),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.onSurface
                            : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: selected
                        ? const Icon(Icons.check, size: 18, color: Colors.white)
                        : null,
                  ),
                ),
              );
            }).toList(),
          ),
          ],
          if (_openSection == 'sub') ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.subAuto')),
            subtitle: Text(
                t('hint.subAuto'),
                style: TextStyle(fontSize: 12)),
            value: _autoUpdateSub,
            onChanged: (v) => setState(() => _autoUpdateSub = v),
          ),
          if (_autoUpdateSub)
            _field(_subInterval, t('set.subInterval'),
                hint: t('set.subIntervalHint')),
          ],
          if (_openSection == 'latency') ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DropdownButtonFormField<String>(
              initialValue: _latencyMode,
              decoration: InputDecoration(
                labelText: t('set.latencyWhat'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                DropdownMenuItem(value: 'proxy', child: Text(t('set.latencyProxy'))),
                DropdownMenuItem(value: 'warm', child: Text(t('set.latencyWarm'))),
                DropdownMenuItem(value: 'connect', child: Text(t('set.latencyConnect'))),
              ],
              onChanged: (v) => setState(() => _latencyMode = v ?? _latencyMode),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              switch (_latencyMode) {
                'connect' => t('hint.latencyConnect'),
                'warm' => t('hint.latencyWarm'),
                _ => t('hint.latencyProxy'),
              },
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
          ),
          if (_latencyMode == 'proxy') ...[
            _presetPicker(t('set.presets'), AppSettings.latencyUrlPresets, _latencyUrl),
            _field(_latencyUrl, t('set.latencyUrl'),
                hint: t('hint.latencyUrl')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('set.latencyWarmup')),
              subtitle: Text(
                  t('hint.latencyWarmup'),
                  style: TextStyle(fontSize: 12)),
              value: _latencyWarmup,
              onChanged: (v) => setState(() => _latencyWarmup = v),
            ),
          ],
          _field(_latencyTimeout, t('set.latencyTimeout')),
          ],
          if (_openSection == 'autoselect') ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.autoOnConnect')),
            subtitle: Text(
                t('hint.autoOnConnect'),
                style: const TextStyle(fontSize: 12)),
            value: _autoOnConnect,
            onChanged: (v) => setState(() => _autoOnConnect = v),
          ),
          _field(_autoInterval, t('set.autoInterval'), hint: t('hint.autoInterval')),
          _field(_tolerance, t('set.tolerance'),
              hint: t('hint.tolerance')),
          _field(_autoFilter, t('set.autoFilter'), hint: t('hint.autoFilter')),
          _field(_autoLimit, t('set.autoLimit'), hint: t('hint.autoLimit')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.favFirst')),
            subtitle: Text(t('hint.favFirst'),
                style: TextStyle(fontSize: 12)),
            value: _autoFavFirst,
            onChanged: (v) => setState(() => _autoFavFirst = v),
          ),
          ],
          if (_openSection == 'tls') ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              t('hint.tlsIntro'),
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.tlsFragment')),
            subtitle: Text(
                t('hint.tlsFragment'),
                style: TextStyle(fontSize: 12)),
            value: _tlsFragment,
            onChanged: (v) => setState(() => _tlsFragment = v),
          ),
          if (_tlsFragment) ...[
            _field(_tlsDelay, t('set.tlsDelay'), hint: t('hint.example500ms')),
            _field(_fragLength, t('set.fragLength'), hint: t('hint.range100')),
            _field(_fragInterval, t('set.fragInterval'), hint: t('hint.example1020')),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.tlsRecordFragment')),
            subtitle: Text(t('hint.tlsRecordFragment'),
                style: TextStyle(fontSize: 12)),
            value: _tlsRecordFragment,
            onChanged: (v) => setState(() => _tlsRecordFragment = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.tlsInsecure')),
            subtitle: Text(
                t('hint.tlsInsecure'),
                style: TextStyle(fontSize: 12)),
            value: _tlsInsecure,
            onChanged: (v) => setState(() => _tlsInsecure = v),
          ),
          ],
          if (_openSection == 'proxy') ...[
          _field(_localPort, t('set.port'), hint: t('hint.port')),
          const SizedBox(height: 8),
          Text(t('set.bypassList'), style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: _bypassList,
            maxLines: 4,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              helperText: t('hint.bypassList'),
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.systemProxy')),
            subtitle: Text(
                t('hint.systemProxy'),
                style: const TextStyle(fontSize: 12)),
            value: _autoSystemProxy,
            onChanged: (v) => setState(() => _autoSystemProxy = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.allowLan')),
            subtitle: Text(t('hint.allowLan'),
                style: TextStyle(fontSize: 12)),
            value: _allowLan,
            onChanged: (v) => setState(() => _allowLan = v),
          ),
          ],
          if (_openSection == 'dns') ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickingDns ? null : () => _autoPickDns(_dnsDirect),
                  icon: _pickingDns
                      ? const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_fix_high, size: 18),
                  label: Text(_pickingDns ? t('set.dnsPicking') : t('set.dnsAutoPick')),
                ),
              ),
            ],
          ),
          if (_dnsPickResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_dnsPickResult!, style: const TextStyle(fontSize: 11, height: 1.35)),
            ),
          _presetPicker(t('hint.presetsDirect'), AppSettings.dnsPresets, _dnsDirect),
          _field(_dnsDirect, t('set.dnsDirect'), hint: t('hint.dnsDirect')),
          _presetPicker(t('hint.presetsRemote'), AppSettings.dnsPresets, _dnsRemote),
          _field(_dnsRemote, t('set.dnsRemote'), hint: t('hint.dnsRemote')),
          const Divider(height: 28),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.dnsHijack')),
            subtitle: Text(
                t('hint.dnsHijack'),
                style: TextStyle(fontSize: 12)),
            value: _dnsHijack,
            onChanged: (v) => setState(() => _dnsHijack = v),
          ),
          // Способ разрешения в DNS для трафика прокси — выпадающий список, а
          // не галочка «FakeIP». Галочка описывала только один из трёх
          // способов, а какой сервер резолвит остальные два, человек вообще
          // не видел и поменять не мог.
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.dnsProxyResolve')),
            subtitle: Text(t('hint.dnsProxyResolve.$_dnsProxyResolve'),
                style: const TextStyle(fontSize: 12)),
            trailing: DropdownButton<String>(
              value: _dnsProxyResolve,
              onChanged: (v) =>
                  setState(() => _dnsProxyResolve = v ?? _dnsProxyResolve),
              items: [
                for (final m in const ['current', 'direct', 'fakeip'])
                  DropdownMenuItem(value: m, child: Text(t('dns.mode.$m'))),
              ],
            ),
          ),
          _field(_dnsTtl, t('set.dnsTtl'), hint: t('hint.dnsTtl')),
          _field(_dnsEcs, t('set.dnsEcs'),
              hint: t('hint.dnsEcs')),
          const SizedBox(height: 8),
          Text(t('set.dnsHosts'), style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: _dnsHostsCtl,
            maxLines: 5,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              hintText: 'router.local=192.168.1.1\nnas=10.0.0.5',
              helperText: t('hint.dnsHosts'),
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DropdownButtonFormField<String>(
              initialValue: _strategy,
              decoration: InputDecoration(
                labelText: t('set.dnsStrategy'),
                helperText: t('hint.dnsStrategy'),
                helperMaxLines: 4,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: AppSettings.strategies
                  .map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(t('ipv6.$s'), overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _strategy = v ?? _strategy),
            ),
          ),
          ],
          if (_openSection == 'tun') ...[
          _field(_tunName, t('set.tunName')),
          _field(_tunIpv4, t('set.tunIpv4')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.tunIpv6On')),
            subtitle: Text(
                t('hint.tunIpv6'),
                style: const TextStyle(fontSize: 12)),
            value: _ipv6Enabled,
            onChanged: (v) => setState(() => _ipv6Enabled = v),
          ),
          if (_ipv6Enabled) _field(_tunIpv6, t('set.tunIpv6')),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DropdownButtonFormField<String>(
              initialValue: _stack,
              decoration: InputDecoration(
                labelText: t('set.tunStack'),
                helperText: t('set.tunStackHint'),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: AppSettings.stacks
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _stack = v ?? _stack),
            ),
          ),
          _field(_tunMtu, t('set.tunMtu')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('set.strictRoute')),
            subtitle: Text(t('hint.strictRoute'),
                style: TextStyle(fontSize: 12)),
            value: _strictRoute,
            onChanged: (v) => setState(() => _strictRoute = v),
          ),
          ],
          if (_openSection == 'mux') ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('set.muxOn')),
              subtitle: Text(t('hint.muxFull'),
                  style: const TextStyle(fontSize: 12)),
              value: _muxEnabled,
              onChanged: (v) => setState(() => _muxEnabled = v),
            ),
            if (_muxEnabled) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: DropdownButtonFormField<String>(
                  initialValue: _muxProtocol,
                  decoration: InputDecoration(
                    labelText: t('set.muxProtocol'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(value: 'h2mux', child: Text(t('set.muxDefault'))),
                    const DropdownMenuItem(value: 'smux', child: Text('smux')),
                    const DropdownMenuItem(value: 'yamux', child: Text('yamux')),
                  ],
                  onChanged: (v) => setState(() => _muxProtocol = v ?? _muxProtocol),
                ),
              ),
              _field(_muxStreams, t('set.muxStreams'), hint: t('hint.muxStreams')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t('set.muxPadding')),
                subtitle: Text(t('hint.muxPadding'),
                    style: TextStyle(fontSize: 12)),
                value: _muxPadding,
                onChanged: (v) => setState(() => _muxPadding = v),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  t('hint.muxVision'),
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
              ),
            ],
          ],
          if (_openSection == 'about') ...[
            _AboutBlock(
              onCheckCores: widget.onCheckCores,
              onCheckApp: widget.onCheckApp,
            ),
          ],
          if (_openSection == 'rules') ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(t('rules.intro'),
                  style: const TextStyle(fontSize: 12, height: 1.35)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('rules.geosite')),
              subtitle: Text(t('rules.geositeHint'),
                  style: const TextStyle(fontSize: 12)),
              value: _geoSite,
              onChanged: (v) => setState(() => _geoSite = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('rules.geoip')),
              subtitle: Text(t('rules.geoipHint'),
                  style: const TextStyle(fontSize: 12)),
              value: _geoIp,
              onChanged: (v) => setState(() => _geoIp = v),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t('rules.aclNote'),
                  style: const TextStyle(fontSize: 12, height: 1.35)),
            ),
          ],
          if (_openSection == 'ntp') ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('ntp.enable')),
              subtitle: Text(t('ntp.hint'),
                  style: const TextStyle(fontSize: 12)),
              value: _ntpEnabled,
              onChanged: (v) => setState(() => _ntpEnabled = v),
            ),
            if (_ntpEnabled) ...[
              _presetPicker(t('ntp.presets'), AppSettings.ntpPresets, _ntpServer),
              _field(_ntpServer, t('ntp.server')),
              _field(_ntpPort, t('ntp.port')),
              _field(_ntpInterval, t('ntp.interval'), hint: t('ntp.intervalHint')),
            ],
          ],
          if (_openSection == 'updates') ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('set.checkCores')),
              subtitle: Text(
                  t('hint.checkCores'),
                  style: TextStyle(fontSize: 12)),
              value: _checkCores,
              onChanged: (v) => setState(() => _checkCores = v),
            ),
            _field(_updateFeed, t('set.updateFeed'), hint: t('hint.updateFeed')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('set.autoUpdateApp')),
              subtitle: Text(t('hint.autoUpdateApp'),
                  style: const TextStyle(fontSize: 12)),
              value: _autoUpdateApp,
              onChanged: (v) => setState(() => _autoUpdateApp = v),
            ),
            const Divider(height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('set.autoUpdateCores')),
              subtitle: Text(t('hint.autoUpdateCores'),
                  style: const TextStyle(fontSize: 12)),
              value: _autoUpdateCores,
              onChanged: (v) => setState(() => _autoUpdateCores = v),
            ),
            _field(_ruleSetDays, t('set.ruleSetDays'),
                hint: t('hint.ruleSetDays')),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                t('hint.ruleSetsBuiltIn'),
                style: const TextStyle(fontSize: 12, height: 1.35),
              ),
            ),
          ],
          if (_openSection == 'misc') ...[
          _field(_clashPort, t('set.clashPort'), hint: t('hint.clashPort')),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// Лог вынесен на отдельный экран: на главной он занимал Expanded наравне со
// списком серверов, и на невысоком окне колонка переливалась через край.
class LogScreen extends StatelessWidget {
  final String log;
  const LogScreen({super.key, required this.log});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('log.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: t('log.copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: log));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t('log.copied'))),
                );
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          log.isEmpty ? t('common.empty') : log,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

// Свои правила маршрутизации. Три списка, по строке на запись: домен или
// IP/подсеть. Применяются при следующем старте ядра — на лету sing-box
// правила не подхватывает.
class CustomRulesScreen extends StatefulWidget {
  final AppSettings initial;
  const CustomRulesScreen({super.key, required this.initial});

  @override
  State<CustomRulesScreen> createState() => _CustomRulesScreenState();
}

class _CustomRulesScreenState extends State<CustomRulesScreen> {
  late final TextEditingController _direct;
  late final TextEditingController _proxy;
  late final TextEditingController _block;

  @override
  void initState() {
    super.initState();
    _direct = TextEditingController(text: widget.initial.customDirect.join('\n'));
    _proxy = TextEditingController(text: widget.initial.customProxy.join('\n'));
    _block = TextEditingController(text: widget.initial.customBlock.join('\n'));
  }

  @override
  void dispose() {
    _direct.dispose();
    _proxy.dispose();
    _block.dispose();
    super.dispose();
  }

  List<String> _lines(TextEditingController c) => c.text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  Widget _list(String title, String hint, IconData icon, Color color, TextEditingController c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 4),
          child: Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
          ]),
        ),
        Text(hint, style: const TextStyle(fontSize: 12, height: 1.3)),
        const SizedBox(height: 8),
        TextField(
          controller: c,
          maxLines: 6,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            hintText: 'example.com\n192.168.1.0/24',
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('cr.title')),
        actions: [
          TextButton.icon(
            onPressed: () {
              final s = widget.initial;
              Navigator.pop(
                context,
                AppSettings.from(s,
                    customDirect: _lines(_direct),
                    customProxy: _lines(_proxy),
                    customBlock: _lines(_block)),
              );
            },
            icon: const Icon(Icons.check),
            label: Text(t('common.save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          Text(
            '${t('cr.intro1')}\n\n${t('cr.intro2')}',
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
          _list(t('cr.direct'), t('cr.directHint'),
              Icons.call_made, Colors.greenAccent, _direct),
          _list(t('cr.proxy'), t('cr.proxyHint'),
              Icons.vpn_lock, Colors.lightBlueAccent, _proxy),
          _list(t('cr.block'), t('cr.blockHint'),
              Icons.block, Colors.redAccent, _block),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// Активные соединения через Clash API. Главный инструмент, когда «сайт не
// открывается»: сразу видно, ушёл ли запрос в туннель или напрямую и какое
// правило это решило. Работает только с ядром sing-box — у Xray Clash API нет.
// QR-код для ссылки: сервера или подписки. Код рисуется на БЕЛОМ поле
// всегда, даже в тёмной теме — сканеры телефонов ждут тёмный узор на
// светлом фоне, инверсия читается через раз.
class QrScreen extends StatelessWidget {
  final String title;
  final String data;
  const QrScreen({super.key, required this.title, required this.data});

  @override
  Widget build(BuildContext context) {
    // Слишком длинную ссылку QR версии 40 уже не вмещает. Вместо непонятной
    // ошибки отрисовки честно говорим, что кода не будет, и оставляем копию.
    final tooLong = data.length > 2000;
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (tooLong)
            Text(t('qr.tooLong'), style: const TextStyle(fontSize: 13, height: 1.35))
          else
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: data,
                  size: 260,
                  backgroundColor: Colors.white,
                  // Средний уровень коррекции: узор остаётся некрупным, но
                  // код читается и с бликом на экране.
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
          const SizedBox(height: 20),
          SelectableText(data, style: const TextStyle(fontSize: 11, height: 1.35)),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.copy_all_outlined),
            label: Text(t('log.copy')),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: data));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t('qr.copied'))),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

// Экран статистики. Свой опрос, а не данные из главного экрана: там сводка
// обновляется раз в две секунды, а для скорости нужен ровный шаг в секунду —
// скорость считается как разница накопленных счётчиков между двумя опросами.
// Отдельный поток Clash API /traffic не используем: он SSE, а обычный
// http-клиент пакета http потоковый ответ не отдаёт по строкам.
class StatsScreen extends StatefulWidget {
  final String apiBase;
  final String? serverName;
  final Map<String, String> tagNames;
  const StatsScreen({
    super.key,
    required this.apiBase,
    required this.serverName,
    required this.tagNames,
  });

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  Timer? _timer;
  int _down = 0; // накоплено за сеанс ядра, байт
  int _up = 0;
  int _speedDown = 0; // байт/с
  int _speedUp = 0;
  int _active = 0;
  int? _prevDown;
  int? _prevUp;
  DateTime? _prevAt;
  String? _error;
  // История скорости для графика. 60 точек — минута при шаге в секунду.
  final List<int> _histDown = [];
  final List<int> _histUp = [];
  // Топ хостов по сумме трафика в текущих соединениях.
  List<(String, int)> _top = [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final resp = await http
          .get(Uri.parse('${widget.apiBase}/connections'))
          .timeout(const Duration(seconds: 3));
      if (!mounted) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final down = (data['downloadTotal'] as num?)?.toInt() ?? 0;
      final up = (data['uploadTotal'] as num?)?.toInt() ?? 0;
      final conns = (data['connections'] as List?) ?? [];

      final now = DateTime.now();
      int sd = 0, su = 0;
      if (_prevDown != null && _prevAt != null) {
        final dt = now.difference(_prevAt!).inMilliseconds;
        if (dt > 0) {
          // Счётчики ядра сбрасываются при его перезапуске — отрицательную
          // разницу считаем нулём, иначе график уходит в минус.
          sd = ((down - _prevDown!) * 1000 / dt).round().clamp(0, 1 << 40);
          su = ((up - _prevUp!) * 1000 / dt).round().clamp(0, 1 << 40);
        }
      }

      // Сумма по хосту: одно соединение с сайтом редко бывает одно, поэтому
      // складываем по имени, иначе в топе окажется десяток строк одного домена.
      final byHost = <String, int>{};
      for (final c in conns) {
        final m = (c['metadata'] as Map?) ?? {};
        final host = (m['host'] as String?)?.isNotEmpty == true
            ? m['host'] as String
            : (m['destinationIP'] as String? ?? '?');
        final bytes = ((c['download'] as num?)?.toInt() ?? 0) +
            ((c['upload'] as num?)?.toInt() ?? 0);
        byHost[host] = (byHost[host] ?? 0) + bytes;
      }
      final top = byHost.entries.map((e) => (e.key, e.value)).toList()
        ..sort((a, b) => b.$2.compareTo(a.$2));

      setState(() {
        _down = down;
        _up = up;
        _active = conns.length;
        _speedDown = sd;
        _speedUp = su;
        _top = top.take(5).toList();
        _error = null;
        if (_prevDown != null) {
          _histDown.add(sd);
          _histUp.add(su);
          if (_histDown.length > 60) _histDown.removeAt(0);
          if (_histUp.length > 60) _histUp.removeAt(0);
        }
      });
      _prevDown = down;
      _prevUp = up;
      _prevAt = now;
    } catch (e) {
      if (mounted) setState(() => _error = t('conn.noCore'));
    }
  }

  String _fmt(num b) {
    if (b < 1024) return '$b ${t('unit.b')}';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} ${t('unit.kb')}';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} ${t('unit.mb')}';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} ${t('unit.gb')}';
  }

  Widget _bigNumber(IconData icon, Color color, String value, String label) => Expanded(
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            FittedBox(
              child: Text(value,
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, color: color)),
            ),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('stats.title'))),
      body: _error != null
          ? Center(child: Text(_error!))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.serverName != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '${t('stat.server')}: ${widget.serverName}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                    child: Row(
                      children: [
                        _bigNumber(Icons.south, Colors.lightBlueAccent,
                            '${_fmt(_speedDown)}/${t('unit.s')}', t('stats.speedDown')),
                        _bigNumber(Icons.north, Colors.orangeAccent,
                            '${_fmt(_speedUp)}/${t('unit.s')}', t('stats.speedUp')),
                      ],
                    ),
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('stats.lastMinute'),
                            style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 90,
                          child: CustomPaint(
                            painter: _SpeedChartPainter(
                              down: _histDown,
                              up: _histUp,
                              downColor: Colors.lightBlueAccent,
                              upColor: Colors.orangeAccent,
                              gridColor: scheme.onSurfaceVariant.withValues(alpha: 0.2),
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                    child: Row(
                      children: [
                        _bigNumber(Icons.download, scheme.onSurface, _fmt(_down),
                            t('stats.totalDown')),
                        _bigNumber(Icons.upload, scheme.onSurface, _fmt(_up),
                            t('stats.totalUp')),
                        _bigNumber(Icons.link, scheme.onSurface, '$_active',
                            t('stats.active')),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(t('stats.topHosts'),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (_top.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(t('conn.none'), style: const TextStyle(fontSize: 12)),
                  ),
                ..._top.map((e) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(e.$1, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(_fmt(e.$2), style: const TextStyle(fontSize: 12)),
                    )),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(t('stats.note'),
                      style: const TextStyle(fontSize: 11, height: 1.35)),
                ),
              ],
            ),
    );
  }
}

// График скорости за последнюю минуту. Своими руками, без пакета: две
// ломаные на общем масштабе, сетка из трёх линий. Масштаб — по максимуму
// из обоих рядов, иначе отдача (обычно на порядок меньше) вырождается
// в прямую по нижнему краю.
class _SpeedChartPainter extends CustomPainter {
  final List<int> down;
  final List<int> up;
  final Color downColor;
  final Color upColor;
  final Color gridColor;
  _SpeedChartPainter({
    required this.down,
    required this.up,
    required this.downColor,
    required this.upColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (down.length < 2) return;

    var maxV = 1;
    for (final v in [...down, ...up]) {
      if (v > maxV) maxV = v;
    }

    void line(List<int> data, Color color) {
      final p = Path();
      for (var i = 0; i < data.length; i++) {
        final x = size.width * i / (data.length - 1);
        final y = size.height - size.height * data[i] / maxV;
        i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
      }
      canvas.drawPath(
        p,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    line(down, downColor);
    line(up, upColor);
  }

  @override
  bool shouldRepaint(covariant _SpeedChartPainter old) =>
      old.down != down || old.up != up;
}

class ConnectionsScreen extends StatefulWidget {
  final String apiBase;
  final Map<String, String> tagNames;
  const ConnectionsScreen({super.key, required this.apiBase, required this.tagNames});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  Timer? _timer;
  List<dynamic> _connections = [];
  String _filter = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final resp = await http
          .get(Uri.parse('${widget.apiBase}/connections'))
          .timeout(const Duration(seconds: 3));
      if (!mounted) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      setState(() {
        _connections = (data['connections'] as List?) ?? [];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = t('conn.noCore'));
    }
  }

  Future<void> _close(String? id) async {
    try {
      final uri = id == null
          ? Uri.parse('${widget.apiBase}/connections')
          : Uri.parse('${widget.apiBase}/connections/$id');
      await http.delete(uri).timeout(const Duration(seconds: 3));
      await _refresh();
    } catch (_) {}
  }

  String _fmt(num b) {
    if (b < 1024) return '$b ${t('unit.b')}';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} ${t('unit.kb')}';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} ${t('unit.mb')}';
  }

  String _age(String? start) {
    if (start == null) return '';
    // Имя tm, а не t: t — функция перевода, локальная переменная её перекрыла бы.
    final tm = DateTime.tryParse(start);
    if (tm == null) return '';
    final s = DateTime.now().difference(tm).inSeconds;
    return s < 60
        ? '$s ${t('unit.s')}'
        : '${s ~/ 60}${t('unit.m')} ${s % 60}${t('unit.s')}';
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.trim().toLowerCase();
    final visible = _connections.where((c) {
      if (query.isEmpty) return true;
      final m = (c['metadata'] as Map?) ?? {};
      return '${m['host']}${m['destinationIP']}'.toLowerCase().contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('${t('conn.title')} (${visible.length})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close_fullscreen),
            tooltip: t('conn.closeAll'),
            onPressed: () => _close(null),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(
                hintText: t('conn.filter'),
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: const TextStyle(color: Colors.amberAccent)),
            ),
          Expanded(
            child: visible.isEmpty
                ? Center(child: Text(t('conn.none')))
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final c = visible[i] as Map<String, dynamic>;
                      final m = (c['metadata'] as Map?) ?? {};
                      final chains = (c['chains'] as List?)?.cast<String>() ?? [];
                      // chains[0] — реально использованный outbound; дальше идут
                      // селекторы, через которые он выбран.
                      final tag = chains.isNotEmpty ? chains.first : '?';
                      final via = widget.tagNames[tag] ?? tag;
                      final direct = tag == 'direct';
                      final host = (m['host'] as String?)?.isNotEmpty == true
                          ? m['host']
                          : (m['destinationIP'] ?? '?');

                      return ListTile(
                        dense: true,
                        leading: Icon(
                          direct ? Icons.call_made : Icons.vpn_lock,
                          size: 18,
                          color: direct ? Colors.greenAccent : Colors.lightBlueAccent,
                        ),
                        title: Text('$host:${m['destinationPort'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${direct ? t('conn.direct') : tp('conn.via', {'name': via})}'
                          ' · ${m['network'] ?? ''}'
                          ' · ${t('conn.rule')}: ${c['rule'] ?? '?'}'
                          '${(c['rulePayload'] as String?)?.isNotEmpty == true ? ' (${c['rulePayload']})' : ''}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('↓ ${_fmt(c['download'] ?? 0)}  ↑ ${_fmt(c['upload'] ?? 0)}',
                                style: const TextStyle(fontSize: 11)),
                            Text(_age(c['start'] as String?),
                                style: const TextStyle(fontSize: 10, color: Colors.grey)),
                          ],
                        ),
                        onLongPress: () => _close(c['id'] as String?),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// Щит-выключатель на главном экране. Заливка поднимается волной при
// подключении и уходит при отключении — состояние читается мгновенно,
// без чтения подписей.
class ShieldPower extends StatefulWidget {
  final bool active;
  final VoidCallback onTap;
  // Высота щита задаётся снаружи: при масштабировании Windows 125–150 %
  // логической высоты окна остаётся мало, и фиксированные 196 px съедали
  // экран так, что переключатель TUN уезжал под срез, а страницу
  // приходилось прокручивать. Ширина считается от высоты, чтобы щит не плющило.
  final double height;
  // Идёт запуск или остановка: вместо значка крутится индикатор, чтобы
  // было видно, что нажатие принято и работа идёт.
  final bool busy;
  const ShieldPower({
    super.key,
    required this.active,
    required this.onTap,
    this.height = 196,
    this.busy = false,
  });

  @override
  State<ShieldPower> createState() => _ShieldPowerState();
}

class _ShieldPowerState extends State<ShieldPower> with TickerProviderStateMixin {
  // Две независимые анимации: волна бежит бесконечно, уровень поднимается
  // один раз при смене состояния. Если делать одним контроллером, волна
  // замирает вместе с заливкой и выглядит мёртвой.
  late final AnimationController _wave =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  late final AnimationController _level = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: widget.active ? 1 : 0,
  );
  // Третья анимация — только на время работы. Заливка показывает, СКОЛЬКО
  // осталось, но при автовыборе она ползёт вверх незаметно медленно, и щит
  // выглядит застывшим. Бегущий сегмент даёт движение, которое видно сразу.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    // Экран может быть построен уже в состоянии «идёт запуск» — например,
    // при автоподключении сразу после старта.
    if (widget.busy) _spin.repeat();
  }

  @override
  void didUpdateWidget(covariant ShieldPower old) {
    super.didUpdateWidget(old);
    if (widget.busy != old.busy) {
      if (widget.busy) {
        _spin.repeat();
      } else {
        _spin.stop();
        _spin.value = 0;
      }
    }
    // Подключение показываем самой заливкой, а не отдельным колесиком:
    // вода медленно прибывает, пока идёт работа, и доливается до верха,
    // когда соединение поднялось. Крутящийся индикатор поверх щита выглядел
    // приклеенным к чужой картинке.
    if (widget.busy && !old.busy && !widget.active) {
      // До 65 %, а не до верха: полный щит должен означать «подключено»,
      // иначе успех ничем не отличается от ожидания. Восемь секунд — с
      // запасом на автовыбор по всем серверам; дойдя, вода просто ждёт.
      _level.animateTo(0.65,
          duration: const Duration(seconds: 8), curve: Curves.easeOut);
      return;
    }
    if (widget.active != old.active) {
      // forward/reverse идут от текущего уровня: если вода уже поднялась
      // наполовину, дольётся оставшееся, а не дёрнется с нуля.
      widget.active ? _level.forward() : _level.reverse();
      return;
    }
    // Работа закончилась, а подключения нет — не получилось, сливаем.
    if (!widget.busy && old.busy && !widget.active) {
      _level.reverse();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    _level.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.active ? t('home.disconnect') : t('home.connect'),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          // 168/196 — исходные пропорции щита.
          width: widget.height * 168 / 196,
          height: widget.height,
          child: AnimatedBuilder(
            animation: Listenable.merge([_wave, _level, _spin]),
            builder: (context, _) {
              // Щит слегка сжимается и разжимается за тот же оборот, что
              // проходит бегущий сегмент. Шесть процентов — намеренно мало:
              // на этом месте лежит кнопка, и заметное «дыхание» под курсором
              // читается как дрожь, а не как работа.
              final squeeze = widget.busy
                  ? 1 - 0.06 * (0.5 - 0.5 * math.cos(_spin.value * 2 * math.pi))
                  : 1.0;
              return Transform.scale(
                scale: squeeze,
                child: CustomPaint(
                  painter: _ShieldPainter(
                    phase: _wave.value,
                    fill: Curves.easeInOut.transform(_level.value),
                    // null — работы нет, сегмент не рисуется вовсе.
                    spin: widget.busy ? _spin.value : null,
                    accent: scheme.primary,
                    outline: scheme.outlineVariant,
                    surface: scheme.surfaceContainerHighest,
                  ),
                  child: Center(
                    child: Icon(
                      widget.active ? Icons.lock_rounded : Icons.power_settings_new_rounded,
                      size: widget.height * 44 / 196,
                      color: _level.value > 0.55 ? scheme.onPrimary : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ShieldPainter extends CustomPainter {
  final double phase;
  final double fill;
  /// Положение бегущего сегмента, 0..1. `null` — работы нет, не рисуем.
  final double? spin;
  final Color accent;
  final Color outline;
  final Color surface;

  _ShieldPainter({
    required this.phase,
    required this.fill,
    required this.spin,
    required this.accent,
    required this.outline,
    required this.surface,
  });

  // Классический щит: плечи сверху, сужение к острию снизу.
  Path _shield(Size s) {
    final w = s.width, h = s.height;
    return Path()
      ..moveTo(w * 0.5, h * 0.02)
      ..lineTo(w * 0.94, h * 0.17)
      ..cubicTo(w * 0.94, h * 0.62, w * 0.86, h * 0.85, w * 0.5, h * 0.99)
      ..cubicTo(w * 0.14, h * 0.85, w * 0.06, h * 0.62, w * 0.06, h * 0.17)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final shield = _shield(size);

    canvas.drawPath(shield, Paint()..color = surface.withValues(alpha: 0.5));

    if (fill > 0.001) {
      canvas.save();
      canvas.clipPath(shield);
      // Уровень воды: чуть выше границы, чтобы гребни волны не срезались.
      final level = size.height * (1.08 - fill * 1.12);
      final amp = 7.0 * (1 - fill * 0.35);
      final water = Path()..moveTo(0, level);
      for (double x = 0; x <= size.width; x += 4) {
        final y = level +
            math.sin((x / size.width * 2 * math.pi * 1.6) + phase * 2 * math.pi) * amp +
            math.sin((x / size.width * 2 * math.pi * 2.7) + phase * 3.1 * math.pi) * amp * 0.35;
        water.lineTo(x, y);
      }
      water
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        water,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [accent.withValues(alpha: 0.95), accent],
          ).createShader(Offset.zero & size),
      );
      canvas.restore();
    }

    canvas.drawPath(
      shield,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = fill > 0.5 ? accent : outline,
    );

    // Бегущий по контуру сегмент — индикатор работы. Это тот же «кружочек»,
    // только формы щита: обычное колесо поверх картинки выглядело приклеенным
    // (уже пробовали и отказались), а сегмент на собственной границе читается
    // как часть щита и не спорит с волной внутри.
    final position = spin;
    if (position != null) {
      final metrics = shield.computeMetrics().toList();
      if (metrics.isNotEmpty) {
        final metric = metrics.first;
        final total = metric.length;
        // Пятая часть периметра: короче — теряется на фоне обводки, длиннее —
        // перестаёт читаться как движение.
        final segment = total * 0.2;
        final start = (position % 1.0) * total;
        final runner = Path();
        if (start + segment <= total) {
          runner.addPath(metric.extractPath(start, start + segment), Offset.zero);
        } else {
          // Через шов замкнутого контура: хвост и голова отдельными кусками,
          // иначе сегмент раз в оборот пропадал бы на месте стыка.
          runner
            ..addPath(metric.extractPath(start, total), Offset.zero)
            ..addPath(metric.extractPath(0, start + segment - total), Offset.zero);
        }
        // Сначала размытая подложка, поверх — чёткая линия: так сегмент виден
        // и на светлой теме, где акцентный цвет сам по себе бледный.
        canvas.drawPath(
          runner,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6
            ..strokeCap = StrokeCap.round
            ..color = accent.withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        canvas.drawPath(
          runner,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..strokeCap = StrokeCap.round
            ..color = accent,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ShieldPainter old) =>
      old.phase != phase ||
      old.fill != fill ||
      old.spin != spin ||
      old.accent != accent;
}

// Правила для популярных сервисов: каждому можно задать «через VPN»,
// «напрямую» или «блокировать». Пусто = сервис идёт по общему режиму
// маршрутизации, поэтому в настройках хранится только осознанно выбранное.
// Правила для отдельных программ: путь к .exe -> proxy | direct | block.
// Работает и в TUN, и в обычном режиме — проверено запуском (см. CLAUDE.md).
class AppRulesScreen extends StatefulWidget {
  final AppSettings initial;
  const AppRulesScreen({super.key, required this.initial});

  @override
  State<AppRulesScreen> createState() => _AppRulesScreenState();
}

class _AppRulesScreenState extends State<AppRulesScreen> {
  late Map<String, String> _rules;
  // Запущенные программы: путь -> имя. Список берётся один раз по кнопке,
  // а не при открытии экрана: опрос процессов занимает около секунды, и
  // платить эту секунду тем, кто зашёл посмотреть уже готовые правила, незачем.
  Map<String, String>? _running;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _rules = Map<String, String>.from(widget.initial.appRules);
  }

  Future<void> _loadRunning() async {
    setState(() => _loading = true);
    final found = <String, String>{};
    // На Android программу опознают по имени пакета, и список даёт система, а
    // не перечисление процессов. Без этой ветки экран на телефоне был мёртвым:
    // кнопка звала PowerShell, которого там нет, список молча оставался пустым,
    // и добавить правило было НЕЧЕМ — второй способ, «выбрать файл», ищет .exe.
    // Показываем только пользовательские программы: системных пакетов под сотню,
    // и человек ищет в этом списке свой мессенджер, а не службы Android.
    if (!Env.appRulesUsePaths) {
      try {
        for (final app in await AndroidVpn.installedApps()) {
          found[app.package] = app.name;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _running = found;
        _loading = false;
      });
      return;
    }
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        // Только процессы текущего пользователя имеют читаемый ExecutablePath
        // из неэлевированной сессии — системные молча отсеются сами.
        'Get-CimInstance Win32_Process | Where-Object { \$_.ExecutablePath } | '
            'Select-Object Name,ExecutablePath | ConvertTo-Json -Compress',
      ]).timeout(const Duration(seconds: 15));
      final decoded = jsonDecode(result.stdout.toString());
      final list = decoded is List ? decoded : [decoded];
      for (final e in list) {
        if (e is! Map) continue;
        final path = e['ExecutablePath'] as String?;
        final name = e['Name'] as String?;
        if (path == null || path.isEmpty || name == null) continue;
        found[path] = name;
      }
    } catch (_) {
      // Не получилось — экран остаётся рабочим, программу можно добавить
      // файловым диалогом.
    }
    if (!mounted) return;
    setState(() {
      _running = found;
      _loading = false;
    });
  }

  Future<void> _addByFile() async {
    final file = await openFile(acceptedTypeGroups: [
      XTypeGroup(label: t('app.exeFiles'), extensions: const ['exe']),
    ]);
    if (file == null) return;
    setState(() => _rules[file.path] = 'proxy');
  }

  IconData _iconFor(String action) => switch (action) {
        'proxy' => Icons.vpn_lock,
        'direct' => Icons.call_made,
        'block' => Icons.block,
        _ => Icons.remove,
      };

  Widget _actionPicker(String path) => DropdownButton<String>(
        value: _rules[path] ?? 'default',
        underline: const SizedBox.shrink(),
        items: AppSettings.serviceActions.entries
            .map((e) => DropdownMenuItem(
                  value: e.key,
                  child: Text(t(e.value), style: const TextStyle(fontSize: 13)),
                ))
            .toList(),
        onChanged: (v) => setState(() {
          if (v == null || v == 'default') {
            _rules.remove(path);
          } else {
            _rules[path] = v;
          }
        }),
      );

  @override
  Widget build(BuildContext context) {
    // Уже настроенные программы всегда сверху и всегда видны, даже если сейчас
    // не запущены: иначе выключенное правило невозможно было бы снять.
    final configured = _rules.keys.toList()..sort();
    final running = (_running ?? {})
        .entries
        .where((e) => !_rules.containsKey(e.key))
        .toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));

    return Scaffold(
      appBar: AppBar(
        title: Text(t('app.title2')),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: t('common.save'),
            onPressed: () => Navigator.pop(
                context, AppSettings.from(widget.initial, appRules: _rules)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          Text(t(Env.appRulesUsePaths ? 'app.intro' : 'app.introAndroid'),
              style: const TextStyle(fontSize: 12, height: 1.35)),
          // Предупреждение про путь с номером версии осмысленно только там, где
          // правило и есть путь.
          if (Env.appRulesUsePaths) ...[
            const SizedBox(height: 8),
            Text(t('app.versionedPathNote'),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: _loading
                      ? const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.memory, size: 18),
                  label: Text(
                      t(Env.appRulesUsePaths ? 'app.listRunning' : 'app.listInstalled')),
                  onPressed: _loading ? null : _loadRunning,
                ),
              ),
              // Выбор файла — только на рабочем столе: на Android приложения
              // задаются именем пакета, файлового пути у них нет вовсе.
              if (Env.appRulesUsePaths) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(t('app.addByFile')),
                    onPressed: _addByFile,
                  ),
                ),
              ],
            ],
          ),
          const Divider(height: 24),
          if (configured.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(t('app.none'), style: const TextStyle(fontSize: 12)),
            ),
          ...configured.map((path) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(_iconFor(_rules[path] ?? 'default'), size: 20),
                title: Text(path.split(Platform.pathSeparator).last),
                subtitle: Text(path,
                    style: const TextStyle(fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: _actionPicker(path),
              )),
          if (running.isNotEmpty) ...[
            const Divider(height: 24),
            Text(t(Env.appRulesUsePaths ? 'app.running' : 'app.installed'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            ...running.map((e) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.circle_outlined, size: 20),
                  title: Text(e.value),
                  subtitle: Text(e.key,
                      style: const TextStyle(fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: _actionPicker(e.key),
                )),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class ServiceRulesScreen extends StatefulWidget {
  final AppSettings initial;
  const ServiceRulesScreen({super.key, required this.initial});

  @override
  State<ServiceRulesScreen> createState() => _ServiceRulesScreenState();
}

class _ServiceRulesScreenState extends State<ServiceRulesScreen> {
  late Map<String, String> _rules;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _rules = Map<String, String>.from(widget.initial.serviceRules);
  }

  IconData _iconFor(String action) => switch (action) {
        'proxy' => Icons.vpn_lock,
        'direct' => Icons.call_made,
        'block' => Icons.block,
        _ => Icons.remove,
      };

  Color? _colorFor(String action, ColorScheme s) => switch (action) {
        'proxy' => Colors.lightBlueAccent,
        'direct' => Colors.greenAccent,
        'block' => Colors.redAccent,
        _ => s.onSurfaceVariant,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = _search.trim().toLowerCase();
    final services = AppSettings.serviceDomains.keys
        .where((s) => query.isEmpty || s.toLowerCase().contains(query))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(t('svc.title')),
        actions: [
          IconButton(
            tooltip: t('svc.resetAll'),
            icon: const Icon(Icons.restart_alt),
            onPressed: () => setState(() => _rules.clear()),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(
              context,
              AppSettings.from(widget.initial, serviceRules: _rules),
            ),
            icon: const Icon(Icons.check),
            label: Text(t('common.save')),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              decoration: InputDecoration(
                hintText: t('svc.search'),
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              t('svc.intro'),
              style: const TextStyle(fontSize: 12, height: 1.35),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: services.length,
              itemBuilder: (context, i) {
                final name = services[i];
                final action = _rules[name] ?? 'default';
                final domains = AppSettings.serviceDomains[name]!;
                final brand = AppSettings.serviceIcons[name];
                return ListTile(
                  dense: true,
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: Color(brand?.$2 ?? 0xFF607D8B).withValues(alpha: 0.18),
                        child: Icon(brand?.$1 ?? Icons.public,
                            size: 17, color: Color(brand?.$2 ?? 0xFF607D8B)),
                      ),
                      // Точка с текущим назначением поверх значка: иначе, чтобы
                      // понять состояние строки, приходится читать выпадающий
                      // список в конце строки.
                      if (action != 'default')
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: scheme.surface,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(_iconFor(action),
                                size: 11, color: _colorFor(action, scheme)),
                          ),
                        ),
                    ],
                  ),
                  title: Text(name),
                  subtitle: Text(
                    domains.take(3).join(', ') + (domains.length > 3 ? '…' : ''),
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: DropdownButton<String>(
                    value: action,
                    underline: const SizedBox.shrink(),
                    items: AppSettings.serviceActions.entries
                        .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(t(e.value), style: const TextStyle(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() {
                      if (v == null || v == 'default') {
                        _rules.remove(name);
                      } else {
                        _rules[name] = v;
                      }
                    }),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Экран добавления профиля: список способов вместо выпадающего меню на
// иконке «+». Пункты, которых нет, показаны отключёнными с пояснением —
// так видно состав, и не выглядит, будто их забыли.
class AddProfileScreen extends StatelessWidget {
  final VoidCallback onLink;
  final VoidCallback onFile;
  final VoidCallback onText;
  final VoidCallback onQr;

  /// Сканирование камерой. `null` там, где камеры нет, — тогда пункта
  /// в списке не будет вовсе.
  final VoidCallback? onScan;
  final VoidCallback onExport;
  final VoidCallback onImport;

  const AddProfileScreen({
    super.key,
    required this.onLink,
    required this.onFile,
    required this.onText,
    required this.onQr,
    this.onScan,
    required this.onExport,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, String title, String hint, VoidCallback? tap) => ListTile(
          leading: Icon(icon, color: tap == null ? Theme.of(context).disabledColor : null),
          title: Text(title),
          subtitle: Text(hint, style: const TextStyle(fontSize: 11)),
          trailing: const Icon(Icons.chevron_right),
          enabled: tap != null,
          onTap: tap == null
              ? null
              : () {
                  Navigator.pop(context);
                  tap();
                },
        );

    return Scaffold(
      appBar: AppBar(title: Text(t('addp.title'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          row(Icons.link, t('addp.link'), t('addp.linkSub'), onLink),
          row(Icons.content_paste, t('addp.paste'), t('addp.pasteSub'), onText),
          row(Icons.insert_drive_file_outlined, t('addp.file'), t('addp.fileSub'), onFile),
          // Сканирование выше импорта картинки: если камера есть, это и есть
          // обычный способ, а картинка — запасной.
          if (onScan != null)
            row(Icons.qr_code_scanner, t('addp.scan'), t('addp.scanSub'), onScan),
          row(Icons.image_outlined, t('addp.qr'), t('addp.qrSub'), onQr),
          const Divider(height: 24),
          row(Icons.save_alt, t('addp.export'), t('addp.exportSub'), onExport),
          row(Icons.settings_backup_restore, t('addp.import'), t('addp.importSub'), onImport),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              t('addp.backupWarn'),
              style: const TextStyle(fontSize: 11, height: 1.35),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(t('qr.hint'),
                style: const TextStyle(fontSize: 11, height: 1.35)),
          ),
        ],
      ),
    );
  }
}
