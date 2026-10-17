#!/usr/bin/env bash
# Holds every consumer of the owner's mirror to the table of what the mirror copies, and refuses every
# address of an upstream that the table alone may name.
#
#   bash scripts/check-mirror-consumers.sh <tree>...
#
# A <tree> is a directory: a checkout, of which the check reads every file git tracks, or an archive
# or a temporary tree, of which it reads every file. The tree this script stands in is the platform
# tree. From it the check reads scripts/list-mirror-sources.sh, clusters/inventories/consumer-build/
# files/mirror-sources.sh (which that script sources), clusters/platform/mirror-sources.table and
# clusters/platform/values-common.yaml, and nothing else, because a test of another repository takes
# that platform tree as an archive of those paths and this script. The platform tree is read as a tree
# only where it is named.
#
# REFUSED, in every file read: an address of a GitHub Release asset, of a GitHub Pages host, of a chart
# on ghcr.io as an oci address, of helm.plane.so and of charts.goauthentik.io, each with its host right
# after the scheme. An owned address carries github.com/<owner>/<name>/releases/download/ or
# <name>.github.io in its path, after the owner, and is no hit. An image on ghcr.io without the oci
# scheme is not refused. Five files may spell such an address, because they are the table or a test
# whose every refused shape is a planted case that nothing fetches; EXCLUDED below names each with its
# tree and its reason.
#
# HELD, at a consumer place: an owned address is text that names <registry>/v2/<owner>/ or
# oci://<registry>/<owner>, the two read from global.buildRegistry. A consumer place is where a consumer
# reads a row:
#   a tool's blob address: the url of an install_pinned_tool step of hostyour-deploy ansiwise/programs,
#     the rows of ci-tools.table, the shell variables of ci-fixed-tools.sh, the ARGs of a Containerfile
#     (gate-runner/Containerfile). With <version> and <sha256> filled from the same step or row, and
#     ${name} from the file's own variable or ARG, the address must be a tool row's owned address, so
#     its version and sha256 are the row's.
#   a chart: the repository, name and version of a dependency of a Chart.yaml, and the chart with its
#     chart_version of a helm_release step. They must be a chart row at that version.
#   an allowlist entry: clusters/argocd/files/projects.yaml, exporterChartsUrl of clusters/units/
#     reconciler/values.yaml and hostyour-deploy ansiwise/templates/slave-appproject.tpl. It must be the
#     owned repository of at least one chart row.
# Every other owned address is NOT READ: a file of no consumer kind, or a line of a consumer-kind file
# that is no consumer place, such as a comment. Nothing fills its slots there. It is printed by
# file:line and fails nothing, and the counts of addresses found, held and not read add up.
#
# UNREAD ROWS are listed and fail nothing: a bump adds its row before its consumer moves, and a row may
# be read by a tree this run does not read.
# The awk programs and the sh -c body are single-quoted on purpose: nothing in them is for this shell to expand.
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
me=check-mirror-consumers
fail() { echo "$me: FAIL — $1" >&2; exit 1; }
[ "$#" -ge 1 ] || fail "name the trees to read: bash scripts/check-mirror-consumers.sh <tree>..."
for tool in awk git grep sed sort tr xargs yq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on this path, and the check runs it"
done
work="$(mktemp -d)" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT

# A tree is named by the file only its repository has. EXCLUDED is <tree>|<path>|<reason>.
EXCLUDED=(
  "hostyour-cloud|clusters/platform/mirror-sources.table|the one place allowed to name an upstream address"
  "hostyour-cloud|scripts/check-mirror-consumers.test.sh|its own test, which writes every refused shape into a temporary tree"
  "hostyour-cloud|scripts/pipeline-publish.test.sh|the tests of the mirror steps: their planted tool rows can only be GitHub Release assets by the form of the table, and they fetch no address, every curl and helm call going to a local fake registry or a fake"
  "hostyour-deploy|scripts/owned-storage.test.mjs|the test of the installer's consumers: its refused shapes are planted defects written into objects in memory and never fetched, and it reads the programs with yq and fetches nothing"
  "hostyour-manager|fitness/gate-runner-tools-from-mirror.test.mjs|the test of the gate-runner image's fetch: its refused shape is a planted defect, a string replaced into the Containerfile text in memory and fetched by nothing"
)
# SHAPES is <name>|<extended regular expression>; the host stands right after the scheme.
SHAPES=(
  'a GitHub Release asset|://github\.com/[^/ ]+/[^/ ]+/releases/download/'
  'a GitHub Pages host|://[A-Za-z0-9._-]+\.github\.io'
  'an oci address on the GitHub container registry|oci://ghcr\.io/'
  'the Plane chart repository|://helm\.plane\.so'
  'the Authentik chart repository|://charts\.goauthentik\.io'
)
shapes_re=""
for shape in "${SHAPES[@]}"; do shapes_re="${shapes_re:+$shapes_re|}${shape#*|}"; done

tree_name() { # <directory>: the repository whose own file it holds
  if [ -f "$1/clusters/platform/values-common.yaml" ]; then echo hostyour-cloud
  elif [ -f "$1/ansiwise/programs/deploy-cluster.yaml" ]; then echo hostyour-deploy
  elif [ -f "$1/gate-runner/Containerfile" ]; then echo hostyour-manager
  else echo unnamed; fi
}

bash "$root/scripts/list-mirror-sources.sh" > "$work/rows" || fail "the table gives no rows (list-mirror-sources.sh says why above)"
registry="$(yq '.global.buildRegistry' "$root/clusters/platform/values-common.yaml")" || fail "global.buildRegistry could not be read"
host="${registry%%/*}" owner="${registry#*/}"
host_re="${host//./\\.}" owner_re="${owner//./\\.}"
word="[^[:space:]\"'(),\`]*"
owned_re="$word($host_re/v2/$owner_re/|oci://$host_re/$owner_re)$word"
awk '$1 == "tool" { print $5 }' "$work/rows" > "$work/tool-addresses"
awk '$1 == "chart" { printf "%s\t%s\t%s\n", $7, $3, $4 }' "$work/rows" > "$work/chart-keys"
awk '$1 == "chart" { print $7 }' "$work/rows" | sort -u > "$work/chart-repositories"
: > "$work/read-tools"; : > "$work/read-charts"
: > "$work/shapes"; : > "$work/held"; : > "$work/notread"; : > "$work/refused"

# The fields of the list item that holds line `want`, as <key> TAB <line> TAB <value> for each key at the
# item's own indent. An item starts at a dash and a line whose first key is `item` (any key where it is
# empty), and only items at the indent of the first such dash count. `section` names the top-level key whose
# items count; with none, the items of every top-level key do.
BLOCK_AWK='
function flush(end,   k) {
  if (begin && want >= begin && want <= end) for (k = 1; k <= n; k++) print key[k] "\t" at[k] "\t" val[k]
  begin = 0; n = 0
}
BEGIN {
  inside = (section == ""); dash = -1
  if (item == "") item = "[A-Za-z_][A-Za-z0-9_-]*"
  start = "^[[:space:]]*-[[:space:]]+" item ":"
}
section != "" && /^[^[:space:]#-]/ { flush(NR - 1); inside = ($0 ~ ("^" section ":")); next }
inside && $0 ~ start {
  match($0, /^[[:space:]]*/)
  if (dash < 0) dash = RLENGTH
  if (RLENGTH == dash) { flush(NR - 1); begin = NR; match($0, /^[[:space:]]*-[[:space:]]+/); keycol = RLENGTH }
}
begin && inside {
  match($0, /^[[:space:]]*/)
  if (NR == begin || RLENGTH == keycol) {
    body = substr($0, keycol + 1)
    if (body ~ /^[A-Za-z_][A-Za-z0-9_-]*:([[:space:]]|$)/) {
      name = body; sub(/:.*/, "", name)
      value = body; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/[[:space:]]+#.*$/, "", value); sub(/[[:space:]]+$/, "", value)
      sub(/^["\047]/, "", value); sub(/["\047]$/, "", value)
      n++; key[n] = name; at[n] = NR; val[n] = value
    }
  }
}
END { flush(NR) }
'
# NAME TAB value of a file: the assignments at the start of a line and the ARG defaults, the first of a name.
VARIABLES_AWK='
/^(ARG[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/ {
  text = $0; sub(/^ARG[[:space:]]+/, "", text)
  name = text; sub(/=.*/, "", name)
  value = text; sub(/^[^=]*=/, "", value); sub(/^["\047]/, "", value); sub(/["\047]$/, "", value)
  if (!(name in seen)) { seen[name] = 1; print name "\t" value }
}
'
# Each ${name} of stdin replaced by its value from the file of NAME TAB value; an unset name is printed as UNSET and stops.
FILL_AWK='
FILENAME == ARGV[1] { split($0, part, "\t"); value[part[1]] = substr($0, length(part[1]) + 2); next }
{
  out = $0
  while (match(out, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
    name = substr(out, RSTART + 2, RLENGTH - 3)
    if (!(name in value)) { print "UNSET " name; exit 1 }
    out = substr(out, 1, RSTART - 1) value[name] substr(out, RSTART + RLENGTH)
  }
  print out
}
'

block_value() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $3; exit }'; }
block_key_at() { printf '%s\n' "$1" | awk -F'\t' -v l="$2" '$2 == l { print $1; exit }'; }

# The occurrence being classified: where it stands, and what the verdict prints.
occurrence_path="" occurrence_line="" occurrence_label="" occurrence_token=""
describe() { printf '%s:%s (%s): %s' "$occurrence_path" "$occurrence_line" "$occurrence_label" "$occurrence_token"; }
hold() { describe >> "$work/held"; echo >> "$work/held"; }
leave_unread() { describe >> "$work/notread"; echo >> "$work/notread"; }
refuse() { { describe; printf ' — %s\n' "$1"; } >> "$work/refused"; }

hold_tool() { # <blob address, slots filled>: the address the line stands for is the one printed
  occurrence_token="$1"
  if grep -qxF -- "$1" "$work/tool-addresses"; then
    printf '%s\n' "$1" >> "$work/read-tools"
    hold
  else
    refuse "no tool row of the table has this owned address, so its version or its sha256 is not a row's"
  fi
}
hold_chart() { # <repository> <chart> <version>
  if grep -qxF -- "$1"$'\t'"$2"$'\t'"$3" "$work/chart-keys"; then
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$work/read-charts"
    hold
  else
    refuse "the chart $2 at $3 on $1 is no row of the table"
  fi
}
hold_allowed() { # <repository>
  if grep -qxF -- "$1" "$work/chart-repositories"; then hold; else refuse "the allowlist entry $1 is the owned repository of no chart row of the table"; fi
}

classify() { # <tree directory>: the occurrence above, by the kind of file it stands in
  local tree="$1" file text block key filled vars name version sha256 prefix entry
  file="$tree/$occurrence_path"
  text="$(sed -n "${occurrence_line}p" "$file")"
  case "$occurrence_path" in
    ansiwise/programs/*.yaml)
      block="$(awk -v want="$occurrence_line" -v item=step "$BLOCK_AWK" "$file")"
      key="$(block_key_at "$block" "$occurrence_line")"
      case "$(block_value "$block" step):$key" in
        install_pinned_tool:url)
          filled="$(block_value "$block" url)"
          filled="${filled//<version>/$(block_value "$block" version)}"
          hold_tool "${filled//<sha256>/$(block_value "$block" sha256)}" ;;
        helm_release:chart)
          hold_chart "${occurrence_token%/*}" "${occurrence_token##*/}" "$(block_value "$block" chart_version)" ;;
        *) leave_unread ;;
      esac ;;
    Chart.yaml | */Chart.yaml)
      block="$(awk -v want="$occurrence_line" -v section=dependencies "$BLOCK_AWK" "$file")"
      if [ "$(block_key_at "$block" "$occurrence_line")" = repository ]; then
        hold_chart "$occurrence_token" "$(block_value "$block" name)" "$(block_value "$block" version)"
      else
        leave_unread
      fi ;;
    clusters/inventories/consumer-build/files/ci-tools.table)
      read -r name version sha256 filled _ <<< "$text"
      case "$name" in
        '#'* | '') leave_unread ;;
        *)
          if [ "$filled" = "$occurrence_token" ]; then
            filled="${filled//<version>/$version}"
            hold_tool "${filled//<sha256>/$sha256}"
          else
            leave_unread
          fi ;;
      esac ;;
    clusters/inventories/consumer-build/files/ci-fixed-tools.sh | gate-runner/Containerfile)
      if [[ "$text" =~ ^[[:space:]]*# ]]; then
        leave_unread
      else
        vars="$work/variables"
        awk "$VARIABLES_AWK" "$file" > "$vars"
        if filled="$(printf '%s\n' "$occurrence_token" | awk "$FILL_AWK" "$vars" -)"; then
          hold_tool "$filled"
        else
          refuse "the address uses ${filled#UNSET }, which the file gives no value"
        fi
      fi ;;
    clusters/argocd/files/projects.yaml | clusters/units/reconciler/values.yaml | ansiwise/templates/slave-appproject.tpl)
      prefix='-'
      [ "$occurrence_path" != clusters/units/reconciler/values.yaml ] || prefix='exporterChartsUrl:'
      entry="$(printf '%s\n' "$text" | sed -E "s/^[[:space:]]*${prefix}[[:space:]]+//; s/[[:space:]]+#.*\$//; s/[[:space:]]+\$//; s/^[\"']//; s/[\"']\$//")"
      if [ "$entry" = "$occurrence_token" ]; then hold_allowed "$occurrence_token"; else leave_unread; fi ;;
    *) leave_unread ;;
  esac
}

# Every file of a tree, matched by xargs in batches. grep exits 1 for no match, which is no error here; 2 is.
scan() { # <tree directory> <list of files> <regex>: path TAB line TAB match
  [ -s "$2" ] || return 0
  if ! ( cd "$1" && tr '\n' '\0' < "$2" | xargs -0 sh -c 'grep -I -n -H -o -E -e "$0" -- "$@" || [ $? -eq 1 ]' "$3" ) > "$work/grep-out"; then
    fail "a file of $1 could not be read by grep"
  fi
  awk '{ i = match($0, /:[0-9]+:/); printf "%s\t%s\t%s\n", substr($0, 1, i - 1), substr($0, i + 1, RLENGTH - 2), substr($0, i + RLENGTH) }' "$work/grep-out"
}

trees=0
for argument in "$@"; do
  [ -d "$argument" ] || fail "$argument is not a directory"
  trees=$((trees + 1))
  tree="$(cd "$argument" && pwd)"
  label="$(tree_name "$tree")"
  all="$work/files.$trees" scanned="$work/scanned.$trees"
  if [ -e "$tree/.git" ]; then
    git -C "$tree" -c core.quotepath=off ls-files | sort > "$all" || fail "the tracked files of $tree could not be listed"
  else
    ( cd "$tree" && find . -type f | sed 's#^\./##' ) | sort > "$all" || fail "the files of $tree could not be listed"
  fi
  : > "$work/excluded.$trees"
  excluded_text=""
  for row in "${EXCLUDED[@]}"; do
    IFS='|' read -r row_tree row_path row_reason <<< "$row"
    [ "$row_tree" = "$label" ] || continue
    grep -qxF -- "$row_path" "$all" || continue
    printf '%s\n' "$row_path" >> "$work/excluded.$trees"
    excluded_text="$excluded_text"$'\n'"  excluded: $row_path ($row_reason)"
  done
  grep -vxF -f "$work/excluded.$trees" "$all" > "$scanned"
  [ $? -le 1 ] || fail "the files of $tree could not be filtered"
  total="$(wc -l < "$all" | tr -d ' ')" read_files="$(wc -l < "$scanned" | tr -d ' ')" as_text=0
  [ ! -s "$scanned" ] || as_text="$(cd "$tree" && tr '\n' '\0' < "$scanned" | xargs -0 sh -c 'grep -I -l -e "" -- "$@" || [ $? -eq 1 ]' _ | wc -l | tr -d ' ')"
  echo "$me: tree $trees: $label, $tree — $total files, $read_files read ($as_text as text, the others binary or empty with no text to match), $(( total - read_files )) excluded$excluded_text"

  scan "$tree" "$scanned" "$shapes_re" > "$work/shapes-found.$trees"
  while IFS=$'\t' read -r path line match; do
    shape_name="$(for shape in "${SHAPES[@]}"; do [[ "$match" =~ ${shape#*|} ]] && { echo "${shape%%|*}"; break; }; done)"
    printf '%s:%s (%s): %s, %s\n' "$path" "$line" "$label" "$match" "$shape_name" >> "$work/shapes"
  done < "$work/shapes-found.$trees"
  scan "$tree" "$scanned" "$owned_re" > "$work/found.$trees"
  while IFS=$'\t' read -r occurrence_path occurrence_line occurrence_token; do
    occurrence_label="$label"
    classify "$tree"
  done < "$work/found.$trees"
done

found="$(cat "$work"/found.* | wc -l | tr -d ' ')"
held="$(wc -l < "$work/held" | tr -d ' ')" notread="$(wc -l < "$work/notread" | tr -d ' ')"
refused="$(wc -l < "$work/refused" | tr -d ' ')" shapes="$(wc -l < "$work/shapes" | tr -d ' ')"
sed 's/^/held: /' "$work/held"
sed 's/^/not read: /' "$work/notread"
echo "$me: addresses found $found = held $held + not read $notread + refused $refused"

: > "$work/unread"
while IFS= read -r row; do
  read -r -a fields <<< "$row"
  case "${fields[0]}" in
    tool) grep -qxF -- "${fields[4]}" "$work/read-tools" || echo "$row" >> "$work/unread" ;;
    chart) grep -qxF -- "${fields[6]}"$'\t'"${fields[2]}"$'\t'"${fields[3]}" "$work/read-charts" || echo "$row" >> "$work/unread" ;;
  esac
done < "$work/rows"
rows="$(wc -l < "$work/rows" | tr -d ' ')" unread="$(wc -l < "$work/unread" | tr -d ' ')"
sed 's/^/unread row: /' "$work/unread"
echo "$me: rows $rows in the table = read by a consumer of these trees $(( rows - unread )) + read by none $unread (listed, not failed)"

echo "$me: refused shapes $shapes"
if [ "$shapes" -gt 0 ] || [ "$refused" -gt 0 ]; then
  sed 's/^/REFUSE — /' "$work/shapes" >&2
  sed 's/^/REFUSE — /' "$work/refused" >&2
  fail "$shapes refused shapes and $refused owned addresses that no row holds, listed above by file:line"
fi
echo "$me: OK — no refused shape, and every owned address at a consumer place is a row of the table"
