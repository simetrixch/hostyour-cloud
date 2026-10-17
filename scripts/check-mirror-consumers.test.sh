#!/usr/bin/env bash
# The tests of scripts/check-mirror-consumers.sh: it runs over temporary trees, each written at test
# time, and every case states what the check must say. A defect is planted for each shape it refuses:
# the five addresses of an upstream, a blob address whose hex no tool row has, a chart version no chart
# row has, an allowlist entry no chart row carries, a table row written at another path, and a
# consumer of each kind that names a version, a hex or a variable the table or the file does not
# have. Each must fail naming its file:line. The innocents must pass: an owned address that carries
# the words of an upstream in its path, at every kind of consumer place; the table row at the one path
# that may hold it; and an owned address in a file of no consumer kind and in a comment, which are
# listed as not read.
#
# Every refused address is spelled here, so this file is one of the files the check does not read.
#
#   bash scripts/check-mirror-consumers.test.sh
set -uo pipefail
root="$(git rev-parse --show-toplevel)" || exit 1
check="$root/scripts/check-mirror-consumers.sh"
fail() { echo "check-mirror-consumers.test: RED — $*" >&2; exit 1; }
ok() { echo "check-mirror-consumers.test: ok — $*"; }
for tool in git yq; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on this path, and the check runs it"; done
work="$(mktemp -d)" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT

# What the table gives: its first tool and its first chart, and the base of the owned names.
bash "$root/scripts/list-mirror-sources.sh" > "$work/rows" || fail "the table gives no rows"
read -r -a tool_row <<< "$(grep -m1 '^tool ' "$work/rows")"
read -r -a chart_row <<< "$(grep -m1 '^chart ' "$work/rows")"
tool_address="${tool_row[4]}" tool_hex="${tool_row[2]}"
tool_tag="${tool_row[1]%/*}"; tool_tag="${tool_tag##*/}"
tool_version="${tool_tag#v}"
chart_repository="${chart_row[6]}" chart_name="${chart_row[2]}" chart_version="${chart_row[3]}"
registry="$(yq '.global.buildRegistry' "$root/clusters/platform/values-common.yaml")" || fail "global.buildRegistry could not be read"
unknown_hex="$(printf '%064d' 0)"
step_address="${tool_address//$tool_tag/<version>}"; step_address="${step_address//$tool_hex/<sha256>}"
row_address="${tool_address//$tool_hex/<sha256>}"
# shellcheck disable=SC2016
shell_slot='${planted_sha256}' argument_slot='${PLANTED_SHA256}'
variable_address="${tool_address//$tool_hex/$shell_slot}" argument_address="${tool_address//$tool_hex/$argument_slot}"

new_tree() { # <name>: an empty directory
  rm -rf "${work:?}/$1"; mkdir -p "$work/$1"; printf '%s\n' "$work/$1"
}
put() { # <file> <line>...: the file, with those lines, below its directory
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"; printf '%s\n' "$@" > "$file"
}
line_of() { grep -n -m1 -F -- "$2" "$1" | cut -d: -f1; } # <file> <text>: the line number of the first line holding the text
mutate() { # <file> <sed expression>
  sed "$2" "$1" > "$1.mutated" && mv "$1.mutated" "$1"
}
copy_tree() { # <from> <to>
  rm -rf "${work:?}/$2"; cp -R "$1" "$work/$2"; printf '%s\n' "$work/$2"
}

# A tree with an owned address at every kind of consumer place, each of which the table holds.
consumers="$(new_tree consumers)"
put "$consumers/ansiwise/programs/deploy-cluster.yaml" 'answers:' '      - name: planted' 'steps:' \
  '  - step: install_pinned_tool' \
  "    tool: planted" \
  "    version: $tool_tag" \
  "    url: $step_address" \
  "    sha256: $tool_hex" \
  '  - step: helm_release' \
  '    release: planted' \
  "    chart: $chart_repository/$chart_name" \
  "    chart_version: '$chart_version'"
put "$consumers/clusters/inventories/consumer-build/files/ci-tools.table" \
  "planted $tool_version $tool_hex $row_address"
put "$consumers/clusters/inventories/consumer-build/files/ci-fixed-tools.sh" \
  "planted_sha256=$tool_hex" \
  "curl -fsSL -o /tmp/planted \"$variable_address\""
put "$consumers/gate-runner/Containerfile" \
  "ARG PLANTED_SHA256=$tool_hex" \
  "RUN curl -fsSL -o /tmp/planted \"$argument_address\""
put "$consumers/clusters/inventories/planted/Chart.yaml" 'apiVersion: v2' 'name: planted' 'version: 1.0.0' 'dependencies:' \
  "  - name: $chart_name" \
  "    version: $chart_version" \
  "    repository: $chart_repository"
put "$consumers/clusters/argocd/files/projects.yaml" 'spec:' '  sourceRepos:' '    - https://example.invalid/repo.git' "    - $chart_repository"
put "$consumers/clusters/units/reconciler/values.yaml" "exporterChartsUrl: $chart_repository"
put "$consumers/ansiwise/templates/slave-appproject.tpl" 'spec:' '  sourceRepos:' "    - $chart_repository"

run() { bash "$check" "$@" 2>&1; }
shows() { grep -qF -- "$2" <<< "$1"; } # <output> <text>
expect_red() { # <what> <tree> <path:line the check must name> <text the line must hold>
  local output status
  output="$(run "$2")"; status=$?
  [ "$status" -eq 1 ] || fail "the check passes a planted $1 (exit $status)"
  shows "$output" "REFUSE — $3 (" || fail "the check fails a planted $1 without naming $3: $output"
  shows "$output" "$4" || fail "the check names $3 for a planted $1 without saying: $4"
  ok "planted defect, $1, refused at $3"
}
expect_green() { # <what> <tree> <count line> [<text the output must show>]...
  local what="$1" output status
  output="$(run "$2")"; status=$?
  [ "$status" -eq 0 ] || fail "the check refuses the innocent $what: $output"
  shows "$output" "$3" || fail "the innocent $what is not counted as '$3': $output"
  shift 3
  while [ "$#" -gt 0 ]; do shows "$output" "$1" || fail "the check does not show '$1' for the innocent $what: $output"; shift; done
  ok "innocent, $what, passes"
}

# The five addresses of an upstream, each in a file whose name no exclusion holds, on the third line.
shape_cases=(
  "a GitHub Release asset|see https://github.com/someone/tool/releases/download/v1.0.0/tool_linux_amd64 for it|://github.com/someone/tool/releases/download/"
  "a GitHub Pages host|charts at https://someone.github.io/charts|://someone.github.io"
  "an oci address on the GitHub container registry|pull oci://ghcr.io/someone/charts/thing|oci://ghcr.io/"
  "the Plane chart repository|repository https://helm.plane.so|://helm.plane.so"
  "the Authentik chart repository|repository https://charts.goauthentik.io|://charts.goauthentik.io"
)
for shape_case in "${shape_cases[@]}"; do
  IFS='|' read -r what text shown <<< "$shape_case"
  tree="$(new_tree shape)"
  put "$tree/docs/note.md" '# notes' 'nothing here' "$text"
  expect_red "$what" "$tree" docs/note.md:3 "$shown"
done

# A table row at a path other than the table's, in a tree that is the platform tree and holds the table at its own path.
platform="$(new_tree platform)"
mkdir -p "$platform/clusters/platform"
cp "$root/clusters/platform/values-common.yaml" "$platform/clusters/platform/values-common.yaml"
cp "$root/clusters/platform/mirror-sources.table" "$platform/clusters/platform/mirror-sources.table"
expect_green "the table row at clusters/platform/mirror-sources.table of the platform tree, the one path allowed to name an upstream" "$platform" \
  "refused shapes 0" "excluded: clusters/platform/mirror-sources.table"
cp "$root/clusters/platform/mirror-sources.table" "$platform/clusters/platform/other.table"
rm "$platform/clusters/platform/mirror-sources.table"
expect_red "table row at another path" "$platform" "clusters/platform/other.table:$(line_of "$platform/clusters/platform/other.table" 'tool https://')" "://github.com/"

# An excluded name binds to its tree: the same file in a tree of no repository is read.
named="$(new_tree named)"
put "$named/scripts/pipeline-publish.test.sh" 'echo planted' 'tool=https://github.com/someone/tool/releases/download/v1.0.0/tool_linux_amd64'
expect_red "excluded file name in a tree of another repository" "$named" scripts/pipeline-publish.test.sh:2 "://github.com/someone/tool/releases/download/"
mkdir -p "$named/clusters/platform"; cp "$root/clusters/platform/values-common.yaml" "$named/clusters/platform/values-common.yaml"
expect_green "excluded file name in the platform tree" "$named" "refused shapes 0" "excluded: scripts/pipeline-publish.test.sh"

# Consumers the table does not hold.
tree="$(new_tree blob)"
put "$tree/clusters/inventories/consumer-build/files/ci-tools.table" 'node 26.11.1 15fc043a51a5783f2f4b634561091658f5a7f0e3db03f997dca3a8033a33e45b https://nodejs.org/dist/v26.11.1/node-v26.11.1-linux-x64.tar.gz' \
  "planted $tool_version $unknown_hex $row_address"
expect_red "blob address whose hex has no row" "$tree" "clusters/inventories/consumer-build/files/ci-tools.table:2" "${tool_address//$tool_hex/$unknown_hex}"
tree="$(new_tree chart-version)"
put "$tree/clusters/inventories/planted/Chart.yaml" 'apiVersion: v2' 'name: planted' 'version: 1.0.0' 'dependencies:' \
  "  - name: $chart_name" '    version: 0.0.1' "    repository: $chart_repository"
expect_red "chart version without its row" "$tree" "clusters/inventories/planted/Chart.yaml:7" "the chart $chart_name at 0.0.1"
tree="$(new_tree allowlist)"
put "$tree/clusters/argocd/files/projects.yaml" 'spec:' '  sourceRepos:' '    - https://example.invalid/repo.git' "    - oci://$registry/nosuch.example.invalid/charts"
expect_red "allowlist entry no row carries" "$tree" "clusters/argocd/files/projects.yaml:4" "the allowlist entry oci://$registry/nosuch.example.invalid/charts"

# One consumer of each kind that names what the table or its own file does not have.
tree="$(copy_tree "$consumers" program-version)"
mutate "$tree/ansiwise/programs/deploy-cluster.yaml" "s/version: $tool_tag/version: v0.0.1/"
expect_red "install_pinned_tool step of a version no row has" "$tree" "ansiwise/programs/deploy-cluster.yaml:$(line_of "$tree/ansiwise/programs/deploy-cluster.yaml" 'url:')" "no tool row of the table has this owned address"
tree="$(copy_tree "$consumers" program-chart)"
mutate "$tree/ansiwise/programs/deploy-cluster.yaml" "s/chart_version: '$chart_version'/chart_version: '0.0.1'/"
expect_red "helm_release step of a chart version no row has" "$tree" "ansiwise/programs/deploy-cluster.yaml:$(line_of "$tree/ansiwise/programs/deploy-cluster.yaml" 'chart: ')" "the chart $chart_name at 0.0.1"
tree="$(copy_tree "$consumers" variable-hex)"
mutate "$tree/clusters/inventories/consumer-build/files/ci-fixed-tools.sh" "s/^planted_sha256=.*/planted_sha256=$unknown_hex/"
expect_red "shell variable whose hex has no row" "$tree" "clusters/inventories/consumer-build/files/ci-fixed-tools.sh:$(line_of "$tree/clusters/inventories/consumer-build/files/ci-fixed-tools.sh" curl)" "${tool_address//$tool_hex/$unknown_hex}"
tree="$(copy_tree "$consumers" variable-unset)"
mutate "$tree/gate-runner/Containerfile" "s/^ARG PLANTED_SHA256=.*/ARG PLANTED_SHA256/"
expect_red "Containerfile ARG without a value" "$tree" "gate-runner/Containerfile:$(line_of "$tree/gate-runner/Containerfile" RUN)" 'which the file gives no value'

# The innocents: the owned address carries github.com/…/releases/download/ and .github.io in its path, and stands at every kind of consumer place.
expect_green "owned addresses at nine consumer places, each held by its row" "$consumers" \
  "addresses found 9 = held 9 + not read 0 + refused 0" "refused shapes 0" "read by a consumer of these trees 2 + read by none"

# An owned address that no consumer reads: in a file of no consumer kind, and in a comment of a Chart.yaml beside its dependencies. Listed, not failed.
tree="$(new_tree not-read)"
put "$tree/notes/mirror.md" "The tool is served at $tool_address."
expect_green "owned address in a file of no consumer kind" "$tree" \
  "addresses found 1 = held 0 + not read 1 + refused 0" "not read: notes/mirror.md:1 (unnamed)"
tree="$(copy_tree "$consumers" comment)"
put "$tree/clusters/inventories/planted/Chart.yaml" 'apiVersion: v2' 'name: planted' 'version: 1.0.0' \
  "# The chart is served at $chart_repository, which is no dependency." \
  'dependencies:' "  - name: $chart_name" "    version: $chart_version" "    repository: $chart_repository"
put "$tree/clusters/argocd/files/projects.yaml" 'spec:' '  sourceRepos:' "    # oci://$registry/nosuch.example.invalid/charts is no entry." '    - https://example.invalid/repo.git' "    - $chart_repository"
expect_green "owned address in a comment of a Chart.yaml beside its dependencies, and of an allowlist" "$tree" \
  "addresses found 11 = held 9 + not read 2 + refused 0" "not read: clusters/inventories/planted/Chart.yaml:4 (hostyour-deploy)" \
  "not read: clusters/argocd/files/projects.yaml:3 (hostyour-deploy)"

echo "check-mirror-consumers.test: OK — every planted defect refused by file:line, every innocent passed"
