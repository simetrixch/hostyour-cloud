#!/usr/bin/env bash
# ===========================================================================
# plane-restore.sh — puts one backup of the set plane back into the STANDING cluster of ONE master, from an operator's machine.
#
#   bash lifecycle/plane-restore.sh lifecycle/config.<machine>.env <backup-id>
#   bash lifecycle/plane-restore.sh lifecycle/config.<machine>.env          # lists the backups
#
# WHAT IT DOES, AND WHAT IT COSTS. The backup is the one master-backup.sh <config> plane put under <fqdn>/plane/<id>/ on the storage
# box. Plane's PostgreSQL and its object store are stopped one at a time, their volumes are emptied and filled from the backup,
# and each is started again and waited for. Everything written to Plane after the backup is gone, which is the point of a
# restore and also its price: no session may write to Plane while this runs. The content each volume had stays beside the
# work until both stores read ready, and the driver says where when one does not.
#
# NOT master-restore. That one stages a master's backup on a BARE machine, before install-machine, and refuses a machine whose
# claims stand. This one acts on a cluster that stands and touches Plane's two volumes alone. It is also the only one of the
# restores that takes the lock master-backup takes: a restore and a backup of the same stores never run at once.
#
# ONE SESSION, THE CONFIG AND THE RCLONE AHEAD OF THE DRIVER, exactly as master-backup.sh sends them. The door is the operator
# key alone: a master carries it, and a machine that refuses it is not an installed master.
# ===========================================================================
set -uo pipefail
die() { printf 'restore: %s. Nothing has been changed\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

USAGE='usage: lifecycle/plane-restore.sh <config> [backup-id]'
CONFIG="${1:-}" ID="${2:-}"
[ $# -le 2 ] || die "lifecycle/plane-restore.sh was given more than it takes: $3" 64
[ -n "$CONFIG" ] || die "$USAGE" 64
case "$ID" in
  ''|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) die "a backup is named by the moment it was taken, like 20260922T031500Z, and \"$ID\" is not one. Run this without an id to see the ones the storage box holds" 64 ;;
esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/plane-restore-driver.sh"
[ -r "$DRIVER" ] \
  || die 'plane-restore-driver.sh is not beside this file. It IS the restore on the machine, and this only starts it' 66
. "$HERE/require-owner-only.sh" \
  || die 'require-owner-only.sh is not beside this file. It is the guard every launcher puts on a config' 66
. "$HERE/require-config-assignments.sh" \
  || die 'require-config-assignments.sh is not beside this file. It is the check every launcher makes on the lines of a config' 66
. "$HERE/read-rclone-pin.sh" \
  || die 'read-rclone-pin.sh is not beside this file. It is what tells the machine which rclone to run' 66
RCLONE_HELPER="$HERE/require-rclone.sh"
[ -r "$RCLONE_HELPER" ] \
  || die 'require-rclone.sh is not beside this file. It is what puts the pinned rclone on the machine, and the machine can read no sibling' 66
command -v ssh >/dev/null 2>&1 \
  || die 'ssh is not on this path, and the restore is one session to the machine'

[ -r "$CONFIG" ] \
  || die "there is no config at $CONFIG. It states the installation this restores: copy config.example.env beside it, fill it in, and name it as the first argument" 66
require_owner_only "$CONFIG" \
  || die "$CONFIG $REACH and carries credentials, the elevation password of the machine among them. Run: $OWNER_ONLY_COMMAND" 77
CONFIG_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
if git -C "$CONFIG_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  git -C "$CONFIG_DIR" check-ignore -q "$CONFIG" 2>/dev/null \
    || die "$CONFIG stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore" 77
fi
require_config_assignments "$CONFIG" "$CONFIG_EXAMPLE_KEYS" \
  || die "$CONFIG carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL on both sides: $BAD_LINES. They are named and never quoted, because a line may carry a credential" 65
. "$CONFIG"
for named in FQDN OPERATOR_USER STAGE; do
  [ -n "${!named:-}" ] || die "$CONFIG states no $named, and nothing here may choose one" 65
done
[ -n "${ELEVATION_PASSWORD:-}" ] \
  || die "$CONFIG states no ELEVATION_PASSWORD, and every store is stopped and filled elevated" 65
for named in STORAGE_BOX_HOST STORAGE_BOX_USER STORAGE_BOX_PASSWORD; do
  [ -n "${!named:-}" ] || die "$CONFIG states no $named, and the storage box is where a backup comes from" 65
done
[ -n "${BACKUP_PASSPHRASE:-}" ] \
  || die "$CONFIG states no BACKUP_PASSPHRASE, and a backup is opened with it or not at all" 65

read_rclone_pin "$HERE/.." \
  || die "the rclone this restore runs is not stated by the tree it was released in: $RCLONE_METADATA_ERROR" 65

# The door is MACHINE_HOST where the config states one — a standby master kept through its own name
# while the identity points at the live one (install-machine.sh says why) — and the identity where not.
DOOR_HOST="${MACHINE_HOST:-$FQDN}"
PORT=22
TARGET="$OPERATOR_USER@$DOOR_HOST"
BASE=(-p "$PORT" -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
# `-n`: THE PROBE READS NOTHING. Without it ssh reads standard input, and takes what
# was typed or piped there for what comes after.
PROBE=$(ssh "${BASE[@]}" -n "$TARGET" true 2>&1)
if [ $? -ne 0 ]; then
  case "$PROBE" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Host key verification failed'*)
      die "$DOOR_HOST answers with a host key this machine does not recognise. Clear nothing: something else may be answering for $DOOR_HOST" 74 ;;
    *'Permission denied'*)
      die "$TARGET refuses the operator key. A master carries it, so this is not an installed master — or not the machine $DOOR_HOST names" 69 ;;
    *)
      # ssh ends its own lines with \r\n, and a \r left inside the sentence sends a terminal
      # back to the start of the line, over what was already printed.
      die "$TARGET could not be reached: $(printf '%s' "$PROBE" | tr -d '\r' | tr '\n' ' ')" 69 ;;
  esac
fi
say "restore: $TARGET opens to the operator key; the restore of the set plane of $FQDN starts"

{
  printf 'umask 077\ncat > "$1" <<%sAW_CONFIG_END%s\n' "'" "'"
  tr -d $'\r' < "$CONFIG"
  printf 'AW_CONFIG_END\n'
  tr -d $'\r' < "$RCLONE_HELPER"
  printf '%s\n' "$RCLONE_METADATA"
  tr -d $'\r' < "$DRIVER"
} | ssh "${BASE[@]}" "$TARGET" "bash -s -- \"\$HOME/.aw-plane-restore.env\" $ID"
RESTORED=${PIPESTATUS[1]}
if [ "$RESTORED" -eq 0 ]; then
  say "restore: backup $ID of the set plane of $FQDN is back in the cluster; the RESTORED line above names it"
elif [ -z "$ID" ] && [ "$RESTORED" -eq 64 ]; then
  say "restore: the backups above are what the storage box holds for $FQDN under plane; name one as the second argument"
else
  say "restore: the restore on $DOOR_HOST ended with exit $RESTORED. The line above it says what stopped and why"
fi
exit "$RESTORED"
