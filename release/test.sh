#!/usr/bin/env bash
# ===========================================================================
# test.sh — proves the two spellings of the release tooling answer identically,
# against a fixture it builds in a temporary directory: two byte-identical bare
# origins, each with a trunk, three install branches and one ref that is no
# install branch at all.
#
#   bash release/test.sh
#
# WHY TWO ORIGINS. release.sh and release.ps1 both MINT, and a mint pushes. Run
# against one origin the second spelling would find the first's tag and take the
# reuse path, so the two would be compared on different work. Each spelling gets
# its own origin, cloned from the same seed so every commit id is the same on
# both sides, and the one thing that legitimately differs — the fourteen digits
# of the mint stamp — is normalised away before the comparison.
#
# WHAT IS COMPARED. Standard output, standard error and the exit code, for every
# path a person can reach: the mint and the pin, the reuse of a tag that already
# stands, the four refusals, and the four states a report can be in — level,
# behind, unpinned and a pin naming a state this repository does not carry.
#
# THE PLANTED DEFECT. A copy of status.sh with one printed line changed is run
# against the untouched status.ps1, and the comparison must go RED. Without it a
# green run would only prove that the comparison found nothing, which is also
# what a comparison that stopped looking prints. The innocent beside it is every
# other case here, which must stay green.
#
# WHAT THIS FILE CANNOT PROVE, named rather than counted: an authenticated
# remote (the fixture's origins are directories, so a push never asks for a
# credential), two workstations minting the same version and channel at the same
# moment, and the regeneration itself — that runs on a machine, out of the
# catalogue repository, and nothing here can stand in for it.
# ===========================================================================
set -euo pipefail

fail() { echo "test: RED — $*" >&2; exit 1; }
ok() { echo "test: ok — $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PWSH="$(command -v pwsh || true)"
[ -n "$PWSH" ] || fail 'pwsh is not on this path, and half of what this measures is written in it'

# Commits of the fixture and of the scripts' own throwaway clones both need an
# identity, and the machine's own must not leak into a test. The dates are fixed
# so the two origins carry the same commit ids and a comparison cannot pass or
# fail on a clock.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_AUTHOR_DATE='2026-01-01T00:00:00+0000'
export GIT_COMMITTER_DATE='2026-01-01T00:00:00+0000'

ORIGIN_A="$WORK/origin-a.git"
ORIGIN_B="$WORK/origin-b.git"
WORK_A="$WORK/checkout-a"
WORK_B="$WORK/checkout-b"
OUT="$WORK/out"
mkdir -p "$OUT"

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

# ── running one spelling of one script, and comparing the pair ──────────────
# The fourteen digits of a mint stamp are by construction different in two runs
# and are the ONE thing allowed to differ, so they are normalised on both sides.
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
must() { # a line the output has to carry
  grep -qF -- "$1" "$OUT/a.out" "$OUT/a.err" || fail "$2 — missing from the output: '$1'"
}
must_not() {
  grep -qF -- "$1" "$OUT/a.out" "$OUT/a.err" && fail "$2 — present in the output: '$1'"
  return 0
}

# ── the refusals, which cost nothing and must leave nothing behind ──────────
run_bash release 1.2 stable apps3.example.invalid
run_pwsh release 1.2 stable apps3.example.invalid
must "version must be x.y.z" 'a version that is not three numbers is refused'
[ "$A_CODE" = '64' ] || fail "a malformed version must end the run with 64, got $A_CODE"
same 'a version that is not three numbers'

run_bash release 0.1.0 golden apps3.example.invalid
run_pwsh release 0.1.0 golden apps3.example.invalid
must "channel must be stable, beta or alpha" 'an unknown channel is refused'
same 'a channel outside the three'

run_bash release 0.1.0 stable nosuch.example.invalid
run_pwsh release 0.1.0 stable nosuch.example.invalid
must "origin has no branch nosuch.example.invalid" 'a domain with no install branch is refused'
same 'a domain that names no install branch'

run_bash release 0.1.0 alpha apps9.example.invalid
run_pwsh release 0.1.0 alpha apps9.example.invalid
must "channel alpha admits only: dev" 'the channel ceiling refuses a prod installation'
same 'an alpha release aimed at a prod installation'

# NOTHING WAS MINTED BY ANY OF THAT. The refusals above all stand before the
# mint, which is the whole reason the order is what it is.
[ -z "$(git --git-dir="$ORIGIN_A" tag -l)" ] || fail 'a refused run left a tag on origin A'
[ -z "$(git --git-dir="$ORIGIN_B" tag -l)" ] || fail 'a refused run left a tag on origin B'
ok 'four refusals, and neither origin carries a tag — nothing is created before the target is known good'

# ── the mint and the pin ────────────────────────────────────────────────────
run_bash release 0.1.0 alpha apps3.example.invalid
run_pwsh release 0.1.0 alpha apps3.example.invalid
must "release: minted 0.1.0-alpha-" 'the first run mints'
must "release: the tag stands on the remote" 'the tag is read back off the remote before anything is pinned'
must "release: pinned apps3.example.invalid to 0.1.0-alpha-" 'the pin is written'
must "ansiwise regenerate-branch --role master --mode run" 'the next act is printed with the ref filled in'
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
run_bash release 0.1.0 alpha apps3.example.invalid
run_pwsh release 0.1.0 alpha apps3.example.invalid
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
ok 'the planted defect was caught — the comparison can go red'

echo "test: OK — the two spellings answered identically on every case above"
