# Multik Sila

A VPN client for Windows and Android built with Flutter — a graphical front end
for the [sing-box](https://github.com/SagerNet/sing-box) and [Xray-core](https://github.com/XTLS/Xray-core)
engines. Supports VLESS, VMess, Trojan and Hysteria2, system-wide VPN through a
TUN adapter, and split tunnelling.

Both platforms share one codebase: subscription parsing, config generation and
routing rules are the same code, so the two cannot drift apart. What differs is
how the engine runs — a child process on Windows, a library inside the app on
Android, where the system hands the tunnel over as a file descriptor and no
other process can be given it.

## Features

- **Subscriptions**: by link, from a file, by pasting text, or from a QR code.
  Auto-refresh on the interval reported by the panel itself.
- **TUN mode** — system-wide VPN: all traffic goes through the tunnel, no need
  to configure a proxy in each program. On Windows it needs administrator rights
  and the app restarts itself elevated when you switch it on. On Android it is
  the only mode and is always on: `VpnService` *is* the tunnel, so there is
  nothing to switch and no administrator to ask.
- **Regular mode** (Windows only) — a local proxy plus automatic system-proxy
  setup (the previous value is saved and restored when you disconnect). Note
  that a system proxy only covers programs that honour it: browsers and most
  messengers do, games and some desktop apps connect directly and ignore it.
  Use TUN mode when you need *everything* tunnelled — the app says so on the
  main screen rather than leaving you to find out the hard way.
- **First-run wizard**: language, terms of use, then your subscription — so a
  fresh install does not drop you onto an empty screen.
- **Split tunnelling**: local sites go direct, everything else through the VPN.
  Driven by GeoSite/GeoIP rule sets that ship inside the app — no internet
  connection is needed for the first run.
- **Custom routing rules**: by domain, by address, for popular services, and for
  individual programs — bound to the `.exe` path on Windows (not the process
  name: different programs can share one) and to the package name on Android.
- **Ad and tracker blocking** through a separate rule set.
- **Latency test** and automatic selection of the fastest server on connect.
- **Statistics**: live speed, a one-minute chart, active connections, top hosts.
- **Diagnostics**: step-by-step checks from the local port to the external IP,
  a table of network interfaces and routes, and a viewer for the generated core configs.
- **Automatic core updates** with verification (Windows): a downloaded core must
  start, report a version newer than the installed one, and accept the current
  config — otherwise the update is cancelled. On Android the engines are
  compiled into the app and travel with it.
- Fine-grained settings: DNS (including FakeIP, hosts, ECS), MUX, TLS fragmentation,
  NTP, IPv6 mode, TUN adapter parameters, start with the system.
- Russian and English interface, light and dark themes.

## Why two engines

sing-box provides native TUN support and serves as the main engine. It does not
support the `xhttp` transport at all, so servers using it are handled by Xray:
in regular mode Xray hosts the local proxy itself, and in TUN mode each such
server gets its own SOCKS5 bridge while sing-box still does all the routing.

## Building from source

### Windows

You need the Flutter SDK (stable channel) and Visual Studio with the
"Desktop development with C++" workload.

```
flutter pub get
flutter build windows --release
```

### Android

The engine is a library here, not an executable, so it is built first. `mobile\build_aar.ps1`
needs the Go toolchain and the Android NDK; it produces `silacore.aar` (sing-box
plus an Xray wrapper for the `xhttp` transport) and puts it where the app build
looks for it. The `.aar` is **not stored in this repository** — it weighs about
55 MB.

```
powershell -File mobile\build_aar.ps1
flutter build apk --release --split-per-abi
```

### Engines on Windows

Engine executables are **not stored in this repository** — they are third-party
builds and together weigh about 90 MB. Place them next to the application `.exe`:

- `sing-box.exe` — [SagerNet/sing-box releases](https://github.com/SagerNet/sing-box/releases),
  the `windows-amd64` build;
- `xray.exe` — [XTLS/Xray-core releases](https://github.com/XTLS/Xray-core/releases),
  the `Xray-windows-64.zip` archive.

After that the app keeps them up to date on its own (the "Update cores
automatically" setting).

### Building the Windows installer

Requires [Inno Setup 6](https://jrsoftware.org/isdl.php):

```
flutter build windows --release
ISCC.exe installer\multik_sila.iss
```

The result lands in `installer\output\`.

## Licence

The application is provided as is. The engines are independent projects with
their own licences: sing-box and Xray-core.

---

## Download

**[Latest release →](https://github.com/MrMultik/Multik-Sila/releases/latest)**

Both engines are already inside the installer and inside the APK — there is
nothing else to download.

### Windows

`MultikSila-<version>-setup.exe` — a regular installer: it installs into your
user profile (`%LOCALAPPDATA%\Programs\Multik Sila`), creates shortcuts and
registers an uninstaller. **No administrator rights are required to install** —
they are only requested when you switch TUN mode on, and the app restarts itself
elevated at that point. Windows 10 or newer, 64-bit.

The `-windows-x64.zip` next to it is **not** a portable build — it is what the
app downloads to update itself, and it deliberately ships without the engines
(those update on their own schedule). Install from the `.exe`.

Profiles and settings live in `%APPDATA%\com.example\proxy_app_test` and are
kept when you update or uninstall, so an update never costs you your
subscription.

### Android

`MultikSila-<version>-android-arm64-v8a.apk` for any current phone;
`...-armeabi-v7a.apk` only for older 32-bit ones. If you are not sure, take
arm64. Android 7 or newer.

The system asks for VPN permission on the first connection. Android keeps one
active VPN at a time, so switching another client on revokes ours — the app is
told, stops the tunnel and drops the shield rather than leaving it lit over
nothing.
