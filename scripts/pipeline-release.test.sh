#!/usr/bin/env bash
# The release pipeline's own shell, where it decides something a fixture can hold it to:
# class (d) of the bump moves a tenant onto the bundle it just built only where the bundle and
# the tenant's engines are of one line (clusters/inventories/consumer-build/templates/
# pipeline-release.yaml, engine_line_off). The function is read out of the template, as the
# Pipeline carries it, and run against fixture registrations; its call is held to standing
# before the registration is written.
#
#   bash scripts/pipeline-release.test.sh
set -uo pipefail
root="$(git rev-parse --show-toplevel)" || exit 1
template="$root/clusters/inventories/consumer-build/templates/pipeline-release.yaml"
fail() { echo "pipeline-release.test: RED — $*" >&2; exit 1; }
ok() { echo "pipeline-release.test: ok — $*"; }
command -v yq >/dev/null 2>&1 || fail "yq is not on this path, and the function under test runs it"
work="$(mktemp -d)" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT

# From the function's first line to the brace that closes it at the same indent.
awk '
  /^ *engine_line_off\(\) \{/ { indent = match($0, /[^ ]/); on = 1 }
  on { print }
  on && /^ *\}$/ && match($0, /[^ ]/) == indent { exit }
' "$template" > "$work/engine-line.sh"
[ -s "$work/engine-line.sh" ] || fail "the template carries no engine_line_off function"
# shellcheck source=/dev/null
. "$work/engine-line.sh"

reg="$work/registration.yaml"
cat > "$reg" <<'EOF'
approvedTags:
  erp: { digita-engine: "0.3.004-stable-20260928080242-a1b2c3d", digita-app: "0.3.004-stable-20260928080242-a1b2c3d" }
  auth: { digita-auth-backend: "0.4.000-stable-20261001000000-abc1234" }
EOF
[ -z "$(engine_line_off digita-engine 0.3 "$reg")" ] \
  || fail "a tenant whose engine runs 0.3.004 was taken for one of another line than 0.3"
ok "a tenant whose engine runs 0.3.x fits a bundle written for 0.3, and a member without the engine pairs with nothing"

off="$(engine_line_off digita-engine 0.4 "$reg")"
[ "$off" = "0.3.004-stable-20260928080242-a1b2c3d" ] \
  || fail "PLANTED DEFECT: a tenant on 0.3 beside a bundle written for 0.4 must be named with its tag, and the answer was '$off'"
ok "a tenant on 0.3 beside a bundle written for 0.4 is named with the tag it runs"

cat > "$reg" <<'EOF'
cluster: s1
appsImage: example-apps-acme
EOF
[ -z "$(engine_line_off digita-engine 0.3 "$reg")" ] || fail "a registration that holds no versions was taken for one off the line"
ok "a registration that holds no versions pairs with nothing"

# The call has to stand before the write it guards, inside class (d): a check placed after the
# registration is written would report a mismatch it had already committed.
call="$(grep -n 'off="$(engine_line_off ' "$template" | head -1 | cut -d: -f1)"
write="$(grep -n 'yq eval -i ".appsImageTag = ' "$template" | head -1 | cut -d: -f1)"
[ -n "$call" ] && [ -n "$write" ] || fail "the template lost either the engine-line call or the appsImageTag write"
[ "$call" -lt "$write" ] || fail "the engine-line call stands at line $call, after the appsImageTag write at line $write"
ok "class (d) judges the engine line (line $call) before it writes appsImageTag (line $write)"

echo "pipeline-release.test: OK"
