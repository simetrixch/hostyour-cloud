#!/usr/bin/env bash
# Applies what ci-run-keeper.jq decides; every decision lives there, where the tests run it.
# A change that fails is reported and the others still run, because the next tick replays the same
# list: stopping at the first failure would keep every later run, and its claim, for good.
# The branches of a remote are read before the decision, because deleting a branch sends no push that
# could tell the keeper. A remote that cannot be read is judged on nothing, and a failure to read one
# fails the tick, after every other change has been made.
set -euo pipefail
apply() {
  case "$1" in
    delete) kubectl delete pipelinerun -n "$2" "$3" --ignore-not-found --wait=false ;;
    cancel | patch) kubectl patch pipelinerun -n "$2" "$3" --type "$4" -p "$5" ;;
  esac
}
# Seconds git has to answer one remote. All remotes are asked at the same time, so this is also the most
# that reading them adds to a tick, and the CronJob's activeDeadlineSeconds holds the tick to its minute.
git_timeout=10
# What the shell reads when `timeout` ended git. The image of the keeper (alpine/k8s) has the BusyBox timeout, which ends
# its command by SIGTERM and so gives 128 + 15, where the timeout of coreutils would give 124.
git_timeout_status=143
# The branches of one remote, as git prints them for `ls-remote --symref <url> HEAD 'refs/heads/ci/*'`: the
# line `ref: refs/heads/<default>	HEAD` names the default branch, and each other line `<sha>	refs/heads/<name>`
# a branch. An answer without the first line is not an answer of a repository: a listing of no `ci/` branch
# at all is one that names the default branch alone.
remote_branches() {
  jq -Rnc '[inputs | split("\t")] as $rows
    | ([$rows[] | select(.[1] == "HEAD" and (.[0] | startswith("ref: refs/heads/"))) | .[0][16:]][0]) as $default
    | if $default == null then error("the answer names no default branch")
      else {default: $default, branches: [$rows[] | select((.[1] // "") | startswith("refs/heads/")) | .[1][11:]]} end' "$1"
}
# Asks one remote and leaves its answer, its error and its exit status beside $2. There is no login and no
# prompt (a private repository answers with a refusal to prompt, which names it), only https, and no
# translation of git's messages, which the caller reads.
ask_remote() {
  local status=0
  GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=https LC_ALL=C timeout "$git_timeout" git ls-remote --symref "$1" HEAD 'refs/heads/ci/*' >"$2.out" 2>"$2.err" || status=$?
  echo "$status" >"$2.status"
}
max="${CI_MAX_RUNNING:?CI_MAX_RUNNING is required}"
. "${KEEPER_DIR}/list-pipelineruns.sh"
# Of each run only the fields ci-run-keeper.jq reads, about 450 bytes a run. A failed page fails the
# tick: a decision on part of the runs would start runs past the cap.
ci_run='{
  metadata: (.metadata | {namespace, name, creationTimestamp,
    labels: {"image-builder.io/ci": .labels["image-builder.io/ci"]},
    annotations: ((.annotations // {}) | with_entries(select(.key == "image-builder.io/ci-branch" or .key == "image-builder.io/queued-behind")))}),
  spec: {status: .spec.status, params: [.spec.params[] | select(.name == "commit" or .name == "git-url")]},
  status: {conditions: [(.status.conditions // [])[] | select(.type == "Succeeded") | {type, status}]}}'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
list_pipelineruns image-builder.io/ci "$ci_run" | jq -cs '{items: .}' >"$work/runs.json"
echo '{}' >"$work/remote.json"
now="$(date +%s)"
keeper() {
  jq -c --argjson max "$max" --argjson now "$now" --slurpfile remote "$work/remote.json" --arg mode "$1" -f "${KEEPER_DIR}/ci-run-keeper.jq" "$work/runs.json"
}
failed=0
asks="$(keeper asks)"
number=0
while IFS= read -r ask; do
  [ -n "$ask" ] || continue
  number=$((number + 1))
  if [ -n "$(jq -r '.ask // empty' <<<"$ask")" ]; then
    ask_remote "$(jq -r .ask <<<"$ask")" "$work/ask-$number" &
  fi
done <<<"$asks"
wait
number=0
while IFS= read -r ask; do
  [ -n "$ask" ] || continue
  number=$((number + 1))
  runs_of="$(jq -r '.runs | join(", ")' <<<"$ask")"
  url="$(jq -r '.ask // empty' <<<"$ask")"
  if [ -z "$url" ]; then
    echo "the git-url '$(jq -r .refuse <<<"$ask")' of $runs_of is not a GitHub clone url, so its branch is not read" >&2
    failed=1
    continue
  fi
  status="$(cat "$work/ask-$number.status")"
  if [ "$status" = 0 ] && entry="$(remote_branches "$work/ask-$number.out")"; then
    jq -c --arg url "$url" --argjson entry "$entry" '. + {($url): $entry}' "$work/remote.json" >"$work/remote.next"
    mv "$work/remote.next" "$work/remote.json"
  elif grep -q 'could not read Username' "$work/ask-$number.err"; then
    echo "not judged: $url asks for a login, so no branch of it is read for $runs_of"
  else
    reason="$(tail -n 1 "$work/ask-$number.err")"
    [ "$status" != "$git_timeout_status" ] || reason="git did not answer within $git_timeout seconds"
    echo "could not read the branches of $url for $runs_of: ${reason:-git answered with exit status $status and no branch listing}" >&2
    failed=1
  fi
done <<<"$asks"
changes="$(keeper decide)"
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
