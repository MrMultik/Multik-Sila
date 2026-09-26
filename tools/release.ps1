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
# The same script builds the release on GitHub Actions
# (.github/workflows/windows-build.yml), so what is published can be traced
# back to the source. CI runs it in two halves, -Stage build and then
# -Stage package, because the app's exe has to be code-signed in between:
# the installer and the update zip must carry the signed one.
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and chokes on Cyrillic.
param(
  [switch]$Publish,          # without it: build and package only, no upload
  [string]$Notes,            # release notes written from tools\release_notes.md
  [string]$Root = "C:\dev\proxy_app_test",
  [ValidateSet("all", "build", "package")]
  [string]$Stage = "all",    # build = clean + flutter build; package = installer + zip (+ publish)
  [string]$BuildStamp = (Get-Date -Format "yyyy-MM-dd HH:mm")
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

# Notes are checked before the build, not after it: finding a forgotten TODO
# only at upload time would cost a full build for nothing.
if ($Notes) {
  if (-not (Test-Path $Notes)) { throw "notes file not found: $Notes" }
  $notesText = [IO.File]::ReadAllText((Resolve-Path $Notes), [Text.Encoding]::UTF8).Replace("{{VERSION}}", $ver)
  if ($notesText -match "TODO") { throw "notes still contain TODO - fill them in first" }
}

$rel = "build\windows\x64\runner\Release"
$exeName = "proxy_app_test.exe"

# What a package may contain, as paths relative to the Release folder: the
# app's exe, the DLLs next to it, what Flutter puts into data\ and the two
# cores. installer\multik_sila.iss takes exactly this set.
#
# An allowlist on purpose. The Release folder is also where the app runs from
# when started out of the build, and where the diagnostic scripts used to
# write, so files land there that a list of things to leave out does not know
# about yet. That list was kept here and in the .iss, and it lost: the output
# of tools\tun_ab_strictroute.ps1 went out in every update zip from 1.0.2 to
# 1.0.10 and in the 1.0.10 installer, and the app's own startup_log.txt
# (Windows user name in paths), xray_probe_single.json (a server's
# credentials) and profile_<id>.txt (an imported profile, all of its servers)
# were on neither list. A file not named here stops the release instead of
# shipping.
function Get-Unshippable([string[]]$Files, [switch]$NoCores) {
  foreach ($f in $Files) {
    $p = $f.Replace("/", "\")
    $ok = $p -eq $exeName -or ($p -like "*.dll" -and $p -notlike "*\*") -or
          $p -eq "data\app.so" -or $p -eq "data\icudtl.dat" -or $p -like "data\flutter_assets\*" -or
          (-not $NoCores -and ($p -eq "sing-box.exe" -or $p -eq "xray.exe"))
    if (-not $ok) { $f }
  }
}

# Checked before the build and again before packaging: a stray file found
# only in the finished installer would cost a full build and a compile.
# Deletes nothing - what is not the app's may be someone's measurement.
function Assert-ReleaseFolder {
  if (-not (Test-Path $rel)) { return }
  $base = (Resolve-Path $rel).ProviderPath.TrimEnd("\") + "\"
  $files = Get-ChildItem $rel -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($base.Length) }
  $extra = @(Get-Unshippable -Files $files)
  if ($extra.Count) {
    throw ("$rel holds files that are not part of the app: " + ($extra -join ", ") +
           ". Nothing was deleted - move them out of the build folder and run again.")
  }
}

# The final word is what actually went into a package, not what the .iss or
# the copy meant to put there. The exe and rule-set checks make sure an audit
# of an empty or misparsed file list does not pass by saying nothing. A
# package that fails is deleted: left in installer\output under the release's
# own name, it would look like the one to upload.
function Assert-Package([string]$What, [string]$Path, [string[]]$Files, [switch]$NoCores) {
  $extra = @(Get-Unshippable -Files $Files -NoCores:$NoCores)
  $srs = @($Files | Where-Object { $_ -like "*.srs" }).Count
  $problem = $null
  if ($extra.Count) { $problem = "contains files that are not part of the app: $($extra -join ', ')" }
  elseif ($Files -notcontains $exeName) { $problem = "does not contain $exeName" }
  elseif ($srs -lt 3) { $problem = "is missing rule sets ($srs of 3)" }
  if ($problem) {
    Remove-Item $Path -Force -ErrorAction SilentlyContinue
    throw "$What $problem - $Path deleted"
  }
  Write-Host "$What`: $($Files.Count) files, $srs rule sets, nothing outside the allowlist"
}

if ($Stage -ne "package") {
  # The Release folder doubles as the app's working directory when it is run from
  # the build, so it accumulates configs with real server addresses, logs and
  # rule-set caches. These the app recreates, and capture/tundiag/tundebug are
  # where tools\*.ps1 used to write, so all of it goes without asking. This list
  # is a convenience, not the safeguard: whatever it misses stops the release
  # at Assert-ReleaseFolder below.
  Write-Host "cleaning working files out of the build folder"
  foreach ($f in @("config.json", "xray_config.json", "app_log.txt", "app_log.txt.prev.txt",
                   "startup_log.txt", "capture.txt", "tundiag.txt", "tundebug.txt")) {
    Remove-Item (Join-Path $rel $f) -Force -ErrorAction SilentlyContinue
  }
  Get-ChildItem $rel -Filter "xray_bridge_*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
  Get-ChildItem $rel -Filter "*_probe*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
  foreach ($d in @("rulesets", "probe")) {
    Remove-Item (Join-Path $rel $d) -Recurse -Force -ErrorAction SilentlyContinue
  }
  Assert-ReleaseFolder

  Write-Host "building"
  # The build stamp is what tells two builds of the same version apart on the
  # About screen. Without it a published build and a local one look identical,
  # and asking someone which of the two they are running is not diagnosis.
  & flutter build windows --release "--dart-define=BUILD_STAMP=$BuildStamp" | Select-Object -Last 1
  # Stop does not cover native commands: without this a failed build went on to
  # package whatever an earlier build had left in the Release folder.
  if ($LASTEXITCODE -ne 0) { throw "flutter build failed with exit code $LASTEXITCODE" }
  if ($Stage -eq "build") { Write-Host "built only (stage build)"; exit }
}

# Again here, not only before the build: -Stage package runs on its own, and a
# build can start putting a new kind of file next to the exe. Either way a
# person decides - ship it (extend the allowlist and the .iss) or move it out.
Assert-ReleaseFolder

Write-Host "compiling installer"
Get-ChildItem "installer\output" -Filter *.exe -ErrorAction SilentlyContinue | Remove-Item -Force
$log = Join-Path $env:TEMP "iscc_release.txt"
& "tools\innosetup\ISCC.exe" "installer\multik_sila.iss" | Out-File $log -Encoding utf8
if (-not (Select-String -Path $log -Pattern "Successful compile" -Quiet)) { throw "installer failed, see $log" }

# ISCC names every file it packs by the path it was given, which has the
# Release folder in it (installer\..\build\...\Release\data\app.so). Anything
# packed from elsewhere keeps its full path and so fails the allowlist.
$marker = "\$rel\"
$packed = Select-String -Path $log -Pattern "Compressing: (.+)$" | ForEach-Object {
  $p = $_.Matches[0].Groups[1].Value.Trim()
  $i = $p.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
  if ($i -ge 0) { $p.Substring($i + $marker.Length) } else { $p }
}
Assert-Package "installer" "installer\output\MultikSila-$ver-setup.exe" $packed

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

# The zip is checked by its own entries: it is copied straight from the
# Release folder, so nothing in the .iss protects it. Directory entries have
# no name. The cores must not be in it at all (see the top of this file).
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $zip).ProviderPath)
try { $zipped = $z.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName } } finally { $z.Dispose() }
Assert-Package "update zip" $zip $zipped -NoCores
Write-Host ("zip: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))

if (-not $Publish) { Write-Host "built only; pass -Publish to upload"; exit }

$gh = "C:\Program Files\GitHub CLI\gh.exe"
$tag = "v$ver"
Write-Host "publishing $tag"
& git tag -f $tag | Out-Null
& git push origin $tag --force | Out-Null
# Without a notes file GitHub lists the commits, which is fine for a quick fix
# but says nothing to people who just want to know what changed for them.
$notesArgs = @("--generate-notes")
if ($Notes) {
  # UTF-8 without a BOM: GitHub would show a BOM as a stray character.
  $notesFile = "installer\output\release-notes-$ver.md"
  [IO.File]::WriteAllText((Join-Path $Root $notesFile), $notesText, (New-Object Text.UTF8Encoding($false)))
  $notesArgs = @("--notes-file", $notesFile)
}
$exists = & $gh release view $tag --json tagName 2>$null
if ($LASTEXITCODE -eq 0) {
  & $gh release upload $tag "installer\output\MultikSila-$ver-setup.exe" $zip --clobber
  if ($Notes) { & $gh release edit $tag --notes-file $notesFile }
} else {
  & $gh release create $tag "installer\output\MultikSila-$ver-setup.exe" $zip --title "Multik Sila $ver" @notesArgs
}
Write-Host "done: https://github.com/MrMultik/Multik-Sila/releases/tag/$tag"
