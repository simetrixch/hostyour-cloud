#!/usr/bin/env pwsh
# Everything this repository can be held to on one machine, before anything leaves it.
#
# Three checks, in this order, and the run stops at the first red one:
#
#   1. every chart under clusters/inventories, clusters/units and clusters/slaves renders,
#      and no value in what came out still carries a Helm expression
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

# ── What a render must never carry ──────────────────────────────────────────────────────────
# A HELM EXPRESSION THAT SURVIVED THE RENDER REACHES A CLUSTER AS TEXT. helm resolves `{{ ... }}`
# in a TEMPLATE; the same thing standing in a VALUE is resolved only where the chart passes that
# value through `tpl`, and a chart that does not ships the expression spelled out. Alertmanager's
# smtp_smarthost stood in every cluster as the text of an expression, so no alert mail could
# leave one, and every render here was green because nothing read what came out of it.
#
# A BARE `{{` IS NOT THE TEST. Twelve of the twenty-four charts render a value carrying one, in
# five template languages that are not helm's: Alertmanager's own alert.tmpl, Prometheus rule
# annotations (`{{ $labels.pod }}`), ExternalSecret templates (`{{ .secretKey }}`), ArgoCD
# ApplicationSet parameters (`{{ .name }}`) and Alloy's log-level mapping (`{{ .level }}`). Each
# is rendered by the system that reads it, so a refusal on `{{` would be red on all twelve. What
# is refused is an expression naming one of the six objects helm alone defines: .Values,
# .Release, .Chart, .Capabilities, .Files and .Template. Nothing but helm resolves one of those,
# so an expression carrying one is an expression helm was meant to have resolved and did not.
#
# BASE64 IS WHERE IT HID. The Alertmanager configuration reaches the cluster as one key of a
# Secret, so the render carries it encoded and a scan of the render text answers nothing. Every
# value standing alone on its line as base64 is decoded and read as well, and a finding out of one
# is named by the key that carried it rather than by a line of the decoded text.
#
# WHAT IT CANNOT SEE, named rather than counted: it reads line by line, so an expression written
# across two lines is not found, and it decodes a value only where the whole value is one base64
# token on its own line.
#
# EVERY COMPARISON BELOW IS SPELLED CASE-SENSITIVELY, and that is what makes this scan the same scan
# scripts/check.sh runs. PowerShell's `-match`, `-eq`, `-contains` and Select-String all ignore case
# unless told otherwise, while awk's `~`, grep and sed never do. `.values` and `.chart` are ArgoCD
# ApplicationSet generator parameters — clusters/argocd/files/slaves-appset.yaml and
# tenants-appset.yaml carry sixteen of them — and a case-blind matcher reads them as `.Values` and
# `.Chart` and refuses exactly what the paragraph above says must be allowed. Measured: the two
# spellings answered differently on the same commit, 48 findings here against none there.
$script:decodedValues = 0

# One render, already split into lines. Returns the finding records as objects, each carrying the
# `# Source:` line it stood under, the key on its line, and either the expression or a base64
# value still to be decoded. $SourceOf and $KeyOf are set when the lines came OUT of a base64
# value, so a finding is attributed to the value that carried it and nothing recurses.
function Read-RenderLines {
    param([string[]] $Lines, [string] $SourceOf = '', [string] $KeyOf = '')
    $records = @()
    $source = $SourceOf
    foreach ($line in $Lines) {
        # Ordinal, because StartsWith(string) alone compares by CULTURE: a zero-width character in
        # front of the line makes it answer true, where awk's /^# Source: / reads bytes and does not.
        if (-not $SourceOf -and $line.StartsWith('# Source: ', [System.StringComparison]::Ordinal)) { $source = $line.Substring(10); continue }
        $key = '-'
        $named = [regex]::Match($line, '^[ \t]*([A-Za-z0-9._/-]+):')
        if ($named.Success) { $key = $named.Groups[1].Value }
        if ($KeyOf) { $key = $KeyOf }
        $found = ''
        foreach ($expression in [regex]::Matches($line, '\{\{[^{}]*\}\}')) {
            if ($expression.Value -cmatch '\.(Values|Release|Chart|Capabilities|Files|Template)[^A-Za-z0-9_]') {
                $found = $expression.Value
                break
            }
        }
        if ($found) { $records += ,@('expression', $source, $key, $found); continue }
        if (-not $SourceOf) {
            $encoded = [regex]::Match($line, '^[ \t]+[A-Za-z0-9._-]+:[ \t]*"?([A-Za-z0-9+/]{40,}={0,2})"?[ \t]*$')
            if ($encoded.Success) { $records += ,@('base64', $source, $key, $encoded.Groups[1].Value) }
        }
    }
    return ,$records
}

# $Where says where the render came from, $Lines is the render. One string per finding.
function Find-HelmExpression {
    param([string] $Where, [string[]] $Lines)
    $records = Read-RenderLines -Lines $Lines
    foreach ($record in @($records)) {
        if ($record[0] -ne 'base64') { continue }
        $script:decodedValues++
        try { $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($record[3])) }
        catch { continue }
        $records += Read-RenderLines -Lines ($text -split "`r?`n") -SourceOf $record[1] -KeyOf $record[2]
    }
    $findings = @()
    foreach ($record in $records) {
        if ($record[0] -ne 'expression') { continue }
        $findings += "  $Where, $($record[1]), $($record[2]): $($record[3])"
    }
    return ,$findings
}

# ── The counter-probe of that scan ──────────────────────────────────────────────────────────
# THE SCAN IS RUN OVER A PLANTED RENDER BEFORE IT IS RUN OVER A REAL ONE. scripts/counter-probe.yaml
# plants two defects it has to report and three innocents it has to leave alone, and its own header
# says which is which. Without the defects a green run would only mean the scan found nothing,
# which is also what a scan that stopped looking prints. scripts/check.sh reads the same file and
# holds it to the same two lines.
$counterProbe = Join-Path $root 'scripts/counter-probe.yaml'
if (-not (Test-Path -LiteralPath $counterProbe)) {
    Stop-Check "$counterProbe is missing, and it is what shows the scan of step 1 can go red"
}
$probeExpected = @(
    '  scripts/counter-probe.yaml, counter-probe/planted-defect-in-the-clear.yaml, smtp_smarthost: {{ .Values.global.env }}'
    '  scripts/counter-probe.yaml, counter-probe/planted-defect-in-base64.yaml, alertmanager.yaml: {{ .Values.global.domain }}'
)
$probeReported = Find-HelmExpression -Where 'scripts/counter-probe.yaml' -Lines ([System.IO.File]::ReadAllLines($counterProbe))
# -cne, because the verdict of a case-sensitive scan cannot be read by a case-blind comparison: with
# -ne a scan reporting `{{ .values.global.env }}` where the line above expects `{{ .Values.global.env }}`
# is taken for agreement, and the probe goes green over the exact defect it exists to catch.
if (($probeReported -join "`n") -cne ($probeExpected -join "`n")) {
    Write-Output 'The counter-probe plants two defects and three innocents. The scan had to report:'
    Write-Output ($probeExpected -join "`n")
    Write-Output 'and it reported:'
    if ($probeReported.Count -gt 0) { Write-Output ($probeReported -join "`n") } else { Write-Output '  (nothing)' }
    Stop-Check 'the scan for a Helm expression does not report what scripts/counter-probe.yaml plants'
}
Write-Output 'check: the counter-probe reports both planted defects in scripts/counter-probe.yaml and neither planted innocent.'
$script:decodedValues = 0

# ── 1. The charts ───────────────────────────────────────────────────────────────────────────
Write-Output 'check: rendering every chart under clusters/inventories, clusters/units and clusters/slaves, and clusters/argocd.'

$stages = @('dev', 'test', 'prod')
$rendered = 0
$skippedLibrary = @()
$neededStandin = @()
$broken = @()
$expressions = @()

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
    # -CaseSensitive on every Select-String below, because scripts/check.sh reads these three lines
    # with grep and sed, which are. Without it `type: Library` is skipped here and rendered there.
    if (Select-String -LiteralPath $chartYaml -Pattern '^type:\s*library\s*$' -Quiet -CaseSensitive) {
        $skippedLibrary += $name
        continue
    }

    # The dependencies first, or the render finds an empty charts/ directory and reports a
    # missing template rather than a missing dependency. Both things the build writes — charts/
    # and Chart.lock — are ignored by this repository, so this leaves the working copy clean.
    if (Select-String -LiteralPath $chartYaml -Pattern '^dependencies:' -Quiet -CaseSensitive) {
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
        $declared = Select-String -LiteralPath $appYaml -Pattern '^namespace:\s*(\S+)' -CaseSensitive |
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

        $trunkOnly = & helm template $name $chart --namespace $namespace @helmArgs 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $rendered++
            $expressions += Find-HelmExpression -Where "$name at stage $stage" -Lines ($trunkOnly -split "`r?`n")
            continue
        }

        # It did not render from what the trunk carries. That is the normal case and not yet a
        # finding: the installation's own answers load last in the chain, and the trunk has none.
        $out = & helm template $name $chart --namespace $namespace @helmArgs -f $mapFile -f $regFile 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $rendered++
            $expressions += Find-HelmExpression -Where "$name at stage $stage" -Lines ($out -split "`r?`n")
            # -cnotcontains, because scripts/check.sh holds this list with a case pattern over the
            # bytes. A chart directory may differ from another in case alone on a case-sensitive
            # filesystem, and the two spellings print one list or two.
            if ($neededStandin -cnotcontains $name) { $neededStandin += $name }
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

if ($expressions.Count -gt 0) {
    Write-Output "These rendered values still carry a Helm expression, which reaches a cluster as text:`n$($expressions -join "`n")"
    Stop-Check 'a rendered value carries a Helm expression'
}
Write-Output "check: no rendered value carries a Helm expression, over $rendered renders and the $script:decodedValues base64 values in them."

# ── clusters/argocd as ArgoCD is handed it: the cluster map ALONE ────────────────────────────
# THE LOOP ABOVE RENDERS IT WITH THE PLATFORM CHAIN, AND NO CLUSTER EVER DOES. clusters/argocd is
# the one chart of this repository whose whole values chain is a single file:
# clusters/argocd/root-app.yaml:33 and clusters/slaves/slave/templates/root-application.yaml:83
# both name $values/clusters/active/<fqdn>.yaml and nothing else. So `global:` reaches this chart
# from the cluster map or from nowhere, while every other chart is handed
# clusters/platform/values-common.yaml first and can never see the block missing.
#
# THE OLD MAP SHAPE IS DERIVED FROM THE STAND-IN, NOT WRITTEN OUT. A cluster map made before the
# block existed carries its values flat at the top level, which is the stand-in with everything
# from its `global:` line onward cut off. Deriving it means the two shapes cannot drift apart and
# there is no third stand-in document to keep in step.
Write-Output 'check: clusters/argocd from the cluster map alone, the way its root Application is handed it.'
$alone = & helm template argocd-apps clusters/argocd -f $mapFile 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Output $alone.TrimEnd()
    Stop-Check 'clusters/argocd does not render from the cluster map alone, which is the only chain it ever gets'
}

$refusalSaid = 'the cluster map states no global: block'
$flat = @()
foreach ($line in [System.IO.File]::ReadAllLines($mapFile)) {
    # Ordinal and case-sensitive, because scripts/check.sh cuts the same line with awk over bytes.
    if ($line.StartsWith('global:', [System.StringComparison]::Ordinal)) { break }
    $flat += $line
}
$mapWithoutGlobal = Join-Path $work 'map-without-global.yaml'
[System.IO.File]::WriteAllLines($mapWithoutGlobal, $flat)
$refused = & helm template argocd-apps clusters/argocd -f $mapWithoutGlobal 2>&1 | Out-String
if (-not $refused.Contains($refusalSaid, [System.StringComparison]::Ordinal)) {
    Write-Output $refused.TrimEnd()
    Stop-Check 'a cluster map with no global: block is not refused by name — helm stops on a nil pointer that names neither the file nor the block'
}
Write-Output 'check: a cluster map with no global: block is refused by name, not by a nil pointer.'

# ── 2. The delivery programs ────────────────────────────────────────────────────────────────
Write-Output 'check: lifecycle/test.sh — the release, the regeneration, the report and the slave removal, in both spellings. About a minute.'
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
