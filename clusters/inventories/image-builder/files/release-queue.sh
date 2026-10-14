#!/usr/bin/env bash
# Applies what release-queue.jq decides; every decision lives there, where the tests run it.
# A patch or delete that fails is reported and the others still run, because the next tick replays the same
# list in the same order: stopping at the first failure would hold every later release back for good.
set -euo pipefail
. "${QUEUE_DIR}/list-pipelineruns.sh"
# The queue's runs are the release runs, which carry image-builder.io/consumer, and the publish runs,
# which carry image-builder.io/publish; a label selector names one key, so they come in two lists. Of
# each run only the fields release-queue.jq reads. A failed page fails the tick: a decision on part of
# the runs would start a release beside one it does not see.
queue_run='{
  metadata: (.metadata | {namespace, name, creationTimestamp,
    annotations: ((.annotations // {}) | with_entries(select(.key == "image-builder.io/queued-behind")))}),
  spec: {status: .spec.status, pipelineRef: {name: .spec.pipelineRef.name},
    params: [(.spec.params // [])[] | select(.name == "release-tag")]},
  status: {conditions: [(.status.conditions // [])[] | select(.type == "Succeeded") | {type, status}]}}'
changes="$({ list_pipelineruns image-builder.io/consumer "$queue_run" && list_pipelineruns image-builder.io/publish "$queue_run"; } \
  | jq -cs '{items: .}' | jq -c -f "${QUEUE_DIR}/release-queue.jq")"
failed=0
while IFS= read -r change; do
  [ -n "$change" ] || continue
  target="$(jq -r '.namespace + "/" + .name' <<<"$change")"
  if [ "$(jq -r '.verb // "patch"' <<<"$change")" = delete ]; then
    if kubectl delete pipelinerun -n "$(jq -r .namespace <<<"$change")" "$(jq -r .name <<<"$change")" \
        --ignore-not-found --wait=false >/dev/null; then
      jq -r .say <<<"$change"
    else
      echo "could not delete ${target}" >&2
      failed=1
    fi
  elif kubectl patch pipelinerun -n "$(jq -r .namespace <<<"$change")" "$(jq -r .name <<<"$change")" \
      --type="$(jq -r .type <<<"$change")" -p "$(jq -c .patch <<<"$change")" >/dev/null; then
    jq -r .say <<<"$change"
  else
    echo "could not patch ${target}: $(jq -r .say <<<"$change") did not happen" >&2
    failed=1
  fi
done <<<"$changes"
exit "$failed"
