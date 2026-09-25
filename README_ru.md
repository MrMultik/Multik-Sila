<p align="center">
  <img src="docs/assets/banner.svg" alt="Multik Sila" width="360">
</p>

<h1 align="center">Multik Sila</h1>

<p align="center">
  <b>Простой и мощный VPN-клиент для Windows и Android</b><br>
  Графическая оболочка для <a href="https://github.com/SagerNet/sing-box">sing-box</a> и
  <a href="https://github.com/XTLS/Xray-core">Xray</a> на
  <a href="https://flutter.dev">Flutter</a>.
</p>

<p align="center">
  <a href="README.md">English</a> | <b>Русский</b>
</p>

<p align="center">
  <a href="https://github.com/MrMultik/Multik-Sila/releases/latest"><img src="https://img.shields.io/github/v/release/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF&label=%D0%B2%D0%B5%D1%80%D1%81%D0%B8%D1%8F" alt="Последняя версия"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/releases"><img src="https://img.shields.io/github/downloads/MrMultik/Multik-Sila/total?style=flat-square&color=7C4DFF&label=%D1%81%D0%BA%D0%B0%D1%87%D0%B8%D0%B2%D0%B0%D0%BD%D0%B8%D0%B9" alt="Скачиваний"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/stargazers"><img src="https://img.shields.io/github/stars/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF&label=%D0%B7%D0%B2%D1%91%D0%B7%D0%B4" alt="Звёзды"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/issues"><img src="https://img.shields.io/github/issues/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF&label=%D0%B2%D0%BE%D0%BF%D1%80%D0%BE%D1%81%D0%BE%D0%B2" alt="Вопросы"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/commits/main"><img src="https://img.shields.io/github/last-commit/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF&label=%D0%BE%D0%B1%D0%BD%D0%BE%D0%B2%D0%BB%D0%B5%D0%BD%D0%BE" alt="Последнее обновление"></a>
  <img src="https://img.shields.io/badge/%D0%BF%D0%BB%D0%B0%D1%82%D1%84%D0%BE%D1%80%D0%BC%D1%8B-Windows%20%7C%20Android-7C4DFF?style=flat-square" alt="Платформы">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF&label=%D0%BB%D0%B8%D1%86%D0%B5%D0%BD%D0%B7%D0%B8%D1%8F" alt="Лицензия"></a>
</p>

<p align="center">
  <a href="https://github.com/MrMultik/Multik-Sila/releases/latest"><img src="https://img.shields.io/badge/%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C-Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Скачать для Windows"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/releases/latest"><img src="https://img.shields.io/badge/%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Скачать для Android"></a>
  <a href="https://t.me/Sila_Multik_bot"><img src="https://img.shields.io/badge/Telegram-@Sila__Multik__bot-26A5E4?style=for-the-badge&logo=telegram&logoColor=white" alt="Бот в Telegram"></a>
</p>

<p align="center">
  <img src="docs/screenshots/windows-connection.png" width="200" alt="Главный экран">
  <img src="docs/screenshots/windows-servers.png" width="200" alt="Список серверов">
  <img src="docs/screenshots/windows-routing.png" width="200" alt="Маршрутизация">
  <img src="docs/screenshots/windows-settings.png" width="200" alt="Настройки">
</p>

---

## Скачать

Файлы — в **[последнем релизе](https://github.com/MrMultik/Multik-Sila/releases/latest)**.
Оба движка уже внутри, больше ничего качать не нужно.

| Платформа | Файл | Примечание |
|---|---|---|
| **Windows** 10 / 11, 64 бит | `MultikSila-<версия>-setup.exe` | Ставится в профиль пользователя. Права администратора для установки не нужны. |
| **Android** 7+ | `MultikSila-<версия>-android-arm64-v8a.apk` | Для любого современного телефона. Не знаете, какой брать, — берите этот. |
| Android, старые 32-битные | `MultikSila-<версия>-android-armeabi-v7a.apk` | Только если arm64 не устанавливается. |

`-windows-x64.zip` в релизе — **не** портативная версия, а то, что приложение
качает для самообновления. Устанавливайте из `.exe`.

## Быстрый старт

1. **Установите** приложение для своей платформы (см. [Скачать](#скачать)).
2. **Возьмите подписку.** Подписки, продление и поддержка — в нашем
   Telegram-боте **[@Sila_Multik_bot](https://t.me/Sila_Multik_bot)**. Подойдёт и
   любая другая подписка VLESS / VMess / Trojan / Hysteria2.
3. **Добавьте её.** При первом запуске мастер сам попросит ссылку. Потом новые
   можно добавить на вкладке **Серверы** → **+**: вставить ссылку, выбрать файл,
   вставить текст подписки или считать QR-код.
4. **Подключитесь.** Нажмите на щит на главном экране. По умолчанию приложение
   само выбирает самый быстрый сервер; нажмите на сервер в списке, чтобы выбрать
   его вручную, или на **Авто** вверху, чтобы вернуть выбор приложению.

### Windows: обычный режим или TUN?

- **Обычный режим** включает системный прокси. Им пользуются браузеры и
  большинство мессенджеров; игры и часть программ его игнорируют и ходят напрямую.
- **TUN** — VPN на весь компьютер: через туннель идёт *всё*. Включайте, если
  какая-то программа не хочет ходить через прокси. Нужны права администратора —
  Windows спросит один раз, и приложение перезапустится с ними само.

На Android туннель всегда общесистемный, выбирать нечего.

## Возможности

- **Подписки** по ссылке, из файла, текстом или QR-кодом, в любом ходовом формате:
  список ссылок, **Clash YAML** и **конфиг sing-box**. Обновляются сами.
- **Протоколы:** VLESS (включая REALITY и xhttp), VMess, Trojan, Hysteria2, Shadowsocks.
- **Сервер выбираете вы — или приложение.** В режиме «Авто» оно меряет все серверы и
  берёт самый быстрый; в ручном держит ровно тот, что вы выбрали.
- **Раздельное туннелирование:** российские сайты — напрямую, остальное — через VPN.
  Наборы правил вшиты в приложение и работают с первого запуска.
- **Свои правила** по домену, адресу, популярному сервису или отдельной программе.
- **Блокировка рекламы и трекеров.**
- **Соединение, которое чинится само:** проверка связи замечает сервер, переставший
  пропускать трафик, и уходит с него; после сна приложение ждёт сеть, а не винит серверы.
- **Движки обновляются сами** (Windows): новые версии sing-box и Xray скачиваются,
  проверяются на вашем конфиге и применяются при следующем запуске.
- **Статистика и диагностика:** скорость в реальном времени, активные соединения,
  сетевые интерфейсы и маршруты, конфиги, отданные движкам.
- Флаги стран, светлая и тёмная темы, русский и английский интерфейс.

## Частые вопросы

<details>
<summary><b>Windows предупреждает, что установщик от неизвестного издателя.</b></summary>

Установщик не подписан сертификатом, поэтому SmartScreen его пока не узнаёт.
Нажмите **Подробнее → Выполнить в любом случае**. Файлы собираются из этого
репозитория — можно собрать самому, см. [Сборка из исходников](#сборка-из-исходников).
</details>

<details>
<summary><b>Подключено, но какая-то программа ходит мимо VPN.</b></summary>

Эта программа не пользуется системным прокси. Включите **TUN** на главном экране —
он пропускает через туннель все программы компьютера.
</details>

<details>
<summary><b>«Соединение поднято, но наружу через него не выходит».</b></summary>

Сервер принял подключение, но трафик через него не идёт. Выберите другой сервер
или нажмите **Авто** вверху списка — приложение выберет само.
</details>

<details>
<summary><b>Android: VPN выключился сам.</b></summary>

Android держит только один VPN одновременно. Если включить другое VPN-приложение,
наше отключится; приложение это заметит и покажет. Включите снова, когда понадобится.
</details>

<details>
<summary><b>Обновление не сотрёт мои подписки?</b></summary>

Нет. Профили и настройки хранятся отдельно от программы и переживают обновление
и даже удаление.
</details>

## Зачем два движка

sing-box умеет TUN сам и делает основную работу. Транспорт `xhttp` он не
поддерживает, поэтому такие серверы обслуживает Xray: в обычном режиме Xray сам
поднимает локальный прокси, а в TUN каждому такому серверу выделяется свой мост,
а маршрутизацию по-прежнему ведёт sing-box.

## Сборка из исходников

<details>
<summary><b>Windows</b></summary>

Нужны Flutter SDK (канал stable) и Visual Studio с нагрузкой
«Разработка классических приложений на C++».

```
flutter pub get
flutter build windows --release
```

Исполняемые файлы движков **в репозитории не хранятся** — это сторонние сборки
общим весом около 90 МБ. Положите их рядом с `.exe` приложения:

- `sing-box.exe` — [релизы SagerNet/sing-box](https://github.com/SagerNet/sing-box/releases), сборка `windows-amd64`;
- `xray.exe` — [релизы XTLS/Xray-core](https://github.com/XTLS/Xray-core/releases), архив `Xray-windows-64.zip`.

Для установщика нужен [Inno Setup 6](https://jrsoftware.org/isdl.php):

```
ISCC.exe installer\multik_sila.iss
```

Результат — в `installer\output\`.
</details>

<details>
<summary><b>Android</b></summary>

Движок здесь — библиотека, её собирают первой. `mobile\build_aar.ps1` нужны Go и
Android NDK; он собирает `silacore.aar` (sing-box и обёртку Xray для `xhttp`).
`.aar` в репозитории не хранится — он весит около 55 МБ.

```
powershell -File mobile\build_aar.ps1
flutter build apk --release --split-per-abi
```
</details>

## Благодарности

Multik Sila работает на [sing-box](https://github.com/SagerNet/sing-box) и
[Xray-core](https://github.com/XTLS/Xray-core) — самостоятельных проектах со
своими лицензиями.

## Лицензия

Multik Sila — свободная программа, распространяется по лицензии
[GNU General Public License v3.0](LICENSE).

Рисунок в `docs/assets` — © MrMultik, под эту лицензию не подпадает:
использовать его без разрешения нельзя.

<p align="center">
  <a href="https://t.me/Sila_Multik_bot"><img src="https://img.shields.io/badge/%D0%95%D1%81%D1%82%D1%8C%20%D0%B2%D0%BE%D0%BF%D1%80%D0%BE%D1%81%D1%8B%3F-%D0%9F%D0%B8%D1%88%D0%B8%D1%82%D0%B5%20%D0%B2%20Telegram-26A5E4?style=for-the-badge&logo=telegram&logoColor=white" alt="Вопросы — в Telegram"></a>
</p>
