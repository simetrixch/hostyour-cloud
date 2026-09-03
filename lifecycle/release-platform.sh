#!/usr/bin/env bash
# =============================================================================
# release-platform.sh — cut a release of the platform tree and put ONE
# installation on it. PowerShell twin: release-platform.ps1 (same folder), which
# does the same in the same order and prints the same lines. lifecycle/test.sh
# measures that.
# =============================================================================
#
# USAGE (run from anywhere inside a hostyour-cloud checkout)
#   bash lifecycle/release-platform.sh <x.y.z> <stable|beta|alpha> <fqdn>
#
# THE THREE INPUTS
#   version  — x.y.z, no leading zeros. EVERY RELEASE IS A PATCH BUMP: the first
#              two numbers say what the product is and are the owner's to move.
#   channel  — the maturity CEILING of the release: alpha may reach a dev
#              installation only, beta dev and test, stable any. The channel is
#              part of the release tag; the installation is not.
#   fqdn     — WHICH INSTALLATION this run puts the release on. It is the domain
#              of the cluster, the name of its install branch, and the name of
#              its map under clusters/active. One release, one tree, any number
#              of installations: run this again with another fqdn and the tag is
#              REUSED rather than cut a second time.
#
# WHAT A PLATFORM RELEASE IS, AND WHAT IT IS NOT. This repository builds nothing
# — no image, no archive, no package. THE TREE AT THE TAG IS THE RELEASE. So
# there is no pipeline to start and nothing to wait for, and this script needs
# nothing but git: no gh, no token, no network service. What it waits on instead
# is the one thing a machine actually needs — that the tag is on the REMOTE,
# because a pin naming a tag the machine cannot fetch is a pin that fails three
# systems away, in a message about a git ref rather than about a release.
#
# WHY THE PIN IS WRITTEN HERE. The line `release: <tag>` in
# clusters/active/<fqdn>.yaml is what says which state an installation stands on,
# and the write belongs where the credential already is: this workstation is
# logged in to this repository, which is both the tree being released and the
# tree carrying the pin. Nothing new has to be created, held or rotated.
#
# NOTHING IS CREATED BEFORE THE TARGET IS KNOWN GOOD. The install branch is
# cloned, its map read and the ceiling checked BEFORE a tag is minted, so a
# mistyped domain or a channel that may not reach that stage costs nothing and
# leaves no tag behind naming a release nobody meant to cut.
#
# WHAT THIS DOES NOT DO. It does not stamp anything, and it touches no file under
# clusters/argocd or clusters/bootstrap. Those files carry one installation's own
# domain, name, stage and role where this tree carries markers, and writing them
# is the branch programs' act in the catalogue repository — re-run by
# regenerate-branch, which regenerate-install-branch.sh beside this file performs
# on the machine, and which is the act a person performs after this one. A second
# implementation of that stamping beside them would disagree with them the first
# time either was corrected.
#
# THE ORDER IS PIN, THEN REGENERATE, and they are two acts on purpose. Between
# them somebody can read what the pin now says and stop. This one ends by naming
# the second, which reads the ref off the pin this one writes rather than being
# told it a second time.
#
# THE TAG GOES ON origin/master AND NEVER ON THE LOCAL BRANCH. What is released
# is what the remote publishes; a local master may carry commits nobody else has,
# and a tag on one of those names a tree no installation could ever fetch. Where
# the local master is ahead, this says how many commits are being left out.
# =============================================================================

set -uo pipefail

# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
die() { printf 'release: %s\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

# THE VALUE OF ONE TOP-LEVEL KEY, read the way the catalogue's own step writes
# it: a line beginning at column one with the key and a colon. A key of the same
# name indented under `global:` is a different key and is deliberately not seen.
# Surrounding quotes are the notation's and are taken off.
value_in_file() {
  local file="$1" key="$2" line value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key":*)
        value="${line#"$key":}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$value" in
          \"*\") value="${value#\"}"; value="${value%\"}" ;;
          \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# THE LINE IS REPLACED WHERE IT STANDS AND APPENDED ONLY WHERE THE FILE HAS NONE,
# which is the grammar the catalogue's writing step uses. Appending regardless
# would leave two lines for one key, and whatever reads them takes one.
write_value_in_file() {
  local file="$1" key="$2" value="$3" line i found=0
  local -a lines=()
  while IFS= read -r line || [ -n "$line" ]; do lines+=("$line"); done < "$file"
  for ((i = 0; i < ${#lines[@]}; i++)); do
    case "${lines[$i]}" in
      "$key":*) lines[$i]="$key: $value"; found=1; break ;;
    esac
  done
  [ "$found" = '1' ] || lines+=("$key: $value")
  : > "$file"
  for line in "${lines[@]}"; do printf '%s\n' "$line" >> "$file"; done
}

VERSION="${1:-}"
CHANNEL="${2:-}"
FQDN="${3:-}"

[ -n "$VERSION" ] && [ -n "$CHANNEL" ] && [ -n "$FQDN" ] \
  || die 'usage: lifecycle/release-platform.sh <x.y.z> <stable|beta|alpha> <fqdn>' 64
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "version must be x.y.z with no leading zeros (got '$VERSION')" 64
case "$CHANNEL" in
  alpha) ADMITS='dev' ;;
  beta) ADMITS='dev test' ;;
  stable) ADMITS='dev test prod' ;;
  *) die "channel must be stable, beta or alpha (got '$CHANNEL')" 64 ;;
esac

command -v git >/dev/null 2>&1 \
  || die 'git is not on this path, and a platform release is nothing but git'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 'not inside a git repository. Run this from a checkout of the platform tree' 66

# THE REMOTE VIEW FIRST, for two reasons. Mint-once has to see the tags somebody
# else pushed, or a second workstation mints a second tag for the same version
# and channel instead of reusing the one that exists. And the tag below is put on
# origin/master, which a checkout that has not fetched resolves to whatever it
# last saw.
git fetch --quiet --tags origin \
  || die 'origin could not be fetched, so neither the tag nor the pin would be about what the remote carries' 69
git rev-parse --verify --quiet origin/master >/dev/null \
  || die 'origin carries no master, and master is what a platform release is cut from' 69

# THE TREE IS CLONED FRESH FOR THE WRITE. The pin stands on an install branch,
# and checking one out in the tree somebody is standing in is a thing a release
# has no business doing.
URL="$(git remote get-url origin)"
[ -n "$URL" ] || die 'this checkout has no origin to clone, so there is no branch to pin' 69
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone --quiet --single-branch --branch "$FQDN" "$URL" "$WORK" \
  || die "origin has no branch $FQDN. An installation is pinned on its own install branch, and there is none of that name" 66

MAP="clusters/active/${FQDN}.yaml"
[ -f "$WORK/$MAP" ] \
  || die "branch $FQDN carries no $MAP. That map is where an installation records what it is, and the pin is one line in it" 66

# THE CEILING IS ENFORCED HERE, and this is the only place that can. The manager's
# release client only warns because a pipeline refuses afterwards; a platform
# release has no pipeline, so a refusal that did not happen here would not happen
# at all, and a prod installation would stand on an alpha tree.
STAGE="$(value_in_file "$WORK/$MAP" stage)"
[ -n "$STAGE" ] \
  || die "$MAP on branch $FQDN states no stage, so the channel ceiling cannot be checked, and a check that cannot measure must not report a pass" 65
case " $ADMITS " in
  *" $STAGE "*) ;;
  *) die "$FQDN is stage $STAGE and channel $CHANNEL admits only: $ADMITS. Nothing else would refuse this, so this does." 65 ;;
esac

# THE STAGE IS NOT A DOMAIN LABEL, and this is the one place that can still say so
# before a tree reaches a machine. An API group is a reverse domain name fixed by
# whoever wrote the software - triggers.tekton.dev, cert-manager.io, argoproj.io -
# and no part of it varies with an installation's stage. Written as the stage
# placeholder it renders correctly on a dev installation by accident, because the
# stamp puts "dev" back, and names a group no cluster registers on every other
# stage. Measured on a real machine: the cicd project permits
# triggers.tekton.prod, ArgoCD cannot manage the ClusterInterceptors, and the
# tekton application stands OutOfSync for ever with the image-builder behind it.
#
# READ OFF origin/master, not the working tree: that is the tree this release
# publishes, and a correction sitting uncommitted beside it would let a release
# claim a fix nobody can fetch.
PLACED=$(git grep -nE '^[[:space:]]*(-[[:space:]]+)?(group|apiVersion):[[:space:]]*[^[:space:]]*__STAGE__' \
  origin/master -- clusters/argocd clusters/bootstrap 2>/dev/null | sed 's/$/;/' | tr -d '\n')
[ -z "$PLACED" ] \
  || die "a stage placeholder stands where an API group or an apiVersion belongs, and neither ever varies with a stage: $PLACED correct it on master and release again" 65

# MINT-ONCE: exactly one release tag per version and channel. A later run for the
# same pair reuses it, which is how one release reaches a further installation
# without a second tree ever being cut.
PREFIX="${VERSION}-${CHANNEL}-"
EXISTING="$(git tag -l "${PREFIX}*" | sort | tail -1)"

# A TAG THAT NEVER REACHED ORIGIN AND NAMES ANOTHER COMMIT IS RESIDUE, and reusing
# it aims every retry at the commit a refused push left behind. The tag is minted
# before it is pushed, so a push the pre-push hook refuses leaves it standing here
# and nowhere else; the next run finds it, reuses it, and is refused again — for
# the same reason, printed as if it were about the new attempt. Measured on this
# workstation: three runs of 0.7.8 refused in a row, cleared only by deleting the
# tag by hand.
#
# A TAG THAT IS ON ORIGIN IS LEFT EXACTLY AS IT STANDS, whatever commit it names.
# That is mint-once itself: one release per version and channel, reused so a
# release already cut reaches a second installation without a second tree.
if [ -n "$EXISTING" ] \
  && ! git ls-remote --exit-code --tags origin "refs/tags/${EXISTING}" >/dev/null 2>&1 \
  && [ "$(git rev-parse --verify --quiet "${EXISTING}^{commit}")" != "$(git rev-parse --verify origin/master)" ]; then
  say "release: $EXISTING stands on this workstation only and names $(git rev-parse --short=7 "${EXISTING}^{commit}"), not the commit this release is cut from. A run whose push was refused left it behind; it is dropped and cut again."
  git tag -d "$EXISTING" >/dev/null \
    || die "the leftover tag $EXISTING could not be dropped, and reusing it would put this release on a commit nobody is releasing" 69
  EXISTING=""
fi

if [ -n "$EXISTING" ]; then
  TAG="$EXISTING"
  say "release: reusing $TAG. One release per version and channel, so putting it on $FQDN cuts nothing new"
else
  TS14="$(date -u +%Y%m%d%H%M%S)"
  TAG="${VERSION}-${CHANNEL}-${TS14}"
  git tag -a "$TAG" -m 'the platform, cut as a release' origin/master \
    || die "the tag $TAG could not be put on origin/master"
  SHA7="$(git rev-parse --short=7 "${TAG}^{commit}")"
  say "release: minted $TAG on origin/master (commit $SHA7)"
  say 'release: this tree builds nothing. The tree at the tag IS the release, so there is no image and nothing further to wait for'
fi

if git rev-parse --verify --quiet master >/dev/null; then
  AHEAD="$(git rev-list --count origin/master..master)"
  [ "$AHEAD" = '0' ] \
    || say "release: your local master is $AHEAD commits ahead of origin/master, and those commits are not in this release"
fi

# NOTHING IS PINNED BEFORE IT EXISTS. The push is what makes the tag fetchable;
# the read-back is what proves it, and it is asked of the REMOTE rather than of
# this checkout, which already has the tag whatever the remote thinks.
git push --quiet origin "refs/tags/$TAG" \
  || die "the tag $TAG could not be pushed to origin, so it exists on this machine only and nothing was pinned" 74
[ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ] \
  || die "origin does not carry $TAG after the push, so a machine could not fetch it and nothing was pinned" 74
say 'release: the tag stands on the remote, so a machine that fetches origin can resolve it'

HELD="$(value_in_file "$WORK/$MAP" release)"
if [ "$HELD" = "$TAG" ]; then
  say "release: $MAP already records $TAG, so it is left as it stands"
else
  write_value_in_file "$WORK/$MAP" release "$TAG"
  git -C "$WORK" add -- "$MAP" \
    || die "the pin could not be staged in $MAP"
  git -C "$WORK" commit --quiet -m "Pin $FQDN to $TAG" -m 'Written by the release of the platform tree, once the tag stood on the remote.' \
    || die "the pin of $FQDN to $TAG could not be committed"
  git -C "$WORK" push --quiet origin "$FQDN" \
    || die "the pin of $FQDN to $TAG could not be pushed, so it is a pin only this machine believes" 74
  say "release: pinned $FQDN to $TAG in $MAP"
fi

say "release: $FQDN is pinned. It STANDS on that release once its branch is regenerated, which is the second act and is performed from a checkout of the platform tree:"
say "release:     bash lifecycle/regenerate-install-branch.sh $FQDN"
say "release:     pwsh ./lifecycle/regenerate-install-branch.ps1 $FQDN"
say "release: that script reads $TAG off the pin this run just wrote, so the ref is stated once and a regeneration cannot be aimed at a state the map does not record."
