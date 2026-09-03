#!/usr/bin/env bash
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
# in PowerShell, and it holds the two spellings to printing the same bytes.
missing=""
for tool in helm gitleaks pwsh; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -n "$missing" ] && fail "these tools are not on this path:$missing"

work="$(mktemp -d)" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT

# ── What an installation answers ────────────────────────────────────────────────────────────
# The stand-in cluster map. It stands where clusters/active/<fqdn>.yaml stands in every chart's
# valueFiles chain: last, after the platform globals and the chart's own values.
#
# WITHOUT IT ALMOST NOTHING RENDERS, and that is the trunk working as designed. The endpoint
# keys in clusters/platform/values-common.yaml are deliberately empty there — every reader wraps
# them in `required`, so a cluster that was given no address is stopped rather than dialling
# nothing. Measured on this tree: 7 of the 24 charts render without this file and 17 do not, so
# a check that skipped them would leave the manager, the registry and the observability charts
# unrendered while reporting itself green.
#
# THE ANSWERS ARE STAND-INS AND NAME NOTHING REAL. configs/config.example declares the keys an
# installation is asked for and leaves every one of them empty on purpose, so it can give a
# domain to nobody. The domain here is under .invalid, which is reserved and resolves nowhere.
#
# THE SHAPE IS THE CONTRACT, not the values: it is the shape the run that generates an install
# branch writes, and a chart that starts reading a key this file does not carry will say so by
# name at the render.
cat > "$work/cluster-map.yaml" <<'CLUSTER_MAP'
stage: dev
role: master
booksCluster: check.example.invalid
release: 0.0.0-placeholder

global:
  domain: check.example.invalid
  clusterName: check
  booksCluster: check.example.invalid
  buildPlane: check.example.invalid
  unitApex: check.example.invalid
  platformDomain: check.example.invalid
  letsencryptEmail: check@check.example.invalid
  letsencryptServer: https://acme-staging-v02.api.letsencrypt.org/directory
  alertRecipients: ['check@check.example.invalid']
  catalogUrl: https://github.com/check/check.git
  catalogRepo: check/check
  vaultKubernetesAuthPath: kubernetes-check
  registryPullUser: check-pull
  registryPushUser: check-push
  nodeCidrs: [10.0.0.1/32]
  endpoints:
    registry:
      host: zot.check.example.invalid
    mail: {url: 'https://mail.check.example.invalid'}
    vault: {url: 'https://vault.check.example.invalid'}
    idp: {url: 'https://idp.check.example.invalid'}
    tailnet: {url: 'https://tale.check.example.invalid'}
  servicesLocal:
    registry: true
    vault: true
    observability: true
CLUSTER_MAP

# The stand-in registration, for the charts an ApplicationSet hands per-unit and per-slave facts
# to at deploy time. A unit chart's own values declare these keys empty and `required` on
# purpose — a default there would be a second source for a number the registration already
# states — so the numbers below are what lets those charts be rendered at all. They bound
# nothing: no cluster ever reads this file.
cat > "$work/registration.yaml" <<'REGISTRATION'
suspended: false
quiesced: false
tenant:
  guid: 00000000-0000-0000-0000-000000000000
  member: check
  appName: check
  subdomain: check
  stage: dev
quota:
  requestsCpu: "1"
  requestsMemory: 1Gi
  limitsCpu: "2"
  limitsMemory: 2Gi
  pods: "10"
  persistentVolumeClaims: "4"
slave:
  name: check
  branch: check.example.invalid
  apiHost: 10.0.0.1
  apiPort: "16443"
  masterFqdn: check.example.invalid
  stage: dev
externalsecret-mongodb:
  externalSecret:
    vaultPath: secret/dev/units/check/mongodb
externalsecret-postgres:
  externalSecret:
    vaultPath: secret/dev/units/check/postgres
REGISTRATION

# ── 1. The charts ───────────────────────────────────────────────────────────────────────────
echo "check: rendering every chart under clusters/inventories, clusters/units and clusters/slaves."

stages="dev test prod"
rendered=0
skipped_library=""
needed_standin=""
broken=""

for chart in clusters/inventories/*/ clusters/units/*/ clusters/slaves/*/; do
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
    # The valueFiles chain of clusters/argocd/apps, in its order: the platform globals, then the
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
      continue
    fi

    # It did not render from what the trunk carries. That is the normal case and not yet a
    # finding: the installation's own answers load last in the chain, and the trunk has none.
    out="$(helm template "$name" "$chart" --namespace "$namespace" \
      "${args[@]}" -f "$work/cluster-map.yaml" -f "$work/registration.yaml" 2>&1)"
    if [ $? -eq 0 ]; then
      rendered=$((rendered + 1))
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

# ── 2. The delivery programs ────────────────────────────────────────────────────────────────
echo "check: lifecycle/test.sh — the release, the regeneration, the migration, the report and the slave removal, in both spellings. About a minute."
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
echo "check: gitleaks over the files git would let you commit."
scan="$work/scan"
mkdir -p "$scan" || fail "the scan directory could not be made"
git ls-files --cached --others --exclude-standard -z \
  | xargs -0 cp --parents -t "$scan" \
  || fail "the committable files could not be collected for the credential scan"
gitleaks detect --no-git --no-banner --source "$scan" || fail "gitleaks found a credential"

echo "check: OK — every check green"
