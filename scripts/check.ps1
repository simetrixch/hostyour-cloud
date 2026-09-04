#!/usr/bin/env pwsh
# Everything this repository can be held to on one machine, before anything leaves it.
#
# Three checks, in this order, and the run stops at the first red one:
#
#   1. every chart under clusters/inventories, clusters/units and clusters/slaves renders
#   2. bash lifecycle/test.sh — the delivery programs against their fixtures
#   3. gitleaks over the files git would let you commit
#
# THE ORDER IS THE COST. The charts are the thing that is edited daily and they render in
# seconds; the lifecycle test builds git fixtures and drives both spellings of five programs,
# which is a minute; the credential scan is under a second and stands last because a leak is
# a stop-everything finding and is worth reading on its own.
#
# A MISSING TOOL IS NAMED AND THE RUN ENDS RED. It is never passed over: a check that did not
# run and a check that passed print differently here, because the two mean opposite things.
#
# scripts/check.sh beside this file runs the same three checks and prints the same lines. The
# two are read against each other by eye, so a line printed here is a line printed there.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# A COMMAND THAT ENDS NON-ZERO IS AN ANSWER HERE, NOT AN ACCIDENT. Seventeen of the charts fail
# their first render on purpose — that is how this check tells a chart needing an installation's
# answers from a chart that is broken — and every step reads $LASTEXITCODE for itself. Where this
# preference is on, a non-zero native command throws instead, the first such render ends the run,
# and the check reports a failure it was in the middle of interpreting. It is set explicitly
# because its default has moved between PowerShell versions.
$PSNativeCommandUseErrorActionPreference = $false

# The lines below carry an em dash, and a console left on the system code page writes it as two
# wrong characters. Both spellings of this check print the same bytes only while this stands.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Stop-Check {
    param([string] $Step)
    Write-Output "check: FAIL — $Step"
    exit 1
}

$root = & git rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) { exit 1 }
Set-Location -LiteralPath $root

# THE BASH THAT SHIPS WITH GIT, AND NOT THE ONE ON THE PATH. On Windows the name `bash` resolves
# to C:\WINDOWS\system32\bash.exe, which is the launcher for the Linux subsystem — another
# machine, with another filesystem and another PATH. lifecycle/test.sh run there ends red on its
# second line, because pwsh is not a command on that PATH and half of what that file measures is
# written in PowerShell. Everything bash in this repository is written for the bash git installs,
# which is also the one git itself runs a hook with, so that is the one this looks for: at its
# fixed place beside git, before falling back to the name. On a machine where the name is the
# only bash there is, the fallback is the right answer.
function Find-Bash {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $shipped = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin/bash.exe'
        if (Test-Path -LiteralPath $shipped) { return $shipped }
    }
    $onPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

# ── The tools ───────────────────────────────────────────────────────────────────────────────
# All of them up front. Each is needed by a later step, and finding the third one missing after
# the first two have run costs a minute for an answer that was knowable at the start.
#
# bash is here because lifecycle/test.sh is a bash program, and this spelling of the check runs
# it rather than owning a second copy of it.
$bash = Find-Bash
$missing = @()
foreach ($tool in 'helm', 'gitleaks') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $missing += $tool }
}
if (-not $bash) { $missing += 'bash' }
if ($missing.Count -gt 0) { Stop-Check "these tools are not on this path: $($missing -join ' ')" }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {

# ── What an installation answers ────────────────────────────────────────────────────────────
# The two stand-in documents are TRACKED FILES, and each is read here rather than written out.
# scripts/check.sh reads the same two. A copy in each spelling of this check would be a second and
# a third place to change a key, and a key that moved in one of them would leave this check green
# while a real install branch failed. Their own comments say what each document is and why the
# charts need it.
$mapFile = Join-Path $root 'scripts/standin/cluster-map.yaml'
$regFile = Join-Path $root 'scripts/standin/registration.yaml'
foreach ($standin in $mapFile, $regFile) {
    if (-not (Test-Path -LiteralPath $standin)) {
        Stop-Check "$standin is missing, and it is what lets the charts of an installation render here"
    }
}

# ── 1. The charts ───────────────────────────────────────────────────────────────────────────
Write-Output 'check: rendering every chart under clusters/inventories, clusters/units and clusters/slaves, and clusters/argocd.'

$stages = @('dev', 'test', 'prod')
$rendered = 0
$skippedLibrary = @()
$neededStandin = @()
$broken = @()

$chartDirs = @()
foreach ($parent in 'clusters/inventories', 'clusters/units', 'clusters/slaves') {
    if (-not (Test-Path -LiteralPath $parent)) { continue }
    # THE ORDER IS THE SHELL'S, byte by byte and with the trailing slash the glob puts on a
    # directory. That slash decides a real pair here: `observability-agent/` stands before
    # `observability/`, because a hyphen is the lower byte, and it would stand after it under
    # a comparison that sorted by name or by the reader's language. Both spellings of this
    # check print one list of chart names, and a list in two orders is two lists.
    $sorted = [string[]] @(
        Get-ChildItem -LiteralPath $parent -Directory | ForEach-Object { $_.Name + '/' }
    )
    [array]::Sort($sorted, [System.StringComparer]::Ordinal)
    foreach ($entry in $sorted) { $chartDirs += "$parent/$($entry.TrimEnd('/'))" }
}
# clusters/argocd IS A CHART, not a directory of charts, so it is named rather than globbed. It
# renders the seven manifests of clusters/argocd/files from the cluster map, and it is the only
# writer of their markers.
$chartDirs += 'clusters/argocd'

foreach ($chart in $chartDirs) {
    $chartYaml = "$chart/Chart.yaml"
    if (-not (Test-Path -LiteralPath $chartYaml)) { continue }
    $name = Split-Path -Leaf $chart

    # A library chart carries no templates of its own and cannot be rendered alone. It is
    # reached through the application charts that depend on it, which is where a defect in it
    # shows up.
    if (Select-String -LiteralPath $chartYaml -Pattern '^type:\s*library\s*$' -Quiet) {
        $skippedLibrary += $name
        continue
    }

    # The dependencies first, or the render finds an empty charts/ directory and reports a
    # missing template rather than a missing dependency. Both things the build writes — charts/
    # and Chart.lock — are ignored by this repository, so this leaves the working copy clean.
    if (Select-String -LiteralPath $chartYaml -Pattern '^dependencies:' -Quiet) {
        $out = & helm dependency build $chart 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Output $out.TrimEnd()
            Stop-Check "the dependencies of $chart could not be built"
        }
    }

    # The namespace the app declares for itself. A chart holding a PersistentVolumeClaim
    # refuses to render into another namespace — a claim does not follow a release — so
    # rendering into helm's default would report a defect in a chart that has none.
    $namespace = 'check'
    $appYaml = "$chart/app.yaml"
    if (Test-Path -LiteralPath $appYaml) {
        $declared = Select-String -LiteralPath $appYaml -Pattern '^namespace:\s*(\S+)' |
            Select-Object -First 1
        if ($declared) { $namespace = $declared.Matches[0].Groups[1].Value }
    }

    foreach ($stage in $stages) {
        # The valueFiles chain of clusters/argocd/files, in its order: the platform globals, then
        # the chart's own values, then the installation. A chart carries either
        # values-common.yaml or values.yaml, and units carry a size preset instead of a stage
        # file.
        $helmArgs = @('-f', 'clusters/platform/values-common.yaml')
        $stageValues = "clusters/platform/values-$stage.yaml"
        if (Test-Path -LiteralPath $stageValues) { $helmArgs += @('-f', $stageValues) }
        foreach ($values in 'values-common.yaml', 'values.yaml', "values-$stage.yaml", 'values-size-small.yaml') {
            $candidate = "$chart/$values"
            if (Test-Path -LiteralPath $candidate) { $helmArgs += @('-f', $candidate) }
        }

        & helm template $name $chart --namespace $namespace @helmArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $rendered++
            continue
        }

        # It did not render from what the trunk carries. That is the normal case and not yet a
        # finding: the installation's own answers load last in the chain, and the trunk has none.
        $out = & helm template $name $chart --namespace $namespace @helmArgs -f $mapFile -f $regFile 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $rendered++
            if ($neededStandin -notcontains $name) { $neededStandin += $name }
            continue
        }

        # It renders from neither. The chart is named with the stage it failed at and the whole
        # message helm gave, because that message names the template and the value.
        $indented = ($out.TrimEnd() -split "`r?`n" | ForEach-Object { "    $_" }) -join "`n"
        $broken += "  $name at stage ${stage}:`n$indented"
    }
}

if ($skippedLibrary.Count -gt 0) {
    Write-Output "check: library charts, which render only through what depends on them: $($skippedLibrary -join ' ')"
}
if ($neededStandin.Count -gt 0) {
    Write-Output "check: charts that render only with an installation's own answers, which no file of this repository carries: $($neededStandin -join ' ')"
}

if ($broken.Count -gt 0) {
    Write-Output "These charts render from neither the trunk nor a stand-in installation:`n$($broken -join "`n")"
    Stop-Check 'a chart does not render'
}
Write-Output "check: $rendered chart renders green, over stages $($stages -join ' ')."

# ── 2. The delivery programs ────────────────────────────────────────────────────────────────
Write-Output 'check: lifecycle/test.sh — the release, the regeneration, the migration, the report and the slave removal, in both spellings. About a minute.'
& $bash lifecycle/test.sh
if ($LASTEXITCODE -ne 0) { Stop-Check 'lifecycle/test.sh' }

# ── 3. The credentials ──────────────────────────────────────────────────────────────────────
# SCANNED OVER WHAT GIT WOULD LET YOU COMMIT, and that is not the same as this directory. A
# working copy also holds files this repository ignores, and on a machine that has installed
# anything those include lifecycle/config.<machine>.env — one installation's ten credentials,
# which lifecycle/.gitignore exists to keep out. Scanning the directory reports every one of
# them, on every run, about files a push cannot carry; scanning the committable set reports
# what can actually leave.
#
# The set is tracked files plus untracked ones git does not ignore, taken from the working copy
# rather than from HEAD, so an edit that has not been committed yet is read too. .gitleaks.toml
# is tracked and travels with them, which is how its allowlist reaches the scan.
Write-Output 'check: gitleaks over the files git would let you commit.'
$scan = Join-Path $work 'scan'
New-Item -ItemType Directory -Path $scan -Force | Out-Null

# Separated by a zero byte, because a file name may carry anything else — a newline included —
# and a list split on newlines would take one such name for two files and copy neither.
$listed = & git ls-files --cached --others --exclude-standard -z
if ($LASTEXITCODE -ne 0) { Stop-Check 'the committable files could not be collected for the credential scan' }
foreach ($file in (($listed -join '') -split "`0")) {
    if ([string]::IsNullOrEmpty($file)) { continue }
    $destination = Join-Path $scan $file
    $parent = Split-Path -Parent $destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $file -Destination $destination -Force
}

& gitleaks detect --no-git --no-banner --source $scan
if ($LASTEXITCODE -ne 0) { Stop-Check 'gitleaks found a credential' }

Write-Output 'check: OK — every check green'

}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
