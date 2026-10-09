#!/usr/bin/env bash
# Applies what ci-run-keeper.jq decides; every decision lives there, where the tests run it.
# A change that fails is reported and the others still run, because the next tick replays the same
# list: stopping at the first failure would keep every later run, and its claim, for good.
set -euo pipefail
apply() {
  case "$1" in
    cancel) kubectl patch pipelinerun -n "$2" "$3" --type merge -p '{"spec":{"status":"Cancelled"}}' ;;
    delete) kubectl delete pipelinerun -n "$2" "$3" --ignore-not-found --wait=false ;;
    patch) kubectl patch pipelinerun -n "$2" "$3" --type "$4" -p "$5" ;;
  esac
}
changes="$(kubectl get pipelineruns -A -l image-builder.io/ci -o json | jq -c --argjson max "${CI_MAX_RUNNING:?CI_MAX_RUNNING is required}" -f "${KEEPER_DIR}/ci-run-keeper.jq")"
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
