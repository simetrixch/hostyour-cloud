# =============================================================================
# status.ps1 — which platform release each installation stands on, and how far
# origin/master has moved past it. Bash twin: status.sh (same folder), which
# answers identically on the same repository. lifecycle/test.sh measures that.
# =============================================================================
#
#   pwsh ./lifecycle/status.ps1                          every installation
#   pwsh ./lifecycle/status.ps1 apps3.example.com        that one
#
# IT ONLY ANSWERS. Nothing here writes a file, a tag, a commit or a ref. The one
# thing it changes is this checkout's view of the remote, because an answer read
# from a stale view is not an answer. release-platform.ps1 beside it is the half
# that acts.
#
# WHAT AN INSTALLATION IS, HERE. A branch of this repository named after the
# cluster's own domain, carrying `clusters/active/<branch>.yaml` — its cluster
# map. That file is what makes a branch an installation rather than a working
# branch, so it is what this looks for, and a branch without one is skipped
# without comment.
#
# A PURE SLAVE IS NOT LISTED, AND HAS NOTHING TO LIST. A cluster that carries
# only the slave part has no install branch of its own: its map stands on the
# books branch beside the master's, and the revision it runs is the books
# branch's. So there is no release line of its own for this to read, and the
# count below is the count of INSTALL BRANCHES, not of clusters.
#
# WHAT THE PIN IS. One line in that map, `release: <tag>`, naming the state of
# the product tree the installation stands on. release-platform.ps1 writes it. A machine
# whose map records nothing cannot be told apart from one that is level, which is
# why an absent line is reported as loudly as a stale one.
#
# WHY THESE TWO TREES ARE COUNTED ON THEIR OWN. clusters/bootstrap carries seven
# TEMPLATES, and a branch program renders each of them onto the install branch as
# the file beside it, filling this installation's own domain and short name. Only
# the rendered file is applied, and it stands on that one branch. clusters/argocd
# carries root-app.yaml, whose branch name and cluster map file name are the
# placeholder domain the branch programs replace across the whole checkout.
# Neither tree can travel to a machine as the trunk writes it, so both reach an
# existing installation only by a regeneration somebody runs. A commit that
# touches one of them is therefore a commit that stays away until that happens,
# and the count of them is the number this whole answer exists for.
#
# WHAT THE PER-FILE LINE MEANS. `stamped:` names a file under one of those two
# trees that changed since the pin. It says the file needs a regeneration to reach
# the machine; it does not say a stamp row writes that particular file, and today
# root-app.yaml is the only file either tree still carries that one does. The rest
# of clusters/argocd is a CHART the reconciler renders from the cluster map, and
# clusters/bootstrap is rendered from its own templates, so in both cases the
# trunk's bytes are what a branch carries.
#
# ONE OF THOSE DIRECTORY NAMES IS ALSO WRITTEN SOMEWHERE ELSE: root-app.yaml is
# reached by the `stamp_placeholder_in_tracked_files` row of the branch programs
# in the catalogue repository that names no `tree:` at all and sweeps the whole
# checkout. Nothing compares that row against this list. A tree a regeneration
# carries and this list does not name makes every count below too low, and
# nothing would say so.
#
# IT ANSWERS ABOUT THE BRANCH, WHICH IS WHAT THE MACHINE FOLLOWS. The cluster's
# reconciler tracks the install branch, so for these files the branch is the
# machine. What it cannot see is a machine that has stopped reconciling.
#
# EXIT CODE. 0 whenever the report was produced, whatever the report says — an
# installation that is behind is an answer, not a failure. A non-zero exit means
# the question could not be answered at all: no git, no repository, no remote, or
# a name that is no installation.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Fqdn = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# EVERY git CALL BELOW IS READ BY ITS EXIT CODE, and several of them are probes
# that are MEANT to fail. Newer PowerShell turns a non-zero native exit into a
# terminating error under the preference above, which would end this run on the
# first probe; stated here so the behaviour is the same on every version.
$PSNativeCommandUseErrorActionPreference = $false

# The trees the branch programs stamp. See the header: this list and theirs are
# two statements of one fact, held together by nothing.
$stampedTrees = @('clusters/argocd', 'clusters/bootstrap')
$stampedTreesSaid = 'clusters/argocd or clusters/bootstrap'

# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
#
# AND EVERY LINE ENDS IN ONE BYTE. Write-Host and WriteLine end a line with what
# the running system calls a newline, which on Windows is two bytes and on Linux
# one, so the same script would print different bytes on two machines and the
# twin could never be held to matching it. The newline is written out here
# instead, and a carriage return never enters the output at all.
function Stop-Here([string] $Because, [int] $Code = 65) {
  [Console]::Error.Write("status: $Because`n")
  exit $Code
}
function Say([string] $Line) { [Console]::Out.Write("$Line`n") }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Stop-Here 'git is not on this path, and every line below is read out of git'
}
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'not inside a git repository. This is read from a checkout of the platform tree' 66
}

# THE VIEW FIRST. Every comparison below is against origin, so a checkout that
# has not fetched would answer about the remote as it stood whenever it last
# looked, and would not say that was what it was doing.
git fetch --quiet --tags origin *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'origin could not be fetched, so nothing here would be an answer about what origin carries' 69
}
git rev-parse --verify --quiet origin/master *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'origin carries no master, and the trunk is what every installation is measured against' 69
}

# THE VALUE OF ONE TOP-LEVEL KEY of one installation's map, read the way the
# catalogue's own step writes it: a line beginning at column one with the key and
# a colon. A key of the same name indented under `global:` is a different key and
# is deliberately not seen here. Surrounding quotes are the notation's and are
# taken off, which is what the catalogue's reading step does too.
function Read-MapValue([string] $Ref, [string] $Key) {
  $map = (git show "origin/${Ref}:clusters/active/${Ref}.yaml" 2>$null)
  if ($LASTEXITCODE -ne 0 -or $null -eq $map) { return '' }
  foreach ($line in @($map)) {
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

# Every branch of the remote that carries a cluster map named after itself.
$installations = [System.Collections.Generic.List[string]]::new()
foreach ($ref in @(git for-each-ref '--format=%(refname:strip=3)' refs/remotes/origin)) {
  if ([string]::IsNullOrEmpty($ref)) { continue }
  if ($ref -eq 'HEAD' -or $ref -eq 'master') { continue }
  git cat-file -e "origin/${ref}:clusters/active/${ref}.yaml" 2>$null
  if ($LASTEXITCODE -ne 0) { continue }
  $installations.Add($ref)
}

if ($Fqdn) {
  $kept = [System.Collections.Generic.List[string]]::new()
  foreach ($each in $installations) {
    if ($each -eq $Fqdn) { $kept.Add($each) }
  }
  if ($kept.Count -eq 0) {
    Stop-Here "origin has no installation called $Fqdn. An installation is a branch of this repository named after its own domain, carrying clusters/active/<domain>.yaml" 66
  }
  $installations = $kept
}

if ($installations.Count -eq 0) {
  Say 'status: no branch of origin carries a cluster map, so there is no installation to report on'
  exit 0
}

Say 'status: which platform release each install branch stands on, and what origin/master carries since. A cluster carrying only the slave part has no branch here and runs the revision of the branch that keeps its books'

foreach ($installation in $installations) {
  Say ''
  Say $installation

  $pin = Read-MapValue $installation 'release'
  if (-not $pin) {
    Say '  release: none'
    Say '  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release-platform.sh / release-platform.ps1 beside this file writes that line.'
    continue
  }
  Say "  release: $pin"

  git rev-parse --verify --quiet "$pin^{commit}" *> $null
  if ($LASTEXITCODE -ne 0) {
    Say '  unresolved: nothing here resolves that to a commit, so it names a state this repository does not carry: it was never pushed, or it has been deleted'
    continue
  }

  $total = (git rev-list --count "$pin..origin/master" | Select-Object -First 1)
  $stamped = (git rev-list --count "$pin..origin/master" -- $stampedTrees | Select-Object -First 1)
  if ("$total" -eq '0') {
    Say '  level: origin/master carries nothing this release does not'
    continue
  }
  Say "  behind: $total commits on origin/master since that release, $stamped of them under $stampedTreesSaid"
  foreach ($changed in @(git diff --name-only $pin origin/master -- $stampedTrees)) {
    if ($changed) { Say "  stamped: $changed" }
  }
}
