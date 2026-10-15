#!/usr/bin/env bash
# Moves the Plane work items a release names to the state Released, and completes the module named
# after its tag. The task plane of the Pipeline forgejo-release (clusters/inventories/forgejo-build)
# runs it in the cloned source after the Forgejo release. scripts/forgejo-release.test.mjs runs it
# against a stand-in curl and a real git.
#
# A work item is named by its key, the project's identifier and its number (SHOP-12), anywhere in a
# commit message since the tag before this one ($PREVIOUS_COMMIT, empty for the first tag). A key
# Plane does not know and a project without Released in the Completed group stop the run. The tag's
# module is created if missing, reused otherwise, given the resolved work items and completed.
#
# The non-secret targets come from the pipeline's values and select by repository basename. The
# installer provisions the credentials in <stage>/app/forgejo-build. The Plane API token travels in
# a private header file, so it is in no argument list, and nothing here prints it.
set -euo pipefail
umask 077

: "${PLANE_TOKEN:?}" "${PLANE_API:?}" "${PLANE_TARGETS:?}" "${REPOSITORY:?}" "${TAG:?}" "${SOURCE:?}"

fail() { echo "plane-update-status: $*" >&2; exit 1; }
repository="${REPOSITORY##*/}"
PLANE_WORKSPACE="$(printf '%s' "$PLANE_TARGETS" | jq -er '.workspace | strings | select(test("^[A-Za-z0-9_-]+$"))' 2>/dev/null)" \
  || fail 'the configured Plane workspace is invalid'
PLANE_PROJECT="$(printf '%s' "$PLANE_TARGETS" | jq -er --arg repo "$repository" \
  '[.projects[] | select(any(.prefixes[]; . as $prefix | $repo | startswith($prefix))) | .id] |
   select(length == 1) | .[0] | strings | select(test("^[A-Za-z0-9_-]+$"))' 2>/dev/null)" \
  || fail "repository ${repository} has no unique configured Plane project"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'X-API-Key: %s\n' "${PLANE_TOKEN}" > "${work}/auth"
project="/workspaces/${PLANE_WORKSPACE}/projects/${PLANE_PROJECT}"

# $1 method, $2 path below the API, $3 the JSON body or empty. The answer stands in answer.json.
plane() {
  local code
  if [ -n "${3:-}" ]; then printf '%s' "$3" > "${work}/body.json"; fi
  code="$(curl -sS --max-time 20 -X "$1" -H "@${work}/auth" -H 'Content-Type: application/json' \
    ${3:+--data-binary "@${work}/body.json"} -o "${work}/answer.json" -w '%{http_code}' \
    "${PLANE_API}$2" 2>"${work}/curl.err")" || fail "Plane could not be reached for $1 $2"
  [ "${code}" = "${4:-200}" ] || fail "Plane answered HTTP ${code} to $1 $2"
}

# Exhaust the cursor before calling a module absent; an older tag can stand on a later page.
list() {
  local path="$1" cursor='' seen='|' next
  : > "${work}/pages"
  while :; do
    plane GET "${path}?per_page=100${cursor:+&cursor=${cursor}}"
    jq -ce '.results | arrays' "${work}/answer.json" >> "${work}/pages" 2>/dev/null \
      || fail "Plane returned no results for ${path}"
    next="$(jq -er '.next_page_results | if type == "boolean" then tostring else empty end' "${work}/answer.json" 2>/dev/null)" \
      || fail "Plane returned no pagination for ${path}"
    [ "$next" = true ] || break
    cursor="$(jq -er '.next_cursor | strings | select(length > 0) | @uri' "${work}/answer.json" 2>/dev/null)" \
      || fail "Plane returned no next cursor for ${path}"
    case "$seen" in *"|${cursor}|"*) fail "Plane repeated a cursor for ${path}";; esac
    seen="${seen}${cursor}|"
  done
  jq -s 'add' "${work}/pages" > "${work}/list.json"
}

plane GET "${project}/"
identifier="$(jq -er '.identifier | strings | select(test("^[A-Za-z0-9_]+$"))' "${work}/answer.json" 2>/dev/null)" \
  || fail 'Plane returned no project identifier'
git -C "${SOURCE}" log --format=%B "${PREVIOUS_COMMIT:+${PREVIOUS_COMMIT}..}HEAD" > "${work}/messages"
# A message with no key is no error, so grep's "no line matched" is not one either.
{ tr -c 'A-Za-z0-9_-' '\n' < "${work}/messages" | grep -E "^${identifier}-[0-9]+$" || [ $? = 1 ]; } | sort -u > "${work}/keys"

list "${project}/states/"
released="$(jq -er '[.[] | select(.name == "Released" and .group == "completed") | .id] |
  select(length == 1) | .[0] | strings | select(test("^[A-Za-z0-9_-]+$"))' "${work}/list.json" 2>/dev/null)" \
  || fail "the project ${identifier} has no state Released uniquely in Completed"

: > "${work}/items"
while read -r key; do
  plane GET "/workspaces/${PLANE_WORKSPACE}/work-items/${key}/"
  item="$(jq -er --arg project "$PLANE_PROJECT" 'select(.project == $project) | .id |
    strings | select(test("^[A-Za-z0-9_-]+$"))' "${work}/answer.json" 2>/dev/null)" \
    || fail "${key} does not resolve to a work item in the selected project"
  printf '%s\n' "$item" >> "${work}/items"
done < "${work}/keys"

list "${project}/modules/"
module="$(jq -er --arg tag "${TAG}" '[.[] | select(.name == $tag) | .id] |
  if length == 0 then "" elif length == 1 then .[0] else error("ambiguous module") end |
  strings | select(. == "" or test("^[A-Za-z0-9_-]+$"))' "${work}/list.json" 2>/dev/null)" \
  || fail "the project ${identifier} returned invalid or ambiguous modules for ${TAG}"
if [ -z "$module" ]; then
  plane POST "${project}/modules/" "$(jq -nc --arg tag "$TAG" '{name: $tag}')" 201
  module="$(jq -er --arg tag "$TAG" 'select(.name == $tag) | .id | strings |
    select(test("^[A-Za-z0-9_-]+$"))' "${work}/answer.json" 2>/dev/null)" \
    || fail "Plane returned no created module for ${TAG}"
fi

while read -r item; do
  plane PATCH "${project}/work-items/${item}/" "$(jq -n -c --arg state "${released}" '{state: $state}')"
done < "${work}/items"

if [ -s "${work}/items" ]; then
  items="$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "${work}/items")"
  plane POST "${project}/modules/${module}/module-issues/" "$(jq -nc --argjson issues "$items" '{issues: $issues}')"
  jq -e --arg module "$module" --argjson items "$items" \
    'type == "array" and (($items - [.[] | select(.module == $module) | .issue]) | length == 0)' \
    "${work}/answer.json" >/dev/null 2>&1 || fail "Plane did not attach every work item to module ${TAG}"
fi
plane PATCH "${project}/modules/${module}/" '{"status":"completed"}'
jq -e --arg module "$module" '.id == $module and .status == "completed"' "${work}/answer.json" >/dev/null 2>&1 \
  || fail "Plane did not complete module ${TAG}"
echo "plane-update-status: module ${TAG} is completed, $(wc -l < "${work}/keys") work items are Released"
