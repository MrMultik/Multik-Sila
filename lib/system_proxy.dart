import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// Применение системного прокси Windows ЧЕРЕЗ WinINET, а не только записью
/// в реестр.
///
/// Зачем отдельный модуль и FFI, если рядом уже есть `reg add`:
///
/// Значения `ProxyEnable`/`ProxyServer`/`ProxyOverride` в
/// `HKCU\...\Internet Settings` — это НЕ то, что реально читает Windows при
/// подключении. Действующая конфигурация лежит бинарным блобом в
/// `HKCU\...\Internet Settings\Connections\DefaultConnectionSettings`, и
/// именно её отдаёт `WinHttpGetIEProxyConfigForCurrentUser` — то есть то, чем
/// пользуются браузеры и почти всё остальное. Плоские значения — legacy-зеркало,
/// которое Windows синхронизирует только когда настройки меняют «правильным»
/// способом.
///
/// Как это выглядело у пользователя: приложение писало `ProxyEnable=1` и
/// `ProxyServer=127.0.0.1:1337`, честно рапортовало «Системный прокси включён»,
/// ядро поднималось и работало — а в блобе флаги оставались `0x01`
/// (PROXY_TYPE_DIRECT, «без прокси») с адресом чужого клиента. В итоге на порт
/// 1337 не приходило НИ ОДНОГО соединения: в логе три подключения подряд без
/// единой строки `inbound connection`. Со стороны — «включаю VPN, а он не
/// работает».
///
/// Второй, не менее важный эффект: даже когда значения меняются, уже
/// запущенные процессы продолжают пользоваться закэшированной конфигурацией,
/// пока им не сказали перечитать её (`INTERNET_OPTION_SETTINGS_CHANGED` +
/// `INTERNET_OPTION_REFRESH`). Отсюда были задержки в полминуты между
/// «прокси включён» и первым реальным соединением.
///
/// Третий: если у пользователя настроен PAC-скрипт (`AutoConfigURL`), он имеет
/// приоритет над фиксированным адресом прокси. Выставляя флаги явно, мы этот
/// случай закрываем — и обязаны так же явно вернуть PAC на место при остановке.
class WinInetProxy {
  // --- dwOption для InternetSetOption ---
  static const int _optionPerConnection = 75; // INTERNET_OPTION_PER_CONNECTION_OPTION
  static const int _optionSettingsChanged = 39; // INTERNET_OPTION_SETTINGS_CHANGED
  static const int _optionRefresh = 37; // INTERNET_OPTION_REFRESH

  // --- dwOption внутри INTERNET_PER_CONN_OPTION ---
  static const int _perConnFlags = 1;
  static const int _perConnProxyServer = 2;
  static const int _perConnProxyBypass = 3;
  static const int _perConnAutoconfigUrl = 4;

  // --- значения для _perConnFlags ---
  static const int _proxyTypeDirect = 1;
  static const int _proxyTypeProxy = 2;
  static const int _proxyTypeAutoProxyUrl = 4;

  // Размеры и смещения полей структур WinINET.
  //
  //   typedef struct { DWORD dwOption; union { DWORD; LPWSTR; FILETIME; }; }
  //     INTERNET_PER_CONN_OPTIONW;
  //   typedef struct { DWORD dwSize; LPWSTR pszConnection; DWORD dwOptionCount;
  //     DWORD dwOptionError; INTERNET_PER_CONN_OPTIONW* pOptions; }
  //     INTERNET_PER_CONN_OPTION_LISTW;
  //
  // Раскладка считается от размера указателя, а не прибита к x64: на x86 union
  // выравнен по 4 (там он максимум FILETIME), на x64 — по 8 (там в нём LPWSTR).
  // Ошибка в раскладке проявилась бы не падением, а тем, что WinINET прочитал
  // бы мусор и молча ничего не сделал — то есть ровно тем багом, который этот
  // модуль и чинит.
  static final int _ptrSize = sizeOf<IntPtr>();
  static int get _optionSize => _ptrSize == 8 ? 16 : 12;
  static int get _optionValueOffset => _ptrSize == 8 ? 8 : 4;
  static int get _listSize => _ptrSize == 8 ? 32 : 20;

  static final DynamicLibrary _wininet = DynamicLibrary.open('wininet.dll');

  // isLeaf: без него Dart успевает сделать своё между вызовом и GetLastError,
  // и код ошибки приезжает нулём — ровно так первый отказ и остался
  // неопознанным (`GetLastError=0`). Обе функции короткие и в Dart не
  // возвращаются, требованиям leaf-вызова удовлетворяют.
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final int Function() _getLastError = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError',
          isLeaf: true);

  /// Строки, которые `InternetQueryOption` вернул, выделены ИМ, а не нами, и
  /// освобождать их обязан вызывающий — через GlobalFree, не через
  /// `calloc.free`: это чужая куча, и free по ней в лучшем случае не сделает
  /// ничего. Утечка тут маленькая (пара строк на каждое подключение), но
  /// молчаливая, а такие живут в коде годами.
  static final Pointer<Void> Function(Pointer<Void>) _globalFree =
      _kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('GlobalFree', isLeaf: true);

  /// Код последней неудачи `InternetSetOption`. Без него отказ выглядел в логе
  /// как «не смогли» без единой подсказки, и причину пришлось искать
  /// сравнением сборок. Разбирать код не пытаемся — важны сами цифры:
  /// 5 (ACCESS_DENIED) значит, что процессу не дают писать в HKCU, а
  /// 87 (INVALID_PARAMETER) — что ядру не понравился сам список опций.
  static int lastError = 0;

  static final int Function(Pointer<Void>, int, Pointer<Void>, int) _setOption =
      _wininet.lookupFunction<
              Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
              int Function(Pointer<Void>, int, Pointer<Void>, int)>(
          'InternetSetOptionW', isLeaf: true);

  static final int Function(Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>)
      _queryOption = _wininet.lookupFunction<
              Int32 Function(
                  Pointer<Void>, Uint32, Pointer<Void>, Pointer<Uint32>),
              int Function(
                  Pointer<Void>, int, Pointer<Void>, Pointer<Uint32>)>(
          'InternetQueryOptionW', isLeaf: true);

  /// Что у Windows ДЕЙСТВИТЕЛЬНО стоит прямо сейчас. Нужна не для работы, а
  /// для лога: `InternetSetOption` умеет отказать молча (например, если ему
  /// не понравилась одна запись в списке исключений), и без обратного чтения
  /// приложение писало «прокси включён», когда система оставалась на прямом
  /// подключении. Ровно на этом расхождении и потерян день отладки.
  ///
  /// Возвращает `null`, если прочитать не удалось.
  static ({bool proxyOn, String server})? current() {
    final options = calloc<Uint8>(_optionSize * 2);
    final list = calloc<Uint8>(_listSize);
    final size = calloc<Uint32>();
    try {
      options.cast<Uint32>().value = _perConnFlags;
      (options + _optionSize).cast<Uint32>().value = _perConnProxyServer;
      list.cast<Uint32>().value = _listSize;
      (list + _ptrSize).cast<IntPtr>().value = 0;
      (list + _ptrSize * 2).cast<Uint32>().value = 2;
      (list + _ptrSize * 2 + 4).cast<Uint32>().value = 0;
      (list + _ptrSize * 3).cast<IntPtr>().value = options.address;
      size.value = _listSize;
      if (_queryOption(nullptr, _optionPerConnection, list.cast<Void>(), size) ==
          0) {
        return null;
      }
      final flags = (options + _optionValueOffset).cast<Uint32>().value;
      final addr =
          (options + _optionSize + _optionValueOffset).cast<IntPtr>().value;
      var server = '';
      if (addr != 0) {
        server = Pointer<Utf16>.fromAddress(addr).toDartString();
        _globalFree(Pointer<Void>.fromAddress(addr));
      }
      return (proxyOn: flags & _proxyTypeProxy != 0, server: server);
    } finally {
      calloc.free(options);
      calloc.free(list);
      calloc.free(size);
    }
  }

  /// Список исключений пришлось выбросить, чтобы прокси вообще включился.
  static bool bypassDropped = false;

  /// Включает фиксированный прокси `server` (вида `127.0.0.1:1337`) со списком
  /// исключений `bypass`. Возвращает false, если WinINET отказал.
  ///
  /// При отказе пробуем ещё раз БЕЗ списка исключений. WinINET отвергает весь
  /// набор опций из-за одной непонравившейся записи в списке (так было с
  /// `::1`), и цена такого отказа несоразмерна: без прокси не работает ничего,
  /// а без исключений — всего лишь локальная сеть идёт через туннель. Пусть
  /// лучше человек увидит в логе, что исключения потеряны, чем молча сидит
  /// с выключенным VPN, который показывает «подключено».
  static bool enable(String server, String bypass) {
    bypassDropped = false;
    if (_apply(
        flags: _proxyTypeDirect | _proxyTypeProxy,
        server: server,
        bypass: bypass)) {
      return true;
    }
    if (bypass.isEmpty) return false;
    final ok = _apply(
        flags: _proxyTypeDirect | _proxyTypeProxy, server: server, bypass: '');
    bypassDropped = ok;
    return ok;
  }

  /// Возврат прошёл, но не полностью — часть прежних настроек восстановить не
  /// удалось. Нужен для лога: молчать об этом нельзя, человек должен знать,
  /// что его список исключений или PAC придётся вернуть руками.
  static bool restoreDegraded = false;

  /// Возвращает конфигурацию, которая была до нас. `server` пустой — прокси
  /// был выключен; `autoConfigUrl` непустой — стоял PAC-скрипт, и он обязан
  /// вернуться, иначе мы молча сломаем человеку корпоративную сеть.
  ///
  /// ОТКАЗ ЗДЕСЬ СТРАШНЕЕ, ЧЕМ ПРИ ВКЛЮЧЕНИИ, поэтому спускаемся по лесенке.
  /// WinINET отвергает весь набор опций целиком из-за одной записи, которая
  /// ему не понравилась (проверено на `::1`), а список исключений тут — не
  /// наш, а пользовательский, и что в нём лежит, мы не знаем. Если просто
  /// вернуть false, в системе останется НАШ прокси на порту, который вот-вот
  /// умрёт вместе с ядром: интернет ляжет во всех программах разом, и чинить
  /// это будут перезагрузкой, не понимая причины. Ровно эту беду пользователь
  /// уже дважды ловил, и ради неё резерв вообще переехал в SharedPreferences.
  ///
  /// Поэтому: сначала пробуем вернуть как было; не вышло — то же самое без
  /// списка исключений; не вышло и это — выключаем прокси совсем. Остаться
  /// без прокси плохо, остаться с мёртвым прокси несравнимо хуже.
  static bool restore({
    required bool enabled,
    required String server,
    required String bypass,
    required String autoConfigUrl,
  }) {
    restoreDegraded = false;
    var flags = _proxyTypeDirect;
    if (enabled && server.isNotEmpty) flags |= _proxyTypeProxy;
    if (autoConfigUrl.isNotEmpty) flags |= _proxyTypeAutoProxyUrl;

    if (_apply(
      flags: flags,
      server: server,
      bypass: bypass,
      autoConfigUrl: autoConfigUrl,
    )) {
      return true;
    }

    restoreDegraded = true;
    if (bypass.isNotEmpty &&
        _apply(flags: flags, server: server, autoConfigUrl: autoConfigUrl)) {
      return true;
    }
    // Последний рубеж: чистое «прямое подключение». Пустые строки переданы
    // намеренно — иначе наш адрес останется лежать в PROXY_SERVER.
    return _apply(flags: _proxyTypeDirect);
  }

  static bool _apply({
    required int flags,
    String server = '',
    String bypass = '',
    String autoConfigUrl = '',
  }) {
    // Опции перечисляем ВСЕ и всегда, включая пустые: WinINET не обнуляет
    // то, чего нет в списке. Не передать пустой PROXY_SERVER при возврате в
    // «прямое подключение» значит оставить в системе наш мёртвый адрес.
    final entries = <(int, String?)>[
      (_perConnFlags, null), // null = числовое значение, лежит во flags
      (_perConnProxyServer, server),
      (_perConnProxyBypass, bypass),
      (_perConnAutoconfigUrl, autoConfigUrl),
    ];

    final options = calloc<Uint8>(_optionSize * entries.length);
    final list = calloc<Uint8>(_listSize);
    final strings = <Pointer<Utf16>>[];
    try {
      for (var i = 0; i < entries.length; i++) {
        final (option, value) = entries[i];
        final base = options + _optionSize * i;
        base.cast<Uint32>().value = option;
        final slot = base + _optionValueOffset;
        if (value == null) {
          // Числовое поле union'а — DWORD в начале тех же восьми байт.
          // calloc уже обнулил остаток, поэтому старшая половина чистая.
          slot.cast<Uint32>().value = flags;
        } else {
          final native = value.toNativeUtf16();
          strings.add(native);
          slot.cast<IntPtr>().value = native.address;
        }
      }

      list.cast<Uint32>().value = _listSize; // dwSize
      // pszConnection = NULL — это LAN-подключение, то самое
      // DefaultConnectionSettings. Именно его читают браузеры.
      (list + _ptrSize).cast<IntPtr>().value = 0;
      (list + _ptrSize * 2).cast<Uint32>().value = entries.length; // dwOptionCount
      (list + _ptrSize * 2 + 4).cast<Uint32>().value = 0; // dwOptionError
      (list + _ptrSize * 3).cast<IntPtr>().value = options.address; // pOptions

      final ok = _setOption(nullptr, _optionPerConnection, list.cast<Void>(), _listSize);
      if (ok == 0) {
        lastError = _getLastError();
        return false;
      }
      lastError = 0;

      // Без этих двух вызовов изменение доедет только до тех, кто запустится
      // ПОСЛЕ него: уже работающие браузеры и приложения держат конфигурацию
      // в памяти. Именно так выглядели «полминуты до первого соединения».
      _setOption(nullptr, _optionSettingsChanged, nullptr, 0);
      _setOption(nullptr, _optionRefresh, nullptr, 0);
      return true;
    } finally {
      for (final s in strings) {
        calloc.free(s);
      }
      calloc.free(options);
      calloc.free(list);
    }
  }
}
