import 'dart:async';

import 'package:flutter/services.dart';

/// Тонкая обёртка над каналом в андроидную службу туннеля.
///
/// Намеренно тонкая: здесь нет ни грамма логики про серверы, конфиги и
/// маршрутизацию. Всё это остаётся в общем коде, одинаковом для Windows и
/// Android, — иначе две платформы начнут расходиться в поведении, и каждая
/// правка будет требовать двух проверок вместо одной.
///
/// Что здесь есть, так это разница, которой на Windows нет вовсе: система
/// спрашивает у человека разрешение на VPN собственным диалогом, и без
/// положительного ответа туннель не поднять.
class AndroidVpn {
  static const MethodChannel _commands = MethodChannel('multik_sila/vpn');
  static const EventChannel _status = EventChannel('multik_sila/vpn_status');

  /// Разрешение на VPN. Android показывает диалог один раз и запоминает ответ,
  /// но спрашивать надо перед КАЖДЫМ запуском: разрешение отзывается, стоит
  /// человеку включить другой клиент VPN — у Android активен только один.
  ///
  /// `false` — человек отказался. Это ответ, а не сбой: показывать его надо
  /// внятно, а не оставлять выключенный щит без объяснений.
  static Future<bool> prepare() async {
    final granted = await _commands.invokeMethod<bool>('prepare');
    return granted ?? false;
  }

  /// Поднять туннель.
  ///
  /// [config] — тот же JSON sing-box, что десктопная версия пишет в
  /// `config.json`. [bridges] — конфиги мостов Xray для xhttp-серверов, по
  /// одному на сервер; на Windows они лежат файлами `xray_bridge_*.json`.
  static Future<void> start({
    required String config,
    List<String> bridges = const [],
  }) async {
    await _commands.invokeMethod<bool>('start', {
      'config': config,
      'bridges': bridges,
    });
  }

  static Future<void> stop() => _commands.invokeMethod<void>('stop');

  static Future<bool> isRunning() async =>
      await _commands.invokeMethod<bool>('isRunning') ?? false;

  /// Версии обоих ядер — спрашиваются у самих ядер, а не хранятся числом
  /// в коде. На Windows на этом уже обжигались: установленная сборка Xray
  /// оказалась новее «последнего релиза», и версия по памяти врала.
  static Future<({String singbox, String xray})> coreVersions() async {
    final map = await _commands.invokeMapMethod<String, String>('coreVersions');
    return (singbox: map?['singbox'] ?? '', xray: map?['xray'] ?? '');
  }

  /// Установленные программы — для правил «эта программа мимо VPN».
  /// Андроидный аналог правил по пути к .exe: там ключ путь, здесь имя пакета.
  static Future<List<AndroidApp>> installedApps() async {
    final raw = await _commands.invokeListMethod<Map<dynamic, dynamic>>('installedApps');
    if (raw == null) return const [];
    return raw
        .map((e) => AndroidApp(
              package: e['package'] as String? ?? '',
              name: e['name'] as String? ?? '',
              isSystem: e['system'] as bool? ?? false,
            ))
        .toList();
  }

  /// Состояние туннеля. Служба сообщает о запуске, остановке и об ошибках
  /// ядра — в том числе о тех, что случились уже после успешного старта
  /// (упавший мост Xray, отозванное системой разрешение).
  static Stream<AndroidVpnStatus> statusStream() =>
      _status.receiveBroadcastStream().map((event) {
        final map = (event as Map).cast<String, dynamic>();
        return AndroidVpnStatus(
          running: map['running'] as bool? ?? false,
          error: map['error'] as String?,
        );
      });
}

class AndroidVpnStatus {
  final bool running;
  final String? error;
  const AndroidVpnStatus({required this.running, this.error});
}

class AndroidApp {
  final String package;
  final String name;
  final bool isSystem;
  const AndroidApp({
    required this.package,
    required this.name,
    required this.isSystem,
  });
}
