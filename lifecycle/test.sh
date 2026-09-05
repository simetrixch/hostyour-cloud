#!/usr/bin/env bash
# ===========================================================================
# test.sh — proves the delivery tooling does what it says, against fixtures it
# builds in a temporary directory.
#
#   bash lifecycle/test.sh
#
# TWO ACTS DELIVER A CHANGE TO A RUNNING INSTALLATION and this file measures
# both: release-platform cuts a release of the platform tree and pins ONE
# installation to it, and regenerate-install-branch brings that installation's
# branch onto the pin. status answers what each installation stands on.
# remove-slave-from-master is neither: it takes one slave's registration off the
# master it stands on, which is the only act here whose subject is a relation
# between two installations. Every one of them is written twice, in bash and in
# PowerShell, and the two spellings are held to printing the same bytes.
#
# WHY TWO ORIGINS PER FIXTURE. release-platform MINTS and a mint pushes. Run
# against one origin the second spelling would find the first's work and take a
# different path, so the two would be compared on different work. Each spelling
# gets its own origin, cloned from the same seed so every commit id is the same
# on both sides, and the one thing that legitimately differs — the fourteen
# digits of a mint stamp — is normalised away before the comparison.
#
# WHAT IS COMPARED. Standard output, standard error and the exit code, for every
# path a person can reach: the mint and the pin, the reuse of a tag that already
# stands, the four release refusals, the four states a report can be in, and the
# six refusals a regeneration makes before it touches a machine.
#
# THE PLANTED DEFECTS. A copy of status.sh with one printed line changed is run
# against the untouched status.ps1, a copy of regenerate-install-branch.sh with
# one printed line changed against the untouched .ps1, and a copy of
# remove-slave-from-master.sh likewise. All three comparisons must go RED.
# Without them a green run would only prove that the comparisons found nothing,
# which is also what a comparison that stopped looking prints. The innocent
# beside them is every other case here, which must stay green.
#
# WHAT THIS FILE CANNOT PROVE, named rather than counted: an authenticated remote
# (the fixtures' origins are directories, so a push never asks for a credential),
# two workstations minting the same version and channel at the same moment, and
# the regeneration and the removal themselves — those run on a
# machine, out of the catalogue repository, and nothing here can stand in for
# them. Nor a slave that is still ANSWERING, which is what
# remove-slave-from-master refuses on: a fixture cannot make a machine listen on
# port 22, so what is measured is the other verdict, that the slave is gone.
#
# NOR THE OWNER-ONLY GUARD ON A CONFIG, in either act that has one: Windows
# states a file's reach as an access list and every other system as a mode, so
# the two spellings ask one question and can only answer it in their own words.
# The guard beside it — a config standing in a git working tree that does not
# ignore it — is refused in the SAME words by both, and that is the one the
# removal's fixture config trips, which is what lets a case run all the way to
# the slave being asked whether it answers.
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
# The fourteen digits of a mint stamp are by construction different in two runs.
# That is the ONLY thing allowed to differ, so it is normalised on both sides.
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
mkdir -p "$SEED/clusters/argocd/files" "$SEED/clusters/bootstrap/idp" \
         "$SEED/clusters/platform" "$SEED/clusters/active"
# The same byte rule the real tree carries, so the fixture's files are stored and
# checked out LF on every machine.
echo "* text=auto eol=lf" > "$SEED/.gitattributes"
# One file in each stamped tree, carrying a marker exactly as the trunk does, and
# one file outside them — so a commit that touches only the third proves the
# split in the report is real and not a count of everything.
echo "selector: __CLUSTER_ROLE_FIRST_PART__" > "$SEED/clusters/argocd/files/platform-apps-appset.yaml"
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
# The fourth exists so the mint cases at the end of this section have an installation
# nothing else reads: every one of the three above is load-bearing somewhere — apps3's
# pin, apps9's missing pin and apps5's unresolvable one are each asserted in TWO.
seed_installation apps4.example.invalid dev ''
git -C "$SEED" checkout --quiet -b work/no-map master
git -C "$SEED" push --quiet origin work/no-map
git -C "$SEED" checkout --quiet master

# The second origin is a copy of the first, so both sides start from the same
# commit ids and every number in a report is comparable.
git clone --quiet --bare "$ORIGIN_A" "$ORIGIN_B"
git clone --quiet "$ORIGIN_A" "$WORK_A"
git clone --quiet "$ORIGIN_B" "$WORK_B"
ok "fixture built — two origins, one trunk, four installations and one ref that is none"

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
  echo "role: __CLUSTER_ROLE_LAST_PART__" >> "$checkout/clusters/argocd/files/platform-apps-appset.yaml"
  git -C "$checkout" add -- clusters/argocd/files/platform-apps-appset.yaml
  git -C "$checkout" commit --quiet -m "Move a file only a regeneration carries"
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
must "  stamped: clusters/argocd/files/platform-apps-appset.yaml" 'the report names the stamped file that moved'
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

# ── a tag a refused push left behind is dropped, not reused ─────────────────
# THE STATE A REFUSED PUSH LEAVES. The tag is minted before it is pushed, so a
# push the hook refuses leaves it standing in the checkout and nowhere else,
# naming the commit it was minted for rather than the one a later run releases.
# Reusing it aims every retry at that same commit and is refused for the same
# reason — printed as if it were about the new attempt. Measured on a real
# workstation: three runs of one version refused in a row, cleared only by
# deleting the tag by hand.
STALE='0.2.0-alpha-19700101000000'
git -C "$WORK_A" tag -a "$STALE" -m 'left behind by a refused push' origin/apps4.example.invalid
git -C "$WORK_B" tag -a "$STALE" -m 'left behind by a refused push' origin/apps4.example.invalid
run_bash release-platform 0.2.0 alpha apps4.example.invalid
run_pwsh release-platform 0.2.0 alpha apps4.example.invalid
must "stands on this workstation only" 'the leftover is named as standing nowhere else'
must "it is dropped and cut again" 'and it is dropped rather than reused'
must "release: minted 0.2.0-alpha-" 'a fresh tag is cut in its place'
must_not "release: reusing $STALE" 'the leftover is never reused'
same 'a tag a refused push left behind'
[ -z "$(git -C "$WORK_A" tag -l "$STALE")" ] || fail 'the leftover tag still stands in the checkout'
[ "$(git --git-dir="$ORIGIN_A" tag -l '0.2.0-alpha-*' | wc -l)" = '1' ] \
  || fail 'origin A does not carry exactly one tag for the version that was cut again'
ok 'the leftover is gone from the checkout and origin carries exactly one tag for that version'

# ── a tag that never reached origin but names the released commit IS reused ──
# The other half of the same reading, and the half that keeps the fix from
# deleting too much: a run whose push was refused for a reason that has nothing
# to do with the tag is resumable, and re-minting there would cut a second tree
# for one release. What decides is not whether the tag was pushed but whether it
# names the commit being released.
RESUMABLE='0.3.0-alpha-19700101000000'
git -C "$WORK_A" tag -a "$RESUMABLE" -m 'minted, not yet pushed' origin/master
git -C "$WORK_B" tag -a "$RESUMABLE" -m 'minted, not yet pushed' origin/master
run_bash release-platform 0.3.0 alpha apps4.example.invalid
run_pwsh release-platform 0.3.0 alpha apps4.example.invalid
must "release: reusing $RESUMABLE" 'a leftover naming the released commit is reused as it stands'
must_not "is dropped and cut again" 'and nothing is dropped'
must_not "release: minted 0.3.0" 'and nothing is cut a second time'
same 'a tag that never reached origin but names the released commit'
[ -n "$(git --git-dir="$ORIGIN_A" tag -l "$RESUMABLE")" ] \
  || fail 'the reused tag never reached origin, so the run resumed nothing'
ok 'a leftover naming the released commit is reused and pushed, not cut again'

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
# THREE — remove-slave-from-master, against a fixture of its own
#
# EVERY CASE HERE IS A REFUSAL, for the reason every regeneration case above is
# one: the act itself opens a session to a master, and there is no master. What
# it proves is the half that stands before one is touched — that the master's
# branch, the map it keeps for the slave, what that map says the slave is, and
# whether the slave still answers are all asked first, and that both spellings
# refuse on the same one with the same words.
#
# ONE ORIGIN AND NOT TWO, unlike the fixtures above. This act reads the remote
# and never writes to it, so the second spelling finds nothing the first left
# behind and the two are compared on the same work. Each spelling gets its own
# CLONE, because a fetch writes FETCH_HEAD into the checkout it runs in.
# ===========================================================================
ORIGIN_S="$WORK/origin-s.git"
SLAVEWORK_A="$WORK/slave-a"
SLAVEWORK_B="$WORK/slave-b"

git init --quiet --bare --initial-branch=master "$ORIGIN_S"
SSEED="$WORK/sseed"
git init --quiet --initial-branch=master "$SSEED"
git -C "$SSEED" remote add origin "$ORIGIN_S"
mkdir -p "$SSEED/clusters/active"
echo "* text=auto eol=lf" > "$SSEED/.gitattributes"
touch "$SSEED/clusters/active/.gitkeep"
git -C "$SSEED" add -A
git -C "$SSEED" commit --quiet -m "Seed the trunk"
git -C "$SSEED" push --quiet origin master

# A cluster map as the catalogue's template writes one: the three top-level keys
# a reader outside Helm selects on, then the block a chart resolves through.
seed_map() { # fqdn, role, the cluster that keeps its books
  local fqdn="$1" role="$2" books="$3"
  {
    echo "stage: prod"
    echo "role: $role"
    echo "booksCluster: $books"
    echo ""
    echo "global:"
    echo "  domain: $fqdn"
    echo "  clusterName: ${fqdn%%.*}"
    echo "  booksCluster: $books"
  } > "$SSEED/clusters/active/$fqdn.yaml"
}

# THE MASTER'S OWN BRANCH IS WHERE THE BOOKS STAND, so every map below is on it:
# its own, one slave it keeps, one cluster that is no slave at all, and one slave
# whose books are somebody else's.
git -C "$SSEED" checkout --quiet -b apps6.example.invalid master
seed_map apps6.example.invalid master apps6.example.invalid
seed_map apps7.example.invalid slave apps6.example.invalid
seed_map apps8.example.invalid master apps8.example.invalid
seed_map apps9.example.invalid slave other.example.invalid
git -C "$SSEED" add -A
git -C "$SSEED" commit --quiet -m "Cut the master's branch with the maps it keeps"
git -C "$SSEED" push --quiet origin apps6.example.invalid
git -C "$SSEED" checkout --quiet master

git clone --quiet "$ORIGIN_S" "$SLAVEWORK_A"
git clone --quiet "$ORIGIN_S" "$SLAVEWORK_B"
ok "fixture built — one origin, a master's branch, the map of one slave it keeps and two that are not that"

# THE MASTER'S CONFIG, which this act is given and only reads. It states no
# credential worth the name and it stands INSIDE a git working tree that does not
# ignore it, which is deliberate: that is the last guard the launcher asks, it is
# refused in the same words by both spellings, and it is therefore where a case
# that has passed everything else can stop and still be compared.
MASTERCFG="$SLAVEWORK_A/master-config.env"
{
  echo "ELEVATION_PASSWORD='not-a-password'"
  echo "OPERATOR_USER='digi6'"
  echo "FQDN='apps6.example.invalid'"
  echo "STAGE='prod' #[dev, test, prod]"
} > "$MASTERCFG"
# The same file naming a master that has no branch on the remote.
NOBRANCHCFG="$SLAVEWORK_A/no-branch-config.env"
sed "s/^FQDN=.*/FQDN='nomaster.example.invalid'/" "$MASTERCFG" > "$NOBRANCHCFG"

run_remove_bash() { # the arguments of the bash spelling
  A_CODE=0
  ( cd "$SLAVEWORK_A" && bash "$HERE/remove-slave-from-master.sh" "$@" ) \
    > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
run_remove_pwsh() { # the arguments of the PowerShell spelling
  B_CODE=0
  ( cd "$SLAVEWORK_B" && "$PWSH" -NoProfile -NoLogo -File "$HERE/remove-slave-from-master.ps1" "$@" ) \
    > "$OUT/b.out" 2> "$OUT/b.err" || B_CODE=$?
}

run_remove_bash
run_remove_pwsh
must "usage: lifecycle/remove-slave-from-master.sh <slave-fqdn>" 'a run naming no slave is refused'
[ "$A_CODE" = '64' ] || fail "a run naming no slave must end with 64, got $A_CODE"
same_code 'a run naming no slave'

# THE DRIVER IS WHAT RUNS ON THE MACHINE, and a launcher without it can start
# nothing. Both spellings are copied where it is not, so both look for it beside
# themselves and find nothing.
mkdir -p "$WORK/slave-driverless"
cp "$HERE/remove-slave-from-master.sh" "$HERE/remove-slave-from-master.ps1" "$WORK/slave-driverless/"
A_CODE=0
( cd "$SLAVEWORK_A" && bash "$WORK/slave-driverless/remove-slave-from-master.sh" apps7.example.invalid ) \
  > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
B_CODE=0
( cd "$SLAVEWORK_B" && "$PWSH" -NoProfile -NoLogo -File "$WORK/slave-driverless/remove-slave-from-master.ps1" apps7.example.invalid ) \
  > "$OUT/b.out" 2> "$OUT/b.err" || B_CODE=$?
must "remove-slave-driver.sh is not beside this file" 'a launcher without its driver is refused'
[ "$A_CODE" = '66' ] || fail "a missing driver must end with 66, got $A_CODE"
same 'a launcher standing without its driver'

run_remove_bash apps7.example.invalid "$NOCONFIG"
run_remove_pwsh apps7.example.invalid "$NOCONFIG"
must "there is no config at" 'a run with no config to state the master is refused'
must "Nothing has been changed" 'a refusal says that nothing has been changed'
[ "$A_CODE" = '66' ] || fail "a missing config must end with 66, got $A_CODE"
same 'a run with no config to state the master'

run_remove_bash apps7.example.invalid "$NOBRANCHCFG"
run_remove_pwsh apps7.example.invalid "$NOBRANCHCFG"
must "origin has no branch nomaster.example.invalid" 'a config naming a master with no install branch is refused'
[ "$A_CODE" = '66' ] || fail "a master with no branch must end with 66, got $A_CODE"
same 'a config naming a master with no install branch'

run_remove_bash nosuch.example.invalid "$MASTERCFG"
run_remove_pwsh nosuch.example.invalid "$MASTERCFG"
# A MAP THAT IS GONE IS NOT A REFUSAL. Dropping the slave's part of the books is the git side of a
# removal and the program's header says the caller does it FIRST, so by the time the rest is wanted
# the map has left. What a run does instead is say so, and say what still protects a typed name.
must "keeps no clusters/active/nosuch.example.invalid.yaml"   'a slave the master keeps no map for is named rather than refused'
must "a name nothing holds removes nothing"   'and the run says what protects a typed name where the map cannot'
same 'a slave the master keeps no map for'

run_remove_bash apps8.example.invalid "$MASTERCFG"
run_remove_pwsh apps8.example.invalid "$MASTERCFG"
must "states role 'master', so what stands under that name is no slave" \
  'a map that does not name the slave part is refused'
[ "$A_CODE" = '65' ] || fail "a map that names no slave part must end with 65, got $A_CODE"
same 'a map that does not name the slave part'

run_remove_bash apps9.example.invalid "$MASTERCFG"
run_remove_pwsh apps9.example.invalid "$MASTERCFG"
must "states booksCluster 'other.example.invalid'" 'a slave whose books are another cluster is refused'
[ "$A_CODE" = '65' ] || fail "a slave of another master must end with 65, got $A_CODE"
same 'a slave whose map names another master'

# THE TARGET IS READ OFF THE MASTER'S BRANCH AND SAID OUT LOUD, and the slave is
# then asked whether it still answers — which is the whole of what this act
# establishes before it opens a session. The fixture's slave resolves to nothing,
# so the verdict is the one this run is for: a machine that is gone. The run then
# stops on the config standing in a tree that does not ignore it, which is where
# both spellings refuse in the same words.
run_remove_bash apps7.example.invalid "$MASTERCFG"
run_remove_pwsh apps7.example.invalid "$MASTERCFG"
must "remove-slave: clusters/active/apps7.example.invalid.yaml on branch apps6.example.invalid records apps7.example.invalid as a slave of apps6.example.invalid" \
  'the registration is read off the master branch and named'
must "remove-slave: apps7.example.invalid does not answer on port 22" \
  'the slave is asked whether it is still there, and the verdict is printed'
must "stands inside a git working tree that does not ignore it" \
  'a config a commit could reach is refused before it leaves this workstation'
[ "$A_CODE" = '77' ] || fail "a config a commit could reach must end with 77, got $A_CODE"
same 'the registration read off the master branch, a slave that is gone, and a config a commit could reach'

# ── the planted defect for this pair ────────────────────────────────────────
PLANTED_S="$WORK/planted-remove-slave.sh"
cp "$HERE/remove-slave-driver.sh" "$WORK/remove-slave-driver.sh"
sed 's/as a slave of/as a slave to/' "$HERE/remove-slave-from-master.sh" > "$PLANTED_S"
grep -q 'as a slave to' "$PLANTED_S" || fail 'the planted line was not planted — the probe proves nothing'
A_CODE=0
( cd "$SLAVEWORK_A" && bash "$PLANTED_S" apps7.example.invalid "$MASTERCFG" ) \
  > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'as a slave to' "$OUT/a.out" || fail 'the planted spelling printed no registration line — the probe was aimed at a line the fixture does not reach'
run_remove_pwsh apps7.example.invalid "$MASTERCFG"
normalise < "$OUT/a.out" > "$OUT/a.out.n"; normalise < "$OUT/b.out" > "$OUT/b.out.n"
if diff -q "$OUT/a.out.n" "$OUT/b.out.n" >/dev/null; then
  fail 'a spelling with one line changed compared EQUAL to the other — the comparison above proves nothing'
fi
ok 'the planted defect was caught — the comparison of the remove-slave pair can go red'

echo "test: GREEN — every case above was measured on both spellings and answered identically."
echo "test: covered — the four release refusals, the mint, the pin, the reuse of a standing"
echo "test:   tag, a tag a refused push left behind — dropped and cut again — beside one that"
echo "test:   never reached origin but names the released commit and is reused as it stands,"
echo "test:   the four states a report can be in and a name that is no installation; the"
echo "test:   six refusals a regeneration makes before it touches a machine, the pin it reads"
echo "test:   off the branch, and a launcher without its driver; the eight refusals a removal"
echo "test:   makes before it touches a master, the registration it reads off the master's"
echo "test:   branch and the verdict on a slave that is gone. Three planted defects prove the"
echo "test:   comparison can go red."
echo "test: not covered — an authenticated remote, two workstations minting at one moment, the"
echo "test:   regeneration and the removal themselves on a machine, a slave that is still"
echo "test:   answering, and the owner-only guard on a config."
