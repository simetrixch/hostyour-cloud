# =============================================================================
# regenerate-install-branch.ps1 — bring ONE installation onto the release its map
# is pinned to. Bash twin: regenerate-install-branch.sh (same folder), which does
# the same in the same order and prints the same lines. lifecycle/test.sh measures
# that.
# =============================================================================
#
# USAGE (run from anywhere inside a hostyour-cloud checkout)
#   pwsh ./lifecycle/regenerate-install-branch.ps1 <fqdn> [config]
#
# THE TWO INPUTS
#   fqdn    — WHICH INSTALLATION is regenerated. It is the domain of the cluster,
#             the name of its install branch, the name of its map under
#             clusters/active, and the name the session is opened to.
#   config  — the key=value file stating that installation, the same one
#             install-machine.ps1 is given and in the same grammar. It holds the
#             account this machine is reached as, the password that raises a
#             command there, and the answers deploy-branch is told with.
#             Defaults to config.env beside this file.
#
# THIS IS THE SECOND ACT, and release-platform.ps1 beside it is the first. That
# one writes `release: <tag>` into clusters/active/<fqdn>.yaml on the install
# branch and stops. That line alone moves every CHART the cluster reads: the
# reconciler's own tree fills __RELEASE__ from it, and every source that reads a
# chart of this repository targets that ref. What it does not move is the three
# trees the reconciler reads from the install branch itself -- clusters/argocd,
# clusters/bootstrap and clusters/platform. This performs the regeneration that
# carries those, and the two are separate acts on purpose: between them somebody
# can read what the pin now says, ask status.sh which of those trees this release
# touched, and stop where it touched none.
#
# THE REF IS READ OFF THE PIN AND NEVER ASKED FOR. `release:` in that map is
# where the first act recorded the state, so reading it is what makes the pin and
# the regeneration ONE statement rather than two that can disagree. An
# installation is brought to the state its own map records, or the run refuses.
#
# NOTHING IS TOUCHED BEFORE THE TARGET IS KNOWN GOOD. The branch, the map, the
# pin and the tag are asked of the REMOTE before a session is opened, so a
# mistyped domain or a pin naming a tag nobody pushed costs a fetch and no more.
# Every refusal below says that nothing has been changed, because at every one of
# them nothing has.
#
# WHAT ACTUALLY REGENERATES A BRANCH is deploy-branch.yaml in the catalogue
# repository, run by the engine on the machine. This opens ONE session, carries
# the config over it, and starts regenerate-driver.sh there — the same shape
# install-machine.ps1 uses to start driver.sh, and for the same
# reason: what runs on a machine is fetched by that machine, and what this
# carries over is the operator's own config and nothing else.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Fqdn = '',
  [Parameter(Position = 1)][string] $ConfigFile = '',
  # THROWN AWAY ONLY WHEN SAID. The twin takes -Discard where the shell takes
  # --discard: PowerShell binds a double dash as a parameter name of its own.
  [switch] $Discard
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# EVERY git AND ssh CALL BELOW IS READ BY ITS EXIT CODE, and several of them are
# probes that are MEANT to fail. Newer PowerShell turns a non-zero native exit
# into a terminating error under the preference above, which would end this run on
# the first probe; stated here so the behaviour is the same on every version.
$PSNativeCommandUseErrorActionPreference = $false

# EVERY REFUSAL SAYS THAT NOTHING HAS BEEN CHANGED, and it is appended here
# rather than written out eighteen times: every one of them stands before the
# session is opened, so the sentence is true of all of them by construction and
# cannot be forgotten on the one that is added next.
#
# AND EVERY LINE ENDS IN ONE BYTE. Write-Host and WriteLine end a line with what
# the running system calls a newline, which on Windows is two bytes and on Linux
# one, so the same script would print different bytes on two machines and the
# twin could never be held to matching it. The newline is written out here
# instead, and a carriage return never enters the output at all.
function Stop-Here([string] $Because, [int] $Code = 65) {
  [Console]::Error.Write("regenerate: $Because. Nothing has been changed`n")
  exit $Code
}
function Say([string] $Line) { [Console]::Out.Write("$Line`n") }

# THE VALUE OF ONE TOP-LEVEL KEY of the installation's map, read the way the
# catalogue's own step writes it: a line beginning at column one with the key and
# a colon. A key of the same name indented under `global:` is a different key and
# is deliberately not seen. Surrounding quotes are the notation's and are taken
# off, which is what the catalogue's reading step does too.
function Read-MapValue([string[]] $Text, [string] $Key) {
  foreach ($line in $Text) {
    if (-not $line.StartsWith("${Key}:")) { continue }
    $value = $line.Substring($Key.Length + 1).Trim()
    if ($value.Length -ge 2) {
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }
    return $value
  }
  return ''
}

if (-not $Fqdn) {
  Stop-Here 'usage: lifecycle/regenerate-install-branch.ps1 <fqdn> [config]' 64
}

$driver = Join-Path $PSScriptRoot 'regenerate-driver.sh'
if (-not (Test-Path -LiteralPath $driver)) {
  Stop-Here 'regenerate-driver.sh is not beside this file. It IS the regeneration on the machine, and this only starts it' 66
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Stop-Here 'git is not on this path, and everything read below is read out of git'
}
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'not inside a git repository. Run this from a checkout of the platform tree' 66
}

# ---------------------------------------------------------- the target, asked
# ASKED OF THE REMOTE AND NOT OF THIS CHECKOUT, for the same reason the first act
# reads the remote: an install branch moves without this workstation — a release
# writes its pin onto it — so a local view of that branch answers about whenever it
# last looked.
git ls-remote --exit-code --heads origin "refs/heads/$Fqdn" *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here "origin has no branch $Fqdn. An installation is regenerated on its own install branch, and there is none of that name" 66
}
git fetch --quiet origin "refs/heads/$Fqdn" *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here "the branch $Fqdn could not be fetched from origin, so its pin cannot be read" 69
}

$map = "clusters/active/$Fqdn.yaml"
$mapText = @(git show "FETCH_HEAD:$map" 2>$null)
if ($LASTEXITCODE -ne 0) {
  Stop-Here "branch $Fqdn carries no $map. That map is where an installation records what it is, and the pin is one line in it" 66
}

$pin = Read-MapValue $mapText 'release'
if (-not $pin) {
  Stop-Here "$map on branch $Fqdn carries no release line, so nothing records which state this installation is to stand on. release-platform.sh / release-platform.ps1 beside this file writes that line" 65
}

# THE TAG IS ASKED OF THE REMOTE, because the remote is what the machine fetches
# from. A pin naming a tag this workstation happens to carry and origin does not
# would send the machine after a ref it can never resolve, and the run would fail
# three systems away in a message about a git ref rather than about a release.
$onRemote = @(git ls-remote --tags origin "refs/tags/$pin")
if ($onRemote.Count -eq 0) {
  Stop-Here "origin carries no $pin, and that is what $map pins $Fqdn to. The machine fetches from origin, so a state only this workstation knows is a state it cannot reach" 69
}

Say "regenerate: $Fqdn is pinned to $pin in $map, and that is the state this brings it to"

# ------------------------------------------------------- the config, and its guards
# THE SAME FILE install-machine.ps1 IS GIVEN, in the same grammar and under the
# same guards. It carries the account this machine is reached as, the password
# that raises a command there, and every answer deploy-branch declares except
# the ref, which is the pin above.
if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'config.env' }
if (-not (Test-Path -LiteralPath $ConfigFile)) {
  Stop-Here "there is no config at $ConfigFile. It states the installation this regenerates: copy config.example.env beside it, fill it in, and name it as the second argument" 66
}
$ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path

# OWNER-ONLY OR NOTHING. Windows says this with an access list rather than a mode,
# so the question asked here is the one the bash twin asks and only the answer is
# read differently: which accounts hold rights on it, beyond the owner and the
# system.
$acl = Get-Acl -Path $ConfigFile
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

# INSIDE A GIT TREE AND NOT IGNORED BY IT is refused: the mistake is made once and
# cannot be taken back, because a token that reached a remote must be rotated.
# IGNORED IS ENOUGH — what this stops is `git add .` sweeping the file up, and a
# file the tree ignores takes a deliberate `git add -f`, which is somebody choosing.
$configDir = Split-Path -Parent $ConfigFile
git -C $configDir rev-parse --show-toplevel *> $null
if ($LASTEXITCODE -eq 0) {
  git -C $configDir check-ignore -q $ConfigFile *> $null
  if ($LASTEXITCODE -ne 0) {
    Stop-Here "$ConfigFile stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore" 77
  }
}

# NOTHING BUT ASSIGNMENTS AND COMMENTS, checked here although the file is read by
# a shell on the far side: a shell `.` executes every line, so a config carrying a
# command would run it there with the operator's own rights. Refusing it on this
# side tells the operator which line is wrong while the file is still open in
# front of them, rather than after a session has been opened to the machine.
$lines = @(Get-Content -Path $ConfigFile)
$shaped = "^\s*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'\s*(#.*)?$"
$bad = @(@(for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -notmatch $shaped) { '{0}:{1}' -f ($i + 1), $lines[$i] }
}) | Select-Object -First 3)
if ($bad.Count -gt 0) {
  Stop-Here "$ConfigFile carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL on both sides: $($bad -join "`n")" 65
}

# READ, NEVER EXECUTED. The same assignments the shell will source, parsed here
# only to name a missing value before a session is opened.
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
  Stop-Here "$ConfigFile states no ELEVATION_PASSWORD, and a regeneration is run elevated" 65
}

# ONE CONFIG STATES ONE INSTALLATION. The answers in it land in this cluster's own
# map and in its own credential files, so a config naming another installation
# would regenerate this branch out of another one's answers — every stamp writing
# a domain, a name and a stage that belong to a different machine.
if ((Stated 'FQDN') -ne $Fqdn) {
  Stop-Here "$ConfigFile states FQDN $(Stated 'FQDN') and this run names $Fqdn. One config states one installation, and its answers are what the branch is regenerated from" 65
}

# ------------------------------------------------------------- the machine
# A MACHINE IS ADDRESSED BY ITS NAME, and by nothing else — the name in the map,
# which is the name of the branch and the name on the certificate.
$port = 22
$target = '{0}@{1}' -f (Stated 'OPERATOR_USER'), $Fqdn
$base = @('-p', "$port", '-o', 'ConnectTimeout=20', '-o', 'StrictHostKeyChecking=accept-new')

# WHICH DOOR THIS MACHINE OPENS, asked before anything is sent. An installation
# that stands carries the operator key — deploy-host's install_authorized_key row
# put it there and disable-password-login shut the password door — so the key is
# the case here, and the password is the exception a machine still at its birth
# would need. The key is tried first and the password only where the key is
# refused, so neither case needs a flag.
$probe = (& ssh @base -o BatchMode=yes $target true 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) {
  $door = @('-o', 'BatchMode=yes')
  Say "regenerate: $target opens to the operator key"
}
elseif ($probe -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed') {
  # NOT ACCEPTED SILENTLY, and accept-new deliberately does not cover it: a
  # machine whose host key changed is either one that was rebuilt or one that is
  # not the machine any more, and only the operator knows which.
  Stop-Here "$Fqdn answers with a host key this machine does not recognise. A restore gives a machine a NEW host key: if you have just restored it, forget the old one with ssh-keygen -R $Fqdn and start again. If you have not, clear nothing: something else is answering for $Fqdn" 74
}
elseif ($probe -match 'Permission denied') {
  if ([Console]::IsInputRedirected) {
    Stop-Here "$target refuses the operator key, so this could only be a password session, and there is no terminal here to ask on. Start it from a terminal" 69
  }
  $door = @('-o', 'BatchMode=no', '-o', 'NumberOfPasswordPrompts=1')
  Say "regenerate: $target refuses the operator key, so ssh asks for the login password ONCE, on this terminal. It is not read from the config and it is not kept"
}
else {
  Stop-Here "$target could not be reached: $(($probe -replace '\r?\n', ' ').Trim())" 69
}

# ONE SESSION, so that a password is typed at most once. The stream is the config
# inside a quoted heredoc with the driver behind it: the config lands on the
# machine under a mask that admits nobody else, and the driver shreds it on every
# path it can end on. Neither is ever an argument, because an argument stands in a
# process listing. The heredoc marker cannot collide with anything in the config,
# because the guard above admits no line but a comment and NAME='value'.
#
# THE PIN IS APPENDED AS THE LAST LINE, in the config's own grammar, so the
# driver composes it into the answers exactly as it composes every other value and
# holds no special case for it. Last, because the composer reads the file top to
# bottom and a later line wins: a config that states a PLATFORM_REF of its own is
# a stale ref, and the pin on the branch is the one this act is about.
#
# A CARRIAGE RETURN IS TAKEN OFF BOTH, and on Windows that is not a formality: the
# config is written in whatever editor the operator has and Notepad writes CRLF,
# while the far side is a bash that reads a CR as part of the value.
$lf = "`n"
$stream = ("umask 077${lf}cat > `"`$1`" <<'AW_CONFIG_END'${lf}" +
           ((Get-Content -Raw -Path $ConfigFile) -replace "`r", '') + $lf +
           "PLATFORM_REF='$pin'${lf}" +
           "AW_CONFIG_END${lf}" +
           ((Get-Content -Raw -Path $driver) -replace "`r", ''))

# UTF-8 ON THE WAY OUT. $OutputEncoding is what PowerShell SENDS to a native
# command, and the config carries credentials an operator may have written in any
# alphabet — a password re-encoded into the console's code page is a password the
# machine refuses. Without a BOM, because bash would read those three bytes as
# part of `umask`. It is put back: this runs in the operator's own session, so an
# encoding changed here would outlive the regeneration.
$spokenBefore = $OutputEncoding
try {
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $remote = if ($Discard) { 'bash -s -- "$HOME/.aw-regenerate.env" --discard' } else { 'bash -s -- "$HOME/.aw-regenerate.env"' }
  $stream | & ssh @base @door $target $remote
  $regenerated = $LASTEXITCODE
}
finally {
  $OutputEncoding = $spokenBefore
}

if ($regenerated -eq 0) {
  Say "regenerate: $Fqdn stands on $pin"
}
else {
  Say "regenerate: the regeneration of $Fqdn ended with exit $regenerated. The line above it says which mode stopped and why"
}
exit $regenerated
