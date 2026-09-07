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
# scripts/check.ps1 beside this file is the Windows entry point and is a shim that starts THIS
# file, so the three checks exist once and cannot be run in a second spelling of them.

set -uo pipefail

# THE CHART NAMES ARE PRINTED AS A LIST, AND A LIST IN TWO ORDERS IS TWO LISTS. A glob is sorted
# by the collation of whatever language the shell was started in, and under some of them a hyphen
# is ignored — which puts `observability` before `observability-agent` on one machine and after it
# on the next. Byte order is the one every machine agrees on.
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
# A copy of either inside this file would be a second place to change a key, and a key that moved
# in one of them would leave this check green while a real install branch failed. Their own
# comments say what each document is and why the charts need it.
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

# ── One repository, one revision, per Application ───────────────────────────────────────────
# AN APPLICATION WHOSE SOURCES RESOLVE ONE REPOSITORY TO TWO COMMITS PRODUCES NO MANIFEST AT ALL.
# ArgoCD's repo-server checks out every `ref` source that a `$name/...` valueFile of the generated
# source names, and where that source stands on the same repository at another commit it refuses
# with "cannot reference a different revision of the same repository". The Application then stands
# Unknown carrying nothing, the whole tree behind it never syncs, and a deployment's verification
# waits out its clock on it. There is no setting that permits it.
#
# A COUNT OF SITES CANNOT SEE THIS. The defect is a RELATION between two sources of one
# Application, and each site of it is a valid revision read on its own. A count of how many sources
# stand on each revision is green on any split that keeps the totals, and it has to be re-edited by
# whoever adds a source, which turns the number into the answer instead of the question.
#
# WHAT IS READ. Every `sources:` block of a render, item by item: each source's repository, its
# targetRevision, and the YAML anchors either may be written through. A finding is named by the
# `# file:` line the reconciler chart writes ahead of each document it emits, and by helm's own
# `# Source:` line where there is none.
#
# WHAT IT CANNOT SEE, named rather than counted. A repository written as an ApplicationSet
# parameter is compared as that text, because the value arrives when the controller creates the
# Application and no render carries it. Two spellings of one repository are compared lower-cased
# with a trailing slash and a `.git` suffix cut, which is what ArgoCD's normalization does to the
# https form this tree writes; an ssh form would read as a second repository here and as the same
# one there. A single-source Application is not read, because one source cannot disagree with
# itself.
revisions_awk='
function reset() { split("", first); split("", second); split("", order); split("", anchors); n = 0; repo = "" }
function emit(   i, name, where) {
  where = (fil != "" ? fil : src)
  for (i = 1; i <= n; i++) {
    name = order[i]
    if (name in second) print where "\t" name "\t" first[name] "\t" second[name]
  }
  reset()
}
function value(s,   name) {
  sub(/^[A-Za-z]+:[ \t]*/, "", s)
  sub(/[ \t]+#.*$/, "", s)
  sub(/[ \t]+$/, "", s)
  if (s ~ /^&/) {
    name = s
    sub(/^&[^ \t]+[ \t]*/, "", s)
    sub(/^&/, "", name)
    sub(/[ \t].*$/, "", name)
    gsub(/"/, "", s)
    anchors[name] = s
    return s
  }
  if (s ~ /^\*/) return anchors[substr(s, 2)]
  gsub(/"/, "", s)
  return s
}
function repository(u) { u = tolower(u); sub(/\/+$/, "", u); sub(/\.git$/, "", u); return u }
function record(name, revision) {
  if (name == "" || revision == "") return
  if (!(name in first)) { first[name] = revision; order[++n] = name }
  else if (first[name] != revision && !(name in second)) second[name] = revision
}
BEGIN { base = -1 }
/^# file: / { fil = substr($0, 9); next }
/^# Source: / { src = substr($0, 11); next }
/^---[ \t]*$/ { emit(); base = -1; fil = ""; next }
{
  match($0, /^[ \t]*/)
  indent = RLENGTH
  line = substr($0, indent + 1)
  if (line == "" || substr(line, 1, 1) == "#") next
  if (base >= 0 && indent <= base) { emit(); base = -1 }
  item = line
  sub(/^-[ \t]+/, "", item)
  if (item ~ /^sources:[ \t]*$/) { emit(); base = indent; next }
  if (base < 0) next
  if (item ~ /^repoURL:[ \t]/) { repo = repository(value(item)); next }
  if (item ~ /^targetRevision:[ \t]/) { record(repo, value(item)); repo = ""; next }
}
END { emit() }
'

# $1 says where the render came from, $2 is a file holding it. One line per finding on stdout.
sources_disagreeing() {
  awk "$revisions_awk" "$2" > "$work/revisions" || fail "the render of $1 could not be read"
  while IFS="$tab" read -r where name one other; do
    printf '  %s, %s: %s stands at %s and at %s in one Application\n' "$1" "$where" "$name" "$one" "$other"
  done < "$work/revisions"
}

# $1 says where the render came from, $2 is the render itself. Adds what it finds to $disagreeing.
collect_disagreeing() {
  printf '%s\n' "$2" > "$work/render"
  found="$(sources_disagreeing "$1" "$work/render")"
  [ -n "$found" ] || return 0
  disagreeing="$disagreeing
$found"
}

# ── The counter-probe of that scan ──────────────────────────────────────────────────────────
# THE SCAN IS RUN OVER A PLANTED RENDER BEFORE IT IS RUN OVER A REAL ONE. scripts/counter-probe.yaml
# plants two defects it has to report and three innocents it has to leave alone, and its own header
# says which is which. Without the defects a green run would only mean the scan found nothing,
# which is also what a scan that stopped looking prints.
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

sources_expected='  scripts/counter-probe.yaml, counter-probe/planted-defect-in-two-revisions.yaml: https://github.com/simetrixch/planted stands at planted-branch and at planted-tag in one Application'
sources_reported="$(sources_disagreeing 'scripts/counter-probe.yaml' "$counter_probe")"
if [ "$sources_reported" != "$sources_expected" ]; then
  echo "The counter-probe plants one Application whose sources disagree and two that do not. The scan had to report:"
  echo "$sources_expected"
  echo "and it reported:"
  echo "${sources_reported:-  (nothing)}"
  fail "the scan for an Application naming one repository at two revisions does not report what scripts/counter-probe.yaml plants"
fi
echo "check: the counter-probe reports the planted Application whose sources disagree and neither planted innocent."

# ── 1. The charts ───────────────────────────────────────────────────────────────────────────
echo "check: rendering every chart under clusters/inventories, clusters/units and clusters/slaves, and clusters/argocd."

stages="dev test prod"
rendered=0
skipped_library=""
needed_standin=""
broken=""
expressions=""
disagreeing=""

# clusters/argocd IS A CHART, not a directory of charts, so it is named rather than globbed. It
# renders the eight manifests of clusters/argocd/files from the cluster map, and it is the only
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
    # THE API VERSIONS A CLUSTER SERVES, declared here: clusters/charts/monitoring emits its kinds only
    # where the destination cluster has them, and helm template alone knows no cluster.
    args=(--api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 -f clusters/platform/values-common.yaml)
    [ -f "clusters/platform/values-$stage.yaml" ] && args+=(-f "clusters/platform/values-$stage.yaml")
    for values in values-common.yaml values.yaml "values-$stage.yaml" values-size-small.yaml; do
      [ -f "$chart/$values" ] && args+=(-f "$chart/$values")
    done

    trunk_only="$(helm template "$name" "$chart" --namespace "$namespace" "${args[@]}" 2>&1)"
    if [ $? -eq 0 ]; then
      rendered=$((rendered + 1))
      collect_expressions "$name at stage $stage" "$trunk_only"
      collect_disagreeing "$name at stage $stage" "$trunk_only"
      continue
    fi

    # It did not render from what the trunk carries. That is the normal case and not yet a
    # finding: the installation's own answers load last in the chain, and the trunk has none.
    out="$(helm template "$name" "$chart" --namespace "$namespace" \
      "${args[@]}" -f "$cluster_map" -f "$registration" 2>&1)"
    if [ $? -eq 0 ]; then
      rendered=$((rendered + 1))
      collect_expressions "$name at stage $stage" "$out"
      collect_disagreeing "$name at stage $stage" "$out"
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

if [ -n "$disagreeing" ]; then
  echo "These Applications name one repository at two revisions, and ArgoCD generates no manifest for one:$disagreeing"
  fail "an Application names one repository at two revisions"
fi
echo "check: every Application of those $rendered renders names each repository it uses at one revision."

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

# ── That render read for the one relation ArgoCD refuses ─────────────────────────────────────
# THIS IS THE RENDER THE DEFECT WOULD REACH A CLUSTER THROUGH. The loop above already reads every
# chart for it, and this is the same reading over the one chain a reconciler actually gets, where
# the Applications the map is answered for are the ones a cluster would carry. The header on
# sources_disagreeing says what the relation is and what ArgoCD does with it.
argocd_disagreeing="$(sources_disagreeing 'clusters/argocd from the cluster map alone' "$work/argocd-alone")"
if [ -n "$argocd_disagreeing" ]; then
  echo "These Applications name one repository at two revisions, and ArgoCD generates no manifest for one:$argocd_disagreeing"
  fail "an Application of clusters/argocd names one repository at two revisions"
fi
echo "check: every Application of clusters/argocd names each repository it uses at one revision."

# ── The per-unit fences, held to the objects they must render ────────────────────────────────
# NOTHING ELSE HERE WOULD NOTICE ONE MISSING. The chart loop above renders every chart and reads
# what came out for a Helm expression, so a chart that rendered one object FEWER renders exactly as
# green as one that rendered them all. These nine objects are what fences a customer's unit — its
# isolation AppProject, its admission boundary and its Binding, and the three grants its release
# cycle runs on — and one dropped from a template is a unit that onboards, reports itself green and
# is never fenced. That is the failure this whole mechanism exists to remove, and it would arrive
# through the mechanism itself.
#
# HELD AS THE OBJECTS AND NOT AS A COUNT, because a count is satisfied by any nine. Each is a `kind`
# and the name under the `metadata:` block that follows it, which is the object's own identity and
# never the name a roleRef or a subject repeats further down.
#
# THE THREE GRANTS STAND IN TWO PLACES AND THAT IS THE RULE, not an accident: a fence is rendered by
# the reconciler that manages the namespace it lands in. The two build-namespace grants come from
# clusters/inventories/consumer-build in UNIT mode, which is the Application that creates
# <unit>-build in the first place, and this is the only place that mode is rendered at all.
#
# WHAT THIS CANNOT SEE, named rather than counted: whether these nine are still the set the Manager
# writes per unit. That comparison lives in hostyour-manager, and nothing on this machine can make
# it. A tenth object appearing there is not refused here.
#
# `--set-json` AND NOT `--set`, because consumer-build declares `unit: null` in its own values and
# that is what tells its two render modes apart. helm applies a `--set` INTO the loaded values, and
# `unit.name=check` over a nil `unit` ends the run with "interface conversion: interface {} is nil"
# rather than with anything naming the chart. `--set-json` writes the whole key and never descends.
echo "check: the per-unit fences, held to the objects they must render."
objects_of() { # $1 a file holding a render. One `kind/name` per object on stdout.
  awk '
    /^kind: / { kind = substr($0, 7); next }
    /^metadata:/ { inmeta = 1; next }
    /^[^ ]/ { inmeta = 0 }
    inmeta && /^  name: / { print kind "/" substr($0, 9); inmeta = 0 }
  ' "$1"
}
fences_expected='AppProject/check
Role/check-argo-sync
Role/eventlistener-create-pipelineruns
Role/manager-read-pipelineruns
RoleBinding/check-argo-sync
RoleBinding/eventlistener-create-pipelineruns
RoleBinding/manager-read-pipelineruns
ValidatingAdmissionPolicy/consumer-check
ValidatingAdmissionPolicyBinding/consumer-check'
: > "$work/fences"
for chart in clusters/units/reconciler clusters/units/admissionpolicy; do
  helm template "$(basename "$chart")" "$chart" --namespace check --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
    -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
    -f "$chart/values.yaml" -f "$cluster_map" -f "$registration" > "$work/fence-render" 2>&1 \
    || { cat "$work/fence-render"; fail "$chart does not render, and it is what fences a unit"; }
  objects_of "$work/fence-render" >> "$work/fences"
done
helm template consumer-build clusters/inventories/consumer-build --namespace argocd --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
  -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
  -f clusters/inventories/consumer-build/values-common.yaml -f "$cluster_map" -f "$registration" \
  --set-json 'unit={"name":"check","repoURL":"https://github.com/check/check.git","buildsJson":"[]"}' \
  > "$work/fence-render" 2>&1 \
  || { cat "$work/fence-render"; fail "clusters/inventories/consumer-build does not render in unit mode, which is where a unit's build grants stand"; }
objects_of "$work/fence-render" \
  | grep -E '^(Role|RoleBinding)/(eventlistener-create-pipelineruns|manager-read-pipelineruns)$' >> "$work/fences"
fences_rendered="$(sort "$work/fences")"
if [ "$fences_rendered" != "$fences_expected" ]; then
  echo "The per-unit fences had to be:"
  printf '%s\n' "$fences_expected" | sed 's/^/  /'
  echo "and they rendered as:"
  printf '%s\n' "${fences_rendered:-  (nothing)}" | sed 's/^/  /'
  fail "the per-unit fences are not the objects they have to be — a unit would onboard green and stand unfenced"
fi
echo "check: all 9 per-unit fences render, over clusters/units/reconciler, clusters/units/admissionpolicy and clusters/inventories/consumer-build in unit mode."

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
