# Run by the owner in PowerShell on the PC, after creating a check at
# healthchecks.io (period 5 minutes, grace 5 minutes). Asks for the check's ping
# address and writes it into backup.conf on the box as HC_UPTIME_URL. The address
# is typed here, sent over ssh on stdin, and never printed or put on a command line.
#   powershell -ExecutionPolicy Bypass -File set-uptime-hc.ps1 -Box deploy@<IP>
param(
  [Parameter(Mandatory = $true)][string]$Box
)
$ErrorActionPreference = 'Stop'
$Ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'
$Secure = Read-Host -AsSecureString 'Healthchecks ping address (https://hc-ping.com/...)'
$Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
try { $Url = [Runtime.InteropServices.Marshal]::PtrToStringAuto($Bstr).Trim() }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr) }
if ($Url -notmatch '^https://[A-Za-z0-9./_:-]+$') { throw 'Not a plain https address. Nothing was changed.' }
# bash -s reads this script from stdin; `read` on the last line takes the next
# stdin line, which is the address. No file in /tmp, one ssh call.
$Script = @'
set -euo pipefail
umask 077
put() {
  local u=$1 c=/opt/box-ops/backup.conf
  [[ $u =~ ^https://[A-Za-z0-9./_:-]+$ ]] || { echo "not a plain https address: nothing changed"; exit 1; }
  [ -f "$c" ] || { echo "$c missing: nothing changed"; exit 1; }
  # backup.conf is sourced by the backup and the alerts: a last line without a
  # newline would swallow the new one.
  [ -z "$(tail -c1 "$c")" ] || echo >> "$c"
  sed -i '/^HC_UPTIME_URL=/d' "$c"
  printf 'HC_UPTIME_URL="%s"\n' "$u" >> "$c"
  grep -qxF "HC_UPTIME_URL=\"$u\"" "$c" || { echo "written but not found: check $c by hand"; exit 1; }
  echo "saved: mode=$(stat -c %a "$c") url_len=${#u}"
}
read -r u; put "$u"
'@
# PowerShell 5.1 adds a byte-order mark and CRLF to piped text: the first line is
# a harmless comment for that reason, and CR is removed on the box.
("#`n" + $Script + "`n" + $Url + "`n") | & $Ssh -o BatchMode=yes $Box "tr -d '\r' | bash -s"
$Url = $null
if ($LASTEXITCODE -ne 0) { throw "ssh failed with exit code $LASTEXITCODE" }
Write-Host 'Saved on the box. Tell Claude: done.'
