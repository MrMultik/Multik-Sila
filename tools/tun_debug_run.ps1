# Runs the core under TUN with debug logging and guaranteed cleanup.
#
# Why this exists: the app runs the core at log level "info", and info does not
# say WHY a lookup or a dial stalls - it only shows that a packet went out and
# nothing came back. Raising the level inside the app would mean a rebuild plus
# a reinstall for a single measurement, so instead we take the config the app
# already generated and run the same binary ourselves, verbatim except for the
# log level.
#
# Everything is wrapped in try/finally with a hard time limit: a TUN session
# left running takes the machine's network with it, and asking for a second UAC
# prompt just to undo the first one is unacceptable.
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and chokes on Cyrillic.
param(
  [int]$Seconds = 40,
  [string]$AppDir = "$env:LOCALAPPDATA\Programs\Multik Sila",
  [string]$Out = "C:\dev\proxy_app_test\build\windows\x64\runner\Release\tundebug.txt"
)

$ErrorActionPreference = "Continue"
$cfgSrc = Join-Path $AppDir "config.json"
$cfgDbg = Join-Path $env:TEMP "singbox_debug.json"
$errLog = Join-Path $env:TEMP "singbox_debug.err"

if (-not (Test-Path $cfgSrc)) { "no config at $cfgSrc" | Out-File $Out -Encoding utf8; exit }

# Same config, one field changed.
$c = [IO.File]::ReadAllText($cfgSrc, [Text.Encoding]::UTF8) | ConvertFrom-Json
$c.log.level = "debug"
[IO.File]::WriteAllText($cfgDbg, ($c | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))

"=== debug run $(Get-Date -Format 'HH:mm:ss'), $Seconds s ===" | Out-File $Out -Encoding utf8
$proc = $null
try {
  $proc = Start-Process (Join-Path $AppDir "sing-box.exe") `
            -ArgumentList "run", "-c", "`"$cfgDbg`"" `
            -RedirectStandardError $errLog -RedirectStandardOutput "$errLog.out" `
            -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 6

  "--- probes ---" | Out-File $Out -Append -Encoding utf8
  foreach ($u in @("https://cp.cloudflare.com/generate_204", "https://www.google.com", "https://web.telegram.org")) {
    $r = & curl.exe -s -o NUL -w "http=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s total=%{time_total}s" --max-time 25 --noproxy "*" $u
    ("  {0,-40} {1}" -f $u, $r) | Out-File $Out -Append -Encoding utf8
  }
  Start-Sleep -Seconds 3
}
finally {
  if ($proc) { try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {} }
  Start-Sleep -Seconds 2
  "--- core log (debug) ---" | Out-File $Out -Append -Encoding utf8
  if (Test-Path $errLog) {
    Get-Content $errLog -EA SilentlyContinue | Out-File $Out -Append -Encoding utf8
  }
  "=== done $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $Out -Append -Encoding utf8
}
