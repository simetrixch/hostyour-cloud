# ===========================================================================
# migrate-install-branches.ps1 — correct branch-born facts across every install
# branch. Bash twin: migrate-install-branches.sh (same folder), which walks the
# same refs in the same order and prints the same lines. lifecycle/test.sh
# measures that.
#
# An install branch carries three kinds of bytes, and two of them already have
# a path. What the product tree owns unstamped — charts, values, inventories,
# pins — reaches a branch by a merge. What it owns stamped — the files under
# clusters/argocd and clusters/bootstrap, where the installation's own domain,
# name, stage and role stand where the trunk carries markers — reaches it by a
# regeneration. The third kind is born on the branch and exists nowhere else:
# the cluster maps under clusters/active/, configs/config.<stage>, the files
# under installation/. A merge cannot reach it because the trunk does not
# carry it, and a regeneration is exactly what preserves it. This script is
# the path for that third kind, and for nothing else: a migration that copies
# product-tree content is a second delivery path that drifts from the first,
# and a migration that moves an image pin is a release wearing the wrong hat.
#
# USAGE (from the repo root of a checkout, on a person's machine — nothing
# runs this automatically, the same way release-platform.ps1 beside it is
# a person's own act)
#
#   pwsh ./lifecycle/migrate-install-branches.ps1          report what every branch would get; push nothing
#   pwsh ./lifecycle/migrate-install-branches.ps1 -Write   the same work, plus the push
#
# THE PUSH IS ASKED FOR AS -Write AND THE TWIN ASKS FOR --write, which is the one
# place the two spellings are spelled apart. PowerShell binds an argument
# beginning with a dash as a parameter of its own and refuses `--write` before a
# line of this file runs, so the twin's spelling is not available here; what the
# two do with it is identical, and every line either prints is the same.
#
# WHAT A RUN DOES
#   1. Clones this repository's origin fresh into a temporary directory, so
#      nothing here depends on the checkout it was started from and nothing
#      here can touch one.
#   2. Walks every branch of the remote except the trunk. A branch is an
#      install branch when it carries its own cluster map at
#      clusters/active/<branch>.yaml; a ref without one is named in the
#      report and skipped, with the path it was looked for under.
#   3. On each install branch, runs every numbered migration the branch has
#      not recorded yet, lowest number first. The scripts run FROM THIS
#      CHECKOUT, never from the walked branch — every branch gets the same
#      version of a migration, the way a database gets its migrations from
#      the codebase and only records which ones it has had.
#   4. Appends each migration that ran to installation/migrations ON THE
#      BRANCH, in the same commit as its changes. The branch keeps its own
#      record because the branch is the only carrier every machine reads the
#      same way — a list kept on a machine knows only the runs that machine
#      happened to perform.
#   5. Reports, per branch, what it did, what it skipped and why. Without
#      --write the commits are built in the throwaway clone and discarded
#      with it; the push is the only thing --write adds, so the report of a
#      dry run is a measurement of the real work and not a prediction.
#
# WHAT A MIGRATION IS
#   lifecycle/migrations/NNNN-<what-it-does>.sh — four digits, unique, applied once per
#   branch, in numeric order. ONE script per migration, never one per kind of
#   branch: whether a branch keeps the books is a fact recorded in its own
#   map (role, booksCluster), not a category it belongs to, and a machine may
#   carry both parts of a role at once. The script is called with two
#   arguments — the directory of a checkout standing on the branch, and the
#   branch name — reads what the branch IS from the branch's own files, does
#   what there is to do or nothing, and prints ONE line saying which. It
#   edits BY LINE, never by parsing YAML and writing it back: these files
#   carry comments and a form a round-trip destroys. A non-zero exit is a
#   failure — nothing is recorded, later migrations do not run on that
#   branch, and the run ends red.
#
# A MIGRATION IS A SHELL SCRIPT BY DECLARATION, so this spelling needs a bash
# to run one with. The twin IS a bash and cannot want for it, which is the one
# refusal below that exists on this side alone.
#
# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its
# output in whatever code page the console carries -- so a dash from outside
# ASCII arrives there as a different byte and the pair quietly stops agreeing.
# The comments in these files are read by people and may say what they like.
# ===========================================================================

[CmdletBinding()]
param(
  [switch] $Write,
  [Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# EVERY git CALL BELOW IS READ BY ITS EXIT CODE, and several of them are probes
# that are MEANT to fail. Newer PowerShell turns a non-zero native exit into a
# terminating error under the preference above, which would end this run on the
# first probe; stated here so the behaviour is the same on every version.
$PSNativeCommandUseErrorActionPreference = $false

# AND EVERY LINE ENDS IN ONE BYTE. Write-Host and WriteLine end a line with what
# the running system calls a newline, which on Windows is two bytes and on Linux
# one, so the same script would print different bytes on two machines and the
# twin could never be held to matching it. The newline is written out here
# instead, and a carriage return never enters the output at all.
function Say([string] $Line) { [Console]::Out.Write("$Line`n") }
function Complain([string] $Line) { [Console]::Error.Write("$Line`n") }
function Stop-Here([string] $Because) {
  Complain "migrate: $Because"
  exit 1
}

$record = 'installation/migrations'

if ($Rest.Count -gt 0) {
  Stop-Here "unknown argument '$($Rest[0])' - usage: pwsh ./lifecycle/migrate-install-branches.ps1 [-Write]"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Stop-Here 'git is not on this path, and the whole run is git'
}
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
  Stop-Here 'bash is not on this path, and a migration is a shell script'
}

# READ WITHOUT `Select-Object -First 1`, and every git call below is read the same
# way. That filter stops a pipeline as soon as it has its one object, and a native
# command whose pipeline was stopped never records an exit code at all - so the very
# next line asks for $LASTEXITCODE and is told it has not been set.
$said = @(git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or $said.Count -eq 0) {
  Stop-Here 'not inside a git repository - run this from a checkout of the platform tree'
}
$root = $said[0]
if (-not (Test-Path -LiteralPath (Join-Path $root 'lifecycle/migrate-install-branches.sh'))) {
  Stop-Here 'this repository has no lifecycle/migrate-install-branches.sh at its root, so it is not the platform tree'
}
$said = @(git -C $root remote get-url origin 2>$null)
if ($LASTEXITCODE -ne 0 -or $said.Count -eq 0) {
  Stop-Here "this checkout has no remote 'origin', so there are no install branches to walk"
}
$originUrl = $said[0]

# ORDERED BY BYTE AND NOT BY CULTURE. The twin sorts under LC_ALL=C, and a
# culture-aware comparison puts a punctuated name in a different place — so the
# two would walk the same refs in a different order and report them apart.
function Sort-ByByte([string[]] $Of) {
  $copy = [string[]]::new($Of.Count)
  [System.Array]::Copy($Of, $copy, $Of.Count)
  [System.Array]::Sort($copy, [System.StringComparer]::Ordinal)
  return $copy
}

# The migrations this checkout carries, in the order their numbers state. Two
# scripts sharing a number would apply in an order the numbers do not state, so
# that is refused before any branch is read.
$migrations = @()
$migrationsDir = Join-Path $root 'lifecycle/migrations'
if (Test-Path -LiteralPath $migrationsDir) {
  $migrations = @(Sort-ByByte @(Get-ChildItem -LiteralPath $migrationsDir -File |
    Where-Object { $_.Name -match '^[0-9]{4}-.*\.sh$' } |
    ForEach-Object { $_.Name }))
}
if ($migrations.Count -gt 0) {
  $dup = @($migrations | ForEach-Object { $_.Substring(0, 4) } | Group-Object |
    Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  $dup = @(Sort-ByByte $dup)
  if ($dup.Count -gt 0) {
    Stop-Here "two migrations share the number $($dup[0]) - renumber one, the number is the order"
  }
}

# A write run applies only migrations that are committed. An uncommitted one
# would change live installations and then exist nowhere anybody else can
# read — the branch would record a name this repository never carried.
if ($Write) {
  $dirty = @(git -C $root status --porcelain -- lifecycle/migrations | Where-Object { $_ })
  if ($dirty.Count -gt 0) {
    Stop-Here 'lifecycle/migrations/ carries uncommitted changes - commit them first, or run without --write'
  }
  Say 'migrate: a WRITE run - what a migration changes is committed and pushed to the install branches'
}
else {
  Say 'migrate: a report run - the commits are built in a throwaway clone and discarded; nothing is pushed without --write'
}

# FORWARD SLASHES, because this path is handed to a MIGRATION as its first
# argument and a migration is a shell script: a backslash is an escape to the
# shell that runs it, so a Windows path written the Windows way arrives there as
# a name with the separators eaten.
$tree = ((New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))).FullName -replace '\\', '/')
try {
  git clone --quiet $originUrl $tree
  if ($LASTEXITCODE -ne 0) {
    Stop-Here "the platform tree at $originUrl could not be cloned - nothing was read"
  }

  $said = @(git -C $tree symbolic-ref --short refs/remotes/origin/HEAD)
  if ($LASTEXITCODE -ne 0 -or $said.Count -eq 0) {
    Stop-Here "the clone of $originUrl states no trunk, and the trunk is the one ref this walk does not walk"
  }
  $trunk = $said[0]
  if ($trunk.StartsWith('origin/')) { $trunk = $trunk.Substring('origin/'.Length) }

  $refs = @(Sort-ByByte @(git -C $tree for-each-ref '--format=%(refname:strip=3)' refs/remotes/origin |
    Where-Object { $_ -and $_ -ne 'HEAD' }))

  $report = [System.Collections.Generic.List[string]]::new()
  $walked = 0
  $skipped = 0
  $red = 0

  foreach ($b in $refs) {
    if ($b -eq $trunk) { continue }

    $map = "clusters/active/$b.yaml"
    $mapText = @(git -C $tree show "origin/${b}:${map}" 2>$null)
    if ($LASTEXITCODE -ne 0) {
      $report.Add("$b - skipped: it carries no $map, so it is not an install branch")
      $skipped++
      continue
    }
    $walked++

    # What the branch IS, read from its own map — reported so a clean answer
    # can be seen to come from looking, not from failing to look.
    $roleSaid = ''
    foreach ($line in $mapText) {
      if ($line -match '^role:[ \t]*(.*)$') { $roleSaid = $Matches[1]; break }
    }
    $booksSaid = ''
    foreach ($line in $mapText) {
      if ($line -match '^booksCluster:[ \t]*(.*)$') { $booksSaid = $Matches[1]; break }
    }
    if (-not $roleSaid) { $roleSaid = '<none>' }
    if (-not $booksSaid) { $booksSaid = '<none>' }
    $report.Add("$b - an install branch; its map states role '$roleSaid' and booksCluster '$booksSaid'")

    $recorded = @(git -C $tree show "origin/${b}:${record}" 2>$null)
    if ($LASTEXITCODE -ne 0) { $recorded = @() }

    # A record line this checkout has no script for means migrations ran from a
    # newer trunk than the one standing here. The branch is right and this
    # checkout is behind — said out loud rather than read as a stale record.
    foreach ($line in $recorded) {
      if ($line -notmatch '^[0-9]{4}-') { continue }
      $known = $false
      foreach ($m in $migrations) {
        if ($m.Substring(0, 4) -eq $line.Substring(0, 4)) { $known = $true; break }
      }
      if (-not $known) {
        $report.Add("    its $record records $line, which this checkout does not carry - the checkout is behind what has already run")
      }
    }

    if ($migrations.Count -eq 0) {
      $report.Add('    this checkout carries no migrations, so there was nothing to apply')
      continue
    }

    $pending = @($migrations | Where-Object {
      $number = $_.Substring(0, 4)
      -not (@($recorded | Where-Object { $_.StartsWith("$number-") }).Count -gt 0)
    })
    if ($pending.Count -eq 0) {
      $report.Add("    every migration of this checkout is recorded in $record - nothing pending")
      continue
    }

    # Stand the throwaway clone on the branch, clean of whatever a failed
    # migration may have left behind on the branch before it.
    git -C $tree reset --quiet --hard
    git -C $tree clean -qfd
    git -C $tree checkout --quiet $b
    git -C $tree reset --quiet --hard "origin/$b"

    foreach ($m in $pending) {
      # WHAT THE MIGRATION SAID, both streams, with the trailing newline off —
      # the twin reads it through a command substitution, which strips it.
      $out = (& bash (Join-Path $root "lifecycle/migrations/$m") $tree $b 2>&1 | Out-String)
      $ran = $LASTEXITCODE
      $out = ($out -replace "`r", '').TrimEnd("`n")
      if ($ran -eq 0) {
        $changed = @(git -C $tree status --porcelain | Where-Object { $_ })
        New-Item -ItemType Directory -Force -Path (Join-Path $tree 'installation') | Out-Null
        $recordPath = Join-Path $tree $record
        if (-not (Test-Path -LiteralPath $recordPath)) {
          $header = @(
            '# The migrations this branch has had, one per line, appended by lifecycle/migrate-install-branches.sh.'
            '# The branch keeps this record itself: it is the one carrier every machine of the'
            '# installation reads the same way, where a list kept on a machine knows only the runs'
            '# that machine happened to perform.'
          )
          [System.IO.File]::WriteAllText($recordPath, (($header -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
        }
        [System.IO.File]::AppendAllText($recordPath, "$m`n", [System.Text.UTF8Encoding]::new($false))
        # The clone was reset hard before the first migration and committed
        # after each one, so everything unstaged here is what this one
        # migration just wrote — staging all of it is staging exactly its work.
        git -C $tree add -A -- .
        $named = $m -replace '\.sh$', ''
        if ($changed.Count -gt 0) {
          git -C $tree commit --quiet -m "Apply migration $named" -m $out
          $report.Add("    ${m}: $out")
        }
        else {
          git -C $tree commit --quiet -m "Record migration $named as applied without effect" -m $out
          $report.Add("    ${m}: nothing to do - $out (recorded as applied)")
        }
      }
      else {
        $report.Add("    ${m}: FAILED - $out")
        $report.Add("    the remaining migrations did not run on this branch, and nothing of $m was recorded")
        $red = 1
        break
      }
    }

    $counted = @(git -C $tree rev-list --count "origin/$b..$b")
    $ahead = [int]$counted[0]
    if ($ahead -gt 0) {
      if ($Write) {
        git -C $tree push --quiet origin $b
        if ($LASTEXITCODE -eq 0) {
          $report.Add("    pushed $ahead commit(s) to origin/$b")
        }
        else {
          $report.Add("    FAILED - the $ahead commit(s) could not be pushed to origin/$b")
          $red = 1
        }
      }
      else {
        $report.Add("    $ahead commit(s) stand ready in a throwaway clone and were NOT pushed - run with --write to push them")
      }
    }
  }
}
finally {
  Remove-Item -Recurse -Force -LiteralPath $tree -ErrorAction SilentlyContinue
}

Say "migrate: the report - every ref of $originUrl, and what happened on it"
foreach ($line in $report) {
  Say "migrate:   $line"
}
Say "migrate: walked $walked install branch(es) and skipped $skipped other ref(s), each named above with why; the trunk $trunk is not walked - what the trunk needs is a commit on the trunk"
if ($migrations.Count -eq 0) {
  Say 'migrate: this checkout carries no migrations, so the walk above states only what each branch is'
}

if ($red -eq 1) {
  Complain 'migrate: the run is RED - a FAILED line above names the branch and the migration'
  exit 1
}
if ($Write) {
  Say 'migrate: OK - every pending migration ran, was recorded on its branch, and was pushed'
}
else {
  Say 'migrate: OK - every install branch was read; nothing was pushed'
}
