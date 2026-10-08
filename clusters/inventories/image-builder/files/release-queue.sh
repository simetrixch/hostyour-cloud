#!/usr/bin/env bash
# Applies what release-queue.jq decides; every decision lives there, where the tests run it.
set -euo pipefail
kubectl get pipelineruns -A -l image-builder.io/consumer -o json \
  | jq -c -f "${QUEUE_DIR}/release-queue.jq" \
  | while IFS= read -r change; do
      kubectl patch pipelinerun -n "$(jq -r .namespace <<<"$change")" "$(jq -r .name <<<"$change")" \
        --type="$(jq -r .type <<<"$change")" -p "$(jq -c .patch <<<"$change")" >/dev/null
      jq -r .say <<<"$change"
    done
