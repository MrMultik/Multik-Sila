// uTLS fingerprints written for Xray must not break sing-box (see
// singboxUtlsFingerprint in main.dart). A free list had one server with
// `fp=unsafe`, and sing-box refused to start the whole tunnel:
// `initialize outbound[74]: unknown uTLS fingerprint: unsafe` (2026-10-08).
//
// The live half runs `sing-box check` on the parsed outbound, with a control:
// the same outbound WITHOUT the fix must be refused, otherwise the check proves
// nothing. The binary: SINGBOX_BIN, or sing-box.exe in the project root.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

const _uuid = '7f17c09d-46f8-4993-9a30-cbbfd0c774f5';

ParsedServer _vlessWs(String fp) {
  final link = 'vless://$_uuid@example.com:443?type=ws&security=tls&sni=example.com'
      '&host=example.com&path=%2Fws&fp=$fp#S';
  final s = parseVless(link)!;
  s.link = link;
  return s;
}

String? _singBox() {
  final fromEnv = Platform.environment['SINGBOX_BIN'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  final local = '${Directory.current.path}${Platform.pathSeparator}sing-box.exe';
  return File(local).existsSync() ? local : null;
}

/// '' — accepted; the core's output — refused; null — no binary.
Future<String?> _check(Map<String, dynamic> outbound) async {
  final bin = _singBox();
  if (bin == null) return null;
  final dir = await Directory.systemTemp.createTemp('utls_test');
  try {
    final file = File('${dir.path}${Platform.pathSeparator}c.json');
    await file.writeAsString(jsonEncode({
      'outbounds': [outbound],
    }));
    final r = await Process.run(bin, ['check', '-c', file.path]);
    return r.exitCode == 0 ? '' : '${r.stdout}${r.stderr}';
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  test('fingerprints map to what sing-box knows', () {
    expect(singboxUtlsFingerprint(null), 'chrome');
    expect(singboxUtlsFingerprint(''), 'chrome');
    expect(singboxUtlsFingerprint('firefox'), 'firefox');
    expect(singboxUtlsFingerprint('Chrome'), 'chrome');
    expect(singboxUtlsFingerprint('randomized'), 'randomized');
    expect(singboxUtlsFingerprint('unsafe'), isNull, reason: 'Xray: plain Go TLS');
    expect(singboxUtlsFingerprint('hellogolang'), isNull);
    expect(singboxUtlsFingerprint('randomizednoalpn'), 'randomized');
    expect(singboxUtlsFingerprint('hellorandomizedalpn'), 'randomized');
    expect(singboxUtlsFingerprint('hellochrome_131'), 'chrome');
    expect(singboxUtlsFingerprint('hellofirefox_148'), 'firefox');
    expect(singboxUtlsFingerprint('helloios_14'), 'ios');
    expect(singboxUtlsFingerprint('hello360_11_0'), '360');
    expect(singboxUtlsFingerprint('something-new'), 'chrome');
  });

  test('fp=unsafe: uTLS is dropped, fp=hellochrome_131: becomes chrome', () {
    final unsafe = _vlessWs('unsafe');
    fixForSingbox(unsafe);
    expect((unsafe.outbound['tls'] as Map).containsKey('utls'), isFalse);
    expect((unsafe.outbound['tls'] as Map)['enabled'], isTrue, reason: 'TLS itself stays');

    final hello = _vlessWs('hellochrome_131');
    fixForSingbox(hello);
    expect(((hello.outbound['tls'] as Map)['utls'] as Map)['fingerprint'], 'chrome');
  });

  test('sing-box refuses fp=unsafe as is and accepts it after the fix', () async {
    final control = await _check(_vlessWs('unsafe').outbound);
    if (control == null) {
      markTestSkipped('no sing-box binary (set SINGBOX_BIN)');
      return;
    }
    expect(control, contains('unknown uTLS fingerprint: unsafe'));
    final rejection = singboxOutboundRejection(control);
    expect(rejection?.index, 0);
    expect(rejection?.reason, contains('unknown uTLS fingerprint'));

    for (final fp in ['unsafe', 'hellochrome_131', 'randomizednoalpn', 'something-new']) {
      final s = _vlessWs(fp);
      fixForSingbox(s);
      expect(await _check(s.outbound), '', reason: 'fp=$fp');
    }
  });

  test('flow=xtls-rprx-vision-udp443 becomes xtls-rprx-vision for sing-box', () async {
    ParsedServer vision() {
      const link = 'vless://$_uuid@example.com:443?type=tcp&security=tls&sni=example.com'
          '&fp=chrome&flow=xtls-rprx-vision-udp443#V';
      return parseVless(link)!..link = link;
    }

    final fixed = vision();
    fixForSingbox(fixed);
    expect(fixed.outbound['flow'], 'xtls-rprx-vision');

    final control = await _check(vision().outbound);
    if (control == null) {
      markTestSkipped('no sing-box binary (set SINGBOX_BIN)');
      return;
    }
    expect(control, contains('unsupported flow'));
    expect(await _check(fixed.outbound), '');
  });

  test('REALITY with fp=unsafe goes to Xray with a real fingerprint', () {
    final link = 'vless://$_uuid@example.com:443?type=tcp&security=reality&sni=www.microsoft.com'
        '&fp=unsafe&pbk=8XOG1coVzNW9J_PWR9AKRzhQu2BYyRAtABP2GjwNHgw&sid=1965b8e0bd#R';
    final parsed = parseVless(link)!..link = link;
    final s = realityViaXray(parsed);
    fixForSingbox(s);
    expect(s.engine, 'xray');
    final reality = (s.outbound['streamSettings'] as Map)['realitySettings'] as Map;
    expect(reality['fingerprint'], 'chrome');
  });

  test('the core error is parsed on both platforms', () {
    final android = singboxOutboundRejection(
        'start or reload service: initialize outbound[74]: unknown uTLS fingerprint: unsafe');
    expect(android?.index, 74);
    expect(android?.reason, 'unknown uTLS fingerprint: unsafe');

    final windows = singboxOutboundRejection(
        'FATAL[0000] start service: initialize outbound[3]: unknown uTLS fingerprint: x\r\n');
    expect(windows?.index, 3);
    expect(windows?.reason, 'unknown uTLS fingerprint: x');

    expect(singboxOutboundRejection('start service: initialize inbound[0]: bind failed'), isNull);
  });
}
