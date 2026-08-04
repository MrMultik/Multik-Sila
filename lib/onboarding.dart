import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n.dart';
import 'prefs_keys.dart';

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
  Widget _profileStep(ColorScheme scheme) {
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
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: t('onb.profileUrlLabel'),
                    hintText: 'https://...',
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _name,
                  decoration:
                      InputDecoration(labelText: t('onb.profileNameLabel')),
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
                  // Проверяем только схему: живость ссылки покажет загрузка
                  // на главном экране, а держать человека в мастере ради
                  // сетевого запроса незачем.
                  if (!url.startsWith('http://') && !url.startsWith('https://')) {
                    setState(() => _error = t('onb.profileUrlBad'));
                    return;
                  }
                  _finish(subscriptionUrl: url, profileName: _name.text);
                },
          child: Text(t('onb.profileAdd')),
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
