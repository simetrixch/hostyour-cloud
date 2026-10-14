#!/usr/bin/env bash
# Creates the Forgejo release of a pushed tag, with the commits since the tag before it as its
# changelog. The task release of the Pipeline forgejo-release (clusters/inventories/forgejo-build)
# runs it in the cloned source, after the image of the tag is pushed. It writes the commit of the
# tag before it to $PREVIOUS_COMMIT_RESULT, empty for the first tag, so the Plane update reads the
# same range. scripts/forgejo-release.test.mjs runs it against a stand-in curl and a real git.
#
# THE TAG BEFORE IT is the nearest of the repository's tags whose commit is an ancestor of this
# one. The clone fetched the tag's history and no tag ref, so the tags come from Forgejo's API.
# ponytail: reads the newest page of tags (50); a repository with more tags than that finds its
# previous tag only among them.
#
# The token is the Forgejo machine user's, from the Secret forgejo-build-tokens. It travels in a
# header file, so it is in no argument list, and nothing here prints it.
set -euo pipefail

: "${FORGEJO_TOKEN:?}" "${FORGEJO_API:?}" "${REPOSITORY:?}" "${TAG:?}" "${SOURCE:?}" "${PREVIOUS_COMMIT_RESULT:?}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'Authorization: token %s\n' "${FORGEJO_TOKEN}" > "${work}/auth"

# $1 method, $2 path below the API, $3 the body file or empty, $4 the HTTP code it must answer.
forgejo() {
  local code
  code="$(curl -sS --max-time 20 -X "$1" -H "@${work}/auth" -H 'Content-Type: application/json' \
    ${3:+--data-binary "@$3"} -o "${work}/answer.json" -w '%{http_code}' \
    "${FORGEJO_API}$2" 2>"${work}/curl.err" || true)"
  if [ "${code}" != "$4" ]; then
    message="$(jq -r '.message // empty' "${work}/answer.json" 2>/dev/null | head -c 300 || true)"
    echo "forgejo-create-release: Forgejo answered HTTP ${code} to $1 $2: ${message:-$(tr '\n' ' ' < "${work}/curl.err" | head -c 300)}" >&2
    exit 1
  fi
}

head="$(git -C "${SOURCE}" rev-parse HEAD)"
forgejo GET "/repos/${REPOSITORY}/tags?limit=50" '' 200
previous='' previous_tag='' distance=''
while IFS=$'\t' read -r name commit; do
  [ "${name}" != "${TAG}" ] && [ "${commit}" != "${head}" ] || continue
  git -C "${SOURCE}" cat-file -e "${commit}^{commit}" 2>/dev/null || continue
  git -C "${SOURCE}" merge-base --is-ancestor "${commit}" "${head}" || continue
  count="$(git -C "${SOURCE}" rev-list --count "${commit}..${head}")"
  if [ -z "${distance}" ] || [ "${count}" -lt "${distance}" ]; then
    previous="${commit}" previous_tag="${name}" distance="${count}"
  fi
done < <(jq -r '.[] | [.name, .commit.sha] | @tsv' "${work}/answer.json")

git -C "${SOURCE}" log --no-merges --format='- %s (%h)' "${previous:+${previous}..}${head}" > "${work}/changelog"
jq -n -c --arg tag "${TAG}" --rawfile body "${work}/changelog" \
  '{tag_name: $tag, name: $tag, body: $body, draft: false, prerelease: false}' > "${work}/release.json"
forgejo POST "/repos/${REPOSITORY}/releases" "${work}/release.json" 201

printf '%s' "${previous}" > "${PREVIOUS_COMMIT_RESULT}"
echo "forgejo-create-release: ${REPOSITORY} ${TAG} is released with $(wc -l < "${work}/changelog") commits since ${previous_tag:-its first commit}"
