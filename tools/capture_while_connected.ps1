# Records network state while the user tries to connect.
#
# Needed because when the VPN is on, Claude Code stops responding - so I cannot
# run commands at the exact moment the breakage happens. This runs on its own,
# independent of the session, and writes to a file.
#
# ASCII only on purpose: PowerShell 5.1 reads .ps1 without a BOM as ANSI, and
# Cyrillic in comments breaks parsing (already stepped on that once).
#
# Every 3 seconds it samples:
#   - whether the system proxy is on and where it points
#   - the exit IP of a DIRECT connection (bypassing our proxy) - the key value:
#     does it change while our core is running?
#   - Anthropic's answer over that direct path (401 = address allowed,
#     403 = refused)
#   - whether our port 1337 is listening
param(
  [double]$Minutes = 8,
  [string]$Out = "C:\dev\proxy_app_test\build\windows\x64\runner\Release\capture.txt"
)

$body = '{"model":"claude-opus-4-1","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'
$key = "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$deadline = (Get-Date).AddMinutes($Minutes)

"=== start $(Get-Date -Format 'HH:mm:ss'), running $Minutes min ===" |
  Out-File $Out -Encoding utf8

while ((Get-Date) -lt $deadline) {
  $ts = Get-Date -Format 'HH:mm:ss'

  $pe = ""
  $m = reg query $key /v ProxyEnable 2>$null | Select-String 'REG_DWORD\s+(\S+)'
  if ($m) { $pe = $m.Matches.Groups[1].Value }
  $ps = ""
  $m = reg query $key /v ProxyServer 2>$null | Select-String 'REG_SZ\s+(\S+)'
  if ($m) { $ps = $m.Matches.Groups[1].Value }

  $core = "----"
  if (netstat -ano -p tcp | Select-String "LISTENING" | Select-String ":1337\s") {
    $core = "CORE"
  }

  # --noproxy "*" on purpose: this is exactly the path taken by traffic that
  # is excluded from the proxy, Anthropic included.
  $ip = & curl.exe -s --max-time 8 --noproxy "*" "https://api.ipify.org"
  if (-not $ip) { $ip = "(no answer)" }

  $code = & curl.exe -s -o NUL -w "%{http_code}" --max-time 10 --noproxy "*" `
    -X POST "https://api.anthropic.com/v1/messages" `
    -H "content-type: application/json" -H "x-api-key: probe" `
    -H "anthropic-version: 2023-06-01" --data-raw $body

  "{0}  {1}  ProxyEnable={2} ProxyServer={3}  direct-ip={4}  anthropic={5}" -f `
    $ts, $core, $pe, $ps, $ip, $code | Out-File $Out -Append -Encoding utf8

  Start-Sleep -Seconds 3
}
"=== end $(Get-Date -Format 'HH:mm:ss') ===" | Out-File $Out -Append -Encoding utf8
