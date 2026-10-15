#!/usr/bin/env bash
# Stream one installed master's declared inputs; no config or answer file leaves the caller.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { printf 'redeploy-platform-services: %s\n' "$1" >&2; exit "${2:-65}"; }
[ "$#" -eq 1 ] || fail 'expected one owner-only lifecycle config path' 64
FILE="$1"
[ -r "$FILE" ] || fail 'the lifecycle config cannot be read' 66
. "$HERE/require-owner-only.sh"
require_owner_only "$FILE" || fail "$FILE $REACH. Run: $OWNER_ONLY_COMMAND" 77
if git -C "$(dirname "$FILE")" rev-parse --show-toplevel >/dev/null 2>&1; then
  git -C "$(dirname "$FILE")" check-ignore -q "$FILE" || fail 'the lifecycle config is not ignored by its Git tree' 77
fi
python3 - "$FILE" <<'VALIDATE'
import re, sys
with open(sys.argv[1], encoding='utf-8', newline='') as config:
    for number, line in enumerate(config, 1):
        if '\r' in line or not re.fullmatch(r"(?:\s*(?:#.*)?|[A-Z][A-Z0-9_]*='[^']*'\s*(?:#.*)?)\n?", line):
            sys.exit('the lifecycle config has an invalid assignment at line ' + str(number) + '; values withheld')
VALIDATE
# Only assignments have been admitted; the values stay in shell/process memory.
. "$FILE"
export -n PLANE_API_TOKEN ELEVATION_PASSWORD
for named in PLANE_API_TOKEN ELEVATION_PASSWORD FQDN OPERATOR_USER STAGE ROLE ACME_SERVER; do
  [ -n "${!named:-}" ] || fail "the lifecycle config states no $named; no remote mutation was started"
done
[[ "$FQDN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || fail 'FQDN is not a host name'
[[ "$OPERATOR_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail 'OPERATOR_USER is not a login name'
[ "$ROLE" = master ] || fail 'this action requires an installed master'
[ "$ACME_SERVER" = https://dv.acme-v02.api.pki.goog/directory ] || fail 'ACME_SERVER must name Google Trust Services'
[ "${BOOKS_FQDN:-$FQDN}" = "$FQDN" ] && [ "${BUILD_PLANE_FQDN:-}" = "$FQDN" ] \
  || fail 'this master must keep the books and the build plane'
case "$STAGE" in dev|test|prod) ;; *) fail 'STAGE is not dev, test or prod' ;; esac
. "$HERE/driver.sh"

TARGET="$OPERATOR_USER@${MACHINE_HOST:-$FQDN}"
[[ "$TARGET" =~ ^[a-z_][a-z0-9_-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || fail 'the SSH target is not a login and host'
BASE=(-p 22 -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
CHECKOUT=/srv/ansiwise-programs
ENGINE=/usr/local/bin/ansiwise
RUNS=/var/lib/ansiwise/runs

# Readiness and the birth guard run before a program receives any input. The map and release pin
# belong to this installed machine, so a first installation cannot enter this action.
printf -v fqdn_arg '%q' "$FQDN"
printf -v master_map_check '%q' 'import pathlib,re,sys; s=pathlib.Path(sys.argv[1]).read_text(); sys.exit(0 if re.search(r"(?m)^role:[ \t]*[\x22\x27]?master[\x22\x27]?[ \t]*(?:#.*)?$",s) else 1)'
probe="python3 -c $master_map_check /srv/hostyour-cloud/clusters/active/$FQDN.yaml && test -x $ENGINE && test -r $CHECKOUT/ansiwise.yaml && test -r /srv/hostyour-cloud/clusters/active/$FQDN.yaml && test \"\$(git -C /srv/hostyour-cloud branch --show-current)\" = $fqdn_arg"
ssh "${BASE[@]}" -n "$TARGET" "$probe" || fail 'the target is not the installed master on its own branch' 69
DECLARATION="$(ssh "${BASE[@]}" -n "$TARGET" "cat $CHECKOUT/ansiwise/programs/deploy-platform-services.yaml")" \
  || fail 'the installed deploy-platform-services program could not be read' 69
printf '%s\n' "$DECLARATION" | grep -qE '^  - name: plane_api_token[[:space:]]*$' \
  || fail 'the installed program has no plane_api_token input; release the reviewed program and engine first'
ENVELOPE="$(project_program_input "$FILE" <(printf '%s\n' "$DECLARATION"))" \
  || fail 'the declared inputs could not be projected; no remote mutation was started'
ACTIVE_SSH=''
cancel() {
  if [ -n "$ACTIVE_SSH" ]; then
    kill -TERM "$ACTIVE_SSH" 2>/dev/null || true
    wait "$ACTIVE_SSH" 2>/dev/null || true
  fi
  unset ENVELOPE PLANE_API_TOKEN ELEVATION_PASSWORD
  exit "$1"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
trap 'unset ENVELOPE PLANE_API_TOKEN ELEVATION_PASSWORD' EXIT

for mode in test dry run; do
  platform_program_command "$ENGINE" "$CHECKOUT" - "$RUNS" master "$STAGE" "$FQDN" "$mode" deploy-platform-services
  printf -v command '%q ' "${PROGRAM_COMMAND[@]}"
  printf 'redeploy-platform-services: deploy-platform-services --mode %s on %s\n' "$mode" "$FQDN"
  printf '%s\n' "$ENVELOPE" | ssh "${BASE[@]}" "$TARGET" "cd $CHECKOUT && exec $command" &
  ACTIVE_SSH=$!
  wait "$ACTIVE_SSH" || fail "deploy-platform-services --mode $mode failed; later modes were not started" 69
  ACTIVE_SSH='' 
done
printf 'redeploy-platform-services: OK — test, dry and run completed\n'
