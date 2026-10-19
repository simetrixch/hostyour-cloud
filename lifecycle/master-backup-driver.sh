#!/usr/bin/env bash
# ===========================================================================
# master-backup-driver.sh — the backup of a master, ON THE MACHINE.
#
# Started by master-backup.sh over the one session it opens, with the config
# ahead of it on the same standard input. Never started by hand.
#
# WHAT A MASTER IS THAT NOTHING ELSE HOLDS. The install branch, the registrations and the deploy repository
# stand on origin; the images are rebuilt by the release cycles; every certificate is issued again
# for the name. What lives on this machine alone is the platform's stores — Vault with every secret
# of every unit, the Manager's database, the IdP's accounts, Headscale's nodes, the master's own
# MongoDB, Redis, mail queue, dbgate and Forgejo's Git repositories — and, beside them on the host, the file Vault's
# quorum is written to once and kept nowhere else: secrets/vault-<stage>.txt. That is the set this
# takes, and nothing beside it: the observability volumes and the build workspaces are left, because
# they are measurements and scratch, and the next installation makes its own.
#
# EACH STORE IS STOPPED FOR ITS COPY. A volume copied under a running database is a volume with a
# write in flight, and a restore that starts on one is a restore that may not start at all. So the
# workload is scaled to nothing, its directory is taken whole, and the workload is scaled back to what
# it was — one store at a time, so the pause each one takes is its own. The Manager is among them:
# a run in flight when this starts is a run this interrupts, so this is started at a quiet hour.
#
# SEALED BEFORE IT LEAVES. Every archive is passed through gpg with the config's BACKUP_PASSPHRASE
# before it is written, so the storage box holds the installation's every credential and can open
# none of it. The passphrase and the storage box's password reach this machine on the session's
# standard input, and gpg and rclone are given them by the path of a file of mode 600 in a folder in
# memory (/dev/shm) that is removed when this ends. Never as an argument: sudo writes the arguments of
# every command it runs to the system log.
#
# WHERE IT GOES. box:<fqdn>/master/<id>/ on the storage box. Everything of one installation lives
# under its FQDN: the unit backups the Manager writes stand beside this, under box:<fqdn>/<stage>/.
# It goes through the same rclone remote the Manager's relocations use (hostyour-manager
# relocation-jobs.ts BOX_REMOTE), one directory per backup, named by the moment it was taken, with a
# manifest of checksums beside the archives. Root made the archives in a folder that is root's alone,
# so root carries them, and root lists the box back on the same config: rclone saves what it learns of
# the box into the config it loaded, so after root's copy that file is root's and the operator cannot
# load it. The last line this prints is that id, which is what master-restore asks for.
#
# ONE BACKUP AT A TIME ON A MACHINE. A second run would read a store's replicas while the first holds that
# store at 0 and start it again with 0, and would copy a store the first has started again. So a run takes a
# lock before it makes or stops anything, and a second run is refused with exit 75, naming the first. The lock
# is flock on a file in /run/lock, which every account may write: /var/lib/master-backup is root's alone, and
# the operator, who runs this, can hold no lock in it. It belongs to this process, so it is gone when the
# process is, however it ends, and a run that died leaves nothing that blocks the next. It sits on the
# machine, so a run started from another computer is refused too.
#
# READ BACK BEFORE IT IS CALLED WHOLE. The count of names and the size check rclone makes while it copies
# look at no byte of what the box keeps. So the backup is copied back from the box into a folder of root's,
# and there its checksums are held to the manifest, the manifest's count of stores to the rows of STORES, and
# the quorum archive is opened with the passphrase, to /dev/null: the opened quorum is written nowhere, and
# this machine's output and log hold no line of it.
# ===========================================================================
set -uo pipefail

C_OFF=$'\033[0m' C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_BLD=$'\033[1m'
say()  { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
good() { printf '%s   ✓ %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '%s   ! %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
die()  { printf '%s   ✗ %s%s\n' "$C_RED" "$1" "$C_OFF" >&2; exit "${2:-1}"; }
step() { printf '\n%s══ %s%s\n' "$C_BLD" "$*" "$C_OFF"; }

readonly CONFIG="${1:?the config's path is this script's only argument}"
SECRETS=''
cleanup() { rm -f "$CONFIG" 2>/dev/null || true; [ -z "$SECRETS" ] || rm -rf "$SECRETS" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

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

# A SECRET AN ELEVATED COMMAND NEEDS IS A FILE, never an argument: sudo writes every command it runs, with
# its arguments, to the system log, and any local account reads an argument in the process list. This
# shell's own printf is no process, so it writes the secret to a file of mode 600 in a folder in memory
# that cleanup removes, and the elevated command is given the file's path.
SECRETS="$(mktemp -d /dev/shm/aw-backup.XXXXXX)" || die 'no folder in memory could be made for the secrets an elevated command needs, and none of them may stand on its command line' 78
PASSPHRASE_FILE="$SECRETS/passphrase"
( umask 077; printf '%s' "$BACKUP_PASSPHRASE" > "$PASSPHRASE_FILE" ) || die 'the passphrase could not be written to a file in memory' 78
root() { printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' "$@"; }
K() { microk8s kubectl "$@"; }

# THE STORES, ONE ROW EACH: namespace | claim | the workload stopped for the copy | its kind. The
# names are the platform's own (clusters/inventories/<app>), stage-suffixed where the chart suffixes
# them. master-restore-driver.sh carries the SAME rows with each claim's size beside it, and
# lifecycle/test.sh holds the two lists against each other, so a store added here is added there.
STORES=(
  "vault|data-vault-0|vault|statefulset"
  "manager|manager-data|manager|deployment"
  "headscale|headscale-data|headscale-${STAGE}-app|deployment"
  "idp|data-idp-postgresql-0|idp-postgresql|statefulset"
  "mongodb|data-mongodb-${STAGE}-0|mongodb-${STAGE}|statefulset"
  "mongodb|data-mongodb-${STAGE}-1|mongodb-${STAGE}|statefulset"
  "mongodb|data-mongodb-${STAGE}-2|mongodb-${STAGE}|statefulset"
  "redis|redis-data|redis-${STAGE}|deployment"
  "postfix|postfix-${STAGE}-postfix-${STAGE}-0|postfix-${STAGE}|statefulset"
  "dbgate|dbgate-data|dbgate-${STAGE}-app|deployment"
  "forgejo|gitea-shared-storage|forgejo|deployment"
)
readonly QUORUM="/srv/hostyour-cloud/secrets/vault-${STAGE}.txt"
# THE QUORUM IS THE OPERATOR'S OWN FILE, and this runs as the operator: it is checked as that account,
# as the unseal service reads it, never through root. An elevated test -r is no check of it: where the
# OS's test is uutils, it judges root by the mode bits and answers no for a 0600 file root does not
# own, which would be reported here as a file that is not on the host.
require_quorum() {
  [ -f "$QUORUM" ] || die "$QUORUM is not on this host — a master keeps Vault's quorum there, and a backup without it could never be opened" 66
  [ -r "$QUORUM" ] || die "$QUORUM stands on this host, but $(id -un), who runs this backup, cannot read it — a master keeps Vault's quorum as the operator's own file at mode 600" 66
}
readonly STORAGE_ROOT=/var/snap/microk8s/common/default-storage

step "what this machine is, before anything is stopped"
say "asked as $(id -un) on $(hostname), for $FQDN, stage $STAGE"
printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' true 2>/dev/null || die 'the ELEVATION_PASSWORD in the config does not raise a command on this machine' 77
command -v microk8s >/dev/null 2>&1 || die 'microk8s is not on this machine, so there is no cluster whose stores could be taken' 69
K get nodes >/dev/null 2>&1 || die 'the cluster does not answer, and a store copied while it cannot be stopped is a store with a write in flight' 69
require_quorum
ROOT_DIR="$(readlink -f "$STORAGE_ROOT")"
[ -d "$ROOT_DIR" ] || die "$STORAGE_ROOT does not lead to a directory, so the stores' volumes cannot be found" 69
good "the stores' volumes stand under $ROOT_DIR"
for tool in tar gpg; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on this machine, and every archive is made with it" 69; done
if ! command -v rclone >/dev/null 2>&1; then
  say 'rclone is not on this machine; it is what carries the archives to the storage box, so it is installed now'
  root apt-get install -y -q rclone >/dev/null 2>&1 || die 'rclone could not be installed, and nothing else here reaches the storage box' 69
fi
RCLONE_CONF="$SECRETS/rclone.conf"
( umask 077; printf '[box]\ntype = sftp\nhost = %s\nuser = %s\npass = %s\n' "$STORAGE_BOX_HOST" "$STORAGE_BOX_USER" "$(printf '%s\n' "$STORAGE_BOX_PASSWORD" | rclone obscure -)" > "$RCLONE_CONF" ) \
  || die 'the storage box config could not be written to a file in memory' 78
export RCLONE_CONFIG="$RCLONE_CONF"
rclone lsd box: >/dev/null 2>&1 || die "the storage box $STORAGE_BOX_HOST does not open to $STORAGE_BOX_USER — nothing was stopped" 69
good "the storage box $STORAGE_BOX_HOST opens"

# The file is opened with <> and never with >, which would wipe the record of the run that holds it before the
# lock is tried. flock ends 75 on a lock another process holds, and any other code is its own failure.
LOCK_FILE=/run/lock/master-backup.lock
command -v flock >/dev/null 2>&1 || die 'flock is not on this machine, and the lock that keeps a second backup out is taken with it' 69
exec 9<>"$LOCK_FILE" || die "the lock file $LOCK_FILE could not be opened — nothing was stopped" 78
LOCKED=0
flock -n -E 75 9 || LOCKED=$?
if [ "$LOCKED" = 75 ]; then
  HOLDER="$(head -n 1 "$LOCK_FILE" 2>/dev/null || true)"
  case "$HOLDER" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
      die "another master backup holds the lock $LOCK_FILE: run $HOLDER, started ${HOLDER:0:4}-${HOLDER:4:2}-${HOLDER:6:2} ${HOLDER:9:2}:${HOLDER:11:2}:${HOLDER:13:2} UTC. Nothing was stopped; start this again once it has ended" 75 ;;
    *)
      die "another master backup holds the lock $LOCK_FILE, and its record is empty or holds no run id, so it names no run. Nothing was stopped; start this again once it has ended" 75 ;;
  esac
elif [ "$LOCKED" != 0 ]; then
  die "the lock $LOCK_FILE could not be taken, flock ended $LOCKED — nothing was stopped" 78
fi
: > "$LOCK_FILE" || die "the record of an earlier run could not be emptied in $LOCK_FILE" 78

ID="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUPS="box:$FQDN/master"
WORK="/var/lib/master-backup/$ID"
root install -d -m 700 -o root -g root /var/lib/master-backup "$WORK" || die "could not make $WORK" 78
printf '%s\n' "$ID" > "$LOCK_FILE" || die "the run's id could not be written to $LOCK_FILE, where a second run reads it" 78
# seal OUT COMMAND...: what COMMAND writes, sealed to OUT. Both run as root inside one bash, because
# root() hands sudo the password on standard input: nothing piped or redirected into a command it
# starts reaches it, and under a NOPASSWD rule the command reads the password line as its data.
# pipefail makes a COMMAND that fails fail the seal, so the copy is not taken for whole. gpg reads the
# passphrase from its file by path.
seal() {
  root bash -c 'set -o pipefail
passfile=$1; out=$2; shift 2
"$@" | gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$passfile" --symmetric --cipher-algo AES256 -o "$out"
' _ "$PASSPHRASE_FILE" "$@"
}
replicas_of() { K -n "$1" get "$3/$2" -o jsonpath='{.spec.replicas}' 2>/dev/null; }

step "the stores, each stopped for its copy"
TAKEN=0
for row in "${STORES[@]}"; do
  IFS='|' read -r ns pvc workload kind <<< "$row"
  dir=$(ls -d "$ROOT_DIR/${ns}-${pvc}-pvc-"* 2>/dev/null | head -1)
  [ -n "$dir" ] || die "no volume of ${ns}/${pvc} stands under $ROOT_DIR — the store is not there, and a backup that skipped it would be taken for whole" 66
  before=$(replicas_of "$ns" "$workload" "$kind")
  [ -n "$before" ] || die "${ns}/${kind}/${workload} is not in the cluster, so nothing could stop the store before its copy" 66
  K -n "$ns" scale "$kind/$workload" --replicas=0 >/dev/null || die "could not stop ${ns}/${workload}" 70
  K -n "$ns" rollout status "$kind/$workload" --timeout=180s >/dev/null 2>&1 || true
  for i in $(seq 1 90); do
    [ "$(K -n "$ns" get pods -o name 2>/dev/null | grep -c "^pod/${workload}")" = 0 ] && break
    sleep 2
  done
  out="$WORK/${ns}--${pvc}.tar.gpg"
  if seal "$out" tar --numeric-owner -C "$dir" -cf - .; then
    good "${ns}/${pvc} taken from $(basename "$dir") — $(root du -sh "$out" | cut -f1)"
  else
    K -n "$ns" scale "$kind/$workload" --replicas="$before" >/dev/null
    die "the copy of ${ns}/${pvc} failed; ${workload} was started again with $before replica(s)" 70
  fi
  K -n "$ns" scale "$kind/$workload" --replicas="$before" >/dev/null || die "could not start ${ns}/${workload} again — it stands at 0 replicas, start it by hand" 70
  say "${ns}/${workload} started again with $before replica(s)"
  TAKEN=$(( TAKEN + 1 ))
done

step "the host's own file"
seal "$WORK/host--vault-${STAGE}.txt.gpg" cat "$QUORUM" || die "the quorum file could not be sealed" 70
good "vault-${STAGE}.txt taken — the quorum this backup is opened with"

step "the manifest, and the way out"
RELEASE=$(grep -E '^release:' "/srv/hostyour-cloud/clusters/active/${FQDN}.yaml" 2>/dev/null | head -1 | sed 's/^release:[[:space:]]*//' | tr -d '"'"'")
root sh -c "cd '$WORK' && { printf 'FQDN=%s\nSTAGE=%s\nID=%s\nRELEASE=%s\nSTORES=%s\n' '$FQDN' '$STAGE' '$ID' '$RELEASE' '$TAKEN'; sha256sum *.gpg; } > manifest.txt" || die 'the manifest could not be written' 70
say "release on this machine: ${RELEASE:-unknown}"
root rclone --config "$RCLONE_CONF" copy "$WORK" "$BACKUPS/$ID/" --quiet || die "the archives could not be carried to $BACKUPS/$ID/ — they stand in $WORK on this machine" 69
LISTING=$(root rclone --config "$RCLONE_CONF" lsf "$BACKUPS/$ID/") || die "the storage box could not be listed under $BACKUPS/$ID/ — the archives stand in $WORK on this machine" 69
LISTED=$(printf '%s\n' "$LISTING" | grep -c .)
EXPECTED=$(( TAKEN + 2 ))
[ "$LISTED" = "$EXPECTED" ] || die "the storage box lists $LISTED file(s) under $BACKUPS/$ID/ and $EXPECTED were sent" 69
# The folder is root's, so cleanup, which runs as the operator, cannot remove it: every way out of this step
# removes it with root. The work folder stands after a refusal, because the archives are all there is.
READBACK="$WORK.readback"
root install -d -m 700 -o root -g root "$READBACK" || die "could not make $READBACK" 78
root rclone --config "$RCLONE_CONF" copy "$BACKUPS/$ID/" "$READBACK" --quiet || { root rm -rf "$READBACK"; die "the archives could not be read back from $BACKUPS/$ID/ — they stand in $WORK on this machine" 69; }
READBACK_CODE=0
root sh -c 'cd "$1" || exit 10
grep -E "^[0-9a-f]{64}  " manifest.txt | sha256sum -c --quiet || exit 11
grep -qx "STORES=$2" manifest.txt || exit 12
gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$3" -o /dev/null -d "host--vault-$4.txt.gpg" || exit 13' _ "$READBACK" "${#STORES[@]}" "$PASSPHRASE_FILE" "$STAGE" || READBACK_CODE=$?
if [ "$READBACK_CODE" != 0 ]; then
  root rm -rf "$READBACK"
  case "$READBACK_CODE" in
    11) die "the archives read back from $BACKUPS/$ID/ do not match the checksums of their manifest — what the storage box keeps is not what was sent; the archives stand in $WORK on this machine" 69 ;;
    12) die "the manifest read back from $BACKUPS/$ID/ counts other stores than the ${#STORES[@]} rows of this backup — the archives stand in $WORK on this machine" 69 ;;
    13) die "the quorum archive read back from $BACKUPS/$ID/ does not open with the BACKUP_PASSPHRASE of the config, and a backup that cannot open its quorum could never be restored — the archives stand in $WORK on this machine" 69 ;;
    *) die "the read-back of $BACKUPS/$ID/ could not be run, it ended with $READBACK_CODE — the archives stand in $WORK on this machine" 69 ;;
  esac
fi
good "read back from $BACKUPS/$ID/: the checksums hold, the manifest counts the ${#STORES[@]} stores, the quorum opens"
root rm -rf "$WORK" "$READBACK"
good "$LISTED file(s) stand under $BACKUPS/$ID/ — $TAKEN store(s), the quorum, the manifest; nothing of it is left on this machine"
printf 'BACKUP %s\n' "$ID"
