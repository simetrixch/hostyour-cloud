# ===========================================================================
# master-backup.ps1 — takes a backup of ONE master, from an operator's machine.
#
#   pwsh lifecycle/master-backup.ps1 lifecycle/config.<machine>.env
#
# The PowerShell spelling of master-backup.sh, held to the same bytes by lifecycle/test.sh. What it
# takes and why, what stops and for how long, and which door it opens are stated there, once.
# ===========================================================================
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $ConfigFile = '',
  [Parameter(ValueFromRemainingArguments = $true)][string[]] $More = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
function Stop-Here([string] $Because, [int] $Code = 65) {
  [Console]::Error.Write("backup: $Because. Nothing has been changed`n")
  exit $Code
}
function Say([string] $Line) { [Console]::Out.Write("$Line`n") }

if ($More.Count -gt 0) {
  Stop-Here "lifecycle/master-backup.ps1 was given more than it takes: $($More[0])" 64
}
if (-not $ConfigFile) {
  Stop-Here 'usage: lifecycle/master-backup.ps1 <config>' 64
}
$driver = Join-Path $PSScriptRoot 'master-backup-driver.sh'
if (-not (Test-Path -LiteralPath $driver)) {
  Stop-Here 'master-backup-driver.sh is not beside this file. It IS the backup on the machine, and this only starts it' 66
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  Stop-Here 'ssh is not on this path, and the backup is one session to the machine'
}
if (-not (Test-Path -LiteralPath $ConfigFile)) {
  Stop-Here "there is no config at $ConfigFile. It states the installation this backs up: copy config.example.env beside it, fill it in, and name it as the argument" 66
}
# THE PATH IS PRINTED AS IT WAS GIVEN, so both spellings say the same file the same way; the
# resolved one is for the checks, which need a real path.
$resolvedConfig = (Resolve-Path -LiteralPath $ConfigFile).Path
$acl = Get-Acl -Path $resolvedConfig
$owner = $acl.Owner
$strangers = @($acl.Access | Where-Object {
  $who = $_.IdentityReference.Value
  $who -ne $owner -and
  $who -notmatch '(?i)\\SYSTEM$' -and
  $who -notmatch '(?i)\\Administrators$'
} | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
if ($strangers.Count -gt 0) {
  Stop-Here "$ConfigFile can be read by $($strangers -join ', ') and it carries credentials, the elevation password of the machine among them. Run: icacls `"$ConfigFile`" /inheritance:r /grant:r `"$($env:USERNAME):(F)`"" 77
}
$configDir = Split-Path -Parent $resolvedConfig
git -C $configDir rev-parse --show-toplevel *> $null
if ($LASTEXITCODE -eq 0) {
  git -C $configDir check-ignore -q $resolvedConfig *> $null
  if ($LASTEXITCODE -ne 0) {
    Stop-Here "$ConfigFile stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore" 77
  }
}
$lines = @(Get-Content -Path $resolvedConfig)
$shaped = "^\s*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'\s*(#.*)?$"
$bad = @(@(for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -notmatch $shaped) { '{0}:{1}' -f ($i + 1), $lines[$i] }
}) | Select-Object -First 3)
if ($bad.Count -gt 0) {
  Stop-Here "$ConfigFile carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL on both sides: $($bad -join "`n")" 65
}
$stated = @{}
foreach ($line in $lines) {
  if ($line -match "^([A-Z][A-Z0-9_]*)='([^']*)'\s*(#.*)?$") { $stated[$Matches[1]] = $Matches[2] }
}
function Stated([string] $Named) {
  if (-not $stated.ContainsKey($Named)) { return '' }
  return $stated[$Named]
}
foreach ($named in @('FQDN', 'OPERATOR_USER', 'STAGE')) {
  if (-not (Stated $named)) { Stop-Here "$ConfigFile states no $named, and nothing here may choose one" 65 }
}
if (-not (Stated 'ELEVATION_PASSWORD')) {
  Stop-Here "$ConfigFile states no ELEVATION_PASSWORD, and every store is stopped and copied elevated" 65
}
foreach ($named in @('STORAGE_BOX_HOST', 'STORAGE_BOX_USER', 'STORAGE_BOX_PASSWORD')) {
  if (-not (Stated $named)) { Stop-Here "$ConfigFile states no $named, and the storage box is where a backup goes" 65 }
}
if (-not (Stated 'BACKUP_PASSPHRASE')) {
  Stop-Here "$ConfigFile states no BACKUP_PASSPHRASE, and a backup of a master's every credential leaves the machine sealed or not at all" 65
}

$fqdn = Stated 'FQDN'
# The door is MACHINE_HOST where the config states one — a standby master kept through its own name
# while the identity points at the live one (install-machine.ps1 says why) — and the identity where not.
$doorHost = Stated 'MACHINE_HOST'
if (-not $doorHost) { $doorHost = $fqdn }
$port = 22
$target = '{0}@{1}' -f (Stated 'OPERATOR_USER'), $doorHost
$base = @('-p', "$port", '-o', 'ConnectTimeout=20', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes')
$probe = (& ssh @base $target true 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
  if ($probe -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed') {
    Stop-Here "$doorHost answers with a host key this machine does not recognise. A restore gives a machine a NEW host key: if you have just restored it, forget the old one with ssh-keygen -R $doorHost and start again. If you have not, clear nothing: something else is answering for $doorHost" 74
  }
  elseif ($probe -match 'Permission denied') {
    Stop-Here "$target refuses the operator key. A master carries it, so this is not an installed master — or not the machine $doorHost names" 69
  }
  else {
    Stop-Here "$target could not be reached: $(($probe -replace '\r?\n', ' ').Trim())" 69
  }
}
Say "backup: $target opens to the operator key; the backup of $fqdn starts"

$lf = "`n"
$stream = ("umask 077${lf}cat > `"`$1`" <<'AW_CONFIG_END'${lf}" +
           ((Get-Content -Raw -Path $resolvedConfig) -replace "`r", '') + $lf +
           "AW_CONFIG_END${lf}" +
           ((Get-Content -Raw -Path $driver) -replace "`r", ''))
$spokenBefore = $OutputEncoding
try {
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $stream | & ssh @base $target 'bash -s -- "$HOME/.aw-backup.env"'
  $taken = $LASTEXITCODE
}
finally {
  $OutputEncoding = $spokenBefore
}
if ($taken -eq 0) {
  Say "backup: the backup of $fqdn stands on the storage box; the BACKUP line above names it, and master-restore takes that name"
}
else {
  Say "backup: the backup of $fqdn ended with exit $taken. The line above it says what stopped and why"
}
exit $taken
