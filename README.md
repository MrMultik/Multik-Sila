# Multik Sila

A VPN client for Windows built with Flutter — a graphical front end for the
[sing-box](https://github.com/SagerNet/sing-box) and [Xray-core](https://github.com/XTLS/Xray-core)
engines. Supports VLESS, VMess, Trojan and Hysteria2, system-wide VPN through a
TUN adapter, and split tunnelling.

## Features

- **Subscriptions**: by link, from a file, by pasting text, or from a QR code.
  Auto-refresh on the interval reported by the panel itself.
- **TUN mode** — system-wide VPN: all traffic from the machine goes through the
  tunnel, no need to configure a proxy in each program. Requires administrator rights.
- **Regular mode** — a local proxy plus automatic Windows system-proxy setup
  (the previous value is saved and restored when you disconnect).
- **Split tunnelling**: local sites go direct, everything else through the VPN.
  Driven by GeoSite/GeoIP rule sets that ship inside the app — no internet
  connection is needed for the first run.
- **Custom routing rules**: by domain, by address, for popular services, and for
  individual programs (the rule is bound to the `.exe` path, not the process name).
- **Ad and tracker blocking** through a separate rule set.
- **Latency test** and automatic selection of the fastest server on connect.
- **Statistics**: live speed, a one-minute chart, active connections, top hosts.
- **Diagnostics**: step-by-step checks from the local port to the external IP,
  a table of network interfaces and routes, and a viewer for the generated core configs.
- **Automatic core updates** with verification: a downloaded core must start,
  report a version newer than the installed one, and accept the current config —
  otherwise the update is cancelled.
- Fine-grained settings: DNS (including FakeIP, hosts, ECS), MUX, TLS fragmentation,
  NTP, IPv6 mode, TUN adapter parameters, start with Windows.
- Russian and English interface, light and dark themes.

## Why two engines

sing-box provides native TUN support and serves as the main engine. It does not
support the `xhttp` transport at all, so servers using it are handled by Xray:
in regular mode Xray hosts the local proxy itself, and in TUN mode each such
server gets its own SOCKS5 bridge while sing-box still does all the routing.

## Building from source

You need the Flutter SDK (stable channel) and Visual Studio with the
"Desktop development with C++" workload.

```
flutter pub get
flutter build windows --release
```

### Engines

Engine executables are **not stored in this repository** — they are third-party
builds and together weigh about 90 MB. Place them next to the application `.exe`:

- `sing-box.exe` — [SagerNet/sing-box releases](https://github.com/SagerNet/sing-box/releases),
  the `windows-amd64` build;
- `xray.exe` — [XTLS/Xray-core releases](https://github.com/XTLS/Xray-core/releases),
  the `Xray-windows-64.zip` archive.

After that the app keeps them up to date on its own (the "Update cores
automatically" setting).

### Building the installer

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

**[Download the installer for Windows →](https://github.com/MrMultik/Multik-Sila/releases/latest)**

A regular installer: it puts the app into Program Files, creates shortcuts and
registers an uninstaller. Both engines are already inside — nothing else to
download. Windows 10 or newer, 64-bit.
