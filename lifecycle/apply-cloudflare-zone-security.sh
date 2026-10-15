#!/usr/bin/env bash
# apply-cloudflare-zone-security.sh <config> preview|apply — the Cloudflare Free controls of the
# installation's two zones; apply-cloudflare-zone-security.mjs beside it says which. The config carries
# the zone security token and the origin pull private key, so it is asked to be owner-only first.
set -uo pipefail
die() { printf 'apply-cloudflare-zone-security: %s\n' "$1" >&2; exit "${2:-65}"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for tool in node git curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on this path, and this act needs it" 69
done
[ -n "${1:-}" ] || die 'usage: lifecycle/apply-cloudflare-zone-security.sh <config> preview|apply' 64
[ -r "$1" ] || die "there is no config at $1. It is the installation's own, the one install-machine is given: name it as the first argument" 66
# shellcheck disable=SC1091
. "$HERE/require-owner-only.sh" || die 'require-owner-only.sh is not beside this file. It is the guard every launcher puts on a config' 66
require_owner_only "$1" \
  || die "$1 $REACH, and it carries the zone security token and the origin pull private key. Make it owner-only with: $OWNER_ONLY_COMMAND. Nothing has been changed" 65
exec node "$HERE/apply-cloudflare-zone-security.mjs" "$@"
