#!/usr/bin/env bash
# Sets the commit status `tekton/forgejo-release` of a commit in Forgejo, linked to the run in the
# Tekton Dashboard. The Pipeline forgejo-release of clusters/inventories/forgejo-build runs it twice:
# with RUN_STATE=pending before the clone, and in its finally task with $(tasks.status).
# scripts/forgejo-release.test.mjs runs it against a stand-in curl.
#
# A pull request skips the release and the Plane update, so a run that passed all it ran reports
# `Completed`, which is a success here.
#
# The token is the Forgejo machine user's, from the Secret forgejo-build-tokens. It travels in a
# header file, so it is in no argument list, and nothing here prints it.
set -euo pipefail

: "${FORGEJO_TOKEN:?}" "${FORGEJO_API:?}" "${REPOSITORY:?}" "${COMMIT:?}" "${RUN_URL:?}" "${RUN_STATE:?}"

case "${RUN_STATE}" in
  pending) state=pending description="The release runs." ;;
  Succeeded | Completed) state=success description="The release passed." ;;
  Failed) state=failure description="A task of the run failed." ;;
  *)
    echo "forgejo-set-status: '${RUN_STATE}' is no state of a run, so ${COMMIT} keeps its status" >&2
    exit 1
    ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'Authorization: token %s\n' "${FORGEJO_TOKEN}" > "${work}/auth"
jq -n -c --arg state "${state}" --arg url "${RUN_URL}" --arg description "${description}" \
  '{state: $state, target_url: $url, description: $description, context: "tekton/forgejo-release"}' > "${work}/status.json"

code="$(curl -sS --max-time 20 -X POST -H "@${work}/auth" -H 'Content-Type: application/json' \
  --data-binary "@${work}/status.json" -o "${work}/answer.json" -w '%{http_code}' \
  "${FORGEJO_API}/repos/${REPOSITORY}/statuses/${COMMIT}" 2>"${work}/curl.err" || true)"
if [ "${code}" != 201 ]; then
  message="$(jq -r '.message // empty' "${work}/answer.json" 2>/dev/null | head -c 300 || true)"
  echo "forgejo-set-status: Forgejo answered HTTP ${code} to ${state} for ${REPOSITORY}@${COMMIT}: ${message:-$(tr '\n' ' ' < "${work}/curl.err" | head -c 300)}" >&2
  exit 1
fi
echo "forgejo-set-status: tekton/forgejo-release is ${state} on ${REPOSITORY}@${COMMIT}"
