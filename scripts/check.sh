#!/usr/bin/env bash
# Everything this repository can be held to on one machine, before anything leaves it.
#
# Local chart validation and credential scanning. Fixture suites run in the ci of the master (scripts/test.sh).

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
# base64 decodes rendered values; yq reads the version stamp declarations; promtool runs the rule
# tests; patch reverses the patch of the vendored Plane chart.
missing=""
for tool in helm gitleaks base64 yq node promtool patch; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -n "$missing" ] && fail "these tools are not on this path:$missing"

work="$(mktemp -d)" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT

# Compare against the preceding stable source, never a hand-maintained snapshot.
# A tag on a clean HEAD is the candidate itself, so its parent supplies the baseline.
revision=HEAD
if git diff --quiet && git diff --cached --quiet && git tag --points-at HEAD | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-stable-'; then
  revision=HEAD^
fi
baseline="$(git describe --tags --match '*-stable-*' --abbrev=0 "$revision" 2>/dev/null)" \
  || fail "no preceding stable release available for immutable comparison; fetch complete release history"
mkdir "$work/baseline" || fail "cannot prepare immutable baseline"
git archive "$baseline" clusters scripts/standin | tar -x -C "$work/baseline" || fail "cannot extract immutable baseline"
node scripts/check-immutable.mjs --probe || fail "immutable-field counter-probe failed"
immutable_rendered=0
immutable_skipped=""

# args, chart, name and namespace are the same value chain used by the render below. The baseline's
# own stand-ins load first and the candidate's over them, so every key both answer takes the
# candidate's value, and a key the candidate renamed is still answered for the baseline chart that
# requires it under its old name. Every argument is one the candidate was rendered with beyond that
# chain, and the baseline gets it too: a chart rendered with the placeholder taken for a tag stops at
# the baseline without it, the same as it would at the candidate.
render_baseline() {
  (cd "$work/baseline" &&
    { helm template "$name" "$chart" --namespace "$namespace" "${args[@]}" "$@" 2>/dev/null ||
      helm template "$name" "$chart" --namespace "$namespace" "${args[@]}" \
        -f scripts/standin/installation-values.yaml -f scripts/standin/cluster-map.yaml -f scripts/standin/registration.yaml \
        -f "$installation_values" -f "$cluster_map" -f "$registration" "$@"; })
}

check_immutable_render() {
  local current="$1" previous
  shift
  [ -f "$work/baseline/$chart/Chart.yaml" ] || return 0
  if ! previous="$(render_baseline "$@" 2>"$work/immutable-baseline.err")"; then
    # A BASELINE PIN AT THE PLACEHOLDER IS NO BASELINE. common.buildTag stops the render of a stage
    # no release has reached, so the preceding release deployed nothing of this chart at this stage,
    # and there is nothing to compare against. Only that cause is skipped: the render is repeated
    # through both chains with the placeholder taken for a tag and nothing else changed, and a
    # baseline that still does not render is red with the message of its first render.
    if render_baseline "$@" --set global.placeholderTag=check-takes-the-placeholder-for-a-tag >/dev/null 2>&1; then
      echo "check: no immutable comparison for $chart at $stage: $baseline pins it at the placeholder, so nothing was deployed there."
      immutable_skipped="$immutable_skipped $name at $stage,"
      return 0
    fi
    cat "$work/immutable-baseline.err"
    fail "cannot render $chart at preceding stable release $baseline"
  fi
  printf '%s' "$previous" | yq eval-all -o=json -I=0 '[.]' - > "$work/immutable-before.json" \
    || fail "cannot parse preceding render"
  printf '%s' "$current" | yq eval-all -o=json -I=0 '[.]' - > "$work/immutable-after.json" \
    || fail "cannot parse candidate render"
  # The candidate's app.yaml is what Argo CD syncs the candidate with; a unit chart has none.
  if [ -f "$chart/app.yaml" ]; then
    yq -o=json -I=0 '.ignoreDifferences |= (. // "[]" | from_yaml)' "$chart/app.yaml" > "$work/immutable-app.json" \
      || fail "cannot parse $chart/app.yaml"
  else
    echo '{}' > "$work/immutable-app.json"
  fi
  node "$root/scripts/check-immutable.mjs" "$work/immutable-before.json" "$work/immutable-after.json" "$namespace" "$work/immutable-app.json" \
    || fail "$chart at $stage changes an immutable field of a retained identity; use a new identity"
  immutable_rendered=$((immutable_rendered + 1))
}

# ── What an installation answers ────────────────────────────────────────────────────────────
# The three stand-in documents are TRACKED FILES, and each is read here rather than written out.
# A copy of either inside this file would be a second place to change a key, and a key that moved
# in one of them would leave this check green while a real install branch failed. Their own
# comments say what each document is and why the charts need it.
cluster_map="$root/scripts/standin/cluster-map.yaml"
registration="$root/scripts/standin/registration.yaml"
installation_values="$root/scripts/standin/installation-values.yaml"
for standin in "$cluster_map" "$registration" "$installation_values"; do
  [ -f "$standin" ] || fail "$standin is missing, and it is what lets the charts of an installation render here"
done
handed_revision="$(yq '.revision // ""' "$registration")"
[ -n "$handed_revision" ] || fail "$registration carries no revision, and it is what the reconciler's charts are handed as the commit their root Application synced"

# ── The probe of the immutable comparison ───────────────────────────────────────────────────
# THE COMPARISON IS RUN OVER A PLANTED BASELINE BEFORE IT IS RUN OVER A REAL ONE. scripts/immutable-probe
# is planted under a baseline of its own with what its render reads, and each case hands
# check_immutable_render the candidate rendered from another values file of it. Each case runs in a
# subshell, because a red comparison exits. The baseline that pins the placeholder is the planted
# innocent: it renders only through the stand-in chain with the placeholder taken for a tag, so a
# skip that retried one chain alone, or retried without that tag, is red on it.
probe="$work/immutable-probe"
mkdir -p "$probe/baseline/clusters/charts" "$probe/baseline/clusters/platform" "$probe/baseline/scripts" \
  && cp -R clusters/charts/common clusters/charts/secret-store "$probe/baseline/clusters/charts/" \
  && cp clusters/platform/values-common.yaml "$probe/baseline/clusters/platform/" \
  && cp -R scripts/standin scripts/immutable-probe "$probe/baseline/scripts/" \
  && out="$(cd "$probe/baseline" && helm dependency update scripts/immutable-probe 2>&1)" \
  || { echo "${out:-}"; fail "cannot prepare the planted baseline of scripts/immutable-probe"; }

# $1 is the exit status the comparison must end with, $2 the values file of the baseline, $3 the one
# of the candidate, and the rest are the lines it must print.
expect_immutable() {
  local status="$1" previous_values="$2" current_values="$3" said line
  shift 3
  said="$(
    exec 2>&1
    work="$probe" chart=scripts/immutable-probe name=immutable-probe namespace=check stage=test
    args=(-f clusters/platform/values-common.yaml -f "$chart/$previous_values")
    current="$(cd "$probe/baseline" && helm template "$name" "$chart" --namespace "$namespace" \
      -f clusters/platform/values-common.yaml -f "$chart/$current_values" \
      -f "$installation_values" -f "$cluster_map" -f "$registration")" \
      || fail "cannot render the planted candidate $current_values"
    check_immutable_render "$current"
    echo "check: $immutable_rendered compared"
  )"
  if [ $? -ne "$status" ]; then
    printf '%s\n' "$said" | sed 's/^/  /'
    fail "the immutable comparison of a baseline at $previous_values and a candidate at $current_values did not exit $status"
  fi
  for line in "$@"; do
    grep -qxF -- "$line" <<< "$said" && continue
    printf '%s\n' "$said" | sed 's/^/  /'
    fail "the immutable comparison of a baseline at $previous_values and a candidate at $current_values did not print: $line"
  done
}
expect_immutable 0 values-placeholder-pin.yaml values-real-pin.yaml \
  "check: no immutable comparison for scripts/immutable-probe at test: $baseline pins it at the placeholder, so nothing was deployed there." \
  'check: 0 compared'
expect_immutable 1 values-real-pin.yaml values-changed-pin.yaml \
  'check: FAIL — scripts/immutable-probe at test changes an immutable field of a retained identity; use a new identity'
expect_immutable 1 values-no-pin.yaml values-real-pin.yaml \
  "check: FAIL — cannot render scripts/immutable-probe at preceding stable release $baseline"
echo "check: the immutable comparison skips the planted baseline that pins the placeholder, and is red on the planted immutable change and on the planted baseline that renders through no chain."

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
  if (src == "" && match($0, /^[ \t]+[A-Za-z0-9._-]+:[ \t]*"?[A-Za-z0-9+\/]+=?=?"?[ \t]*$/)) {
    payload = $0
    sub(/^[ \t]+[A-Za-z0-9._-]+:[ \t]*"?/, "", payload)
    sub(/"?[ \t]*$/, "", payload)
    bare = payload
    sub(/=+$/, "", bare)
    if (length(bare) >= 40) print "base64\t" source "\t" key "\t" payload
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
# A source's fields as the two scans below read them: a value with its YAML anchor resolved or
# recorded, and a repository URL the way ArgoCD normalizes it.
source_fields_awk='
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
'

revisions_awk="$source_fields_awk"'
function reset() { split("", first); split("", second); split("", order); split("", anchors); n = 0; repo = "" }
function emit(   i, name, where) {
  where = (fil != "" ? fil : src)
  for (i = 1; i <= n; i++) {
    name = order[i]
    if (name in second) print where "\t" name "\t" first[name] "\t" second[name]
  }
  reset()
}
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

# AN INGRESS IS SERVED OVER PLAIN HTTP UNLESS IT BINDS websecure ALONE. Traefik binds an Ingress
# without the entrypoints annotation to every entrypoint, `web` included, and a route with a host
# outranks the catch-all of clusters/inventories/https-redirect, so the page, its sign-in and its
# cookies would travel unencrypted. $1 says where the render came from, $2 is a file holding it.
ingresses_on_web() {
  yq eval-all -N 'select(.kind == "Ingress" and .metadata.annotations["traefik.ingress.kubernetes.io/router.entrypoints"] != "websecure") | .metadata.name' "$2" \
    > "$work/plain-http" 2>/dev/null || fail "the render of $1 could not be read"
  while read -r ingress; do
    [ -n "$ingress" ] && printf '  %s: Ingress %s binds more than websecure\n' "$1" "$ingress"
  done < "$work/plain-http"
}

# $1 says where the render came from, $2 is the render itself. Adds what it finds to $plain_http.
collect_plain_http() {
  printf '%s\n' "$2" > "$work/render"
  found="$(ingresses_on_web "$1" "$work/render")"
  [ -n "$found" ] || return 0
  plain_http="$plain_http
$found"
}

# THE PODS THE MASTER CANNOT WORK WITHOUT CARRY A CPU REQUEST. A pod with none gets the smallest share of the node
# once the node is saturated, and the build plane saturates it: the ci check may take 12 cores, seven runs at once. The
# ingress, the reconcilers, the certificates and the build plane's controllers are the pods that must keep working
# then, so each container of the workloads below asks for the CPU it uses (its p95 over seven days, which the
# comment beside each request in the values names). The names are the ones the charts render and the live pods
# carry; traefik is the MicroK8s ingress addon's DaemonSet, which no chart of this repository renders, so it stands
# here for the render that carries it once hostyour-deploy sets its request. The ci pods and the other pods that
# stand on the node are budgeted in clusters/inventories/consumer-build/values-common.yaml (ciCapacity).
cpu_guaranteed='traefik|argocd-application-controller|argocd-applicationset-controller|argocd-repo-server|argocd-server|argocd-redis|argocd-dex-server|argocd-notifications-controller|cert-manager|cert-manager-cainjector|cert-manager-webhook'

# $1 says where the render came from, $2 is a file holding it. One line per finding on stdout. `eval` reads one document at
# a time, which the variables of the filter need: `eval-all` would bind them across every document of the render.
workloads_without_cpu_request() {
  yq eval -N 'select((.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet") and ((.metadata.name // "") | test("^('"$cpu_guaranteed"')$")))
    | .kind as $kind | .metadata.name as $name | .spec.template.spec.containers[] | select(.resources.requests.cpu == null)
    | $kind + " " + $name + " container " + .name' "$2" > "$work/no-cpu-request" 2>/dev/null || fail "the render of $1 could not be read"
  while read -r workload; do
    [ -n "$workload" ] && printf '  %s: %s has no CPU request\n' "$1" "$workload"
  done < "$work/no-cpu-request"
}

# $1 says where the render came from, $2 is the render itself. Adds what it finds to $no_cpu_request.
collect_cpu_requests() {
  printf '%s\n' "$2" > "$work/render"
  found="$(workloads_without_cpu_request "$1" "$work/render")"
  [ -n "$found" ] || return 0
  no_cpu_request="$no_cpu_request
$found"
}

# A SOURCE OR A GENERATOR OF THIS REPOSITORY STANDS AT THE COMMIT ITS ROOT APPLICATION SYNCED, which
# that Application hands clusters/argocd and clusters/slaves/slave as `revision`, and which every
# platform Application, standing at it, hands consumer-build the same way. One standing at a
# branch follows the branch on its own, so it can reach a commit before the root Application has
# applied that commit's AppProjects, and its sync fails on a kind the project does not admit yet.
# WHAT IS READ. Every line of the render, so a source inside an ApplicationSet's templatePatch,
# which is a string to any YAML reader, is read like one in its template: a repoURL of this
# repository and the targetRevision or git generator revision that follows it, through the anchors
# either may be written with. A revision written ahead of its repoURL, and a source of this
# repository that names no revision at all, are not seen; every source of this tree writes repoURL
# first. $1 says where the render came from, $2 is a file holding it, $3 is the revision the chart
# was handed. A finding is named by the document's `metadata.name`, because helm sorts the documents
# by kind and a `# file:` line stands ahead of only the first document a file emits.
off_revision_awk="$source_fields_awk"'
/^# Source: / { src = substr($0, 11); next }
/^---[ \t]*$/ { split("", anchors); repo = ""; name = ""; next }
/^metadata:/ { meta = 1; next }
/^[^ ]/ { meta = 0 }
meta && /^  name:[ \t]/ { name = value(substr($0, 3)); meta = 0; next }
{
  item = $0
  sub(/^[ \t]*/, "", item)
  if (item == "" || substr(item, 1, 1) == "#") next
  sub(/^-[ \t]+/, "", item)
  if (item ~ /^repoURL:[ \t]/) { repo = repository(value(item)); next }
  if (item ~ /^(targetRevision|revision):[ \t]/) {
    revision = value(item)
    if (repo == "https://github.com/simetrixch/hostyour-cloud" && revision != handed) print src "\t" name "\t" revision
    repo = ""
  }
}
'
sources_off_revision() {
  awk -v handed="$3" "$off_revision_awk" "$2" | awk '!seen[$0]++' > "$work/off-revision" || fail "the render of $1 could not be read"
  while IFS="$tab" read -r where name revision; do
    printf '  %s, %s: %s names this repository at %s\n' "$1" "$where" "$name" "${revision:-no revision}"
  done < "$work/off-revision"
}

# $1 says where the render came from, $2 is the render itself. Adds what it finds to $off_revision,
# for the charts handed a revision that emit sources or generators of this repository: the two the
# root Application hands one, and consumer-build, which its platform Application hands one.
collect_off_revision() {
  case "$chart" in clusters/argocd|clusters/slaves/slave|clusters/inventories/consumer-build) ;; *) return 0 ;; esac
  printf '%s\n' "$2" > "$work/render"
  found="$(sources_off_revision "$1" "$work/render" "$handed_revision")"
  [ -n "$found" ] || return 0
  off_revision="$off_revision
$found"
}

# ── The awk programs of the scans read no regex interval ────────────────────────────────────
# THE CI IMAGE'S AWK IS mawk 1.3.4 20200120, AND IT READS A BRACE EXPRESSION IN A REGEX AS TEXT. A
# regex ending in an interval (a class and a count in braces) matches nothing there and nothing
# complains: the base64 field of the scan stayed unmatched, no value was decoded, and the
# counter-probe below went red in the ci run and green on every workstation, whose awk reads it.
# The fence reads the programs, so it is red on every machine the day one is written again. A
# count is written as a `length()` test or as repeated classes.
has_interval() { grep -Eq '[{][0-9]+(,[0-9]*)?[}]' <<< "$1"; }
interval_planted='match($0, /^[A-Za-z0-9+\/]{40,}={0,2}$/)'
interval_innocent='match(s, /\{\{[^{}]*\}\}/) && length(s) >= 40 && s ~ /=?=?$/'
has_interval "$interval_planted" || fail "the fence for a regex interval does not see one planted in an awk program"
has_interval "$interval_innocent" && fail "the fence for a regex interval reports an awk program that writes none"
for program in scan_awk source_fields_awk revisions_awk off_revision_awk; do
  has_interval "${!program}" && fail "the awk program $program writes a regex interval, which the ci image's mawk 1.3.4 20200120 reads as text, so its match is silently empty there"
done
echo "check: no awk program of the scans writes a regex interval, and the fence reports one planted."

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

plain_expected='  scripts/counter-probe.yaml: Ingress planted-defect-on-every-entrypoint binds more than websecure
  scripts/counter-probe.yaml: Ingress planted-defect-on-web-and-websecure binds more than websecure'
plain_reported="$(ingresses_on_web 'scripts/counter-probe.yaml' "$counter_probe")"
if [ "$plain_reported" != "$plain_expected" ]; then
  echo "The counter-probe plants two Ingresses served over plain http and one that is not. The scan had to report:"
  echo "$plain_expected"
  echo "and it reported:"
  echo "${plain_reported:-  (nothing)}"
  fail "the scan for an Ingress served over plain http does not report what scripts/counter-probe.yaml plants"
fi
echo "check: the counter-probe reports both planted Ingresses served over plain http and not the planted innocent."

cpu_expected='  scripts/counter-probe.yaml: DaemonSet traefik container traefik has no CPU request
  scripts/counter-probe.yaml: Deployment argocd-repo-server container sidecar has no CPU request'
cpu_reported="$(workloads_without_cpu_request 'scripts/counter-probe.yaml' "$counter_probe")"
if [ "$cpu_reported" != "$cpu_expected" ]; then
  echo "The counter-probe plants a Traefik without a CPU request, an Argo CD repo-server whose second container has none, and four workloads that need none. The scan had to report:"
  echo "$cpu_expected"
  echo "and it reported:"
  echo "${cpu_reported:-  (nothing)}"
  fail "the scan for a workload without a CPU request does not report what scripts/counter-probe.yaml plants"
fi
echo "check: the counter-probe reports the planted Traefik and the planted second container without a CPU request, and not the planted innocents."

off_expected='  scripts/counter-probe.yaml, counter-probe/planted-defect-generator-on-a-branch.yaml: planted-defect-generator-on-a-branch names this repository at planted.example.invalid
  scripts/counter-probe.yaml, counter-probe/planted-defect-sources-on-a-branch.yaml: planted-defect-sources-on-a-branch names this repository at planted.example.invalid'
off_reported="$(sources_off_revision 'scripts/counter-probe.yaml' "$counter_probe" "$handed_revision")"
if [ "$off_reported" != "$off_expected" ]; then
  echo "The counter-probe plants two documents naming this repository at a branch and one at the handed revision. The scan had to report:"
  echo "$off_expected"
  echo "and it reported:"
  echo "${off_reported:-  (nothing)}"
  fail "the scan for a source of this repository off the handed revision does not report what scripts/counter-probe.yaml plants"
fi
echo "check: the counter-probe reports both planted sources of this repository at a branch and not the planted innocent."

# A CHART THAT CARRIES rules.test.yaml HAS IT RUN OVER ITS OWN RENDER, so the test reads the rules
# that reach the cluster and not the values they are written in. The .spec of every PrometheusRule
# goes to a file of its own, because two objects may carry one group name and one rule file
# refuses that. $1 is the render of $chart at $stage. Adds the chart and the stage to $rule_tests.
collect_rule_test() {
  [ -f "$chart/rules.test.yaml" ] || return 0
  local dir="$work/rules/$name/$stage"
  mkdir -p "$dir" && printf '%s\n' "$1" > "$dir/render" \
    && (cd "$dir" && yq eval-all -N -s '"rule-" + $index' 'select(.kind == "PrometheusRule") | .spec' render) \
    && yq '.rule_files = ["rule-*.yml"]' "$chart/rules.test.yaml" > "$dir/rules.test.yaml" \
    || fail "the rule test of $name at stage $stage could not be prepared"
  rule_tests="$rule_tests
$chart $stage"
}

# ── 1. The charts ───────────────────────────────────────────────────────────────────────────
echo "check: rendering every chart under clusters/inventories, clusters/units and clusters/slaves, and clusters/argocd."

stages="dev test prod"
rendered=0
skipped_library=""
needed_standin=""
awaiting_release=""
broken=""
expressions=""
disagreeing=""
plain_http=""
no_cpu_request=""
off_revision=""
rule_tests=""

# clusters/argocd IS A CHART, not a directory of charts, so it is named rather than globbed. It
# renders the manifests of clusters/argocd/files from the cluster map, and it is the only
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
  # template rather than a missing dependency. Both outputs, charts/ and Chart.lock, are ignored by
  # this repository, so this leaves the working copy clean. UPDATE AND NOT BUILD: once a Chart.lock
  # stands, `helm dependency build` resolves a dependency named by URL only through a
  # `helm repo add`, so every run after the first failed on a machine that never added one; update
  # resolves it the same way on every run. A CHART WHOSE DEPENDENCIES NAME NO REPOSITORY is vendored
  # (clusters/inventories/external-secrets): helm refuses to update it, and its render needs nothing fetched.
  if grep -qE '^[[:space:]]+repository:' "$chart/Chart.yaml"; then
    out="$(helm dependency update "$chart" 2>&1)" \
      || { echo "$out"; fail "the dependencies of $chart could not be built"; }
  fi

  if [ -f "$work/baseline/$chart/Chart.yaml" ] && grep -qE '^[[:space:]]+repository:' "$work/baseline/$chart/Chart.yaml"; then
    out="$(cd "$work/baseline" && helm dependency update "$chart" 2>&1)" \
      || { echo "$out"; fail "cannot build baseline dependencies of $chart"; }
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
      collect_plain_http "$name at stage $stage" "$trunk_only"
      collect_cpu_requests "$name at stage $stage" "$trunk_only"
      collect_off_revision "$name at stage $stage" "$trunk_only"
      collect_rule_test "$trunk_only"
      check_immutable_render "$trunk_only"
      continue
    fi

    # It did not render from what the trunk carries. That is the normal case and not yet a
    # finding: the installation's own answers load last in the chain, and the trunk has none.
    out="$(helm template "$name" "$chart" --namespace "$namespace" \
      "${args[@]}" -f "$installation_values" -f "$cluster_map" -f "$registration" 2>&1)"
    if [ $? -eq 0 ]; then
      rendered=$((rendered + 1))
      collect_expressions "$name at stage $stage" "$out"
      collect_disagreeing "$name at stage $stage" "$out"
      collect_plain_http "$name at stage $stage" "$out"
      collect_cpu_requests "$name at stage $stage" "$out"
      collect_off_revision "$name at stage $stage" "$out"
      collect_rule_test "$out"
      check_immutable_render "$out"
      case " $needed_standin " in
        *" $name "*) ;;
        *) needed_standin="$needed_standin $name" ;;
      esac
      continue
    fi

    # One cause is no defect: a pin at global.placeholderTag, the tag a stage carries before its
    # first release, stops the render on purpose (clusters/charts/common common.buildTag), and that
    # release can write over the pin only once the pin stands on the trunk. So the chart is
    # rendered once more with the placeholder taken for a tag. Nothing else changes, so a chart
    # that renders now has no defect but a pin no release has written yet, and it is named below.
    out="$(helm template "$name" "$chart" --namespace "$namespace" \
      "${args[@]}" -f "$installation_values" -f "$cluster_map" -f "$registration" \
      --set global.placeholderTag=check-takes-the-placeholder-for-a-tag 2>&1)"
    if [ $? -eq 0 ]; then
      rendered=$((rendered + 1))
      collect_expressions "$name at stage $stage" "$out"
      collect_disagreeing "$name at stage $stage" "$out"
      collect_plain_http "$name at stage $stage" "$out"
      collect_cpu_requests "$name at stage $stage" "$out"
      collect_off_revision "$name at stage $stage" "$out"
      collect_rule_test "$out"
      check_immutable_render "$out" --set global.placeholderTag=check-takes-the-placeholder-for-a-tag
      awaiting_release="$awaiting_release $name at $stage,"
      continue
    fi

    # It renders from none of these. The chart is named with the stage it failed at and the whole
    # message helm gave, because that message names the template and the value.
    broken="$broken
  $name at stage $stage:
$(printf '%s' "$out" | sed 's/^/    /')"
  done
done

# Catalog mode emits only the fan-out, so also compare the generic production-unit mode.
chart=clusters/inventories/consumer-build
name=consumer-build
namespace=check-build
for stage in $stages; do
  args=(-f clusters/platform/values-common.yaml -f "clusters/platform/values-$stage.yaml"
    -f "$chart/values-common.yaml" --set-json
    'unit={"name":"check","repoURL":"https://github.com/check/check.git","buildsJson":"[\"check\"]"}')
  out="$(helm template "$name" "$chart" --namespace "$namespace" "${args[@]}" \
    -f "$installation_values" -f "$cluster_map" -f "$registration" 2>&1)" \
    || { echo "$out"; fail "cannot render production-unit immutable probe"; }
  check_immutable_render "$out"
done
echo "check: $immutable_rendered immutable render comparisons green against $baseline."
[ -n "$immutable_skipped" ] && echo "check: no immutable comparison where $baseline pins the placeholder:${immutable_skipped%,}."

[ -n "$skipped_library" ] && echo "check: library charts, which render only through what depends on them:$skipped_library"
[ -n "$needed_standin" ] && echo "check: charts that render only with an installation's own answers, which no file of this repository carries:$needed_standin"
[ -n "$awaiting_release" ] && echo "check: charts that render only once a release has written the pin their stage carries before its first one:${awaiting_release%,}"

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

if [ -n "$plain_http" ]; then
  echo "These Ingresses are served over plain http as well, because they do not bind websecure alone:$plain_http"
  fail "an Ingress is served over plain http"
fi
echo "check: every Ingress of those $rendered renders binds websecure alone."

# THE RECONCILER OF THE MASTER IS NOT A CHART OF THIS REPOSITORY: the deploy program installs the argo-cd chart with
# clusters/bootstrap/argocd/values.tpl. The slave chart depends on that chart at the master's version, so its archive
# (built by the loop above) renders the master's values here, and the master's own Argo CD is held to the same scan.
argo_chart="$(ls clusters/slaves/slave/charts/argo-cd-*.tgz 2>/dev/null | head -n 1)"
[ -n "$argo_chart" ] || fail "the argo-cd chart of clusters/slaves/slave was not built, so the values of the master's Argo CD cannot be rendered"
master_argo="$(helm template argocd "$argo_chart" --namespace argocd -f clusters/bootstrap/argocd/values.tpl 2>&1)" \
  || { echo "$master_argo"; fail "the argo-cd chart does not render with clusters/bootstrap/argocd/values.tpl"; }
collect_cpu_requests "the argo-cd chart with clusters/bootstrap/argocd/values.tpl" "$master_argo"
if [ -n "$no_cpu_request" ]; then
  echo "These workloads stand on the node where a heavy build runs, and without a CPU request they get the smallest share of it:$no_cpu_request"
  fail "a workload the master cannot work without renders without a CPU request"
fi
echo "check: every container of those workloads that the $rendered renders and the master's Argo CD carry has a CPU request; traefik is in none of them."

if [ -n "$off_revision" ]; then
  echo "These name this repository at another revision than the one their root Application synced, so they can reach a commit before its AppProjects:$off_revision"
  fail "a source or a generator of this repository is off the handed revision"
fi
echo "check: every source and generator of this repository in clusters/argocd, clusters/slaves/slave and clusters/inventories/consumer-build stands at the handed revision."

# ── The rule tests, over the rules as they render ────────────────────────────────────────────
# PROMTOOL ANSWERS FOR THE MASTER'S PROMETHEUS ONLY AT ITS VERSION, which is read from the render
# the tests run over and is pinned nowhere else. A chart upgrade that moves Prometheus turns this
# red until promtool follows it.
prometheus_version="$(yq eval-all -N 'select(.kind == "Prometheus") | .spec.version' "$work"/rules/*/*/render | sed 's/^v//; s/-.*//' | sort -u)"
promtool_version="$(promtool --version | sed -n '1s/^promtool, version \([^ ]*\).*/\1/p')"
[ -n "$prometheus_version" ] && [ "$promtool_version" = "$prometheus_version" ] \
  || fail "promtool is ${promtool_version:-of a version it does not state}, and the master's Prometheus runs ${prometheus_version:-at a version no render states}"
echo "check: promtool $promtool_version, the version of the master's Prometheus."

# promtool names a failing test case by its expression and time; the test group it stands in is
# named only in its JUnit report.
while read -r test_chart test_stage; do
  [ -n "$test_chart" ] || continue
  test_dir="$work/rules/$(basename "$test_chart")/$test_stage"
  if ! out="$(cd "$test_dir" && promtool test rules --junit=junit.xml rules.test.yaml 2>&1)"; then
    echo "$out"
    failing_groups="$(yq -p xml -oy '.. | select(has("failure")) | "  " + ."+@name"' "$test_dir/junit.xml")"
    [ -n "$failing_groups" ] && printf 'These test groups of %s/rules.test.yaml fail at stage %s:\n%s\n' "$test_chart" "$test_stage" "$failing_groups"
    fail "the rule test $test_chart/rules.test.yaml fails at stage $test_stage"
  fi
  echo "check: the rule test $test_chart/rules.test.yaml passes at stage $test_stage."
done <<< "$rule_tests"

# THE PLANTED DEFECT is the join across clusters the test was written for: the dev rules run once
# more with cluster taken out of PodNotReady's `on (cluster, namespace, pod)`, and that run fails.
planted="$work/rules-planted"
cp -R "$work/rules/observability/dev" "$planted" \
  || fail "the planted run of the rule test needs the rules of observability at stage dev"
planted_rules="$(grep -l 'alert: PodNotReady' "$planted"/rule-*.yml)" \
  && yq -i '(.groups[].rules[] | select(.alert == "PodNotReady") | .expr) |= sub("on [(]cluster, namespace, pod[)]"; "on (namespace, pod)")' "$planted_rules" \
  || fail "PodNotReady could not be planted with cluster taken out of its on list"
if (cd "$planted" && promtool test rules rules.test.yaml >/dev/null 2>&1); then
  fail "the rule test clusters/inventories/observability/rules.test.yaml passes at stage dev with cluster taken out of PodNotReady's on (cluster, namespace, pod), so it cannot catch a join across clusters, or PodNotReady carries that on list no more"
fi
echo "check: the rule test goes red at stage dev with cluster taken out of PodNotReady's on (cluster, namespace, pod)."

# THE PLANTED DEFECTS OF THE PIPELINERUN ALERTS are the two shapes of a wrong join between the start series and the
# completion series: cluster taken out of the `on` list, which lets a run of another cluster that carries the same
# name hide a run that has not completed, and the `unless` clause taken out, which alerts on a run that completed. The
# dev rules of tekton and image-builder run once more with each, and each run fails.
for planted_chart in tekton image-builder; do
  for planted_defect in "cluster taken out of the on list of PipelineRunRunningTooLong" "the unless clause taken out of PipelineRunRunningTooLong"; do
    planted="$work/rules-planted-$planted_chart"
    rm -rf "$planted"
    cp -R "$work/rules/$planted_chart/dev" "$planted" \
      || fail "the planted run of the rule test needs the rules of $planted_chart at stage dev"
    planted_rules="$(grep -l 'alert: PipelineRunRunningTooLong' "$planted"/rule-*.yml)" \
      || fail "the rules of $planted_chart at stage dev carry no PipelineRunRunningTooLong to plant a defect in"
    case "$planted_defect" in
      cluster*) yq -i '(.groups[].rules[] | select(.alert == "PipelineRunRunningTooLong") | .expr) |= sub("on [(]cluster, namespace, pipelinerun[)]"; "on (namespace, pipelinerun)")' "$planted_rules" ;;
      *) yq -i '(.groups[].rules[] | select(.alert == "PipelineRunRunningTooLong") | .expr) |= "time() - tekton_pipelinerun_start_timestamp_seconds > 1800"' "$planted_rules" ;;
    esac \
      || fail "PipelineRunRunningTooLong of $planted_chart could not be planted with $planted_defect"
    if (cd "$planted" && promtool test rules rules.test.yaml >/dev/null 2>&1); then
      fail "the rule test clusters/inventories/$planted_chart/rules.test.yaml passes at stage dev with $planted_defect, so it cannot catch that join, or the alert is not written the way the plant expects"
    fi
    echo "check: the rule test of $planted_chart goes red at stage dev with $planted_defect."
  done
done

# ── clusters/argocd as ArgoCD is handed it: the cluster map ALONE ────────────────────────────
# THE LOOP ABOVE RENDERS IT WITH THE PLATFORM CHAIN, AND NO CLUSTER EVER DOES. clusters/argocd is
# the one chart of this repository whose whole values chain is a single file:
# clusters/argocd/root-app.yaml and clusters/slaves/slave/templates/root-application.yaml both name
# $values/clusters/active/<fqdn>.yaml and the parameter `revision`, which the stand-in registration
# answers here, and nothing else. So `global:` reaches this chart
# from the cluster map or from nowhere, while every other chart is handed
# clusters/platform/values-common.yaml first and can never see the block missing.
#
# THE OLD MAP SHAPE IS DERIVED FROM THE STAND-IN, NOT WRITTEN OUT. A cluster map made before the
# block existed carries its values flat at the top level, which is the stand-in with everything
# from its `global:` line onward cut off. Deriving it means the two shapes cannot drift apart and
# there is no third stand-in document to keep in step.
echo "check: clusters/argocd from the cluster map alone, the way its root Application is handed it."
if ! helm template argocd-apps clusters/argocd -f "$cluster_map" --set "revision=$handed_revision" > "$work/argocd-alone" 2>&1; then
  cat "$work/argocd-alone"
  fail "clusters/argocd does not render from the cluster map alone, which is the only chain it ever gets"
fi

refusal_said='the cluster map states no global: block'
awk '/^global:/ { exit } { print }' "$cluster_map" > "$work/map-without-global"
refused="$(helm template argocd-apps clusters/argocd -f "$work/map-without-global" --set "revision=$handed_revision" 2>&1)"
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

argocd_off_revision="$(sources_off_revision 'clusters/argocd from the cluster map alone' "$work/argocd-alone" "$handed_revision")"
if [ -n "$argocd_off_revision" ]; then
  echo "These name this repository at another revision than the one their root Application synced, so they can reach a commit before its AppProjects:$argocd_off_revision"
  fail "a source or a generator of clusters/argocd names this repository off the handed revision"
fi
echo "check: every source and generator of this repository in clusters/argocd stands at the handed revision."

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
# never the name a roleRef or a subject repeats further down. The stage-bound seven carry the
# stand-in's stage in their name — a unit's fences are per (unit, stage), and the two build grants
# are the stage-free ones.
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
fences_expected='AppProject/check-dev
Role/check-dev-argo-sync
Role/eventlistener-create-pipelineruns
Role/manager-read-pipelineruns
RoleBinding/check-dev-argo-sync
RoleBinding/eventlistener-create-pipelineruns
RoleBinding/manager-read-pipelineruns
ValidatingAdmissionPolicy/consumer-check-dev
ValidatingAdmissionPolicyBinding/consumer-check-dev'
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
  --set-json 'unit={"name":"check","repoURL":"https://github.com/check/check.git","buildsJson":"[\"check\"]"}' \
  > "$work/fence-render" 2>&1 \
  || { cat "$work/fence-render"; fail "clusters/inventories/consumer-build does not render in unit mode, which is where a unit's build grants stand"; }
# The build's .npmrc reads no npm package from GitHub Packages: no line names npm.pkg.github.com, and the
# ExternalSecret reads no `packages` property of the unit's build entry, which the Manager writes no more
# (templates/externalsecret-npmrc.yaml).
npmrc_secret="$(yq e 'select(.kind == "ExternalSecret" and .metadata.name == "build-npmrc")' "$work/fence-render")"
[ -n "$npmrc_secret" ] || fail "unit check renders no ExternalSecret build-npmrc"
for gone in 'npm.pkg.github.com' '{{ .packages }}' 'secretKey: packages' 'property: packages'; do
  if printf '%s\n' "$npmrc_secret" | grep -qF -- "$gone"; then
    printf '%s\n' "$npmrc_secret" | grep -nF -- "$gone"
    fail "the build .npmrc of unit check still carries '$gone' — the npm packages are read from this build plane's registry alone"
  fi
done
# The same .npmrc reads the npm packages this build plane publishes (templates/pipeline-publish.yaml), which a
# lockfile names by their tarball URL under the registry's npm prefix, with the registry's pull identity.
grep -qE '^ +//[a-z0-9.-]+/v2/npm/:_auth=\{\{ printf "%s:%s" \.pullUser \.pullPassword \| b64enc \}\}$' "$work/fence-render" \
  && grep -qF 'secretKey: pullUser' "$work/fence-render" && grep -qF 'secretKey: pullPassword' "$work/fence-render" \
  || { grep -A4 -F '.npmrc: |' "$work/fence-render"; fail "the build .npmrc of unit check does not read the registry's npm prefix with its pull identity — a lockfile that names a package published here would answer 401"; }
# A unit that builds nothing still publishes its npm packages: it renders the publish pipeline and the push identity
# its push task mounts, and still no pull identity, which only a release reads.
helm template consumer-build clusters/inventories/consumer-build --namespace argocd --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
  -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
  -f clusters/inventories/consumer-build/values-common.yaml -f "$cluster_map" -f "$registration" \
  --set-json 'unit={"name":"check","repoURL":"https://github.com/check/check.git","buildsJson":"[]"}' \
  > "$work/publish-render" 2>&1 \
  || { cat "$work/publish-render"; fail "clusters/inventories/consumer-build does not render a unit that builds nothing"; }
publish_objects="$(objects_of "$work/publish-render")"
for object in Pipeline/check-publish ExternalSecret/image-builder-registry-push; do
  printf '%s\n' "$publish_objects" | grep -qxF "$object" \
    || fail "a unit that builds nothing renders no $object — its release tag would publish no npm package"
done
printf '%s\n' "$publish_objects" | grep -q '^ExternalSecret/image-builder-registry-pull' \
  && fail "a unit that builds nothing renders the registry pull identity, which only a release reads"

# ── The tools of this repository's own ci run ────────────────────────────────────────────────
# ci-tools.json names the tools the ci of the master installs before it runs this file and then scripts/test.sh
# (clusters/inventories/consumer-build/templates/pipeline-ci.yaml). Each pair has to be a row of the table
# that pipeline installs from, or the run ends on the build plane before the check starts, so it is refused here.
# The promtool of the run is the one the master's Prometheus needs, as the one on this machine is above.
tools_table=clusters/inventories/consumer-build/files/ci-tools.table
tools_named="$(yq -p=json -o=yaml e 'to_entries | .[] | .key + " " + .value' ci-tools.json)" \
  || fail "ci-tools.json does not parse as an object of tools and versions"
[ -n "$tools_named" ] || fail "ci-tools.json names no tool, so the ci run of this repository would have no gitleaks and no promtool"
tools_rows="$(awk '{ print $1, $2 }' "$tools_table")"
while IFS= read -r pair; do
  printf '%s\n' "$tools_rows" | grep -qxF "$pair" \
    || fail "ci-tools.json names $pair, which $tools_table does not carry, so the ci run of this repository would end before its check"
done <<< "$tools_named"
printf '%s\n' "$tools_named" | grep -qxF "promtool $prometheus_version" \
  || fail "ci-tools.json does not name promtool $prometheus_version, the version of the master's Prometheus, so the ci run would test its rules with another one"
[ "$(yq e 'select(.kind == "Pipeline" and .metadata.name == "check-ci") | .spec.tasks[] | select(.name == "check") | .taskSpec.steps[0].env[] | select(.name == "CI_TOOLS_TABLE") | .value' "$work/publish-render")" = "$(cat "$tools_table")" ] \
  || fail "the ci pipeline of a unit does not hand its check the table $tools_table, whole"
echo "check: ci-tools.json names $(printf '%s\n' "$tools_named" | wc -l) tools, each a row of $tools_table, and the ci pipeline renders that table."
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

# ── The npm packages a release tag publishes ─────────────────────────────────────────────────
# A push of the release tag itself starts the unit's publish pipeline through the Trigger github-release-publish of
# clusters/inventories/image-builder, and the registry keeps every version that pipeline pushes: zot applies the
# FIRST retention policy whose repositories match a repo, and only the first one keeps every tag, so npm/** must be
# named there and not left to the ["**"] policy of the docker.io cache, which keeps the newest 50.
helm template image-builder clusters/inventories/image-builder --namespace image-builder \
  -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
  -f clusters/inventories/image-builder/values-common.yaml -f clusters/inventories/image-builder/values-dev.yaml -f "$cluster_map" -f "$registration" \
  > "$work/builder-render" 2>&1 \
  || { cat "$work/builder-render"; fail "clusters/inventories/image-builder does not render"; }
for object in Trigger/github-release-publish TriggerBinding/github-release-publish-binding TriggerTemplate/release-publish; do
  objects_of "$work/builder-render" | grep -qxF "$object" || fail "clusters/inventories/image-builder renders no $object — a release tag would publish nothing"
done
grep -qF -- '- triggerRef: github-release-publish' "$work/builder-render" || fail "the EventListener does not attach github-release-publish"
grep -qF -- "body.ref.matches(r'^refs/tags/$(yq '.global.releaseTagFilter' clusters/platform/values-common.yaml)\$')" "$work/builder-render" \
  || fail "the publish trigger does not take the release tag in the grammar of global.releaseTagFilter, anchored"
first_retention="$(yq '.configmap.configmap.data."config.json"' clusters/inventories/registry/values-common.yaml | grep -m1 -F '"repositories": [')"
case "$first_retention" in
  *'["*", "npm/**", "simetrixch/**"]'*) ;;
  *) fail "the first retention policy of the registry names $first_retention — a version under npm/** or simetrixch/** would be deleted once 50 newer tags are pushed" ;;
esac
echo "check: a release tag starts the publish pipeline of a unit, with builds or without, and the registry keeps every tag under npm/** and simetrixch/**."

# ── The platform's own images: where they are pushed and who may read them ───────────────────
# Every other installation, and the relocation Jobs on the app clusters, pull the platform's own images
# from the owner's registry without a credential, so zot opens exactly the owner's prefix to anonymous
# read and nothing else, and fetches nothing from ghcr.io: a tag missing there fails, it is never pulled
# through from GitHub. The release
# pipeline pushes there only the builds of global.buildRegistryUnit, and only on the installation whose
# registry IS global.buildRegistry; every other build stays flat, because the readers of a unit's image
# (its chart, the Manager's tenant versions, the reaper) compose the flat path.
repository_policy() { # $1 the zot config.json, $2 a repositories key, $3 its field. A quoted regex, because yq reads a "*" in a key or in == as a glob.
  yq -p=json -o=json -I=0 ".http.accessControl.repositories | to_entries[] | select(.key | test(\"^\\\\Q$2\\\\E\$\")) | .value.$3" "$1"
}
go_duration_seconds() { # $1 a Go duration such as 30m, 1h30m or 1m0s -> its whole seconds, or nothing when it is not one; zot decodes http.writeTimeout with time.ParseDuration
  awk -v text="$1" 'BEGIN {
    rest = text; total = 0
    if (rest == "") exit
    while (rest != "") {
      if (!match(rest, /^[0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h)/)) exit
      part = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
      unit = part; sub(/^[0-9.]+/, "", unit); sub(/(ns|us|ms|s|m|h)$/, "", part)
      scale = (unit == "h") ? 3600 : (unit == "m") ? 60 : (unit == "s") ? 1 : (unit == "ms") ? 0.001 : (unit == "us") ? 0.000001 : 0.000000001
      total += part * scale
    }
    printf "%d\n", total
  }'
}
zot_fault() { # $1 the zot config.json -> the first way it differs from the access this platform needs, or nothing
  local open
  open="$(yq -p=json -o=json -I=0 '.http.accessControl.repositories | keys' "$1")"
  [ "$open" = '["**","simetrixch/**"]' ] || { echo "the repositories of accessControl are $open, not ** and simetrixch/**"; return; }
  [ "$(repository_policy "$1" '**' anonymousPolicy)" = '[]' ] \
    || { echo "every repository is open to an anonymous read, not simetrixch/** alone"; return; }
  [ "$(repository_policy "$1" 'simetrixch/**' anonymousPolicy)" = '["read"]' ] \
    || { echo "simetrixch/** is not open to an anonymous read, so another installation pulls the platform's images with no credential and gets 401"; return; }
  [ "$(repository_policy "$1" 'simetrixch/**' policies)" = "$(repository_policy "$1" '**' policies)" ] \
    || { echo "simetrixch/** grants the push and pull users other actions than **, and zot takes the longest matching pattern alone"; return; }
  [ "$(yq -p=json -o=json -I=0 '.http.compat' "$1")" = '["docker2s2"]' ] \
    || { echo "zot refuses a Docker v2 schema 2 manifest, so the mirror cannot hold an upstream image of that media type at the digest its consumers pin"; return; }
  [ "$(yq -p=json -o=json -I=0 '[.extensions.sync.registries[].urls[]] | map(select(test("ghcr\\.io"))) | length' "$1")" = 0 ] \
    || { echo "zot still fetches from ghcr.io on a miss, so a platform image it lacks is pulled through from GitHub instead of failing"; return; }
  local write_timeout seconds
  write_timeout="$(yq -p=json -o=yaml '.http.writeTimeout' "$1")"
  seconds="$(go_duration_seconds "$write_timeout")"
  [ -n "$seconds" ] && [ "$seconds" -ge 1800 ] \
    || echo "zot ends a response that is still being written after http.writeTimeout ($write_timeout; its default is 60 seconds), so eight clusters fetching one large pinned tool at once are cut part-way (curl 92); it must be a Go duration of at least 30 minutes"
}
helm template registry clusters/inventories/registry --namespace registry \
  -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
  -f clusters/inventories/registry/values-common.yaml -f clusters/inventories/registry/values-dev.yaml -f "$cluster_map" -f "$registration" \
  > "$work/registry-render" 2>&1 \
  || { cat "$work/registry-render"; fail "clusters/inventories/registry does not render"; }
yq 'select(.kind == "ConfigMap" and .metadata.name == "zot-config") | .data."config.json"' "$work/registry-render" > "$work/zot.json"
fault="$(zot_fault "$work/zot.json")"
[ -z "$fault" ] || fail "the registry's zot config: $fault"
# The planted defects: every repository open to an anonymous read, the seed storing flat, and no Docker v2 schema 2.
yq -p=json -o=json '(.http.accessControl.repositories[] | .anonymousPolicy) = ["read"]' "$work/zot.json" > "$work/zot-planted.json"
[ -n "$(zot_fault "$work/zot-planted.json")" ] || fail "zot_fault takes a zot that lets anyone read every repository"
yq -p=json -o=json '.extensions.sync.registries = [{"urls": ["https://ghcr.io"], "onDemand": true, "content": [{"prefix": "/simetrixch/*", "destination": "/simetrixch", "stripPrefix": true}]}] + .extensions.sync.registries' "$work/zot.json" > "$work/zot-planted.json"
[ -n "$(zot_fault "$work/zot-planted.json")" ] || fail "zot_fault takes a zot that still fetches from ghcr.io"
yq -p=json -o=json 'del(.http.compat)' "$work/zot.json" > "$work/zot-planted.json"
[ -n "$(zot_fault "$work/zot-planted.json")" ] || fail "zot_fault takes a zot that refuses Docker v2 schema 2 manifests"
yq -p=json -o=json 'del(.http.writeTimeout)' "$work/zot.json" > "$work/zot-planted.json"
[ -n "$(zot_fault "$work/zot-planted.json")" ] || fail "zot_fault takes a zot that ends every response after its default 60 seconds"
for short in 60s 1m 1m0s 59s 5m 29m59s 1799s 0; do
  yq -p=json -o=json ".http.writeTimeout = \"$short\"" "$work/zot.json" > "$work/zot-planted.json"
  [ -n "$(zot_fault "$work/zot-planted.json")" ] || fail "zot_fault takes a zot whose write timeout is $short, shorter than 30 minutes"
done
yq -p=json -o=json '.http.writeTimeout = 60' "$work/zot.json" > "$work/zot-planted.json"
[ -n "$(zot_fault "$work/zot-planted.json")" ] || fail "zot_fault takes a zot whose write timeout is a bare number, not a duration"
# The planted innocent: buildRegistry naming the owner's own registry keeps the owner's prefix.
helm template registry clusters/inventories/registry --namespace registry \
  -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
  -f clusters/inventories/registry/values-common.yaml -f clusters/inventories/registry/values-dev.yaml -f "$cluster_map" -f "$registration" \
  --set global.buildRegistry=zot.master.digitacloud.app/simetrixch \
  | yq 'select(.kind == "ConfigMap" and .metadata.name == "zot-config") | .data."config.json"' > "$work/zot-planted.json"
fault="$(zot_fault "$work/zot-planted.json")"
[ -z "$fault" ] || fail "the planted innocent, buildRegistry at the owner's own registry, is refused: $fault"
for long in 30m 1h 1h0m0s 1800s 31m 90m; do
  yq -p=json -o=json ".http.writeTimeout = \"$long\"" "$work/zot.json" > "$work/zot-planted.json"
  fault="$(zot_fault "$work/zot-planted.json")"
  [ -z "$fault" ] || fail "the planted innocent, a write timeout of $long, is refused: $fault"
done
echo "check: zot opens simetrixch/** alone to an anonymous read, takes Docker v2 schema 2 manifests as they are and fetches nothing from ghcr.io; ends no response before 30 minutes; the check refuses the planted defects and takes the planted innocent."

# ── The pod of zot rolls when the config.json it was started with is not the one the ConfigMap holds ─
# zot loads its config at start and never again, and a ConfigMap mount that follows an edit does not
# restart it: a new accessControl or sync stays unread, and every request is answered by the old rules,
# until the pod template changes. The pod template carries hostyour.cloud/config-revision for that, and
# only this check ties it to the config, so the revision is not a string somebody remembers to bump: it
# is "config-" and the first 12 hex digits of the git hash of the config.json that every stage renders,
# and a render whose revision is any other value is refused with the value to set. A checksum written by
# the chart would need no check, but the pod and the ConfigMap come from two library charts, and a chart
# reads its own values and `global` alone, so the deployment cannot see what its sibling renders.
render_registry_stages() { # extra helm arguments -> $work/registry-<stage>-render for every stage
  local stage
  for stage in $stages; do
    helm template registry clusters/inventories/registry --namespace registry \
      -f clusters/platform/values-common.yaml -f "clusters/platform/values-$stage.yaml" \
      -f clusters/inventories/registry/values-common.yaml -f "clusters/inventories/registry/values-$stage.yaml" -f "$cluster_map" -f "$registration" "$@" \
      > "$work/registry-$stage-render" 2>&1 \
      || { cat "$work/registry-$stage-render"; fail "clusters/inventories/registry does not render at stage $stage"; }
  done
}
zot_revision_fault() { # -> the first way the revision of the zot pod does not name the config.json of $work/registry-<stage>-render, or nothing
  local stage render named="" wanted carried
  for stage in $stages; do
    named="$named$(yq 'select(.kind == "ConfigMap" and .metadata.name == "zot-config") | .data."config.json"' "$work/registry-$stage-render")"
  done
  wanted="config-$(printf '%s' "$named" | git hash-object --stdin | cut -c1-12)"
  for stage in $stages; do
    render="$work/registry-$stage-render"
    carried="$(yq 'select(.kind == "Deployment") | .spec.template.metadata.annotations."hostyour.cloud/config-revision"' "$render")"
    [ "$carried" = "$wanted" ] \
      || { echo "the zot pod of stage $stage carries config-revision $carried, and the config.json of the registry is named $wanted — zot reads that file at start only, so the pod keeps the old access rules until hostyour.cloud/config-revision in clusters/inventories/registry/values-common.yaml is set to $wanted"; return; }
  done
}
render_registry_stages
fault="$(zot_revision_fault)"
[ -z "$fault" ] || fail "$fault"
# The planted defects: a config.json that changed under the revision it had, and a revision written by hand.
render_registry_stages --set-string global.registryPullUser=planted-pull
[ -n "$(zot_revision_fault)" ] || fail "zot_revision_fault takes a config.json that changed while the revision stayed"
render_registry_stages --set-string 'app.podAnnotations.hostyour\.cloud/config-revision=metrics-acl-grants-the-pull-user'
[ -n "$(zot_revision_fault)" ] || fail "zot_revision_fault takes a revision that no config.json names"
# The planted innocent: a change that does not reach config.json leaves the pod where it is.
render_registry_stages --set app.replicas=2 --set-string pvc.pvc.storageSize=60Gi
fault="$(zot_revision_fault)"
[ -z "$fault" ] || fail "the planted innocent, a replica count and a volume size outside config.json, is refused: $fault"
echo "check: the zot pod rolls with the config.json of every stage; the check refuses a changed config under an old revision and a revision no config names, and takes a change outside config.json."

# ── The images the owner's mirror holds ─────────────────────────────────────────────────────────
# scripts/list-mirror-images.sh lists every image the tree names on ghcr.io or under a mirror of it, for
# the `mirror` task of the platform's publish run and for the release that waits on it. An entry is one
# digest under its tag, so a ref without its digest has none and fails the list, and the release with it.
mirror_refs="$(bash scripts/list-mirror-images.sh --rendered)" || fail "scripts/list-mirror-images.sh cannot render the tree"
mirror_entries="$(printf '%s\n' "$mirror_refs" | bash scripts/list-mirror-images.sh --entries 2>&1)" \
  || fail "an image the mirror must hold has no entry: $mirror_entries"
mirror_prefix="$(yq '.global.buildRegistry' clusters/platform/values-common.yaml)/ghcr.io"
# The planted defects: a ref on ghcr.io and a ref under the mirror, each without its digest.
printf 'ghcr.io/planted/image:1.0.0 planted\n' | bash scripts/list-mirror-images.sh --entries >/dev/null 2>&1 \
  && fail "scripts/list-mirror-images.sh lists a ref on ghcr.io that names no digest"
printf '%s/planted/image:1.0.0 planted\n' "$mirror_prefix" | bash scripts/list-mirror-images.sh --entries >/dev/null 2>&1 \
  && fail "scripts/list-mirror-images.sh lists a ref under the mirror that names no digest"
echo "check: the mirror holds $(printf '%s\n' "$mirror_entries" | wc -l | tr -d ' ') images, each at its digest; the list refuses a planted ref on ghcr.io and one under the mirror without it."

# ── The tools and charts the owner's mirror holds ───────────────────────────────────────────────
# scripts/list-mirror-sources.sh writes one line per row of clusters/platform/mirror-sources.table for the
# steps fetch, copy-sources and read-back-sources of the mirror task, and refuses a row of another form by
# its line number. The planted defects: a tool row without its url, and a chart pinned at a version no row holds,
# which --chart refuses by naming it; the innocent case is the chart the pin of versions.yaml names, found below.
mirror_sources="$(bash scripts/list-mirror-sources.sh)" || fail "scripts/list-mirror-sources.sh refuses clusters/platform/mirror-sources.table"
printf 'tool %s\n' "$(printf '0%.0s' {1..64})" > "$work/planted-mirror-sources.table"
bash scripts/list-mirror-sources.sh "$work/planted-mirror-sources.table" >/dev/null 2>&1 \
  && fail "scripts/list-mirror-sources.sh lists a planted tool row without its url"
out="$(bash scripts/list-mirror-sources.sh --chart headlamp 0.0.0 2>&1)" \
  && fail "scripts/list-mirror-sources.sh --chart gives an address for a headlamp version no row holds"
case "$out" in *"the chart headlamp at 0.0.0"*) ;; *) fail "scripts/list-mirror-sources.sh --chart does not name the chart and the version it has no row for: $out" ;; esac
echo "check: the mirror holds $(printf '%s\n' "$mirror_sources" | grep -c '^tool ') tools and $(printf '%s\n' "$mirror_sources" | grep -c '^chart ') charts of the $(printf '%s\n' "$mirror_sources" | grep -c .) rows of clusters/platform/mirror-sources.table, each at its sha256; the list refuses a planted tool row without its url and a chart at a version no row holds."

# NO REF IS PULLED FROM ghcr.io. Every image of the list is pulled from the mirror, the registry's own zot, External
# Secrets, Tekton with the helpers its controllers inject, headscale, Authentik, Dex and Headlamp included: a cold
# owner's master starts those from the images lifecycle/driver.sh imports into its node before Argo CD or zot
# stand, and every other cluster pulls them from the owner's zot.
ghcr_pull_fault() { # "<ref> [<where>]" lines on standard input -> the first ref pulled from ghcr.io, or nothing
  grep -E '^ghcr\.io/' | head -n 1
}
fault="$(printf '%s\n' "$mirror_refs" | ghcr_pull_fault)"
[ -z "$fault" ] || fail "$fault is pulled from ghcr.io, and the mirror serves it under $mirror_prefix"
inventory_refs() { # <app> <extra helm arguments...> -> the refs of clusters/inventories/<app> at stage dev
  local app="$1" values=()
  shift
  [ -f "clusters/inventories/$app/values-dev.yaml" ] && values=(-f "clusters/inventories/$app/values-dev.yaml")
  helm template "$app" "clusters/inventories/$app" --namespace "$app" --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
    -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
    -f "clusters/inventories/$app/values-common.yaml" "${values[@]}" \
    -f "$installation_values" -f "$cluster_map" -f "$registration" "$@" > "$work/$app-render" 2>&1 \
    || { cat "$work/$app-render"; fail "clusters/inventories/$app does not render at stage dev"; }
  bash scripts/list-mirror-images.sh --refs < "$work/$app-render"
}
# The planted defects: the admission Jobs' override dropped back to the chart's registry, zot's own image back on
# ghcr.io, a Tekton controller that injects its entrypoint image from ghcr.io, and the access-log exporter under a
# mirror name that is not the trunk's.
[ -n "$(inventory_refs observability --set kube-prometheus-stack.prometheusOperator.admissionWebhooks.patch.image.registry=ghcr.io | ghcr_pull_fault)" ] \
  || fail "ghcr_pull_fault takes the admission Jobs' image pulled from ghcr.io"
[ -n "$(inventory_refs registry --set app.image.repository=ghcr.io/project-zot/zot-linux-amd64 | ghcr_pull_fault)" ] \
  || fail "ghcr_pull_fault takes zot's own image pulled from ghcr.io"
[ -z "$(inventory_refs tekton | ghcr_pull_fault)" ] || fail "the tekton chart pulls from ghcr.io on the trunk"
rm -rf "$work/planted-tekton" && cp -R clusters/inventories/tekton "$work/planted-tekton" \
  || fail "clusters/inventories/tekton could not be copied to plant a defect in it"
sed -i "s|\"-entrypoint-image\", '{{ include \"common.buildRegistry\" [$] }}/ghcr.io/|\"-entrypoint-image\", 'ghcr.io/|" "$work/planted-tekton/templates/release-pipelines.yaml"
cmp -s "$work/planted-tekton/templates/release-pipelines.yaml" clusters/inventories/tekton/templates/release-pipelines.yaml \
  && fail "the planted entrypoint image was not planted in a copy of clusters/inventories/tekton/templates/release-pipelines.yaml"
helm template tekton "$work/planted-tekton" --namespace tekton-pipelines --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
  -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml -f clusters/inventories/tekton/values-common.yaml \
  -f "$installation_values" -f "$cluster_map" -f "$registration" > "$work/planted-tekton-render" 2>&1 \
  || { cat "$work/planted-tekton-render"; fail "the planted copy of clusters/inventories/tekton does not render at stage dev"; }
[ -n "$(bash scripts/list-mirror-images.sh --refs < "$work/planted-tekton-render" | ghcr_pull_fault)" ] \
  || fail "ghcr_pull_fault takes a Tekton controller that injects its entrypoint image from ghcr.io"
inventory_refs observability --set loki.gateway.metrics.image.registry=zot.old.example.invalid/simetrixch/ghcr.io \
  | bash scripts/list-mirror-images.sh --entries >/dev/null 2>&1 \
  && fail "scripts/list-mirror-images.sh lists the access-log exporter under a mirror name that is not $mirror_prefix"
echo "check: no rendered ref is pulled from ghcr.io; the check refuses a planted pull from ghcr.io of the admission Jobs, of zot itself and of an image a Tekton controller injects, and a planted stale mirror name."

# ZOT'S NEXT IMAGE IS PULLED BY A PreSync HOOK while the old zot serves it (clusters/inventories/registry/templates/
# zot-image-hook.yaml): the hook runs exactly the Deployment's image, neither pulls Always, and the hook is
# recreated before each sync, which keeps its last pod readable. The planted defects: a hook with another image,
# no hook, and a pull Always. The innocent case is the trunk render.
zot_hook_fault() { # <a render of the registry chart> -> what is wrong, or nothing
  local deployed hooked policies
  deployed="$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$1")"
  hooked="$(yq -N 'select(.kind == "Job" and .metadata.annotations["argocd.argoproj.io/hook"] == "PreSync") | .spec.template.spec.containers[0].image' "$1")"
  policies="$(yq -N 'select(.kind == "Job" or .kind == "Deployment") | .spec.template.spec.containers[0].imagePullPolicy' "$1" | sort -u)"
  [ "$(printf "%s\n" "$deployed" | grep -c .)" = 1 ] || { echo "the registry renders $(printf "%s\n" "$deployed" | grep -c .) Deployments, and it runs zot in one"; return; }
  [ -n "$hooked" ] || { echo "the registry renders no PreSync Job that pulls zot's next image while the old zot serves"; return; }
  [ "$hooked" = "$deployed" ] || { echo "the PreSync Job pulls $hooked, and the Deployment runs $deployed"; return; }
  [ "$policies" = IfNotPresent ] || { echo "zot or its PreSync Job pulls $(printf '%s' "$policies" | tr '\n' ' '), and a pod that pulls Always asks the zot it replaces"; return; }
  [ "$(yq -N 'select(.kind == "Job") | .metadata.annotations["argocd.argoproj.io/hook-delete-policy"]' "$1")" = BeforeHookCreation ] \
    || echo "the PreSync Job of zot is not deleted BeforeHookCreation"
}
inventory_refs registry > /dev/null
cp "$work/registry-render" "$work/registry-trunk-render"
fault="$(zot_hook_fault "$work/registry-trunk-render")"
[ -z "$fault" ] || fail "$fault"
yq 'select(.kind == "Job").spec.template.spec.containers[0].image |= sub("@sha256:", "-planted@sha256:")' "$work/registry-trunk-render" > "$work/registry-planted"
[ -n "$(zot_hook_fault "$work/registry-planted")" ] || fail "zot_hook_fault takes a PreSync Job that pulls another image than zot runs"
yq 'select(.kind != "Job")' "$work/registry-trunk-render" > "$work/registry-planted"
[ -n "$(zot_hook_fault "$work/registry-planted")" ] || fail "zot_hook_fault takes a registry without its PreSync Job"
inventory_refs registry --set app.image.pullPolicy=Always > /dev/null
[ -n "$(zot_hook_fault "$work/registry-render")" ] || fail "zot_hook_fault takes zot pulled Always"
echo "check: zot's next image is pulled by a PreSync Job that runs exactly the Deployment's image, IfNotPresent; the check refuses a planted other image, a missing hook and a pull Always."

# NOTHING A COLD OWNER'S MASTER STARTS BEFORE ZOT ANSWERS PULLS Always. External Secrets, Tekton and zot start
# from the images lifecycle/driver.sh imports into the node, and a pull Always would ask the zot that is not up.
# The planted defect: External Secrets pulled Always. The innocent case is the trunk render.
always_pull_fault() { # <a render> -> the first container that pulls Always, or nothing
  yq -N '.. | select(tag == "!!map" and .imagePullPolicy == "Always") | .name' "$1" | head -n 1
}
for app in external-secrets tekton registry; do
  inventory_refs "$app" > /dev/null
  fault="$(always_pull_fault "$work/$app-render")"
  [ -z "$fault" ] || fail "the container $fault of clusters/inventories/$app pulls Always, and a cold owner's master starts it from the node's image before zot answers"
done
inventory_refs external-secrets --set external-secrets.image.pullPolicy=Always > /dev/null
[ -n "$(always_pull_fault "$work/external-secrets-render")" ] || fail "always_pull_fault takes External Secrets pulled Always"
echo "check: no container of external-secrets, tekton or registry pulls Always; the check refuses a planted External Secrets pulled Always."

# WHERE A CHART HAS NO FIELD FOR A DIGEST, the digest rides on the tag of an override, and the override then
# names the tag as well. Each such tag is held to the one its chart names, so a bump of the chart cannot
# leave its image behind at the old one.
pinned_tag_fault() { # <what> <the chart's own tag> <values file> <yq path of the override> -> what is wrong, or nothing
  local pinned
  pinned="$(yq "$4" "$3")"
  [ "${pinned%%@*}" = "$2" ] || echo "$1 is pinned at ${pinned%%@*} in $3 ($4), and its chart names $2"
}
headlamp_version="$(yq '.bootstrap.headlamp.version' clusters/platform/versions.yaml)"
headlamp_address="$(bash scripts/list-mirror-sources.sh --chart headlamp "$headlamp_version")" \
  || fail "clusters/platform/versions.yaml pins the headlamp chart at $headlamp_version, and clusters/platform/mirror-sources.table has no row for it"
headlamp_app="$(helm show chart "$headlamp_address/headlamp" --version "$headlamp_version" | yq '.appVersion')" \
  || fail "the headlamp chart clusters/platform/versions.yaml pins could not be read from $headlamp_address"
pinned_tags=(
  "the master's Dex|$(helm show values "$argo_chart" | yq '.dex.image.tag')|clusters/bootstrap/argocd/values.tpl|.dex.image.tag"
  "Headlamp|v$headlamp_app|clusters/bootstrap/headlamp/values.tpl|.image.tag"
  "the External Secrets controller|$(helm show chart clusters/inventories/external-secrets/charts/external-secrets-*.tgz | yq '.appVersion')|clusters/inventories/external-secrets/values-common.yaml|.external-secrets.image.tag"
  "the Loki gateway's access-log exporter|$(helm show values clusters/inventories/observability/charts/loki-*.tgz | yq '.gateway.metrics.image.tag')|clusters/inventories/observability/values-common.yaml|.loki.gateway.metrics.image.tag"
)
for row in "${pinned_tags[@]}"; do
  IFS='|' read -r what chart_tag file path <<< "$row"
  fault="$(pinned_tag_fault "$what" "$chart_tag" "$file" "$path")"
  [ -z "$fault" ] || fail "$fault — write the chart's tag with the digest it names there"
done
# The planted defect: a chart that names another tag than the override.
[ -n "$(pinned_tag_fault Headlamp v0.0.0-planted clusters/bootstrap/headlamp/values.tpl .image.tag)" ] \
  || fail "pinned_tag_fault takes an override whose tag its chart no longer names"
echo "check: ${#pinned_tags[@]} overrides carry a digest on their chart's own tag; the check refuses a planted chart that names another."

# HEADLAMP IS GIVEN ITS OIDC SCOPES ONLY WHERE THE VALUES SAY THE EXTERNAL SECRET HAS THEM. From chart 0.46.0 on,
# an external secret without externalSecret.hasScopes loses the container argument -oidc-scopes, so the scopes
# the values name (OIDC_SCOPES) are never passed and the sign-in asks the identity provider for Headlamp's own.
# The planted defect: the key false. The innocent case is the trunk's values.
headlamp_scopes_fault() { # <extra helm arguments...> -> what is wrong, or nothing
  helm template headlamp "$headlamp_address/headlamp" --version "$headlamp_version" -f clusters/bootstrap/headlamp/values.tpl "$@" \
    | yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].args[]' | grep -qxF -- '-oidc-scopes=$(OIDC_SCOPES)' \
    || echo "the Headlamp container of chart $headlamp_version is given no -oidc-scopes argument by clusters/bootstrap/headlamp/values.tpl"
}
[ -z "$(headlamp_scopes_fault)" ] \
  || fail "$(headlamp_scopes_fault) — set config.oidc.externalSecret.hasScopes to true there"
[ -n "$(headlamp_scopes_fault --set config.oidc.externalSecret.hasScopes=false)" ] \
  || fail "headlamp_scopes_fault takes a Headlamp chart rendered without the -oidc-scopes argument"
echo "check: the Headlamp container is given -oidc-scopes; the check refuses a planted external secret without hasScopes."

# ── The charts a cold owner's master renders before zot answers ───────────────────────────────
# AN INVENTORY WHOSE SYNC WAVE IS AT MOST THE REGISTRY'S renders before zot serves, so a chart it fetches from
# zot never arrives, and one it fetches from ghcr.io makes a cold start wait on GitHub. Its dependencies name
# neither host, and no inventory names ghcr.io at all. Such a chart is vendored instead: its dependency names no
# repository, its archive <name>-<version>.tgz stands in its charts/ folder, holds that version in its own
# Chart.yaml (helm renders a stale archive without a word), and has exactly one line in
# clusters/platform/charts.sha256, which `sha256sum --check` holds it to. A chart that also depends on charts of
# this repository stands unpacked in its charts/ folder instead, because Helm builds its dependencies and takes a
# dependency without a repository only as a folder; vendored_patch_fault holds every such folder, and charts_fault
# passes only a folder that has its vendor/<name>-<version>.upstream.sha256. The waves are read
# from the app.yaml files, so the set moves with the registry's wave.
zot_host="${mirror_prefix%%/*}"
charts_fault() { # <tree root> <file listing its vendored archives> -> the first fault, or nothing
  local root="$1" archives="$2" registry_wave app wave chart name version repository archive lines out
  out="$(cd "$root" && sha256sum --check --strict --quiet clusters/platform/charts.sha256 2>&1)" \
    || { echo "clusters/platform/charts.sha256 does not hold: $out"; return; }
  while read -r archive; do
    lines="$(awk -v path="$archive" '$2 == path' "$root/clusters/platform/charts.sha256" | grep -c .)"
    [ "$lines" = 1 ] || { echo "$archive has $lines lines in clusters/platform/charts.sha256, and a vendored archive has exactly one"; return; }
  done < "$archives"
  registry_wave="$(yq '.syncWave' "$root/clusters/inventories/registry/app.yaml")"
  for app in "$root"/clusters/inventories/*/app.yaml; do
    chart="$(dirname "$app")"
    [ -f "$chart/Chart.yaml" ] || continue
    wave="$(yq '.syncWave' "$app")"
    while read -r name version repository; do
      [ -n "$name" ] || continue
      case "$repository" in
        *ghcr.io*) echo "${chart#"$root/"} names its dependency $name on $repository, and nothing the tree renders is fetched from ghcr.io"; return ;;
        *"$zot_host"*)
          if [ "$wave" -le "$registry_wave" ]; then
            echo "${chart#"$root/"} renders in sync wave $wave, before zot in wave $registry_wave, and fetches its dependency $name from $repository"
            return
          fi ;;
        '')
          [ -f "$chart/charts/$name/Chart.yaml" ] && [ -f "$chart/vendor/$name-$version.upstream.sha256" ] && continue
          archive="${chart#"$root/"}/charts/$name-$version.tgz"
          grep -qxF "$archive" "$archives" || { echo "${chart#"$root/"} names no repository for $name, and $archive is no vendored archive"; return; }
          [ "$(tar -xzOf "$root/$archive" "$name/Chart.yaml" 2>/dev/null | yq '.version')" = "$version" ] \
            || { echo "$archive does not hold $name $version in its own Chart.yaml, and helm would render it as that version"; return; } ;;
      esac
    done < <(yq '.dependencies[] | .name + " " + .version + " " + (.repository // "")' "$chart/Chart.yaml")
  done
}
git ls-files 'clusters/inventories/*/charts/*.tgz' > "$work/vendored-charts"
fault="$(charts_fault "$root" "$work/vendored-charts")"
[ -z "$fault" ] || fail "$fault"
# The planted defects, each in a copy of what the check reads: the external-secrets dependency given back its
# repository on ghcr.io; cert-manager fetched from zot; the archive removed; one byte of it changed; Chart.yaml
# stamped to 2.9.0 beside the 2.8.0 archive; a second archive with no line; the 2.8.0 archive renamed to 2.9.0
# with its line; an unpacked chart folder in another inventory, with no upstream digest list.
plant_charts() { # <name> <a command run in the copy> -> the fault the check finds in that copy, or nothing
  local copy="$work/planted-charts/$1"
  rm -rf "$copy" && mkdir -p "$copy/clusters/platform" "$copy/clusters/inventories" || return 1
  cp clusters/platform/charts.sha256 "$copy/clusters/platform/"
  for app in clusters/inventories/*/app.yaml; do
    mkdir -p "$copy/$(dirname "$app")" && cp "$app" "$copy/$app"
    [ -f "$(dirname "$app")/Chart.yaml" ] && cp "$(dirname "$app")/Chart.yaml" "$copy/$(dirname "$app")/"
    for folder in "$(dirname "$app")"/charts/*/; do
      [ -f "$folder/Chart.yaml" ] && mkdir -p "$copy/$folder" && cp "$folder/Chart.yaml" "$copy/$folder"
    done
    [ -d "$(dirname "$app")/vendor" ] && cp -R "$(dirname "$app")/vendor" "$copy/$(dirname "$app")/vendor"
  done
  while read -r archive; do mkdir -p "$copy/$(dirname "$archive")" && cp "$archive" "$copy/$archive"; done < "$work/vendored-charts"
  cp "$work/vendored-charts" "$copy.archives"
  ( cd "$copy" && eval "$2" ) || return 1
  charts_fault "$copy" "$copy.archives"
}
eso=clusters/inventories/external-secrets
# From its parts, because scripts/check-mirror-consumers.sh refuses the whole address in every file it reads.
ghcr_host=ghcr.io
ghcr_chart="oci://$ghcr_host/external-secrets/charts"
planted_charts=(
  "ghcr|sed -i 's#^    version: 2.8.0\$#    version: 2.8.0\n    repository: $ghcr_chart#' $eso/Chart.yaml|names its dependency external-secrets on $ghcr_chart"
  "zot|sed -i 's#oci://quay.io/jetstack/charts#oci://$zot_host/simetrixch/quay.io/jetstack/charts#' clusters/inventories/cert-manager/Chart.yaml|renders in sync wave 0, before zot"
  "removed|rm $eso/charts/external-secrets-2.8.0.tgz|clusters/platform/charts.sha256 does not hold"
  "changed|printf x >> $eso/charts/external-secrets-2.8.0.tgz|clusters/platform/charts.sha256 does not hold"
  "stamped|sed -i 's#^    version: 2.8.0\$#    version: 2.9.0#' $eso/Chart.yaml|names no repository for external-secrets, and $eso/charts/external-secrets-2.9.0.tgz is no vendored archive"
  "unlisted|cp $eso/charts/external-secrets-2.8.0.tgz $eso/charts/external-secrets-2.9.0.tgz && echo $eso/charts/external-secrets-2.9.0.tgz >> ../unlisted.archives|has 0 lines in clusters/platform/charts.sha256"
  "renamed|mv $eso/charts/external-secrets-2.8.0.tgz $eso/charts/external-secrets-2.9.0.tgz && sed -i 's#external-secrets-2.8.0.tgz#external-secrets-2.9.0.tgz#' clusters/platform/charts.sha256 ../renamed.archives && sed -i 's#^    version: 2.8.0\$#    version: 2.9.0#' $eso/Chart.yaml|does not hold external-secrets 2.9.0 in its own Chart.yaml"
  "foreign|printf '  - name: foreign\\n    version: 1.0.0\\n' >> clusters/inventories/forgejo/Chart.yaml && mkdir -p clusters/inventories/forgejo/charts/foreign && printf 'name: foreign\\nversion: 6.6.6\\n' > clusters/inventories/forgejo/charts/foreign/Chart.yaml|clusters/inventories/forgejo names no repository for foreign"
)
for row in "${planted_charts[@]}"; do
  IFS='|' read -r name command expected <<< "$row"
  fault="$(plant_charts "$name" "$command")" || fail "the planted chart defect '$name' could not be planted"
  case "$fault" in *"$expected"*) ;; *) fail "charts_fault does not refuse the planted chart defect '$name' as expected ('$expected'): ${fault:-it found nothing}" ;; esac
done
echo "check: $(grep -c . "$work/vendored-charts") vendored chart archive holds its line in clusters/platform/charts.sha256 and its version; no inventory up to the registry's sync wave fetches a chart from ghcr.io or zot, and none fetches one from ghcr.io; the check refuses ${#planted_charts[@]} planted defects."

# EVERY UNPACKED CHART FOLDER IS VENDORED AND PATCHED; today that is clusters/inventories/plane/charts/plane-ce. Unpacked, because
# the plane chart also depends on charts of this repository, so Helm builds its dependencies, and Helm accepts a
# dependency that names no repository only as a folder. The claim "this folder is upstream plus the patch, and
# nothing else" is held here and by no comment: the patch must apply in reverse without fuzz, and the result must be
# exactly the files, and only the files, of vendor/plane-ce-<version>.upstream.sha256, which lists each file of the
# upstream archive but its README.md with its sha256. The README is not vendored: it names upstream addresses that
# scripts/check-mirror-consumers.sh refuses in every tracked file, and Helm renders nothing from it. The folder's own Chart.yaml must hold the version the dependency names, or
# Helm renders a stale folder without a word.
vendored_patch_fault() { # <tree root> -> the first fault, or nothing
  local root="$1" inventory name version dependency patch_file upstream copy listed found folder
  for folder in "$root"/clusters/inventories/*/charts/*/; do
    [ -f "$folder/Chart.yaml" ] || continue
    inventory="$(dirname "$(dirname "${folder%/}")")"
    name="$(basename "$folder")"
    version="$(yq '.version' "$folder/Chart.yaml" 2>/dev/null)"
    dependency="$(yq ".dependencies[] | select(.name == \"$name\") | .version" "$inventory/Chart.yaml")"
    [ "$dependency" = "$version" ] \
      || { echo "${inventory#"$root/"}/Chart.yaml names $name $dependency, and the vendored folder holds $name ${version:-nothing} in its own Chart.yaml"; return; }
    patch_file="$inventory/vendor/$name-$version.patch"
    upstream="$inventory/vendor/$name-$version.upstream.sha256"
    [ -f "$patch_file" ] && [ -f "$upstream" ] || { echo "${inventory#"$root/"}/vendor holds no $name-$version.patch and $name-$version.upstream.sha256"; return; }
    copy="$(mktemp -d "$work/vendored-patch.XXXXXX")" && cp -R "$folder" "$copy/$name" || { echo "the vendored $name could not be copied"; return; }
    (cd "$copy" && patch -R -p1 -F0 -s --no-backup-if-mismatch < "$patch_file" >/dev/null 2>&1) \
      || { echo "$name-$version.patch does not apply in reverse to the vendored $name, so the folder does not hold the patch"; return; }
    found="$(cd "$copy" && find "$name" -type f | grep -c .)"
    listed="$(grep -c . "$upstream")"
    [ "$found" = "$listed" ] || { echo "the vendored $name with the patch reversed holds $found files, and $name-$version.upstream.sha256 lists $listed"; return; }
    (cd "$copy" && sha256sum --check --strict --quiet "$upstream" >/dev/null 2>&1) \
      || { echo "the vendored $name with the patch reversed is not the upstream chart listed in $name-$version.upstream.sha256"; return; }
  done
}
fault="$(vendored_patch_fault "$root")"
[ -z "$fault" ] || fail "$fault"
# The planted defects, each in a copy: a patched template line edited by hand; a template line the patch does not
# touch edited by hand; the patch with its added line changed; the patch with its restored line changed; a file
# added to the folder; a file removed; the unpatched upstream chart; the dependency stamped to another version; a
# foreign folder in another inventory with an empty upstream list, and with a forged one. The planted innocent:
# every file given another modification time.
plant_vendor() { # <name> <a command run in the copy> -> the fault the check finds in that copy, or nothing
  local copy="$work/planted-vendor/$1"
  rm -rf "$copy" && mkdir -p "$copy/clusters/inventories" || return 1
  cp -R clusters/inventories/plane clusters/inventories/forgejo "$copy/clusters/inventories/" || return 1
  ( cd "$copy" && eval "$2" ) || return 1
  vendored_patch_fault "$copy"
}
pl=clusters/inventories/plane
fg=clusters/inventories/forgejo
foreign="printf '  - name: foreign\\n    version: 1.0.0\\n' >> $fg/Chart.yaml && mkdir -p $fg/charts/foreign $fg/vendor && printf 'name: foreign\\nversion: 1.0.0\\n' > $fg/charts/foreign/Chart.yaml && : > $fg/vendor/foreign-1.0.0.patch"
planted_vendor=(
  "patched-line|sed -i 's/trunc 8/trunc 9/' $pl/charts/plane-ce/templates/workloads/migrator.job.yaml|does not apply in reverse"
  "other-line|sed -i '1s/\$/ # edited/' $pl/charts/plane-ce/templates/workloads/migrator.job.yaml|is not the upstream chart"
  "hunk-added|sed -i 's/trunc 8/trunc 9/' $pl/vendor/plane-ce-1.8.5.patch|does not apply in reverse"
  "hunk-restored|sed -i 's/^-  name: {{ .Release.Name }}-api-migrate-{{ .Release.Revision }}\$/-  name: {{ .Release.Name }}-api-migrate-edited/' $pl/vendor/plane-ce-1.8.5.patch|is not the upstream chart"
  "added|echo extra > $pl/charts/plane-ce/templates/extra.yaml|holds 31 files, and plane-ce-1.8.5.upstream.sha256 lists 30"
  "removed|rm $pl/charts/plane-ce/.helmignore|holds 29 files"
  "unpatched|(cd $pl/charts && patch -R -p1 -s < ../vendor/plane-ce-1.8.5.patch)|does not apply in reverse"
  "stamped|sed -i 's/^    version: 1.8.5\$/    version: 1.8.6/' $pl/Chart.yaml|names plane-ce 1.8.6"
  "foreign-empty|$foreign && : > $fg/vendor/foreign-1.0.0.upstream.sha256|the vendored foreign with the patch reversed holds 1 files, and foreign-1.0.0.upstream.sha256 lists 0"
  "foreign-forged|$foreign && printf '%064d  foreign/Chart.yaml\\n' 1 > $fg/vendor/foreign-1.0.0.upstream.sha256|the vendored foreign with the patch reversed is not the upstream chart"
)
for row in "${planted_vendor[@]}"; do
  IFS='|' read -r name command expected <<< "$row"
  fault="$(plant_vendor "$name" "$command")" || fail "the planted vendored-chart defect '$name' could not be planted"
  case "$fault" in *"$expected"*) ;; *) fail "vendored_patch_fault does not refuse the planted vendored-chart defect '$name' as expected ('$expected'): ${fault:-it found nothing}" ;; esac
done
fault="$(plant_vendor retimed "find $pl/charts -type f -exec touch -d 2001-01-01 {} +")" || fail "the planted innocent vendored-chart case could not be planted"
[ -z "$fault" ] || fail "vendored_patch_fault refuses the planted innocent case, every file given another modification time: $fault"
echo "check: the vendored plane-ce folder is the upstream chart plus plane-ce-$(yq '.version' clusters/inventories/plane/charts/plane-ce/Chart.yaml).patch, and nothing else; the check refuses ${#planted_vendor[@]} planted defects and passes the innocent case."

push_paths() { # $1 unit name, $2 repoURL, $3 builds as JSON, $4 global.buildRegistry -> the probe IMAGE and buildah image-name of each build, one line each
  helm template consumer-build clusters/inventories/consumer-build --namespace argocd --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
    -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
    -f clusters/inventories/consumer-build/values-common.yaml -f "$cluster_map" -f "$registration" \
    --set "global.buildRegistry=$4" --set-json "unit={\"name\":\"$1\",\"repoURL\":\"$2\",\"buildsJson\":$(printf '%s' "$3" | yq -o=json -I=0 'to_json(0)')}" \
    > "$work/push-render" 2>&1 \
    || { cat "$work/push-render" >&2; echo "consumer-build does not render the release of unit $1"; return; }
  yq "select(.kind == \"Pipeline\" and .metadata.name == \"$1-release\") | .spec.tasks[] | select(.name | test(\"^(probe|build)-\")) | .name + \" \" + ([.taskSpec.steps[].env[] | select(.name == \"IMAGE\") | .value] + [.params[] | select(.name == \"image-name\") | .value] | .[0])" "$work/push-render"
}
master_registry="$(yq '.global.endpoints.registry.host' "$cluster_map")/simetrixch"
trunk_registry="$(yq '.global.buildRegistry' clusters/platform/values-common.yaml)"
push_cases=(
  "the platform's builds on the owner's master|hostyour-manager|https://github.com/simetrixch/hostyour-manager.git|[\"manager\",\"gate-runner\",\"dbtools\"]|$master_registry|simetrixch/"
  "a unit of the owner that is not buildRegistryUnit|hostyour-demo-consumer|https://github.com/simetrixch/hostyour-demo-consumer.git|[\"hostyour-demo-consumer\"]|$master_registry|"
  "a unit of another owner|digita-platform|https://github.com/digitaplatform/digita-platform.git|[\"digita-platform\"]|$master_registry|"
  "the platform's builds on another installation|hostyour-manager|https://github.com/simetrixch/hostyour-manager.git|[\"manager\",\"gate-runner\",\"dbtools\"]|$trunk_registry|"
)
push_fault() { # unit, repoURL, builds, buildRegistry, prefix -> the first build whose push path is not <prefix><build>, or nothing
  local want got
  want="$(printf '%s' "$3" | yq -p=json ".[] | ((\"probe-\" + . + \" $5\" + .), (\"build-\" + . + \" $5\" + .))" | sort)"
  got="$(push_paths "$1" "$2" "$3" "$4" | sort)"
  [ "$got" = "$want" ] || echo "unit $1 under buildRegistry $4 pushes ${got//$'\n'/, }, not under '${5:-flat}'"
}
for c in "${push_cases[@]}"; do
  IFS='|' read -r what unit repo builds breg prefix <<< "$c"
  fault="$(push_fault "$unit" "$repo" "$builds" "$breg" "$prefix")"
  [ -z "$fault" ] || fail "the push path of $what: $fault"
done
# The planted defects: a unit of the owner moved under the prefix it must not take, and the platform's
# builds left flat on the owner's master.
[ -n "$(push_fault hostyour-demo-consumer https://github.com/simetrixch/hostyour-demo-consumer.git '["hostyour-demo-consumer"]' "$master_registry" simetrixch/)" ] \
  || fail "push_fault takes a unit that is not buildRegistryUnit pushed under the owner's prefix"
[ -n "$(push_fault hostyour-manager https://github.com/simetrixch/hostyour-manager.git '["manager"]' "$trunk_registry" simetrixch/)" ] \
  || fail "push_fault takes the platform's builds pushed flat where they must go under the owner's prefix"
echo "check: ${#push_cases[@]} push paths, the platform's builds under simetrixch/ on the owner's master alone and every other build flat; the check refuses both planted defects."

# And the pods pull them from there: every builds[] pin of the manager and the gate-runner composes against
# the owner's Zot under simetrixch/, so no cluster asks ghcr.io for an image of this platform.
own_images() { # $1 global.buildRegistry -> the refs of the platform's own images the manager and gate-runner render at prod
  local app
  for app in manager gate-runner; do
    helm template "$app" "clusters/inventories/$app" --namespace "$app" --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
      -f clusters/platform/values-common.yaml -f clusters/platform/values-prod.yaml \
      -f "clusters/inventories/$app/values-common.yaml" -f "clusters/inventories/$app/values-prod.yaml" \
      -f "$installation_values" -f "$cluster_map" -f "$registration" --set "global.buildRegistry=$1" \
      | grep -oE '[a-z0-9.-]+/simetrixch/(manager|gate-runner|dbtools):[^" ]+'
  done | sort -u
}
own_image_fault() { # $1 the refs -> what is wrong with them, or nothing
  [ "$(printf '%s\n' "$1" | sed 's|:.*||' | sort -u | wc -l)" = 3 ] || { echo "the renders name ${1//$'\n'/, }, not manager, gate-runner and dbtools once each"; return; }
  printf '%s\n' "$1" | grep -v '^zot\.master\.digitacloud\.app/simetrixch/' | sed 's/^/not on the owner'"'"'s Zot: /' | head -1
}
fault="$(own_image_fault "$(own_images "$trunk_registry")")"
[ -z "$fault" ] || fail "the platform's own images: $fault"
[ -n "$(own_image_fault "$(own_images ghcr.io/simetrixch)")" ] || fail "own_image_fault takes the planted defect, the platform's images pulled from ghcr.io"
echo "check: the manager, gate-runner and dbtools pods pull from zot.master.digitacloud.app/simetrixch/, and the check refuses the planted pull from ghcr.io."

# The binaries a release tag publishes from release/build.sh stand under <owner>/<repository>, read off the
# repoURL, which for ansiwise-cli is the path the Manager, the lifecycle and the release script fetch.
binaries_repository() { # $1 repoURL -> the repository the publish pipeline of unit ansiwise-cli pushes binaries to
  helm template consumer-build clusters/inventories/consumer-build --namespace argocd --api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1alpha1 \
    -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
    -f clusters/inventories/consumer-build/values-common.yaml -f "$cluster_map" -f "$registration" \
    --set-json "unit={\"name\":\"ansiwise-cli\",\"repoURL\":\"$1\",\"buildsJson\":\"[]\"}" \
    | yq 'select(.kind == "Pipeline" and .metadata.name == "ansiwise-cli-publish") | .spec.tasks[] | select(.name == "push") | .taskSpec.steps[0].env[] | select(.name == "BINARIES_REPOSITORY") | .value'
}
for url in https://github.com/simetrixch/ansiwise-cli.git https://github.com/simetrixch/ansiwise-cli; do
  [ "$(binaries_repository "$url")" = simetrixch/ansiwise-cli ] || fail "the publish of $url pushes its binaries to '$(binaries_repository "$url")', not simetrixch/ansiwise-cli"
done
[ "$(binaries_repository https://github.com/simetrixch/ansiwise-core.git)" != simetrixch/ansiwise-cli ] \
  || fail "the planted defect, another repository, still pushes its binaries to simetrixch/ansiwise-cli"
echo "check: the publish of a repository with release/build.sh pushes its binaries to simetrixch/ansiwise-cli, with or without .git, and another repository elsewhere."

# ── A unit that declares an SMTP entry, and a unit that does not ─────────────────────────────
# THE STAND-IN REGISTRATION DECLARES NO ENTRY, because almost no unit does, so every render above
# takes the branch without one. A unit that declares one gets three lines more: an ingress rule in
# its fence admitting the books cluster's tailnet address and the relay's own namespace on the
# entry's port, and an exception in its admission boundary letting the entry's Service alone carry
# this cluster's tailnet address as its external IP. Both charts are rendered here with the entry and without it, in the shape each
# ApplicationSet hands it, and held to those two lines: a branch that fell through would render
# exactly as green as one that was taken. The stand-in map is both clusters at once, so one address
# stands for the books cluster's and the unit cluster's.
echo "check: a unit's fence and admission boundary, with an SMTP entry and without one."
tailnet_address="$(sed -n 's/^  apiHost:[[:space:]]*//p' "$cluster_map")"
[ -n "$tailnet_address" ] || fail "$cluster_map carries no global.apiHost, the tailnet address an SMTP entry is opened on and admitted from"
for entry in none declared; do
  fence_entry='{}'
  boundary_entry='"{}"'
  if [ "$entry" = declared ]; then
    fence_entry='{"port":2525}'
    boundary_entry='"{\"service\":\"check-mta\",\"port\":2525}"'
  fi
  { helm template unit-networkpolicy clusters/units/networkpolicy --namespace check-dev \
      -f clusters/units/networkpolicy/values.yaml -f "$cluster_map" --set-json "smtpEntry=$fence_entry" \
    && helm template unit-admissionpolicy clusters/units/admissionpolicy --namespace check-dev \
      -f clusters/platform/values-common.yaml -f clusters/platform/values-dev.yaml \
      -f clusters/units/admissionpolicy/values.yaml -f "$cluster_map" -f "$registration" \
      --set-json "registration.smtpEntryJson=$boundary_entry"
  } > "$work/entry-render" 2>&1 \
    || { cat "$work/entry-render"; fail "a unit's fence or admission boundary does not render where the SMTP entry is $entry"; }
  opened="$(grep -cF -e "cidr: \"$tailnet_address/32\"" -e 'kubernetes.io/metadata.name: "postfix"' \
    -e "object.metadata.name == 'check-mta' && object.spec.externalIPs == ['$tailnet_address']" "$work/entry-render")"
  expected=0
  [ "$entry" = declared ] && expected=3
  if [ "$opened" != "$expected" ]; then
    cat "$work/entry-render"
    fail "where the SMTP entry is $entry, the fence and the admission boundary carry $opened of the 3 lines that open it, and they have to carry $expected"
  fi
done
echo "check: an SMTP entry opens a unit's fence and admission boundary where one is declared, and nowhere else."

# ── What clusters/bootstrap must never carry ─────────────────────────────────────────────────
# NOTHING STAMPS THAT TREE, AND A PLACEHOLDER LEFT IN IT TRAVELS AS TEXT. The seven files under
# clusters/bootstrap that carry one installation's own domain and short name are TEMPLATES: the
# branch program renders each .tpl onto the install branch beside itself, filling the slots its row
# hands it, which the next section holds. No stamping row reaches the tree any more, and a row whose
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

# ── What the branch program hands the templates of clusters/bootstrap ───────────────────────
# A TEMPLATE AND ITS ROW ARE TWO HALVES OF ONE CALL, IN TWO REPOSITORIES. The write_file_from_template
# rows of hostyour-deploy's ansiwise/programs/deploy-branch.yaml render every .tpl here, and the engine
# refuses the run when a template and its row's values do not fit. Every slot counts, one in a comment
# as much as one in a value, so a comment that names <tag> stops the regeneration of every machine
# after the release is already pinned. Each template is read here against its row as the engine reads it.
#
# THE RULE IS THE ENGINE'S, COPIED ONCE: the grammar is ansiwise-core lib/src/steps/slots.dart
# slotPattern, the refusals are template.dart Template.filledWith. A required slot <name> its row does
# not hand, a value of the row that no slot takes and a value handed to a carried slot <name!?> are
# refused; an optional slot <name?> may go without one. Beside the engine's rule, a .tpl that no row
# names is refused, because nothing hands its slots, and so is a row that names a template of this
# tree that does not stand in it.
bootstrap_template_faults() { # <program> <tree> -> one line per template and row that do not fit, or nothing
  local rows template values file lines slot name kind slots names value
  rows="$(yq '.. | select(tag == "!!map" and .step == "write_file_from_template") | [.template, (.values // {} | keys | join(" "))] | @tsv' "$1")" \
    || { echo "the write_file_from_template rows of $1 could not be read"; return; }
  bootstrap_rows=0
  local named=" "
  while IFS=$'\t' read -r template values; do
    case "$template" in /srv/hostyour-cloud/*) ;; *) continue ;; esac
    file="${template#/srv/hostyour-cloud/}"
    named="$named$file "
    bootstrap_rows=$((bootstrap_rows + 1))
    # yq's own line operator names lines this program's text does not have there, so the row is found
    # by its template line.
    lines="$(awk -v t="$template" '{ s = $0; sub(/^[ \t]*(- )?/, "", s); sub(/[ \t]+$/, "", s); gsub(/["'\'']/, "", s) }
      s == "template: " t { printf "%s%s", (n++ ? "," : ""), NR }' "$1")"
    if [ ! -f "$2/$file" ]; then
      echo "$file: the row at deploy-branch.yaml:$lines names it, and it does not stand in this tree"
      continue
    fi
    slots="$(grep -oE '<[a-z][a-z0-9-]*(!\?|\?)?>' "$2/$file" | sort -u)"
    names=" "
    while IFS= read -r slot; do
      [ -n "$slot" ] || continue
      name="${slot#<}"; name="${name%>}"
      case "$name" in
        *'!?') kind=carried; name="${name%'!?'}" ;;
        *'?') kind=optional; name="${name%'?'}" ;;
        *) kind=required ;;
      esac
      names="$names$name "
      case " $values " in
        *" $name "*) [ "$kind" != carried ] \
          || echo "$file carries $slot, and its row at deploy-branch.yaml:$lines hands it a value, which a carried slot never takes" ;;
        *) [ "$kind" != required ] \
          || echo "$file names $slot, and its row at deploy-branch.yaml:$lines hands no value under that name" ;;
      esac
    done <<< "$slots"
    while IFS= read -r value; do
      [ -n "$value" ] || continue
      case "$names" in
        *" $value "*) ;;
        *) echo "$file names no slot <$value>, and its row at deploy-branch.yaml:$lines hands a value under that name" ;;
      esac
    done < <(printf '%s\n' "$values" | tr ' ' '\n')
  done <<< "$rows"
  while IFS= read -r file; do
    case "$named" in
      *" $file "*) ;;
      *) echo "$file: no write_file_from_template row of the program names it, so nothing hands its slots" ;;
    esac
  done < <(cd "$2" && find clusters/bootstrap -name '*.tpl' | sort)
}

# THE ROWS ARE READ AT THE COMMIT ci-sources.json PINS, NEVER FROM A WORKING TREE: on the master's ci
# out of the bare repository the sources step of the ci task makes under CI_SOURCES_DIR, on a machine out of the object
# store of the hostyour-deploy clone beside the main checkout, which a worktree finds through its
# common git directory. A template that needs a new binding moves the pin to the row's commit, and the
# pin records which rows the templates were held to.
deploy_pin="$(yq -p=json -o=yaml '.git["hostyour-deploy"] // ""' ci-sources.json)" \
  || fail "ci-sources.json could not be read, so the commit of hostyour-deploy whose rows render clusters/bootstrap is not known"
[[ "$deploy_pin" =~ ^[0-9a-f]{40}$ ]] \
  || fail "ci-sources.json pins hostyour-deploy at '$deploy_pin', not a full commit (40 lowercase hex digits)"
if [ -n "${CI_SOURCES_DIR:-}" ]; then
  deploy_source="$CI_SOURCES_DIR/hostyour-deploy.git"
  deploy_from="CI_SOURCES_DIR ($deploy_source)"
  deploy_read=(git --git-dir="$deploy_source")
else
  common="$(git rev-parse --git-common-dir)" || fail "the common git directory of this checkout could not be read"
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  deploy_source="$(cd "$common/../.." && pwd)/hostyour-deploy"
  [ -d "$deploy_source" ] \
    || fail "no hostyour-deploy clone at $deploy_source, beside the main checkout, and the rows that render clusters/bootstrap stand in it — clone simetrixch/hostyour-deploy there"
  deploy_from="the clone beside the main checkout ($deploy_source)"
  deploy_read=(git -C "$deploy_source")
fi
"${deploy_read[@]}" show "$deploy_pin:ansiwise/programs/deploy-branch.yaml" > "$work/deploy-branch.yaml" \
  || fail "hostyour-deploy ansiwise/programs/deploy-branch.yaml at $deploy_pin, the pin of ci-sources.json, could not be read from $deploy_source — fetch that commit into it"
bootstrap_template_faults "$work/deploy-branch.yaml" "$root" > "$work/bootstrap-faults"
if [ -s "$work/bootstrap-faults" ]; then
  sed 's/^/  /' "$work/bootstrap-faults"
  fail "a template under clusters/bootstrap and its row of hostyour-deploy ansiwise/programs/deploy-branch.yaml at ${deploy_pin:0:7} do not fit, and the engine would stop the regeneration there — bind the slot in that row and move the hostyour-deploy pin of ci-sources.json to its commit, or take the angle brackets off a word that is no slot"
fi
[ "$bootstrap_rows" -gt 0 ] || fail "no write_file_from_template row of hostyour-deploy ansiwise/programs/deploy-branch.yaml at ${deploy_pin:0:7} names a template of this tree"
bootstrap_templates="$(find clusters/bootstrap -name '*.tpl' | wc -l | tr -d ' ')"
real_rows=$bootstrap_rows
planted_red=0
planted_green=0

# The planted cases, through the same function: <red|green>|<what>|<template, \n for a new line, empty for
# no file>|<the row's values, empty for no row>.
bootstrap_plants=(
  "red|a comment that names <repository>:<tag>, which its row does not hand|# The chart composes <repository>:<tag> and has no field for a digest.\ndomain: argo.<fqdn>|{fqdn: {answer: fqdn}}"
  "red|a row that hands a value no slot takes|domain: argo.<fqdn>|{fqdn: {answer: fqdn}, cluster-name: {answer: cluster_name}}"
  "red|a row that hands a value to a carried slot|domain: argo.<fqdn>\nkept: <kept!?>|{fqdn: {answer: fqdn}, kept: {answer: kept}}"
  "red|a template no row names|domain: argo.<fqdn>|"
  "red|a row that names a template which does not stand in the tree||{fqdn: {answer: fqdn}}"
  "green|only <fqdn>, which its row hands|domain: argo.<fqdn>|{fqdn: {answer: fqdn}}"
  "green|an optional and a carried slot left without a value|domain: argo.<fqdn>\nnote: <note?>\nkept: <kept!?>|{fqdn: {answer: fqdn}}"
)
for plant_case in "${bootstrap_plants[@]}"; do
  IFS='|' read -r expected what text values <<< "$plant_case"
  plant="$(mktemp -d "$work/bootstrap-plant.XXXXXX")" || fail "no folder for a planted bootstrap template could be made"
  mkdir -p "$plant/clusters/bootstrap/planted" || fail "no folder for a planted bootstrap template could be made"
  [ -z "$text" ] || printf '%b\n' "$text" > "$plant/clusters/bootstrap/planted/values.tpl"
  : > "$plant/program.yaml"
  [ -z "$values" ] || printf '%s\n' '- step: write_file_from_template' \
    '  template: /srv/hostyour-cloud/clusters/bootstrap/planted/values.tpl' "  values: $values" > "$plant/program.yaml"
  bootstrap_template_faults "$plant/program.yaml" "$plant" > "$plant/faults"
  case "$expected" in
    red) [ -s "$plant/faults" ] || fail "bootstrap_template_faults passes a planted template with $what"
      planted_red=$((planted_red + 1)) ;;
    green) [ ! -s "$plant/faults" ] || { sed 's/^/  /' "$plant/faults"; fail "bootstrap_template_faults refuses a planted template with $what"; }
      planted_green=$((planted_green + 1)) ;;
  esac
done
echo "check: the $bootstrap_templates templates under clusters/bootstrap fit the $real_rows rows of hostyour-deploy ansiwise/programs/deploy-branch.yaml at ${deploy_pin:0:7} that render them, read from $deploy_from; the check refuses $planted_red planted misfits, a comment that names <repository>:<tag> among them, and passes $planted_green planted innocents, one with only <fqdn>."

# THE CONSUMERS OF THE OWNER'S MIRROR, of this tree and of hostyour-deploy at the commit ci-sources.json pins, taken
# with the same pin and the same reader as the program above, as an archive of the whole commit: they name no address
# of an upstream, and every owned address at a place that reads a row of clusters/platform/mirror-sources.table is
# that row. Its planted defects and innocents run in scripts/check-mirror-consumers.test.sh.
deploy_tree="$work/hostyour-deploy-at-pin"
mkdir "$deploy_tree" || fail "no folder for hostyour-deploy at its pin could be made"
"${deploy_read[@]}" archive "$deploy_pin" | tar -x -C "$deploy_tree" \
  || fail "hostyour-deploy at $deploy_pin, the pin of ci-sources.json, could not be archived from $deploy_source — fetch that commit into it"
bash scripts/check-mirror-consumers.sh . "$deploy_tree" || fail "scripts/check-mirror-consumers.sh refuses a consumer of the owner's mirror, listed above by file:line"
echo "check: a row listed above as read by none is no failure: the row of kubeconform is read by hostyour-manager gate-runner/Containerfile, a tree this check does not read, and a bump adds its row before its consumer moves."

# ── What an installation's branch must be able to take ───────────────────────────────────────
# A RELEASE REACHES A MACHINE AS A MERGE into its installation's branch, the branch named after its
# domain, on which the branch program replaced example.invalid with that domain in every file it
# stamps. git refuses to merge a change to a line the branch rewrote, and also one to the line
# beside it, so a release that edits next to a stamped line stops at that merge and reaches no
# machine. The installation branches on origin are the real merge targets, so HEAD is merged into
# each of them as the release would be, in memory, without a working tree.
#
# A BRANCH IS AN INSTALLATION'S WHEN IT HOLDS clusters/active/<its own name>.yaml, the cluster map the
# branch program writes there and the default branch never carries. A name alone tells nothing: a
# dot in a branch name is a version as often as a domain. The branches are fetched first, because
# the installation branch moves with every release pin and a copy fetched an hour ago answers for
# an hour ago. A clone that holds no installation branch has nothing to merge into, and says so
# instead of reporting a pass.
merges_into() {
  git -C "$1" merge-tree --write-tree --name-only --no-messages "$2" "$3" >"$work/merge-tree" 2>&1
}
# THE LANDING IS A COMMIT, AND A COMMIT NEEDS AN AUTHOR. A CI runner has no git identity, and
# commit-tree refuses to write without one, so the landing carries its own: it is never pushed and
# nothing points at it, so the name only has to exist.
landing_commit() {
  GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@example.invalid \
    GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@example.invalid \
    git -C "$1" commit-tree "$2" -p "$3" -p "$4" -m "check: $4 on $3"
}
# AN INSTALLATION'S COMMIT IS JUDGED AGAINST THE DEFAULT BRANCH AS IT STOOD WHEN THE COMMIT WAS MADE.
# A release pins the default branch and then the installation's branch, stage by stage, seconds apart,
# so the run a branch push starts finds the default branch already one pin ahead of a commit that was
# made before that pin existed. That commit conflicts with the newest pin until its own pin lands, a
# minute later, and the run it starts is green: a red run the release itself leaves behind. A
# conflict that stands in the default branch of the commit's own time is still a conflict. Any other
# commit is judged against the tip, which is what a release of it would be cut onto. An installation's
# commit is one that holds a cluster map under clusters/active; the default branch holds none.
default_when() { # <repo> <default branch> <commit> -> the commit of the default branch to judge it against
  if git -C "$1" ls-tree -r --name-only "$3" -- clusters/active | grep -q '\.yaml$'; then
    git -C "$1" rev-list -1 --first-parent --before="$(git -C "$1" log -1 --format=%cI "$3")" "$2"
  else
    git -C "$1" rev-parse "$2"
  fi
}
probe="$work/merge-probe"
git -c init.defaultBranch=probe init -q "$probe" || fail "the merge probe could not make its repository"
# Each probe commit is made one second after the one before, so the order in which they are made is
# the order of their dates, which is what default_when reads.
# The clock is a file because every call runs in a command substitution, which keeps no variable.
echo 1760000000 >"$work/probe-clock"
probe_commit() {
  printf '%s\n' "$@" >"$probe/root-app.yaml"
  mkdir -p "$probe/clusters/active"
  [ -n "${probe_map:-}" ] && : >"$probe/clusters/active/installation.example.yaml"
  echo $(($(cat "$work/probe-clock") + 1)) >"$work/probe-clock"
  git -C "$probe" add -A && GIT_COMMITTER_DATE="$(cat "$work/probe-clock") +0000" git -C "$probe" -c user.name=probe -c user.email=probe@example.invalid commit -qm probe && git -C "$probe" rev-parse HEAD
}
probe_base="$(probe_commit '      helm:' '        valueFiles:' '          - $values/example.invalid.yaml' '' '  destination:')"
probe_installation="$(probe_map=1 probe_commit '      helm:' '        valueFiles:' '          - $values/installation.example.yaml' '' '  destination:')"
git -C "$probe" checkout -q "$probe_base" 2>/dev/null
probe_defect="$(probe_commit '      helm:' '        valueFiles:' '          - $values/example.invalid.yaml' '        parameters: planted-defect' '' '  destination:')"
git -C "$probe" checkout -q "$probe_base" 2>/dev/null
probe_innocent="$(probe_commit '      helm:' '        parameters: planted-innocent' '        valueFiles:' '          - $values/example.invalid.yaml' '' '  destination:')"
# An installation commit made after the default branch took the planted change, and without it.
git -C "$probe" checkout -q "$probe_base" 2>/dev/null
probe_late="$(probe_map=1 probe_commit '      helm:' '        valueFiles:' '          - $values/installation.example.yaml' '' '  destination:')"
[ -n "$probe_installation" ] && [ -n "$probe_defect" ] && [ -n "$probe_innocent" ] && [ -n "$probe_late" ] || fail "the merge probe could not write its commits"
merges_into "$probe" "$probe_installation" "$probe_defect" \
  && fail "the merge probe took a change beside a stamped line without a conflict, so this check cannot see one"
merges_into "$probe" "$probe_installation" "$probe_innocent" \
  || { cat "$work/merge-tree"; fail "the merge probe refused a change one line away from a stamped line, which git merges"; }
# The default branch of the probe stands on the planted change, which the installation commit made
# before it lacks: that is the race of a release, and it is judged against the default branch of its
# own time. The commit made after it, still lacking it, is a conflict that stands, and stays one.
# A commit that is no installation's is judged against the tip whatever its date.
git -C "$probe" update-ref refs/heads/trunk "$probe_defect"
merges_into "$probe" "$(default_when "$probe" trunk "$probe_installation")" "$probe_installation" \
  || { cat "$work/merge-tree"; fail "the merge probe refused an installation commit for a change the default branch took after it was made, which a release leaves behind for a minute"; }
merges_into "$probe" "$(default_when "$probe" trunk "$probe_late")" "$probe_late" \
  && fail "the merge probe took an installation commit made after the default branch's change that conflicts with it, so this check cannot see a conflict that stands"
[ "$(default_when "$probe" trunk "$probe_base")" = "$probe_defect" ] \
  || fail "the merge probe judged a commit that is no installation's against the default branch of its own time, not against its tip"
# The landing is written once more as a runner would write it, with no identity anywhere: no global
# or system configuration and no repository one.
mkdir "$work/no-identity" || fail "the merge probe could not make an empty home"
HOME="$work/no-identity" XDG_CONFIG_HOME="$work/no-identity" GIT_CONFIG_NOSYSTEM=1 \
  landing_commit "$probe" "$(git -C "$probe" rev-parse "$probe_innocent^{tree}")" "$probe_base" "$probe_innocent" >/dev/null \
  || fail "the merge probe could not write a landing without a git identity, the way a CI runner has none"
echo "check: the merge probe refuses the planted change beside a stamped line and takes the planted innocent, and writes a landing with no git identity."

# WHAT IS MERGED IS WHAT A RELEASE WOULD CUT: HEAD on top of the default branch. A branch that is
# behind it lacks the release pins written there since, and the installation branch carries the
# same pins, so HEAD alone would conflict on lines the change never touched. Where HEAD does not
# hold the default branch, the two are merged in memory into a commit nothing points at; where
# they conflict, nothing could be released, and that conflict is the failure named.
git fetch -q --prune origin || fail "origin could not be fetched, so the installation branches a release merges into are unknown"
installations=""
for branch in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin); do
  git cat-file -e "$branch:clusters/active/${branch#origin/}.yaml" 2>/dev/null && installations="$installations $branch"
done
if [ -z "$installations" ]; then
  echo "check: NOT RUN — no installation branch in this clone, so no merge of HEAD into one was tried."
else
  default_branch="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" \
    || fail "origin/HEAD names no default branch, so what a release would cut is unknown — run git remote set-head origin --auto"
  # An installation's HEAD is judged against $default_branch as it stood when HEAD was made (default_when above).
  release_base="$(default_when "$root" "$default_branch" HEAD)"
  [ -n "$release_base" ] || fail "$default_branch holds no commit as old as HEAD, so what HEAD was released with is unknown"
  candidate=HEAD
  if ! git merge-base --is-ancestor "$release_base" HEAD; then
    git merge-tree --write-tree --name-only --no-messages "$release_base" HEAD >"$work/merge-tree" 2>&1 || {
      sed 's/^/  /' "$work/merge-tree"
      fail "HEAD conflicts with $default_branch, so no release of it can be cut — merge $default_branch into it first"
    }
    candidate="$(landing_commit "$root" "$(head -n 1 "$work/merge-tree")" "$release_base" HEAD)" \
      || fail "HEAD on $default_branch could not be written as a commit to merge"
  fi
  for installation in $installations; do
    merges_into "$root" "$installation" "$candidate" || {
      sed 's/^/  /' "$work/merge-tree"
      fail "HEAD on $default_branch does not merge into $installation: a release of it would stop at that machine's merge — move the change off the line the installation stamped and off the lines beside it"
    }
  done
  echo "check: HEAD on $default_branch merges into every installation branch on origin: $(echo $installations)."
fi

# ── Every stamp site of this tree, held to its pin ───────────────────────────────────────────
# clusters/platform/versions.yaml names, per pin, the sites a version sync writes it into. The
# sync is an ansiwise program and does not run here, so a site it left behind went unnoticed
# until a pod failed to pull, as the per-unit MongoDB chart once did. Every yaml_value site of
# the `platform` tree is read here the way the stamp reads it (ansiwise-versions
# lib/src/stamping.dart): the line whose trim is the anchor, exactly once; the block under it,
# which ends where a line stands further left or a list item begins at the anchor's column or
# left of it; and in it the key at the anchor's column, outside list items, exactly once. Sites of
# the `deploy` and `manager` trees stand in other repositories, and are those repositories' to hold.
site_value() { # <file> <key> <anchor, or empty for the top level> — prints "<line>\t<value>", or "!<why>"
  awk -v key="$2" -v anchor="$3" '
    function trimmed(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function column(s,   c, a) {
      c = match(s, /[^ ]/) - 1; if (c < 0) return length(s)
      if (substr(s, c + 1, 1) == "-") { a = c + 1; while (substr(s, a + 1, 1) == " ") a++; if (a > c + 1) return a }
      return c
    }
    function quiet(s,   t) { t = trimmed(s); return t == "" || substr(t, 1, 1) == "#" }
    function item(s,   t) { t = s; sub(/^[ \t]+/, "", t); return substr(t, 1, 2) == "- " }
    # The value token of a `key: value` line, as the stamp reads one: one token with no whitespace
    # and no quote, quoted or not, and nothing after it but a comment. "" where the line is no such line.
    function token(s,   rest, q, v) {
      if (!match(s, "^[ ]*(-[ ]+)?" key ":[ ]*")) return ""
      rest = substr(s, RLENGTH + 1); q = substr(rest, 1, 1)
      if (q == "\"" || q == "\047") { rest = substr(rest, 2); if (!match(rest, "^[^ \t\"\047]+")) return ""; v = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1); if (substr(rest, 1, 1) != q) return ""; rest = substr(rest, 2) }
      else { if (!match(rest, "^[^ \t\"\047]+")) return ""; v = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1) }
      return (rest ~ /^[ \t]*(#.*)?$/) ? v : ""
    }
    { line[NR] = $0; if (anchor != "" && trimmed($0) == anchor) { hits++; at = NR } }
    END {
      if (anchor == "") { first = 1; past = NR + 1; col = 0 }
      else {
        if (hits != 1) { printf "!holds the anchor \"%s\" %d times, and a stamp reads it exactly once\n", anchor, hits; exit }
        col = column(line[at]); first = at + 1; past = first
        while (past <= NR) { s = line[past]; if (!quiet(s)) { c = column(s); if (c < col || (item(s) && c <= col)) break }; past++ }
      }
      n = 0
      for (i = first; i < past; i++) {
        s = line[i]; if (quiet(s) || item(s) || column(s) != col) continue
        v = token(s); if (v != "") { n++; found = i; value = v }
      }
      if (n != 1) { printf "!holds %d values of \"%s\" under \"%s\", and a stamp writes exactly one\n", n, key, (anchor == "" ? "the top level" : anchor); exit }
      printf "%d\t%s\n", found, value
    }' "$1"
}
stamp_drifts() { # <tree root> — one line per yaml_value site of the platform tree that does not hold its pin
  local root="$1" pin sha file key anchor segments writes want got
  yq e '.. | select(tag == "!!map" and has("version") and has("stamps")) | . as $c | .stamps[]
        | select(.kind == "yaml_value" and .tree == "platform")
        | [$c.version, ($c.sha256 // "~"), .file, .key, (.anchor // "~"), (.segments // 0), (.writes // "version")] | @tsv' \
    "$root/clusters/platform/versions.yaml" |
  while IFS=$'\t' read -r pin sha file key anchor segments writes; do
    # yq prints an empty line for every component whose stamps the filter leaves none of.
    [ -n "$pin" ] || continue
    [ "$anchor" = '~' ] && anchor=''
    want="$pin"; [ "$writes" = sha256 ] && want="$sha"
    [ "$segments" -gt 0 ] && want="$(printf '%s' "$want" | cut -d. -f1-"$segments")"
    if [ ! -f "$root/$file" ]; then echo "$file is not there, and versions.yaml stamps $want into it"; continue; fi
    got="$(site_value "$root/$file" "$key" "$anchor")"
    case "$got" in
      '!'*) echo "$file ${got#!}" ;;
      *) [ "${got#*$'\t'}" = "$want" ] \
           || echo "$file:${got%%$'\t'*}: $key holds ${got#*$'\t'}, and versions.yaml pins $want" ;;
    esac
  done
}
# The planted drift and the planted innocent beside it: one site one version behind its pin, and
# one at its pin with a comment between its lines. The probe has to name the first and stay
# silent on the second, or a clean answer below means nothing.
probe="$work/stamp-probe"
mkdir -p "$probe/clusters/platform" "$probe/parts"
cat > "$probe/clusters/platform/versions.yaml" <<'PROBE'
images:
  drifted:
    version: "1.2.3"
    stamps:
      - kind: yaml_value
        tree: platform
        file: parts/values.yaml
        key: tag
        anchor: 'repository: example/drifted'
  innocent:
    version: "4.5.6"
    stamps:
      - kind: yaml_value
        tree: platform
        file: parts/values.yaml
        key: tag
        anchor: 'repository: example/innocent'
PROBE
cat > "$probe/parts/values.yaml" <<'PROBE'
drifted:
  image:
    repository: example/drifted
    tag: "1.2.2"
innocent:
  image:
    repository: example/innocent
    # the stamp reads past a comment
    tag: 4.5.6
PROBE
probed="$(stamp_drifts "$probe")"
[ "$probed" = 'parts/values.yaml:4: tag holds 1.2.2, and versions.yaml pins 1.2.3' ] \
  || fail "the stamp-site probe did not report exactly the planted drift and nothing else: ${probed:-nothing}"
echo "check: the stamp-site probe reports the planted drift and not the planted innocent."
drifts="$(stamp_drifts .)"
if [ -n "$drifts" ]; then
  printf '%s\n' "$drifts" | sed 's/^/  /'
  fail "a stamp site of this tree does not hold its pin — write the pin into it, or move the pin in clusters/platform/versions.yaml"
fi
echo "check: every yaml_value stamp site of this tree holds its pin from clusters/platform/versions.yaml, $(yq e '[.. | select(tag == "!!map" and has("stamps")) | .stamps[] | select(.kind == "yaml_value" and .tree == "platform")] | length' clusters/platform/versions.yaml) of them."

# ── The keys of clusters/platform/versions.yaml, held to what the versions grammar takes ──────
# `ansiwise --program sync-versions --mode dry` refuses the whole file for one key its kind does not
# take, before it plans anything, and nothing here ran that program: a reader of the file in another
# repository (hostyour-manager's engine repository once) had a key added that the pinned ansiwise
# then refused on every release. Each component, upstream and stamp is read here the way the loader
# reads it (a top-level map with a `version` is a component, any other top-level map a group of them).
#
# THE RULE IS THE ENGINE'S, COPIED ONCE: the key sets are ansiwise-plugins ansiwise-versions
# lib/src/declaration.dart at aef0ade, the ref of the ansiwise 0.8.321-stable-20261017151629 that
# versions.yaml pins: a component :449-450, the upstream kinds :544-591, the stamp kinds :594-682, and
# the refusal of a key its kind does not take :739-745. A key the engine adds later is not known here
# until the table below is copied again from the commit the pin then names.
# Coverage: the keys of every component, upstream and stamp of this file. Not covered: the sites of the
# `deploy` and `manager` trees (those repositories' to hold, above), and the answers of an upstream
# (report-versions). A dry run can still fail on a site of the `deploy` or `manager` tree that this
# tree cannot see.
declaration_records() { # <tree root> — "<label> <what> <kind> <keys>" per component, upstream and stamp, tab separated
  # A component is a top-level map with a `version`, or an entry of a top-level map that has none; an
  # entry that is no map or has no `version` is still a component record, which lacks its `version`.
  yq e '[ (to_entries | .[] | select(.value | tag == "!!map") | select(.value | has("version")) | {"label": .key, "body": .value}),
          (to_entries | .[] | select(.value | tag == "!!map") | select(.value | has("version") | not) | .key as $g | .value | to_entries | .[] | {"label": ($g + "/" + .key), "body": .value}),
          (to_entries | .[] | select(.value | tag != "!!map") | {"label": .key, "body": .value}) ]
        | .[] | .label as $l | .body as $b | (
          ([$l, "component", "~", (($b | select(tag == "!!map") | keys | join(",")) // "")] | @tsv),
          ($b | select(tag == "!!map") | select(has("upstream")) | .upstream | [$l, "upstream", (.kind // "~"), (keys | join(","))] | @tsv),
          ($b | select(tag == "!!map") | select(has("stamps")) | .stamps[] | [$l, "stamp", (.kind // "~"), (keys | join(","))] | @tsv))' \
    "$1/clusters/platform/versions.yaml"
}
declaration_faults() { # <records on stdin> — one line per key a kind does not take and per key it needs and lacks
  local label what kind keys needs takes key
  while IFS=$'\t' read -r label what kind keys; do
    [ -n "$label" ] || continue
    case "$what:$kind" in
      component:*) needs='version'; takes='sha256 note upstream stamps' ;;
      upstream:git_tags) needs='kind project matching'; takes='' ;;
      upstream:docker_hub) needs='kind image matching'; takes='' ;;
      upstream:oci_tags) needs='kind host image matching'; takes='' ;;
      upstream:chart_repository) needs='kind'; takes='' ;;
      upstream:helm_index) needs='kind repository chart'; takes='' ;;
      upstream:snap_channel) needs='kind snap'; takes='' ;;
      upstream:hashicorp_release) needs='kind product'; takes='' ;;
      stamp:yaml_value) needs='kind tree file key'; takes='anchor segments writes' ;;
      stamp:chart_dependency) needs='kind tree file dependency'; takes='' ;;
      stamp:list_pin) needs='kind tree file anchor entry'; takes='segments' ;;
      stamp:dockerfile_from) needs='kind tree file image'; takes='' ;;
      stamp:dockerfile_arg) needs='kind tree file argument'; takes='segments' ;;
      *) echo "$label: the $what of kind $kind is no kind the versions grammar knows"; continue ;;
    esac
    [ "$kind" = '~' ] && kind='' || kind=" of kind $kind"
    for key in ${keys//,/ }; do
      case " $needs $takes " in *" $key "*) ;; *) echo "$label: the $what$kind carries \"$key\", which it does not take" ;; esac
    done
    for key in $needs; do
      case ",$keys," in *",$key,"*) ;; *) echo "$label: the $what$kind lacks \"$key\", which it needs" ;; esac
    done
  done
}
# The planted defects and the planted innocents beside them: an oci_tags upstream carrying a
# `repository`, a yaml_value stamp carrying a key its kind does not take, and a list_pin stamp lacking
# a key it needs, a group member without a `version` (a typo) and a component nested one level too
# deep; a helm_index upstream carrying a `repository`, an oci_tags upstream with its three fields and a
# note on the component, and a top-level component with a version and a note and nothing else. The
# probe has to name the planted faults and stay silent on the rest.
probe="$work/declaration-probe"
mkdir -p "$probe/clusters/platform"
cat > "$probe/clusters/platform/versions.yaml" <<'PROBE'
images:
  planted-upstream:
    version: "1.0.0"
    upstream:
      kind: oci_tags
      host: registry.example.invalid
      image: example/engine
      repository: example/engine
      matching: '.*'
  planted-stamp:
    version: "2.0.0"
    stamps:
      - kind: yaml_value
        tree: platform
        file: parts/values.yaml
        key: tag
        column: 4
      - kind: list_pin
        tree: platform
        file: parts/values.yaml
        anchor: 'tools:'
  innocent-helm:
    version: "3.0.0"
    upstream:
      kind: helm_index
      repository: https://charts.example.invalid
      chart: example
  innocent-oci:
    version: "4.0.0"
    note: a note on the component
    upstream:
      kind: oci_tags
      host: registry.example.invalid
      image: example/engine
      matching: '.*'
  planted-typo:
    verison: "5.0.0"
innocent-top-level:
  version: "26.04"
  note: a component at the top level, which is no group
planted-nested:
  sub:
    deep:
      version: "6.0.0"
PROBE
probed="$(declaration_records "$probe" | declaration_faults)"
expected="$(printf '%s\n' \
  'images/planted-upstream: the upstream of kind oci_tags carries "repository", which it does not take' \
  'images/planted-stamp: the stamp of kind yaml_value carries "column", which it does not take' \
  'images/planted-stamp: the stamp of kind list_pin lacks "entry", which it needs' \
  'images/planted-typo: the component carries "verison", which it does not take' \
  'images/planted-typo: the component lacks "version", which it needs' \
  'planted-nested/sub: the component carries "deep", which it does not take' \
  'planted-nested/sub: the component lacks "version", which it needs')"
[ "$probed" = "$expected" ] \
  || fail "the declaration probe did not report exactly the planted faults and nothing else: ${probed:-nothing}"
echo "check: the declaration probe reports the planted faults and not the planted innocents."
records="$(declaration_records .)"
faults="$(printf '%s\n' "$records" | declaration_faults)"
if [ -n "$faults" ]; then
  printf '%s\n' "$faults" | sed 's/^/  /'
  fail "clusters/platform/versions.yaml holds a key the versions grammar refuses, and the dry run of the sync would stop at it — delete the key, or the engine that reads it takes it from the pin"
fi
printf '%s\n' "$records" | awk -F'\t' '
  { n[$2]++; keys += split($4, k, ",") }
  END { printf "check: every key of clusters/platform/versions.yaml is one its kind takes — %d components, %d upstreams, %d stamps, %d keys; not the sites of the deploy and manager trees, nor the answers of an upstream, so a dry run can still fail on a site this tree cannot see.\n", n["component"], n["upstream"], n["stamp"], keys }'

echo 'check: NOT RUN locally — lifecycle/test.sh; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/pipeline-release.test.sh; runs in the ci of the master via scripts/test.sh.'
bash -n scripts/pipeline-publish.test.sh || fail 'Bash syntax: scripts/pipeline-publish.test.sh'
echo 'check: NOT RUN locally — scripts/pipeline-publish.test.sh; runs in the ci of the master via scripts/test.sh.'
bash -n scripts/test.sh || fail 'Bash syntax: scripts/test.sh'
bash -n scripts/test-pool.test.sh || fail 'Bash syntax: scripts/test-pool.test.sh'
echo 'check: NOT RUN locally — scripts/test-pool.test.sh; runs in the ci of the master via scripts/test.sh.'
bash -n scripts/check-mirror-consumers.test.sh || fail 'Bash syntax: scripts/check-mirror-consumers.test.sh'
echo 'check: NOT RUN locally — scripts/check-mirror-consumers.test.sh; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/build-contract.test.mjs; runs in the ci of the master via scripts/test.sh.'
for module in scripts/release-queue.test.mjs scripts/site-telemetry.test.mjs scripts/ci-run-keeper.test.mjs scripts/ci-green-status.test.mjs scripts/cloudflare-origin-pull.test.mjs scripts/tenant-limits.test.mjs scripts/unit-networkpolicy.test.mjs scripts/loki-retention.test.mjs scripts/ingress-access-log-alert.test.mjs scripts/alloy-access-log-strip.test.mjs scripts/site-telemetry-registration.test.mjs scripts/site-telemetry-deployment.test.mjs; do
  node --check "$module" || fail "Node syntax: $module"
  echo "check: NOT RUN locally — $module; runs in the ci of the master via scripts/test.sh."
done
for module in scripts/check-immutable.mjs scripts/build-contract.test.mjs lifecycle/plan-installation-domain.mjs scripts/installation-domain.test.mjs scripts/post-stage-callbacks.test.mjs scripts/redis-maxmemory.test.mjs scripts/coredns-cache.test.mjs scripts/tenant-appset-fixture.mjs scripts/tenant-appset.test.mjs scripts/tenant-size.test.mjs scripts/tenant-own-domain-aliases.test.mjs scripts/tenant-proxied-hosts.test.mjs scripts/unit-alerts.test.mjs scripts/unit-mongodb-exporter.test.mjs scripts/unit-charts-consumer-project.test.mjs scripts/consumer-data-sizes.test.mjs scripts/e2e-runner.test.mjs; do
  node --check "$module" || fail "Node syntax: $module"
done
echo 'check: NOT RUN locally — scripts/manager-generator-refresh.test.mjs; runs in the ci of the master via scripts/test.sh.'
node --check scripts/manager-pat-storage.test.mjs || fail 'Manager PAT storage check syntax'
echo 'check: NOT RUN locally — scripts/manager-pat-storage.test.mjs; runs in the ci of the master via scripts/test.sh.'
node --check scripts/manager-forge-env.test.mjs || fail 'Manager forge env check syntax'
echo 'check: NOT RUN locally — scripts/manager-forge-env.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/installation-domain.test.mjs; runs in the ci of the master via scripts/test.sh.'
node --check scripts/zot-sync.test.mjs || fail 'Node syntax: scripts/zot-sync.test.mjs'
echo 'check: NOT RUN locally — scripts/zot-sync.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/post-stage-callbacks.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/redis-maxmemory.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/coredns-cache.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/tenant-appset.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/tenant-size.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/tenant-own-domain-aliases.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/tenant-proxied-hosts.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/unit-alerts.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/unit-mongodb-exporter.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/unit-charts-consumer-project.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/consumer-data-sizes.test.mjs; runs in the ci of the master via scripts/test.sh.'
echo 'check: NOT RUN locally — scripts/e2e-runner.test.mjs; runs in the ci of the master via scripts/test.sh.'
bash -n lifecycle/plan-installation-domain.sh || fail 'installation domain Bash syntax'
bash -n lifecycle/check-forgejo-ssh.sh || fail 'Forgejo SSH check Bash syntax'
bash -n lifecycle/create-origin-pull-certificate.sh || fail 'origin pull certificate Bash syntax'
bash -n lifecycle/apply-cloudflare-zone-security.sh || fail 'Cloudflare zone security Bash syntax'
bash -n lifecycle/release-unit.sh || fail 'release-unit Bash syntax'
for module in lifecycle/apply-cloudflare-zone-security.mjs lifecycle/apply-cloudflare-zone-security.test.mjs lifecycle/create-origin-pull-certificate.test.mjs lifecycle/release-unit.mjs scripts/standin/release-unit-manager.mjs; do
  node --check "$module" || fail "Node syntax: $module"
done
for module in scripts/forgejo.test.mjs scripts/plane-test-accounts.test.mjs scripts/forward-auth-gate.test.mjs scripts/plane.test.mjs scripts/forgejo-release.test.mjs scripts/forgejo-ssh.test.mjs; do
  node --check "$module" || fail "Node syntax: $module"
  echo "check: NOT RUN locally — $module; runs in the ci of the master via scripts/test.sh."
done

# ── 2. The credentials ──────────────────────────────────────────────────────────────────────
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
gitleaks detect --redact --no-git --no-banner --source "$scan" || fail "gitleaks found a credential"
# The allowlist of .gitleaks.toml for the two public default keys of the vendored plane-ce values.yaml hides those
# two values in that file and nothing else. The planted defects, each in a copy of the config and that file: a third
# key-shaped value added to it; one of the two values written into another file. The planted innocent: the file
# as vendored.
plant_leak() { # <name> <a command run in the copy> -> 0 when gitleaks finds nothing in that copy, 1 when it finds a leak
  local copy="$work/planted-leaks/$1" status
  rm -rf "$copy" && mkdir -p "$copy/$pl/charts/plane-ce" || fail "the planted leak '$1' could not be planted"
  cp .gitleaks.toml "$copy/" && cp "$pl/charts/plane-ce/values.yaml" "$copy/$pl/charts/plane-ce/" || fail "the planted leak '$1' could not be planted"
  ( cd "$copy" && eval "$2" ) || fail "the planted leak '$1' could not be planted"
  gitleaks detect --redact --no-git --no-banner --source "$copy" >/dev/null 2>&1
  status=$?
  [ "$status" -le 1 ] || fail "gitleaks failed on the planted leak '$1' with status $status"
  return "$status"
}
plant_leak vendored true || fail "gitleaks reports the vendored plane-ce values.yaml, whose public default keys .gitleaks.toml allows"
plant_leak third "sed -i 's|^  sentry_dsn: \"\"|  admin_secret_key: \"Zk3Qw9Lm2Xv7Bn5Rt1Yc4Hd6Jp0Sf8Ga\"\n&|' $pl/charts/plane-ce/values.yaml" \
  && fail "gitleaks does not report a third key-shaped value added to the vendored plane-ce values.yaml"
plant_leak elsewhere "printf 'secret_key: \"60gp0byfz2dvffa45cxl20p1scy9xbpf6d8c5y0geejgkyp1b5\"\\n' > other.yaml" \
  && fail "gitleaks does not report a public default key of plane-ce written into another file"
echo "check: the .gitleaks.toml allowlist for plane-ce's public default keys hides them in the vendored values.yaml only; gitleaks reports 2 planted defects and passes the innocent case."

echo "check: OK — every check green"
