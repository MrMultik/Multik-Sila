// Задержка до QUIC-сервера (Hysteria2, TUIC) за один круг — как TCP-
// рукопожатие у остальных.
//
// Порт TCP-соединений Hysteria2 не принимает, и раньше в режиме «до сервера»
// её меряли полным запросом через пробное ядро: рукопожатие QUIC, вход на
// сервер, запрос к проверочному адресу — три-четыре круга против одного у
// VLESS. На канале пользователя 01.10.2026 это давало Hysteria2 100 мс против
// 40 мс у VLESS на ТОЙ ЖЕ машине, и «Авто» её никогда не выбирал.
//
// Приём: пакет QUIC с заведомо неизвестной версией (из зарезервированного
// ряда 0x?a?a?a?a, RFC 9000 §15) размером 1200 байт. Сервер QUIC обязан
// ответить на него согласованием версии (RFC 9000 §6) — сразу, без
// криптографии и без входа. Если на сервере включена обфускация salamander,
// пакет оборачивается так же, как это делает клиент Hysteria2: 8 байт соли и
// XOR с BLAKE2b-256(пароль ‖ соль). Проверено на сервере пользователя: ответ
// за 42–70 мс, столько же, сколько TCP-рукопожатие до той же машины.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Куда и как слать пробу для outbound'а sing-box; null — этот сервер так не
/// измерить (не QUIC, Hysteria первой версии со своей обфускацией, обфускация
/// не salamander, нет адреса или порта). Тогда его меряет пробное ядро, как
/// раньше.
///
/// Hysteria2 со сменой портов (`server_ports`, «20000:30000») — в первый порт
/// первого диапазона: сервер слушает все.
({String host, int port, List<int>? salamander})? quicProbeTarget(Map<dynamic, dynamic> outbound) {
  final type = outbound['type'];
  if (type != 'hysteria2' && type != 'tuic') return null;
  final host = outbound['server'];
  if (host is! String || host.isEmpty) return null;
  var port = outbound['server_port'] is int ? outbound['server_port'] as int : null;
  final ports = outbound['server_ports'];
  if (port == null && ports is List && ports.isNotEmpty) {
    port = int.tryParse('${ports.first}'.split(RegExp(r'[:-]')).first.trim());
  }
  if (port == null || port <= 0) return null;
  List<int>? salamander;
  final obfs = outbound['obfs'];
  if (obfs is Map) {
    final password = obfs['password'];
    if (obfs['type'] != 'salamander' || password is! String || password.isEmpty) return null;
    salamander = utf8.encode(password);
  }
  return (host: host, port: port, salamander: salamander);
}

/// BLAKE2b с выходом 32 байта, без ключа (RFC 7693).
Uint8List blake2b256(List<int> input) {
  const iv = [
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1, //
    0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
  ];
  const sigma = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
  ];
  int rotr(int x, int n) => (x >>> n) | (x << (64 - n));

  final h = List<int>.of(iv);
  h[0] ^= 0x01010000 ^ 32; // fan-out 1, depth 1, без ключа, выход 32 байта
  final v = List<int>.filled(16, 0);
  final m = List<int>.filled(16, 0);

  void compress(Uint8List block, int counter, bool last) {
    final bd = ByteData.sublistView(block);
    for (var i = 0; i < 16; i++) {
      m[i] = bd.getUint64(i * 8, Endian.little);
    }
    for (var i = 0; i < 8; i++) {
      v[i] = h[i];
      v[i + 8] = iv[i];
    }
    v[12] ^= counter; // старшая половина счётчика при наших размерах — ноль
    if (last) v[14] = ~v[14];
    void g(int a, int b, int c, int d, int x, int y) {
      v[a] = v[a] + v[b] + x;
      v[d] = rotr(v[d] ^ v[a], 32);
      v[c] = v[c] + v[d];
      v[b] = rotr(v[b] ^ v[c], 24);
      v[a] = v[a] + v[b] + y;
      v[d] = rotr(v[d] ^ v[a], 16);
      v[c] = v[c] + v[d];
      v[b] = rotr(v[b] ^ v[c], 63);
    }

    for (var r = 0; r < 12; r++) {
      final s = sigma[r % 10];
      g(0, 4, 8, 12, m[s[0]], m[s[1]]);
      g(1, 5, 9, 13, m[s[2]], m[s[3]]);
      g(2, 6, 10, 14, m[s[4]], m[s[5]]);
      g(3, 7, 11, 15, m[s[6]], m[s[7]]);
      g(0, 5, 10, 15, m[s[8]], m[s[9]]);
      g(1, 6, 11, 12, m[s[10]], m[s[11]]);
      g(2, 7, 8, 13, m[s[12]], m[s[13]]);
      g(3, 4, 9, 14, m[s[14]], m[s[15]]);
    }
    for (var i = 0; i < 8; i++) {
      h[i] ^= v[i] ^ v[i + 8];
    }
  }

  final data = Uint8List.fromList(input);
  var offset = 0;
  // Последний блок (в том числе пустой ввод) сжимается с флагом «последний».
  while (data.length - offset > 128) {
    compress(Uint8List.sublistView(data, offset, offset + 128), offset + 128, false);
    offset += 128;
  }
  final tail = Uint8List(128)..setRange(0, data.length - offset, data, offset);
  compress(tail, data.length, true);

  final out = ByteData(32);
  for (var i = 0; i < 4; i++) {
    out.setUint64(i * 8, h[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Обёртка salamander (обфускация Hysteria2): соль 8 байт, затем пакет,
/// сложенный по XOR с BLAKE2b-256(пароль ‖ соль).
Uint8List salamanderWrap(List<int> password, List<int> packet, Random rnd) {
  final salt = List<int>.generate(8, (_) => rnd.nextInt(256));
  final key = blake2b256([...password, ...salt]);
  final out = Uint8List(8 + packet.length)..setRange(0, 8, salt);
  for (var i = 0; i < packet.length; i++) {
    out[8 + i] = packet[i] ^ key[i % 32];
  }
  return out;
}

/// Снимает обёртку salamander; null — слишком короткий пакет.
Uint8List? salamanderUnwrap(List<int> password, List<int> data) {
  if (data.length <= 8) return null;
  final key = blake2b256([...password, ...data.sublist(0, 8)]);
  final out = Uint8List(data.length - 8);
  for (var i = 0; i < out.length; i++) {
    out[i] = data[8 + i] ^ key[i % 32];
  }
  return out;
}

/// Пакет QUIC с длинным заголовком и зарезервированной версией 0x1a2a3a4a,
/// добитый до 1200 байт: на меньший сервер отвечать не обязан.
Uint8List quicVersionProbe(Random rnd) {
  final p = Uint8List(1200);
  for (var i = 0; i < p.length; i++) {
    p[i] = rnd.nextInt(256);
  }
  p[0] = 0xC0 | (p[0] & 0x0F); // длинный заголовок, фиксированный бит
  p.setRange(1, 5, const [0x1a, 0x2a, 0x3a, 0x4a]);
  p[5] = 8; // длина Destination Connection ID
  p[14] = 8; // длина Source Connection ID
  return p;
}

/// Согласование версии: длинный заголовок и версия 0.
bool isQuicVersionNegotiation(List<int> p) =>
    p.length >= 7 && (p[0] & 0x80) != 0 && p[1] == 0 && p[2] == 0 && p[3] == 0 && p[4] == 0;

/// Один круг до QUIC-сервера в миллисекундах; null — ответа нет за [timeout]
/// (сервер молчит, порт закрыт, не тот пароль обфускации).
///
/// [source] — адрес физического адаптера, если пакет должен выйти мимо
/// своего же туннеля (см. `_testLatenciesByConnect` в main.dart).
Future<int?> quicRoundTrip(
  InternetAddress address,
  int port, {
  List<int>? salamander,
  InternetAddress? source,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final rnd = Random.secure();
  final probe = quicVersionProbe(rnd);
  final payload = salamander == null ? probe : salamanderWrap(salamander, probe, rnd);
  final socket = await RawDatagramSocket.bind(
      source ?? (address.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4),
      0);
  final answered = Completer<int?>();
  final sw = Stopwatch();
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null || answered.isCompleted) return;
    if (dg.address != address || dg.port != port) return;
    final plain = salamander == null ? dg.data : salamanderUnwrap(salamander, dg.data);
    if (plain != null && isQuicVersionNegotiation(plain)) {
      answered.complete(sw.elapsedMilliseconds);
    }
  });
  try {
    sw.start();
    socket.send(payload, address, port);
    return await answered.future.timeout(timeout, onTimeout: () => null);
  } finally {
    await sub.cancel();
    socket.close();
  }
}
