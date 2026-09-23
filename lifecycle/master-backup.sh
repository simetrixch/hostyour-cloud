#!/usr/bin/env bash
# ===========================================================================
# master-backup.sh — takes a backup of ONE master, from an operator's machine.
#
#   bash lifecycle/master-backup.sh lifecycle/config.<machine>.env
#
# WHAT IT TAKES, AND WHY THIS EXISTS. A master is the one machine of an installation that holds
# state nothing else holds: Vault with every unit's secrets, the Manager's database, the IdP's
# accounts, Headscale's nodes, its own MongoDB, Redis, mail queue, registry and dbgate — and the file
# Vault's quorum was written to once, secrets/vault-<stage>.txt. Lose the machine and every one of
# them is gone; the install branch, the registrations and the catalog on origin describe an
# installation that can no longer be opened. This takes that set, sealed with BACKUP_PASSPHRASE, to
# the storage box under master/<fqdn>/<id>/, and master-restore brings it back onto a bare machine.
#
# ONE SESSION, THE CONFIG AHEAD OF THE DRIVER. master-backup-driver.sh is the backup itself and runs
# on the machine; this only opens the session and carries it over, the config inside a quoted
# heredoc on the same standard input, exactly as install-machine does. The passphrase and the storage
# box's credentials travel that way and land in no file on either side.
#
# THE DOOR IS THE OPERATOR KEY ALONE. A master carries it — deploy-host put it there — and
# disable-password-login has shut the other door. A machine that refuses the key is not an installed
# master, and this refuses it rather than asking for a password it should not need.
#
# WHAT STOPS, FOR HOW LONG. Each store is scaled to nothing for its own copy and started again with
# the replicas it had: a database copied under a running process is a copy with a write in flight.
# The Manager is one of them, so a run in flight when this starts is a run this interrupts — start
# this at a quiet hour. The units on the master keep running; what they read from a stopped store
# they read again once it is back.
#
# Written twice, in bash and in PowerShell, held to the same bytes by lifecycle/test.sh.
# ===========================================================================
set -uo pipefail
die() { printf 'backup: %s. Nothing has been changed\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

CONFIG="${1:-}"
[ $# -le 1 ] || die "lifecycle/master-backup.sh was given more than it takes: $2" 64
[ -n "$CONFIG" ] || die 'usage: lifecycle/master-backup.sh <config>' 64
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/master-backup-driver.sh"
[ -r "$DRIVER" ] \
  || die 'master-backup-driver.sh is not beside this file. It IS the backup on the machine, and this only starts it' 66
. "$HERE/require-owner-only.sh" \
  || die 'require-owner-only.sh is not beside this file. It is the guard every launcher puts on a config' 66
command -v ssh >/dev/null 2>&1 \
  || die 'ssh is not on this path, and the backup is one session to the machine'

[ -r "$CONFIG" ] \
  || die "there is no config at $CONFIG. It states the installation this backs up: copy config.example.env beside it, fill it in, and name it as the argument" 66
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
for named in FQDN OPERATOR_USER STAGE; do
  [ -n "${!named:-}" ] || die "$CONFIG states no $named, and nothing here may choose one" 65
done
[ -n "${ELEVATION_PASSWORD:-}" ] \
  || die "$CONFIG states no ELEVATION_PASSWORD, and every store is stopped and copied elevated" 65
for named in STORAGE_BOX_HOST STORAGE_BOX_USER STORAGE_BOX_PASSWORD; do
  [ -n "${!named:-}" ] || die "$CONFIG states no $named, and the storage box is where a backup goes" 65
done
[ -n "${BACKUP_PASSPHRASE:-}" ] \
  || die "$CONFIG states no BACKUP_PASSPHRASE, and a backup of a master's every credential leaves the machine sealed or not at all" 65

# The door is MACHINE_HOST where the config states one — a standby master kept through its own name
# while the identity points at the live one (install-machine.sh says why) — and the identity where not.
DOOR_HOST="${MACHINE_HOST:-$FQDN}"
PORT=22
TARGET="$OPERATOR_USER@$DOOR_HOST"
BASE=(-p "$PORT" -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
# `-n`: THE PROBE READS NOTHING, and without it ssh reads this terminal. Windows' own
# OpenSSH then stays after `true` has ended until a key is pressed.
PROBE=$(ssh "${BASE[@]}" -n "$TARGET" true 2>&1)
if [ $? -ne 0 ]; then
  case "$PROBE" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*)
      die "$DOOR_HOST answers with a host key this machine does not recognise. A restore gives a machine a NEW host key: if you have just restored it, forget the old one with ssh-keygen -R $DOOR_HOST and start again. If you have not, clear nothing: something else is answering for $DOOR_HOST" 74 ;;
    *'Permission denied'*)
      die "$TARGET refuses the operator key. A master carries it, so this is not an installed master — or not the machine $DOOR_HOST names" 69 ;;
    *)
      die "$TARGET could not be reached: $(printf '%s' "$PROBE" | tr '\n' ' ')" 69 ;;
  esac
fi
say "backup: $TARGET opens to the operator key; the backup of $FQDN starts"

{
  printf 'umask 077\ncat > "$1" <<%sAW_CONFIG_END%s\n' "'" "'"
  tr -d $'\r' < "$CONFIG"
  printf 'AW_CONFIG_END\n'
  tr -d $'\r' < "$DRIVER"
} | ssh "${BASE[@]}" "$TARGET" 'bash -s -- "$HOME/.aw-backup.env"'
TAKEN=${PIPESTATUS[1]}
if [ "$TAKEN" -eq 0 ]; then
  say "backup: the backup of $FQDN stands on the storage box; the BACKUP line above names it, and master-restore takes that name"
else
  say "backup: the backup of $FQDN ended with exit $TAKEN. The line above it says what stopped and why"
fi
exit "$TAKEN"
