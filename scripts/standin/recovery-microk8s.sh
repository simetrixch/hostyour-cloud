#!/usr/bin/env bash
# The node's microk8s, for the recovery-folder cases of lifecycle/test.sh: kubectl answers the two Secrets
# the seed reads, ctr records every call in $OUT/node.log, and the skopeo it runs pushes into and reads from
# the folder $RF/registry. A push checks that the push identity and the authority arrived by path, as the
# Secrets hold them; a read of the name in SERVE_OTHER answers another manifest.
echo "microk8s $*" >> "$OUT/node.log"
case "$*" in
  'kubectl --namespace registry get secret registry-seed-push') exit 0 ;;
  'kubectl --namespace registry get secret registry-seed-push --output jsonpath={.data.\.dockerconfigjson}') printf '%s' "$SEED_AUTH" | base64 | tr -d '\n'; exit 0 ;;
  'kubectl --namespace cert-manager get secret platform-ca --output jsonpath={.data.ca\.crt}') printf 'the fixture authority\n' | base64 | tr -d '\n'; exit 0 ;;
  'ctr --namespace k8s.io images '*) exit 0 ;;
  'ctr --namespace k8s.io run '*) shift 4 ;;
  *) exit 1 ;;
esac
recovery='' seed=''
while [ $# -gt 0 ]; do
  case "$1" in
    --rm|--net-host) shift ;;
    --mount)
      mount="${2#type=bind,src=}"
      case "$2" in *,dst=/recovery,*) recovery="${mount%%,dst=*}" ;; *,dst=/seed,*) seed="${mount%%,dst=*}" ;; esac
      shift 2 ;;
    *) break ;;
  esac
done
shift 2
[ "$1" = skopeo ] || exit 1
name="${*: -1}"; name="${name#docker://}"
stored="$RF/registry/$(printf '%s' "$name" | tr '/:' '__')"
case "$2" in
  copy)
    [ "$(cat "$seed/auth.json")" = "$SEED_AUTH" ] && [ "$(stat -c %a "$seed/auth.json")" = 600 ] && [ -s "$seed/certs/ca.crt" ] \
      || { echo 'the push identity or the authority the seed was handed is not what the Secrets hold' >&2; exit 1; }
    archive="${*: -2:1}"; archive="$recovery/${archive#oci-archive:/recovery/}"
    echo "$name" >> "$OUT/pushed.log"
    digest=$(tar -xOf "$archive" ./index.json | jq -r '.manifests[0].digest')
    tar -xOf "$archive" "./blobs/sha256/${digest#sha256:}" > "$stored" ;;
  inspect)
    [ "$name" != "${SERVE_OTHER:-}" ] || { printf 'another manifest'; exit 0; }
    cat "$stored" ;;
  *) exit 1 ;;
esac
