#!/usr/bin/env bash
# ===========================================================================
# test.sh — proves migrations/migrate.sh does what it says, against a fixture
# it builds in a temporary directory: a bare origin with a trunk, two install
# branches and one ref that is no install branch at all.
#
#   bash migrations/test.sh
#
# Every check here carries a planted defect of the shape it is meant to catch
# and a planted innocent beside it, so a green run means the checks looked
# and found order — not that nothing was looking. The planted MIGRATION is
# shaped like the first real candidate this mechanism was designed around
# (writing a release line into a cluster map that lost its writer), planted
# here rather than shipped, because no real migration is needed today.
#
# What this file cannot prove, named rather than counted: an authenticated
# remote (the fixture's origin is a directory, so a push never asks for a
# credential), two runs racing on one branch, and a migration that reaches
# outside the clone it is handed.
# ===========================================================================
set -euo pipefail

fail() { echo "test: RED — $*" >&2; exit 1; }
ok() { echo "test: ok — $*"; }

# Every assertion states what it was checking, so a red line names the claim
# that broke and not merely the string that was missing.
must() { grep -qF -- "$1" <<< "$OUT" || fail "$2 — missing from the output: '$1'"; }
must_not() { ! grep -qF -- "$1" <<< "$OUT" || fail "$2 — present in the output: '$1'"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Commits of the fixture and of the runner's throwaway clone both need an
# identity, and the machine's own must not leak into a test.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

ORIGIN="$WORK/origin.git"
git init --quiet --bare --initial-branch=master "$ORIGIN"

show_origin() { git --git-dir="$ORIGIN" show "$1"; }
refs_of_origin() { git ls-remote "$ORIGIN" | LC_ALL=C sort; }

# ── the fixture: a trunk, two install branches, one other ref ──────────────
SEED="$WORK/seed"
git init --quiet --initial-branch=master "$SEED"
git -C "$SEED" remote add origin "$ORIGIN"
mkdir -p "$SEED/migrations" "$SEED/clusters/active"
# The same byte rule the real tree carries, so the fixture's files are stored
# and checked out LF on every machine, exactly as the files a migration edits.
echo "* text=auto eol=lf" > "$SEED/.gitattributes"
cp "$HERE/migrate.sh" "$SEED/migrations/migrate.sh"
touch "$SEED/clusters/active/.gitkeep"
git -C "$SEED" add -A
git -C "$SEED" commit --quiet -m "Seed the trunk"
git -C "$SEED" push --quiet origin master

# Branch one: role master, no release line — the branch the planted migration
# has work on. Its comments and blank line are the probe that a line edit
# leaves every other byte alone.
git -C "$SEED" checkout --quiet -b one.example.invalid
cat > "$SEED/clusters/active/one.example.invalid.yaml" <<'EOF'
# What this cluster is — a fixture standing in for a real cluster map.
# The comments and the blank line below are the form a YAML round-trip
# destroys, and the probe that an edit leaves them byte for byte.
stage: dev
role: master
booksCluster: one.example.invalid
# THE PIN. The release this cluster stands on. Nothing writes this line any
# more, which is the fact the planted migration corrects.

global:
  domain: one.example.invalid
  booksCluster: one.example.invalid
EOF
cp "$SEED/clusters/active/one.example.invalid.yaml" "$WORK/one-map-before"
git -C "$SEED" add -A
git -C "$SEED" commit --quiet -m "Cut the first install branch"
git -C "$SEED" push --quiet origin one.example.invalid

# Branch two: role slave, release line already standing — the innocent the
# migration must leave alone while still recording that it looked.
git -C "$SEED" checkout --quiet master
git -C "$SEED" checkout --quiet -b two.example.invalid
cat > "$SEED/clusters/active/two.example.invalid.yaml" <<'EOF'
stage: dev
role: slave
booksCluster: one.example.invalid
release: 0.0.9-already
global:
  domain: two.example.invalid
EOF
cp "$SEED/clusters/active/two.example.invalid.yaml" "$WORK/two-map-before"
git -C "$SEED" add -A
git -C "$SEED" commit --quiet -m "Cut the second install branch"
git -C "$SEED" push --quiet origin two.example.invalid

# A ref that is NOT an install branch — the planted defect of the shape "a
# ref the walk must skip out loud", because it carries no cluster map.
git -C "$SEED" checkout --quiet master
git -C "$SEED" checkout --quiet -b not-an-install-branch
echo "not a cluster" > "$SEED/notes.txt"
git -C "$SEED" add -A
git -C "$SEED" commit --quiet -m "A branch of some other kind"
git -C "$SEED" push --quiet origin not-an-install-branch

# ── the person's checkout, with the planted migration committed ────────────
USERCO="$WORK/user"
git clone --quiet "$ORIGIN" "$USERCO"
cat > "$USERCO/migrations/0001-write-a-release-line.sh" <<'EOF'
#!/usr/bin/env bash
# Planted by test.sh: insert `release: 0.0.9-planted` after the top-level
# booksCluster line of the branch's own cluster map, where no release line
# stands. Line by line, so every other byte survives.
set -euo pipefail
TREE="$1"
BRANCH="$2"
MAP="$TREE/clusters/active/${BRANCH}.yaml"
[ -f "$MAP" ] || { echo "the branch carries no clusters/active/${BRANCH}.yaml"; exit 1; }
if grep -qE '^release:' "$MAP"; then
  echo "a release line already stands in clusters/active/${BRANCH}.yaml"
  exit 0
fi
awk '{ print } /^booksCluster:/ && !seen { print "release: 0.0.9-planted"; seen=1 }' \
  "$MAP" > "$MAP.writing"
mv "$MAP.writing" "$MAP"
echo "wrote release: 0.0.9-planted after the booksCluster line of clusters/active/${BRANCH}.yaml"
EOF
git -C "$USERCO" add migrations/0001-write-a-release-line.sh
git -C "$USERCO" commit --quiet -m "Plant the first migration"

run() {
  RC=0
  OUT="$( (cd "$USERCO" && bash migrations/migrate.sh "$@") 2>&1 )" || RC=$?
}

# ── 1. a report run looks at everything and writes nothing ─────────────────
BEFORE="$(refs_of_origin)"
run
[ "$RC" = "0" ] || fail "the report run ended red: ${OUT}"
[ "$BEFORE" = "$(refs_of_origin)" ] || fail "a run without --write moved the remote"
must "one.example.invalid — an install branch; its map states role 'master' and booksCluster 'one.example.invalid'" \
  "the walk reads a branch's map, not just its name"
must "two.example.invalid — an install branch; its map states role 'slave'" \
  "the walk reads the second branch's map too"
must "not-an-install-branch — skipped: it carries no clusters/active/not-an-install-branch.yaml" \
  "a ref without a cluster map is skipped with the path it was looked for under"
must "0001-write-a-release-line.sh: wrote release: 0.0.9-planted" \
  "the migration reports what it did on the branch that needed it"
must "nothing to do — a release line already stands" \
  "the innocent branch is reported as looked at, with the reason nothing was done"
must "NOT pushed" "a report run says out loud that its commits were discarded"
ok "a report run walks every ref, says why it skips, and leaves the remote byte-identical"

# ── 2. a write run applies, records on the branch, and pushes ──────────────
run --write
[ "$RC" = "0" ] || fail "the write run ended red: ${OUT}"
must "pushed 1 commit(s) to origin/one.example.invalid" "the changed branch was pushed"
must "pushed 1 commit(s) to origin/two.example.invalid" "the record-only branch was pushed too"

AFTERMAP="$(show_origin one.example.invalid:clusters/active/one.example.invalid.yaml)"
[ "$(grep -cE '^release:' <<< "$AFTERMAP")" = "1" ] \
  || fail "branch one's map does not carry exactly one release line"
AFTERBOOKS="$(awk '{ if (prev ~ /^booksCluster:/) { print; exit } prev=$0 }' <<< "$AFTERMAP")"
[ "$AFTERBOOKS" = "release: 0.0.9-planted" ] \
  || fail "the release line does not stand after the booksCluster line (found: '${AFTERBOOKS}')"
grep -vxF 'release: 0.0.9-planted' <<< "$AFTERMAP" > "$WORK/one-map-after-minus"
diff -u "$WORK/one-map-before" "$WORK/one-map-after-minus" > /dev/null \
  || fail "the migration touched bytes beside the one line it inserted — comments did not survive"
ok "the planted migration edited one line and every comment and blank line survived byte for byte"

[ "$(show_origin two.example.invalid:clusters/active/two.example.invalid.yaml)" = "$(cat "$WORK/two-map-before")" ] \
  || fail "the innocent branch's map changed although its release line already stood"
ok "the innocent branch was read and left untouched"

for BR in one.example.invalid two.example.invalid; do
  REC="$(show_origin "${BR}:installation/migrations")" \
    || fail "${BR} carries no installation/migrations after the write run"
  grep -qxF "0001-write-a-release-line.sh" <<< "$REC" \
    || fail "${BR}'s installation/migrations does not record 0001-write-a-release-line.sh"
done
[ "$(git --git-dir="$ORIGIN" log -1 --format=%s one.example.invalid)" = "Apply migration 0001-write-a-release-line" ] \
  || fail "branch one's commit does not name the migration it applied"
[ "$(git --git-dir="$ORIGIN" log -1 --format=%s two.example.invalid)" = "Record migration 0001-write-a-release-line as applied without effect" ] \
  || fail "branch two's commit does not say the migration ran without effect"
ok "both branches record the migration in installation/migrations, in commits that name it"

# ── 3. a second write run finds everything recorded and moves nothing ──────
BEFORE="$(refs_of_origin)"
run --write
[ "$RC" = "0" ] || fail "the second write run ended red: ${OUT}"
[ "$BEFORE" = "$(refs_of_origin)" ] || fail "a second write run moved the remote — the record did not hold"
must "every migration of this checkout is recorded in installation/migrations" \
  "an applied migration is reported as recorded, not re-run"
ok "applied once each: the second run reads the record and pushes nothing"

# ── 4. a failing migration ends the run red, recorded nowhere ──────────────
cat > "$USERCO/migrations/0002-fail-on-purpose.sh" <<'EOF'
#!/usr/bin/env bash
echo "planted failure: this migration refuses every branch"
exit 1
EOF
git -C "$USERCO" add migrations/0002-fail-on-purpose.sh
git -C "$USERCO" commit --quiet -m "Plant a failing migration"
BEFORE="$(refs_of_origin)"
run --write
[ "$RC" != "0" ] || fail "a failing migration did not end the run red"
must "0002-fail-on-purpose.sh: FAILED — planted failure" "the failure names the migration and its own words"
must "the run is RED" "the run's last word is red, not a green summary over a failure"
[ "$BEFORE" = "$(refs_of_origin)" ] || fail "a failed migration still moved the remote"
! show_origin one.example.invalid:installation/migrations | grep -q "^0002-" \
  || fail "a failed migration was recorded as applied"
ok "a failing migration is reported red, recorded nowhere, and pushes nothing"
git -C "$USERCO" rm --quiet migrations/0002-fail-on-purpose.sh
git -C "$USERCO" commit --quiet -m "Unplant the failing migration"

# ── 5. two migrations sharing a number are refused before any branch ───────
printf '#!/usr/bin/env bash\necho a\n' > "$USERCO/migrations/0003-first-of-a-pair.sh"
printf '#!/usr/bin/env bash\necho b\n' > "$USERCO/migrations/0003-second-of-a-pair.sh"
run
[ "$RC" != "0" ] || fail "two migrations sharing a number were not refused"
must "share the number 0003" "the refusal names the duplicated number"
must_not "an install branch" "the refusal came before any branch was read"
rm "$USERCO/migrations/0003-first-of-a-pair.sh" "$USERCO/migrations/0003-second-of-a-pair.sh"
ok "a duplicated number is refused before the walk begins"

# ── 6. a record from a newer trunk is named, not silently trusted ──────────
SCRATCH="$WORK/scratch"
git clone --quiet "$ORIGIN" "$SCRATCH"
git -C "$SCRATCH" checkout --quiet two.example.invalid
echo "0009-from-the-future.sh" >> "$SCRATCH/installation/migrations"
git -C "$SCRATCH" add installation/migrations
git -C "$SCRATCH" commit --quiet -m "Record a migration this test's checkout never carried"
git -C "$SCRATCH" push --quiet origin two.example.invalid
run
[ "$RC" = "0" ] || fail "a record line without a script here ended the run red: ${OUT}"
must "records 0009-from-the-future.sh, which this checkout does not carry" \
  "a record from a newer trunk is reported as the checkout being behind"
ok "a record line with no script behind it is named as the checkout being behind"

# ── 7. an uncommitted migration is refused a write run ─────────────────────
printf '#!/usr/bin/env bash\necho "planted draft does nothing"\n' > "$USERCO/migrations/0004-draft.sh"
run --write
[ "$RC" != "0" ] || fail "an uncommitted migration was allowed to write"
must "uncommitted" "the refusal says what stands in the way"
run
[ "$RC" = "0" ] || fail "an uncommitted migration blocked even a report run: ${OUT}"
rm "$USERCO/migrations/0004-draft.sh"
ok "a write run takes only committed migrations; a report run may carry a draft"

echo "test: GREEN — 7 checks, each with its planted defect and its planted innocent."
echo "test: covered — the walk and its skip reasons, the report run's refusal to push, the"
echo "test:   write run's apply/record/push, the record holding on a second run, a failing"
echo "test:   migration ending red and unrecorded, a duplicated number refused before the"
echo "test:   walk, a record from a newer trunk named as such, and an uncommitted migration"
echo "test:   refused a write run."
echo "test: not covered — an authenticated remote, two runs racing on one branch, and a"
echo "test:   migration that reaches outside the clone it is handed."
