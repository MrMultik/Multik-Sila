import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n.dart';
import 'platform_env.dart';
import 'prefs_keys.dart';
import 'qr_import.dart';

/// Мастер первого запуска: язык -> соглашение -> профиль -> главный экран.
///
/// Зачем отдельным экраном, а не диалогами поверх главного: на свежей
/// установке главный экран показывать нечего — профиля нет, серверов нет,
/// щит нажимать бессмысленно. Человек видел пустое окно и должен был сам
/// догадаться нажать «+».
///
/// Порядок шагов НЕ такой, как просили (соглашение -> язык -> профиль), а
/// язык первым — соглашение нельзя показывать раньше, чем человек выбрал, на
/// каком языке его читать. В установщике порядок тот же: Inno сначала
/// спрашивает язык, потом показывает лицензию.
///
/// Ключи хранения берутся из `prefs_keys.dart` — общие с главным экраном.
/// Формат записи профиля обязан совпадать с тем, что читает `_loadProfiles`.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  final _url = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _nameError;

  /// Показывать ли форму ввода вместо выбора способа.
  ///
  /// Третий шаг раньше сразу открывал два пустых поля, и человек упирался в
  /// длинный адрес, который надо набрать руками на телефоне. Ссылка при этом
  /// почти всегда уже есть — скопирована или пришла картинкой с кодом.
  /// Поэтому сначала спрашиваем СПОСОБ, а поля показываем уже заполненными.
  bool _showForm = false;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  // Язык лежит внутри JSON настроек (`app_settings`), а не отдельным ключом.
  // Читаем-правим-пишем, а не пишем свежий объект: на повторном прохождении
  // мастера (сброс онбординга) иначе стёрли бы все остальные настройки.
  Future<void> _saveLanguage(String code) async {
    appLang.value = code;
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> settings = {};
    final raw = prefs.getString(kSettingsPrefsKey);
    if (raw != null) {
      try {
        settings = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        // Битые настройки не должны мешать первому запуску — начнём с чистых.
      }
    }
    settings['language'] = code;
    await prefs.setString(kSettingsPrefsKey, jsonEncode(settings));
  }

  Future<void> _finish({String? subscriptionUrl, String? profileName}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final prefs = await SharedPreferences.getInstance();

    if (subscriptionUrl != null && subscriptionUrl.isNotEmpty) {
      // Профиль кладём в том же формате, что пишет главный экран, и НЕ качаем
      // подписку здесь: загрузкой, разбором и обработкой ошибок занимается
      // `_loadProfiles`, у него для этого уже всё есть. Мастер только заводит
      // запись — иначе логика скачивания расползётся по двум местам.
      final profile = {
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'name': (profileName == null || profileName.trim().isEmpty)
            ? t('onb.profileDefaultName')
            : profileName.trim(),
        'url': subscriptionUrl,
        'upload': 0,
        'download': 0,
        'total': 0,
        'expire': 0,
        'updateIntervalHours': 0,
        'lastUpdated': 0,
      };
      await prefs.setString(kProfilesPrefsKey, jsonEncode([profile]));
      await prefs.setString(kActiveProfilePrefsKey, profile['id'] as String);
    }

    await prefs.setBool(kOnboardingPrefsKey, true);
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StepDots(current: _step, total: 3, color: scheme.primary),
              const SizedBox(height: 16),
              Expanded(child: _buildStep(scheme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(ColorScheme scheme) {
    switch (_step) {
      case 0:
        return _languageStep(scheme);
      case 1:
        return _licenseStep(scheme);
      default:
        return _profileStep(scheme);
    }
  }

  // --- Шаг 1: язык ---
  Widget _languageStep(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t('app.title'),
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        // Подпись намеренно на обоих языках: человек ещё не выбрал, на каком
        // читает, и односложная надпись на чужом языке ему не помогает.
        Text('Выберите язык · Choose language',
            style: TextStyle(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center),
        const SizedBox(height: 24),
        for (final entry in languageNames.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: OutlinedButton(
              onPressed: () async {
                await _saveLanguage(entry.key);
                if (mounted) setState(() => _step = 1);
              },
              child: Text(entry.value),
            ),
          ),
      ],
    );
  }

  // --- Шаг 2: соглашение ---
  Widget _licenseStep(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t('onb.licenseTitle'),
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(14),
            ),
            child: SingleChildScrollView(child: Text(t('onb.licenseText'))),
          ),
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: () => setState(() => _step = 2),
          child: Text(t('onb.accept')),
        ),
        const SizedBox(height: 8),
        // Отказ обязан что-то делать. Кнопка «не согласен», которая просто
        // ничего не меняет, — это не выбор, а имитация.
        TextButton(
          onPressed: () => exit(0),
          child: Text(t('onb.decline')),
        ),
      ],
    );
  }

  // --- Шаг 3: профиль ---
  Widget _profileStep(ColorScheme scheme) =>
      _showForm ? _profileForm(scheme) : _profileChooser(scheme);

  /// Выбор способа добавления.
  ///
  /// Ссылка подписки — это сотня символов, и набирать её руками, тем более на
  /// телефоне, не должен никто. Почти всегда она уже есть: скопирована из
  /// переписки или прислана картинкой с QR-кодом. Ручной ввод остаётся
  /// третьим вариантом, а не единственным.
  Widget _profileChooser(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t('onb.profileHow'),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(t('onb.profileHowHint'),
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 20),
                if (_error != null) ...[
                  Text(_error!, style: TextStyle(color: scheme.error)),
                  const SizedBox(height: 12),
                ],
                _chooserTile(
                  scheme,
                  icon: Icons.content_paste_rounded,
                  title: t('onb.fromClipboard'),
                  hint: t('onb.fromClipboardHint'),
                  onTap: _pasteFromClipboard,
                ),
                // Сканирование камерой — выше импорта картинки и только там,
                // где камера есть. На первом запуске это самый частый случай:
                // код показан на другом экране или на бумаге.
                if (Env.hasCameraScanner)
                  _chooserTile(
                    scheme,
                    icon: Icons.qr_code_scanner_rounded,
                    title: t('onb.scanQr'),
                    hint: t('onb.scanQrHint'),
                    onTap: _scanQr,
                  ),
                _chooserTile(
                  scheme,
                  icon: Icons.image_outlined,
                  title: t('onb.fromQr'),
                  hint: t('onb.fromQrHint'),
                  onTap: _pickFromQr,
                ),
                _chooserTile(
                  scheme,
                  icon: Icons.keyboard_rounded,
                  title: t('onb.manual'),
                  hint: t('onb.manualHint'),
                  onTap: () => setState(() {
                    _error = null;
                    _showForm = true;
                  }),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Пропустить обязательно: ссылки может не быть под рукой прямо сейчас,
        // а запирать человека в мастере до её появления — худшее, что можно
        // сделать на первом запуске. Добавит потом кнопкой «+».
        TextButton(
          onPressed: _busy ? null : () => _finish(),
          child: Text(t('onb.profileSkip')),
        ),
      ],
    );
  }

  Widget _chooserTile(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String hint,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text(hint,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      setState(() => _error = t('onb.clipboardEmpty'));
      return;
    }
    setState(() {
      _error = null;
      _url.text = text;
      _showForm = true;
    });
  }

  Future<void> _scanQr() async {
    final text = await QrImport.scanWithCamera(context);
    // null — экран сканера закрыли. Не ошибка, говорить нечего.
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _error = null;
      _url.text = text;
      _showForm = true;
    });
  }

  Future<void> _pickFromQr() async {
    try {
      final text = await QrImport.pickAndDecode();
      // null — человек закрыл выбор файла. Это не ошибка, и говорить нечего.
      if (text == null || !mounted) return;
      if (text.isEmpty) {
        setState(() => _error = t('onb.qrNotFound'));
        return;
      }
      setState(() {
        _error = null;
        _url.text = text;
        _showForm = true;
      });
    } catch (_) {
      // В картинке нет кода, либо она вообще не читается. Для человека это
      // один и тот же случай: выбрал не то изображение.
      if (mounted) setState(() => _error = t('onb.qrNotFound'));
    }
  }

  Widget _profileForm(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Поля в прокрутке, кнопки закреплены снизу. Голый Column со Spacer
        // разъезжается, стоит окну стать ниже: на длинной подсказке, крупном
        // системном шрифте или всплывшей ошибке под полем вылезает жёлто-чёрная
        // полоса RenderFlex overflow, и кнопки уходят за край — а это первый
        // экран, который человек вообще видит.
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t('onb.profileTitle'),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(t('onb.profileHint'),
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 18),
                TextField(
                  controller: _url,
                  // Автофокуса нет намеренно. На телефоне он поднимает
                  // клавиатуру сразу при входе на экран, и та закрывает
                  // половину его вместе с кнопками. Сюда к тому же приходят с
                  // уже вставленной ссылкой — набирать в этом поле нечего.
                  decoration: InputDecoration(
                    labelText: t('onb.profileUrlLabel'),
                    hintText: 'https://...',
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: t('onb.profileNameLabel'),
                    errorText: _nameError,
                  ),
                  onChanged: (_) {
                    if (_nameError != null) setState(() => _nameError = null);
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  final url = _url.text.trim();
                  final name = _name.text.trim();
                  // Проверяем только схему: живость ссылки покажет загрузка
                  // на главном экране, а держать человека в мастере ради
                  // сетевого запроса незачем.
                  final urlBad =
                      !url.startsWith('http://') && !url.startsWith('https://');
                  // Название теперь обязательно. Раньше пустое поле подменялось
                  // на «Профиль 1», и человек соглашался не думая — а потом,
                  // заведя второй и третий, не мог отличить их в списке.
                  // Спросить один раз при заведении дешевле, чем разбираться
                  // позже, какой из трёх «Профиль 1» рабочий.
                  if (urlBad || name.isEmpty) {
                    setState(() {
                      _error = urlBad ? t('onb.profileUrlBad') : null;
                      _nameError = name.isEmpty ? t('onb.nameRequired') : null;
                    });
                    return;
                  }
                  _finish(subscriptionUrl: url, profileName: name);
                },
          child: Text(t('onb.profileAdd')),
        ),
        const SizedBox(height: 8),
        // Назад к выбору способа: человек мог нажать «вручную», а потом
        // вспомнить, что ссылка лежит в буфере.
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _error = null;
                    _nameError = null;
                    _showForm = false;
                  }),
          child: Text(t('common.back')),
        ),
      ],
    );
  }
}

class _StepDots extends StatelessWidget {
  final int current;
  final int total;
  final Color color;
  const _StepDots(
      {required this.current, required this.total, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < total; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == current ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i <= current ? color : color.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
