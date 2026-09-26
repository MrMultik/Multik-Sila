# Security policy

## Supported versions

Only the latest release gets fixes. On Windows the app offers updates on its own;
on Android, install the newest APK from [Releases](https://github.com/MrMultik/Multik-Sila/releases/latest).

## Reporting a vulnerability

**Please don't open a public issue for a security problem** — it would tell everyone
how to exploit it before a fix is out.

Report it privately instead:

- **On GitHub:** [Report a vulnerability](https://github.com/MrMultik/Multik-Sila/security/advisories/new)
  (Security tab → *Report a vulnerability*). Only the maintainer can see it.
- **Without a GitHub account:** write to [@Sila_Multik_bot](https://t.me/Sila_Multik_bot)
  and ask for the report to be passed to the developer. Keep the details out of public chats.

English or Russian are both fine. Useful to include: app version and platform,
connection mode (regular or TUN), steps to reproduce, and what an attacker could do with it.

## What we're most interested in

A VPN client is only worth using if it keeps its promises, so these matter most:

- traffic or DNS requests leaving outside the tunnel while the app shows you as protected;
- system settings the app changes — proxy, routes, autostart — left altered or not restored;
- subscription links, server credentials or logs exposed to other programs or sent anywhere;
- the update mechanism accepting a tampered or substituted download.

Problems in the engines themselves belong upstream:
[sing-box](https://github.com/SagerNet/sing-box/security) and
[Xray-core](https://github.com/XTLS/Xray-core/security).

## What happens next

You'll get a reply as soon as possible. Once confirmed, the fix ships in a new release,
and you'll be credited in its notes unless you'd rather stay anonymous.
