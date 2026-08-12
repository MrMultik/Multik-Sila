import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
// Обе библиотеки объявляют `BarcodeFormat`, и без префикса импорт неоднозначен.
// Префикс у сканера, а не у zxing2: zxing2 здесь используется россыпью имён
// (RGBLuminanceSource, BinaryBitmap, QRCodeReader), а от сканера нужно
// несколько штук в одном месте.
import 'package:mobile_scanner/mobile_scanner.dart' as scanner;
import 'package:zxing2/qrcode.dart';

import 'l10n.dart';

/// Чтение QR-кода из картинки.
///
/// Вынесено из главного экрана, потому что тем же кодом пользуется мастер
/// первого запуска. Дублировать разбор картинки в двух местах нельзя: он
/// неочевиден (zxing2 ждёт линейный массив пикселей, а не объект картинки),
/// и разойтись две копии успеют раньше, чем кто-нибудь это заметит.
///
/// Способов два, и один не заменяет другой.
///
/// Камера ([scanWithCamera]) — то, ради чего QR вообще существует: код
/// показывают на чужом экране или на бумаге. Есть только на телефоне.
///
/// Картинка ([pickAndDecode]) — скриншот, фотография, сохранённое из переписки
/// изображение. Такой код камерой не отсканируешь, поэтому путь остаётся на
/// обеих платформах, а на Windows он единственный: камеры у приложения там нет.
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

  /// Живое сканирование камерой. `null` — экран закрыли, ничего не нашли.
  ///
  /// В отличие от [pickAndDecode] исключений не бросает: отказ в доступе к
  /// камере и «человек передумал» — это одно и то же с точки зрения
  /// вызывающего, экран просто закрывается. О причине говорит сам экран, там
  /// же, где человек её и увидит.
  static Future<String?> scanWithCamera(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen(), fullscreenDialog: true),
    );
  }
}

/// Экран сканирования: видоискатель во весь экран и рамка по центру.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final scanner.MobileScannerController _controller =
      scanner.MobileScannerController(
    // Только QR. Штрихкоды с товаров распознавать не нужно, а каждый лишний
    // формат — работа на каждом кадре.
    formats: const [scanner.BarcodeFormat.qrCode],
    detectionSpeed: scanner.DetectionSpeed.noDuplicates,
  );

  /// Уже отдали результат.
  ///
  /// Камера присылает кадры пачкой, и распознанный код прилетает несколько раз
  /// подряд. Без флага `Navigator.pop` звался бы на уже закрытом экране —
  /// закрыло бы и то, что под ним.
  bool _done = false;
  bool _torch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(scanner.BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      _done = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('qr.scanTitle')),
        actions: [
          IconButton(
            icon: Icon(_torch ? Icons.flashlight_on : Icons.flashlight_off),
            tooltip: t('qr.torch'),
            onPressed: () async {
              await _controller.toggleTorch();
              if (mounted) setState(() => _torch = !_torch);
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          scanner.MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // Отказ в доступе к камере, отсутствие камеры, занятость её другим
            // приложением — всё это приезжает сюда. Пустой экран без
            // объяснения выглядел бы как поломка приложения.
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '${t('qr.cameraFailed')}\n\n${error.errorCode.name}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            ),
          ),
          // Рамка: показывает, куда наводить. Без неё человек держит код
          // краем кадра и не понимает, почему не срабатывает.
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Text(
              t('qr.scanHint'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
