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
$shaped = "^\s*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'\s*(#.*)?$"
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
  if ($line -match "^([A-Z][A-Z0-9_]*)='([^']*)'\s*(#.*)?$") { $stated[$Matches[1]] = $Matches[2] }
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
$base   = @('-p', "$port", '-o', 'ConnectTimeout=20', '-o', 'StrictHostKeyChecking=accept-new')

# WHICH DOOR THIS MACHINE OPENS, asked before anything is sent, because the two cases
# this has to serve are opposites. A machine this platform installed carries the
# operator key and has had its password door shut by disable-password-login. A machine
# at its birth carries NO key — deploy-host's install_authorized_key row is what puts it
# there — so its first session can only be a password session, and it is the case these
# launchers exist for.
#
# The key is tried first and the password only where the key is refused, so neither case
# needs a flag and a re-run never asks for a password a machine no longer takes.
$probe = (& ssh @base -o BatchMode=yes $target true 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) {
  $door = @('-o', 'BatchMode=yes')
  Write-Host "  $target opens to the operator key" -ForegroundColor DarkGray
}
elseif ($probe -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed') {
  # NOT ACCEPTED SILENTLY, and accept-new deliberately does not cover it: a machine
  # whose host key changed is either one that was rebuilt or one that is not the
  # machine any more, and only the operator knows which.
  Stop-Here (@(
    "$fqdn answers with a host key this machine does not recognise."
    ''
    'A restore gives a machine a NEW host key, so if you have just restored it that is'
    'expected. Forget the old one and start again:'
    ''
    "  ssh-keygen -R $fqdn"
    ''
    "If you have NOT restored it, clear nothing: something else is answering for $fqdn."
  ) -join [Environment]::NewLine) 74
}
elseif ($probe -match 'Permission denied') {
  if ([Console]::IsInputRedirected) {
    Stop-Here "$target carries no operator key yet, so this can only be a password session — and there is no terminal here to ask on. Start it from a terminal." 69
  }
  $door = @('-o', 'BatchMode=no', '-o', 'NumberOfPasswordPrompts=1')
  Write-Host ''
  Write-Host "  $target carries no operator key yet. deploy-host is what puts it there," -ForegroundColor Yellow
  Write-Host '  and it is one of the five programs this is about to run.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  ssh will ask for the login password ONCE, on this terminal. It is not read' -ForegroundColor DarkGray
  Write-Host '  from the config, it is not kept, and it does not reach the transcript.' -ForegroundColor DarkGray
}
else {
  Stop-Here "could not reach ${target}:$([Environment]::NewLine)$([Environment]::NewLine)$($probe.Trim())" 69
}

# ONE SESSION, so that a password is typed at most once. The stream is the config
# inside a quoted heredoc with the driver behind it: the config lands on the machine
# under a mask that admits nobody else, and driver.sh shreds it on every path it can
# end on. Neither is ever an argument, because an argument stands in a process listing.
# The heredoc marker cannot collide with anything in the config, because the guard
# above admits no line but a comment and NAME='value'.
#
# A CARRIAGE RETURN IS TAKEN OFF BOTH, and on Windows that is not a formality: the
# config is written in whatever editor the operator has and Notepad writes CRLF, while
# the far side is a bash that reads a CR as part of the value. NAME='value' followed by
# a CR would put that CR INSIDE the value, so the FQDN a certificate is issued for
# would carry one and nothing downstream would say why.
$lf     = "`n"
$stream = ("umask 077${lf}cat > `"`$1`" <<'AW_CONFIG_END'${lf}" +
           ((Get-Content -Raw -Path $ConfigFile) -replace "`r", '') + $lf +
           "AW_CONFIG_END${lf}" +
           ((Get-Content -Raw -Path $driver) -replace "`r", ''))

# UTF-8 IN BOTH DIRECTIONS, and they are two different settings.
#
# $OutputEncoding is what PowerShell SENDS to a native command; without a BOM,
# because bash would read those three bytes as part of `umask`.
#
# [Console]::OutputEncoding is what PowerShell READS BACK from one, and it is the
# one that was missing: driver.sh draws its phases with ══ and its verdicts with ✓,
# and a console left on its code page turned those into ΓòÉΓòÉ and Γ£ô. The bytes
# arriving were always right; nothing was decoding them.
#
# BOTH ARE PUT BACK. This runs in the operator's own session when it is started as
# ./install.ps1, so a console encoding changed here would outlive the installation.
$spokenBefore = $OutputEncoding
$heardBefore  = [Console]::OutputEncoding
try {
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

  $stream | & ssh @base @door $target 'bash -s -- "$HOME/.aw-config.env"' 2>&1 |
    Tee-Object -FilePath $transcript
  $installed = $LASTEXITCODE
}
finally {
  $OutputEncoding = $spokenBefore
  [Console]::OutputEncoding = $heardBefore
}

# ---------------------------------------------------- the machine's own records
# FETCHED WHATEVER HAPPENED: a failed installation is the one whose records are
# read, so this runs on the failing path too.
$runsLine = Get-Content -Path $transcript |
  ForEach-Object { $_ -replace "`e\[[0-9;]*m", '' } |
  Select-String -Pattern '^\s*RUNS (.+)$' | Select-Object -Last 1
if ($runsLine) {
  $ids = @($runsLine.Matches[0].Groups[1].Value.Trim() -split '\s+' | Where-Object { $_ })
  Write-Host ''
  Write-Host "  Fetching the machine's own record of $($ids.Count) run(s) into $session" -ForegroundColor DarkGray
  $arrived = 0
  foreach ($id in $ids) {
    $into = Join-Path $session $id
    New-Item -ItemType Directory -Force -Path $into | Out-Null
    & scp -q -P $port -o BatchMode=yes "${target}:/var/lib/ansiwise/runs/$id/*" $into 2>$null
    & scp -q -P $port -o BatchMode=yes "${target}:/var/lib/ansiwise/runs/$id.startup.log" $into 2>$null
    # WHAT ACTUALLY LANDED, COUNTED. An empty directory beside a line saying the
    # records were fetched is worse than no line at all: it reads as "they are
    # there" to whoever comes looking for them later.
    if (@(Get-ChildItem -LiteralPath $into -Force -ErrorAction SilentlyContinue).Count -gt 0) {
      $arrived++
    } else {
      Remove-Item -LiteralPath $into -Force -ErrorAction SilentlyContinue
    }
  }
  if ($arrived -eq 0) {
    Write-Host '  NOTHING ARRIVED. The machine named its runs, and none of them could be read.' -ForegroundColor Yellow
    Write-Host '  Either this account carries no key on that machine yet — deploy-host installs' -ForegroundColor Yellow
    Write-Host '  it, and it did not get that far — or the records are not readable by it. They' -ForegroundColor Yellow
    Write-Host '  stand on the machine either way:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "    ssh $target sudo tar -C /var/lib/ansiwise -cf - runs | tar -C $session -xf -" -ForegroundColor DarkGray
  } else {
    Write-Host "  $arrived of $($ids.Count) arrived: $session" -ForegroundColor Green
  }
} else {
  Write-Host '  The machine named no runs — read the transcript above; nothing was recorded to fetch.' -ForegroundColor Yellow
}
Write-Host ''

exit $installed
