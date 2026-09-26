<p align="center">
  <img src="docs/assets/banner.svg" alt="Multik Sila" width="360">
</p>

<h1 align="center">Multik Sila</h1>

<p align="center">
  <b>A simple, powerful VPN client for Windows and Android</b><br>
  A <a href="https://github.com/SagerNet/sing-box">sing-box</a> and
  <a href="https://github.com/XTLS/Xray-core">Xray</a> GUI built with
  <a href="https://flutter.dev">Flutter</a>.
</p>

<p align="center">
  <b>English</b> | <a href="README_ru.md">Русский</a>
</p>

<p align="center">
  <a href="https://github.com/MrMultik/Multik-Sila/releases/latest"><img src="https://img.shields.io/github/v/release/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF&label=release" alt="Latest release"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/releases"><img src="https://img.shields.io/github/downloads/MrMultik/Multik-Sila/total?style=flat-square&color=7C4DFF" alt="Downloads"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/stargazers"><img src="https://img.shields.io/github/stars/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF" alt="Stars"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/issues"><img src="https://img.shields.io/github/issues/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF" alt="Issues"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/commits/main"><img src="https://img.shields.io/github/last-commit/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF" alt="Last commit"></a>
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20Android-7C4DFF?style=flat-square" alt="Platforms">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/MrMultik/Multik-Sila?style=flat-square&color=7C4DFF" alt="License"></a>
</p>

<p align="center">
  <a href="https://github.com/MrMultik/Multik-Sila/releases/latest"><img src="https://img.shields.io/badge/Download-Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download for Windows"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/releases/latest"><img src="https://img.shields.io/badge/Download-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Download for Android"></a>
  <a href="https://t.me/Sila_Multik_bot"><img src="https://img.shields.io/badge/Telegram-@Sila__Multik__bot-26A5E4?style=for-the-badge&logo=telegram&logoColor=white" alt="Telegram bot"></a>
</p>

<p align="center">
  <sub><b>Windows</b></sub><br>
  <img src="docs/screenshots/windows-connection.png" width="200" alt="Connection screen on Windows">
  <img src="docs/screenshots/windows-servers.png" width="200" alt="Server list on Windows">
  <img src="docs/screenshots/windows-routing.png" width="200" alt="Routing on Windows">
  <img src="docs/screenshots/windows-settings.png" width="200" alt="Settings on Windows">
</p>

<p align="center">
  <sub><b>Android</b></sub><br>
  <img src="docs/screenshots/android-connection.png" width="170" alt="Connection screen on Android">
  <img src="docs/screenshots/android-servers.png" width="170" alt="Server list on Android">
  <img src="docs/screenshots/android-routing.png" width="170" alt="Routing on Android">
  <img src="docs/screenshots/android-settings.png" width="170" alt="Settings on Android">
</p>

---

## Download

Grab the files from the **[latest release](https://github.com/MrMultik/Multik-Sila/releases/latest)**.
Both engines are already inside — there is nothing else to download.

| Platform | File | Notes |
|---|---|---|
| **Windows** 10 / 11, 64-bit | `MultikSila-<version>-setup.exe` | Installs into your user profile. No administrator rights needed to install. |
| **Android** 7+ | `MultikSila-<version>-android-arm64-v8a.apk` | For any current phone. Not sure which one? Take this. |
| Android, older 32-bit phones | `MultikSila-<version>-android-armeabi-v7a.apk` | Only if the arm64 build refuses to install. |

The `-windows-x64.zip` in the release is **not** a portable build — it is what the
app downloads to update itself. Install from the `.exe`.

## Quick start

1. **Install** the app for your platform (see [Download](#download)).
2. **Get a subscription.** Our Telegram bot
   **[@Sila_Multik_bot](https://t.me/Sila_Multik_bot)** hands out subscriptions,
   renewals and support. Any other VLESS / VMess / Trojan / Hysteria2 subscription
   works too.
3. **Add it.** On first launch the setup wizard asks for it. Later you can add
   more from the **Servers** tab → **+**: paste a link, pick a file, paste the text
   itself, or scan a QR code.
4. **Connect.** Tap the shield on the main screen. By default the app picks the
   fastest server; tap any server in the list to choose it yourself, or **Auto** at
   the top to hand the choice back.

### Windows: regular mode or TUN?

- **Regular mode** sets a system proxy. Browsers and most messengers use it;
  games and some desktop programs ignore it and connect directly.
- **TUN mode** is a system-wide VPN: *everything* goes through the tunnel. Switch
  it on when a program refuses to use the proxy. It needs administrator rights —
  Windows asks once, and the app restarts itself with them.

On Android the tunnel is always system-wide, so there is nothing to choose.

## Features

- **Subscriptions** by link, file, pasted text or QR code, in any common format:
  plain link lists, **Clash YAML** and **sing-box JSON**. They refresh on their own.
- **Protocols:** VLESS (incl. REALITY and xhttp), VMess, Trojan, Hysteria2, Shadowsocks.
- **Choose the server yourself or let the app do it.** Auto mode measures every
  server and picks the fastest; manual mode keeps exactly the one you chose.
- **Split tunnelling:** Russian sites go direct, everything else through the VPN.
  Rule sets ship inside the app, so it works on the very first launch.
- **Custom rules** by domain, address, popular service or individual program.
- **Ad and tracker blocking.**
- **Self-healing connection:** a health check notices a server that stops passing
  traffic — in Auto mode the app moves to another one, in manual mode it tells you
  and leaves the choice to you; after sleep the app waits for the network instead of
  blaming the servers.
- **Ready for Xray 26.9.9+ servers:** REALITY servers go through Xray, so they keep
  working after the server moves to the post-quantum handshake that sing-box-based
  clients cannot do.
- **Engines that keep themselves up to date** (Windows): new sing-box and Xray
  releases are downloaded, verified against your configuration, and applied on
  the next start.
- **Statistics and diagnostics:** live speed, active connections, network
  interfaces and routes, and the exact configs handed to the engines.
- Country flags, light and dark themes, English and Russian interface.

## Privacy

Multik Sila has no telemetry, no analytics and no accounts. Your subscriptions and
settings stay on your device. The app itself only talks to:

- **your subscription address** — to load and refresh your servers;
- **the servers you connect to**;
- **GitHub** — to check for updates of the app and the engines, and to refresh the
  routing rule sets (update checks can be switched off in **Settings → Updates**);
- **the latency-check address**, `cp.cloudflare.com` by default — to measure servers and
  confirm that traffic gets through (changeable in **Settings → Latency test**);
- **DNS servers**, `1.1.1.1` and `8.8.8.8` by default (changeable in **Settings → DNS**);
- only when you run them from diagnostics: `api.ipify.org` to show your external IP and
  `speed.cloudflare.com` for the speed test; an NTP server only if you turn time sync on.

## FAQ

<details>
<summary><b>Windows warns that the installer is from an unknown publisher.</b></summary>

The installer is not code-signed, so Windows SmartScreen does not recognise it
yet. Click **More info → Run anyway**. The files are built from this repository;
you can build them yourself — see [Building from source](#building-from-source).
</details>

<details>
<summary><b>Connected, but some program still goes around the VPN.</b></summary>

That program ignores the system proxy. Switch on **TUN mode** on the main screen —
it tunnels every program on the machine.
</details>

<details>
<summary><b>"Connected, but nothing gets out through it".</b></summary>

The server accepted the connection but traffic does not pass. Pick another server,
or tap **Auto** at the top of the server list and let the app choose.
</details>

<details>
<summary><b>Android: the VPN turned itself off.</b></summary>

Android keeps one VPN active at a time. Switching another VPN app on revokes ours;
the app notices and shows it as disconnected. Switch it back on when you need it.
</details>

<details>
<summary><b>Will an update wipe my subscriptions?</b></summary>

No. Profiles and settings are stored separately from the program and survive
updates and even an uninstall.
</details>

## Why two engines

sing-box provides native TUN support and does most of the work. Two kinds of servers
go through Xray instead:

- **`xhttp`** — sing-box does not support this transport at all;
- **REALITY** — since Xray 26.9.9 a REALITY server rejects any handshake without the
  post-quantum X25519MLKEM768 key exchange, and sing-box 1.14 does not send one with
  any of its fingerprints. The Xray client does, and it works with older servers too.

In regular mode Xray hosts the local proxy itself; in TUN mode and on Android each such
server gets its own Xray bridge while sing-box still does all the routing.

## Building from source

<details>
<summary><b>Windows</b></summary>

You need the Flutter SDK (stable channel) and Visual Studio with the
"Desktop development with C++" workload.

```
flutter pub get
flutter build windows --release
```

Engine executables are **not stored in this repository** — they are third-party
builds and weigh about 90 MB together. Place them next to the application `.exe`:

- `sing-box.exe` — [SagerNet/sing-box releases](https://github.com/SagerNet/sing-box/releases), the `windows-amd64` build;
- `xray.exe` — [XTLS/Xray-core releases](https://github.com/XTLS/Xray-core/releases), the `Xray-windows-64.zip` archive.

The installer needs [Inno Setup 6](https://jrsoftware.org/isdl.php):

```
ISCC.exe installer\multik_sila.iss
```

The result lands in `installer\output\`.
</details>

<details>
<summary><b>Android</b></summary>

The engine is a library here, so it is built first. `mobile\build_aar.ps1` needs the
Go toolchain and the Android NDK; it produces `silacore.aar` (sing-box plus an Xray
wrapper for `xhttp`). The `.aar` is not stored in the repository — it weighs about 55 MB.

```
powershell -File mobile\build_aar.ps1
flutter build apk --release --split-per-abi
```
</details>

## Acknowledgements

Multik Sila stands on [sing-box](https://github.com/SagerNet/sing-box) and
[Xray-core](https://github.com/XTLS/Xray-core) — independent projects with their own
licences.

## License

Multik Sila is free software, released under the [GNU General Public License v3.0](LICENSE).

The artwork in `docs/assets` is © MrMultik and is not covered by that licence —
please don't reuse it without permission.

<p align="center">
  <a href="https://t.me/Sila_Multik_bot"><img src="https://img.shields.io/badge/Questions%3F-Ask%20in%20Telegram-26A5E4?style=for-the-badge&logo=telegram&logoColor=white" alt="Ask in Telegram"></a>
</p>
