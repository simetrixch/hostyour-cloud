#!/usr/bin/env bash
# Moves the Plane work items a release names to the state Released, and completes the module named
# after its tag. The task plane of the Pipeline forgejo-release (clusters/inventories/forgejo-build)
# runs it in the cloned source after the Forgejo release. scripts/forgejo-release.test.mjs runs it
# against a stand-in curl and a real git.
#
# A work item is named by its key, the project's identifier and its number (SHOP-12), anywhere in a
# commit message since the tag before this one ($PREVIOUS_COMMIT, empty for the first tag). A key
# Plane does not know, a project without the state Released, and a missing module stop the run, so
# a release never reports a Plane update it did not make.
#
# The workspace and the project come from the Secret forgejo-build-tokens, written by hand into
# <stage>/app/forgejo-build. The token is a Plane API token; it travels in a header file, so it is in
# no argument list, and nothing here prints it.
set -euo pipefail

: "${PLANE_TOKEN:?}" "${PLANE_API:?}" "${PLANE_WORKSPACE:?}" "${PLANE_PROJECT:?}" "${TAG:?}" "${SOURCE:?}"

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
    "${PLANE_API}$2" 2>"${work}/curl.err" || true)"
  if [ "${code}" != 200 ]; then
    message="$(jq -r '.error // .detail // empty' "${work}/answer.json" 2>/dev/null | head -c 300 || true)"
    echo "plane-update-status: Plane answered HTTP ${code} to $1 $2: ${message:-$(tr '\n' ' ' < "${work}/curl.err" | head -c 300)}" >&2
    exit 1
  fi
}

plane GET "${project}/"
identifier="$(jq -r '.identifier' "${work}/answer.json")"
git -C "${SOURCE}" log --format=%B "${PREVIOUS_COMMIT:+${PREVIOUS_COMMIT}..}HEAD" > "${work}/messages"
# A message with no key is no error, so grep's "no line matched" is not one either.
{ tr -c 'A-Za-z0-9_-' '\n' < "${work}/messages" | grep -E "^${identifier}-[0-9]+$" || [ $? = 1 ]; } | sort -u > "${work}/keys"

plane GET "${project}/states/?per_page=100"
released="$(jq -r '[.results[] | select(.name == "Released") | .id][0] // empty' "${work}/answer.json")"
if [ -z "${released}" ]; then
  echo "plane-update-status: the project ${identifier} has no state Released" >&2
  exit 1
fi

while read -r key; do
  plane GET "/workspaces/${PLANE_WORKSPACE}/work-items/${key}/"
  item="$(jq -r '.id' "${work}/answer.json")"
  plane PATCH "${project}/work-items/${item}/" "$(jq -n -c --arg state "${released}" '{state: $state}')"
  echo "plane-update-status: ${key} is Released"
done < "${work}/keys"

plane GET "${project}/modules/?per_page=100"
module="$(jq -r --arg tag "${TAG}" '[.results[] | select(.name == $tag) | .id][0] // empty' "${work}/answer.json")"
if [ -z "${module}" ]; then
  echo "plane-update-status: the project ${identifier} has no module ${TAG}" >&2
  exit 1
fi
plane PATCH "${project}/modules/${module}/" '{"status":"completed"}'
echo "plane-update-status: module ${TAG} is completed, $(wc -l < "${work}/keys") work items are Released"
