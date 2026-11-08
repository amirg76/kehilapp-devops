# Run by the owner in PowerShell on the PC. Copies the Telegram bot token and chat
# id from the trading-desk settings into backup.conf, inside the box: the values
# never leave it and are not shown. Only their lengths are printed.
#   powershell -ExecutionPolicy Bypass -File set-telegram.ps1 -Box deploy@<IP>
param(
  [Parameter(Mandatory = $true)][string]$Box
)
$ErrorActionPreference = 'Stop'
$Ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'
$Script = @'
set -euo pipefail
umask 077
c=/opt/box-ops/backup.conf
touch "$c"
sed -i '/^TELEGRAM_/d' "$c"
for n in TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
  v=$(grep -m1 "^$n=" /opt/trading-desk/.env | cut -d= -f2- | tr -d "\r\"'")
  printf '%s="%s"\n' "$n" "$v" >> "$c"
done
. "$c"
echo "mode=$(stat -c %a "$c") token_len=${#TELEGRAM_BOT_TOKEN} chat_len=${#TELEGRAM_CHAT_ID}"
'@
# PowerShell 5.1 adds a byte-order mark and CRLF to piped text: the first line of
# the piped text is a harmless comment for that reason, and CR is removed on the box.
("#`n" + $Script) | & $Ssh -o BatchMode=yes $Box "tr -d '\r' | bash -s"
if ($LASTEXITCODE -ne 0) { throw "ssh failed with exit code $LASTEXITCODE" }
Write-Host 'Saved on the box. Tell Claude: done.'
