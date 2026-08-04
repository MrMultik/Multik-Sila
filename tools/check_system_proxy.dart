// ignore_for_file: avoid_print
// Консольная диагностика: печать в stdout здесь и есть весь результат.
//
// Одноразовая проверка раскладки нативных структур из lib/system_proxy.dart.
// ТОЛЬКО ЧТЕНИЕ (InternetQueryOptionW): если те же формулы смещений читают
// осмысленные значения, значит и запись ляжет туда, куда надо.
import 'dart:ffi';
import 'package:ffi/ffi.dart';

const int optionPerConnection = 75;
const int perConnFlags = 1;
const int perConnProxyServer = 2;
const int perConnProxyBypass = 3;
const int perConnAutoconfigUrl = 4;

final int ptrSize = sizeOf<IntPtr>();
int get optionSize => ptrSize == 8 ? 16 : 12;
int get optionValueOffset => ptrSize == 8 ? 8 : 4;
int get listSize => ptrSize == 8 ? 32 : 20;

void main() {
  final wininet = DynamicLibrary.open('wininet.dll');
  final query = wininet.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Pointer<Uint32>),
      int Function(Pointer<Void>, int, Pointer<Void>,
          Pointer<Uint32>)>('InternetQueryOptionW');

  const wanted = [
    (perConnFlags, 'FLAGS'),
    (perConnProxyServer, 'PROXY_SERVER'),
    (perConnProxyBypass, 'PROXY_BYPASS'),
    (perConnAutoconfigUrl, 'AUTOCONFIG_URL'),
  ];

  final options = calloc<Uint8>(optionSize * wanted.length);
  final list = calloc<Uint8>(listSize);
  final size = calloc<Uint32>();
  try {
    for (var i = 0; i < wanted.length; i++) {
      (options + optionSize * i).cast<Uint32>().value = wanted[i].$1;
    }
    list.cast<Uint32>().value = listSize;
    (list + ptrSize).cast<IntPtr>().value = 0; // pszConnection = NULL (LAN)
    (list + ptrSize * 2).cast<Uint32>().value = wanted.length;
    (list + ptrSize * 2 + 4).cast<Uint32>().value = 0;
    (list + ptrSize * 3).cast<IntPtr>().value = options.address;
    size.value = listSize;

    final ok = query(nullptr, optionPerConnection, list.cast<Void>(), size);
    print('sizeOf<IntPtr>=$ptrSize optionSize=$optionSize listSize=$listSize');
    print('InternetQueryOptionW -> $ok');
    if (ok == 0) return;

    for (var i = 0; i < wanted.length; i++) {
      final base = options + optionSize * i;
      final slot = base + optionValueOffset;
      if (wanted[i].$1 == perConnFlags) {
        final f = slot.cast<Uint32>().value;
        print('${wanted[i].$2} = $f  (0x${f.toRadixString(16)})');
      } else {
        final addr = slot.cast<IntPtr>().value;
        final s = addr == 0
            ? '<null>'
            : Pointer<Utf16>.fromAddress(addr).toDartString();
        print('${wanted[i].$2} = "$s"');
      }
    }
  } finally {
    calloc.free(options);
    calloc.free(list);
    calloc.free(size);
  }
}
