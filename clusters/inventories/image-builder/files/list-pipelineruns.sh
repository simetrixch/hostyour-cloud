# Lists the PipelineRuns of the cluster that carry the label $1, one run a line, each cut by the jq
# expression $2 to the fields its caller decides on. Every run carries its whole resolved pipeline in
# status.pipelineSpec, nearly all of its size, which no decision reads. So the runs come raw, which
# kubectl passes on without decoding them, a page at a time: kubectl and jq hold one page, and only the
# cut list grows with the runs. A failed page fails the list: a decision on part of the runs would act on
# runs it does not see.
list_pipelineruns() {
  local selector page continue_token=""
  selector="$(jq -rn --arg label "$1" '$label | @uri')" || return
  while :; do
    page="$(kubectl get --raw "/apis/tekton.dev/v1/pipelineruns?labelSelector=${selector}&limit=50${continue_token:+&continue=$continue_token}")" || return
    jq -c ".items[] | $2" <<<"$page" || return
    continue_token="$(jq -r '.metadata.continue // "" | @uri' <<<"$page")" || return
    [ -n "$continue_token" ] || return 0
  done
}
