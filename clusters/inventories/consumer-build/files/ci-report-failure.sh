#!/usr/bin/env bash
# Mails the failure of a ci run: finds every task of the run that failed, reads the last 60 lines of
# the step that failed from the Kubernetes API, and posts ONE alert to Alertmanager, whose route
# for CIRunFailed mails it. The Pipeline runs this as its finally task `report-failure`, and
# scripts/ci-report-failure.test.mjs runs it against a stand-in curl.
#
# The run is read through its own record, not through pod names: the PipelineRun lists its TaskRuns,
# and each TaskRun names its pod and its steps. A pod that is gone is said so in the mail; an API
# answer other than 200 or a 404 on the log is still mailed, with the answer in the log, and then
# fails this task, so a mail that lost its lines is never taken for a complete one.
#
# The only credential is the projected token of the ServiceAccount. It goes to the API server and to
# nobody else: the alert is posted without it.
set -euo pipefail

: "${SERVICE_ACCOUNT_DIR:?}" "${PIPELINE_RUN:?}" "${REPOSITORY:?}" "${BRANCH:?}" "${COMMIT:?}"
: "${DASHBOARD_URL:?}" "${GRAFANA_URL:?}" "${ALERTMANAGER_URL:?}"
: "${KUBERNETES_SERVICE_HOST:?}" "${KUBERNETES_SERVICE_PORT:?}"

TAIL_LINES=60
MAX_LINE_LENGTH=1000

namespace="$(cat "${SERVICE_ACCOUNT_DIR}/namespace")"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
# The token travels in a header file, so it is in no argument list.
printf 'Authorization: Bearer %s\n' "$(cat "${SERVICE_ACCOUNT_DIR}/token")" > "${work}/auth"

problems=()

# api <path> <file>: GET on the API server into <file>; prints the HTTP status, 000 when there is none.
api() {
  curl -sS --max-time 20 --cacert "${SERVICE_ACCOUNT_DIR}/ca.crt" -H "@${work}/auth" \
    -o "$2" -w '%{http_code}' "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}$1" 2>"${work}/curl.err" || true
}

# get <path> <file>: api, and a problem for anything but 200.
get() {
  local code
  code="$(api "$1" "$2")"
  if [ "${code}" != 200 ]; then
    problems+=("GET $1 answered HTTP ${code} $(tr '\n' ' ' < "${work}/curl.err" | head -c 200)")
    return 1
  fi
}

# cleaned: drops colors and carriage returns, and cuts a line that is longer than a mail can use.
cleaned() {
  sed -E $'s/\x1b\\[[0-9;?]*[ -/]*[@-~]//g' | tr -d '\r' | cut -c "1-${MAX_LINE_LENGTH}"
}

# What one TaskRun says: whether it failed, which step, and the results it left.
#
# A TaskRun that Tekton cancelled is a failure when the time budget of the run ran out: Tekton cancels the
# running TaskRuns with the message below (pkg/apis/pipeline/v1/taskrun_types.go, TaskRunCancelledByPipelineTimeoutMsg),
# marks them failed with the reason TaskRunCancelled, and still runs this task. Any other cancel is a newer
# push replacing the run; that cancels the PipelineRun itself, which runs no finally task, so such a
# TaskRun is never read here as a failure.
taskrun_info='
  (.status.conditions // [] | map(select(.type == "Succeeded")) | .[0] // {}) as $c
  | ($c.reason == "TaskRunCancelled"
     and (.spec.statusMessage // "") == "TaskRun cancelled as the PipelineRun it belongs to has timed out.") as $timed_out
  | ((.status.steps // []) as $steps
     | ($steps | map(select((.terminated.exitCode // 0) != 0)) | .[0])
       // ($steps | map(select(.terminated == null)) | .[0]) // {}) as $s
  | {failed: ($c.status == "False" and ($c.reason != "TaskRunCancelled" or $timed_out)),
     reason: ($c.reason // ""),
     message: (($c.message // "") + (if $timed_out then " The time budget of the run ran out, so Tekton cancelled this task." else "" end)),
     pod: (.status.podName // ""), step: ($s.name // ""), container: ($s.container // ""),
     exitCode: ($s.terminated.exitCode // null),
     results: ((.status.results // []) | map({(.name): .value}) | add // {})}'

: > "${work}/failures.jsonl"
subject=""
author=""
clone_failed=false
run_created=""

if get "/apis/tekton.dev/v1/namespaces/${namespace}/pipelineruns/${PIPELINE_RUN}" "${work}/run.json"; then
  run_created="$(jq -r '.metadata.creationTimestamp' "${work}/run.json")"
  while IFS=$'\t' read -r taskrun task; do
    [ -n "${taskrun}" ] || continue
    get "/apis/tekton.dev/v1/namespaces/${namespace}/taskruns/${taskrun}" "${work}/taskrun.json" || continue
    info="$(jq -c "${taskrun_info}" "${work}/taskrun.json")"
    if [ "${task}" = describe-commit ]; then
      subject="$(jq -r '.results.subject // ""' <<<"${info}")"
      author="$(jq -r '.results.author // ""' <<<"${info}")"
    fi
    [ "$(jq -r .failed <<<"${info}")" = true ] || continue
    [ "${task}" != clone ] || clone_failed=true
    pod="$(jq -r .pod <<<"${info}")"
    container="$(jq -r .container <<<"${info}")"
    reason="$(jq -r '.reason + ": " + .message' <<<"${info}")"
    log=""
    if [ -z "${pod}" ] || [ -z "${container}" ]; then
      log="no step of ${task} ran (${reason})"
    else
      code="$(api "/api/v1/namespaces/${namespace}/pods/${pod}/log?container=${container}&tailLines=${TAIL_LINES}" "${work}/log.txt")"
      case "${code}" in
        200)
          log="$(cleaned < "${work}/log.txt")"
          [ -n "${log}" ] || log="(the step printed nothing)"
          ;;
        404)
          log="the pod of ${task} is gone, so its output is behind the run link. Tekton deletes the pod of a task that timed out or was cancelled, and a pod is also lost to a node drain or a delete by hand. The task ended with ${reason}"
          ;;
        *)
          problems+=("GET the log of ${task} answered HTTP ${code}")
          log="the log of ${task} could not be read: the API server answered HTTP ${code}"
          ;;
      esac
    fi
    jq -n -c --arg task "${task}" --argjson info "${info}" --arg log "${log}" \
      '{task: $task, step: ($info.step | if . == "" then "none" else . end), exitCode: $info.exitCode,
        reason: ($info.reason + ": " + $info.message), log: $log}' >> "${work}/failures.jsonl"
  done < <(jq -r '(.status.childReferences // [])[] | select(.kind == "TaskRun" and .pipelineTaskName != "report-failure") | [.name, .pipelineTaskName] | @tsv' "${work}/run.json")
fi

if [ ! -s "${work}/failures.jsonl" ] && [ "${#problems[@]}" -eq 0 ]; then
  echo "report-failure: no task of ${PIPELINE_RUN} failed on its own (a task cancelled by a newer push is not a failure), so there is nothing to mail"
  exit 0
fi

if [ -z "${subject}" ]; then
  if [ "${clone_failed}" = true ]; then
    subject="(none: the commit was not cloned)"
  else
    subject="(none: the task describe-commit left no subject)"
  fi
fi
[ -n "${author}" ] || author="(unknown)"

if [ "${#problems[@]}" -gt 0 ]; then
  printf '%s\n' "${problems[@]}" | jq -R -c '{task: "report-failure", step: "none", exitCode: null, reason: ., log: .}' >> "${work}/failures.jsonl"
fi

jq -n -c \
  --slurpfile failures "${work}/failures.jsonl" \
  --arg repository "${REPOSITORY}" --arg branch "${BRANCH}" --arg commit "${COMMIT}" \
  --arg subject "${subject}" --arg author "${author}" \
  --arg namespace "${namespace}" --arg run "${PIPELINE_RUN}" --arg created "${run_created}" \
  --arg dashboard "${DASHBOARD_URL}" --arg grafana "${GRAFANA_URL}" '
  # The first failed task names the alert; the others are in its log.
  $failures[0] as $first
  | ($failures | length) as $count
  | [{labels: {alertname: "CIRunFailed", repository: $repository, branch: $branch, commit: $commit[0:7],
               task: $first.task, step: $first.step},
      annotations: {
        subject: $subject, author: $author,
        failure: ($failures | map("\(.task), step \(.step): \(.reason)") | join("\n")),
        log: ($failures | map(if $count > 1 then "== \(.task), step \(.step) ==\n\(.log)" else .log end) | join("\n\n")),
        run_url: "\($dashboard)/#/namespaces/\($namespace)/pipelineruns/\($run)",
        logs_url: ("\($grafana)/explore?schemaVersion=1&orgId=1&panes=" + ({a: {datasource: "loki",
          queries: [{refId: "A", datasource: {type: "loki", uid: "loki"},
                     expr: "{namespace=\"\($namespace)\", pod=~\"\($run)-.+\"}"}],
          range: {from: (if $created == "" then "now-6h" else ($created | fromdateiso8601 * 1000 | tostring) end), to: "now"}}} | tojson | @uri))},
      startsAt: (now | todate), endsAt: ((now + 600) | todate)}]' > "${work}/alerts.json"

code="$(curl -sS --max-time 20 -o "${work}/post.out" -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary "@${work}/alerts.json" "${ALERTMANAGER_URL}/api/v2/alerts" 2>"${work}/curl.err" || true)"
if [ "${code}" != 200 ]; then
  echo "report-failure: Alertmanager answered HTTP ${code} at ${ALERTMANAGER_URL}/api/v2/alerts, so no mail left" >&2
  head -c 500 "${work}/post.out" >&2 || true
  head -c 500 "${work}/curl.err" >&2 || true
  exit 1
fi
echo "report-failure: posted CIRunFailed for ${REPOSITORY} ${BRANCH} ${COMMIT:0:7}, task $(jq -r '.[0].labels.task' "${work}/alerts.json")"

if [ "${#problems[@]}" -gt 0 ]; then
  printf 'report-failure: the mail is incomplete: %s\n' "${problems[@]}" >&2
  exit 1
fi
