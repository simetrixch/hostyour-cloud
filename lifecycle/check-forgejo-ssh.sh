#!/usr/bin/env bash
# =============================================================================
# check-forgejo-ssh.sh — does the SSH port an installation announces for Forgejo
# answer with an SSH banner, from where this runs?
# =============================================================================
#
#   bash lifecycle/check-forgejo-ssh.sh master.example.com
#
# Run it from OUTSIDE the installation's network: the port is the one the owner's router
# forwards (FORGEJO_SSH_PORT in the installation's config, 23 today) to the master's 2222. The
# master's 2222 is internal and is not what is probed.
#
# THE PORT AND THE HOST ARE READ, NEVER WRITTEN HERE. Both stand on the install branch, in
# installation/values/forgejo.yaml, as gitea.config.server.SSH_PORT and SSH_DOMAIN, which is what
# Forgejo puts into every clone address it shows. So the probe asks exactly where a clone would go.
#
# IT ONLY ANSWERS. Exit 0 when the first bytes the port sends begin with `SSH-`; 1 when it
# refuses, times out or sends anything else; 65 and up when the question could not be asked: 66 when
# the branch runs no Forgejo (no installation/values/forgejo.yaml), 67 when it runs one that announces
# no SSH_DOMAIN and numeric SSH_PORT, 69 when origin could not be fetched. status.sh and
# install-machine.sh call it and read these codes: 66 is not a row, 0 is green, 1 is red.
# =============================================================================

set -uo pipefail

die() { printf 'check-forgejo-ssh: %s\n' "$1" >&2; exit "${2:-65}"; }

[ $# -eq 1 ] || die 'usage: check-forgejo-ssh.sh <installation fqdn>'
FQDN="$1"
for tool in git yq curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on this path"
done

git fetch --quiet origin "$FQDN" \
  || die "origin could not be fetched, so nothing here would be an answer about what $FQDN announces" 69
VALUES="$(git show "FETCH_HEAD:installation/values/forgejo.yaml" 2>/dev/null)" \
  || die "$FQDN carries no installation/values/forgejo.yaml; it is not an installation with a Forgejo" 66
HOST="$(yq '.forgejo.gitea.config.server.SSH_DOMAIN // ""' <<<"$VALUES")"
PORT="$(yq '.forgejo.gitea.config.server.SSH_PORT // ""' <<<"$VALUES")"
[ -n "$HOST" ] && [[ "$PORT" =~ ^[0-9]+$ ]] \
  || die "$FQDN announces no SSH_DOMAIN and numeric SSH_PORT for Forgejo" 67

# An SSH server speaks first, so curl's raw connection (telnet://) prints the banner and is ended by
# the time limit, which is why only the bytes it printed are read and not its exit code.
BANNER="$(curl -sS --connect-timeout 5 --max-time 8 "telnet://$HOST:$PORT" </dev/null 2>/dev/null | head -c 64 | tr -d '\r' | head -n 1)"
case "$BANNER" in
  SSH-*) printf 'check-forgejo-ssh: %s:%s answers %s\n' "$HOST" "$PORT" "$BANNER" ;;
  *) printf 'check-forgejo-ssh: %s:%s gave no SSH banner\n' "$HOST" "$PORT" >&2; exit 1 ;;
esac
