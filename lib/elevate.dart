import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Запрос прав администратора у Windows.
///
/// **Почему не через PowerShell.** Раньше здесь был
/// `Start-Process -Verb RunAs`, запущенный отдельным процессом, и он не
/// работал по причине, которую не видно из кода: **запрос прав от ФОНОВОГО
/// процесса Windows на экран не выводит**. Окно согласия показывается только
/// тому, у кого есть право на передний план, а у скрытого стороннего
/// powershell его нет. Наружу это выходило так: человек жмёт
/// «Перезапустить» — и не происходит ничего: ни окна UAC, ни ошибки, ни
/// записи в логе. Замерено: `Start-Process -Verb RunAs` простоял 40 секунд,
/// а `consent.exe` (само окно согласия) в системе так и не появился.
///
/// Запрос из САМОГО приложения — обычный для Windows путь: право на передний
/// план у него есть, потому что человек секунду назад нажал кнопку.
///
/// `ShellExecuteW`, а не `ShellExecuteExW`: второй требует структуру
/// `SHELLEXECUTEINFOW`, раскладка которой на x64 считается вручную, а ошибка
/// в ней не падает, а молча делает не то (ровно этим уже попались в
/// `system_proxy.dart`). Здесь же хватает возвращаемого числа.
class Elevate {
  static final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
  static final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');

  static final int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
          Pointer<Utf16>, int) _shellExecute =
      _shell32.lookupFunction<
          IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, Pointer<Utf16>, Int32),
          int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, int)>('ShellExecuteW');

  static final int Function(Pointer<Void>, int) _coInitializeEx =
      _ole32.lookupFunction<Int32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)>('CoInitializeEx');

  /// Пользователь нажал «Нет» в окне UAC (`SE_ERR_ACCESSDENIED`).
  static const int accessDenied = 5;

  /// Всё, что больше 32, — успех. Так задокументирован ShellExecute: он
  /// возвращает не код ошибки, а псевдо-HINSTANCE, и осмысленного значения
  /// у чисел ниже порога нет, кроме как «не получилось, вот почему».
  static const int successThreshold = 32;

  /// Просит Windows перезапустить `exePath` с повышенными правами.
  /// Возвращает результат `ShellExecuteW`: > 32 — согласие получено и копия
  /// запускается, [accessDenied] — человек отказал, остальное — ошибка.
  ///
  /// Вызов синхронный и на время окна UAC подвешивает кадры: пока висит
  /// запрос согласия, экран и так затемнён системой, а уводить вызов в
  /// отдельный изолят означало бы отдельно инициализировать в нём COM.
  static int runAs(String exePath) {
    // Апартамент COM для потока. Если он уже инициализирован (а у главного
    // потока Flutter это так), вызов вернёт S_FALSE и ничего не сделает —
    // поэтому результат не проверяем, он тут ни на что не влияет.
    _coInitializeEx(nullptr, 2 /* COINIT_APARTMENTTHREADED */);

    final verb = 'runas'.toNativeUtf16();
    final file = exePath.toNativeUtf16();
    try {
      return _shellExecute(0, verb, file, nullptr, nullptr, 1 /* SW_SHOWNORMAL */);
    } finally {
      malloc.free(verb);
      malloc.free(file);
    }
  }
}
