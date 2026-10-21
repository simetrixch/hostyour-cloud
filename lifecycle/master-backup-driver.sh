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
# it was — one store at a time, so the pause each one takes is its own. The Manager is the one that
# does not wait for its turn: it is stopped before the first store and started after the last one, for
# the reason below.
#
# THE MANAGER'S RUNS ARE HELD. A step of a run reads Vault, the Manager's database and the Git server,
# so a step that runs while one of them is stopped fails its run, and a failed run keeps its locks and
# holds every later run behind it. So before anything is stopped, the release queue is suspended: it is
# the one thing that starts a release or a publish run. This waits until the queue's last job has ended
# and no release or publish run runs, read twice in a row, for at most QUEUE_WAIT_SECONDS. Then it
# stops the Manager, which pauses its runs between two steps and goes on with them when it starts, and
# takes the stores. The Manager is started, and then the queue let go, only once every store this
# stopped reads ready. A step the Manager's stop cuts off runs again from its start. What this does not
# hold: a run in planning, which the Manager fails at every start of its own, this one included; a run
# of the Forgejo release flow, which lands in the namespace forgejo-build with neither queue label and
# is no step of a run of the Manager; and a run of this driver that is killed, which leaves the Manager
# at 0 and the queue suspended, beside the store it was copying.
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
# machine, so a run started from another computer is refused too. The first is named from the record its run
# wrote into the file, its id and its process id; that record stays after the run, and a lock held by hand writes
# none, so the refusal names a run only while its process still has the file open, and otherwise says that no
# run can be named.
#
# READ BACK BEFORE IT IS CALLED WHOLE. The count of names and the size check rclone makes while it copies
# look at no byte of what the box keeps. So the backup is copied back from the box into a folder of root's,
# and there its checksums are held to the manifest, the manifest's count of stores to the rows of STORES, the
# quorum archive is opened with the passphrase, to /dev/null (the opened quorum is written nowhere, and this
# machine's output and log hold no line of it), and the manifest itself is held to the one that was sent. That
# last check is what makes the first one whole: a checksum line that lost its form is skipped by the filter
# of the first, and so is the archive under it. The storage box answers rclone's md5sum command over its shell
# with a failure, or never, so the remote's hash check is off and what proves the bytes is the manifest's sha256.
# The rate of the copy back is measured, not assumed: for its first READBACK_WAIT_SECONDS the bytes rclone reports
# received are held against rclone's own elapsed time, the floor is that rate divided by READBACK_SLOWDOWN_FACTOR,
# and the rest of the copy is given the time the whole backup takes at the floor, counted from the end of that
# measurement and never moved again. A copy that moves no byte for READBACK_WAIT_SECONDS, or passes its allowance,
# is ended and this ends 69, saying how many bytes were read and at what rate. A rate below the floor that never
# stands still is ended by that allowance alone, so a very slow box is not waited on past it.
# THE STORAGE BOX IS NAMED "the storage box" AND NOTHING MORE in what this prints. rclone's own messages carry the
# account, so none of them reaches a stream: its errors are dropped and its statistics are read as three numbers.
# ===========================================================================
set -uo pipefail

C_OFF=$'\033[0m' C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_BLD=$'\033[1m'
say()  { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
good() { printf '%s   ✓ %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '%s   ! %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
die()  { printf '%s   ✗ %s%s\n' "$C_RED" "$1" "$C_OFF" >&2; exit "${2:-1}"; }
step() { printf '\n%s══ %s%s\n' "$C_BLD" "$*" "$C_OFF"; }

readonly CONFIG="${1:?the config's path is this script's only argument}"
# The queue that starts every release and publish run, and how long this waits on it and on a store, in seconds.
# QUEUE_WAIT_SECONDS is the pipelines' timeout of one hour (timeouts.pipeline of the release and the publish run,
# which no run outlives) and five minutes. Each stands on a line of its own because a test moves them. The read-back
# from the storage box measures its own rate for READBACK_WAIT_SECONDS, the connection, the listing and the box's
# latency among them, and ends a copy that moves no byte for as long. READBACK_POLL_SECONDS is how often it looks at
# rclone's statistics, READBACK_REPORT_SECONDS how often it prints them, READBACK_GRACE_SECONDS how long a copy asked
# to end has before it is killed, and READBACK_SLOWDOWN_FACTOR how many times slower than measured the box may get.
readonly QUEUE_NAMESPACE=image-builder
readonly QUEUE_CRONJOB=release-queue
readonly QUEUE_POLL_SECONDS=5
readonly QUEUE_WAIT_SECONDS=3900
readonly STORE_POLL_SECONDS=2
readonly STORE_WAIT_SECONDS=180
readonly READBACK_WAIT_SECONDS=300
readonly READBACK_POLL_SECONDS=5
readonly READBACK_REPORT_SECONDS=30
readonly READBACK_GRACE_SECONDS=30
readonly READBACK_SLOWDOWN_FACTOR=2
SECRETS=''
READBACK=''
HELD=''
TRANSFER_JOB='' TRANSFER_CODE=''
cleanup() {
  rm -f "$CONFIG" 2>/dev/null || true
  [ -z "$TRANSFER_JOB" ] || readback_end
  [ -z "$SECRETS" ] || rm -rf "$SECRETS" 2>/dev/null || true
  if [ -n "$READBACK" ]; then root rm -rf "$READBACK" >/dev/null 2>&1; fi
}
# What this run holds is let go on every way out that is not a signal, once; a signal keeps the handler it had.
leave() { local code=$?; [ -z "$HELD" ] || release_hold || true; cleanup; exit "$code"; }
trap leave EXIT
trap cleanup INT TERM

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
# The hash check of the remote is off for the carry and the copy back alike: the box answers rclone's md5sum command with a failure or never.
RCLONE_CONF="$SECRETS/rclone.conf"
( umask 077; printf '[box]\ntype = sftp\nhost = %s\nuser = %s\npass = %s\ndisable_hashcheck = true\n' "$STORAGE_BOX_HOST" "$STORAGE_BOX_USER" "$(printf '%s\n' "$STORAGE_BOX_PASSWORD" | rclone obscure -)" > "$RCLONE_CONF" ) \
  || die 'the storage box config could not be written to a file in memory' 78
export RCLONE_CONFIG="$RCLONE_CONF"
rclone lsd box: >/dev/null 2>&1 || die 'the storage box does not open — nothing was stopped' 69
good 'the storage box opens'

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
  HOLDER_ID='' HOLDER_PID=''
  read -r HOLDER_ID HOLDER_PID _ < "$LOCK_FILE" || true
  if [[ "$HOLDER_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ && "$HOLDER_PID" =~ ^[0-9]+$ ]] && [ "/proc/$HOLDER_PID/fd/9" -ef "$LOCK_FILE" ]; then
    die "another master backup holds the lock $LOCK_FILE: run $HOLDER_ID, started ${HOLDER_ID:0:4}-${HOLDER_ID:4:2}-${HOLDER_ID:6:2} ${HOLDER_ID:9:2}:${HOLDER_ID:11:2}:${HOLDER_ID:13:2} UTC. Nothing was stopped; start this again once it has ended" 75
  fi
  die "the lock $LOCK_FILE is held, and its record is empty or names a run that is not alive, so no run can be named. Nothing was stopped; start this again once the holder has ended" 75
elif [ "$LOCKED" != 0 ]; then
  die "the lock $LOCK_FILE could not be taken, flock ended $LOCKED — nothing was stopped" 78
fi

ID="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUPS="box:$FQDN/master"
WORK="/var/lib/master-backup/$ID"
root install -d -m 700 -o root -g root /var/lib/master-backup "$WORK" || die "could not make $WORK" 78
printf '%s %s\n' "$ID" "$$" > "$LOCK_FILE" || die "the run's id could not be written to $LOCK_FILE, where a second run reads it" 78
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
# A store reads ready by the workload's own count of ready pods, which the Deployment and StatefulSet controllers keep
# for every update strategy; kubectl's rollout status refuses a StatefulSet that is not a RollingUpdate, Vault's among them.
ready_of() { K -n "$1" get "$3/$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null; }
# stop_store NS WORKLOAD KIND: the workload is scaled to nothing and its pods are waited for until they are gone, or
# STORE_WAIT_SECONDS have passed. The stop of the Manager and the stop of every other store are this one function.
stop_store() {
  local deadline=$(( SECONDS + STORE_WAIT_SECONDS ))
  K -n "$1" scale "$3/$2" --replicas=0 >/dev/null || die "could not stop ${1}/${2}" 70
  while [ "$(K -n "$1" get pods -o name 2>/dev/null | grep -c "^pod/${2}")" != 0 ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep "$STORE_POLL_SECONDS"
  done
}
start_store() { K -n "$1" scale "$3/$2" --replicas="$4" >/dev/null; } # NS WORKLOAD KIND REPLICAS
# mark_started ROW: the store ROW (NS|WORKLOAD|KIND|REPLICAS) is started again, so it no longer stands among the stopped ones.
mark_started() {
  STOPPED=$(printf '%s\n' "$STOPPED" | grep -vxF -- "$1") || true
  printf '%s\n' "$STARTED" | grep -qxF -- "$1" || STARTED="${STARTED:+$STARTED$'\n'}$1"
}

# WHAT THE QUEUE STILL HAS. BUSY becomes one name per line of what works for the release queue: a Job the CronJob
# names active, a Job of the CronJob that has not finished (it carries neither condition Complete nor Failed), and a
# release or publish run that runs (its Succeeded condition is neither True nor False, and it is not waiting on the
# queue as PipelineRunPending). A Job is the CronJob's by its owner reference, which the CronJob controller sets.
# Ends 1 when a read fails, because no answer is not a quiet queue.
queue_busy() {
  local active jobs runs label one
  BUSY=''
  active=$(K -n "$QUEUE_NAMESPACE" get "cronjob/$QUEUE_CRONJOB" -o jsonpath='{range .status.active[*]}{.name}{"\n"}{end}') || return 1
  active=$(printf '%s\n' "$active" | awk -v ns="$QUEUE_NAMESPACE" 'NF > 0 { print "job " ns "/" $1 }')
  jobs=$(K -n "$QUEUE_NAMESPACE" get jobs -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .metadata.ownerReferences[*]}{.kind}/{.name}{" "}{end}{"|"}{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}{"\n"}{end}') || return 1
  jobs=$(printf '%s\n' "$jobs" | awk -F'|' -v ns="$QUEUE_NAMESPACE" -v owner="CronJob/$QUEUE_CRONJOB" '
    $1 != "" { mine = 0; finished = 0
      n = split($2, owners, " "); for (i = 1; i <= n; i++) if (owners[i] == owner) mine = 1
      n = split($3, conditions, " "); for (i = 1; i <= n; i++) if (conditions[i] == "Complete" || conditions[i] == "Failed") finished = 1
      if (mine && !finished) print "job " ns "/" $1 }')
  runs=''
  for label in image-builder.io/consumer image-builder.io/publish; do
    one=$(K get pipelineruns -A -l "$label" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"|"}{.spec.status}{"|"}{.status.conditions[?(@.type=="Succeeded")].status}{"\n"}{end}') || return 1
    runs="$runs"$'\n'"$(printf '%s\n' "$one" | awk -F'|' '$1 != "" && $3 != "True" && $3 != "False" && $2 != "PipelineRunPending" { print "run " $1 }')"
  done
  BUSY=$(printf '%s\n%s\n%s\n' "$active" "$jobs" "$runs" | grep . | sort -u) || true
}
# wait_for_queue: ends at the second pass in a row that finds the queue quiet, because a Job the CronJob creates from a
# read taken before the queue was held can land after one pass has looked. Each Job and run is named once, and a line is
# written a minute. Past QUEUE_WAIT_SECONDS it lets the queue go again, stops nothing and ends 75, naming what still runs.
wait_for_queue() {
  local quiet=0 deadline=$(( SECONDS + QUEUE_WAIT_SECONDS )) next_line=$(( SECONDS + 60 )) named='' name
  while :; do
    queue_busy || die "the release queue could not be read in ${QUEUE_NAMESPACE} or in the namespaces of the pipeline runs, and a queue that cannot be read is not a quiet one — nothing was stopped" 69
    if [ -z "$BUSY" ]; then
      quiet=$(( quiet + 1 ))
      [ "$quiet" -ge 2 ] && break
    else
      quiet=0
      while IFS= read -r name; do
        case "$named" in *"|$name|"*) ;; *) named="$named|$name|"; say "waiting for $name to end" ;; esac
      done <<< "$BUSY"
      if [ "$SECONDS" -ge "$deadline" ]; then
        release_hold
        die "after ${QUEUE_WAIT_SECONDS} s the queue still has: $(printf '%s' "$BUSY" | tr '\n' ';') — nothing was stopped, and the queue was let go again" 75
      fi
      if [ "$SECONDS" -ge "$next_line" ]; then
        say "still waiting for the queue: $(printf '%s' "$BUSY" | tr '\n' ';')"
        next_line=$(( SECONDS + 60 ))
      fi
    fi
    sleep "$QUEUE_POLL_SECONDS"
  done
}
# release_refused WHAT: what is wrong, and the commands that let the Manager and the queue go once the store is ready.
release_refused() {
  warn "$1"
  warn 'The Manager stays stopped and the queue suspended. Once the store is ready, start the Manager and let the queue go with:'
  say "  microk8s kubectl -n manager scale ${MANAGER_KIND}/${MANAGER_WORKLOAD} --replicas=${MANAGER_WAS}"
  say "  microk8s kubectl -n ${QUEUE_NAMESPACE} patch cronjob/${QUEUE_CRONJOB} --type=merge -p '{\"spec\":{\"suspend\":${QUEUE_WAS}}}'"
}
# release_hold: starts the Manager with the replicas it had and then lets the queue go, only when every store this run
# stopped reads the replicas it had and ready within STORE_WAIT_SECONDS. Otherwise it starts neither, says which
# store, and ends 1. It is called once: HELD is cleared first, so the way out does not run it again after a refusal.
# A store asked to stop is read from the cluster, not from the record: a scale to 0 that failed may have changed
# nothing, and a scale back that failed may have worked.
release_hold() {
  local row ns workload kind want got deadline names=''
  HELD=''
  for row in $STOPPED; do
    IFS='|' read -r ns workload kind want <<< "$row"
    got=$(replicas_of "$ns" "$workload" "$kind")
    if [ "$got" -ge "$want" ] 2>/dev/null; then
      mark_started "$row"
    elif [ -n "$got" ]; then
      names="${names}${names:+; }${ns}/${kind}/${workload} reads ${got} replica(s) of the ${want} it had"
    else
      names="${names}${names:+; }${ns}/${kind}/${workload} could not be read"
    fi
  done
  if [ -n "$names" ]; then
    release_refused "these stores were asked to stop and do not read the replicas they had: ${names}"
    return 1
  fi
  for row in $STARTED; do
    IFS='|' read -r ns workload kind want <<< "$row"
    deadline=$(( SECONDS + STORE_WAIT_SECONDS ))
    while :; do
      got=$(ready_of "$ns" "$workload" "$kind")
      got=${got:-0}
      [ "$got" -ge "$want" ] 2>/dev/null && break
      if [ "$SECONDS" -ge "$deadline" ]; then
        release_refused "${ns}/${kind}/${workload} reads ${got} ready replica(s) of the ${want} it had, after ${STORE_WAIT_SECONDS} s"
        return 1
      fi
      sleep "$STORE_POLL_SECONDS"
    done
    good "${ns}/${kind}/${workload} reads ready: ${got} of ${want}"
  done
  if [ -n "$MANAGER_STOPPED" ]; then
    if ! start_store manager "$MANAGER_WORKLOAD" "$MANAGER_KIND" "$MANAGER_WAS"; then
      release_refused "manager/${MANAGER_KIND}/${MANAGER_WORKLOAD} could not be started again"
      return 1
    fi
    good "manager/${MANAGER_KIND}/${MANAGER_WORKLOAD} started again with ${MANAGER_WAS} replica(s); its runs go on"
  fi
  if ! K -n "$QUEUE_NAMESPACE" patch "cronjob/$QUEUE_CRONJOB" --type=merge -p "{\"spec\":{\"suspend\":${QUEUE_WAS}}}" >/dev/null; then
    warn "the queue ${QUEUE_NAMESPACE}/${QUEUE_CRONJOB} could not be set back to suspend=${QUEUE_WAS}. Set it with:"
    say "  microk8s kubectl -n ${QUEUE_NAMESPACE} patch cronjob/${QUEUE_CRONJOB} --type=merge -p '{\"spec\":{\"suspend\":${QUEUE_WAS}}}'"
    return 1
  fi
  good "the queue ${QUEUE_NAMESPACE}/${QUEUE_CRONJOB} is let go (suspend=${QUEUE_WAS})"
}

step "the Manager's runs, held"
MANAGER_WORKLOAD='' MANAGER_KIND='' MANAGER_STOPPED='' STOPPED='' STARTED=''
for row in "${STORES[@]}"; do
  [ "${row%%|*}" = manager ] && IFS='|' read -r _ _ MANAGER_WORKLOAD MANAGER_KIND <<< "$row"
done
[ -n "$MANAGER_WORKLOAD" ] || die 'no row of STORES names the namespace manager, so there is no Manager whose runs could be held' 66
MANAGER_WAS=$(replicas_of manager "$MANAGER_WORKLOAD" "$MANAGER_KIND")
[ -n "$MANAGER_WAS" ] || die "manager/${MANAGER_KIND}/${MANAGER_WORKLOAD} is not in the cluster, so nothing could stop the Manager before its copy" 66
QUEUE_WAS=$(K -n "$QUEUE_NAMESPACE" get "cronjob/$QUEUE_CRONJOB" -o jsonpath='{.spec.suspend}' 2>/dev/null) \
  || die "the CronJob ${QUEUE_NAMESPACE}/${QUEUE_CRONJOB} is not in the cluster, and without it no release or publish run can be held — nothing was stopped" 66
[ "$QUEUE_WAS" = true ] || QUEUE_WAS=false
HELD=1
K -n "$QUEUE_NAMESPACE" patch "cronjob/$QUEUE_CRONJOB" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null || die "could not hold the queue ${QUEUE_NAMESPACE}/${QUEUE_CRONJOB}" 70
good "the queue ${QUEUE_NAMESPACE}/${QUEUE_CRONJOB} is held (it stood at suspend=${QUEUE_WAS}): no release or publish run starts until this has ended"
wait_for_queue
good 'no job of the queue and no release or publish run is running'
MANAGER_STOPPED=1
stop_store manager "$MANAGER_WORKLOAD" "$MANAGER_KIND"
good "manager/${MANAGER_KIND}/${MANAGER_WORKLOAD} stopped (it ran with ${MANAGER_WAS} replica(s)): its runs pause between two steps"

step "the stores, each stopped for its copy"
TAKEN=0
for row in "${STORES[@]}"; do
  IFS='|' read -r ns pvc workload kind <<< "$row"
  dir=$(ls -d "$ROOT_DIR/${ns}-${pvc}-pvc-"* 2>/dev/null | head -1)
  [ -n "$dir" ] || die "no volume of ${ns}/${pvc} stands under $ROOT_DIR — the store is not there, and a backup that skipped it would be taken for whole" 66
  stopped_row=''
  if [ "$ns" = manager ]; then
    before=$MANAGER_WAS
  else
    before=$(replicas_of "$ns" "$workload" "$kind")
    [ -n "$before" ] || die "${ns}/${kind}/${workload} is not in the cluster, so nothing could stop the store before its copy" 66
    stopped_row="${ns}|${workload}|${kind}|${before}"
    STOPPED="${STOPPED:+$STOPPED$'\n'}$stopped_row"
    stop_store "$ns" "$workload" "$kind"
  fi
  out="$WORK/${ns}--${pvc}.tar.gpg"
  if seal "$out" tar --numeric-owner -C "$dir" -cf - .; then
    good "${ns}/${pvc} taken from $(basename "$dir") — $(root du -sh "$out" | cut -f1)"
  else
    if [ -z "$stopped_row" ]; then
      die "the copy of ${ns}/${pvc} failed; ${workload} stays stopped until the rest is back" 70
    elif start_store "$ns" "$workload" "$kind" "$before"; then
      mark_started "$stopped_row"
      die "the copy of ${ns}/${pvc} failed; ${workload} was started again with $before replica(s)" 70
    fi
    die "the copy of ${ns}/${pvc} failed, and ${workload} could not be started again — it stands at 0 replicas, start it by hand" 70
  fi
  if [ -z "$stopped_row" ]; then
    say "${ns}/${workload} stays stopped until every other store is back"
  else
    start_store "$ns" "$workload" "$kind" "$before" || die "could not start ${ns}/${workload} again — it stands at 0 replicas, start it by hand" 70
    mark_started "$stopped_row"
    say "${ns}/${workload} started again with $before replica(s)"
  fi
  TAKEN=$(( TAKEN + 1 ))
done

step "the Manager and its queue, let go"
release_hold || die "the Manager and the queue were not let go; the archives stand in $WORK on this machine" 70

step "the host's own file"
seal "$WORK/host--vault-${STAGE}.txt.gpg" cat "$QUORUM" || die "the quorum file could not be sealed" 70
good "vault-${STAGE}.txt taken — the quorum this backup is opened with"

step "the manifest, and the way out"
RELEASE=$(grep -E '^release:' "/srv/hostyour-cloud/clusters/active/${FQDN}.yaml" 2>/dev/null | head -1 | sed 's/^release:[[:space:]]*//' | tr -d '"'"'")
root sh -c "cd '$WORK' && { printf 'FQDN=%s\nSTAGE=%s\nID=%s\nRELEASE=%s\nSTORES=%s\n' '$FQDN' '$STAGE' '$ID' '$RELEASE' '$TAKEN'; sha256sum *.gpg; } > manifest.txt" || die 'the manifest could not be written' 70
say "release on this machine: ${RELEASE:-unknown}"
root rclone --config "$RCLONE_CONF" copy "$WORK" "$BACKUPS/$ID/" --quiet 2>/dev/null || die "the archives could not be carried to $BACKUPS/$ID/ (rclone ended $?) — they stand in $WORK on this machine" 69
LISTING=$(root rclone --config "$RCLONE_CONF" lsf "$BACKUPS/$ID/" 2>/dev/null) || die "the storage box could not be listed under $BACKUPS/$ID/ (rclone ended $?) — the archives stand in $WORK on this machine" 69
LISTED=$(printf '%s\n' "$LISTING" | grep -c .)
EXPECTED=$(( TAKEN + 2 ))
[ "$LISTED" = "$EXPECTED" ] || die "the storage box lists $LISTED file(s) under $BACKUPS/$ID/ and $EXPECTED were sent" 69
# The folder is root's and cleanup removes it with root on every way out: a write after the ssh session has ended kills
# this shell before the next line runs, so no line after a write is where the removal can rest.
# The work folder stands after a refusal, because the archives are all there is.
READBACK="$WORK.readback"
root install -d -m 700 -o root -g root "$READBACK" || die "could not make $READBACK" 78
# What the files sent weigh, by rclone's own count of the files it sends (no directory among them): the total the read-back is measured against.
READBACK_EXPECTED=$(root rclone --config "$RCLONE_CONF" size "$WORK" --json 2>/dev/null | sed -n 's/^.*"bytes":\([0-9][0-9]*\).*$/\1/p')
case "$READBACK_EXPECTED" in
  ''|*[!0-9]*|0) die "the size of the files in $WORK could not be read, and the read-back is measured against it — the archives stand in $WORK on this machine" 69 ;;
esac

# rate_of BYTES MILLISECONDS: bytes a second to three places, and "unavailable" where no time has passed.
rate_of() {
  local milli
  [ "$2" -gt 0 ] || { printf unavailable; return 0; }
  milli=$(( $1 * 1000000 / $2 ))
  printf '%d.%03d' $(( milli / 1000 )) $(( milli % 1000 ))
}
seconds_of() { printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )); } # MILLISECONDS as seconds
# readback_allowance_seconds EXPECTED BYTES MILLISECONDS: the seconds the whole backup takes at the floor, which is the
# rate BYTES in MILLISECONDS divided by READBACK_SLOWDOWN_FACTOR, rounded up so that a positive rate never gives none.
readback_allowance_seconds() { printf '%d' $(( ($1 * READBACK_SLOWDOWN_FACTOR * $3 + $2 * 1000 - 1) / ($2 * 1000) )); }
# readback_sample: the newest statistics line the transfer wrote, as "BYTES MILLISECONDS" in digits and nothing else;
# nothing when no line holds both. rclone's other messages stay in the file, which is not printed and is gone at the end.
readback_sample() {
  grep -a '"stats":{"bytes":' "$READBACK_STATS" 2>/dev/null | tail -n 1 | awk '
    !match($0, /"stats":\{"bytes":[0-9]+,/) { next }
    { bytes = substr($0, RSTART + 17, RLENGTH - 18) }
    !match($0, /"elapsedTime":[0-9]+(\.[0-9]+)?,/) { next }
    { split(substr($0, RSTART + 14, RLENGTH - 15), part, ".")
      millis = part[1] substr(part[2] "000", 1, 3)
      if (length(bytes) <= 12 && length(millis) <= 8) print bytes, millis }'
}
readback_read() { # the newest sample into SAMPLE_BYTES and SAMPLE_MILLIS; ends 1 when there is none
  local sample
  sample=$(readback_sample)
  [ -n "$sample" ] || return 1
  read -r SAMPLE_BYTES SAMPLE_MILLIS <<< "$sample"
  SAMPLE_BYTES=$(( 10#$SAMPLE_BYTES )) SAMPLE_MILLIS=$(( 10#$SAMPLE_MILLIS ))
}
readback_state() { # what the transfer had read, in the words of every failure and of the last line
  if readback_read; then
    printf 'read %s of %s expected bytes in %s s, %s bytes a second' "$SAMPLE_BYTES" "$READBACK_EXPECTED" "$(seconds_of "$SAMPLE_MILLIS")" "$(rate_of "$SAMPLE_BYTES" "$SAMPLE_MILLIS")"
  else
    printf 'no statistics were read of %s expected bytes' "$READBACK_EXPECTED"
  fi
  [ -z "$TRANSFER_CODE" ] || printf ', transfer exit status %s' "$TRANSFER_CODE"
}
# The transfer is root's, so root ends it: the pid it wrote is asked to end, and killed once READBACK_GRACE_SECONDS have passed.
readback_end() {
  local pid limit
  [ -n "$TRANSFER_JOB" ] || return 0
  if kill -0 "$TRANSFER_JOB" 2>/dev/null; then
    pid=$(cat "$READBACK_PID" 2>/dev/null) || pid=''
    case "$pid" in *[!0-9]*) pid='' ;; esac
    [ -z "$pid" ] || root kill -TERM "$pid" >/dev/null 2>&1
    limit=$(( SECONDS + READBACK_GRACE_SECONDS ))
    while kill -0 "$TRANSFER_JOB" 2>/dev/null && [ "$SECONDS" -lt "$limit" ]; do sleep 0.1; done
    if kill -0 "$TRANSFER_JOB" 2>/dev/null && [ -n "$pid" ]; then root kill -KILL "$pid" >/dev/null 2>&1; fi
  fi
  wait "$TRANSFER_JOB"; TRANSFER_CODE=$?
  TRANSFER_JOB=''
}
readback_fail() { # WHAT HAPPENED — the transfer is ended and reaped, then this ends 69 naming it and what was read
  readback_end
  die "the read-back of $BACKUPS/$ID/ $1: $(readback_state); the archives stand in $WORK on this machine" 69
}
# readback_follow: the transfer runs in the background with its statistics in a file that only this reads. The first
# READBACK_WAIT_SECONDS measure the rate; a transfer that moves no byte for that long is ended, and so is one that passes
# the allowance the measured rate gives it, which is fixed at the end of the measurement. Ends 0 when the transfer ended
# 0 and left a statistics line; otherwise it ends the run.
readback_follow() {
  local started=$SECONDS progress=$SECONDS next_report now seen='' last=0 frozen='' deadline=0
  next_report=$(( SECONDS + READBACK_REPORT_SECONDS ))
  while kill -0 "$TRANSFER_JOB" 2>/dev/null; do
    sleep "$READBACK_POLL_SECONDS"
    now=$SECONDS
    if readback_read; then
      seen=1
      if [ "$SAMPLE_BYTES" -gt "$last" ]; then last=$SAMPLE_BYTES progress=$now; fi
    fi
    if [ -z "$seen" ] && [ $(( now - started )) -ge "$READBACK_WAIT_SECONDS" ]; then
      readback_fail "gave no statistics within $READBACK_WAIT_SECONDS s, so its rate could not be measured"
    fi
    if [ -n "$seen" ] && [ $(( now - progress )) -ge "$READBACK_WAIT_SECONDS" ]; then
      readback_fail "moved no byte for $READBACK_WAIT_SECONDS s and was ended"
    fi
    if [ -z "$frozen" ] && [ $(( now - started )) -ge "$READBACK_WAIT_SECONDS" ]; then
      if [ "$SAMPLE_BYTES" -le 0 ] || [ "$SAMPLE_MILLIS" -le 0 ] || [ "${#READBACK_EXPECTED}" -gt 11 ] || [ "${#SAMPLE_MILLIS}" -gt 7 ]; then
        readback_fail "gave statistics that cannot be measured and was ended"
      fi
      READBACK_LEAST_BYTES_PER_SECOND=$(rate_of "$SAMPLE_BYTES" $(( SAMPLE_MILLIS * READBACK_SLOWDOWN_FACTOR )))
      READBACK_ALLOWED_SECONDS=$(readback_allowance_seconds "$READBACK_EXPECTED" "$SAMPLE_BYTES" "$SAMPLE_MILLIS")
      deadline=$(( now + READBACK_ALLOWED_SECONDS )) frozen=1
      say "measured $SAMPLE_BYTES bytes in $(seconds_of "$SAMPLE_MILLIS") s, $(rate_of "$SAMPLE_BYTES" "$SAMPLE_MILLIS") bytes a second; policy: a floor of 1/$READBACK_SLOWDOWN_FACTOR of it, $READBACK_LEAST_BYTES_PER_SECOND bytes a second; the $READBACK_EXPECTED bytes are given $READBACK_ALLOWED_SECONDS s more (backup $ID)"
    fi
    if [ -n "$frozen" ] && [ "$now" -ge "$deadline" ]; then
      readback_fail "did not finish within the $READBACK_ALLOWED_SECONDS s its measured rate allows and was ended"
    fi
    if [ "$now" -ge "$next_report" ]; then
      next_report=$(( now + READBACK_REPORT_SECONDS ))
      if [ -n "$seen" ]; then
        say "read back $SAMPLE_BYTES of $READBACK_EXPECTED bytes in $(seconds_of "$SAMPLE_MILLIS") s, $(rate_of "$SAMPLE_BYTES" "$SAMPLE_MILLIS") bytes a second (backup $ID)"
      else
        say "read back: no statistics yet (backup $ID)"
      fi
    fi
  done
  wait "$TRANSFER_JOB"; TRANSFER_CODE=$?
  TRANSFER_JOB=''
  [ "$TRANSFER_CODE" = 0 ] || die "the archives could not be read back from $BACKUPS/$ID/: $(readback_state); they stand in $WORK on this machine" 69
  readback_read || die "the read-back of $BACKUPS/$ID/ ended without a statistics line, so what it read could not be counted; the archives stand in $WORK on this machine" 69
}
READBACK_STATS="$SECRETS/readback.stats" READBACK_PID="$SECRETS/readback.pid"
( umask 077; : > "$READBACK_STATS"; : > "$READBACK_PID" ) || die 'the files for the read-back could not be made in memory' 78
say "reading back $READBACK_EXPECTED bytes from $BACKUPS/$ID/; the first $READBACK_WAIT_SECONDS s measure the rate, and a copy that moves no byte for $READBACK_WAIT_SECONDS s is ended"
root bash -c 'echo "$$" > "$1"; shift; exec "$@"' _ "$READBACK_PID" \
  rclone --config "$RCLONE_CONF" copy "$BACKUPS/$ID/" "$READBACK" --use-json-log --stats "${READBACK_POLL_SECONDS}s" --stats-log-level NOTICE 2> "$READBACK_STATS" &
TRANSFER_JOB=$!
for _ in $(seq 1 100); do [ -s "$READBACK_PID" ] && break; kill -0 "$TRANSFER_JOB" 2>/dev/null || break; sleep 0.1; done
readback_follow
good "read back $SAMPLE_BYTES of $READBACK_EXPECTED expected bytes in $(seconds_of "$SAMPLE_MILLIS") s, $(rate_of "$SAMPLE_BYTES" "$SAMPLE_MILLIS") bytes a second (backup $ID)"
READBACK_CODE=0
root sh -c 'cd "$1" || exit 10
grep -E "^[0-9a-f]{64}  " manifest.txt | sha256sum -c --quiet || exit 11
grep -qx "STORES=$2" manifest.txt || exit 12
gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$3" -o /dev/null -d "host--vault-$4.txt.gpg" || exit 13
cmp -s manifest.txt "$5" || exit 14' _ "$READBACK" "${#STORES[@]}" "$PASSPHRASE_FILE" "$STAGE" "$WORK/manifest.txt" || READBACK_CODE=$?
if [ "$READBACK_CODE" != 0 ]; then
  case "$READBACK_CODE" in
    11) die "the archives read back from $BACKUPS/$ID/ do not match the checksums of their manifest — what the storage box keeps is not what was sent; the archives stand in $WORK on this machine" 69 ;;
    12) die "the manifest read back from $BACKUPS/$ID/ counts other stores than the ${#STORES[@]} rows of this backup — the archives stand in $WORK on this machine" 69 ;;
    13) die "the quorum archive read back from $BACKUPS/$ID/ does not open with the BACKUP_PASSPHRASE of the config, and a backup that cannot open its quorum could never be restored — the archives stand in $WORK on this machine" 69 ;;
    14) die "the manifest read back from $BACKUPS/$ID/ is not the manifest that was sent — a checksum line that lost its form on the box is a line no archive is held to; the archives stand in $WORK on this machine" 69 ;;
    *) die "the read-back of $BACKUPS/$ID/ could not be run, it ended with $READBACK_CODE — the archives stand in $WORK on this machine" 69 ;;
  esac
fi
good "read back from $BACKUPS/$ID/: the checksums hold, the manifest counts the ${#STORES[@]} stores, the quorum opens, the manifest is the one sent"
root rm -rf "$WORK" "$READBACK"
if root test -e "$WORK" || root test -e "$READBACK"; then
  die "the backup stands whole on the storage box, but $WORK or $READBACK could not be removed from this machine" 70
fi
good "$LISTED file(s) stand under $BACKUPS/$ID/ — $TAKEN store(s), the quorum, the manifest; nothing of it is left on this machine"
printf 'BACKUP %s\n' "$ID"
