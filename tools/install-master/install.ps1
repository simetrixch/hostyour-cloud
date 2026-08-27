# =============================================================================
# install.ps1 — install a first master, from Windows.
# =============================================================================
#
#   pwsh ./install.ps1              reads ./config.env
#   pwsh ./install.ps1 other.env    reads that instead
#
# A FIRST MASTER AND NOTHING ELSE. Everything after it — adopting a machine,
# deploying a slave, onboarding a consumer or a tenant — is the Manager's, and
# this deliberately cannot do any of it. What it installs is the one machine that
# has to exist before the Manager does.
#
# NO OPTIONS. Thirty-four values reach the five programs, and a command line long
# enough to carry them is one nobody can read back, nobody can diff, and whose
# every value stands in this machine's process listing. One file states the whole
# installation; this reads it and starts.
#
# THE TWIN OF install.sh, doing the same four things in the same order: refuse a
# config anyone else can read, carry it over, open one session, keep every line
# that comes back. The installation itself is driver.sh and it runs ON THE
# MACHINE — nothing is fetched here and nothing is carried from this disk, so what
# stands on the machine afterwards is what the repositories say rather than what
# this checkout happened to hold.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $ConfigFile = './config.env'
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
if (-not (Test-Path $driver)) {
  Stop-Here 'driver.sh is not beside this file — it IS the installation, and this only starts it' 66
}
if (-not (Test-Path $ConfigFile)) {
  Stop-Here "there is no config at $ConfigFile. Copy config.example.env, fill it in, then take every other account off it" 66
}
$ConfigFile = (Resolve-Path $ConfigFile).Path

# ------------------------------------------------------ the file, and its guards
# OWNER-ONLY OR NOTHING. Windows says this with an access list rather than a mode,
# so the question asked here is the one install.sh asks and only the answer is read
# differently: which accounts hold rights on it, beyond the owner and the system.
$acl = Get-Acl -Path $ConfigFile
$owner = $acl.Owner
$strangers = @($acl.Access | Where-Object {
  $who = $_.IdentityReference.Value
  $who -ne $owner -and
  $who -notmatch '(?i)\\SYSTEM$' -and
  $who -notmatch '(?i)\\Administrators$'
} | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)

if ($strangers.Count -gt 0) {
  Stop-Here (@(
    "$ConfigFile can be read by $($strangers -join ', ') and it carries credentials —"
    'ten of them, four being tokens with WRITE access to your repositories.'
    'Take every other account off it:'
    ''
    "  icacls `"$ConfigFile`" /inheritance:r /grant:r `"$($env:USERNAME):(F)`""
  ) -join [Environment]::NewLine) 77
}

# INSIDE A GIT TREE AND NOT IGNORED BY IT is refused: the mistake is made once and
# cannot be taken back, because a token that reached a remote must be rotated.
# IGNORED IS ENOUGH — what this stops is `git add .` sweeping the file up, and a
# file the tree ignores takes a deliberate `git add -f`, which is somebody choosing.
$here = Split-Path -Parent $ConfigFile
$inTree = & git -C $here rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $inTree) {
  & git -C $here check-ignore -q $ConfigFile 2>$null
  if ($LASTEXITCODE -ne 0) {
    Stop-Here (@(
      "$ConfigFile stands inside the git working tree at $inTree and that tree does not ignore it."
      'A file of credentials belongs nowhere a commit can reach it — move it out, or name it'
      'in that tree''s .gitignore.'
    ) -join [Environment]::NewLine) 77
  }
}

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked here although the file is read by a
# shell on the far side: a shell `.` executes every line, so a config carrying a
# command would run it there with the operator's own rights. Refusing it on this
# side tells the operator which line is wrong while the file is still open in front
# of them, rather than after a session has been opened to the machine. The pattern
# is the one install.sh and driver.sh apply, so all three agree on what a config
# may contain.
$lines = @(Get-Content -Path $ConfigFile)
$shaped = "^\s*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'\s*$"
$bad = @(@(for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -notmatch $shaped) { '{0}:{1}' -f ($i + 1), $lines[$i] }
}) | Select-Object -First 3)

if ($bad.Count -gt 0) {
  Stop-Here (@(
    "$ConfigFile carries lines that are neither a comment nor NAME='value', and this file is"
    'READ BY THE SHELL on the machine — a line that is not an assignment is a command that would run:'
    ''
    ($bad -join [Environment]::NewLine)
  ) -join [Environment]::NewLine)
}

# ------------------------------------------------------------- what it must say
# READ, NEVER EXECUTED. The same assignments the shell will source, parsed here only
# to name a missing value before a session is opened rather than ninety steps in.
$stated = @{}
foreach ($line in $lines) {
  if ($line -match "^([A-Z][A-Z0-9_]*)='([^']*)'\s*$") { $stated[$Matches[1]] = $Matches[2] }
}
function Stated([string] $Named) {
  if (-not $stated.ContainsKey($Named)) { return '' }
  return $stated[$Named]
}

foreach ($named in @('FQDN', 'OPERATOR_USER', 'STAGE', 'CATALOG_REPO', 'PLATFORM_REPO')) {
  if (-not (Stated $named)) { Stop-Here "$ConfigFile states no $named, and nothing here may choose one" }
}
if (-not (Stated 'ELEVATION_PASSWORD')) {
  Stop-Here "$ConfigFile states no ELEVATION_PASSWORD, and every program of this sequence is run elevated"
}
if (-not (Stated 'CATALOG_REPO_READ_PAT')) {
  Stop-Here "$ConfigFile states no CATALOG_REPO_READ_PAT, and the catalogue every program is read from is private"
}

# A MACHINE IS ADDRESSED BY ITS NAME, and by nothing else. The name in the config is
# the one the certificate will carry and the one the cluster is reached by, so a
# session opened to anything else is a session opened to a machine we cannot name.
$fqdn = Stated 'FQDN'
$port = 22

# --------------------------------------------------------------- the transcript
$session = Join-Path './install-transcripts' ('{0}-{1}' -f $fqdn, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $session | Out-Null
$transcript = Join-Path $session 'session.log'
Write-Host ''
Write-Host "  $fqdn  ·  stage $(Stated 'STAGE')" -ForegroundColor Cyan
Write-Host "  Everything said here is also kept in $transcript" -ForegroundColor DarkGray

$target = '{0}@{1}' -f (Stated 'OPERATOR_USER'), $fqdn
$ssh    = @('-p', "$port", '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', $target)

# THE CONFIG TRAVELS AS IT STANDS, over the session's own standard input. It lands
# under a mask that admits nobody else and driver.sh shreds it on every path it can
# end on. It is never an argument, because an argument stands in a process listing.
Get-Content -Raw -Path $ConfigFile | & ssh @ssh 'umask 077 && cat > ~/.aw-config.env'
if ($LASTEXITCODE -ne 0) { Stop-Here "could not reach $target, or could not write the config there" 69 }

# THE INSTALLATION, over the same session, with the driver on standard input so
# that nothing this put there is left on the machine.
Get-Content -Raw -Path $driver | & ssh @ssh 'bash -s -- ~/.aw-config.env' 2>&1 |
  Tee-Object -FilePath $transcript
$installed = $LASTEXITCODE

# ---------------------------------------------------- the machine's own records
# FETCHED WHATEVER HAPPENED: a failed installation is the one whose records are
# read, so this runs on the failing path too.
$runsLine = Select-String -Path $transcript -Pattern '^\s*RUNS (.+)$' | Select-Object -Last 1
if ($runsLine) {
  $ids = @($runsLine.Matches[0].Groups[1].Value.Trim() -split '\s+' | Where-Object { $_ })
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
