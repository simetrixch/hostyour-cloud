# =============================================================================
# release-platform.ps1 — cut a release of the platform tree and put ONE
# installation on it. Bash twin: release-platform.sh (same folder), which does
# the same in the same order and prints the same lines. lifecycle/test.sh measures
# that.
# =============================================================================
#
# USAGE (run from anywhere inside a hostyour-cloud checkout)
#   pwsh ./lifecycle/release-platform.ps1 <x.y.z> <stable|beta|alpha> <fqdn>
#
# THE THREE INPUTS
#   version  — x.y.z, no leading zeros. EVERY RELEASE IS A PATCH BUMP: the first
#              two numbers say what the product is and are the owner's to move.
#   channel  — the maturity CEILING of the release: alpha may reach a dev
#              installation only, beta dev and test, stable any. The channel is
#              part of the release tag; the installation is not.
#   fqdn     — WHICH INSTALLATION this run puts the release on. It is the domain
#              of the cluster, the name of its install branch, and the name of
#              its map under clusters/active. One release, one tree, any number
#              of installations: run this again with another fqdn and the tag is
#              REUSED rather than cut a second time.
#
# WHAT A PLATFORM RELEASE IS, AND WHAT IT IS NOT. This repository builds nothing
# — no image, no archive, no package. THE TREE AT THE TAG IS THE RELEASE. So
# there is no pipeline to start and nothing to wait for, and this script needs
# nothing but git: no gh, no token, no network service. What it waits on instead
# is the one thing a machine actually needs — that the tag is on the REMOTE,
# because a pin naming a tag the machine cannot fetch is a pin that fails three
# systems away, in a message about a git ref rather than about a release.
#
# WHY THE PIN IS WRITTEN HERE. The line `release: <tag>` in
# clusters/active/<fqdn>.yaml is what says which state an installation stands on,
# and the write belongs where the credential already is: this workstation is
# logged in to this repository, which is both the tree being released and the
# tree carrying the pin. Nothing new has to be created, held or rotated.
#
# NOTHING IS CREATED BEFORE THE TARGET IS KNOWN GOOD. The install branch is
# cloned, its map read and the ceiling checked BEFORE a tag is minted, so a
# mistyped domain or a channel that may not reach that stage costs nothing and
# leaves no tag behind naming a release nobody meant to cut.
#
# WHAT THIS DOES NOT DO. It does not stamp anything, and it touches no file under
# clusters/argocd or clusters/bootstrap. Those files carry one installation's own
# domain, name, stage and role where this tree carries markers, and writing them
# is the branch programs' act in the catalogue repository — re-run by
# regenerate-branch, which regenerate-install-branch.ps1 beside this file performs
# on the machine, and which is the act a person performs after this one. A second
# implementation of that stamping beside them would disagree with them the first
# time either was corrected.
#
# THE ORDER IS PIN, THEN REGENERATE, and they are two acts on purpose. Between
# them somebody can read what the pin now says and stop. This one ends by naming
# the second, which reads the ref off the pin this one writes rather than being
# told it a second time.
#
# THE TAG GOES ON origin/master AND NEVER ON THE LOCAL BRANCH. What is released
# is what the remote publishes; a local master may carry commits nobody else has,
# and a tag on one of those names a tree no installation could ever fetch. Where
# the local master is ahead, this says how many commits are being left out.
# =============================================================================

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string] $Version = '',
  [Parameter(Position = 1)][string] $Channel = '',
  [Parameter(Position = 2)][string] $Fqdn = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# EVERY git CALL BELOW IS READ BY ITS EXIT CODE, and several of them are probes
# that are MEANT to fail. Newer PowerShell turns a non-zero native exit into a
# terminating error under the preference above, which would end this run on the
# first probe; stated here so the behaviour is the same on every version.
$PSNativeCommandUseErrorActionPreference = $false

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
  [Console]::Error.Write("release: $Because`n")
  exit $Code
}
function Say([string] $Line) { [Console]::Out.Write("$Line`n") }

# THE VALUE OF ONE TOP-LEVEL KEY, read the way the catalogue's own step writes
# it: a line beginning at column one with the key and a colon. A key of the same
# name indented under `global:` is a different key and is deliberately not seen.
# Surrounding quotes are the notation's and are taken off.
function Read-FileValue([string] $Path, [string] $Key) {
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
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

# THE LINE IS REPLACED WHERE IT STANDS AND APPENDED ONLY WHERE THE FILE HAS NONE,
# which is the grammar the catalogue's writing step uses. Appending regardless
# would leave two lines for one key, and whatever reads them takes one.
function Write-FileValue([string] $Path, [string] $Key, [string] $Value) {
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) { $lines.Add($line) }
  $found = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].StartsWith("${Key}:")) {
      $lines[$i] = "${Key}: $Value"
      $found = $true
      break
    }
  }
  if (-not $found) { $lines.Add("${Key}: $Value") }
  [System.IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

if (-not $Version -or -not $Channel -or -not $Fqdn) {
  Stop-Here 'usage: lifecycle/release-platform.ps1 <x.y.z> <stable|beta|alpha> <fqdn>' 64
}
if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
  Stop-Here "version must be x.y.z with no leading zeros (got '$Version')" 64
}
$admits = ''
switch ($Channel) {
  'alpha' { $admits = 'dev' }
  'beta' { $admits = 'dev test' }
  'stable' { $admits = 'dev test prod' }
  default { Stop-Here "channel must be stable, beta or alpha (got '$Channel')" 64 }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Stop-Here 'git is not on this path, and a platform release is nothing but git'
}
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'not inside a git repository. Run this from a checkout of the platform tree' 66
}

# THE REMOTE VIEW FIRST, for two reasons. Mint-once has to see the tags somebody
# else pushed, or a second workstation mints a second tag for the same version
# and channel instead of reusing the one that exists. And the tag below is put on
# origin/master, which a checkout that has not fetched resolves to whatever it
# last saw.
git fetch --quiet --tags origin *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'origin could not be fetched, so neither the tag nor the pin would be about what the remote carries' 69
}
git rev-parse --verify --quiet origin/master *> $null
if ($LASTEXITCODE -ne 0) {
  Stop-Here 'origin carries no master, and master is what a platform release is cut from' 69
}

# THE TREE IS CLONED FRESH FOR THE WRITE. The pin stands on an install branch,
# and checking one out in the tree somebody is standing in is a thing a release
# has no business doing.
$url = (git remote get-url origin | Select-Object -First 1)
if (-not $url) { Stop-Here 'this checkout has no origin to clone, so there is no branch to pin' 69 }
$work = (New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))).FullName
try {
  git clone --quiet --single-branch --branch $Fqdn $url $work
  if ($LASTEXITCODE -ne 0) {
    Stop-Here "origin has no branch $Fqdn. An installation is pinned on its own install branch, and there is none of that name" 66
  }

  $map = "clusters/active/$Fqdn.yaml"
  $mapPath = Join-Path $work $map
  if (-not (Test-Path -LiteralPath $mapPath)) {
    Stop-Here "branch $Fqdn carries no $map. That map is where an installation records what it is, and the pin is one line in it" 66
  }

  # THE CEILING IS ENFORCED HERE, and this is the only place that can. The
  # manager's release client only warns because a pipeline refuses afterwards; a
  # platform release has no pipeline, so a refusal that did not happen here would
  # not happen at all, and a prod installation would stand on an alpha tree.
  $stage = Read-FileValue $mapPath 'stage'
  if (-not $stage) {
    Stop-Here "$map on branch $Fqdn states no stage, so the channel ceiling cannot be checked, and a check that cannot measure must not report a pass" 65
  }
  if ($admits.Split(' ') -notcontains $stage) {
    Stop-Here "$Fqdn is stage $stage and channel $Channel admits only: $admits. Nothing else would refuse this, so this does." 65
  }

  # THE STAGE IS NOT A DOMAIN LABEL, and this is the one place that can still say so
  # before a tree reaches a machine. An API group is a reverse domain name fixed by
  # whoever wrote the software - triggers.tekton.dev, cert-manager.io, argoproj.io -
  # and no part of it varies with an installation's stage. Written as the stage
  # placeholder it renders correctly on a dev installation by accident, because the
  # stamp puts "dev" back, and names a group no cluster registers on every other
  # stage. Measured on a real machine: the cicd project permits
  # triggers.tekton.prod, ArgoCD cannot manage the ClusterInterceptors, and the
  # tekton application stands OutOfSync for ever with the image-builder behind it.
  #
  # READ OFF origin/master, not the working tree: that is the tree this release
  # publishes, and a correction sitting uncommitted beside it would let a release
  # claim a fix nobody can fetch.
  $placed = (& git grep -nE '^[[:space:]]*(-[[:space:]]+)?(group|apiVersion):[[:space:]]*[^[:space:]]*__STAGE__' origin/master -- clusters/argocd clusters/bootstrap 2>$null)
  if ($LASTEXITCODE -gt 1) { $placed = @() }
  $placedLine = (($placed | ForEach-Object { "$_;" }) -join '')
  if ($placedLine) {
    Stop-Here "a stage placeholder stands where an API group or an apiVersion belongs, and neither ever varies with a stage: $placedLine correct it on master and release again" 65
  }
  # MINT-ONCE: exactly one release tag per version and channel. A later run for
  # the same pair reuses it, which is how one release reaches a further
  # installation without a second tree ever being cut.
  $prefix = "$Version-$Channel-"
  $existing = @(git tag -l "$prefix*" | Sort-Object)

  # A TAG THAT NEVER REACHED ORIGIN AND NAMES ANOTHER COMMIT IS RESIDUE, and reusing
  # it aims every retry at the commit a refused push left behind. The tag is minted
  # before it is pushed, so a push the pre-push hook refuses leaves it standing here
  # and nowhere else; the next run finds it, reuses it, and is refused again — for
  # the same reason, printed as if it were about the new attempt. Measured on this
  # workstation: three runs of 0.7.8 refused in a row, cleared only by deleting the
  # tag by hand.
  #
  # A TAG THAT IS ON ORIGIN IS LEFT EXACTLY AS IT STANDS, whatever commit it names.
  # That is mint-once itself: one release per version and channel, reused so a
  # release already cut reaches a second installation without a second tree.
  if ($existing.Count -gt 0) {
    $candidate = $existing[-1]
    git ls-remote --exit-code --tags origin "refs/tags/$candidate" *> $null
    $onOrigin = ($LASTEXITCODE -eq 0)
    $candidateSha = (git rev-parse --verify --quiet "$candidate^{commit}" | Select-Object -First 1)
    $releasedSha = (git rev-parse --verify origin/master | Select-Object -First 1)
    if (-not $onOrigin -and "$candidateSha" -ne "$releasedSha") {
      $candidateShort = (git rev-parse --short=7 "$candidate^{commit}" | Select-Object -First 1)
      Say "release: $candidate stands on this workstation only and names $candidateShort, not the commit this release is cut from. A run whose push was refused left it behind; it is dropped and cut again."
      git tag -d $candidate *> $null
      if ($LASTEXITCODE -ne 0) {
        Stop-Here "the leftover tag $candidate could not be dropped, and reusing it would put this release on a commit nobody is releasing" 69
      }
      $existing = @()
    }
  }

  if ($existing.Count -gt 0) {
    $tag = $existing[-1]
    Say "release: reusing $tag. One release per version and channel, so putting it on $Fqdn cuts nothing new"
  }
  else {
    $ts14 = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $tag = "$Version-$Channel-$ts14"
    git tag -a $tag -m 'the platform, cut as a release' origin/master
    if ($LASTEXITCODE -ne 0) { Stop-Here "the tag $tag could not be put on origin/master" }
    $sha7 = (git rev-parse --short=7 "$tag^{commit}" | Select-Object -First 1)
    Say "release: minted $tag on origin/master (commit $sha7)"
    Say 'release: this tree builds nothing. The tree at the tag IS the release, so there is no image and nothing further to wait for'
  }

  git rev-parse --verify --quiet master *> $null
  if ($LASTEXITCODE -eq 0) {
    $ahead = (git rev-list --count origin/master..master | Select-Object -First 1)
    if ("$ahead" -ne '0') {
      Say "release: your local master is $ahead commits ahead of origin/master, and those commits are not in this release"
    }
  }

  # NOTHING IS PINNED BEFORE IT EXISTS. The push is what makes the tag fetchable;
  # the read-back is what proves it, and it is asked of the REMOTE rather than of
  # this checkout, which already has the tag whatever the remote thinks.
  git push --quiet origin "refs/tags/$tag"
  if ($LASTEXITCODE -ne 0) {
    Stop-Here "the tag $tag could not be pushed to origin, so it exists on this machine only and nothing was pinned" 74
  }
  $onRemote = @(git ls-remote --tags origin "refs/tags/$tag")
  if ($onRemote.Count -eq 0) {
    Stop-Here "origin does not carry $tag after the push, so a machine could not fetch it and nothing was pinned" 74
  }
  Say 'release: the tag stands on the remote, so a machine that fetches origin can resolve it'

  $held = Read-FileValue $mapPath 'release'
  if ($held -eq $tag) {
    Say "release: $map already records $tag, so it is left as it stands"
  }
  else {
    Write-FileValue $mapPath 'release' $tag
    git -C $work add -- $map
    if ($LASTEXITCODE -ne 0) { Stop-Here "the pin could not be staged in $map" }
    git -C $work commit --quiet -m "Pin $Fqdn to $tag" -m 'Written by the release of the platform tree, once the tag stood on the remote.'
    if ($LASTEXITCODE -ne 0) { Stop-Here "the pin of $Fqdn to $tag could not be committed" }
    git -C $work push --quiet origin $Fqdn
    if ($LASTEXITCODE -ne 0) {
      Stop-Here "the pin of $Fqdn to $tag could not be pushed, so it is a pin only this machine believes" 74
    }
    Say "release: pinned $Fqdn to $tag in $map"
  }
}
finally {
  Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Say "release: $Fqdn is pinned. It STANDS on that release once its branch is regenerated, which is the second act and is performed from a checkout of the platform tree:"
Say "release:     bash lifecycle/regenerate-install-branch.sh $Fqdn"
Say "release:     pwsh ./lifecycle/regenerate-install-branch.ps1 $Fqdn"
Say "release: that script reads $tag off the pin this run just wrote, so the ref is stated once and a regeneration cannot be aimed at a state the map does not record."
