#!/usr/bin/env bash
# Sets the commit status `tekton/ci` of the pushed commit on GitHub, linked to the run in the Tekton
# Dashboard. The ci pipeline runs it twice: as the task commit-status-pending right after the gate,
# with RUN_STATE=running, and as the finally task commit-status with the outcome Tekton reports.
# scripts/ci-commit-status.test.mjs runs it against a stand-in curl.
#
# The outcome is $(tasks.status) and the reasons of the tasks before the finally ones. Tekton counts a
# task it cancelled as failed: TaskRunCancelled when a newer push replaced the run (the ci run keeper
# cancels a started run gracefully, so this task still runs) or when the time of the run ran out, and
# TaskRunTimeout when the task's own time ran out. Such a run never finished its check, so the commit
# gets `error`, not `failure`, which GitHub keeps for a check that ran and failed. A graceful cancel
# that lands between two tasks cancels no TaskRun and skips the rest, so Tekton reports `Completed`:
# no task of this pipeline has a when, so a skipped task is always a stopped run, and `Completed` is
# `error` too, never a passed check.
#
# The token is the unit's repository token from build-git-https. It travels in a header file, so it is
# in no argument list, and nothing here prints it.
set -euo pipefail

: "${GITHUB_TOKEN:?}" "${REPOSITORY_PATH:?}" "${COMMIT:?}" "${RUN_URL:?}" "${RUN_STATE:?}"

stopped="The run stopped before its check finished: a newer push replaced it, or its time ran out."
case "${RUN_STATE}" in
  running) state=pending description="The check runs." ;;
  Succeeded) state=success description="The check passed." ;;
  Failed)
    case " ${TASK_REASONS:-} " in
      *" TaskRunCancelled "* | *" TaskRunTimeout "*) state=error description="${stopped}" ;;
      *) state=failure description="A task of the run failed. The mail CIRunFailed carries its error." ;;
    esac
    ;;
  Completed | None) state=error description="${stopped}" ;;
  *)
    echo "commit-status: '${RUN_STATE}' is no state of a run, so ${COMMIT} keeps its status" >&2
    exit 1
    ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'Authorization: Bearer %s\n' "${GITHUB_TOKEN}" > "${work}/auth"
jq -n -c --arg state "${state}" --arg url "${RUN_URL}" --arg description "${description}" \
  '{state: $state, target_url: $url, description: $description, context: "tekton/ci"}' > "${work}/status.json"

code="$(curl -sS --max-time 20 -X POST -H "@${work}/auth" -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' --data-binary "@${work}/status.json" -o "${work}/answer.json" \
  -w '%{http_code}' "https://api.github.com/repos/${REPOSITORY_PATH}/statuses/${COMMIT}" 2>"${work}/curl.err" || true)"
if [ "${code}" != 201 ]; then
  message="$(jq -r '.message // empty' "${work}/answer.json" 2>/dev/null | head -c 300 || true)"
  echo "commit-status: GitHub answered HTTP ${code} to ${state} for ${REPOSITORY_PATH}@${COMMIT}: ${message:-$(tr '\n' ' ' < "${work}/curl.err" | head -c 300)}" >&2
  exit 1
fi
echo "commit-status: tekton/ci is ${state} on ${REPOSITORY_PATH}@${COMMIT}"
