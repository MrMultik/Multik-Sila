# One command to cut a release: build, package, publish.
#
# Exists so that shipping a fix does not turn into a manual sequence of build,
# clean, compile installer, zip, upload - which is where mistakes creep in.
# The first published installer carried the build machine's own config.json
# with live subscription credentials precisely because the packaging step was
# done by hand.
#
# Produces two assets:
#   MultikSila-<ver>-setup.exe   - for people, a normal installer
#   MultikSila-<ver>-windows-x64.zip - for the app's own auto-update
#
# Why both: the updater unpacks a folder next to the app and swaps it with a
# batch file after the app exits (see _stageAppUpdate in main.dart). Running an
# installer from inside the running app is not possible - the installer's first
# act is to ask that app to close.
#
# The zip deliberately excludes sing-box.exe and xray.exe. The app updates the
# cores on its own schedule and may already hold a newer build than the one
# bundled here; overwriting them on every app update would roll them back.
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and chokes on Cyrillic.
param(
  [switch]$Publish,          # without it: build and package only, no upload
  [string]$Root = "C:\dev\proxy_app_test"
)

$ErrorActionPreference = "Stop"
Set-Location $Root

# Version comes from the .iss, which is the single place a human edits for a
# release. If it ever disagrees with pubspec.yaml or kAppVersion, self-update
# breaks silently, so we check instead of trusting.
$iss = Get-Content "installer\multik_sila.iss" -Raw -Encoding UTF8
$ver = [regex]::Match($iss, '#define\s+AppVersion\s+"([^"]+)"').Groups[1].Value
$pub = [regex]::Match((Get-Content "pubspec.yaml" -Raw), '(?m)^version:\s*([\d.]+)').Groups[1].Value
$dart = [regex]::Match((Get-Content "lib\main.dart" -Raw -Encoding UTF8), "kAppVersion\s*=\s*'([^']+)'").Groups[1].Value
Write-Host "version: iss=$ver pubspec=$pub kAppVersion=$dart"
if ($ver -ne $pub -or $ver -ne $dart) { throw "versions disagree - fix before releasing" }

$rel = "build\windows\x64\runner\Release"

# The Release folder doubles as the app's working directory when it is run from
# the build, so it accumulates configs with real server addresses, logs and
# rule-set caches. None of that may end up in a published artefact.
Write-Host "cleaning working files out of the build folder"
foreach ($f in @("config.json", "xray_config.json", "app_log.txt", "app_log.txt.prev.txt",
                 "capture.txt", "tundiag.txt", "tundebug.txt")) {
  Remove-Item (Join-Path $rel $f) -Force -ErrorAction SilentlyContinue
}
Get-ChildItem $rel -Filter "xray_bridge_*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $rel -Filter "*_probe.json" -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $rel -Filter "rulesets" -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

Write-Host "building"
& flutter build windows --release | Select-Object -Last 1

Write-Host "compiling installer"
Get-ChildItem "installer\output" -Filter *.exe -ErrorAction SilentlyContinue | Remove-Item -Force
$log = Join-Path $env:TEMP "iscc_release.txt"
& "tools\innosetup\ISCC.exe" "installer\multik_sila.iss" | Out-File $log -Encoding utf8
if (-not (Select-String -Path $log -Pattern "Successful compile" -Quiet)) { throw "installer failed, see $log" }

# Audit what actually went into the package rather than trusting the Excludes.
$packed = Select-String -Path $log -Pattern "Compressing: (.+)$" | ForEach-Object { $_.Matches.Groups[1].Value }
$leak = $packed | Where-Object {
  $_ -like "*config.json" -or $_ -like "*_probe.json" -or $_ -like "*xray_bridge*" -or
  $_ -like "*app_log*" -or $_ -like "*capture.txt" -or $_ -like "*tundiag*" -or $_ -like "*tundebug*"
}
if ($leak) { throw "installer contains working files: $($leak -join ', ')" }
$srs = ($packed | Where-Object { $_ -like "*.srs" }).Count
if ($srs -lt 3) { throw "rule sets missing from the installer ($srs of 3)" }
Write-Host "installer: $($packed.Count) files, $srs rule sets, no working files"

Write-Host "packing the update zip"
$zip = "installer\output\MultikSila-$ver-windows-x64.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
$staging = Join-Path $env:TEMP "multik_zip"
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item $rel $staging -Recurse
foreach ($f in @("sing-box.exe", "xray.exe")) {
  Remove-Item (Join-Path $staging $f) -Force -ErrorAction SilentlyContinue
}
Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("zip: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))

if (-not $Publish) { Write-Host "built only; pass -Publish to upload"; exit }

$gh = "C:\Program Files\GitHub CLI\gh.exe"
$tag = "v$ver"
Write-Host "publishing $tag"
& git tag -f $tag | Out-Null
& git push origin $tag --force | Out-Null
$exists = & $gh release view $tag --json tagName 2>$null
if ($LASTEXITCODE -eq 0) {
  & $gh release upload $tag "installer\output\MultikSila-$ver-setup.exe" $zip --clobber
} else {
  & $gh release create $tag "installer\output\MultikSila-$ver-setup.exe" $zip --title "Multik Sila $ver" --generate-notes
}
Write-Host "done: https://github.com/MrMultik/Multik-Sila/releases/tag/$tag"
