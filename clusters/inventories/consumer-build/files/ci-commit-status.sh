#!/usr/bin/env bash
# Sets the commit status `tekton/ci` of the pushed commit on GitHub, linked to the run in the Tekton
# Dashboard. The ci pipeline runs it twice: as the step commit-status-pending of its task ci right after the gate,
# with RUN_STATE=running, and as the finally task commit-status with the outcome Tekton reports.
# scripts/ci-commit-status.test.mjs runs it against a stand-in curl.
#
# The outcome is $(tasks.status) and the reason of the task ci. Tekton counts a task it cancelled as failed:
# TaskRunCancelled when a newer push replaced the run or its branch was deleted (the ci run keeper cancels a
# started run gracefully, so this task still runs) or when the time of the run ran out, and TaskRunTimeout when
# the task's own time ran out. Such a run never finished its check, so the commit gets `error`, not `failure`,
# which GitHub keeps for a check that ran and failed. A graceful cancel that lands before the task ci starts
# skips it, so Tekton reports `Completed`: the one task of this pipeline has no when, so a skipped task is
# always a stopped run, and `Completed` is `error` too, never a passed check.
#
# The commit is validated before anything is posted: 40 lowercase hex, or the script ends at once without a post. The pipeline
# lets this task run after a run the gate refused, whose commit nothing proved, so a refused run sets no status here.
# A success is posted only when the commit carries none yet (earlier_green_run of ci-green-status.sh, inlined before this
# file): a run that found the commit green already did no check, and the status keeps naming the run that did.
#
# The token is the unit's statuses token from build-git-https (key `token`): it posts commit statuses on
# the unit's own repository and writes nothing else. It travels in a header file, so it is in no
# argument list, and nothing here prints it.
set -euo pipefail

: "${GITHUB_TOKEN:?}" "${REPOSITORY_PATH:?}" "${COMMIT:?}" "${RUN_URL:?}" "${RUN_STATE:?}"

case "${COMMIT}" in
  *[!0-9a-f]*) valid=false ;;
  *) valid=true ;;
esac
if [ "${valid}" != true ] || [ "${#COMMIT}" -ne 40 ]; then
  echo "commit-status: '${COMMIT}' is not a full lowercase SHA-1, so no status is posted"
  exit 0
fi

stopped="The run stopped before its check finished: a newer push replaced it, its branch was deleted, or its time ran out."
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

if [ "${state}" = success ] && earlier="$(earlier_green_run)"; then
  echo "commit-status: tekton/ci is success on ${REPOSITORY_PATH}@${COMMIT} already, set by the run ${earlier}, so nothing is posted"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf 'Authorization: Bearer %s\n' "${GITHUB_TOKEN}" > "${work}/auth"
jq -n -c --arg state "${state}" --arg url "${RUN_URL}" --arg description "${description}" \
  '{state: $state, target_url: $url, description: $description, context: "tekton/ci"}' > "${work}/status.json"

# GitHub answering 5xx, or not at all (curl prints 000), is a blip that passes: the post is tried 3 times with a
# wait of 2 and 4 seconds between them, which fits the 2 minutes of the task with the 20 of each try. Any other
# answer is the answer to a request that is wrong (a 4xx is a wrong token or permission), so it fails at once. When
# the pending still fails, the run goes on to the check with a warning, because a status is a signal and the check
# is the run; the outcome that never reached GitHub fails the task, because it would leave the commit pending.
tries=3
attempt=0
while :; do
  attempt=$((attempt + 1))
  rm -f "${work}/answer.json"
  code="$(curl -sS --max-time 20 -X POST -H "@${work}/auth" -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' --data-binary "@${work}/status.json" -o "${work}/answer.json" \
    -w '%{http_code}' "https://api.github.com/repos/${REPOSITORY_PATH}/statuses/${COMMIT}" 2>"${work}/curl.err" || true)"
  [ "${code}" = 201 ] && break
  message="$(jq -r '.message // empty' "${work}/answer.json" 2>/dev/null | head -c 300 || true)"
  answer="GitHub answered HTTP ${code} to ${state} for ${REPOSITORY_PATH}@${COMMIT}: ${message:-$(tr '\n' ' ' < "${work}/curl.err" | head -c 300)}"
  case "${code}" in
    5?? | 000) ;;
    *) echo "commit-status: ${answer}" >&2; exit 1 ;;
  esac
  if [ "${attempt}" -lt "${tries}" ]; then
    echo "commit-status: warning: attempt ${attempt} of ${tries}: ${answer}" >&2
    sleep $((attempt * 2))
  elif [ "${state}" = pending ]; then
    echo "commit-status: warning: ${answer}, after ${tries} attempts: the run goes on to the check without a pending status" >&2
    exit 0
  else
    echo "commit-status: ${answer}, after ${tries} attempts" >&2
    exit 1
  fi
done
echo "commit-status: tekton/ci is ${state} on ${REPOSITORY_PATH}@${COMMIT}"
