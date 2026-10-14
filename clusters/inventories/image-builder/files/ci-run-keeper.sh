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
. "${KEEPER_DIR}/list-pipelineruns.sh"
# Of each run only the fields ci-run-keeper.jq reads, about 340 bytes a run. A failed page fails the
# tick: a decision on part of the runs would start runs past the cap.
ci_run='{
  metadata: (.metadata | {namespace, name, creationTimestamp,
    labels: {"image-builder.io/ci": .labels["image-builder.io/ci"]},
    annotations: ((.annotations // {}) | with_entries(select(.key == "image-builder.io/ci-branch" or .key == "image-builder.io/queued-behind")))}),
  spec: {status: .spec.status},
  status: {conditions: [(.status.conditions // [])[] | select(.type == "Succeeded") | {type, status}]}}'
changes="$(list_pipelineruns image-builder.io/ci "$ci_run" | jq -cs '{items: .}' | jq -c --argjson max "$max" -f "${KEEPER_DIR}/ci-run-keeper.jq")"
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
