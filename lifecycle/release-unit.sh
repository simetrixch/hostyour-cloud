#!/usr/bin/env bash
command -v node >/dev/null 2>&1 || { printf 'release-unit: node is required\n' >&2; exit 69; }
command -v ssh >/dev/null 2>&1 || { printf 'release-unit: ssh is required\n' >&2; exit 69; }
exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-unit.mjs" "$@"
