# =============================================================================
# install.ps1 — start a first master's installation from Windows.
# =============================================================================
#
#   pwsh ./install.ps1                     reads ./installation.json
#   pwsh ./install.ps1 other-machine.json  reads that instead
#
# NO OPTIONS, AND THAT IS THE POINT. An installation is a great many statements —
# thirty-three answers for deploy-branch alone — and a command line long enough to
# carry them is one nobody can read back, nobody can diff, and whose every value
# stands in this machine's process listing and in the shell's history. One file
# states the whole installation; this reads it and starts.
#
# THE TWIN OF install.sh, doing the same four things in the same order: refuse a
# file anyone else can read, compose the envelope, open one session, keep every
# line that comes back. The installation itself is driver.sh and it runs ON
# THE MACHINE — nothing is fetched here and nothing is carried from this disk, so
# what stands on the machine afterwards is what the repositories say rather than
# what this checkout happened to hold.
#
# THE FILE CARRIES CREDENTIALS AND IS REFUSED UNLESS IT IS PROTECTED. Nine of
# deploy-branch's answers are credentials — three repository write tokens, a DNS
# token, a storage password, a registry token — and two more open this session and
# the catalogue. A file other accounts can read is refused by name, and so is one
# standing inside a git working tree, because the mistake that is made once is
# `git add .` and a token that reached a remote must be rotated.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $InstallationFile = './installation.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Stop-Here([string] $Because, [int] $Code = 65) {
  Write-Host ''
  Write-Host "  $Because" -ForegroundColor Red
  Write-Host ''
  exit $Code
}

$driver = Join-Path $PSScriptRoot 'driver.sh'
if (-not (Test-Path $driver)) { Stop-Here 'driver.sh is not beside this file — it IS the installation, and this only starts it' 66 }
if (-not (Test-Path $InstallationFile)) {
  Stop-Here "there is no installation file at $InstallationFile. Copy installation.example.json, fill it in, then take every other account off it" 66
}
$InstallationFile = (Resolve-Path $InstallationFile).Path

# ------------------------------------------------------- the file, and its guard
# OWNER-ONLY OR NOTHING. Windows says this with an access list rather than a mode,
# so the question asked here is the same one and the answer is read differently:
# which accounts hold rights on it, beyond the owner and the system.
$acl = Get-Acl -Path $InstallationFile
$owner = $acl.Owner
$strangers = @($acl.Access | Where-Object {
  $who = $_.IdentityReference.Value
  $who -ne $owner -and
  $who -notmatch '(?i)\\SYSTEM$' -and
  $who -notmatch '(?i)\\Administrators$' -and
  $who -notmatch '(?i)^NT AUTHORITY\\SYSTEM$' -and
  $who -notmatch '(?i)^BUILTIN\\Administrators$'
} | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)

if ($strangers.Count -gt 0) {
  Stop-Here (@(
    "$InstallationFile can be read by $($strangers -join ', ') and it carries credentials —"
    'nine of deploy-branch''s answers are tokens with write access to your repositories.'
    'Take every other account off it:'
    ''
    "  icacls `"$InstallationFile`" /inheritance:r /grant:r `"$($env:USERNAME):(R,W)`""
  ) -join [Environment]::NewLine) 77
}

# INSIDE A GIT TREE IS REFUSED, for the reason above: the mistake is made once and
# cannot be taken back.
$inTree = & git -C (Split-Path -Parent $InstallationFile) rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $inTree) {
  Stop-Here (@(
    "$InstallationFile stands inside the git working tree at $inTree."
    'A file of credentials belongs nowhere a commit can reach it — move it out, or say so'
    'in that tree''s .gitignore and move it anyway.'
  ) -join [Environment]::NewLine) 77
}

# ------------------------------------------------------------- what it must say
$stated = Get-Content -Raw -Path $InstallationFile | ConvertFrom-Json -AsHashtable
function Stated([string] $Section, [string] $Named) {
  if (-not $stated.ContainsKey($Section) -or -not $stated[$Section].ContainsKey($Named) -or -not $stated[$Section][$Named]) {
    Stop-Here "$InstallationFile states no $Section.$Named, and nothing here may choose one"
  }
  return $stated[$Section][$Named]
}

$fqdn     = Stated 'machine' 'fqdn'
$address  = Stated 'machine' 'address'
$operator = Stated 'machine' 'operator_user'
$stage    = Stated 'machine' 'stage'
$port     = if ($stated['machine'].ContainsKey('port')) { $stated['machine']['port'] } else { 22 }
$null     = Stated 'credentials' 'elevation_password'
$null     = Stated 'credentials' 'catalog_token'
$null     = Stated 'repositories' 'catalog'
$null     = Stated 'repositories' 'platform'

if (-not $stated.ContainsKey('answers') -or $stated['answers'].Count -eq 0) {
  Stop-Here "$InstallationFile states no answers at all, and an installation is what its answers say"
}
foreach ($named in @('operator_user', 'fqdn')) {
  if (-not $stated['answers'][$named]) { Stop-Here "$InstallationFile states no answers.$named" }
}
if ($stated['answers']['fqdn'] -ne $fqdn) {
  Stop-Here "$InstallationFile says machine.fqdn `"$fqdn`" and answers.fqdn `"$($stated['answers']['fqdn'])`" — one installation, one name"
}
if ($stated['answers']['operator_user'] -ne $operator) {
  Stop-Here "$InstallationFile names two different operator accounts — one installation, one account"
}
# NAMED HERE BEFORE THE MACHINE IS TOUCHED: an apostrophe in a mailbox makes the
# cluster map unparseable and the run dies far from the cause
# (simetrixch/ansiwise-plugins#161).
$carrying = @($stated['answers'].GetEnumerator() | Where-Object { $_.Value -is [string] -and $_.Value.Contains("'") } | ForEach-Object { $_.Key })
if ($carrying.Count -gt 0) {
  Stop-Here "$InstallationFile`: $($carrying -join ', ') carries an apostrophe, and a template slot standing inside quotes has no way to say so — simetrixch/ansiwise-plugins#161"
}

# THE ENVELOPE IS COMPOSED IN MEMORY and reaches the machine over standard input;
# it touches no disk on this side and stands in no argument list.
$envelope = @{
  answers            = $stated['answers']
  elevation_password = $stated['credentials']['elevation_password']
  catalog_token      = $stated['credentials']['catalog_token']
  catalog_repo       = $stated['repositories']['catalog']
  platform_repo      = $stated['repositories']['platform']
  stage              = $stage
} | ConvertTo-Json -Depth 20 -Compress

# --------------------------------------------------------------- the transcript
$session = Join-Path './install-transcripts' ("{0}-{1}" -f $fqdn, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $session | Out-Null
$transcript = Join-Path $session 'session.log'
Write-Host ''
Write-Host "  $fqdn  ·  $address  ·  stage $stage" -ForegroundColor Cyan
Write-Host "  Everything said here is also kept in $transcript" -ForegroundColor DarkGray

$target = "$operator@$address"
$ssh    = @('-p', "$port", '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', $target)

$envelope | & ssh @ssh 'umask 077 && cat > ~/.aw-envelope.json'
if ($LASTEXITCODE -ne 0) { Stop-Here "could not reach $target, or could not write the envelope there" 69 }
$envelope = $null

# THE INSTALLATION, over the same session, with the driver on standard input so
# that nothing this put there is left on the machine.
Get-Content -Raw -Path $driver | & ssh @ssh 'bash -s -- ~/.aw-envelope.json' 2>&1 |
  Tee-Object -FilePath $transcript
$installed = $LASTEXITCODE

# ---------------------------------------------------- the machine's own records
# FETCHED WHATEVER HAPPENED: a failed installation is the one whose records are
# read, so this runs on the failing path too.
$named = Select-String -Path $transcript -Pattern '^\s*RUNS (.+)$' | Select-Object -Last 1
if ($named) {
  $ids = @($named.Matches[0].Groups[1].Value.Trim() -split '\s+' | Where-Object { $_ })
  Write-Host ''
  Write-Host "  Fetching the machine's own record of $($ids.Count) run(s) into $session" -ForegroundColor DarkGray
  foreach ($id in $ids) {
    $into = Join-Path $session $id
    New-Item -ItemType Directory -Force -Path $into | Out-Null
    & scp -q -P $port -o BatchMode=yes "${target}:/var/lib/ansiwise/runs/$id/*" $into 2>$null
    & scp -q -P $port -o BatchMode=yes "${target}:/var/lib/ansiwise/runs/$id.startup.log" $into 2>$null
  }
  Write-Host "  $session" -ForegroundColor Green
} else {
  Write-Host '  The machine named no runs — read the transcript above; nothing was recorded to fetch.' -ForegroundColor Yellow
}
Write-Host ''

exit $installed
