#!/usr/bin/env bash
# ===========================================================================
# master-restore-driver.sh — stages a master's backup on a bare machine, ON THE MACHINE.
#
# Started by master-restore.sh over the one session it opens, with the config
# ahead of it on the same standard input and the backup's id as its second argument. Never started
# by hand.
#
# A RESTORE IS AN INSTALLATION THAT FINDS ITS STORES STANDING, and this is what makes them stand.
# It does two things, and the launcher that follows does the rest:
#
#   1. THE CHECKOUT AND THE QUORUM, before install-machine runs at all. The installation's branch
#      stands on origin under its name, and driver.sh refuses a machine that carries no checkout
#      beside a branch that exists — rightly, because deploy-branch would cut a second branch and
#      its push would be refused at the last step. So the platform tree is cloned to
#      /srv/hostyour-cloud the way deploy-host clones it, owned by the operator, with the
#      installation's branch fetched into it as a local branch: the driver then finds a checkout that
#      holds the published tip and stands the checkout on it. Beside it, secrets/vault-<stage>.txt is
#      put back, so deploy-platform-services finds Vault initialized AND its quorum on this host,
#      which is the branch of vault_init that touches nothing, and unseals with the keys in the file.
#
#   2. THE STORES, STAGED FOR THE MOMENT THE CLUSTER STANDS. A volume's directory is named after
#      the claim's uid, which exists only once the claim is created — so the data cannot be placed
#      now. It is opened here, into a root-only staging directory, together with a script that
#      driver.sh runs right after deploy-cluster and before deploy-platform-services: for every
#      store it places the directory and a PersistentVolume with a claimRef, so the claim that
#      program creates binds to the volume already holding the store instead of being provisioned
#      empty. The mark /var/lib/master-restore/pending is what tells the driver to do that.
#
# THE RCLONE IS THE PINNED ONE. The rclone that Ubuntu packages leaves a multi-thread copy from the storage box open after
# its last byte, so the machine is given the release the platform pins (require-rclone.sh, sent ahead of this driver) before
# the box is opened; master-restore.sh says where its package comes from.
#
# WHAT IS MEASURED FIRST. A mark already standing is refused (a restore is staged once); a machine
# already carrying the platform's claims is refused (a restore comes before the services, and an
# installation that already stands is not this act's to overwrite); a backup whose checksums do not
# hold is refused before a byte of it is placed.
#
# GIVEN NO ID, it lists the backups the storage box holds for this installation and stops: the id
# is the one thing here a person chooses, and the list is how they choose it.
# ===========================================================================
set -uo pipefail

C_OFF=$'\033[0m' C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_BLD=$'\033[1m'
say()  { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
good() { printf '%s   ✓ %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
warn() { printf '%s   ! %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
die()  { printf '%s   ✗ %s%s\n' "$C_RED" "$1" "$C_OFF" >&2; exit "${2:-1}"; }
step() { printf '\n%s══ %s%s\n' "$C_BLD" "$*" "$C_OFF"; }

readonly CONFIG="${1:?the config's path is this script's first argument}"
ID="${2:-}"
SECRETS=''
cleanup() { rm -f "$CONFIG" 2>/dev/null || true; [ -z "$SECRETS" ] || rm -rf "$SECRETS" 2>/dev/null || true; rclone_cleanup; }
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
for named in FQDN OPERATOR_USER STAGE ELEVATION_PASSWORD PLATFORM_REPO PLATFORM_BRANCH PLATFORM_REPO_READ_PAT STORAGE_BOX_HOST STORAGE_BOX_USER STORAGE_BOX_PASSWORD BACKUP_PASSPHRASE; do
  [ -n "${!named:-}" ] || die "the config says nothing under ${named}, and nothing here may choose one" 64
done

root() { printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' "$@"; }

# THE STORES, ONE ROW EACH: namespace | claim | the size the chart asks for. The SAME claims
# master-backup-driver.sh takes, in the same order; lifecycle/test.sh holds the two lists against
# each other. The size is the claim's request in clusters/inventories/<app>: a volume smaller than
# the request would never bind, and a larger one is a lie about what the store may grow to.
STORES=(
  "vault|data-vault-0|5Gi"
  "manager|manager-data|2Gi"
  "headscale|headscale-data|1Gi"
  "idp|data-idp-postgresql-0|8Gi"
  "mongodb|data-mongodb-${STAGE}-0|20Gi"
  "mongodb|data-mongodb-${STAGE}-1|20Gi"
  "mongodb|data-mongodb-${STAGE}-2|20Gi"
  "redis|redis-data|10Gi"
  "postfix|postfix-${STAGE}-postfix-${STAGE}-0|1Gi"
  "dbgate|dbgate-data|1Gi"
  "forgejo|gitea-shared-storage|10Gi"
)
readonly CHECKOUT=/srv/hostyour-cloud
readonly STAGING=/var/lib/master-restore
readonly STORAGE_ROOT=/var/snap/microk8s/common/default-storage

step "what this machine is, before anything is placed"
say "asked as $(id -un) on $(hostname), for $FQDN, stage $STAGE"
printf '%s\n' "$ELEVATION_PASSWORD" | sudo -S -p '' true 2>/dev/null || die 'the ELEVATION_PASSWORD in the config does not raise a command on this machine' 77
if root test -e "$STAGING/pending"; then
  die "a restore is already staged on this machine ($(root cat "$STAGING/pending")). Run install-machine; it places the stores once the cluster stands" 65
fi
if command -v microk8s >/dev/null 2>&1 && microk8s kubectl -n vault get pvc data-vault-0 >/dev/null 2>&1; then
  die "this machine already carries the platform's claims (vault/data-vault-0 among them). A restore comes BEFORE the services, onto a bare machine: this one already stands, and an installation is not overwritten" 65
fi
for tool in git tar gpg; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    say "$tool is not on this machine and this act needs it, so it is installed now"
    root apt-get install -y -q "$tool" >/dev/null 2>&1 || die "$tool could not be installed" 69
  fi
done
# THE PINNED RCLONE, from the shared helper the launcher sent ahead of this driver: from the owner's mirror, or from the package the
# operator carried with --rclone-package where the mirror stands on the machine that is lost. Nothing is placed before it answers the pin.
require_rclone || die "rclone $AW_RCLONE_PIN could not be put on this machine, and nothing else here reaches the storage box: $RCLONE_REFUSAL. Nothing was placed" 69
# A SECRET AN ELEVATED COMMAND NEEDS IS A FILE, never an argument: sudo writes every command it runs, with
# its arguments, to the system log, and any local account reads an argument in the process list. This
# shell's own printf is no process, so it writes each secret to a file of mode 600 in a folder in memory
# that cleanup removes, and the elevated command is given the file's path: gpg the passphrase's, rclone the
# storage box's, git the file whose extraheader carries the read token.
SECRETS="$(mktemp -d /dev/shm/aw-restore.XXXXXX)" || die 'no folder in memory could be made for the secrets an elevated command needs, and none of them may stand on its command line' 78
PASSPHRASE_FILE="$SECRETS/passphrase"
RCLONE_CONF="$SECRETS/rclone.conf"
GIT_CONF="$SECRETS/git.conf"
(
  umask 077
  printf '%s' "$BACKUP_PASSPHRASE" > "$PASSPHRASE_FILE"
  # The hash check of the remote is off, as where the backup was written: the box answers rclone's md5sum command with a failure or never.
  printf '[box]\ntype = sftp\nhost = %s\nuser = %s\npass = %s\ndisable_hashcheck = true\n' "$STORAGE_BOX_HOST" "$STORAGE_BOX_USER" "$(printf '%s\n' "$STORAGE_BOX_PASSWORD" | rclone obscure -)" > "$RCLONE_CONF"
  printf '[http "https://github.com/"]\n\textraheader = AUTHORIZATION: basic %s\n' "$(printf 'x-access-token:%s' "$PLATFORM_REPO_READ_PAT" | base64 | tr -d '\n')" > "$GIT_CONF"
) || die 'the secrets could not be written to files in memory' 78
export RCLONE_CONFIG="$RCLONE_CONF"
rclone lsd box: >/dev/null 2>&1 || die 'the storage box does not open — nothing was placed' 69
good 'the storage box opens'

BACKUPS="box:$FQDN/master"
if [ -z "$ID" ]; then
  step "the backups the storage box holds for $FQDN"
  LIST=$(rclone lsf "$BACKUPS/" --dirs-only 2>/dev/null | tr -d / | sort)
  [ -n "$LIST" ] || die "the storage box holds no backup under $BACKUPS/ — master-backup is what puts one there" 66
  printf '%s\n' "$LIST" | sed 's/^/     /'
  die 'name one of them as the second argument of master-restore; the newest is last' 64
fi

step "the backup $ID, fetched and checked"
rclone lsf "$BACKUPS/$ID/manifest.txt" >/dev/null 2>&1 \
  || die "the storage box holds no backup $ID under $BACKUPS/ — run master-restore without an id to see the ones it holds" 66
root install -d -m 700 -o root -g root "$STAGING" "$STAGING/$ID" || die "could not make $STAGING/$ID" 78
FETCH="$STAGING/$ID/sealed"
root install -d -m 700 "$FETCH"
root rclone --config "$RCLONE_CONF" copy "$BACKUPS/$ID/" "$FETCH/" --quiet 2>/dev/null || die "the backup $ID could not be fetched (rclone ended $?)" 69
root sh -c "cd '$FETCH' && grep -E '^[0-9a-f]{64}  ' manifest.txt | sha256sum -c --quiet" \
  || die "the checksums in manifest.txt of backup $ID do not hold — the archives are not what was written, and nothing of them is placed" 65
BACKED_FQDN=$(root grep -E '^FQDN=' "$FETCH/manifest.txt" | cut -d= -f2-)
BACKED_STAGE=$(root grep -E '^STAGE=' "$FETCH/manifest.txt" | cut -d= -f2-)
BACKED_RELEASE=$(root grep -E '^RELEASE=' "$FETCH/manifest.txt" | cut -d= -f2-)
[ "$BACKED_FQDN" = "$FQDN" ] || die "backup $ID was taken from $BACKED_FQDN and this config states $FQDN — a master's stores carry its identity, and a restore under another name is not a restore" 65
[ "$BACKED_STAGE" = "$STAGE" ] || die "backup $ID was taken at stage $BACKED_STAGE and this config states $STAGE" 65
good "backup $ID of $FQDN ($STAGE) fetched — every checksum holds"
if [ -n "$BACKED_RELEASE" ] && [ -n "${PLATFORM_REF:-}" ] && [ "$BACKED_RELEASE" != "$PLATFORM_REF" ]; then
  warn "the machine this was taken from stood on $BACKED_RELEASE and this config names PLATFORM_REF $PLATFORM_REF — the stores are opened by whatever release install-machine puts here; the same one is the safe answer"
fi

step "the platform checkout, standing where deploy-host would put it, with the installation's branch"
if root test -d "$CHECKOUT/.git"; then
  say "$CHECKOUT already stands here; the installation's branch is fetched into it"
else
  root env GIT_CONFIG_GLOBAL="$GIT_CONF" git clone --quiet --branch "$PLATFORM_BRANCH" "https://github.com/$PLATFORM_REPO.git" "$CHECKOUT" \
    || die "could not clone https://github.com/$PLATFORM_REPO.git ($PLATFORM_BRANCH) to $CHECKOUT" 69
  root chown -R "$OPERATOR_USER:$OPERATOR_USER" "$CHECKOUT"
  good "$CHECKOUT cloned on $PLATFORM_BRANCH, owned by $OPERATOR_USER"
fi
root -u "$OPERATOR_USER" env GIT_CONFIG_GLOBAL="$GIT_CONF" git -C "$CHECKOUT" fetch --quiet origin "refs/heads/$FQDN:refs/heads/$FQDN" \
  || die "origin carries no branch $FQDN, or it could not be fetched — the installation's branch is what a restore stands on, and without it this is a first installation, not a restore" 66
good "branch $FQDN stands in $CHECKOUT at $(root -u "$OPERATOR_USER" git -C "$CHECKOUT" rev-parse --short "refs/heads/$FQDN") — driver.sh finds a checkout that wrote it"

step "the quorum, back beside the checkout"
root install -d -m 700 -o "$OPERATOR_USER" -g "$OPERATOR_USER" "$CHECKOUT/secrets"
root gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE" -o "$CHECKOUT/secrets/vault-${STAGE}.txt" -d "$FETCH/host--vault-${STAGE}.txt.gpg" \
  || die "the quorum could not be opened — the BACKUP_PASSPHRASE in this config is not the one backup $ID was sealed with, and nothing of it is placed" 65
root chown "$OPERATOR_USER:$OPERATOR_USER" "$CHECKOUT/secrets/vault-${STAGE}.txt"
root chmod 600 "$CHECKOUT/secrets/vault-${STAGE}.txt"
good "secrets/vault-${STAGE}.txt stands — deploy-platform-services finds Vault initialized and its quorum here"

step "the stores, opened and staged for the moment the cluster stands"
PLAIN="$STAGING/$ID/stores"
root install -d -m 700 "$PLAIN"
for row in "${STORES[@]}"; do
  IFS='|' read -r ns pvc size <<< "$row"
  sealed="$FETCH/${ns}--${pvc}.tar.gpg"
  root test -f "$sealed" || die "backup $ID carries no archive for ${ns}/${pvc} — a backup missing a store is not one this places" 66
  root install -d -m 700 "$PLAIN/${ns}--${pvc}"
  root sh -c 'gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$1" -d "$2" | tar --numeric-owner -C "$3" -xf -' _ "$PASSPHRASE_FILE" "$sealed" "$PLAIN/${ns}--${pvc}" || die "the archive of ${ns}/${pvc} could not be opened" 65
  say "${ns}/${pvc} opened ($(root du -sh "$PLAIN/${ns}--${pvc}" | cut -f1))"
done
root rm -rf "$FETCH"
good "${#STORES[@]} store(s) stand opened under $PLAIN, root only"

# THE PLACEMENT, RUN BY driver.sh AFTER deploy-cluster. Written now, with every name resolved, so
# the driver runs one file and knows nothing of stores. Each claim gets a volume of its own under
# the storage root, holding the store, and a PersistentVolume with a claimRef to it: the claim the
# services create then binds to it, and the provisioner leaves it alone.
PLACE="$STAGING/restore-data.sh"
# The script is made here and handed to root through the environment: root() hands sudo the password
# on standard input, so a heredoc given to it never reaches the command, and under a NOPASSWD rule the
# command writes the password line instead.
IFS= read -r -d '' PLACEMENT <<EOF
#!/usr/bin/env bash
# Written by master-restore-driver.sh for backup $ID; run by driver.sh after deploy-cluster.
set -uo pipefail
ROOT_DIR="\$(readlink -f '$STORAGE_ROOT')"
[ -d "\$ROOT_DIR" ] || { echo "the storage root $STORAGE_ROOT does not lead to a directory" >&2; exit 69; }
placed=0
while IFS='|' read -r ns pvc size; do
  dir="\$ROOT_DIR/\${ns}-\${pvc}-restored-$ID"
  if [ ! -d "\$dir" ]; then
    mv "$PLAIN/\${ns}--\${pvc}" "\$dir" || { echo "could not place \${ns}/\${pvc}" >&2; exit 70; }
    chmod 777 "\$dir"
  fi
  microk8s kubectl apply -f - >/dev/null <<PV || { echo "the volume for \${ns}/\${pvc} could not be declared" >&2; exit 70; }
apiVersion: v1
kind: PersistentVolume
metadata:
  name: restored-\${ns}-\${pvc}
  labels:
    platform/restored-from: "$ID"
spec:
  capacity:
    storage: \${size}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: microk8s-hostpath
  claimRef:
    namespace: \${ns}
    name: \${pvc}
  hostPath:
    path: \$dir
    type: Directory
PV
  echo "   \${ns}/\${pvc} stands in \$dir, bound ahead of its claim"
  placed=\$(( placed + 1 ))
done <<ROWS
$(printf '%s\n' "${STORES[@]}")
ROWS
mv '$STAGING/pending' "$STAGING/placed-$ID"
echo "   \$placed store(s) placed from backup $ID"
EOF
root env PLACEMENT="$PLACEMENT" bash -c 'printf "%s" "$PLACEMENT" > "$1"' _ "$PLACE"
root chmod 700 "$PLACE"
root sh -c "printf '%s\n' '$ID' > '$STAGING/pending'"
good "the placement is written and the mark stands — driver.sh runs it after deploy-cluster"

step "what comes next"
say "run install-machine with this config. Phase 0 finds $CHECKOUT holding branch $FQDN and goes on;"
say "after deploy-cluster the driver places the ${#STORES[@]} store(s) and binds their claims; deploy-platform-services"
say "then finds Vault initialized with its quorum in secrets/, unseals it, and rewrites every mount and role for this cluster."
say "When it is green, point the name at this machine: master.<apex> and *.master.<apex> to $(hostname -f 2>/dev/null || hostname)."
printf 'STAGED %s\n' "$ID"
