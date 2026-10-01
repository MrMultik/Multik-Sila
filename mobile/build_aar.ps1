# Собирает ядро мобильной версии в silacore.aar и кладёт его туда, откуда
# его берёт сборка приложения.
#
# Зачем скриптом, а не строчкой в README: команда длинная, и каждый её кусок
# добыт отдельной неудачной сборкой. Записанная руками, она обрастает
# опечатками ровно там, где ошибка не видна до самого конца компиляции.
#
# Сам .aar в репозиторий НЕ попадает (см. .gitignore): он весит 55 МБ и
# превышает мягкий лимит GitHub, ровно как sing-box.exe и xray.exe в
# настольной версии. Собирается этим скриптом за несколько минут.
#
# ASCII only: PowerShell 5.1 читает .ps1 без BOM как ANSI и спотыкается на
# кириллице в коде (в комментариях выше она безопасна только потому, что файл
# сохранён в UTF-8 с BOM - если правите, проверьте кодировку).
param(
  [string]$Ndk = "C:\dev\android-sdk\ndk\27.3.13750724",
  [string]$Sdk = "C:\dev\android-sdk",
  [string]$Jdk = "C:\Program Files\Android\openjdk\jdk-21.0.8",
  # arm64 покрывает практически все современные телефоны; полный список нужен
  # для раздачи и для эмулятора (x86_64).
  [string]$Target = "android/arm64,android/arm,android/amd64"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$env:JAVA_HOME = $Jdk
$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_NDK_HOME = $Ndk
$env:Path = "$((go env GOPATH))\bin;$Jdk\bin;$env:Path"

# gomobile и gobind - форк SagerNet: официальный golang.org/x/mobile не умеет
# части того, на чём построен libbox.
if (-not (Test-Path "$((go env GOPATH))\bin\gomobile.exe")) {
  Write-Host "installing gomobile"
  go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.13
  go install github.com/sagernet/gomobile/cmd/gobind@v0.1.13
}

# -checklinkname=0 обязателен. libbox дотягивается до внутренностей стандартной
# библиотеки через //go:linkname, а Go начиная с 1.23 такие ссылки запрещает,
# и сборка падает на самой последней стадии - линковке:
#   link: invalid reference to os.checkPidfdOnce
# Версия ядра проставляется здесь же: без неё оно отвечает "unknown", а экран
# "О программе" её показывает.
$ld = "-X github.com/sagernet/sing-box/constant.Version=1.13.16 " +
      "-X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0"

# with_gvisor - сетевой стек для TUN, with_quic - Hysteria2/TUIC и QUIC-транспорты,
# with_utls - отпечатки TLS (нужен REALITY), with_clash_api - тот самый HTTP-интерфейс
# на localhost, благодаря которому статистика и переключение серверов работают
# общим с Windows кодом.
$tags = "with_gvisor,with_quic,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0"

# Аргументы массивом, а не строкой: PowerShell разрывает "-javapkg=com.multiksila"
# на два аргумента и сборка падает с невнятным "no exported names in the package".
$gmArgs = @(
  'bind', '-o', 'silacore.aar',
  '-target', $Target,
  '-androidapi', '24',
  '-javapkg=com.multiksila',
  # Имя своё, не gojni: две gomobile-библиотеки в одном APK конфликтуют именами
  # файлов. Здесь она одна, но имя всё равно должно быть узнаваемым.
  '-libname=silacore',
  '-trimpath', '-buildvcs=false',
  '-ldflags', $ld,
  '-tags', $tags,
  # Два пакета ОДНОЙ командой: ядро sing-box и обёртка над Xray для транспорта
  # xhttp, которого sing-box не понимает вовсе.
  'github.com/sagernet/sing-box/experimental/libbox',
  './silaxray'
)

Write-Host "building silacore.aar for $Target"
& gomobile @gmArgs
if ($LASTEXITCODE -ne 0) { throw "gomobile bind failed" }

$dest = Join-Path $PSScriptRoot "..\android\app\libs"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item "silacore.aar" (Join-Path $dest "silacore.aar") -Force
Write-Host ("done: {0:N1} MB -> android/app/libs/silacore.aar" -f ((Get-Item "silacore.aar").Length / 1MB))
