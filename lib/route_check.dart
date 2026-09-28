import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import "package:http/http.dart" as http;
import "l10n.dart";

/// Адрес для проверки маршрута из того, что человек вставил: домен, IP,
/// `хост:порт`, `[IPv6]:порт` или целая ссылка. Порт по умолчанию 443 —
/// так ходит почти всё, что человек хочет проверить (сайты, приложения).
/// null — не похоже ни на домен, ни на адрес.
(String, int)? parseRouteTarget(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (s.contains('://')) {
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return null;
    return (u.host.toLowerCase(), u.hasPort ? u.port : (u.scheme == 'http' ? 80 : 443));
  }
  s = s.split('/').first;
  final v6 = RegExp(r'^\[([0-9a-fA-F:.]+)\](?::(\d{1,5}))?$').firstMatch(s);
  if (v6 != null) {
    if (InternetAddress.tryParse(v6.group(1)!) == null) return null;
    final port = int.tryParse(v6.group(2) ?? '') ?? 443;
    if (port < 1 || port > 65535) return null;
    return (v6.group(1)!, port);
  }
  // Голый IPv6 без скобок: двоеточий много, порт к нему не приписать.
  if (InternetAddress.tryParse(s)?.type == InternetAddressType.IPv6) return (s, 443);
  var port = 443;
  final hp = RegExp(r'^(.+):(\d{1,5})$').firstMatch(s);
  if (hp != null) {
    s = hp.group(1)!;
    port = int.parse(hp.group(2)!);
  }
  if (port < 1 || port > 65535) return null;
  if (InternetAddress.tryParse(s) != null) return (s, port);
  final host = s.toLowerCase();
  if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$')
      .hasMatch(host)) {
    return null;
  }
  return (host, port);
}

/// Совпадает ли адрес с записью списка правил так же, как их понимает ядро:
/// домен — как `domain_suffix` (сам домен и все поддомены), IP или подсеть —
/// как `ip_cidr`. Записи строятся в `ruleFromList` в main.dart.
bool routeEntryMatches(String host, String entry) {
  final e = entry.trim().toLowerCase();
  if (e.isEmpty || e.startsWith('#')) return false;
  final h = host.toLowerCase();
  final slash = e.indexOf('/');
  final net = InternetAddress.tryParse(slash < 0 ? e : e.substring(0, slash));
  if (net != null) {
    final addr = InternetAddress.tryParse(h);
    if (addr == null || addr.type != net.type) return false;
    final a = addr.rawAddress, b = net.rawAddress;
    final bits = slash < 0 ? a.length * 8 : int.tryParse(e.substring(slash + 1));
    if (bits == null || bits < 0 || bits > a.length * 8) return false;
    for (var i = 0; i < bits; i++) {
      final mask = 0x80 >> (i % 8);
      if ((a[i ~/ 8] & mask) != (b[i ~/ 8] & mask)) return false;
    }
    return true;
  }
  return h == e || h.endsWith('.$e');
}

/// Правило в том виде, как его пишет ядро в Clash API (`rule`), — человеческими
/// словами. Сырой текст экран показывает рядом: перевод нужен, чтобы понять
/// сказанное ядром, а не чтобы его спрятать.
String describeCoreRule(String rule) {
  final r = rule.trim();
  if (r.isEmpty) return '?';
  if (r == 'final') return t('rc.ruleFinal');
  final sets = RegExp(r'rule_set=\[([^\]]*)\]').firstMatch(r);
  if (sets != null) {
    const labels = {
      'geosite-ru': 'rc.setRuSites',
      'geoip-ru': 'rc.setRuIp',
      'geosite-ads': 'rc.setAds',
    };
    final names = sets
        .group(1)!
        .split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .map((s) => labels[s] != null ? t(labels[s]!) : s)
        .join(', ');
    return tp('rc.ruleSet', {'names': names});
  }
  if (r.contains('ip_is_private')) return t('rc.rulePrivate');
  if (r.contains('process_path') || r.contains('package_name')) return t('rc.ruleApp');
  if (r.contains('domain') || r.contains('ip_cidr')) return t('rc.ruleList');
  return r;
}

/// Что сказало ядро про пробное соединение. Ровно одно из двух: маршрут с
/// правилом или пояснение, почему маршрута не узнать.
class RouteCheckResult {
  final String? route;
  final String? rule;

  /// Правило как его написало ядро — показывается рядом с переводом.
  final String? rawRule;
  final String? note;
  const RouteCheckResult({this.route, this.rule, this.rawRule, this.note});
}

/// «Куда пойдёт этот адрес» — проверка, как экран правила в Karing.
///
/// Ответ даёт само ядро, а не наш пересказ его правил: открываем к адресу
/// пробное соединение через работающее ядро и читаем в Clash API
/// (`/connections`), через какой выход и по какому правилу ядро его пустило.
/// Пересказ разошёлся бы с ядром на первой же правке правил — а вопрос «почему
/// сайт пошёл не туда» задают как раз тогда, когда они разошлись.
///
/// В обычном режиме соединение идёт через локальный прокси (`CONNECT`), и
/// домен ядро видит сразу. В TUN — напрямую, как у любой программы: трафик
/// самого приложения туннель не исключает. Для домена на 443 это TLS-
/// рукопожатие: без него ядро без FakeIP узнало бы только IP (sniff берёт
/// домен из ClientHello), и доменные правила не сработали бы.
///
/// Отклонённое соединение в `/connections` не попадает вовсе (проверено:
/// `doubleclick.net` при блокировке рекламы — в логе ядра только «inbound
/// connection», выхода нет), а локальный прокси всё равно отвечает «200»:
/// решение принимается после ответа. Поэтому «заблокировано» выводится из того,
/// что ядро сразу закрыло соединение, а причину называем, только если нашли её
/// сами — в списке «Блокировать», в заблокированных сервисах или в наборе
/// рекламы (`sing-box rule-set match`). Не нашли — так и говорим.
///
/// Только для Windows: на Android приложение исключено из собственного VPN
/// (`addDisallowedApplication`), и пробное соединение прошло бы мимо ядра.
class RouteProber {
  final String apiBase;
  final int localPort;
  final bool tunMode;

  /// Тег outbound'а -> имя сервера: `srv_3` человеку ничего не говорит.
  final Map<String, String> tagNames;
  final List<String> customBlock;

  /// Заблокированные сервисы: имя -> их домены.
  final Map<String, List<String>> blockedServices;

  /// Набор рекламы (.srs), которым объяснять отказ; null — блокировка рекламы
  /// выключена или набора нет.
  final String? adsRuleSetPath;
  final String singBoxPath;
  final bool ipv4Only;

  const RouteProber({
    required this.apiBase,
    required this.localPort,
    required this.tunMode,
    required this.tagNames,
    required this.customBlock,
    required this.blockedServices,
    required this.adsRuleSetPath,
    required this.singBoxPath,
    required this.ipv4Only,
  });

  Future<RouteCheckResult> check(String host, int port) async {
    Socket? socket;
    var closedByCore = false;
    Object? openError;
    Map<String, dynamic>? entry;
    Object? apiError;
    try {
      final (s, done) = await _open(host, port);
      socket = s;
      // Ядро закрывает отклонённое соединение сразу, живое держится, пока мы
      // молчим. Полсекунды — с запасом: отказ приходит за миллисекунды.
      closedByCore = await Future.any([
        done.then((_) => true),
        Future.delayed(const Duration(milliseconds: 500), () => false),
      ]);
    } catch (e) {
      openError = e;
    }
    try {
      entry = await _findConnection(host);
    } catch (e) {
      apiError = e;
    }
    socket?.destroy();

    if (entry != null) {
      final chains = (entry['chains'] as List?)?.cast<String>() ?? const [];
      final out = chains.isNotEmpty ? chains.first : '?';
      final name = tagNames[out];
      var raw = '${entry['rule'] ?? ''}';
      final payload = '${entry['rulePayload'] ?? ''}';
      if (payload.isNotEmpty) raw = '$raw ($payload)';
      return RouteCheckResult(
        route: out == 'direct'
            ? t('rc.direct')
            : name != null
                ? tp('rc.viaServer', {'name': name})
                : out,
        rule: describeCoreRule('${entry['rule'] ?? ''}'),
        rawRule: raw,
      );
    }
    if (apiError != null) {
      return RouteCheckResult(note: tp('rc.apiError', {'e': apiError}));
    }
    if (closedByCore || openError != null) {
      final why = await _whyBlocked(host);
      if (why != null) return RouteCheckResult(route: t('rc.blocked'), rule: why);
      return RouteCheckResult(
          note: openError != null
              ? '${t('rc.noConnection')}\n$openError'
              : t('rc.noConnection'));
    }
    return RouteCheckResult(note: t('rc.notSeen'));
  }

  Future<String?> _whyBlocked(String host) async {
    if (customBlock.any((e) => routeEntryMatches(host, e))) {
      return t('rc.whyUserBlock');
    }
    for (final s in blockedServices.entries) {
      if (s.value.any((d) => routeEntryMatches(host, d))) {
        return tp('rc.whyService', {'name': s.key});
      }
    }
    final ads = adsRuleSetPath;
    if (ads != null && InternetAddress.tryParse(host) == null) {
      try {
        final r = await Process.run(
                singBoxPath, ['rule-set', 'match', '-f', 'binary', ads, host])
            .timeout(const Duration(seconds: 5));
        // Совпадение ядро печатает строкой «match rules.[N]: ...» — в STDERR,
        // как и весь свой лог (в stdout пусто; первая версия смотрела туда и
        // рекламу не узнавала). Промах — пустой вывод; код возврата в обоих
        // случаях 0.
        if (RegExp(r'match rules\.\[').hasMatch('${r.stdout}${r.stderr}')) {
          return t('rc.whyAds');
        }
      } catch (_) {}
    }
    if (ipv4Only && InternetAddress.tryParse(host)?.type == InternetAddressType.IPv6) {
      return t('rc.whyIpv6');
    }
    return null;
  }

  /// Открывает пробное соединение и возвращает его вместе с событием «ядро
  /// его закрыло». Бросает, если соединиться не удалось вовсе.
  Future<(Socket, Future<void>)> _open(String host, int port) async {
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    if (tunMode) {
      final isIp = InternetAddress.tryParse(host) != null;
      final Socket s = port == 443 && !isIp
          ? await SecureSocket.connect(host, 443,
              onBadCertificate: (_) => true, timeout: const Duration(seconds: 8))
          : await Socket.connect(host, port, timeout: const Duration(seconds: 8));
      s.listen((_) {}, onDone: finish, onError: (_) => finish(), cancelOnError: true);
      return (s, done.future);
    }

    final s = await Socket.connect('127.0.0.1', localPort,
        timeout: const Duration(seconds: 3));
    final reply = Completer<String>();
    final buf = StringBuffer();
    void answered() {
      if (!reply.isCompleted) reply.complete(buf.toString());
    }

    s.listen(
      (d) {
        buf.write(latin1.decode(d, allowInvalid: true));
        if (buf.toString().contains('\r\n\r\n')) answered();
      },
      onDone: () {
        answered();
        finish();
      },
      onError: (_) {
        answered();
        finish();
      },
      cancelOnError: true,
    );
    final target = host.contains(':') ? '[$host]:$port' : '$host:$port';
    s.write('CONNECT $target HTTP/1.1\r\nHost: $target\r\n\r\n');
    final status = (await reply.future.timeout(const Duration(seconds: 8)))
        .split('\r\n')
        .first;
    if (!status.contains(' 200')) {
      s.destroy();
      throw status.isEmpty ? t('rc.noAnswer') : status;
    }
    return (s, done.future);
  }

  Future<Map<String, dynamic>?> _findConnection(String host) async {
    final r = await http
        .get(Uri.parse('$apiBase/connections'))
        .timeout(const Duration(seconds: 4));
    if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
    final list = (jsonDecode(r.body)['connections'] as List?) ?? const [];
    for (final c in list) {
      if (c is! Map) continue;
      final m = (c['metadata'] as Map?) ?? const {};
      if (m['host'] == host || m['destinationIP'] == host) {
        return c.cast<String, dynamic>();
      }
    }
    return null;
  }
}

class RouteCheckScreen extends StatefulWidget {
  final RouteProber prober;
  final bool coreRunning;
  const RouteCheckScreen({super.key, required this.prober, required this.coreRunning});

  @override
  State<RouteCheckScreen> createState() => _RouteCheckScreenState();
}

class _RouteCheckScreenState extends State<RouteCheckScreen> {
  final _input = TextEditingController();
  bool _busy = false;
  String? _error;
  RouteCheckResult? _result;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final target = parseRouteTarget(_input.text);
    if (target == null) {
      setState(() => _error = t('rc.badInput'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    final result = await widget.prober.check(target.$1, target.$2);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canCheck = !_busy && widget.coreRunning;
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: Text(t('rc.title'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Text(t('rc.intro'), style: const TextStyle(fontSize: 12, height: 1.35)),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (canCheck) _check();
            },
            decoration: InputDecoration(
              labelText: t('rc.input'),
              hintText: t('rc.hint'),
              errorText: _error,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          if (!widget.coreRunning) ...[
            Text(t('rc.needCore'), style: TextStyle(fontSize: 12, color: scheme.error)),
            const SizedBox(height: 8),
          ],
          FilledButton.icon(
            onPressed: canCheck ? _check : null,
            icon: _busy
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.alt_route),
            label: Text(_busy ? t('rc.checking') : t('rc.check')),
          ),
          if (r != null) const SizedBox(height: 16),
          if (r != null && r.route != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('rc.route'), style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(r.route!,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    Text(t('rc.rule'), style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(r.rule ?? '?', style: const TextStyle(fontSize: 14)),
                    if (r.rawRule != null && r.rawRule!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SelectableText(r.rawRule!,
                          style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: scheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
            ),
          if (r != null && r.note != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(r.note!, style: const TextStyle(fontSize: 13, height: 1.35)),
              ),
            ),
        ],
      ),
    );
  }
}
