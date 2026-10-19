# earlier_green_run: asks GitHub for the combined commit status of COMMIT and, when the context `tekton/ci` stands at
# `success` there, prints the name of the run that set it (the last path segment of its target_url) and returns 0. It
# returns 1 for everything else: no status, a red or pending one, a green one of another context, and a read that fails.
# A failed read says so on stderr and never counts as green, so a run never skips its check on an answer it did not get.
# The ci pipeline inlines this file in the step earlier-green and, before ci-commit-status.sh, in the finally task
# commit-status, which posts no success on a commit that carries one. scripts/ci-green-status.test.mjs runs it against a
# stand-in curl.
#
# The token is the unit's statuses token from build-git-https (key `token`). It travels in a header file, so it is in no
# argument list. An anonymous read is not used: the limit of 60 requests an hour is shared by the address of the cluster.
earlier_green_run() {
  local work code run
  work="$(mktemp -d)"
  printf 'Authorization: Bearer %s\n' "${GITHUB_TOKEN}" > "${work}/auth"
  code="$(curl -sS --max-time 15 -H "@${work}/auth" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -o "${work}/answer.json" -w '%{http_code}' "https://api.github.com/repos/${REPOSITORY_PATH}/commits/${COMMIT}/status?per_page=100" 2>"${work}/curl.err" || true)"
  if [ "${code}" != 200 ]; then
    echo "earlier-green: GitHub answered HTTP ${code} to the status of ${REPOSITORY_PATH}@${COMMIT}: $(tr '\n' ' ' < "${work}/curl.err" | head -c 300)" >&2
    rm -rf "${work}"
    return 1
  fi
  if ! run="$(jq -r '[.statuses[]? | select(.context == "tekton/ci" and .state == "success")][0] | if . == null then empty else ((.target_url // "") | sub("/+$"; "") | split("/") | last // "") + "\n" end' "${work}/answer.json" 2>"${work}/jq.err")"; then
    echo "earlier-green: the status of ${REPOSITORY_PATH}@${COMMIT} is no JSON answer: $(head -c 300 "${work}/jq.err")" >&2
    rm -rf "${work}"
    return 1
  fi
  rm -rf "${work}"
  [ -n "${run}" ] || return 1
  printf '%s' "${run}" | tr -d '\n'
}
