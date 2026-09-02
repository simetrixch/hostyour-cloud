#!/usr/bin/env bash
# =============================================================================
# status.sh — which platform release each installation stands on, and how far
# origin/master has moved past it. PowerShell twin: status.ps1 (same folder),
# which answers identically on the same repository. release/test.sh measures
# that.
# =============================================================================
#
#   bash release/status.sh                          every installation
#   bash release/status.sh apps3.example.com        that one
#
# IT ONLY ANSWERS. Nothing here writes a file, a tag, a commit or a ref. The one
# thing it changes is this checkout's view of the remote, because an answer read
# from a stale view is not an answer. release.sh beside it is the half that acts.
#
# WHAT AN INSTALLATION IS, HERE. A branch of this repository named after the
# cluster's own domain, carrying `clusters/active/<branch>.yaml` — its cluster
# map. That file is what makes a branch an installation rather than a working
# branch, so it is what this looks for, and a branch without one is skipped
# without comment. migrations/migrate.sh decides the same question the same way,
# and nothing holds the two statements of it together.
#
# WHAT THE PIN IS. One line in that map, `release: <tag>`, naming the state of
# the product tree the installation stands on. release.sh writes it. A machine
# whose map records nothing cannot be told apart from one that is level, which is
# why an absent line is reported as loudly as a stale one.
#
# WHY THE STAMPED TREE IS COUNTED ON ITS OWN. Everything under clusters/argocd
# and clusters/bootstrap carries this installation's own domain, name, stage and
# role where the trunk carries markers. Those files cannot travel to a machine by
# a merge — merging the trunk's copy would put the markers back into files a
# reconciler reads literally — so they reach an existing installation only by a
# regeneration somebody runs. A commit that touches one of them is therefore a
# commit that stays away until that happens, and the count of them is the number
# this whole answer exists for.
#
# THOSE TWO DIRECTORY NAMES ARE ALSO WRITTEN SOMEWHERE ELSE: on the
# `stamp_placeholder_in_tracked_files` rows of the branch programs in the
# catalogue repository, which is what actually does the stamping. Nothing
# compares the two lists. A third stamped tree added there and not here makes
# every count below too low, and nothing would say so.
#
# IT ANSWERS ABOUT THE BRANCH, WHICH IS WHAT THE MACHINE FOLLOWS. The cluster's
# reconciler tracks the install branch, so for these files the branch is the
# machine. What it cannot see is a machine that has stopped reconciling.
#
# EXIT CODE. 0 whenever the report was produced, whatever the report says — an
# installation that is behind is an answer, not a failure. A non-zero exit means
# the question could not be answered at all: no git, no repository, no remote, or
# a name that is no installation.
# =============================================================================

set -uo pipefail

# The trees the branch programs stamp. See the header: this list and theirs are
# two statements of one fact, held together by nothing.
STAMPED_TREES=(clusters/argocd clusters/bootstrap)
STAMPED_TREES_SAID='clusters/argocd or clusters/bootstrap'

# WHAT IS PRINTED IS ASCII, and that is not a typographic preference. The two
# spellings are held to printing the same bytes, and PowerShell writes its output
# in whatever code page the console carries -- so a dash from outside ASCII
# arrives there as a different byte and the pair quietly stops agreeing. The
# comments in these files are read by people and may say what they like.
die() { printf 'status: %s\n' "$1" >&2; exit "${2:-65}"; }
say() { printf '%s\n' "$1"; }

ONLY="${1:-}"

command -v git >/dev/null 2>&1 \
  || die 'git is not on this path, and every line below is read out of git'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 'not inside a git repository. This is read from a checkout of the platform tree' 66

# THE VIEW FIRST. Every comparison below is against origin, so a checkout that
# has not fetched would answer about the remote as it stood whenever it last
# looked, and would not say that was what it was doing.
git fetch --quiet --tags origin \
  || die 'origin could not be fetched, so nothing here would be an answer about what origin carries' 69
git rev-parse --verify --quiet origin/master >/dev/null \
  || die 'origin carries no master, and the trunk is what every installation is measured against' 69

# THE VALUE OF ONE TOP-LEVEL KEY of one installation's map, read the way the
# catalogue's own step writes it: a line beginning at column one with the key and
# a colon. A key of the same name indented under `global:` is a different key and
# is deliberately not seen here. Surrounding quotes are the notation's and are
# taken off, which is what the catalogue's reading step does too.
value_in_map() {
  local ref="$1" key="$2" line value
  while IFS= read -r line; do
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
  done < <(git show "origin/$ref:clusters/active/$ref.yaml" 2>/dev/null)
  return 1
}

# Every branch of the remote that carries a cluster map named after itself.
INSTALLATIONS=()
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  [ "$ref" = 'HEAD' ] && continue
  [ "$ref" = 'master' ] && continue
  git cat-file -e "origin/$ref:clusters/active/$ref.yaml" 2>/dev/null || continue
  INSTALLATIONS+=("$ref")
done < <(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin)

if [ -n "$ONLY" ]; then
  KEPT=()
  for each in ${INSTALLATIONS[@]+"${INSTALLATIONS[@]}"}; do
    [ "$each" = "$ONLY" ] && KEPT=("$each")
  done
  [ ${#KEPT[@]} -gt 0 ] \
    || die "origin has no installation called $ONLY. An installation is a branch of this repository named after its own domain, carrying clusters/active/<domain>.yaml" 66
  INSTALLATIONS=("${KEPT[@]}")
fi

if [ ${#INSTALLATIONS[@]} -eq 0 ]; then
  say 'status: no branch of origin carries a cluster map, so there is no installation to report on'
  exit 0
fi

say 'status: which platform release each installation stands on, and what origin/master carries since'

for fqdn in "${INSTALLATIONS[@]}"; do
  say ''
  say "$fqdn"

  pin="$(value_in_map "$fqdn" release)"
  if [ -z "$pin" ]; then
    say '  release: none'
    say '  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release.sh / release.ps1 beside this file writes that line.'
    continue
  fi
  say "  release: $pin"

  git rev-parse --verify --quiet "${pin}^{commit}" >/dev/null || {
    say '  unresolved: nothing here resolves that to a commit, so it names a state this repository does not carry: it was never pushed, or it has been deleted'
    continue
  }

  total="$(git rev-list --count "${pin}..origin/master")"
  stamped="$(git rev-list --count "${pin}..origin/master" -- "${STAMPED_TREES[@]}")"
  if [ "$total" = '0' ]; then
    say '  level: origin/master carries nothing this release does not'
    continue
  fi
  say "  behind: $total commits on origin/master since that release, $stamped of them under $STAMPED_TREES_SAID"
  while IFS= read -r changed; do
    [ -n "$changed" ] && say "  stamped: $changed"
  done < <(git diff --name-only "$pin" origin/master -- "${STAMPED_TREES[@]}")
done
