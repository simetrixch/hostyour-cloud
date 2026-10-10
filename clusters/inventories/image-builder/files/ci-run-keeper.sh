#!/usr/bin/env bash
# Applies what ci-run-keeper.jq decides; every decision lives there, where the tests run it.
# A change that fails is reported and the others still run, because the next tick replays the same
# list: stopping at the first failure would keep every later run, and its claim, for good.
set -euo pipefail
apply() {
  case "$1" in
    delete) kubectl delete pipelinerun -n "$2" "$3" --ignore-not-found --wait=false ;;
    cancel | patch) kubectl patch pipelinerun -n "$2" "$3" --type "$4" -p "$5" ;;
  esac
}
max="${CI_MAX_RUNNING:?CI_MAX_RUNNING is required}"
# Every run carries its whole resolved pipeline in status.pipelineSpec, nearly all of its size, which the
# decision never reads. So the runs come raw, which kubectl passes on without decoding them, a page at a
# time, and jq keeps of each run only the fields ci-run-keeper.jq reads: kubectl and jq hold one page,
# and only the slim list grows with the kept runs, by about 340 bytes a run. A failed page fails the
# tick: a decision on part of the runs would start runs past the cap.
list_ci_runs() {
  local page continue_token=""
  while :; do
    page="$(kubectl get --raw "/apis/tekton.dev/v1/pipelineruns?labelSelector=image-builder.io%2Fci&limit=50${continue_token:+&continue=$continue_token}")" || return
    jq -c '.items[] | {
      metadata: (.metadata | {namespace, name, creationTimestamp,
        labels: {"image-builder.io/ci": .labels["image-builder.io/ci"]},
        annotations: ((.annotations // {}) | with_entries(select(.key == "image-builder.io/ci-branch" or .key == "image-builder.io/queued-behind")))}),
      spec: {status: .spec.status},
      status: {conditions: [(.status.conditions // [])[] | select(.type == "Succeeded") | {type, status}]}}' <<<"$page" || return
    continue_token="$(jq -r '.metadata.continue // "" | @uri' <<<"$page")" || return
    [ -n "$continue_token" ] || return 0
  done
}
changes="$(list_ci_runs | jq -cs '{items: .}' | jq -c --argjson max "$max" -f "${KEEPER_DIR}/ci-run-keeper.jq")"
failed=0
while IFS= read -r change; do
  [ -n "$change" ] || continue
  if apply "$(jq -r .verb <<<"$change")" "$(jq -r .namespace <<<"$change")" "$(jq -r .name <<<"$change")" \
      "$(jq -r '.type // ""' <<<"$change")" "$(jq -c '.patch // ""' <<<"$change")" >/dev/null; then
    jq -r .say <<<"$change"
  else
    echo "could not change $(jq -r '.namespace + "/" + .name' <<<"$change"): $(jq -r .say <<<"$change") did not happen" >&2
    failed=1
  fi
done <<<"$changes"
exit "$failed"
