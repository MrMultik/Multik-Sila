// The sing-box config the app writes, built for different platforms and
// settings: the rules whose order or presence once broke connections, and
// — when a sing-box binary is at hand — `sing-box check` on every result.
//
// The binary: SINGBOX_BIN, or sing-box.exe in the project root (that is
// where the GitHub Actions build puts it). Without it the check is skipped
// and only the structure is tested.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

final _root = Directory.current.path;
String _ruleSet(String file) => '$_root${Platform.pathSeparator}assets'
    '${Platform.pathSeparator}rulesets${Platform.pathSeparator}$file';

final _allRuleSets = {
  'geosite-ru': _ruleSet('geosite-category-ru.srs'),
  'geoip-ru': _ruleSet('geoip-ru.srs'),
  'geosite-ads': _ruleSet('geosite-category-ads-all.srs'),
};

// Servers as they reach the builder: addresses already baked in.
final _outbounds = <Map<String, dynamic>>[
  {
    'type': 'vless',
    'tag': 'srv_1',
    'server': '203.0.113.10',
    'server_port': 25025,
    'uuid': '11111111-2222-3333-4444-555555555555',
    'tls': {'enabled': true, 'server_name': 'example.com'},
  },
  {
    'type': 'hysteria2',
    'tag': 'srv_5',
    'server': '203.0.113.10',
    'server_port': 13674,
    'password': 'secret',
    'obfs': {'type': 'salamander', 'password': 'obfs-secret'},
    'tls': {'enabled': true, 'server_name': 'example.com'},
  },
  {
    'type': 'trojan',
    'tag': 'srv_6',
    'server': '203.0.113.10',
    'server_port': 25783,
    'password': 'secret',
    'tls': {'enabled': true, 'server_name': 'example.com'},
  },
];

SingboxConfigInput _input({
  AppSettings? settings,
  bool tun = true,
  bool android = false,
  RoutingMode mode = RoutingMode.bypassRu,
  bool ads = true,
  bool gvisor = true,
  bool independentCache = false,
}) {
  final st = settings ?? AppSettings();
  return SingboxConfigInput(
    settings: st,
    tunMode: tun,
    routingMode: mode,
    blockAds: ads,
    singboxOutbounds: _outbounds,
    bridges: const [(tag: 'srv_0', port: 1338), (tag: 'srv_2', port: 1339)],
    selectedTag: 'srv_0',
    proxyHostNames: {'203.0.113.10', 'vpn.example.com'},
    proxyPorts: {443, 13674, 25025, 25783},
    readyRuleSets: {
      for (final rs in ruleSetsWanted(st, mode, blockAds: ads)) rs.tag: _allRuleSets[rs.tag]!,
    },
    bypassCidrs: tun ? const ['203.0.113.10/32'] : const [],
    needsIndependentCache: independentCache,
    gvisorSupported: gvisor,
    coreRunsAsProcess: !android,
    appRulesUsePaths: !android,
    processPathsDirect: android ? const [] : const [r'C:\app\xray.exe', r'C:\app\probe\sing-box.exe'],
    coreLogPath: android ? '/data/user/0/app/files/core_log.txt' : null,
  );
}

List<Map<String, dynamic>> _rules(Map<String, dynamic> c) =>
    (c['route']['rules'] as List).cast<Map<String, dynamic>>();
List<Map<String, dynamic>> _dnsRules(Map<String, dynamic> c) =>
    (c['dns']['rules'] as List).cast<Map<String, dynamic>>();
int _indexOf(List<Map<String, dynamic>> rules, bool Function(Map<String, dynamic>) test) =>
    rules.indexWhere(test);

String? _singBox() {
  final fromEnv = Platform.environment['SINGBOX_BIN'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  final local = '$_root${Platform.pathSeparator}sing-box.exe';
  return File(local).existsSync() ? local : null;
}

/// `sing-box check` on the config; skipped (returns null) without a binary.
Future<String?> _check(Map<String, dynamic> config, String name) async {
  final bin = _singBox();
  if (bin == null) return null;
  final dir = await Directory.systemTemp.createTemp('core_config_test');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}$name.json');
    await file.writeAsString(jsonEncode(config));
    final r = await Process.run(bin, ['check', '-c', file.path]);
    return r.exitCode == 0 ? '' : '${r.stdout}${r.stderr}';
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  // Without this a missing or broken binary would make every check below
  // pass silently. (A dangling reference such as route.final to a missing
  // outbound is NOT a broken config for `check` — sing-box only sees it at
  // start — so the control case is an unknown outbound type.)
  test('the check really runs: sing-box refuses a broken config', () async {
    final result = await _check({
      'outbounds': [
        {'type': 'no-such-type', 'tag': 'x'},
      ],
    }, 'broken');
    if (result == null) {
      markTestSkipped('no sing-box binary (set SINGBOX_BIN)');
      return;
    }
    expect(result, isNotEmpty);
  });

  group('Windows, TUN, Russian sites direct', () {
    final built = buildSingboxConfig(_input());
    final c = built.config;
    final rules = _rules(c);

    test('every server is in the selector, the chosen one by default', () {
      final selector = (c['outbounds'] as List).firstWhere((o) => o['type'] == 'selector');
      expect(selector['outbounds'], ['srv_1', 'srv_5', 'srv_6', 'srv_0', 'srv_2']);
      expect(selector['default'], 'srv_0');
      final bridges = (c['outbounds'] as List).where((o) => o['type'] == 'socks').toList();
      expect(bridges.map((b) => '${b['server']}:${b['server_port']}'), ['127.0.0.1:1338', '127.0.0.1:1339']);
    });

    test('own processes and the server ports go direct before QUIC is rejected', () {
      final sniff = _indexOf(rules, (r) => r['action'] == 'sniff');
      final process = _indexOf(rules, (r) => r.containsKey('process_path'));
      final servers = _indexOf(rules, (r) => r.containsKey('ip_cidr') && r.containsKey('port'));
      final quic = _indexOf(rules, (r) => r['protocol'] == 'quic');
      expect(sniff, 0);
      expect(process, greaterThan(sniff));
      expect(servers, greaterThan(process));
      expect(quic, greaterThan(servers));
      expect(rules[servers]['port'], [443, 13674, 25025, 25783]);
      expect(rules[process]['outbound'], 'direct');
    });

    test('ads are rejected before Russian sites go direct', () {
      final ads = _indexOf(rules, (r) => (r['rule_set'] as List?)?.contains('geosite-ads') ?? false);
      final ru = _indexOf(rules, (r) => (r['rule_set'] as List?)?.contains('geosite-ru') ?? false);
      expect(ads, isNonNegative);
      expect(ru, greaterThan(ads));
      expect(c['route']['final'], 'proxy');
      expect(c['route']['default_domain_resolver'], 'dns-direct');
    });

    test('FakeIP is the last DNS rule and lives 1 s; private names are refused before it', () {
      final dns = _dnsRules(c);
      expect(dns.last['server'], 'dns-fake');
      expect(dns.last['rewrite_ttl'], 1);
      expect(dns[dns.length - 2]['action'], 'reject');
      expect(c['dns']['final'], 'dns-remote');
      expect(c['dns'].containsKey('independent_cache'), isFalse);
    });

    // Port 53 past the tunnel gets no answer under TUN on Windows; DNS over
    // HTTPS does (see the comment at dns-ru in buildSingboxConfig).
    test('Russian domains resolve over HTTPS to a Russian resolver, directly', () {
      final ru = _dnsRules(c).firstWhere((r) => (r['rule_set'] as List?)?.contains('geosite-ru') ?? false);
      expect(ru['server'], 'dns-ru');
      final server = (c['dns']['servers'] as List).firstWhere((s) => s['tag'] == 'dns-ru') as Map;
      expect(server['type'], 'https');
      expect(server.containsKey('detour'), isFalse);
      expect((c['dns']['servers'] as List).where((s) => s['tag'] == 'dns-ru'), hasLength(1));
    });

    test('the TUN inbound has no package list on Windows', () {
      final tun = (c['inbounds'] as List).single as Map;
      expect(tun['type'], 'tun');
      expect(tun['stack'], 'mixed');
      expect(tun.containsKey('exclude_package'), isFalse);
      expect(built.warnings, isEmpty);
    });

    test('sing-box accepts it', () async {
      expect(await _check(c, 'windows_tun'), anyOf(isNull, isEmpty));
    });
  });

  test('a core without gVisor falls back to the system stack and says so', () {
    final built = buildSingboxConfig(_input(gvisor: false));
    expect(((built.config['inbounds'] as List).single as Map)['stack'], 'system');
    expect(built.warnings, ['log.tunStackFallback']);
  });

  test('older cores get independent_cache with FakeIP', () {
    final c = buildSingboxConfig(_input(independentCache: true)).config;
    expect(c['dns']['independent_cache'], isTrue);
  });

  group('Windows, regular mode', () {
    final c = buildSingboxConfig(_input(tun: false)).config;
    final rules = _rules(c);

    test('a local mixed proxy, no TUN-only rules', () {
      final inbound = (c['inbounds'] as List).single as Map;
      expect(inbound['type'], 'mixed');
      expect(inbound['listen'], '127.0.0.1');
      expect(inbound['listen_port'], 1337);
      expect(rules.any((r) => r['action'] == 'sniff' || r.containsKey('process_path')), isFalse);
      expect(rules.any((r) => r['protocol'] == 'quic'), isFalse);
    });

    test('domains are resolved before the GeoIP rule', () {
      final resolve = _indexOf(rules, (r) => r['action'] == 'resolve');
      final ru = _indexOf(rules, (r) => (r['rule_set'] as List?)?.contains('geoip-ru') ?? false);
      expect(resolve, isNonNegative);
      expect(ru, greaterThan(resolve));
    });

    test('sing-box accepts it', () async {
      expect(await _check(c, 'windows_regular'), anyOf(isNull, isEmpty));
    });
  });

  group('Android', () {
    final c = buildSingboxConfig(_input(android: true)).config;
    final tun = (c['inbounds'] as List).single as Map;

    test('Russian apps leave the VPN by themselves, the core log goes to a file', () {
      expect(tun['exclude_package'], contains('ru.ozon.app.android'));
      expect(c['log']['output'], '/data/user/0/app/files/core_log.txt');
    });

    test('no process rule (it would make the router look up every connection)', () {
      expect(_rules(c).any((r) => r.containsKey('process_path')), isFalse);
    });

    test('Russian domains resolve directly, with no DoH server added', () {
      final ru = _dnsRules(c).firstWhere((r) => (r['rule_set'] as List?)?.contains('geosite-ru') ?? false);
      expect(ru['server'], 'dns-direct');
      expect((c['dns']['servers'] as List).any((s) => s['tag'] == 'dns-ru'), isFalse);
    });

    test('sing-box accepts it', () async {
      expect(await _check(c, 'android'), anyOf(isNull, isEmpty));
    });
  });

  group('everything through the VPN, no FakeIP, no ad blocking', () {
    final st = AppSettings()..dnsProxyResolve = 'current';
    final c = buildSingboxConfig(_input(settings: st, mode: RoutingMode.global, ads: false)).config;

    test('no rule sets at all, no FakeIP server or rule', () {
      expect(c['route'].containsKey('rule_set'), isFalse);
      expect(_rules(c).any((r) => r.containsKey('rule_set')), isFalse);
      expect((c['dns']['servers'] as List).any((s) => s['type'] == 'fakeip'), isFalse);
      expect(_dnsRules(c).any((r) => r['server'] == 'dns-fake'), isFalse);
    });

    test('sing-box accepts it', () async {
      expect(await _check(c, 'global'), anyOf(isNull, isEmpty));
    });
  });
}
