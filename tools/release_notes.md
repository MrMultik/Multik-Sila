<!--
  Release notes template. Copy it next to the build, fill in every TODO and pass it to
  tools\release.ps1 -Publish -Notes <file>. {{VERSION}} is filled in by the script, and it
  refuses to publish while a TODO is left. HTML comments like this one are not shown on GitHub.

  People read the top half, so it is written for them: what they will notice, in plain
  words. How it was found and fixed goes into "Technical details" at the bottom.
  Drop the Android button and rows if the release has no APKs.
-->
<p align="center">
  <a href="https://github.com/MrMultik/Multik-Sila/releases/download/v{{VERSION}}/MultikSila-{{VERSION}}-setup.exe"><img src="https://img.shields.io/badge/Download-Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download for Windows"></a>
  <a href="https://github.com/MrMultik/Multik-Sila/releases/download/v{{VERSION}}/MultikSila-{{VERSION}}-android-arm64-v8a.apk"><img src="https://img.shields.io/badge/Download-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Download for Android"></a>
</p>

## What's new

- **TODO: headline in plain words.** TODO: one or two sentences on what people will notice.

## Which file do I need?

| Device | File |
|---|---|
| Windows 10 / 11 | `MultikSila-{{VERSION}}-setup.exe` |
| Android — almost any phone | `MultikSila-{{VERSION}}-android-arm64-v8a.apk` |
| Android — old 32-bit phones | `MultikSila-{{VERSION}}-android-armeabi-v7a.apk` |
| Android emulator | `MultikSila-{{VERSION}}-android-x86_64.apk` |

Already using Multik Sila on Windows? It offers this update on its own.
`MultikSila-{{VERSION}}-windows-x64.zip` is what it downloads for that — you don't need it.

<details>
<summary><b>Technical details</b></summary>

TODO: what was broken, why, how it was fixed, and how it was verified.

</details>

<p align="center">
  <a href="https://t.me/Sila_Multik_bot"><img src="https://img.shields.io/badge/Questions%3F-Ask%20in%20Telegram-26A5E4?style=for-the-badge&logo=telegram&logoColor=white" alt="Ask in Telegram"></a>
</p>
