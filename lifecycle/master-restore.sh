#!/usr/bin/env bash
# ===========================================================================
# master-restore.sh — stages a master's backup on a bare machine, from an operator's machine.
#
#   bash lifecycle/master-restore.sh lifecycle/config.<machine>.env <backup-id>
#   bash lifecycle/master-restore.sh lifecycle/config.<machine>.env          # lists the backups
#
# WHAT A RESTORE IS HERE. Not a machine put back, an installation put back: the same identity
# (FQDN), the same branch on origin, the same stores — on a different machine, reached through its
# own name (MACHINE_HOST) while the identity still points at the one that died or at nothing. This
# stages what install-machine then finds standing: the platform checkout with the installation's
# branch, Vault's quorum beside it, and every store opened and ready to be placed the moment the
# cluster exists. It does not install; install-machine does, exactly as for a first machine, and
# driver.sh places the stores between deploy-cluster and deploy-platform-services because a volume
# can be named only once its claim exists. master-restore-driver.sh says the rest.
#
# THE ORDER, WHOLE:  master-restore <config> <id>  →  install-machine <config>  →  the name.
# The name is the operator's own act at the end: master.<apex> and *.master.<apex> onto this
# machine, once install-machine is green.
#
# ONE SESSION, THE CONFIG AHEAD OF THE DRIVER, like install-machine. The machine is bare, so the
# door may be the password door: the key is tried first, and where it is refused ssh asks for the
# login password ONCE, on this terminal. It is not read from the config and it is not kept.
#
# Written twice, in bash and in PowerShell, held to the same bytes by lifecycle/test.sh.
# ===========================================================================
set -uo pipefail
die() { printf 'restore: %s. Nothing has been changed\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

CONFIG="${1:-}"
ID="${2:-}"
[ $# -le 2 ] || die "lifecycle/master-restore.sh was given more than it takes: $3" 64
[ -n "$CONFIG" ] || die 'usage: lifecycle/master-restore.sh <config> [backup-id]' 64
case "$ID" in
  ''|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) die "a backup is named by the moment it was taken, like 20260922T031500Z, and \"$ID\" is not one. Run this without an id to see the ones the storage box holds" 64 ;;
esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/master-restore-driver.sh"
[ -r "$DRIVER" ] \
  || die 'master-restore-driver.sh is not beside this file. It IS the staging on the machine, and this only starts it' 66
. "$HERE/require-owner-only.sh" \
  || die 'require-owner-only.sh is not beside this file. It is the guard every launcher puts on a config' 66
command -v ssh >/dev/null 2>&1 \
  || die 'ssh is not on this path, and the staging is one session to the machine'

[ -r "$CONFIG" ] \
  || die "there is no config at $CONFIG. It states the installation this restores: copy config.example.env beside it, fill it in, and name it as the first argument" 66
require_owner_only "$CONFIG" \
  || die "$CONFIG $REACH and carries credentials, the elevation password of the machine among them. Run: $OWNER_ONLY_COMMAND" 77
CONFIG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
if git -C "$CONFIG_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  git -C "$CONFIG_DIR" check-ignore -q "$CONFIG" 2>/dev/null \
    || die "$CONFIG stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore" 77
fi
BAD=$(grep -nvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$CONFIG" | head -3)
[ -z "$BAD" ] \
  || die "$CONFIG carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL on both sides: $BAD" 65
. "$CONFIG"
for named in FQDN OPERATOR_USER STAGE PLATFORM_REPO PLATFORM_BRANCH; do
  [ -n "${!named:-}" ] || die "$CONFIG states no $named, and nothing here may choose one" 65
done
[ -n "${ELEVATION_PASSWORD:-}" ] \
  || die "$CONFIG states no ELEVATION_PASSWORD, and every store is placed elevated" 65
[ -n "${PLATFORM_REPO_READ_PAT:-}" ] \
  || die "$CONFIG states no PLATFORM_REPO_READ_PAT, and the platform checkout is cloned with it" 65
for named in STORAGE_BOX_HOST STORAGE_BOX_USER STORAGE_BOX_PASSWORD; do
  [ -n "${!named:-}" ] || die "$CONFIG states no $named, and the storage box is where a backup comes from" 65
done
[ -n "${BACKUP_PASSPHRASE:-}" ] \
  || die "$CONFIG states no BACKUP_PASSPHRASE, and a backup is opened with it or not at all" 65

# The door is MACHINE_HOST where the config states one — a standby master reached through its own
# name while the identity points at the live one (install-machine.sh says why) — and the identity where not.
DOOR_HOST="${MACHINE_HOST:-$FQDN}"
PORT=22
TARGET="$OPERATOR_USER@$DOOR_HOST"
BASE=(-p "$PORT" -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)
# `-n`: THE PROBE READS NOTHING, and without it ssh reads this terminal. Windows' own
# OpenSSH then stays after `true` has ended until a key is pressed.
PROBE=$(ssh "${BASE[@]}" -n -o BatchMode=yes "$TARGET" true 2>&1)
if [ $? -eq 0 ]; then
  DOOR=(-o BatchMode=yes)
  say "restore: $TARGET opens to the operator key"
else
  case "$PROBE" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*)
      die "$DOOR_HOST answers with a host key this machine does not recognise. A restore gives a machine a NEW host key: if you have just restored it, forget the old one with ssh-keygen -R $DOOR_HOST and start again. If you have not, clear nothing: something else is answering for $DOOR_HOST" 74 ;;
    *'Permission denied'*)
      [ -t 0 ] \
        || die "$TARGET carries no operator key yet, so this can only be a password session, and there is no terminal here to ask on. Start it from a terminal" 69
      DOOR=(-o BatchMode=no -o NumberOfPasswordPrompts=1)
      say "restore: $TARGET carries no operator key yet, so ssh asks for the login password ONCE, on this terminal. It is not read from the config and it is not kept" ;;
    *)
      die "$TARGET could not be reached: $(printf '%s' "$PROBE" | tr '\n' ' ')" 69 ;;
  esac
fi

{
  printf 'umask 077\ncat > "$1" <<%sAW_CONFIG_END%s\n' "'" "'"
  tr -d $'\r' < "$CONFIG"
  printf 'AW_CONFIG_END\n'
  tr -d $'\r' < "$DRIVER"
} | ssh "${BASE[@]}" "${DOOR[@]}" "$TARGET" "bash -s -- \"\$HOME/.aw-restore.env\" $ID"
STAGED=${PIPESTATUS[1]}
if [ "$STAGED" -eq 0 ]; then
  say "restore: backup $ID of $FQDN is staged on $DOOR_HOST. Now: install-machine with this config, then point the name at the machine"
elif [ -z "$ID" ] && [ "$STAGED" -eq 64 ]; then
  say "restore: the backups above are what the storage box holds for $FQDN; name one as the second argument"
else
  say "restore: the staging on $DOOR_HOST ended with exit $STAGED. The line above it says what stopped and why"
fi
exit "$STAGED"
