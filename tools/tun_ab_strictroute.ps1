# A/B for strict_route under TUN, with guaranteed cleanup.
#
# The question: Russian sites are routed past the tunnel (outbound "direct")
# and do not open, while foreign sites through the tunnel work. Everything that
# should leave the machine bypassing the tunnel fails. strict_route exists
# precisely to stop traffic from bypassing the tunnel, so it is the first thing
# to rule in or out - by measurement, not by editing the app and hoping.
#
# Runs the app's own config twice, changing exactly one field, and probes the
# same three addresses each time:
#   yandex.ru  - goes to "direct" by the RU-bypass rule
#   cp.cloudflare.com - goes through the tunnel
#   1.1.1.1 over UDP  - the DNS server "dns-direct" itself uses
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and chokes on Cyrillic.
param(
  [string]$AppDir = "$env:LOCALAPPDATA\Programs\Multik Sila",
  [string]$Out = "C:\dev\proxy_app_test\build\windows\x64\runner\Release\ab_strictroute.txt"
)

$cfgSrc = Join-Path $AppDir "config.json"
if (-not (Test-Path $cfgSrc)) { "no config at $cfgSrc" | Out-File $Out -Encoding utf8; exit }
function W($s) { $s | Out-File $Out -Append -Encoding utf8 }

"=== strict_route A/B $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $Out -Encoding utf8

foreach ($strict in @($true, $false)) {
  $cfg = Join-Path $env:TEMP "ab_strict_$strict.json"
  $err = Join-Path $env:TEMP "ab_strict_$strict.err"
  $c = [IO.File]::ReadAllText($cfgSrc, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $c.inbounds[0].strict_route = $strict
  $c.experimental.clash_api.external_controller = "127.0.0.1:19399"
  [IO.File]::WriteAllText($cfg, ($c | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))

  W ""
  W "--- strict_route = $strict ---"
  $proc = $null
  try {
    $proc = Start-Process (Join-Path $AppDir "sing-box.exe") `
              -ArgumentList "run", "-c", "`"$cfg`"" `
              -RedirectStandardError $err -RedirectStandardOutput "$err.out" `
              -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 6

    foreach ($u in @("https://yandex.ru", "https://cp.cloudflare.com/generate_204")) {
      $r = & curl.exe -s -o NUL -w "http=%{http_code} dns=%{time_namelookup}s total=%{time_total}s" --max-time 15 --noproxy "*" $u
      W ("  {0,-38} {1}" -f $u, $r)
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      Resolve-DnsName yandex.ru -Server 1.1.1.1 -Type A -QuickTimeout -ErrorAction Stop | Out-Null
      W ("  {0,-38} ok in {1} ms" -f "udp dns 1.1.1.1", $sw.ElapsedMilliseconds)
    } catch {
      W ("  {0,-38} FAILED in {1} ms" -f "udp dns 1.1.1.1", $sw.ElapsedMilliseconds)
    }
  }
  finally {
    if ($proc) { try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {} }
    Start-Sleep -Seconds 3
  }
  # what the core said about the direct outbound
  $lines = Get-Content $err -EA SilentlyContinue | Select-String "outbound/direct|yandex" | Select-Object -First 4
  foreach ($l in $lines) { W ("    core: " + $l.Line) }
}
W ""
W "=== done $(Get-Date -Format 'HH:mm:ss') ==="
