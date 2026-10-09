#!/usr/bin/env bash
# Applies what release-queue.jq decides; every decision lives there, where the tests run it.
# A patch or delete that fails is reported and the others still run, because the next tick replays the same
# list in the same order: stopping at the first failure would hold every later release back for good.
set -euo pipefail
changes="$(kubectl get pipelineruns -A -l image-builder.io/consumer -o json | jq -c -f "${QUEUE_DIR}/release-queue.jq")"
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
