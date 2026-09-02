#!/usr/bin/env bash
# =============================================================================
# 0001-declare-deploy-repo.sh - state which repository the deployment programs
# are read from, in an installation's own config file.
# =============================================================================
#
# WHY A MIGRATION AND NOT A MERGE. configs/config.<stage> is born on the branch
# and stands on no trunk, so nothing carries a new key into it: a merge has
# nothing to merge from and a regeneration is what preserves the file. The
# programs fill a key that is ALREADY THERE, in place, under the explanation it
# stands beneath - they do not append one, because a bare assignment at the end
# of a file whose whole value is that every key carries its reason is worse than
# no assignment at all.
#
# WHAT IT DOES. Writes DEPLOY_REPO beneath CATALOG_REPO, with the sentence that
# says which of the two is which. It is the platform's own repository, public
# and the same for every installation, so the value is stated here rather than
# read off the branch. CATALOG_REPO beside it is the installation's own tenant
# charts, private and reached with a credential; one key for both clones
# whichever repository the last writer meant.
set -euo pipefail

CHECKOUT="${1:?the directory of a checkout standing on the branch}"
BRANCH="${2:?the branch name}"

readonly VALUE='simetrixch/hostyour-deploy'

# THE BLOCK, WITH ITS EXPLANATION. A key in these files stands under the sentence
# that says what it names; a bare assignment is what this migration exists to
# avoid rather than to create. The value is quoted the way every other value in
# the file is quoted.
BLOCK=$(cat <<BLOCK_END

# The repository the DEPLOYMENT PROGRAMS are read from, written as owner/name. It is the platform's
# own and public, the same for every installation, and the row that clones the catalogue onto this
# machine reads it from HERE and names no credential beside it. It is not CATALOG_REPO above: that
# one is your tenant charts, private and reached with a read credential, and a single key for both
# clones whichever repository the last writer meant.
DEPLOY_REPO="$VALUE"
BLOCK_END
)

touched=0
missing=0
for file in "$CHECKOUT"/configs/config.*; do
  [ -f "$file" ] || continue
  case "${file##*/}" in config.example) continue ;; esac
  if grep -q '^DEPLOY_REPO=' "$file"; then continue; fi
  if ! grep -q '^CATALOG_REPO=' "$file"; then missing=$((missing + 1)); continue; fi
  # BY LINE, and after the LAST CATALOG_REPO line rather than the first: awk
  # walks once and prints the block behind the assignment, so every comment
  # above it and every byte around it stands exactly where it stood.
  awk -v block="$BLOCK" '
    { print }
    /^CATALOG_REPO=/ && !done { print block; done = 1 }
  ' "$file" > "$file.0001" && mv -f "$file.0001" "$file"
  touched=$((touched + 1))
done

if [ "$missing" -gt 0 ]; then
  echo "0001-declare-deploy-repo: $BRANCH carries a config with no CATALOG_REPO line, so there is nothing to write DEPLOY_REPO beneath" >&2
  exit 1
fi
if [ "$touched" -eq 0 ]; then
  echo "0001-declare-deploy-repo: $BRANCH already states DEPLOY_REPO in every config it carries"
else
  echo "0001-declare-deploy-repo: $BRANCH now states DEPLOY_REPO=$VALUE in $touched config file(s)"
fi
