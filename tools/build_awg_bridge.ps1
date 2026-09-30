# Builds awg-bridge.exe (the AmneziaWG bridge) from awgbridge\ into the
# repository root, next to sing-box.exe and xray.exe, where
# windows\CMakeLists.txt picks it up and installs it next to the app's exe.
#
# Unlike the two cores this one is ours: there is no upstream binary to
# download, so it is built from source here and on GitHub Actions with the
# same command. The Go module checksums (awgbridge\go.sum) pin every
# dependency, including amneziawg-go.
#
# -trimpath and an empty build id keep the machine's paths (and the user name
# in them) out of the binary.
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and chokes on Cyrillic.
param(
  [string]$Root = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
  throw "Go is not installed or not on PATH - it is needed to build awg-bridge.exe"
}

$out = Join-Path $Root "awg-bridge.exe"
$env:CGO_ENABLED = "0"
$env:GOOS = "windows"
$env:GOARCH = "amd64"

Push-Location (Join-Path $Root "awgbridge")
try {
  # Native commands do not throw under Stop, so the exit code is checked.
  & go build -trimpath -ldflags "-s -w -buildid=" -o $out ./cmd/awg-bridge
  if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

$version = & $out -version
if ($LASTEXITCODE -ne 0) { throw "awg-bridge.exe does not start" }
Write-Host ("{0} ({1:N1} MB)" -f $version, ((Get-Item $out).Length / 1MB))
