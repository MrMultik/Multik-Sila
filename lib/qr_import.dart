import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import 'l10n.dart';

/// Чтение QR-кода из картинки.
///
/// Вынесено из главного экрана, потому что тем же кодом пользуется мастер
/// первого запуска. Дублировать разбор картинки в двух местах нельзя: он
/// неочевиден (zxing2 ждёт линейный массив пикселей, а не объект картинки),
/// и разойтись две копии успеют раньше, чем кто-нибудь это заметит.
///
/// Камеры здесь нет намеренно. На Windows её у приложения нет вовсе, а
/// картинка с кодом есть всегда: скриншот с телефона, фотография, сохранённое
/// изображение из переписки. На Android живое сканирование камерой полезнее,
/// но требует отдельного плагина — это следующий шаг, а не замена этому:
/// код, присланный картинкой, камерой не отсканируешь.
class QrImport {
  QrImport._();

  /// Открывает выбор картинки и возвращает содержимое кода.
  ///
  /// `null` — человек закрыл выбор файла, ничего не делаем и молчим.
  /// Бросает исключение, если картинка не читается или кода в ней нет:
  /// это разные случаи, и сообщать о них должен вызывающий, у которого есть
  /// куда писать — лог или всплывающая подсказка.
  static Future<String?> pickAndDecode() async {
    final file = await openFile(acceptedTypeGroups: [
      XTypeGroup(
        label: t('dlg.fileImages'),
        extensions: const ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
      ),
      XTypeGroup(label: t('dlg.fileAll'), extensions: const []),
    ]);
    if (file == null) return null;

    final decoded = img.decodeImage(await file.readAsBytes());
    if (decoded == null) throw const FormatException('image');

    // zxing2 принимает линейный массив ARGB-пикселей, а не объект картинки.
    final pixels = Int32List(decoded.width * decoded.height);
    var i = 0;
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        final p = decoded.getPixel(x, y);
        pixels[i++] =
            (0xFF << 24) | (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
      }
    }
    final source = RGBLuminanceSource(decoded.width, decoded.height, pixels);
    final result = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source)));
    return result.text.trim();
  }
}
