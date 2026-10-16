#!/usr/bin/env bash
# The tools and charts the owner's mirror holds: one line per row of clusters/platform/mirror-sources.table,
# with the names the mirror serves it under.
#
#   bash scripts/list-mirror-sources.sh [<table>]    the lines of the table, clusters/platform/mirror-sources.table unless named
#
# A LINE is `tool <url> <sha256> <owned reference> <owned address>` or
# `chart <repository> <chart> <version> <sha256> <owned reference> <owned address>`, both names under the
# <registry>/<owner> of global.buildRegistry in clusters/platform/values-common.yaml. The owned reference is
# the tag a row stands under in the mirror; the owned address is what a consumer reads without a login, the
# blob of a tool or the oci repository a chart is pulled from by helm.
#
# ONE DERIVATION, EVERY READER. The forms and the names are the functions of
# clusters/inventories/consumer-build/files/mirror-sources.sh, which the steps fetch, copy-sources and
# read-back-sources of the mirror task in pipeline-publish.yaml include and hold every line to again. The
# fetch step runs this script on the tree at the tag, and scripts/check.sh runs it over the table, so a row
# of another form, a sha256 that is not 64 lower-case hex digits and a row that stands twice fail by line
# number before a push.
set -uo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
table="${1:-$root/clusters/platform/mirror-sources.table}"
fail() { echo "list-mirror-sources: FAIL — $1" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || fail "yq is not on this path, and global.buildRegistry is read with it"
[ -f "$table" ] || fail "$table does not exist"
# shellcheck source=../clusters/inventories/consumer-build/files/mirror-sources.sh
. "$root/clusters/inventories/consumer-build/files/mirror-sources.sh"

registry="$(yq '.global.buildRegistry' "$root/clusters/platform/values-common.yaml")"
[[ "$registry" =~ ^[a-z0-9.-]+/[a-z0-9._-]+$ ]] \
  || fail "clusters/platform/values-common.yaml names no global.buildRegistry of the form <host>/<owner>, so the mirror has no name"
REGISTRY="${registry%%/*}" OWNER="${registry#*/}"

number=0 seen=" "
while IFS= read -r row || [ -n "$row" ]; do
  number=$((number + 1))
  read -r -a fields <<< "${row%%#*}"
  [ "${#fields[@]}" -gt 0 ] || continue
  line="$(mirror_source_line "${fields[@]}")" || fail "$table:$number: $line"
  read -r -a parts <<< "$line"
  reference="${parts[${#parts[@]} - 2]}"
  case "$seen" in *" $reference "*) fail "$table:$number: $reference has a row above already" ;; esac
  seen="$seen$reference "
  printf '%s\n' "$line"
done < "$table"
