# Waits for the core to come up, then measures what can and cannot leave the
# machine while the tunnel is active.
#
# Needed because a broken tunnel takes the machine's internet with it, so the
# operator cannot run anything at that moment - the round trip goes through the
# very connection that is down. This watches for the Clash API and measures on
# its own.
#
# The probes are ordered from "no tunnel involved" to "full path", so the first
# failing line says where it breaks:
#   1. ICMP to the LAN gateway      - the physical link
#   2. TCP to the proxy server IP   - can sing-box's own dial escape the tunnel
#   3. HTTPS to a bare IP           - the tunnel carries TCP, no DNS involved
#   4. UDP DNS straight to 1.1.1.1  - UDP leaves the machine at all
#   5. HTTPS to a hostname          - the full path including the tunnel's DNS
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as ANSI and chokes on Cyrillic.
param(
  [int]$WaitMinutes = 12,
  [string]$Out = "C:\dev\proxy_app_test\build\windows\x64\runner\Release\tundiag.txt",
  [string]$ProxyIp = "78.17.99.116",
  [int]$ProxyPort = 57181
)

$api = "http://127.0.0.1:9090"
$deadline = (Get-Date).AddMinutes($WaitMinutes)
function W($s) { $s | Out-File $Out -Append -Encoding utf8 }

"=== watcher started $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $Out -Encoding utf8

while ((Get-Date) -lt $deadline) {
  try { Invoke-RestMethod "$api/version" -TimeoutSec 3 | Out-Null; break }
  catch { Start-Sleep -Seconds 2 }
}
if ((Get-Date) -ge $deadline) { W "core never came up"; exit }
W "core is up at $(Get-Date -Format 'HH:mm:ss')"
Start-Sleep -Seconds 5

$gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -EA SilentlyContinue |
       Where-Object { $_.NextHop -ne "0.0.0.0" } | Select-Object -First 1).NextHop
W "lan gateway: $gw"
(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -EA SilentlyContinue |
  Select-Object InterfaceAlias, RouteMetric | Out-String) | Out-File $Out -Append -Encoding utf8

W "--- 1. ICMP to LAN gateway (physical link) ---"
if ($gw) { W ("  " + (Test-Connection -ComputerName $gw -Count 2 -Quiet -EA SilentlyContinue)) }

W "--- 2. TCP to proxy server ${ProxyIp}:${ProxyPort} (can the core's dial escape) ---"
$sw = [Diagnostics.Stopwatch]::StartNew()
$ok = $false
try {
  $t = New-Object Net.Sockets.TcpClient
  $ok = $t.ConnectAsync($ProxyIp, $ProxyPort).Wait(8000)
  $t.Close()
} catch { $ok = $false }
W ("  connected={0}  in {1} ms" -f $ok, $sw.ElapsedMilliseconds)

W "--- 3. HTTPS to a bare IP, no DNS involved ---"
W ("  1.1.1.1        " + (& curl.exe -s -o NUL -w "http=%{http_code} total=%{time_total}s" -k --max-time 15 --noproxy "*" "https://1.1.1.1/"))

W "--- 4. UDP DNS straight to 1.1.1.1 ---"
try {
  $r = Resolve-DnsName -Name "example.com" -Server 1.1.1.1 -Type A -QuickTimeout -EA Stop
  W ("  answered: " + (($r | Where-Object { $_.IPAddress }).IPAddress -join ', '))
} catch { W "  failed: $($_.Exception.Message)" }

W "--- 5. HTTPS to a hostname (full path) ---"
W ("  cp.cloudflare  " + (& curl.exe -s -o NUL -w "http=%{http_code} dns=%{time_namelookup}s total=%{time_total}s" --max-time 20 --noproxy "*" "https://cp.cloudflare.com/generate_204"))

try {
  $cn = Invoke-RestMethod "$api/connections" -TimeoutSec 5
  W "connections=$($cn.connections.Count) down=$($cn.downloadTotal) up=$($cn.uploadTotal)"
} catch {}
W "=== done $(Get-Date -Format 'HH:mm:ss') ==="
