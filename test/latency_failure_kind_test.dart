// Сводка сбоев замера на длинном списке: к какому виду относится ошибка.
// Тексты ошибок взяты из настоящих журналов (Dart и ядро sing-box).

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_app_test/main.dart';

void main() {
  test('timeouts from Dart and from the core are one kind', () {
    expect(latencyFailureKind('TimeoutException after 0:00:06.000000: Future not completed'), 'timeout');
    expect(latencyFailureKind('HTTP 504 {"message":"Timeout"}'), 'timeout');
    expect(
        latencyFailureKind('SocketException: Connection timed out (OS Error: Connection timed out, errno = 110)'),
        'timeout');
  });

  test('a refused connection is told apart on both systems', () {
    expect(
        latencyFailureKind('SocketException: Connection refused (OS Error: Connection refused, errno = 111), '
            'address = a.example.com, port = 34500'),
        'refused');
    expect(latencyFailureKind('SocketException: OS Error: errno = 10061, address = 203.0.113.5'), 'refused');
  });

  test('a name that does not resolve is its own kind', () {
    expect(
        latencyFailureKind("SocketException: Failed host lookup: 'gone.example.com' "
            '(OS Error: No address associated with hostname, errno = 7)'),
        'dns');
  });

  test('everything else falls into "other"', () {
    expect(latencyFailureKind('HTTP 503 {"message":"An error occurred in the delay test"}'), 'other');
    expect(latencyFailureKind('HandshakeException: Connection terminated during handshake'), 'other');
  });
}
