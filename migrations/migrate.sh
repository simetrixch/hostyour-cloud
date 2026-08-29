#!/usr/bin/env bash
# ===========================================================================
# migrate.sh — correct branch-born facts across every install branch.
#
# An install branch carries three kinds of bytes, and two of them already have
# a path. What the product tree owns unstamped — charts, values, inventories,
# pins — reaches a branch by a merge. What it owns stamped — the files under
# clusters/argocd and clusters/bootstrap, where the installation's own domain,
# name, stage and role stand where the trunk carries markers — reaches it by a
# regeneration. The third kind is born on the branch and exists nowhere else:
# the cluster maps under clusters/active/, configs/config.<stage>, the files
# under installation/. A merge cannot reach it because the trunk does not
# carry it, and a regeneration is exactly what preserves it. This script is
# the path for that third kind, and for nothing else: a migration that copies
# product-tree content is a second delivery path that drifts from the first,
# and a migration that moves an image pin is a release wearing the wrong hat.
#
# USAGE (from the repo root of a checkout, on a person's machine — nothing
# runs this automatically, the same way release/release.sh of the manager is
# a person's own act)
#
#   bash migrations/migrate.sh            report what every branch would get; push nothing
#   bash migrations/migrate.sh --write    the same work, plus the push
#
# WHAT A RUN DOES
#   1. Clones this repository's origin fresh into a temporary directory, so
#      nothing here depends on the checkout it was started from and nothing
#      here can touch one.
#   2. Walks every branch of the remote except the trunk. A branch is an
#      install branch when it carries its own cluster map at
#      clusters/active/<branch>.yaml; a ref without one is named in the
#      report and skipped, with the path it was looked for under.
#   3. On each install branch, runs every numbered migration the branch has
#      not recorded yet, lowest number first. The scripts run FROM THIS
#      CHECKOUT, never from the walked branch — every branch gets the same
#      version of a migration, the way a database gets its migrations from
#      the codebase and only records which ones it has had.
#   4. Appends each migration that ran to installation/migrations ON THE
#      BRANCH, in the same commit as its changes. The branch keeps its own
#      record because the branch is the only carrier every machine reads the
#      same way — a list kept on a machine knows only the runs that machine
#      happened to perform.
#   5. Reports, per branch, what it did, what it skipped and why. Without
#      --write the commits are built in the throwaway clone and discarded
#      with it; the push is the only thing --write adds, so the report of a
#      dry run is a measurement of the real work and not a prediction.
#
# WHAT A MIGRATION IS
#   migrations/NNNN-<what-it-does>.sh — four digits, unique, applied once per
#   branch, in numeric order. ONE script per migration, never one per kind of
#   branch: whether a branch keeps the books is a fact recorded in its own
#   map (role, booksCluster), not a category it belongs to, and a machine may
#   carry both parts of a role at once. The script is called with two
#   arguments — the directory of a checkout standing on the branch, and the
#   branch name — reads what the branch IS from the branch's own files, does
#   what there is to do or nothing, and prints ONE line saying which. It
#   edits BY LINE, never by parsing YAML and writing it back: these files
#   carry comments and a form a round-trip destroys. A non-zero exit is a
#   failure — nothing is recorded, later migrations do not run on that
#   branch, and the run ends red.
# ===========================================================================
set -euo pipefail

die() { echo "migrate: $*" >&2; exit 1; }

RECORD="installation/migrations"

WRITE=0
case "${1:-}" in
  "") ;;
  --write) WRITE=1 ;;
  *) die "unknown argument '${1}' — usage: bash migrations/migrate.sh [--write]" ;;
esac

command -v git >/dev/null 2>&1 || die "git is not on this path, and the whole run is git"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repository — run this from a checkout of the platform tree"
[ -f "$ROOT/migrations/migrate.sh" ] \
  || die "this repository has no migrations/migrate.sh at its root, so it is not the platform tree"
ORIGIN_URL="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" \
  || die "this checkout has no remote 'origin', so there are no install branches to walk"

# The migrations this checkout carries, in the order their numbers state. Two
# scripts sharing a number would apply in an order the numbers no longer
# state, so that is refused before any branch is read.
MIGRATIONS=()
while IFS= read -r f; do
  [ -n "$f" ] && MIGRATIONS+=("${f##*/}")
done < <(find "$ROOT/migrations" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.sh' | LC_ALL=C sort)
if [ "${#MIGRATIONS[@]}" -gt 0 ]; then
  DUP="$(printf '%s\n' "${MIGRATIONS[@]}" | cut -c1-4 | LC_ALL=C sort | uniq -d | head -1)"
  [ -z "$DUP" ] || die "two migrations share the number ${DUP} — renumber one, the number is the order"
fi

# A write run applies only migrations that are committed. An uncommitted one
# would change live installations and then exist nowhere anybody else can
# read — the branch would record a name this repository never carried.
if [ "$WRITE" = "1" ]; then
  [ -z "$(git -C "$ROOT" status --porcelain -- migrations)" ] \
    || die "migrations/ carries uncommitted changes — commit them first, or run without --write"
  echo "migrate: a WRITE run — what a migration changes is committed and pushed to the install branches"
else
  echo "migrate: a report run — the commits are built in a throwaway clone and discarded; nothing is pushed without --write"
fi

TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT
git clone --quiet "$ORIGIN_URL" "$TREE" \
  || die "the platform tree at ${ORIGIN_URL} could not be cloned — nothing was read"

TRUNK="$(git -C "$TREE" symbolic-ref --short refs/remotes/origin/HEAD)"
TRUNK="${TRUNK#origin/}"

REFS=()
while IFS= read -r r; do
  [ "$r" = "HEAD" ] && continue
  REFS+=("$r")
done < <(git -C "$TREE" for-each-ref --format='%(refname:strip=3)' refs/remotes/origin | LC_ALL=C sort)

REPORT=()
WALKED=0
SKIPPED=0
RED=0

for B in "${REFS[@]}"; do
  [ "$B" = "$TRUNK" ] && continue

  MAP="clusters/active/${B}.yaml"
  if ! MAPTEXT="$(git -C "$TREE" show "origin/${B}:${MAP}" 2>/dev/null)"; then
    REPORT+=("${B} — skipped: it carries no ${MAP}, so it is not an install branch")
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  WALKED=$((WALKED + 1))

  # What the branch IS, read from its own map — reported so a clean answer
  # can be seen to come from looking, not from failing to look.
  ROLE="$(printf '%s\n' "$MAPTEXT" | sed -n -E 's/^role:[[:space:]]*//p' | head -1)"
  BOOKS="$(printf '%s\n' "$MAPTEXT" | sed -n -E 's/^booksCluster:[[:space:]]*//p' | head -1)"
  REPORT+=("${B} — an install branch; its map states role '${ROLE:-<none>}' and booksCluster '${BOOKS:-<none>}'")

  RECORDED="$(git -C "$TREE" show "origin/${B}:${RECORD}" 2>/dev/null || true)"

  # A record line this checkout has no script for means migrations ran from a
  # newer trunk than the one standing here. The branch is right and this
  # checkout is behind — said out loud rather than read as a stale record.
  while IFS= read -r LINE; do
    case "$LINE" in [0-9][0-9][0-9][0-9]-*) ;; *) continue ;; esac
    KNOWN=0
    for M in "${MIGRATIONS[@]}"; do
      [ "${M:0:4}" = "${LINE:0:4}" ] && KNOWN=1 && break
    done
    [ "$KNOWN" = "1" ] \
      || REPORT+=("    its ${RECORD} records ${LINE}, which this checkout does not carry — the checkout is behind what has already run")
  done <<< "$RECORDED"

  if [ "${#MIGRATIONS[@]}" -eq 0 ]; then
    REPORT+=("    this checkout carries no migrations, so there was nothing to apply")
    continue
  fi

  PENDING=()
  for M in "${MIGRATIONS[@]}"; do
    printf '%s\n' "$RECORDED" | grep -q "^${M:0:4}-" || PENDING+=("$M")
  done
  if [ "${#PENDING[@]}" -eq 0 ]; then
    REPORT+=("    every migration of this checkout is recorded in ${RECORD} — nothing pending")
    continue
  fi

  # Stand the throwaway clone on the branch, clean of whatever a failed
  # migration may have left behind on the branch before it.
  git -C "$TREE" reset --quiet --hard
  git -C "$TREE" clean -qfd
  git -C "$TREE" checkout --quiet "$B"
  git -C "$TREE" reset --quiet --hard "origin/${B}"

  for M in "${PENDING[@]}"; do
    if OUT="$(bash "$ROOT/migrations/${M}" "$TREE" "$B" 2>&1)"; then
      CHANGED="$(git -C "$TREE" status --porcelain)"
      mkdir -p "$TREE/installation"
      if [ ! -f "$TREE/${RECORD}" ]; then
        printf '%s\n' \
          "# The migrations this branch has had, one per line, appended by migrations/migrate.sh." \
          "# The branch keeps this record itself: it is the one carrier every machine of the" \
          "# installation reads the same way, where a list kept on a machine knows only the runs" \
          "# that machine happened to perform." > "$TREE/${RECORD}"
      fi
      printf '%s\n' "$M" >> "$TREE/${RECORD}"
      # The clone was reset hard before the first migration and committed
      # after each one, so everything unstaged here is what this one
      # migration just wrote — staging all of it is staging exactly its work.
      git -C "$TREE" add -A -- .
      if [ -n "$CHANGED" ]; then
        git -C "$TREE" commit --quiet -m "Apply migration ${M%.sh}" -m "$OUT"
        REPORT+=("    ${M}: ${OUT}")
      else
        git -C "$TREE" commit --quiet -m "Record migration ${M%.sh} as applied without effect" -m "$OUT"
        REPORT+=("    ${M}: nothing to do — ${OUT} (recorded as applied)")
      fi
    else
      REPORT+=("    ${M}: FAILED — ${OUT}")
      REPORT+=("    the remaining migrations did not run on this branch, and nothing of ${M} was recorded")
      RED=1
      break
    fi
  done

  AHEAD="$(git -C "$TREE" rev-list --count "origin/${B}..${B}")"
  if [ "$AHEAD" -gt 0 ]; then
    if [ "$WRITE" = "1" ]; then
      if git -C "$TREE" push --quiet origin "$B"; then
        REPORT+=("    pushed ${AHEAD} commit(s) to origin/${B}")
      else
        REPORT+=("    FAILED — the ${AHEAD} commit(s) could not be pushed to origin/${B}")
        RED=1
      fi
    else
      REPORT+=("    ${AHEAD} commit(s) stand ready in a throwaway clone and were NOT pushed — run with --write to push them")
    fi
  fi
done

echo "migrate: the report — every ref of ${ORIGIN_URL}, and what happened on it"
for LINE in ${REPORT[@]+"${REPORT[@]}"}; do
  echo "migrate:   ${LINE}"
done
echo "migrate: walked ${WALKED} install branch(es) and skipped ${SKIPPED} other ref(s), each named above with why; the trunk ${TRUNK} is not walked — what the trunk needs is a commit on the trunk"
[ "${#MIGRATIONS[@]}" -gt 0 ] \
  || echo "migrate: this checkout carries no migrations, so the walk above states only what each branch is"

if [ "$RED" = "1" ]; then
  echo "migrate: the run is RED — a FAILED line above names the branch and the migration" >&2
  exit 1
fi
if [ "$WRITE" = "1" ]; then
  echo "migrate: OK — every pending migration ran, was recorded on its branch, and was pushed"
else
  echo "migrate: OK — every install branch was read; nothing was pushed"
fi
