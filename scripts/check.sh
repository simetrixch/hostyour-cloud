#!/usr/bin/env bash
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
# scripts/check.ps1 beside this file runs the same three checks and prints the same lines.

set -uo pipefail

# THE CHART NAMES ARE PRINTED AS A LIST, AND A LIST IN TWO ORDERS IS TWO LISTS. A glob is sorted
# by the collation of whatever language the shell was started in, and under some of them a hyphen
# is ignored — which puts `observability` before `observability-agent` on one machine and after it
# on the next. Byte order is the one every machine agrees on, and it is the order scripts/check.ps1
# sorts in.
export LC_COLLATE=C

root="$(git rev-parse --show-toplevel)" || exit 1
cd "$root" || exit 1

fail() { echo "check: FAIL — $1"; exit 1; }

# ── The tools ───────────────────────────────────────────────────────────────────────────────
# All of them up front. Each is needed by a later step, and finding the third one missing after
# the first two have run costs a minute for an answer that was knowable at the start.
#
# pwsh is here because lifecycle/test.sh needs it: half of what that file measures is written
# in PowerShell, and it holds the two spellings to printing the same bytes. base64 is here
# because the scan of step 1 decodes every base64 value of a render, and a decoder that is not
# there would leave that half of the scan silently finding nothing.
missing=""
for tool in helm gitleaks pwsh base64; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -n "$missing" ] && fail "these tools are not on this path:$missing"

work="$(mktemp -d)" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT

# ── What an installation answers ────────────────────────────────────────────────────────────
# The two stand-in documents are TRACKED FILES, and each is read here rather than written out.
# scripts/check.ps1 reads the same two. A copy in each spelling of this check would be a second and
# a third place to change a key, and a key that moved in one of them would leave this check green
# while a real install branch failed. Their own comments say what each document is and why the
# charts need it.
cluster_map="$root/scripts/standin/cluster-map.yaml"
registration="$root/scripts/standin/registration.yaml"
for standin in "$cluster_map" "$registration"; do
  [ -f "$standin" ] || fail "$standin is missing, and it is what lets the charts of an installation render here"
done

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
tab="$(printf '\t')"
scan_awk='
function helm_expression(s,   m) {
  while (match(s, /\{\{[^{}]*\}\}/)) {
    m = substr(s, RSTART, RLENGTH)
    if (m ~ /\.(Values|Release|Chart|Capabilities|Files|Template)[^A-Za-z0-9_]/) return m
    s = substr(s, RSTART + RLENGTH)
  }
  return ""
}
/^# Source: / { if (src == "") { source = substr($0, 11); next } }
{
  key = "-"
  if (match($0, /^[ \t]*[A-Za-z0-9._\/-]+:/)) {
    key = substr($0, RSTART, RLENGTH - 1)
    sub(/^[ \t]+/, "", key)
  }
  if (src != "") { source = src }
  if (keyname != "") { key = keyname }
  found = helm_expression($0)
  if (found != "") { print "expression\t" source "\t" key "\t" found; next }
  if (src == "" && match($0, /^[ \t]+[A-Za-z0-9._-]+:[ \t]*"?[A-Za-z0-9+\/]{40,}={0,2}"?[ \t]*$/)) {
    payload = $0
    sub(/^[ \t]+[A-Za-z0-9._-]+:[ \t]*"?/, "", payload)
    sub(/"?[ \t]*$/, "", payload)
    print "base64\t" source "\t" key "\t" payload
  }
}
'

# HOW MANY VALUES scan_render DECODED IS TALLIED IN A FILE AND NOT IN A VARIABLE. Its callers read
# it through `$( )`, which runs it in a subshell, and a count kept in a variable would be thrown
# away with that subshell: the run would end by reporting nought values decoded over a tree full
# of Secrets, which is a check saying it looked where it did not.
: > "$work/decoded.tally"

# $1 says where the render came from, $2 is a file holding it. One line per finding on stdout.
scan_render() {
  : > "$work/records.decoded"
  awk "$scan_awk" "$2" > "$work/records" || fail "the render of $1 could not be read"
  while IFS="$tab" read -r kind src key payload; do
    [ "$kind" = base64 ] || continue
    echo >> "$work/decoded.tally"
    printf '%s' "$payload" | base64 -d 2>/dev/null \
      | awk -v src="$src" -v keyname="$key" "$scan_awk" >> "$work/records.decoded"
  done < "$work/records"
  cat "$work/records" "$work/records.decoded" | while IFS="$tab" read -r kind src key payload; do
    [ "$kind" = expression ] || continue
    printf '  %s, %s, %s: %s\n' "$1" "$src" "$key" "$payload"
  done
}

# $1 says where the render came from, $2 is the render itself. Adds what it finds to $expressions.
collect_expressions() {
  printf '%s\n' "$2" > "$work/render"
  found="$(scan_render "$1" "$work/render")"
  [ -n "$found" ] || return 0
  expressions="$expressions
$found"
}

# ── The counter-probe of that scan ──────────────────────────────────────────────────────────
# THE SCAN IS RUN OVER A PLANTED RENDER BEFORE IT IS RUN OVER A REAL ONE. scripts/counter-probe.yaml
# plants two defects it has to report and three innocents it has to leave alone, and its own header
# says which is which. Without the defects a green run would only mean the scan found nothing,
# which is also what a scan that stopped looking prints. scripts/check.ps1 reads the same file and
# holds it to the same two lines.
counter_probe="$root/scripts/counter-probe.yaml"
[ -f "$counter_probe" ] || fail "$counter_probe is missing, and it is what shows the scan of step 1 can go red"

probe_expected="  scripts/counter-probe.yaml, counter-probe/planted-defect-in-the-clear.yaml, smtp_smarthost: {{ .Values.global.env }}
  scripts/counter-probe.yaml, counter-probe/planted-defect-in-base64.yaml, alertmanager.yaml: {{ .Values.global.domain }}"
probe_reported="$(scan_render 'scripts/counter-probe.yaml' "$counter_probe")"
if [ "$probe_reported" != "$probe_expected" ]; then
  echo "The counter-probe plants two defects and three innocents. The scan had to report:"
  echo "$probe_expected"
  echo "and it reported:"
  echo "${probe_reported:-  (nothing)}"
  fail "the scan for a Helm expression does not report what scripts/counter-probe.yaml plants"
fi
echo "check: the counter-probe reports both planted defects in scripts/counter-probe.yaml and neither planted innocent."
: > "$work/decoded.tally"

# ── 1. The charts ───────────────────────────────────────────────────────────────────────────
echo "check: rendering every chart under clusters/inventories, clusters/units and clusters/slaves, and clusters/argocd."

stages="dev test prod"
rendered=0
skipped_library=""
needed_standin=""
broken=""
expressions=""

# clusters/argocd IS A CHART, not a directory of charts, so it is named rather than globbed. It
# renders the seven manifests of clusters/argocd/files from the cluster map, and it is the only
# writer of their markers.
for chart in clusters/inventories/*/ clusters/units/*/ clusters/slaves/*/ clusters/argocd/; do
  chart="${chart%/}"
  [ -f "$chart/Chart.yaml" ] || continue
  name="$(basename "$chart")"

  # A library chart carries no templates of its own and cannot be rendered alone. It is reached
  # through the application charts that depend on it, which is where a defect in it shows up.
  if grep -qE '^type:[[:space:]]*library[[:space:]]*$' "$chart/Chart.yaml"; then
    skipped_library="$skipped_library $name"
    continue
  fi

  # The dependencies first, or the render finds an empty charts/ directory and reports a missing
  # template rather than a missing dependency. Both directories the build writes — charts/ and
  # Chart.lock — are ignored by this repository, so this leaves the working copy clean.
  if grep -q '^dependencies:' "$chart/Chart.yaml"; then
    out="$(helm dependency build "$chart" 2>&1)" \
      || { echo "$out"; fail "the dependencies of $chart could not be built"; }
  fi

  # The namespace the app declares for itself. A chart holding a PersistentVolumeClaim refuses
  # to render into another namespace — a claim does not follow a release — so rendering into
  # helm's default would report a defect in a chart that has none.
  namespace="$(sed -n 's/^namespace:[[:space:]]*//p' "$chart/app.yaml" 2>/dev/null | head -1)"
  [ -n "$namespace" ] || namespace=check

  for stage in $stages; do
    # The valueFiles chain of clusters/argocd/files, in its order: the platform globals, then the
    # chart's own values, then the installation. A chart carries either values-common.yaml or
    # values.yaml, and units carry a size preset instead of a stage file.
    args=(-f clusters/platform/values-common.yaml)
    [ -f "clusters/platform/values-$stage.yaml" ] && args+=(-f "clusters/platform/values-$stage.yaml")
    for values in values-common.yaml values.yaml "values-$stage.yaml" values-size-small.yaml; do
      [ -f "$chart/$values" ] && args+=(-f "$chart/$values")
    done

    trunk_only="$(helm template "$name" "$chart" --namespace "$namespace" "${args[@]}" 2>&1)"
    if [ $? -eq 0 ]; then
      rendered=$((rendered + 1))
      collect_expressions "$name at stage $stage" "$trunk_only"
      continue
    fi

    # It did not render from what the trunk carries. That is the normal case and not yet a
    # finding: the installation's own answers load last in the chain, and the trunk has none.
    out="$(helm template "$name" "$chart" --namespace "$namespace" \
      "${args[@]}" -f "$cluster_map" -f "$registration" 2>&1)"
    if [ $? -eq 0 ]; then
      rendered=$((rendered + 1))
      collect_expressions "$name at stage $stage" "$out"
      case " $needed_standin " in
        *" $name "*) ;;
        *) needed_standin="$needed_standin $name" ;;
      esac
      continue
    fi

    # It renders from neither. The chart is named with the stage it failed at and the whole
    # message helm gave, because that message names the template and the value.
    broken="$broken
  $name at stage $stage:
$(printf '%s' "$out" | sed 's/^/    /')"
  done
done

[ -n "$skipped_library" ] && echo "check: library charts, which render only through what depends on them:$skipped_library"
[ -n "$needed_standin" ] && echo "check: charts that render only with an installation's own answers, which no file of this repository carries:$needed_standin"

if [ -n "$broken" ]; then
  echo "These charts render from neither the trunk nor a stand-in installation:$broken"
  fail "a chart does not render"
fi
echo "check: $rendered chart renders green, over stages $stages."

if [ -n "$expressions" ]; then
  echo "These rendered values still carry a Helm expression, which reaches a cluster as text:$expressions"
  fail "a rendered value carries a Helm expression"
fi
decoded="$(wc -l < "$work/decoded.tally" | tr -d ' ')"
echo "check: no rendered value carries a Helm expression, over $rendered renders and the $decoded base64 values in them."

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
echo "check: clusters/argocd from the cluster map alone, the way its root Application is handed it."
if ! helm template argocd-apps clusters/argocd -f "$cluster_map" > "$work/argocd-alone" 2>&1; then
  cat "$work/argocd-alone"
  fail "clusters/argocd does not render from the cluster map alone, which is the only chain it ever gets"
fi

refusal_said='the cluster map states no global: block'
awk '/^global:/ { exit } { print }' "$cluster_map" > "$work/map-without-global"
refused="$(helm template argocd-apps clusters/argocd -f "$work/map-without-global" 2>&1)"
case "$refused" in
  *"$refusal_said"*) ;;
  *)
    echo "$refused"
    fail "a cluster map with no global: block is not refused by name — helm stops on a nil pointer that names neither the file nor the block"
    ;;
esac
echo "check: a cluster map with no global: block is refused by name, not by a nil pointer."

# ── What clusters/bootstrap must never carry ─────────────────────────────────────────────────
# NOTHING STAMPS THAT TREE, AND A PLACEHOLDER LEFT IN IT TRAVELS AS TEXT. The seven files under
# clusters/bootstrap that carry one installation's own domain and short name are TEMPLATES: the
# branch program renders each .tpl onto the install branch beside itself, filling <fqdn>,
# <cluster-name> and <books-name>. No stamping row reaches the tree any more, and a row whose
# literal is gone reports itself satisfied rather than refusing, so a placeholder written here
# afterwards would reach every machine spelled out, with no run saying a word.
#
# STATED OVER THE TREE AND NOT OVER A LIST OF FILES, so it holds for a file nobody has written yet.
placeholders="$(git grep -lE 'example\.invalid|__[A-Z][A-Z0-9_]*__' -- clusters/bootstrap)"
if [ -n "$placeholders" ]; then
  printf '%s\n' "$placeholders" | sed 's/^/  /'
  fail "a file under clusters/bootstrap carries a placeholder, and nothing stamps that tree — write the value as a template slot in the .tpl beside it instead"
fi
echo "check: no file under clusters/bootstrap carries a placeholder, which nothing there would replace."

# ── 2. The delivery programs ────────────────────────────────────────────────────────────────
echo "check: lifecycle/test.sh — the release, the regeneration, the report and the slave removal, in both spellings. About a minute."
bash lifecycle/test.sh || fail "lifecycle/test.sh"

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
#
# COPIED ONE FILE AT A TIME, and not with `cp --parents -t`. Those two options are GNU coreutils
# only: the cp macOS ships carries neither, so that line ends this check red on every Mac. The loop
# below makes each file's folder itself and uses nothing but plain cp.
#
# The list is separated by zero bytes, because a file name may carry anything else — a newline
# included — and a list split on newlines would take one such name for two files and copy neither.
echo "check: gitleaks over the files git would let you commit."
scan="$work/scan"
mkdir -p "$scan" || fail "the scan directory could not be made"
list="$work/committable"
git ls-files --cached --others --exclude-standard -z > "$list" \
  || fail "the committable files could not be listed for the credential scan"
while IFS= read -r -d '' file; do
  [ -n "$file" ] || continue
  destination="$scan/$file"
  mkdir -p "$(dirname "$destination")" \
    || fail "the committable files could not be collected for the credential scan"
  cp "$file" "$destination" \
    || fail "the committable files could not be collected for the credential scan"
done < "$list"
gitleaks detect --no-git --no-banner --source "$scan" || fail "gitleaks found a credential"

echo "check: OK — every check green"
