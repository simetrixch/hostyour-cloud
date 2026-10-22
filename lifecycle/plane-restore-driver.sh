#!/usr/bin/env bash
# ===========================================================================
# plane-restore-driver.sh — puts one backup of the set plane back into the standing cluster, ON THE MACHINE.
#
# Started by plane-restore.sh over the one session it opens, with the config ahead of it on the same standard input and the
# backup's id as its second argument. Never started by hand.
#
# WHAT IS RESTORED. The two stores master-backup-driver.sh takes as its set plane: Plane's PostgreSQL (plane-pgdb) and its object
# store (plane-minio), each one volume under the storage root. The cluster stands, so nothing is staged: each store is stopped, the
# content of its volume is moved aside, the archive is opened into the volume with the owners the archive names, and the store is
# started with the replicas it had and waited for. Plane's other pods keep running, and cannot reach a store while it is stopped.
# A write to Plane after the backup is gone.
#
# NOTHING IS STOPPED UNTIL EVERYTHING IS KNOWN. The backup is fetched to /var/lib/master-backup/restore-<id>/ (root's, mode 700) and
# refused, before a store is stopped, when its checksums do not hold, when its manifest was written for another FQDN, STAGE or
# set, when it counts other stores than this driver has rows or lacks an archive, when an archive does not open with the config's
# passphrase, or when a workload or a volume of a row is not in the cluster. Folders an earlier restore of the same id left behind
# are refused too, because the content that restore replaced may be the only copy there is.
#
# THE REPLACED CONTENT IS KEPT. What a volume held is moved to /var/lib/master-backup/restore-<id>.replaced/<namespace>--<claim>/,
# not deleted, and both folders are removed only once both stores read ready. A store that does not read ready, or a step that
# fails, ends 70 and leaves both folders where they stand, naming the store and two commands: the one that puts the old content back
# and the one that keeps the new and clears the folders. A restore killed after it began to stop stores leaves them too.
#
# ONE RUN AT A TIME ON A MACHINE, with the lock master-backup-driver.sh takes (its text says why): a restore and a backup of the
# same stores never run at once. The two copies of the lock lines are held byte-equal by lifecycle/test.sh.
#
# GIVEN NO ID, it lists the backups the storage box holds for this installation under plane/ and stops: the id is the one thing
# here a person chooses, and the list is how they choose it.
# ===========================================================================
set -uo pipefail

C_OFF=$'\033[0m' C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_BLD=$'\033[1m'
say()  { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
good() { printf '%s   ✓ %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '%s   ! %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
die()  { printf '%s   ✗ %s%s\n' "$C_RED" "$1" "$C_OFF" >&2; exit "${2:-1}"; }
step() { printf '\n%s══ %s%s\n' "$C_BLD" "$*" "$C_OFF"; }

readonly CONFIG="${1:?the first argument is the path of the config}"
readonly ID="${2:-}"
readonly BACKUP_ROOT=/var/lib/master-backup
readonly FETCH="$BACKUP_ROOT/restore-$ID"
readonly KEPT="$FETCH.replaced"
# How long a store is given to stop and to read ready, in seconds, and how often it is looked at. Each stands on a line of its own because a test moves them.
readonly STORE_POLL_SECONDS=2
readonly STORE_WAIT_SECONDS=180
SECRETS='' FETCHED='' KEEP=''
# The fetched backup is removed on every way out that has stopped no store; once a store is stopped it stays, with the content it replaced.
cleanup() {
  rm -f "$CONFIG" 2>/dev/null || true
  if [ -n "$FETCHED" ] && [ -z "$KEEP" ]; then root rm -rf "$FETCH" >/dev/null 2>&1; fi
  [ -z "$SECRETS" ] || rm -rf "$SECRETS" 2>/dev/null || true
  rclone_cleanup
}
trap cleanup EXIT
trap 'exit 143' INT TERM

# The same function as require-config-assignments.sh, held byte-equal to it by test.sh: this
# script arrives over one ssh session and can read no sibling. It is handed no keys, so a refused
# line is named by its number alone and never quoted, because it may carry a credential.
require_config_assignments() {
  local file="$1" keys="${2:-}"
  BAD_LINES=$(
    export LC_ALL=C
    grep -anvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$file" \
      | tr -d '\000' \
      | head -3 \
      | awk -v keys=" $keys " '{
          number = substr($0, 1, index($0, ":") - 1)
          name = ""
          if (match(substr($0, index($0, ":") + 1), /^[A-Z][A-Z0-9_]*=/)) {
            name = substr($0, index($0, ":") + 1, RLENGTH - 1)
            if (index(keys, " " name " ") == 0) name = ""
          }
          printf "%sline %s%s", (NR > 1 ? ", " : ""), number, (name == "" ? "" : " (" name ")")
        }'
  )
  [ -z "$BAD_LINES" ]
}
require_config_assignments "$CONFIG" \
  || die "the config carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL: $BAD_LINES. They are named and never quoted, because a line may carry a credential" 65
. "$CONFIG"
for named in FQDN OPERATOR_USER STAGE ELEVATION_PASSWORD STORAGE_BOX_HOST STORAGE_BOX_USER STORAGE_BOX_PASSWORD BACKUP_PASSPHRASE; do
  [ -n "${!named:-}" ] || die "the config says nothing under ${named}, and nothing here may choose one" 64
done
case "$ID" in
  ''|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) die "a backup is named by the moment it was taken, like 20260922T031500Z, and \"$ID\" is not one" 64 ;;
esac

# A SECRET AN ELEVATED COMMAND NEEDS IS A FILE, never an argument: sudo writes every command it runs, with
# its arguments, to the system log, and any local account reads an argument in the process list. This
# shell's own printf is no process, so it writes the secret to a file of mode 600 in a folder in memory
# that cleanup removes, and the elevated command is given the file's path.
SECRETS="$(mktemp -d /dev/shm/aw-plane-restore.XXXXXX)" || die 'no folder in memory could be made for the secrets an elevated command needs, and none of them may stand on its command line' 78
PASSPHRASE_FILE="$SECRETS/passphrase"
( umask 077; printf '%s' "$BACKUP_PASSPHRASE" > "$PASSPHRASE_FILE" ) || die 'the passphrase could not be written to a file in memory' 78
root() { printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' "$@"; }
K() { microk8s kubectl "$@"; }

# THE STORES, ONE ROW EACH: namespace | claim | the workload stopped for the copy | its kind. The SAME rows
# master-backup-driver.sh takes as its set plane, in the same order; lifecycle/test.sh holds the two lists against each other.
STORES=(
  "plane|pvc-plane-pgdb-vol-plane-pgdb-wl-0|plane-pgdb-wl|statefulset"
  "plane|pvc-plane-minio-vol-plane-minio-wl-0|plane-minio-wl|statefulset"
)
readonly STORAGE_ROOT=/var/snap/microk8s/common/default-storage
BACKUPS="box:$FQDN/plane"

step "what this machine is, before anything is stopped"
say "asked as $(id -un) on $(hostname), for $FQDN, stage $STAGE"
printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' true 2>/dev/null || die 'the ELEVATION_PASSWORD in the config does not raise a command on this machine' 77

# open_the_box: the pinned rclone from the shared helper the launcher sent ahead of this driver, then the box's config in memory and its opening.
open_the_box() {
  require_rclone || die "rclone $AW_RCLONE_PIN could not be put on this machine, and nothing else here reaches the storage box: $RCLONE_REFUSAL. Nothing was stopped" 69
  RCLONE_CONF="$SECRETS/rclone.conf"
  # The hash check of the remote is off, as where the backup was written: the box answers rclone's md5sum command with a failure or never.
  ( umask 077; printf '[box]\ntype = sftp\nhost = %s\nuser = %s\npass = %s\ndisable_hashcheck = true\n' "$STORAGE_BOX_HOST" "$STORAGE_BOX_USER" "$(printf '%s\n' "$STORAGE_BOX_PASSWORD" | rclone obscure -)" > "$RCLONE_CONF" ) \
    || die 'the storage box config could not be written to a file in memory' 78
  export RCLONE_CONFIG="$RCLONE_CONF"
  rclone lsd box: >/dev/null 2>&1 || die 'the storage box does not open — nothing was stopped' 69
  good 'the storage box opens'
}
if [ -z "$ID" ]; then
  open_the_box
  step "the backups the storage box holds for $FQDN"
  LIST=$(rclone lsf "$BACKUPS/" --dirs-only 2>/dev/null | tr -d / | sort)
  [ -n "$LIST" ] || die "the storage box holds no backup under $BACKUPS/ — master-backup with the set plane is what puts one there" 66
  printf '%s\n' "$LIST" | sed 's/^/     /'
  die 'name one of them as the second argument of plane-restore; the newest is last' 64
fi

command -v microk8s >/dev/null 2>&1 || die 'microk8s is not on this machine, so there is no cluster whose stores could be restored' 69
K get nodes >/dev/null 2>&1 || die 'the cluster does not answer, and a store that cannot be stopped cannot be restored' 69
for tool in tar gpg find; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on this machine, and the restore is made with it" 69; done
ROOT_DIR="$(readlink -f "$STORAGE_ROOT")"
[ -d "$ROOT_DIR" ] || die "$STORAGE_ROOT does not lead to a directory, so the stores' volumes cannot be found" 69
good "the stores' volumes stand under $ROOT_DIR"
# The lock comes before rclone is replaced or the storage box is reached, and it is the lock master-backup-driver.sh takes: the same file, the same record.
# The file is opened with <> and never with >, which would wipe the record of the run that holds it before the
# lock is tried. flock ends 75 on a lock another process holds, and any other code is its own failure.
LOCK_FILE=/run/lock/master-backup.lock
command -v flock >/dev/null 2>&1 || die 'flock is not on this machine, and the lock that keeps a second backup out is taken with it' 69
exec 9<>"$LOCK_FILE" || die "the lock file $LOCK_FILE could not be opened — nothing was stopped" 78
LOCKED=0
flock -n -E 75 9 || LOCKED=$?
if [ "$LOCKED" = 75 ]; then
  # The record stays in the file when its run ends, and a lock held by hand writes none, so a record names the
  # holder only while the process it names still has this file open as descriptor 9.
  HOLDER_ID='' HOLDER_PID='' HOLDER_ACT=''
  read -r HOLDER_ID HOLDER_PID HOLDER_ACT _ < "$LOCK_FILE" || true
  if [[ "$HOLDER_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ && "$HOLDER_PID" =~ ^[0-9]+$ && "$HOLDER_ACT" =~ ^(master|plane|plane-restore)$ ]] && [ "/proc/$HOLDER_PID/fd/9" -ef "$LOCK_FILE" ]; then
    die "another run holds the lock $LOCK_FILE: the act $HOLDER_ACT, run $HOLDER_ID, started ${HOLDER_ID:0:4}-${HOLDER_ID:4:2}-${HOLDER_ID:6:2} ${HOLDER_ID:9:2}:${HOLDER_ID:11:2}:${HOLDER_ID:13:2} UTC. Nothing was stopped; start this again once it has ended" 75
  fi
  die "the lock $LOCK_FILE is held, and its record is empty or names a run that is not alive, so no run can be named. Nothing was stopped; start this again once the holder has ended" 75
elif [ "$LOCKED" != 0 ]; then
  die "the lock $LOCK_FILE could not be taken, flock ended $LOCKED — nothing was stopped" 78
fi
printf '%s %s %s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$" plane-restore > "$LOCK_FILE" || die "the run's record could not be written to $LOCK_FILE, where a second run reads it" 78
open_the_box

replicas_of() { K -n "$1" get "$3/$2" -o jsonpath='{.spec.replicas}' 2>/dev/null; }
# A store reads ready by the workload's own count of ready pods, which the Deployment and StatefulSet controllers keep
# for every update strategy; kubectl's rollout status refuses a StatefulSet that is not a RollingUpdate.
ready_of() { K -n "$1" get "$3/$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null; }
# stop_store NS WORKLOAD KIND: scaled to nothing and waited for until its pods are gone. Unlike the backup's, this ends 1 when
# they are not gone within STORE_WAIT_SECONDS, because a volume is emptied under no running pod here.
stop_store() {
  local deadline=$(( SECONDS + STORE_WAIT_SECONDS ))
  K -n "$1" scale "$3/$2" --replicas=0 >/dev/null || return 1
  while [ "$(K -n "$1" get pods -o name 2>/dev/null | grep -c "^pod/${2}")" != 0 ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$STORE_POLL_SECONDS"
  done
}
start_store() { K -n "$1" scale "$3/$2" --replicas="$4" >/dev/null; } # NS WORKLOAD KIND REPLICAS

step "the backup $ID, fetched and checked"
rclone lsf "$BACKUPS/$ID/manifest.txt" >/dev/null 2>&1 \
  || die "the storage box holds no backup $ID under $BACKUPS/ — run plane-restore without an id to see the ones it holds" 66
if root test -e "$FETCH" || root test -e "$KEPT"; then
  die "$FETCH or $KEPT stands on this machine: an earlier restore of $ID stopped there, and the content it replaced may be the only copy of it. Look at both, then remove them with: sudo rm -rf $FETCH $KEPT" 65
fi
root install -d -m 700 -o root -g root "$BACKUP_ROOT" "$FETCH" || die "could not make $FETCH" 78
FETCHED=1
root rclone --config "$RCLONE_CONF" copy "$BACKUPS/$ID/" "$FETCH/" --quiet 2>/dev/null || die "the backup $ID could not be fetched (rclone ended $?)" 69
root sh -c "cd '$FETCH' && grep -E '^[0-9a-f]{64}  ' manifest.txt | sha256sum -c --quiet" \
  || die "the checksums in manifest.txt of backup $ID do not hold — the archives are not what was written, and nothing of them is placed" 65
for field in FQDN STAGE SET; do
  backed=$(root grep -E "^${field}=" "$FETCH/manifest.txt" | cut -d= -f2-)
  case "$field" in FQDN) wanted=$FQDN ;; STAGE) wanted=$STAGE ;; SET) wanted=plane ;; esac
  [ "$backed" = "$wanted" ] || die "backup $ID names $field ${backed:-nothing} and this restore needs $wanted — a backup of another installation, stage or set is not put into this cluster" 65
done
root grep -qx "STORES=${#STORES[@]}" "$FETCH/manifest.txt" || die "backup $ID counts other stores than the ${#STORES[@]} rows of this restore" 66
for row in "${STORES[@]}"; do
  IFS='|' read -r ns pvc _ <<< "$row"
  sealed="$FETCH/${ns}--${pvc}.tar.gpg"
  root test -f "$sealed" || die "backup $ID carries no archive for ${ns}/${pvc} — a backup missing a store is not one this puts back" 66
  root grep -qE "^[0-9a-f]{64}  ${ns}--${pvc}\.tar\.gpg\$" "$FETCH/manifest.txt" || die "the manifest of backup $ID holds no checksum for the archive of ${ns}/${pvc}, and an archive no checksum holds is not put back" 65
  root bash -c 'set -o pipefail; gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$1" -d "$2" | tar -tf - >/dev/null' _ "$PASSPHRASE_FILE" "$sealed" \
    || die "the archive of ${ns}/${pvc} does not open with the BACKUP_PASSPHRASE of the config, or is no archive — nothing was stopped" 65
done
good "backup $ID of $FQDN ($STAGE, the set plane) fetched — every checksum holds and every archive opens"

step "the stores in the cluster, before anything is stopped"
DIRS=() WANTS=()
for row in "${STORES[@]}"; do
  IFS='|' read -r ns pvc workload kind <<< "$row"
  dir=$(ls -d "$ROOT_DIR/${ns}-${pvc}-pvc-"* 2>/dev/null | head -1)
  [ -n "$dir" ] || die "no volume of ${ns}/${pvc} stands under $ROOT_DIR — there is nothing to put the backup into" 66
  want=$(replicas_of "$ns" "$workload" "$kind")
  [ -n "$want" ] || die "${ns}/${kind}/${workload} is not in the cluster, so nothing could stop the store before its volume is emptied" 66
  DIRS+=("$dir") WANTS+=("$want")
  say "${ns}/${kind}/${workload} runs with ${want} replica(s); its volume is $(basename "$dir")"
done

# store_refused WHAT: names the store the loop stands on and what stopped the restore there, where the two contents stand, and the
# two commands; the fetched backup and the replaced content stay where they are. Ends 70.
store_refused() {
  warn "${ns}/${kind}/${workload}: $1"
  warn "The restore stops here. What ${ns}/${pvc} held stands in ${held}, the fetched backup in ${FETCH}. To put the old content back:"
  say "  sudo sh -c 'microk8s kubectl -n ${ns} scale ${kind}/${workload} --replicas=0 && find ${dir} -mindepth 1 -delete && find ${held} -mindepth 1 -maxdepth 1 -exec mv -t ${dir} {} + && microk8s kubectl -n ${ns} scale ${kind}/${workload} --replicas=${want}'"
  say "To keep what the backup put there, and clear both folders:"
  say "  sudo rm -rf ${FETCH} ${KEPT}"
  die "the restore of ${ns}/${pvc} stopped; ${FETCH} and ${KEPT} stand on this machine" 70
}

step "the stores, each stopped and filled from the backup"
KEEP=1
root install -d -m 700 -o root -g root "$KEPT" || die "could not make $KEPT" 78
index=0
for row in "${STORES[@]}"; do
  IFS='|' read -r ns pvc workload kind <<< "$row"
  dir="${DIRS[$index]}" want="${WANTS[$index]}" held="$KEPT/${ns}--${pvc}"
  index=$(( index + 1 ))
  root install -d -m 700 -o root -g root "$held" || die "could not make $held" 78
  if ! stop_store "$ns" "$workload" "$kind"; then
    if start_store "$ns" "$workload" "$kind" "$want"; then back="it was asked to run with ${want} replica(s) again"; else back="it could not be started again and may stand at 0 replicas"; fi
    store_refused "was not stopped (its pods stood after ${STORE_WAIT_SECONDS} s, or the scale failed), so its volume was not touched; $back"
  fi
  say "${ns}/${workload} stopped"
  root find "$dir" -mindepth 1 -maxdepth 1 -exec mv -t "$held" {} + || store_refused "its volume could not be moved aside; it stands at 0 replicas"
  root bash -c 'set -o pipefail; gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$1" -d "$2" | tar --numeric-owner -C "$3" -xf -' _ "$PASSPHRASE_FILE" "$FETCH/${ns}--${pvc}.tar.gpg" "$dir" \
    || store_refused "its archive could not be opened into its volume; it stands at 0 replicas"
  good "${ns}/${pvc}: the volume held $(root du -sh "$held" | cut -f1), the backup put back $(root du -sh "$dir" | cut -f1)"
  start_store "$ns" "$workload" "$kind" "$want" || store_refused "could not be started again; it stands at 0 replicas"
  deadline=$(( SECONDS + STORE_WAIT_SECONDS ))
  while :; do
    ready=$(ready_of "$ns" "$workload" "$kind")
    ready=${ready:-0}
    [ "$ready" -ge "$want" ] 2>/dev/null && break
    [ "$SECONDS" -lt "$deadline" ] || store_refused "reads ${ready} ready replica(s) of the ${want} it had, after ${STORE_WAIT_SECONDS} s"
    sleep "$STORE_POLL_SECONDS"
  done
  good "${ns}/${kind}/${workload} reads ready: ${ready} of ${want}"
done

step "the replaced content and the fetched backup, removed"
root rm -rf "$KEPT" "$FETCH"
if root test -e "$KEPT" || root test -e "$FETCH"; then
  die "both stores read ready, but $KEPT or $FETCH could not be removed from this machine" 70
fi
good "both stores read ready; nothing of the restore is left on this machine"
printf 'RESTORED %s\n' "$ID"
