# Run by the owner in PowerShell on the PC. Sends the R2 values straight into
# backup.conf on the box through ssh stdin: nothing is saved on the PC, nothing
# reaches a command line, and the secret is not shown while it is typed.
#   powershell -ExecutionPolicy Bypass -File set-r2-secrets.ps1 -Box deploy@<IP>
# -Fake sends made-up values, to test the path without a real token.
param(
  [Parameter(Mandatory = $true)][string]$Box,
  [string]$Conf = '/opt/box-ops/backup.conf',
  [switch]$Fake
)
$ErrorActionPreference = 'Stop'
$Ssh ='C:\Windows\System32\OpenSSH\ssh.exe'

function Read-Secret($Prompt) {
  $s = Read-Host $Prompt -AsSecureString
  $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p).Trim() }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

if ($Fake) {
  $Endpoint = 'https://' + ('a' * 32) + '.r2.cloudflarestorage.com'
  $KeyId = 'b' * 32
  $Secret = 'c' * 64
} else {
  $Endpoint = (Read-Host 'S3 endpoint (https://....r2.cloudflarestorage.com)').Trim()
  $KeyId = (Read-Host 'Access Key ID').Trim()
  $Secret = Read-Secret 'Secret Access Key (hidden)'
}

if ($Endpoint -notmatch '^https://[0-9a-f]{32}\.r2\.cloudflarestorage\.com') { throw 'Endpoint does not look right' }
$Endpoint = $Matches[0]
if ($KeyId -notmatch '^[0-9a-f]{32}$') { throw "Access Key ID: expected 32 hex characters, got $($KeyId.Length)" }
if ($Secret -notmatch '^[0-9a-f]{64}$') { throw "Secret Access Key: expected 64 hex characters, got $($Secret.Length)" }

$Lines = @(
  "R2_ENDPOINT=""$Endpoint""",
  'R2_BUCKET="box-backups"',
  "R2_ACCESS_KEY_ID=""$KeyId""",
  "R2_SECRET_ACCESS_KEY=""$Secret"""
) -join "`n"

# PowerShell 5.1 starts piped text with a byte-order mark, even with $OutputEncoding
# set, and ends lines with CRLF: both are removed on the box.
$Remote = "set -e; umask 077; c=$Conf; touch `$c; tr -d '\r' | sed '1s/^\xEF\xBB\xBF//' > `$c.in; grep -v '^R2_' `$c > `$c.new || true; cat `$c.in >> `$c.new; mv `$c.new `$c; rm -f `$c.in; stat -c '%a %s' `$c"
$Lines | & $Ssh -o BatchMode=yes $Box $Remote
if ($LASTEXITCODE -ne 0) { throw "ssh failed with exit code $LASTEXITCODE" }
Write-Host 'Saved on the box. Tell Claude: done.'
