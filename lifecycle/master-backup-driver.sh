#!/usr/bin/env bash
# ===========================================================================
# master-backup-driver.sh — the backup of a master, ON THE MACHINE.
#
# Started by master-backup.sh / master-backup.ps1 over the one session they open, with the config
# ahead of it on the same standard input. Never started by hand.
#
# WHAT A MASTER IS THAT NOTHING ELSE HOLDS. The install branch, the registrations and the catalog
# stand on origin; the images are rebuilt by the release cycles; every certificate is issued again
# for the name. What lives on this machine alone is the platform's stores — Vault with every secret
# of every unit, the Manager's database, the IdP's accounts, Headscale's nodes, the master's own
# MongoDB, Redis, mail queue, registry and dbgate — and, beside them on the host, the file Vault's
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
# none of it. The passphrase reaches this machine on the session's standard input, is read into the
# environment and never lands in a file.
#
# WHERE IT GOES. box:master/<fqdn>/<id>/ on the storage box, through the same rclone remote the
# Manager's relocations use (hostyour-manager relocation-jobs.ts BOX_REMOTE), one directory per
# backup, named by the moment it was taken, with a manifest of checksums beside the archives. The
# last line this prints is that id, which is what master-restore asks for.
# ===========================================================================
set -uo pipefail

C_OFF=$'\033[0m' C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_BLD=$'\033[1m'
say()  { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
good() { printf '%s   ✓ %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '%s   ! %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
die()  { printf '%s   ✗ %s%s\n' "$C_RED" "$1" "$C_OFF" >&2; exit "${2:-1}"; }
step() { printf '\n%s══ %s%s\n' "$C_BLD" "$*" "$C_OFF"; }

readonly CONFIG="${1:?the config's path is this script's only argument}"
cleanup() { rm -f "$CONFIG" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

BAD=$(grep -nvE "^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*(#.*)?$" "$CONFIG" | head -3)
[ -z "$BAD" ] || die "the config carries lines that are neither a comment nor NAME='value', and this file is READ BY THE SHELL: $BAD" 65
. "$CONFIG"
for named in FQDN OPERATOR_USER STAGE ELEVATION_PASSWORD STORAGE_BOX_HOST STORAGE_BOX_USER STORAGE_BOX_PASSWORD BACKUP_PASSPHRASE; do
  [ -n "${!named:-}" ] || die "the config says nothing under ${named}, and nothing here may choose one" 64
done

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
  "registry|zot-data|registry-${STAGE}-app|deployment"
  "postfix|postfix-${STAGE}-postfix-${STAGE}-0|postfix-${STAGE}|statefulset"
  "dbgate|dbgate-data|dbgate-${STAGE}-app|deployment"
)
readonly QUORUM="/srv/hostyour-cloud/secrets/vault-${STAGE}.txt"
readonly STORAGE_ROOT=/var/snap/microk8s/common/default-storage

step "what this machine is, before anything is stopped"
say "asked as $(id -un) on $(hostname), for $FQDN, stage $STAGE"
printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' true 2>/dev/null || die 'the ELEVATION_PASSWORD in the config does not raise a command on this machine' 77
command -v microk8s >/dev/null 2>&1 || die 'microk8s is not on this machine, so there is no cluster whose stores could be taken' 69
K get nodes >/dev/null 2>&1 || die 'the cluster does not answer, and a store copied while it cannot be stopped is a store with a write in flight' 69
root test -r "$QUORUM" || die "$QUORUM is not on this host — a master keeps Vault's quorum there, and a backup without it could never be opened" 66
ROOT_DIR="$(readlink -f "$STORAGE_ROOT")"
[ -d "$ROOT_DIR" ] || die "$STORAGE_ROOT does not lead to a directory, so the stores' volumes cannot be found" 69
good "the stores' volumes stand under $ROOT_DIR"
for tool in tar gpg; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on this machine, and every archive is made with it" 69; done
if ! command -v rclone >/dev/null 2>&1; then
  say 'rclone is not on this machine; it is what carries the archives to the storage box, so it is installed now'
  root apt-get install -y -q rclone >/dev/null 2>&1 || die 'rclone could not be installed, and nothing else here reaches the storage box' 69
fi
export RCLONE_CONFIG_BOX_TYPE=sftp
export RCLONE_CONFIG_BOX_HOST="$STORAGE_BOX_HOST"
export RCLONE_CONFIG_BOX_USER="$STORAGE_BOX_USER"
RCLONE_CONFIG_BOX_PASS="$(rclone obscure "$STORAGE_BOX_PASSWORD")"; export RCLONE_CONFIG_BOX_PASS
rclone lsd box: >/dev/null 2>&1 || die "the storage box $STORAGE_BOX_HOST does not open to $STORAGE_BOX_USER — nothing was stopped" 69
good "the storage box $STORAGE_BOX_HOST opens"

ID="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="/var/lib/master-backup/$ID"
root install -d -m 700 -o root -g root /var/lib/master-backup "$WORK" || die "could not make $WORK" 78
seal() { # a file on stdin, sealed to $1 as root
  root env BACKUP_PASSPHRASE="$BACKUP_PASSPHRASE" sh -c 'exec gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 -o "$1" 3<<EOF
$BACKUP_PASSPHRASE
EOF
' _ "$1"
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
  if root tar --numeric-owner -C "$dir" -cf - . | seal "$out"; then
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
root cat "$QUORUM" | seal "$WORK/host--vault-${STAGE}.txt.gpg" || die "the quorum file could not be sealed" 70
good "vault-${STAGE}.txt taken — the quorum this backup is opened with"

step "the manifest, and the way out"
RELEASE=$(grep -E '^release:' "/srv/hostyour-cloud/clusters/active/${FQDN}.yaml" 2>/dev/null | head -1 | sed 's/^release:[[:space:]]*//' | tr -d '"'"'")
root sh -c "cd '$WORK' && { printf 'FQDN=%s\nSTAGE=%s\nID=%s\nRELEASE=%s\nSTORES=%s\n' '$FQDN' '$STAGE' '$ID' '$RELEASE' '$TAKEN'; sha256sum *.gpg; } > manifest.txt" || die 'the manifest could not be written' 70
say "release on this machine: ${RELEASE:-unknown}"
rclone copy "$WORK" "box:master/$FQDN/$ID/" --quiet || die "the archives could not be carried to box:master/$FQDN/$ID/ — they stand in $WORK on this machine" 69
LISTED=$(rclone lsf "box:master/$FQDN/$ID/" 2>/dev/null | wc -l | tr -d ' ')
EXPECTED=$(( TAKEN + 2 ))
[ "$LISTED" = "$EXPECTED" ] || die "the storage box lists $LISTED file(s) under master/$FQDN/$ID/ and $EXPECTED were sent" 69
root rm -rf "$WORK"
good "$LISTED file(s) stand under box:master/$FQDN/$ID/ — $TAKEN store(s), the quorum, the manifest; nothing of it is left on this machine"
printf 'BACKUP %s\n' "$ID"
