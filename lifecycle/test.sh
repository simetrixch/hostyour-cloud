#!/usr/bin/env bash
# ===========================================================================
# test.sh — proves the delivery tooling does what it says, against fixtures it
# builds in a temporary directory.
#
#   bash lifecycle/test.sh
#
# THREE ACTS DELIVER A CHANGE TO A RUNNING INSTALLATION and this file measures
# all three: release-platform cuts a release of the platform tree and pins ONE
# installation to it, regenerate-install-branch brings that installation's branch
# onto the pin, and migrate-install-branches corrects what is born on install
# branches and reachable by neither of the other two. status answers what each
# installation stands on. Every one of them is written twice, in bash and in
# PowerShell, and the two spellings are held to printing the same bytes.
#
# WHY TWO ORIGINS PER FIXTURE. release-platform MINTS and a mint pushes; a
# migration write run PUSHES. Run against one origin the second spelling would
# find the first's work and take a different path, so the two would be compared
# on different work. Each spelling gets its own origin, cloned from the same seed
# so every commit id is the same on both sides, and the two things that
# legitimately differ — the fourteen digits of a mint stamp and which of the two
# origins a report names — are normalised away before the comparison.
#
# WHAT IS COMPARED. Standard output, standard error and the exit code, for every
# path a person can reach: the mint and the pin, the reuse of a tag that already
# stands, the four release refusals, the four states a report can be in, the six
# refusals a regeneration makes before it touches a machine, and the seven states
# a migration walk can be in.
#
# THE PLANTED DEFECTS. A copy of status.sh with one printed line changed is run
# against the untouched status.ps1, and a copy of regenerate-install-branch.sh
# with one printed line changed against the untouched .ps1. Both comparisons must
# go RED. Without them a green run would only prove that the comparisons found
# nothing, which is also what a comparison that stopped looking prints. The
# innocent beside them is every other case here, which must stay green. The
# migration walk carries a planted defect and a planted innocent of its own in
# every one of its checks.
#
# WHAT THIS FILE CANNOT PROVE, named rather than counted: an authenticated remote
# (the fixtures' origins are directories, so a push never asks for a credential),
# two workstations minting the same version and channel at the same moment, two
# migration runs racing on one branch, a migration that reaches outside the clone
# it is handed, and the regeneration itself — that runs on a machine, out of the
# catalogue repository, and nothing here can stand in for it. Nor the config
# guards of regenerate-install-branch beyond the file's absence: Windows states a
# file's reach as an access list and every other system as a mode, so the two
# spellings ask one question and can only answer it in their own words.
# ===========================================================================
set -euo pipefail

fail() { echo "test: RED — $*" >&2; exit 1; }
ok() { echo "test: ok — $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ONE PATH SHAPE BOTH SPELLINGS RESOLVE. On Windows this bash is an MSYS one and
# says /tmp/... and /d/repos/..., which the PowerShell side and the git it starts
# resolve to nothing at all — a fixture the second spelling cannot open is a
# comparison that is red about the wrong thing. cygpath -m gives the drive-letter
# form with forward slashes, which this bash, PowerShell and both gits all read.
if command -v cygpath >/dev/null 2>&1; then
  HERE="$(cygpath -m "$HERE")"
  WORK="$(cygpath -m "$WORK")"
fi

PWSH="$(command -v pwsh || true)"
[ -n "$PWSH" ] || fail 'pwsh is not on this path, and half of what this measures is written in it'

# Commits of the fixtures and of the scripts' own throwaway clones both need an
# identity, and the machine's own must not leak into a test. The dates are fixed
# so the two origins carry the same commit ids and a comparison cannot pass or
# fail on a clock.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_AUTHOR_DATE='2026-01-01T00:00:00+0000'
export GIT_COMMITTER_DATE='2026-01-01T00:00:00+0000'

OUT="$WORK/out"
mkdir -p "$OUT"

# ── running one spelling of one script, and comparing the pair ──────────────
# The fourteen digits of a mint stamp are by construction different in two runs,
# and a migration report names the origin it walked, which is a different
# directory per spelling. Those two are the ONLY things allowed to differ, so
# they are normalised on both sides.
#
# WRITTEN HERE RATHER THAN SHELLED OUT TO, because the filter that normalises is
# as much part of the measurement as the comparison is. sed on Windows reads its
# input as text and DROPS a carriage return, which would hide the difference the
# two spellings are likeliest to have: a PowerShell that ends its lines the way
# the running system does prints two bytes where bash prints one. A normaliser
# that quietly removed that would leave a comparison which cannot go red for it.
normalise() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    while [[ "$line" =~ ([0-9]{14}) ]]; do line="${line//${BASH_REMATCH[1]}/TS14}"; done
    line="${line//origin-ma.git/ORIGIN.git}"
    line="${line//origin-mb.git/ORIGIN.git}"
    printf '%s\n' "$line"
  done
}
printf 'x\r\n' > "$OUT/probe.in"
normalise < "$OUT/probe.in" > "$OUT/probe.out"
[ "$(tr -cd '\r' < "$OUT/probe.out" | wc -c)" = '1' ] \
  || fail 'the normaliser drops a carriage return, so the comparison below could not see one'
[ "$(cat "$OUT/probe.out" | tr -d '\r')" = 'x' ] \
  || fail 'the normaliser changed a line it had no stamp to replace in'
ok 'the normaliser keeps a carriage return, so a line ending is something the comparison can see'

A_CODE=0
B_CODE=0
same() { # what was being checked
  local label="$1"
  normalise < "$OUT/a.out" > "$OUT/a.out.n"; normalise < "$OUT/b.out" > "$OUT/b.out.n"
  normalise < "$OUT/a.err" > "$OUT/a.err.n"; normalise < "$OUT/b.err" > "$OUT/b.err.n"
  diff -u "$OUT/a.out.n" "$OUT/b.out.n" || fail "$label — the two spellings printed different output"
  diff -u "$OUT/a.err.n" "$OUT/b.err.n" || fail "$label — the two spellings said different things when refusing"
  [ "$A_CODE" = "$B_CODE" ] \
    || fail "$label — the two spellings ended differently: bash $A_CODE, powershell $B_CODE"
  ok "$label — identical on both spellings, exit $A_CODE"
}
# THE EXIT CODE ALONE, for the one refusal whose words cannot match: each
# spelling's usage line names the file a person would type, which is its own.
same_code() {
  local label="$1"
  [ "$A_CODE" = "$B_CODE" ] \
    || fail "$label — the two spellings ended differently: bash $A_CODE, powershell $B_CODE"
  ok "$label — both spellings refused with exit $A_CODE"
}
must() { # a line the output has to carry
  grep -qF -- "$1" "$OUT/a.out" "$OUT/a.err" || fail "$2 — missing from the output: '$1'"
}
must_not() {
  grep -qF -- "$1" "$OUT/a.out" "$OUT/a.err" && fail "$2 — present in the output: '$1'"
  return 0
}

# ===========================================================================
# ONE — release-platform and status, against a fixture of two origins
# ===========================================================================
ORIGIN_A="$WORK/origin-a.git"
ORIGIN_B="$WORK/origin-b.git"
WORK_A="$WORK/checkout-a"
WORK_B="$WORK/checkout-b"

run_bash() { # script base name, then its arguments
  local base="$1"; shift
  A_CODE=0
  ( cd "$WORK_A" && bash "$HERE/$base.sh" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
run_pwsh() { # script base name, then its arguments
  local base="$1"; shift
  B_CODE=0
  ( cd "$WORK_B" && "$PWSH" -NoProfile -NoLogo -File "$HERE/$base.ps1" "$@" ) > "$OUT/b.out" 2> "$OUT/b.err" || B_CODE=$?
}

# ── the fixture: a trunk, three install branches, one other ref ─────────────
git init --quiet --bare --initial-branch=master "$ORIGIN_A"
SEED="$WORK/seed"
git init --quiet --initial-branch=master "$SEED"
git -C "$SEED" remote add origin "$ORIGIN_A"
mkdir -p "$SEED/clusters/argocd/apps" "$SEED/clusters/bootstrap/idp" \
         "$SEED/clusters/platform" "$SEED/clusters/active"
# The same byte rule the real tree carries, so the fixture's files are stored and
# checked out LF on every machine.
echo "* text=auto eol=lf" > "$SEED/.gitattributes"
# One file in each stamped tree, carrying a marker exactly as the trunk does, and
# one file outside them — so a commit that touches only the third proves the
# split in the report is real and not a count of everything.
echo "selector: __CLUSTER_ROLE_FIRST_PART__" > "$SEED/clusters/argocd/apps/platform-apps-appset.yaml"
echo "host: idp.example.invalid" > "$SEED/clusters/bootstrap/idp/values.yaml"
echo "platform: 0.0.0" > "$SEED/clusters/platform/versions.yaml"
touch "$SEED/clusters/active/.gitkeep"
git -C "$SEED" add -A
git -C "$SEED" commit --quiet -m "Seed the trunk"
git -C "$SEED" push --quiet origin master

# An install branch is a branch carrying its own cluster map. Three of them, one
# per state a report can be in, plus a ref that carries no map at all.
seed_installation() { # fqdn, stage, release line (empty for none)
  local fqdn="$1" stage="$2" release="$3"
  git -C "$SEED" checkout --quiet -b "$fqdn" master
  {
    echo "stage: $stage"
    echo "role: master"
    [ -n "$release" ] && echo "release: $release"
    echo ""
    echo "global:"
    echo "  domain: $fqdn"
  } > "$SEED/clusters/active/$fqdn.yaml"
  git -C "$SEED" add -- "clusters/active/$fqdn.yaml"
  git -C "$SEED" commit --quiet -m "Generate the branch of $fqdn"
  git -C "$SEED" push --quiet origin "$fqdn"
  git -C "$SEED" checkout --quiet master
}
seed_installation apps3.example.invalid dev ''
seed_installation apps5.example.invalid test '9.9.9-stable-19700101000000'
seed_installation apps9.example.invalid prod ''
git -C "$SEED" checkout --quiet -b work/no-map master
git -C "$SEED" push --quiet origin work/no-map
git -C "$SEED" checkout --quiet master

# The second origin is a copy of the first, so both sides start from the same
# commit ids and every number in a report is comparable.
git clone --quiet --bare "$ORIGIN_A" "$ORIGIN_B"
git clone --quiet "$ORIGIN_A" "$WORK_A"
git clone --quiet "$ORIGIN_B" "$WORK_B"
ok "fixture built — two origins, one trunk, three installations and one ref that is none"

# ── the refusals, which cost nothing and must leave nothing behind ──────────
run_bash release-platform 1.2 stable apps3.example.invalid
run_pwsh release-platform 1.2 stable apps3.example.invalid
must "version must be x.y.z" 'a version that is not three numbers is refused'
[ "$A_CODE" = '64' ] || fail "a malformed version must end the run with 64, got $A_CODE"
same 'a version that is not three numbers'

run_bash release-platform 0.1.0 golden apps3.example.invalid
run_pwsh release-platform 0.1.0 golden apps3.example.invalid
must "channel must be stable, beta or alpha" 'an unknown channel is refused'
same 'a channel outside the three'

run_bash release-platform 0.1.0 stable nosuch.example.invalid
run_pwsh release-platform 0.1.0 stable nosuch.example.invalid
must "origin has no branch nosuch.example.invalid" 'a domain with no install branch is refused'
same 'a domain that names no install branch'

run_bash release-platform 0.1.0 alpha apps9.example.invalid
run_pwsh release-platform 0.1.0 alpha apps9.example.invalid
must "channel alpha admits only: dev" 'the channel ceiling refuses a prod installation'
same 'an alpha release aimed at a prod installation'

# NOTHING WAS MINTED BY ANY OF THAT. The refusals above all stand before the
# mint, which is the whole reason the order is what it is.
[ -z "$(git --git-dir="$ORIGIN_A" tag -l)" ] || fail 'a refused run left a tag on origin A'
[ -z "$(git --git-dir="$ORIGIN_B" tag -l)" ] || fail 'a refused run left a tag on origin B'
ok 'four refusals, and neither origin carries a tag — nothing is created before the target is known good'

# ── the mint and the pin ────────────────────────────────────────────────────
run_bash release-platform 0.1.0 alpha apps3.example.invalid
run_pwsh release-platform 0.1.0 alpha apps3.example.invalid
must "release: minted 0.1.0-alpha-" 'the first run mints'
must "release: the tag stands on the remote" 'the tag is read back off the remote before anything is pinned'
must "release: pinned apps3.example.invalid to 0.1.0-alpha-" 'the pin is written'
must "bash lifecycle/regenerate-install-branch.sh apps3.example.invalid" \
     'the second act is named, as the script that performs it'
must_not "ansiwise regenerate-branch" 'the second act is a script beside this one, not a command to retype'
same 'the mint and the pin'

TAG_A="$(git --git-dir="$ORIGIN_A" tag -l)"
TAG_B="$(git --git-dir="$ORIGIN_B" tag -l)"
[ -n "$TAG_A" ] && [ -n "$TAG_B" ] || fail 'the mint pushed no tag to one of the origins'
[ "$(printf '%s\n' "$TAG_A" | wc -l)" = '1' ] || fail "origin A carries more than one tag: $TAG_A"
ok "each origin carries exactly one tag — A $TAG_A, B $TAG_B"

# THE PIN IS ONE LINE AT COLUMN ONE, and the map is otherwise as it was: the
# grammar the catalogue's own writing step uses, so a map written by either hand
# reads the same to whatever reads it next.
PINNED="$(git --git-dir="$ORIGIN_A" show "apps3.example.invalid:clusters/active/apps3.example.invalid.yaml")"
[ "$(grep -c '^release: ' <<< "$PINNED")" = '1' ] || fail 'the map does not carry exactly one top-level release line'
grep -q "^release: ${TAG_A}\$" <<< "$PINNED" || fail 'the release line does not carry the tag that was minted'
grep -q '^stage: dev$' <<< "$PINNED" || fail 'the pin disturbed the stage line'
grep -q '^  domain: apps3.example.invalid$' <<< "$PINNED" || fail 'the pin disturbed the global block'
ok 'the map carries one top-level release line and is otherwise untouched'

# ── the second run: the tag is reused and the pin is left as it stands ──────
run_bash release-platform 0.1.0 alpha apps3.example.invalid
run_pwsh release-platform 0.1.0 alpha apps3.example.invalid
must "release: reusing 0.1.0-alpha-" 'a second run for the same version and channel cuts nothing new'
must "already records" 'a pin that already says the right thing is left alone'
must_not "release: minted" 'a second run must not mint'
same 'the second run for the same version and channel'
[ "$(git --git-dir="$ORIGIN_A" tag -l | wc -l)" = '1' ] || fail 'the second run minted a second tag'
ok 'the second run left the one tag standing'

# ── the report, with the installation level ─────────────────────────────────
run_bash status
run_pwsh status
must "  level: origin/master carries nothing this release does not" 'a freshly pinned installation reports level'
must "  unpinned: nothing records which platform state" 'an installation with no release line reports unpinned'
must "  unresolved: nothing here resolves that to a commit" 'a pin naming a state this repository does not carry says so'
must_not "work/no-map" 'a branch carrying no cluster map is no installation and is not reported'
same 'the report with one installation level'

# ── the trunk moves, and the report says how far ────────────────────────────
advance_master() { # a checkout to commit in and push from
  local checkout="$1"
  echo "role: __CLUSTER_ROLE_LAST_PART__" >> "$checkout/clusters/argocd/apps/platform-apps-appset.yaml"
  git -C "$checkout" add -- clusters/argocd/apps/platform-apps-appset.yaml
  git -C "$checkout" commit --quiet -m "Move a file the branch programs stamp"
  echo "platform: 0.0.1" >> "$checkout/clusters/platform/versions.yaml"
  git -C "$checkout" add -- clusters/platform/versions.yaml
  git -C "$checkout" commit --quiet -m "Move a file nothing stamps"
  git -C "$checkout" push --quiet origin master
}
advance_master "$WORK_A"
advance_master "$WORK_B"

run_bash status
run_pwsh status
must "  behind: 2 commits on origin/master since that release, 1 of them under clusters/argocd or clusters/bootstrap" \
     'the report counts the commits since the pin and the stamped ones among them'
must "  stamped: clusters/argocd/apps/platform-apps-appset.yaml" 'the report names the stamped file that moved'
must_not "  stamped: clusters/platform/versions.yaml" 'a file outside the stamped trees is not reported as stamped'
same 'the report with the trunk two commits ahead'

# ── the report, narrowed to one installation ───────────────────────────────
run_bash status apps3.example.invalid
run_pwsh status apps3.example.invalid
must "apps3.example.invalid" 'the named installation is reported'
must_not "apps9.example.invalid" 'no other installation is reported'
same 'the report narrowed to one installation'

run_bash status nosuch.example.invalid
run_pwsh status nosuch.example.invalid
must "origin has no installation called nosuch.example.invalid" 'a name that is no installation is refused'
[ "$A_CODE" = '66' ] || fail "a name that is no installation must end the run with 66, got $A_CODE"
same 'a name that is no installation'

# ── the planted defect: the comparison has to be able to go red ─────────────
PLANTED="$WORK/planted-status.sh"
# The planted line is the one this whole answer exists for, and it is printed in
# the state the fixture now stands in — a defect planted on a line the fixture
# never reaches would prove that the probe is unreachable, not that it works.
sed 's/commits on origin\/master since that release/changes since that release/' \
  "$HERE/status.sh" > "$PLANTED"
grep -q 'changes since that release' "$PLANTED" || fail 'the planted line was not planted — the probe proves nothing'
A_CODE=0
( cd "$WORK_A" && bash "$PLANTED" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'behind: ' "$OUT/a.out" || fail 'the planted spelling printed no behind line — the probe was aimed at a line the fixture does not reach'
run_pwsh status
normalise < "$OUT/a.out" > "$OUT/a.out.n"; normalise < "$OUT/b.out" > "$OUT/b.out.n"
if diff -q "$OUT/a.out.n" "$OUT/b.out.n" >/dev/null; then
  fail 'a spelling with one line changed compared EQUAL to the other — the comparison above proves nothing'
fi
ok 'the planted defect was caught — the comparison of the release pair can go red'

# ===========================================================================
# TWO — regenerate-install-branch, on the fixture the release above pinned
#
# EVERY CASE HERE IS A REFUSAL, and that is what this can measure: the act
# itself opens a session to a machine, and there is no machine. What it proves is
# the half that stands before one is touched — that a branch, a map, a pin and a
# tag are asked of the remote first, and that both spellings refuse on the same
# one with the same words.
# ===========================================================================
NOCONFIG="$WORK/there-is-no-config.env"

run_bash regenerate-install-branch
run_pwsh regenerate-install-branch
must "usage: lifecycle/regenerate-install-branch.sh <fqdn>" 'a run naming no installation is refused'
[ "$A_CODE" = '64' ] || fail "a run naming no installation must end with 64, got $A_CODE"
same_code 'a run naming no installation'

run_bash regenerate-install-branch nosuch.example.invalid "$NOCONFIG"
run_pwsh regenerate-install-branch nosuch.example.invalid "$NOCONFIG"
must "origin has no branch nosuch.example.invalid" 'a domain with no install branch is refused'
must "Nothing has been changed" 'a refusal says that nothing has been changed'
[ "$A_CODE" = '66' ] || fail "a domain that names no install branch must end with 66, got $A_CODE"
same 'a domain that names no install branch'

run_bash regenerate-install-branch apps9.example.invalid "$NOCONFIG"
run_pwsh regenerate-install-branch apps9.example.invalid "$NOCONFIG"
must "carries no release line" 'an installation whose map records no pin is refused'
must "release-platform" 'the refusal names the act that writes that line'
[ "$A_CODE" = '65' ] || fail "a map with no release line must end with 65, got $A_CODE"
same 'an installation whose map carries no release line'

run_bash regenerate-install-branch apps5.example.invalid "$NOCONFIG"
run_pwsh regenerate-install-branch apps5.example.invalid "$NOCONFIG"
must "origin carries no 9.9.9-stable-19700101000000" 'a pin naming a tag the remote does not carry is refused'
[ "$A_CODE" = '69' ] || fail "a pin the remote cannot resolve must end with 69, got $A_CODE"
same 'a pin naming a tag that is not on the remote'

# THE PIN IS READ OFF THE BRANCH AND SAID OUT LOUD, which is the whole of what
# this act is told: the ref is nobody's to type. The run then stops on the config,
# before a session is opened, so the line above it is measured without a machine.
run_bash regenerate-install-branch apps3.example.invalid "$NOCONFIG"
run_pwsh regenerate-install-branch apps3.example.invalid "$NOCONFIG"
must "regenerate: apps3.example.invalid is pinned to 0.1.0-alpha-" 'the pin is read off the branch and named'
must "there is no config at" 'a run with no config to state the installation is refused'
[ "$A_CODE" = '66' ] || fail "a missing config must end with 66, got $A_CODE"
same 'the pin read off the branch, and a missing config'

# THE DRIVER IS WHAT RUNS ON THE MACHINE, and a launcher without it can start
# nothing. Both spellings are copied where it is not, so both look for it beside
# themselves and find nothing.
mkdir -p "$WORK/driverless"
cp "$HERE/regenerate-install-branch.sh" "$HERE/regenerate-install-branch.ps1" "$WORK/driverless/"
A_CODE=0
( cd "$WORK_A" && bash "$WORK/driverless/regenerate-install-branch.sh" apps3.example.invalid ) \
  > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
B_CODE=0
( cd "$WORK_B" && "$PWSH" -NoProfile -NoLogo -File "$WORK/driverless/regenerate-install-branch.ps1" apps3.example.invalid ) \
  > "$OUT/b.out" 2> "$OUT/b.err" || B_CODE=$?
must "regenerate-driver.sh is not beside this file" 'a launcher without its driver is refused'
[ "$A_CODE" = '66' ] || fail "a missing driver must end with 66, got $A_CODE"
same 'a launcher standing without its driver'

# ── the planted defect for this pair ────────────────────────────────────────
PLANTED_R="$WORK/planted-regenerate.sh"
cp "$HERE/regenerate-driver.sh" "$WORK/regenerate-driver.sh"
sed 's/is pinned to/is pinned at/' "$HERE/regenerate-install-branch.sh" > "$PLANTED_R"
grep -q 'is pinned at' "$PLANTED_R" || fail 'the planted line was not planted — the probe proves nothing'
A_CODE=0
( cd "$WORK_A" && bash "$PLANTED_R" apps3.example.invalid "$NOCONFIG" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'is pinned at' "$OUT/a.out" || fail 'the planted spelling printed no pin line — the probe was aimed at a line the fixture does not reach'
run_pwsh regenerate-install-branch apps3.example.invalid "$NOCONFIG"
normalise < "$OUT/a.out" > "$OUT/a.out.n"; normalise < "$OUT/b.out" > "$OUT/b.out.n"
if diff -q "$OUT/a.out.n" "$OUT/b.out.n" >/dev/null; then
  fail 'a spelling with one line changed compared EQUAL to the other — the comparison above proves nothing'
fi
ok 'the planted defect was caught — the comparison of the regenerate pair can go red'

# ===========================================================================
# THREE — migrate-install-branches, against a fixture of its own
#
# Every check here carries a planted defect of the shape it is meant to catch
# and a planted innocent beside it, so a green run means the checks looked and
# found order — not that nothing was looking. The planted MIGRATION is shaped
# like the first real candidate this mechanism was designed around (writing a
# release line into a cluster map that lost its writer), planted here rather
# than shipped, because no real migration is needed today.
# ===========================================================================
ORIGIN_MA="$WORK/origin-ma.git"
ORIGIN_MB="$WORK/origin-mb.git"
USERCO_A="$WORK/user-a"
USERCO_B="$WORK/user-b"

git init --quiet --bare --initial-branch=master "$ORIGIN_MA"

show_origin() { git --git-dir="$1" show "$2"; }
refs_of_origin() { git ls-remote "$1" | LC_ALL=C sort; }

# ── the fixture: a trunk, two install branches, one other ref ──────────────
MSEED="$WORK/mseed"
git init --quiet --initial-branch=master "$MSEED"
git -C "$MSEED" remote add origin "$ORIGIN_MA"
mkdir -p "$MSEED/lifecycle/migrations" "$MSEED/clusters/active"
# The same byte rule the real tree carries, so the fixture's files are stored
# and checked out LF on every machine, exactly as the files a migration edits.
echo "* text=auto eol=lf" > "$MSEED/.gitattributes"
# BOTH SPELLINGS STAND IN THE FIXTURE, because each asks the checkout it walks
# from whether it is the platform tree, and the answer is the bash spelling
# standing at lifecycle/. The runs below start the real files beside this test.
cp "$HERE/migrate-install-branches.sh" "$MSEED/lifecycle/migrate-install-branches.sh"
cp "$HERE/migrate-install-branches.ps1" "$MSEED/lifecycle/migrate-install-branches.ps1"
touch "$MSEED/lifecycle/migrations/.gitkeep"
touch "$MSEED/clusters/active/.gitkeep"
git -C "$MSEED" add -A
git -C "$MSEED" commit --quiet -m "Seed the trunk"
git -C "$MSEED" push --quiet origin master

# Branch one: role master, no release line — the branch the planted migration
# has work on. Its comments and blank line are the probe that a line edit
# leaves every other byte alone.
git -C "$MSEED" checkout --quiet -b one.example.invalid
cat > "$MSEED/clusters/active/one.example.invalid.yaml" <<'EOF'
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
cp "$MSEED/clusters/active/one.example.invalid.yaml" "$WORK/one-map-before"
git -C "$MSEED" add -A
git -C "$MSEED" commit --quiet -m "Cut the first install branch"
git -C "$MSEED" push --quiet origin one.example.invalid

# Branch two: role slave, release line already standing — the innocent the
# migration must leave alone while still recording that it looked.
git -C "$MSEED" checkout --quiet master
git -C "$MSEED" checkout --quiet -b two.example.invalid
cat > "$MSEED/clusters/active/two.example.invalid.yaml" <<'EOF'
stage: dev
role: slave
booksCluster: one.example.invalid
release: 0.0.9-already
global:
  domain: two.example.invalid
EOF
cp "$MSEED/clusters/active/two.example.invalid.yaml" "$WORK/two-map-before"
git -C "$MSEED" add -A
git -C "$MSEED" commit --quiet -m "Cut the second install branch"
git -C "$MSEED" push --quiet origin two.example.invalid

# A ref that is NOT an install branch — the planted defect of the shape "a
# ref the walk must skip out loud", because it carries no cluster map.
git -C "$MSEED" checkout --quiet master
git -C "$MSEED" checkout --quiet -b not-an-install-branch
echo "not a cluster" > "$MSEED/notes.txt"
git -C "$MSEED" add -A
git -C "$MSEED" commit --quiet -m "A branch of some other kind"
git -C "$MSEED" push --quiet origin not-an-install-branch

# One origin per spelling, for the reason the release fixture has two: a write
# run pushes, and a second spelling walking the first's result would be compared
# on work the first had already done.
git clone --quiet --bare "$ORIGIN_MA" "$ORIGIN_MB"

# ── the person's checkout, one per spelling, with the same planted migration ─
git clone --quiet "$ORIGIN_MA" "$USERCO_A"
git clone --quiet "$ORIGIN_MB" "$USERCO_B"
for CO in "$USERCO_A" "$USERCO_B"; do
  cat > "$CO/lifecycle/migrations/0001-write-a-release-line.sh" <<'EOF'
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
  git -C "$CO" add lifecycle/migrations/0001-write-a-release-line.sh
  git -C "$CO" commit --quiet -m "Plant the first migration"
done

run_migrate_bash() { # the arguments of the bash spelling
  A_CODE=0
  ( cd "$USERCO_A" && bash "$HERE/migrate-install-branches.sh" "$@" ) \
    > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
run_migrate_pwsh() { # the arguments of the PowerShell spelling
  B_CODE=0
  ( cd "$USERCO_B" && "$PWSH" -NoProfile -NoLogo -File "$HERE/migrate-install-branches.ps1" "$@" ) \
    > "$OUT/b.out" 2> "$OUT/b.err" || B_CODE=$?
}

# ── 1. a report run looks at everything and writes nothing ─────────────────
BEFORE_A="$(refs_of_origin "$ORIGIN_MA")"
BEFORE_B="$(refs_of_origin "$ORIGIN_MB")"
run_migrate_bash
run_migrate_pwsh
[ "$A_CODE" = "0" ] || fail "the report run ended red: $(cat "$OUT/a.err")"
[ "$BEFORE_A" = "$(refs_of_origin "$ORIGIN_MA")" ] || fail "a run without --write moved origin A"
[ "$BEFORE_B" = "$(refs_of_origin "$ORIGIN_MB")" ] || fail "a run without --write moved origin B"
must "one.example.invalid - an install branch; its map states role 'master' and booksCluster 'one.example.invalid'" \
  "the walk reads a branch's map, not just its name"
must "two.example.invalid - an install branch; its map states role 'slave'" \
  "the walk reads the second branch's map too"
must "not-an-install-branch - skipped: it carries no clusters/active/not-an-install-branch.yaml" \
  "a ref without a cluster map is skipped with the path it was looked for under"
must "0001-write-a-release-line.sh: wrote release: 0.0.9-planted" \
  "the migration reports what it did on the branch that needed it"
must "nothing to do - a release line already stands" \
  "the innocent branch is reported as looked at, with the reason nothing was done"
must "NOT pushed" "a report run says out loud that its commits were discarded"
same 'a report run, which walks every ref and leaves both remotes byte-identical'

# ── 2. a write run applies, records on the branch, and pushes ──────────────
run_migrate_bash --write
run_migrate_pwsh -Write
[ "$A_CODE" = "0" ] || fail "the write run ended red: $(cat "$OUT/a.err")"
must "pushed 1 commit(s) to origin/one.example.invalid" "the changed branch was pushed"
must "pushed 1 commit(s) to origin/two.example.invalid" "the record-only branch was pushed too"
same 'a write run, which applies, records and pushes'

# WHAT EACH ORIGIN NOW CARRIES, asked of both: identical output proves the two
# spellings SAID the same, and this proves they DID the same.
what_the_write_left() { # an origin, and which spelling wrote it
  local origin="$1" spelling="$2" aftermap afterbooks rec
  aftermap="$(show_origin "$origin" one.example.invalid:clusters/active/one.example.invalid.yaml)"
  [ "$(grep -cE '^release:' <<< "$aftermap")" = "1" ] \
    || fail "$spelling: branch one's map does not carry exactly one release line"
  afterbooks="$(awk '{ if (prev ~ /^booksCluster:/) { print; exit } prev=$0 }' <<< "$aftermap")"
  [ "$afterbooks" = "release: 0.0.9-planted" ] \
    || fail "$spelling: the release line does not stand after the booksCluster line (found: '${afterbooks}')"
  grep -vxF 'release: 0.0.9-planted' <<< "$aftermap" > "$WORK/one-map-after-minus"
  diff -u "$WORK/one-map-before" "$WORK/one-map-after-minus" > /dev/null \
    || fail "$spelling: the migration touched bytes beside the one line it inserted — comments did not survive"

  [ "$(show_origin "$origin" two.example.invalid:clusters/active/two.example.invalid.yaml)" = "$(cat "$WORK/two-map-before")" ] \
    || fail "$spelling: the innocent branch's map changed although its release line already stood"

  for BR in one.example.invalid two.example.invalid; do
    rec="$(show_origin "$origin" "${BR}:installation/migrations")" \
      || fail "$spelling: ${BR} carries no installation/migrations after the write run"
    grep -qxF "0001-write-a-release-line.sh" <<< "$rec" \
      || fail "$spelling: ${BR}'s installation/migrations does not record 0001-write-a-release-line.sh"
  done
  [ "$(git --git-dir="$origin" log -1 --format=%s one.example.invalid)" = "Apply migration 0001-write-a-release-line" ] \
    || fail "$spelling: branch one's commit does not name the migration it applied"
  [ "$(git --git-dir="$origin" log -1 --format=%s two.example.invalid)" = "Record migration 0001-write-a-release-line as applied without effect" ] \
    || fail "$spelling: branch two's commit does not say the migration ran without effect"
}
what_the_write_left "$ORIGIN_MA" 'bash'
what_the_write_left "$ORIGIN_MB" 'powershell'
ok 'both spellings edited one line, left every comment and blank line byte for byte, and recorded the migration in commits that name it'

# ── 3. a second write run finds everything recorded and moves nothing ──────
BEFORE_A="$(refs_of_origin "$ORIGIN_MA")"
BEFORE_B="$(refs_of_origin "$ORIGIN_MB")"
run_migrate_bash --write
run_migrate_pwsh -Write
[ "$A_CODE" = "0" ] || fail "the second write run ended red: $(cat "$OUT/a.err")"
[ "$BEFORE_A" = "$(refs_of_origin "$ORIGIN_MA")" ] || fail "a second write run moved origin A — the record did not hold"
[ "$BEFORE_B" = "$(refs_of_origin "$ORIGIN_MB")" ] || fail "a second write run moved origin B — the record did not hold"
must "every migration of this checkout is recorded in installation/migrations" \
  "an applied migration is reported as recorded, not re-run"
same 'a second write run, which reads the record and pushes nothing'

# ── 4. a failing migration ends the run red, recorded nowhere ──────────────
for CO in "$USERCO_A" "$USERCO_B"; do
  cat > "$CO/lifecycle/migrations/0002-fail-on-purpose.sh" <<'EOF'
#!/usr/bin/env bash
echo "planted failure: this migration refuses every branch"
exit 1
EOF
  git -C "$CO" add lifecycle/migrations/0002-fail-on-purpose.sh
  git -C "$CO" commit --quiet -m "Plant a failing migration"
done
BEFORE_A="$(refs_of_origin "$ORIGIN_MA")"
BEFORE_B="$(refs_of_origin "$ORIGIN_MB")"
run_migrate_bash --write
run_migrate_pwsh -Write
[ "$A_CODE" != "0" ] || fail "a failing migration did not end the run red"
must "0002-fail-on-purpose.sh: FAILED - planted failure" "the failure names the migration and its own words"
must "the run is RED" "the run's last word is red, not a green summary over a failure"
[ "$BEFORE_A" = "$(refs_of_origin "$ORIGIN_MA")" ] || fail "a failed migration still moved origin A"
[ "$BEFORE_B" = "$(refs_of_origin "$ORIGIN_MB")" ] || fail "a failed migration still moved origin B"
show_origin "$ORIGIN_MA" one.example.invalid:installation/migrations | grep -q "^0002-" \
  && fail "a failed migration was recorded as applied on origin A"
show_origin "$ORIGIN_MB" one.example.invalid:installation/migrations | grep -q "^0002-" \
  && fail "a failed migration was recorded as applied on origin B"
same 'a failing migration, reported red, recorded nowhere and pushing nothing'
for CO in "$USERCO_A" "$USERCO_B"; do
  git -C "$CO" rm --quiet lifecycle/migrations/0002-fail-on-purpose.sh
  git -C "$CO" commit --quiet -m "Unplant the failing migration"
done

# ── 5. two migrations sharing a number are refused before any branch ───────
for CO in "$USERCO_A" "$USERCO_B"; do
  printf '#!/usr/bin/env bash\necho a\n' > "$CO/lifecycle/migrations/0003-first-of-a-pair.sh"
  printf '#!/usr/bin/env bash\necho b\n' > "$CO/lifecycle/migrations/0003-second-of-a-pair.sh"
done
run_migrate_bash
run_migrate_pwsh
[ "$A_CODE" != "0" ] || fail "two migrations sharing a number were not refused"
must "share the number 0003" "the refusal names the duplicated number"
must_not "an install branch" "the refusal came before any branch was read"
same 'a duplicated number, refused before the walk begins'
for CO in "$USERCO_A" "$USERCO_B"; do
  rm "$CO/lifecycle/migrations/0003-first-of-a-pair.sh" "$CO/lifecycle/migrations/0003-second-of-a-pair.sh"
done

# ── 6. a record from a newer trunk is named, not silently trusted ──────────
scratch_a_record_from_the_future() { # an origin
  local origin="$1" scratch="$WORK/scratch-$RANDOM"
  git clone --quiet "$origin" "$scratch"
  git -C "$scratch" checkout --quiet two.example.invalid
  echo "0009-from-the-future.sh" >> "$scratch/installation/migrations"
  git -C "$scratch" add installation/migrations
  git -C "$scratch" commit --quiet -m "Record a migration this test's checkout never carried"
  git -C "$scratch" push --quiet origin two.example.invalid
  rm -rf "$scratch"
}
scratch_a_record_from_the_future "$ORIGIN_MA"
scratch_a_record_from_the_future "$ORIGIN_MB"
run_migrate_bash
run_migrate_pwsh
[ "$A_CODE" = "0" ] || fail "a record line without a script here ended the run red: $(cat "$OUT/a.err")"
must "records 0009-from-the-future.sh, which this checkout does not carry" \
  "a record from a newer trunk is reported as the checkout being behind"
same 'a record line with no script behind it, named as the checkout being behind'

# ── 7. an uncommitted migration is refused a write run ─────────────────────
for CO in "$USERCO_A" "$USERCO_B"; do
  printf '#!/usr/bin/env bash\necho "planted draft does nothing"\n' > "$CO/lifecycle/migrations/0004-draft.sh"
done
run_migrate_bash --write
run_migrate_pwsh -Write
[ "$A_CODE" != "0" ] || fail "an uncommitted migration was allowed to write"
must "uncommitted" "the refusal says what stands in the way"
same 'an uncommitted migration, refused a write run'
run_migrate_bash
run_migrate_pwsh
[ "$A_CODE" = "0" ] || fail "an uncommitted migration blocked even a report run: $(cat "$OUT/a.err")"
same 'a report run, which may carry a draft'
for CO in "$USERCO_A" "$USERCO_B"; do
  rm "$CO/lifecycle/migrations/0004-draft.sh"
done

echo "test: GREEN — every case above was measured on both spellings and answered identically."
echo "test: covered — the four release refusals, the mint, the pin, the reuse of a standing"
echo "test:   tag, the four states a report can be in and a name that is no installation; the"
echo "test:   six refusals a regeneration makes before it touches a machine, the pin it reads"
echo "test:   off the branch, and a launcher without its driver; the migration walk and its"
echo "test:   skip reasons, the report run's refusal to push, the write run's"
echo "test:   apply/record/push, the record holding on a second run, a failing migration"
echo "test:   ending red and unrecorded, a duplicated number refused before the walk, a record"
echo "test:   from a newer trunk named as such, and an uncommitted migration refused a write"
echo "test:   run. Two planted defects prove the comparison can go red."
echo "test: not covered — an authenticated remote, two workstations minting at one moment, two"
echo "test:   migration runs racing on one branch, a migration that reaches outside the clone"
echo "test:   it is handed, the regeneration itself on a machine, and the config guards beyond"
echo "test:   the file's absence."
