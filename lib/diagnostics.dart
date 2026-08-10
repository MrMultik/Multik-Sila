import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import "package:http/http.dart" as http;
import "l10n.dart";
import "platform_env.dart";

class DiagCheck {
  final String name;
  String status; // pending | ok | fail
  String detail;
  DiagCheck(this.name, {this.status = 'pending', this.detail = ''});
}

/// Просмотр конфигов, которые приложение отдало ядрам.
///
/// Пока это можно было увидеть только открыв папку рядом с .exe, а вопрос
/// «почему трафик пошёл не туда» решается именно чтением route.rules. Файлы
/// показываем как есть, без разбора: любая наша интерпретация тут только
/// добавила бы шанс соврать.
class ConfigViewScreen extends StatefulWidget {
  final String appDir;
  const ConfigViewScreen({super.key, required this.appDir});

  @override
  State<ConfigViewScreen> createState() => _ConfigViewScreenState();
}

class _ConfigViewScreenState extends State<ConfigViewScreen> {
  // Мосты Xray в TUN-режиме поднимаются по файлу на сервер, поэтому список
  // строится из каталога, а не задаётся жёстко.
  List<File> _files = [];
  File? _selected;
  String _content = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final dir = Directory(widget.appDir);
    final found = <File>[];
    try {
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        // Журнал самого ядра — здесь же, рядом с конфигами.
        //
        // На Windows вывод ядра идёт в общий лог приложения: ядро там отдельный
        // процесс, его stdout/stderr можно читать. На Android оно вкомпилировано
        // в приложение, и его лог не виден НИГДЕ — только этим файлом. Ровно на
        // этом уже сгорел разбор: туннель поднят, пакеты в него идут, наружу не
        // выходит ничего, и ни одной строки о причине.
        if (name == 'config.json' ||
            name == 'xray_config.json' ||
            name == 'core_log.txt' ||
            name == 'core_panic.txt' ||
            name.startsWith('xray_bridge_')) {
          found.add(e);
        }
      }
    } catch (_) {}
    found.sort((a, b) => a.path.compareTo(b.path));
    if (!mounted) return;
    setState(() {
      _files = found;
      _loading = false;
    });
    if (found.isNotEmpty) await _open(found.first);
  }

  // Журнал ядра растёт неограниченно, а нужен всегда конец. Читать целиком —
  // значит однажды положить экран на многомегабайтном файле.
  static const int _tailBytes = 256 * 1024;

  Future<void> _open(File f) async {
    try {
      final length = await f.length();
      final text = length > _tailBytes
          // allowMalformed: срез начат с произвольного байта, и на границе
          // многобайтного символа декодер иначе бросит исключение.
          ? utf8
              .decode(
                  await f.openRead(length - _tailBytes).expand((c) => c).toList(),
                  allowMalformed: true)
              .split('\n')
              // Первая строка почти наверняка обрезана посередине.
              .skip(1)
              .join('\n')
          : await f.readAsString();
      if (!mounted) return;
      setState(() {
        _selected = f;
        _content = text;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _selected = f;
        _content = '$e';
      });
    }
  }

  String _name(File f) => f.path.split(Platform.pathSeparator).last;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('cfg.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: t('log.copy'),
            onPressed: _content.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _content));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t('log.copied'))),
                      );
                    }
                  },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t('net.refresh'),
            onPressed: _scan,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(t('cfg.none'), style: const TextStyle(height: 1.4)),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 48,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: _files
                            .map((f) => Padding(
                                  padding: const EdgeInsets.only(right: 8, top: 6),
                                  child: ChoiceChip(
                                    label: Text(_name(f),
                                        style: const TextStyle(fontSize: 12)),
                                    selected: _selected?.path == f.path,
                                    onSelected: (_) => _open(f),
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                    const Divider(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        // Горизонтальная прокрутка обязательна: строки конфига
                        // длинные, а перенос ломает читаемость JSON.
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SelectableText(
                            _content,
                            style: const TextStyle(
                                fontFamily: 'Consolas', fontSize: 11, height: 1.35),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// Сетевые интерфейсы и маршруты по умолчанию.
///
/// Нужен ровно для одной беды, на которой уже сгорел целый прогон TUN: за
/// маршрут по умолчанию борются несколько адаптеров. У пользователя рядом
/// работает v2rayN со своим `xray_tun`, у которого маршрут с метрикой 0 —
/// и наш `SilaTUN`, поднявшись, оказывается не первым. Наружу это выглядит
/// как «VPN включён, а данные не идут», и без этой таблицы причина не видна.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  List<Map<String, dynamic>> _routes = [];
  List<Map<String, dynamic>> _interfaces = [];
  final Map<String, List<String>> _addresses = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // OutputEncoding обязателен: без него PowerShell 5.1 отдаёт консольную
      // кодировку, и «Беспроводная сеть» приезжает мусором.
      const script = r'''
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | Select-Object ifIndex,NextHop,RouteMetric,InterfaceAlias
$i = Get-NetIPInterface -AddressFamily IPv4 -EA SilentlyContinue | Select-Object ifIndex,InterfaceAlias,InterfaceMetric,ConnectionState
@{routes=@($r);interfaces=@($i)} | ConvertTo-Json -Depth 4 -Compress
''';
      final r = await Process.run('powershell', ['-NoProfile', '-Command', script],
              stdoutEncoding: utf8)
          .timeout(const Duration(seconds: 20));
      final data = jsonDecode('${r.stdout}'.trim()) as Map<String, dynamic>;

      // Адреса берём средствами Dart: PowerShell для этого звать незачем.
      _addresses.clear();
      for (final iface in await NetworkInterface.list(includeLoopback: false)) {
        _addresses[iface.name] = iface.addresses.map((a) => a.address).toList();
      }

      if (!mounted) return;
      setState(() {
        _routes = (data['routes'] as List).cast<Map<String, dynamic>>();
        _interfaces = (data['interfaces'] as List).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  int _metric(Map<String, dynamic> r) => (r['RouteMetric'] as num?)?.toInt() ?? 9999;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final routes = [..._routes]..sort((a, b) => _metric(a).compareTo(_metric(b)));
    // Спорят те, у кого метрика равна минимальной: именно между ними система
    // выбирает, куда уйдёт трафик по умолчанию.
    final best = routes.isEmpty ? null : _metric(routes.first);
    final contested = routes.where((r) => _metric(r) == best).length > 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(t('net.title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t('net.refresh'),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('${t('net.failed')}\n\n$_error'),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (contested)
                      Card(
                        color: scheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(t('net.contested'),
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: scheme.onErrorContainer)),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(t('net.defaultRoutes'),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    if (routes.isEmpty)
                      Text(t('net.noRoutes'), style: const TextStyle(fontSize: 12)),
                    ...routes.map((r) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            _metric(r) == best ? Icons.check_circle : Icons.circle_outlined,
                            size: 18,
                            color: _metric(r) == best ? Colors.greenAccent : null,
                          ),
                          title: Text('${r['InterfaceAlias']}'),
                          subtitle: Text(
                            '${t('net.gateway')}: ${r['NextHop']} · '
                            '${t('net.metric')}: ${r['RouteMetric']}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        )),
                    const Divider(height: 24),
                    Text(t('net.interfaces'),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ..._interfaces.map((i) {
                      final alias = '${i['InterfaceAlias']}';
                      final addrs = _addresses[alias] ?? const <String>[];
                      final up = '${i['ConnectionState']}' == 'Connected';
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(up ? Icons.lan : Icons.lan_outlined,
                            size: 18,
                            color: up ? Colors.lightBlueAccent : scheme.onSurfaceVariant),
                        title: Text(alias),
                        subtitle: Text(
                          '${t('net.metric')}: ${i['InterfaceMetric'] ?? '—'}'
                          '${addrs.isEmpty ? '' : ' · ${addrs.join(', ')}'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      );
                    }),
                  ],
                ),
    );
  }
}

/// Диагностика и тест скорости.
///
/// Проверки идут по порядку от локальных к внешним: если не отвечает свой же
/// прокси, ходить наружу бессмысленно — и по первой красной строке сразу
/// видно, на каком шаге всё встало. Экран вынесен в отдельный файл: своего
/// состояния приложения ему не нужно, всё приходит параметрами.
class DiagnosticsScreen extends StatefulWidget {
  final String apiBase;
  final int localPort;
  final bool tunMode;
  final bool coreRunning;
  final String? serverHost;
  final int? serverPort;

  const DiagnosticsScreen({
    super.key,
    required this.apiBase,
    required this.localPort,
    required this.tunMode,
    required this.coreRunning,
    this.serverHost,
    this.serverPort,
  });

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final List<DiagCheck> _checks = [];
  bool _running = false;
  bool _speedRunning = false;
  String? _speedResult;

  /// В TUN-режиме трафик заворачивается в туннель на уровне системы, локальный
  /// прокси там не участвует — обращаться к нему через findProxy нельзя.
  HttpClient _client() {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (!widget.tunMode) {
      c.findProxy = (_) => 'PROXY 127.0.0.1:${widget.localPort}';
    }
    return c;
  }

  Future<void> _step(int i, Future<String> Function() body) async {
    try {
      final detail = await body();
      if (!mounted) return;
      setState(() {
        _checks[i].status = 'ok';
        _checks[i].detail = detail;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checks[i].status = 'fail';
        _checks[i].detail = '$e';
      });
    }
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _checks
        ..clear()
        ..addAll([
          DiagCheck(t('diag.coreRunning')),
          DiagCheck(widget.tunMode ? t('diag.tunMode') : t('diag.localProxy')),
          DiagCheck(t('diag.clashApi')),
          DiagCheck(t('diag.dns')),
          DiagCheck(t('diag.server')),
          DiagCheck(t('diag.internet')),
          DiagCheck(t('diag.exitIp')),
        ]);
    });

    await _step(0, () async {
      if (!widget.coreRunning) {
        throw t('diag.notRunning');
      }
      return t('diag.works');
    });

    await _step(1, () async {
      if (widget.tunMode) return t('diag.tunNote');
      final s = await Socket.connect('127.0.0.1', widget.localPort,
          timeout: const Duration(seconds: 3));
      s.destroy();
      return "${t('diag.portOk')}: ${widget.localPort}";
    });

    await _step(2, () async {
      final r = await http
          .get(Uri.parse('${widget.apiBase}/version'))
          .timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
      return r.body.trim();
    });

    await _step(3, () async {
      final sw = Stopwatch()..start();
      final a = await InternetAddress.lookup('example.com')
          .timeout(const Duration(seconds: 5));
      sw.stop();
      return "${a.first.address} ${t('diag.in')} ${sw.elapsedMilliseconds} ${t('common.ms')}";
    });

    await _step(4, () async {
      final host = widget.serverHost;
      final port = widget.serverPort;
      if (host == null || port == null) throw t('diag.noServer');
      final sw = Stopwatch()..start();
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 6));
      sw.stop();
      s.destroy();
      return "$host:$port ${t('diag.in')} ${sw.elapsedMilliseconds} ${t('common.ms')}";
    });

    await _step(5, () async {
      final c = _client();
      try {
        final sw = Stopwatch()..start();
        final req = await c
            .getUrl(Uri.parse('https://cp.cloudflare.com/generate_204'))
            .timeout(const Duration(seconds: 12));
        final resp = await req.close().timeout(const Duration(seconds: 12));
        await resp.drain();
        sw.stop();
        return "${t('diag.code')} ${resp.statusCode} ${t('diag.in')} ${sw.elapsedMilliseconds} ${t('common.ms')}";
      } finally {
        c.close(force: true);
      }
    });

    await _step(6, () async {
      final c = _client();
      try {
        final req = await c
            .getUrl(Uri.parse('https://api.ipify.org'))
            .timeout(const Duration(seconds: 12));
        final resp = await req.close().timeout(const Duration(seconds: 12));
        return (await resp.transform(utf8.decoder).join()).trim();
      } finally {
        c.close(force: true);
      }
    });

    if (mounted) setState(() => _running = false);
  }

  Future<void> _speedTest() async {
    setState(() {
      _speedRunning = true;
      _speedResult = null;
    });
    const bytes = 20 * 1024 * 1024;
    final c = _client();
    try {
      final sw = Stopwatch()..start();
      final req = await c
          .getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=$bytes'))
          .timeout(const Duration(seconds: 20));
      final resp = await req.close().timeout(const Duration(seconds: 60));
      var received = 0;
      await for (final chunk in resp) {
        received += chunk.length;
      }
      sw.stop();
      final seconds = sw.elapsedMilliseconds / 1000;
      final mbits = (received * 8) / seconds / 1000000;
      final mb = received / 1024 / 1024;
      if (!mounted) return;
      setState(() => _speedResult = '${mbits.toStringAsFixed(1)} ${t('diag.mbits')}  ·  '
          '${mb.toStringAsFixed(1)} ${t('diag.mb')} ${t('diag.in')} '
          '${seconds.toStringAsFixed(1)} ${t('diag.sec')}');
    } catch (e) {
      if (mounted) setState(() => _speedResult = "${t('diag.speedFail')}: $e");
    } finally {
      c.close(force: true);
      if (mounted) setState(() => _speedRunning = false);
    }
  }

  Widget _statusIcon(String status) => switch (status) {
        'ok' => const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
        'fail' => const Icon(Icons.cancel, color: Colors.redAccent, size: 20),
        'pending' => const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        _ => const Icon(Icons.remove, size: 20),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('diag.title')),
        actions: [
          // Экран «Интерфейсы и маршруты» целиком построен на одном вызове
          // PowerShell (`Get-NetRoute` + `Get-NetIPInterface`). На Android
          // такого нет, и открытый экран показал бы пустоту с ошибкой. Сам
          // вопрос, ради которого он заводился — «за маршрут по умолчанию
          // борются несколько адаптеров» — там тоже не стоит: система
          // разрешает ровно один активный VPN.
          if (Env.hasWindowAndTray)
            IconButton(
              icon: const Icon(Icons.settings_ethernet),
              tooltip: t('net.title'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NetworkScreen()),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.data_object),
            tooltip: t('cfg.title'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConfigViewScreen(
                  // На Android рабочий каталог выдаёт система, и путь к
                  // исполняемому файлу к нему отношения не имеет: конфиги
                  // ядра лежат в песочнице приложения, а не рядом с ним.
                  appDir: Env.workDirOverride ??
                      File(Platform.resolvedExecutable).parent.path,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_running ? t('diag.running') : t('diag.run')),
          ),
          const SizedBox(height: 12),
          ..._checks.map(
            (c) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: _statusIcon(c.status),
              title: Text(c.name, style: const TextStyle(fontSize: 14)),
              subtitle: c.detail.isEmpty
                  ? null
                  : Text(c.detail, style: const TextStyle(fontSize: 11)),
            ),
          ),
          const Divider(height: 32),
          Text(
            t('diag.speedTitle'),
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            t('diag.speedNote'),
            style: const TextStyle(fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _speedRunning ? null : _speedTest,
            icon: _speedRunning
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download, size: 18),
            label: Text(_speedRunning ? t('diag.speedRunning') : t('diag.speedRun')),
          ),
          if (_speedResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    _speedResult!,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
