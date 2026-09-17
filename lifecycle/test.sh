#!/usr/bin/env bash
# ===========================================================================
# test.sh — proves the delivery tooling does what it says, against fixtures it
# builds in a temporary directory.
#
#   bash lifecycle/test.sh
#
# TWO ACTS DELIVER A CHANGE TO A RUNNING INSTALLATION and this file measures
# both: release-platform cuts a release of the platform tree and pins every
# installation the channel admits to it (or the one named), and
# regenerate-install-branch brings an installation's branch onto the pin — which
# the release itself performs where the installation's config stands beside the
# tree. status answers what each installation stands on.
# remove-slave-from-master is neither: it takes one slave's registration off the
# master it stands on, which is the only act here whose subject is a relation
# between two installations. abandon-installation is the end of one: it takes
# down what an installation whose machines are gone left outside them, which is
# its DNS records, its branches on origin and its books branch in the catalog.
# Every one of them is written twice, in bash and in PowerShell, and the two
# spellings are held to printing the same bytes.
#
# WHY TWO ORIGINS PER FIXTURE. release-platform MINTS and a mint pushes. Run
# against one origin the second spelling would find the first's work and take a
# different path, so the two would be compared on different work. Each spelling
# gets its own origin, cloned from the same seed so every commit id is the same
# on both sides, and the one thing that legitimately differs — the fourteen
# digits of a mint stamp — is normalised away before the comparison.
#
# WHAT IS COMPARED. Standard output, standard error and the exit code, for every
# path a person can reach: the mint and the pin, the mint that names no
# installation and pins nothing, the reuse of a tag that already stands, the four
# release refusals, the four states a report can be in, and the six refusals a
# regeneration makes before it touches a machine.
#
# THE PLANTED DEFECTS. A copy of status.sh with one printed line changed is run
# against the untouched status.ps1, a copy of regenerate-install-branch.sh with
# one printed line changed against the untouched .ps1, and a copy of
# remove-slave-from-master.sh and of abandon-installation.sh likewise. All four
# comparisons must go RED. Without them a green run would only prove that the
# comparisons found nothing, which is also what a comparison that stopped looking
# prints. The innocent beside them is every other case here, which must stay
# green.
#
# THE ABANDONMENT IS DRIVEN END TO END, in section FIVE, because everything it
# writes to is a fixture: the branches stand in directory origins, and the DNS
# provider and the liveness probe are one stand-in curl on the path, which
# answers the zone's records out of a table, takes a deletion out of it, and
# logs every call so the exact calls can be asserted rather than the printed
# lines alone. The stand-in is a bash script, and a .cmd shim beside it is what
# PowerShell on Windows finds under the same name; off Windows the shim is never
# looked at.
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
# THE OWNER-ONLY GUARD ON A CONFIG is measured on the bash spelling alone, in
# section FOUR: Windows states a file's reach as an access list and every other
# system as a mode, and require-owner-only.sh reads whichever the platform it
# runs on keeps. Its cases are driven with icacls, cygpath, stat and uname stood
# in for by stubs, so they run and answer the same on every platform, and once
# with the real tools, after a release has rewritten a config in place. The
# PowerShell spelling's Get-Acl is not driven, because a fixture cannot make it
# answer on a system that keeps no access lists. The guard beside it — a config
# standing in a git working tree that does not ignore it — is refused in the SAME
# words by both, and that is the one the removal's fixture config trips, which is
# what lets a case run all the way to the slave being asked whether it answers.
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

# THE GUARD THE LAUNCHERS PUT ON A CONFIG, read here so a fixture can be asked the
# same question a launcher asks, with the same tools.
# shellcheck disable=SC1091
. "$HERE/require-owner-only.sh" || fail 'require-owner-only.sh is not beside this file'

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
# Three files under the tree a regeneration carries, and one file outside it —
# so a commit that touches only the last proves the split in the report is real
# and not a count of everything.
echo "selector: __CLUSTER_ROLE_FIRST_PART__" > "$SEED/clusters/argocd/files/platform-apps-appset.yaml"
echo "host: idp.<fqdn>" > "$SEED/clusters/bootstrap/idp/ingressroute.tpl"
echo "platform: 0.0.0" > "$SEED/clusters/platform/versions.yaml"
echo "# the product tree" > "$SEED/README.md"
touch "$SEED/clusters/active/.gitkeep"
git -C "$SEED" add -A
git -C "$SEED" commit --quiet -m "Seed the trunk"
git -C "$SEED" push --quiet origin master

# An install branch is a branch carrying its own cluster map. Three of them, one
# per state a report can be in, plus a ref that carries no map at all.
seed_installation() { # fqdn, stage, release line (empty for none), role (master unless said)
  local fqdn="$1" stage="$2" release="$3" role="${4:-master}"
  git -C "$SEED" checkout --quiet -b "$fqdn" master
  {
    echo "stage: $stage"
    echo "role: $role"
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
# A master that took the slave part: its map says so, and a regeneration has to read it there.
seed_installation apps4.example.invalid dev '' master+slave
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
must_not "ansiwise deploy-branch" 'the second act is a script beside this one, not a command to retype'
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
  git -C "$checkout" commit --quiet -m "Move a second file only a regeneration carries"
  echo "# and a line nobody reads" >> "$checkout/README.md"
  git -C "$checkout" add -- README.md
  git -C "$checkout" commit --quiet -m "Move a file no cluster ever reads"
  git -C "$checkout" push --quiet origin master
}
advance_master "$WORK_A"
advance_master "$WORK_B"

run_bash status
run_pwsh status
must "  behind: 3 commits on origin/master since that release, 2 of them under clusters, which a regeneration has to carry" \
     'the report counts the commits since the pin and the ones a regeneration has to carry among them'
must "  regenerate: clusters/argocd/files/platform-apps-appset.yaml" 'the report names the file of the reconciler tree that moved'
must "  regenerate: clusters/platform/versions.yaml" 'and the file of the platform values chain, which nothing stamps and a regeneration still carries'
must_not "  regenerate: README.md" 'a file no cluster reads is not reported'
same 'the report with the trunk three commits ahead'

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
# reason — printed as if it were about the new attempt, until somebody deletes
# the tag by hand.
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

# ── the mint that names no installation, which pins every one ───────────────
# THE FORM A RELEASE IS CUT IN. It names no installation, and every installation
# origin carries takes the release: each branch carrying a map is pinned, each
# against the ceiling its own map's stage measures, and a branch carrying no map
# is no installation. A FIRST machine has no branch yet — the branch is cut by
# deploy-branch on the machine itself, which fetches PLATFORM_REF as a TAG — so
# the tag stands on the remote before that installation exists, and the configs
# beside the tree name it as PLATFORM_REF (the fixture carries none, and the run
# says so). What the printed lines alone cannot prove is measured: the tag reached
# both origins, every map records it, and the ref without a map did not move.
HEADS_A="$(git --git-dir="$ORIGIN_A" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
HEADS_B="$(git --git-dir="$ORIGIN_B" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
run_bash release-platform 0.4.0 alpha
run_pwsh release-platform 0.4.0 alpha
must "release: minted 0.4.0-alpha-" 'a run naming no installation mints'
must "release: the tag stands on the remote" 'and reads the tag back off the remote'
for each in apps3 apps4; do
  must "release: pinned $each.example.invalid to 0.4.0-alpha-" "every installation the channel admits is pinned — $each is dev"
  must "regenerate-install-branch.sh $each.example.invalid <config>" "and the regeneration of $each is named, because no config for it stands beside this tree"
done
must "release: apps5.example.invalid is stage test and channel alpha admits only: dev - left as it stands" 'a test installation is left as it stands by an alpha release, and said so'
must "release: apps9.example.invalid is stage prod and channel alpha admits only: dev - left as it stands" 'and so is the prod installation'
must_not "release: pinned apps5" 'the test installation is not pinned by an alpha release'
must_not "release: pinned apps9" 'nor is the prod installation'
must "no config beside this tree names a PLATFORM_REF, so none was written" 'the fixture carries no machine config, and the run says so instead of writing one'
must_not "work/no-map" 'a branch carrying no map is no installation and is not pinned'
same 'the mint that names no installation'
[ -n "$(git --git-dir="$ORIGIN_A" tag -l '0.4.0-alpha-*')" ] || fail 'the mint that names no installation put no tag on origin A'
[ -n "$(git --git-dir="$ORIGIN_B" tag -l '0.4.0-alpha-*')" ] || fail 'the mint that names no installation put no tag on origin B'
for ref in work/no-map apps5.example.invalid apps9.example.invalid; do
  [ "$(git --git-dir="$ORIGIN_A" rev-parse "refs/heads/$ref")" = "$(grep "^refs/heads/$ref " <<< "$HEADS_A" | cut -d' ' -f2)" ] \
    || fail "the release moved $ref, which it had no business touching"
done
for each in apps3 apps4; do
  git --git-dir="$ORIGIN_A" show "$each.example.invalid:clusters/active/$each.example.invalid.yaml" | grep -q '^release: 0.4.0-alpha-' \
    || fail "the map of $each does not record the release on origin A"
  git --git-dir="$ORIGIN_B" show "$each.example.invalid:clusters/active/$each.example.invalid.yaml" | grep -q '^release: 0.4.0-alpha-' \
    || fail "the map of $each does not record the release on origin B"
done
ok 'the mint that names no installation reached both origins, pinned the installations its channel admits, and moved nothing else'
# ── the counter-probes: ONE argument became optional, and no more ───────────
# Without these the case above would only prove that the arity check was
# loosened, not that it was loosened by exactly one argument.
run_bash release-platform 0.5.0
run_pwsh release-platform 0.5.0
must "usage: lifecycle/release-platform.sh" 'a run naming a version and no channel is still refused'
[ "$A_CODE" = '64' ] || fail "a run naming no channel must end with 64, got $A_CODE"
same_code 'a run naming a version and no channel'

run_bash release-platform 0.4.0 stable nosuch.example.invalid
run_pwsh release-platform 0.4.0 stable nosuch.example.invalid
must "origin has no branch nosuch.example.invalid" 'a domain with no install branch is still refused by name'
must_not "release: reusing" 'and it is refused before the tag it would have reused is read'
[ "$A_CODE" = '66' ] || fail "a domain that names no install branch must still end with 66, got $A_CODE"
same 'a domain with no install branch, now that the third argument is optional'

# ── the configs beside the tree take the tag and keep their access list ─────
# A RELEASE REWRITES PLATFORM_REF IN PLACE, in every lifecycle/config.*.env
# beside the tree it runs in, the example excepted, and a launcher then demands
# that the file is still owner-only. The write truncates the file where it
# stands rather than moving a copy over it, which on Windows would carry the
# copy's access list. So each fixture config is made owner-only with the real
# tools of this platform, the release runs, and the guard the launchers use is
# asked again with the same real tools. The config is named after no
# installation, so no regeneration is started over a session, and the release
# names apps4, whose pin no case below reads back.
make_owner_only() { # a file -> nobody but the owner reaches it, in this platform's own words
  if [ -n "${MSYSTEM:-}" ] || [ "$(uname -o 2>/dev/null)" = 'Msys' ]; then
    icacls "$(cygpath -aw "$1")" /inheritance:r /grant:r "$USERNAME:(F)" >/dev/null
  else
    chmod 600 "$1"
  fi
}
for side in "$WORK_A" "$WORK_B"; do
  mkdir -p "$side/lifecycle"
  printf "PLATFORM_REF=''\n" > "$side/lifecycle/config.example.env"
  printf "PLATFORM_REF='0.0.0-alpha-19700101000000'\nFQDN='other.example.invalid'\n" > "$side/lifecycle/config.other.env"
  make_owner_only "$side/lifecycle/config.other.env"
  require_owner_only "$side/lifecycle/config.other.env" \
    || fail "the fixture config under $side could not be made owner-only: it $REACH"
done
run_bash release-platform 0.6.0 alpha apps4.example.invalid
run_pwsh release-platform 0.6.0 alpha apps4.example.invalid
must "release: pinned apps4.example.invalid to 0.6.0-alpha-" 'the named installation is pinned'
must "release: PLATFORM_REF=0.6.0-alpha-" 'the tag is written into the config beside the tree'
must "written into 1 config(s) under lifecycle/" 'and the example beside it is not counted'
same 'the mint that rewrites the config beside the tree'
for side in "$WORK_A" "$WORK_B"; do
  grep -q "^PLATFORM_REF='0.6.0-alpha-" "$side/lifecycle/config.other.env" \
    || fail "the config under $side does not carry the tag as PLATFORM_REF"
  grep -q "^FQDN='other.example.invalid'\$" "$side/lifecycle/config.other.env" \
    || fail "the rewrite disturbed a line of the config under $side"
  grep -q "^PLATFORM_REF=''\$" "$side/lifecycle/config.example.env" \
    || fail "the rewrite touched the example under $side"
  require_owner_only "$side/lifecycle/config.other.env" \
    || fail "the rewrite took the access list off the config under $side: it $REACH"
done
ok 'the release rewrote PLATFORM_REF in place, left the example alone, and both configs still pass the owner-only guard asked with the real tools'

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
must "regenerate: apps3.example.invalid is pinned to 0.4.0-alpha-" 'the pin is read off the branch and named'
must "regenerate: apps3.example.invalid carries role master in clusters/active/apps3.example.invalid.yaml" 'the role is read off the branch and named'
must "there is no config at" 'a run with no config to state the installation is refused'
[ "$A_CODE" = '66' ] || fail "a missing config must end with 66, got $A_CODE"
same 'the pin read off the branch, and a missing config'

# THE ROLE IS THE MAP'S AND NOT THE CONFIG'S. A master that took the slave part
# through the Manager states master+slave on its branch while its config still
# says master; the regeneration names the map's role, which is what it appends
# behind the config so that the map keeps both parts (hostyour-cloud#220).
run_bash regenerate-install-branch apps4.example.invalid "$NOCONFIG"
run_pwsh regenerate-install-branch apps4.example.invalid "$NOCONFIG"
must "regenerate: apps4.example.invalid carries role master+slave in clusters/active/apps4.example.invalid.yaml" 'a map stating master+slave is named as such, whatever a config would say'
must "there is no config at" 'and the run still stops on the config, before a session is opened'
same 'the role read off the branch of a master that took the slave part'

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
# The planted copy looks beside itself for its driver and for the guard it reads.
cp "$HERE/regenerate-driver.sh" "$HERE/require-owner-only.sh" "$WORK/"
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

# ===========================================================================
# FOUR — the owner-only guard, on the bash spelling alone
#
# ONE QUESTION, AND THE PLATFORM SAYS WHERE THE ANSWER IS. On Windows a mode says
# nothing: Git Bash mounts every drive noacl, so stat answers 644 for every
# writable file and chmod 600 changes nothing, and the access list read with
# icacls is what counts. Everywhere else the mode is the answer. Both branches
# are driven here with icacls, cygpath, stat and uname stood in for by stubs on
# the path, so every case runs on every platform and answers the same. MSYSTEM
# is set to pick the Windows branch and set EMPTY to leave it, because the MSYS
# runtime puts the variable back when it is merely unset. Section ONE asked the
# real tools once already, after the release's rewrite.
#
# WHAT PROVES THE STUBS ARE THE ONES ANSWERING: on Windows the real icacls would
# refuse the probe, which inherits its directory's list, so a pass on the first
# case can only come from the stub; and the real stat there answers 644, so a
# pass on mode 600 can only come from the stub. On Linux and macOS there is no
# icacls and no cygpath at all.
# ===========================================================================
STUB="$WORK/stub"
STUB_PATH="$STUB"
if command -v cygpath >/dev/null 2>&1; then STUB_PATH="$(cygpath -u "$STUB")"; fi
mkdir -p "$STUB"
# icacls prints the path it was given, a space and the first entry, then one
# entry per line under it, a blank line and a count — the shape measured on
# Windows 11. The entries come from the file STUB_ACL names.
cat > "$STUB/icacls" <<'EOF'
#!/usr/bin/env bash
first=1
while IFS= read -r entry; do
  if [ "$first" = 1 ]; then printf '%s %s\n' "$1" "$entry"; first=0; else printf '%*s %s\n' "${#1}" '' "$entry"; fi
done < "$STUB_ACL"
printf '\nSuccessfully processed 1 files; Failed processing 0 files\n'
EOF
cat > "$STUB/cygpath" <<'EOF'
#!/usr/bin/env bash
shift $(($# - 1))
printf '%s\n' "$1"
EOF
cat > "$STUB/stat" <<'EOF'
#!/usr/bin/env bash
case "$2" in '%U') printf 'mkadm\n' ;; '%a') printf '%s\n' "$STUB_MODE" ;; *) exit 1 ;; esac
EOF
cat > "$STUB/uname" <<'EOF'
#!/usr/bin/env bash
printf 'GNU/Linux\n'
EOF
chmod +x "$STUB"/*
PROBE="$WORK/probe.env"
printf "X='1'\n" > "$PROBE"

guard() { # MSYSTEM value, the stubbed access list, the stubbed mode -> A_CODE, a.out, a.err
  printf '%s\n' "$2" > "$STUB/acl"
  A_CODE=0
  MSYSTEM="$1" USERNAME=mkadm STUB_ACL="$STUB/acl" STUB_MODE="$3" PATH="$STUB_PATH:$PATH" \
    bash -c '. "$1/require-owner-only.sh"; require_owner_only "$2" && echo passes || { echo "refused: $2 $REACH. Run: $OWNER_ONLY_COMMAND"; exit 1; }' _ "$HERE" "$PROBE" \
    > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
ICACLS_LINE="icacls \"$PROBE\" /inheritance:r /grant:r \"mkadm:(F)\""

guard MINGW64 'VPC1\mkadm:(F)' 644
must 'passes' 'the owner alone passes on Windows, whatever the mode says'
[ "$A_CODE" = '0' ] || fail "the owner alone must pass, got $A_CODE"
[ ! -s "$OUT/a.err" ] || fail "the guard wrote to standard error: $(cat "$OUT/a.err")"

guard MINGW64 $'BUILTIN\\Administrators:(I)(F)\nNT AUTHORITY\\SYSTEM:(I)(F)\nVPC1\\mkadm:(I)(F)' 644
must 'passes' 'the owner beside SYSTEM and Administrators passes, inherited or not'
[ "$A_CODE" = '0' ] || fail "owner, SYSTEM and Administrators must pass, got $A_CODE"

guard MINGW64 $'vpc1\\MKADM:(F)\nnt authority\\system:(F)' 644
must 'passes' 'the names are compared without case, the way Windows compares them'
[ "$A_CODE" = '0' ] || fail "an account name in another case must still be the owner, got $A_CODE"

guard MINGW64 $'Everyone:(R)\nVPC1\\mkadm:(F)' 644
must "refused: $PROBE can be read by Everyone. Run: $ICACLS_LINE" \
  'a stranger is refused by name, with the icacls line the PowerShell spelling prints'
[ "$A_CODE" = '1' ] || fail "a stranger must refuse, got $A_CODE"

guard MINGW64 $'VPC1\\CodexSandboxUsers:(I)(M)\nVPC1\\CodexSandboxUsers:(OI)(CI)(IO)(M)\nS-1-5-21-2543673324-2585280709-58404866-2868637010:(I)(M)\nNT AUTHORITY\\SYSTEM:(I)(F)\nBUILTIN\\Administrators:(I)(F)\nVPC1\\mkadm:(I)(F)' 644
must "can be read by VPC1\\CodexSandboxUsers, S-1-5-21-2543673324-2585280709-58404866-2868637010. Run:" \
  'every stranger is named once, in the order icacls lists them, and an unresolved SID is a stranger too'
[ "$A_CODE" = '1' ] || fail "an inherited list with strangers must refuse, got $A_CODE"

guard MINGW64 '' 644
must "refused: $PROBE has an access list icacls did not answer. Run: $ICACLS_LINE" \
  'an icacls that lists nobody is a refusal, not a pass'
[ "$A_CODE" = '1' ] || fail "an empty icacls answer must refuse, got $A_CODE"

guard '' 'Everyone:(R)' 600
must 'passes' 'off Windows, mode 600 passes and the access list is never read'
[ "$A_CODE" = '0' ] || fail "mode 600 must pass off Windows, got $A_CODE"

guard '' 'VPC1\mkadm:(F)' 400
must 'passes' 'and so does mode 400'
[ "$A_CODE" = '0' ] || fail "mode 400 must pass off Windows, got $A_CODE"

guard '' 'VPC1\mkadm:(F)' 644
must "refused: $PROBE is mode 644. Run: chmod 600 $PROBE" 'off Windows, mode 644 is refused with the mode sentence as it stands'
[ "$A_CODE" = '1' ] || fail "mode 644 must refuse off Windows, got $A_CODE"
ok 'the guard: owner alone, owner with SYSTEM and Administrators, and another case pass; a stranger, an inherited list and an empty answer refuse by name with the icacls line; off Windows 600 and 400 pass and 644 refuses with the mode sentence'

# ── the three launchers refuse in their own sentence, from the one guard ────
# EACH LAUNCHER SAYS WHICH CREDENTIALS THE FILE CARRIES and the guard says who
# can read it and what to run. The stranger case is driven through each of the
# three, and the mode case through one, so the sentences are measured as a
# person meets them and not only as the pieces they are built from.
printf 'Everyone:(R)\nVPC1\\mkadm:(F)\n' > "$STUB/acl"
run_guarded() { # the directory to stand in, MSYSTEM value, the stubbed mode, then the script and its arguments
  local in="$1" msystem="$2" mode="$3"; shift 3
  A_CODE=0
  ( cd "$in" && MSYSTEM="$msystem" USERNAME=mkadm STUB_ACL="$STUB/acl" STUB_MODE="$mode" PATH="$STUB_PATH:$PATH" bash "$@" ) \
    > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
run_guarded "$WORK_A" MINGW64 644 "$HERE/regenerate-install-branch.sh" apps3.example.invalid "$PROBE"
must "regenerate: $PROBE can be read by Everyone and carries credentials, the elevation password of the machine among them. Run: $ICACLS_LINE. Nothing has been changed" \
  'the regeneration refuses a stranger in its own sentence'
[ "$A_CODE" = '77' ] || fail "the regeneration must refuse a readable config with 77, got $A_CODE"

run_guarded "$WORK_A" MINGW64 644 "$HERE/install-machine.sh" "$PROBE"
must "$PROBE can be read by Everyone and carries ten credentials, four of them tokens with WRITE access to your repositories. Run: $ICACLS_LINE" \
  'the launcher refuses a stranger in its own sentence'
[ "$A_CODE" = '77' ] || fail "the launcher must refuse a readable config with 77, got $A_CODE"

# The removal reads the master's branch and asks the slave first, so its config
# stands outside every git tree and the guard is the refusal it reaches.
REMOVECFG="$WORK/remove-config.env"
cp "$MASTERCFG" "$REMOVECFG"
run_guarded "$SLAVEWORK_A" MINGW64 644 "$HERE/remove-slave-from-master.sh" apps7.example.invalid "$REMOVECFG"
must "remove-slave: $REMOVECFG can be read by Everyone and carries credentials, the elevation password of the machine among them. Run: icacls \"$REMOVECFG\" /inheritance:r /grant:r \"mkadm:(F)\". Nothing has been changed" \
  'the removal refuses a stranger in its own sentence'
[ "$A_CODE" = '77' ] || fail "the removal must refuse a readable config with 77, got $A_CODE"

run_guarded "$WORK_A" '' 644 "$HERE/regenerate-install-branch.sh" apps3.example.invalid "$PROBE"
must "regenerate: $PROBE is mode 644 and carries credentials, the elevation password of the machine among them. Run: chmod 600 $PROBE. Nothing has been changed" \
  'off Windows the regeneration refuses with the mode sentence as it stands'
[ "$A_CODE" = '77' ] || fail "the regeneration must refuse mode 644 with 77, got $A_CODE"
ok 'the three launchers refuse a readable config in their own sentence, built from the one guard'

# ===========================================================================
# FIVE — abandon-installation, against a fixture of an installation that is gone
#
# ONE INSTALLATION AS ITS BRANCH RECORDS IT: a master whose map lists two
# addresses in the flow spelling the branch program writes, one slave whose map
# lists one in the block spelling the Manager writes, two consumer registrations
# at two stages (and a build.yaml, which names no stage and must be passed
# over), a slave's own install branch of the earlier layout, and one tenant
# registration on the catalog's books branch of the same name. The zone carries
# what such an installation leaves: its wildcards and one platform host name at
# its addresses, both unit records, the tenant's wildcard, the sender domains'
# address records and SPF, and beside them everything the act must NOT touch —
# a foreign address under a unit's own name, the machine's own address record,
# a DKIM key, a DMARC policy, an SPF merged with another sender's include, and
# an MX. The second zone is the platform domain's, so the zone walk is measured
# across two zones.
#
# TWO OF EVERYTHING, for the reason section ONE has two origins: the act deletes,
# so the second spelling gets its own origin, its own catalog and its own copy
# of the zone tables, seeded identically, and the two call logs are compared as
# closely as the two outputs.
# ===========================================================================
ABANDON="$WORK/abandon"
mkdir -p "$ABANDON"
AORIGIN_A="$ABANDON/origin-a.git"; AORIGIN_B="$ABANDON/origin-b.git"
ACATALOG_A="$ABANDON/catalog-a.git"; ACATALOG_B="$ABANDON/catalog-b.git"
AWORK_A="$ABANDON/checkout-a"; AWORK_B="$ABANDON/checkout-b"
ASEED="$ABANDON/seed"; ACSEED="$ABANDON/cseed"

git init --quiet --bare --initial-branch=master "$AORIGIN_A"
git init --quiet --bare --initial-branch=master "$ACATALOG_A"
git init --quiet --initial-branch=master "$ASEED"
git -C "$ASEED" remote add origin "$AORIGIN_A"
mkdir -p "$ASEED/clusters/active"
echo "* text=auto eol=lf" > "$ASEED/.gitattributes"
touch "$ASEED/clusters/active/.gitkeep"
git -C "$ASEED" add -A
git -C "$ASEED" commit --quiet -m "Seed the trunk"
git -C "$ASEED" push --quiet origin master
git -C "$ASEED" checkout --quiet -b apps6.example.invalid master
{
  echo "stage: prod"
  echo "role: master"
  echo "booksCluster: apps6.example.invalid"
  echo "release: 0.1.0-stable-19700101000000"
  echo ""
  echo "global:"
  echo "  domain: apps6.example.invalid"
  echo "  clusterName: apps6"
  echo "  unitApex: example.invalid"
  echo "  platformDomain: platform.invalid"
  echo "  nodeCidrs: [203.0.113.6/32, 100.64.0.1/32]"
} > "$ASEED/clusters/active/apps6.example.invalid.yaml"
{
  echo "stage: prod"
  echo "role: slave"
  echo "booksCluster: apps6.example.invalid"
  echo ""
  echo "global:"
  echo "  domain: apps7.example.invalid"
  echo "  clusterName: apps7"
  echo "  unitApex: example.invalid"
  echo "  nodeCidrs:"
  echo "    - 203.0.113.7/32"
} > "$ASEED/clusters/active/apps7.example.invalid.yaml"
mkdir -p "$ASEED/registrations/digita-post" "$ASEED/registrations/digita-auth"
printf 'name: "digita-post"\ncluster: "apps6"\nhost: "post"\n' > "$ASEED/registrations/digita-post/prod.yaml"
printf 'name: "digita-post"\nrepoURL: "https://example.invalid/post.git"\n' > "$ASEED/registrations/digita-post/build.yaml"
printf 'name: "digita-auth"\ncluster: "apps7"\nhost: "auth"\n' > "$ASEED/registrations/digita-auth/dev.yaml"
git -C "$ASEED" add -A
git -C "$ASEED" commit --quiet -m "Cut the branch of apps6 with the books it keeps"
git -C "$ASEED" push --quiet origin apps6.example.invalid
git -C "$ASEED" checkout --quiet -b apps7.example.invalid master
echo "role: slave" > "$ASEED/clusters/active/apps7.example.invalid.yaml"
git -C "$ASEED" add -A
git -C "$ASEED" commit --quiet -m "A slave's own branch, as the earlier layout cut it"
git -C "$ASEED" push --quiet origin apps7.example.invalid
git -C "$ASEED" checkout --quiet master

git init --quiet --initial-branch=master "$ACSEED"
git -C "$ACSEED" remote add origin "$ACATALOG_A"
echo "* text=auto eol=lf" > "$ACSEED/.gitattributes"
echo "# the tenant catalog" > "$ACSEED/README.md"
git -C "$ACSEED" add -A
git -C "$ACSEED" commit --quiet -m "Seed the catalog"
git -C "$ACSEED" push --quiet origin master
git -C "$ACSEED" checkout --quiet -b apps6.example.invalid master
mkdir -p "$ACSEED/registrations/t_01acme"
printf 'cluster: "apps7"\nsubdomain: "acme"\n' > "$ACSEED/registrations/t_01acme/prod.yaml"
git -C "$ACSEED" add -A
git -C "$ACSEED" commit --quiet -m "Register a tenant"
git -C "$ACSEED" push --quiet origin apps6.example.invalid

git clone --quiet --bare "$AORIGIN_A" "$AORIGIN_B"
git clone --quiet --bare "$ACATALOG_A" "$ACATALOG_B"
git clone --quiet "$AORIGIN_A" "$AWORK_A"
git clone --quiet "$AORIGIN_B" "$AWORK_B"

# THE CATALOG IS REACHED BY THE ADDRESS THE ACT COMPOSES, https://github.com/<repo>.git,
# and git is told to read that address as the fixture's directory: each spelling
# gets a global git config of its own, handed over as GIT_CONFIG_GLOBAL, so the
# act composes the real address and no test-only switch stands in it.
git config --file "$ABANDON/gitconfig-a" "url.$ACATALOG_A.insteadOf" 'https://github.com/acme/catalog.git'
git config --file "$ABANDON/gitconfig-b" "url.$ACATALOG_B.insteadOf" 'https://github.com/acme/catalog.git'

# THE INSTALLATION'S CONFIG, read for two values and never run: it states the
# token the stand-in expects and the catalog.
ACFG="$ABANDON/config.apps6.env"
{
  echo "FQDN='apps6.example.invalid'"
  echo "CLOUDFLARE_DNS_API_TOKEN='cf-token-of-the-fixture'"
  echo "CATALOG_REPO='acme/catalog'"
  echo "STAGE='prod' #[dev, test, prod]"
} > "$ACFG"
OTHERCFG="$ABANDON/config.apps9.env"
sed "s/^FQDN=.*/FQDN='apps9.example.invalid'/" "$ACFG" > "$OTHERCFG"

# THE STAND-IN FOR curl, answering two things by the address it is given: the
# liveness probe on the API port, alive while the state directory holds a file
# named alive and connection-refused (7) otherwise; and the DNS provider's v4
# API, out of one table per zone. Every call is logged as its method, its path
# and the name it asked for, and the token is required on every API call the
# way the real API requires it.
ASTUB="$ABANDON/stub"
mkdir -p "$ASTUB"
cat > "$ASTUB/curl" <<'EOF'
#!/usr/bin/env bash
state="$ABANDON_STUB"
method=GET; url=''; name=''; stdin=''
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-urlencode) case "$2" in name=*) name="${2#name=}" ;; esac; shift ;;
    -K) shift; stdin="$(cat)" ;;
    https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  https://*:16443/) printf 'PROBE %s\n' "${url#https://}" >> "$state/log"; [ -f "$state/alive" ] && exit 0 || exit 7 ;;
esac
path="${url#https://api.cloudflare.com/client/v4}"
printf '%s\n' "$method $path${name:+ name=$name}" >> "$state/log"
case "$stdin" in
  *'Authorization: Bearer cf-token-of-the-fixture'*) ;;
  *) printf '{"result":null,"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"messages":[]}'; exit 0 ;;
esac
json_records() { # zone id, name -> the records at that name, as the API answers a listing
  local first=1 id n type content
  printf '{"result":['
  while IFS=$'\t' read -r id n type content; do
    [ "$n" = "$2" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    content="${content//\\/\\\\}"; content="${content//\"/\\\"}"
    printf '{"id":"%s","zone_id":"%s","zone_name":"z","name":"%s","type":"%s","content":"%s","proxiable":true,"proxied":false,"ttl":1,"settings":{},"meta":{},"comment":null,"tags":[],"created_on":"2026-01-01T00:00:00Z","modified_on":"2026-01-01T00:00:00Z"}' "$id" "$1" "$n" "$type" "$content"
  done < "$state/zone-$1.tsv"
  printf '],"success":true,"errors":[],"messages":[],"result_info":{"page":1,"per_page":100,"count":0,"total_count":0}}'
}
case "$method $path" in
  'GET /zones')
    case "$name" in
      example.invalid) printf '{"result":[{"id":"11111111111111111111111111111111","name":"example.invalid"}],"success":true,"errors":[],"messages":[]}' ;;
      platform.invalid) printf '{"result":[{"id":"22222222222222222222222222222222","name":"platform.invalid"}],"success":true,"errors":[],"messages":[]}' ;;
      *) printf '{"result":[],"success":true,"errors":[],"messages":[]}' ;;
    esac ;;
  'GET /zones/'*'/dns_records')
    zone="${path#/zones/}"; zone="${zone%%/*}"
    json_records "$zone" "$name" ;;
  'DELETE /zones/'*'/dns_records/'*)
    zone="${path#/zones/}"; zone="${zone%%/*}"; rid="${path##*/}"
    grep -v "^$rid	" "$state/zone-$zone.tsv" > "$state/zone-$zone.tsv.new"
    mv "$state/zone-$zone.tsv.new" "$state/zone-$zone.tsv"
    printf '{"result":{"id":"%s"},"success":true,"errors":[],"messages":[]}' "$rid" ;;
  *) printf '{"result":null,"success":false,"errors":[{"code":7003,"message":"no route for %s %s"}],"messages":[]}' "$method" "$path" ;;
esac
EOF
printf '@bash "%%~dp0curl" %%*\r\n' > "$ASTUB/curl.cmd"
chmod +x "$ASTUB/curl"
ASTUB_PATH="$ASTUB"
if command -v cygpath >/dev/null 2>&1; then ASTUB_PATH="$(cygpath -u "$ASTUB")"; fi

# THE ZONES, one table each, as they stand before the act. The first column is
# the record id the act has to delete by.
seed_zones() { # the state directory to seed
  mkdir -p "$1"
  printf '%s\t%s\t%s\t%s\n' \
    a0000000000000000000000000000001 '*.apps6.example.invalid' A 203.0.113.6 \
    a0000000000000000000000000000002 argo.apps6.example.invalid A 203.0.113.6 \
    a0000000000000000000000000000003 '*.apps7.example.invalid' A 203.0.113.7 \
    a0000000000000000000000000000004 post.example.invalid A 203.0.113.6 \
    a0000000000000000000000000000005 post.example.invalid A 198.51.100.9 \
    a0000000000000000000000000000006 auth.dev.example.invalid A 203.0.113.7 \
    a0000000000000000000000000000007 '*.acme.example.invalid' A 203.0.113.7 \
    a0000000000000000000000000000008 apps6.example.invalid A 203.0.113.6 \
    a0000000000000000000000000000009 example.invalid A 203.0.113.6 \
    a0000000000000000000000000000010 example.invalid TXT '"v=spf1 ip4:203.0.113.6 -all"' \
    a0000000000000000000000000000011 prod._domainkey.example.invalid TXT '"v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA" "xyz"' \
    a0000000000000000000000000000012 _dmarc.example.invalid TXT '"v=DMARC1; p=none; rua=mailto:dmarc@example.invalid"' \
    > "$1/zone-11111111111111111111111111111111.tsv"
  printf '%s\t%s\t%s\t%s\n' \
    b0000000000000000000000000000001 platform.invalid A 203.0.113.6 \
    b0000000000000000000000000000002 platform.invalid TXT '"v=spf1 include:_spf.other.invalid ip4:203.0.113.6 -all"' \
    b0000000000000000000000000000003 platform.invalid MX '10 mx.other.invalid' \
    > "$1/zone-22222222222222222222222222222222.tsv"
  : > "$1/log"
}
seed_zones "$ABANDON/state-a"
seed_zones "$ABANDON/state-b"
ok "fixture built — two origins and two catalogs carrying one installation, two zones carrying what it left, and a stand-in curl"

# The first argument is what the operator types at the confirmation; the rest
# are the act's own arguments.
run_abandon_bash() {
  local answer="$1"; shift
  A_CODE=0
  ( cd "$AWORK_A" && export GIT_CONFIG_GLOBAL="$ABANDON/gitconfig-a" ABANDON_STUB="$ABANDON/state-a" PATH="$ASTUB_PATH:$PATH" \
    && printf '%s\n' "$answer" | bash "$HERE/abandon-installation.sh" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
run_abandon_pwsh() {
  local answer="$1"; shift
  B_CODE=0
  ( cd "$AWORK_B" && export GIT_CONFIG_GLOBAL="$ABANDON/gitconfig-b" ABANDON_STUB="$ABANDON/state-b" PATH="$ASTUB_PATH:$PATH" \
    && printf '%s\n' "$answer" | "$PWSH" -NoProfile -NoLogo -File "$HERE/abandon-installation.ps1" "$@" ) > "$OUT/b.out" 2> "$OUT/b.err" || B_CODE=$?
}
untouched() { # what was being checked -> every origin, catalog and zone table stands as seeded
  local label="$1"
  for origin in "$AORIGIN_A" "$AORIGIN_B"; do
    [ "$(git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads | wc -l)" = '3' ] || fail "$label — a branch of the platform origin moved"
  done
  for catalog in "$ACATALOG_A" "$ACATALOG_B"; do
    [ "$(git --git-dir="$catalog" for-each-ref --format='%(refname)' refs/heads | wc -l)" = '2' ] || fail "$label — a branch of the catalog moved"
  done
  for state in "$ABANDON/state-a" "$ABANDON/state-b"; do
    [ "$(wc -l < "$state/zone-11111111111111111111111111111111.tsv")" = '12' ] || fail "$label — a record of the first zone went"
    [ "$(wc -l < "$state/zone-22222222222222222222222222222222.tsv")" = '3' ] || fail "$label — a record of the second zone went"
    ! grep -q '^DELETE' "$state/log" || fail "$label — a deletion reached the DNS provider"
  done
}

run_abandon_bash ''
run_abandon_pwsh ''
must "usage: lifecycle/abandon-installation.sh <master-fqdn>" 'a run naming no installation is refused'
[ "$A_CODE" = '64' ] || fail "a run naming no installation must end with 64, got $A_CODE"
same_code 'a run naming no installation'

run_abandon_bash '' apps6.example.invalid "$NOCONFIG"
run_abandon_pwsh '' apps6.example.invalid "$NOCONFIG"
must "there is no config at" 'a run with no config to read the token from is refused'
[ "$A_CODE" = '66' ] || fail "a missing config must end with 66, got $A_CODE"
same 'a run with no config'

run_abandon_bash '' apps6.example.invalid "$OTHERCFG"
run_abandon_pwsh '' apps6.example.invalid "$OTHERCFG"
must "states FQDN='apps9.example.invalid', and this abandons apps6.example.invalid" 'a config of another installation is refused by name'
[ "$A_CODE" = '65' ] || fail "another installation's config must end with 65, got $A_CODE"
same "another installation's config"
untouched 'the three refusals'

# ── the guard: a cluster whose API still answers refuses before any write ────
touch "$ABANDON/state-a/alive" "$ABANDON/state-b/alive"
run_abandon_bash apps6.example.invalid apps6.example.invalid "$ACFG"
run_abandon_pwsh apps6.example.invalid apps6.example.invalid "$ACFG"
must "abandon: apps6.example.invalid keeps its books on branch apps6.example.invalid of origin" 'the books are read off origin and said so'
must "abandon: clusters/active/apps6.example.invalid.yaml records apps6.example.invalid as master at 203.0.113.6, 100.64.0.1" 'the master and its two addresses are read off its map, in the flow spelling'
must "abandon: clusters/active/apps7.example.invalid.yaml records apps7.example.invalid as slave at 203.0.113.7" 'the slave and its address are read off its map, in the block spelling'
must "abandon: apps6.example.invalid answers on port 16443 at 203.0.113.6 (curl exit 0), so this is a LIVING installation" 'a cluster whose API answers refuses, naming the cluster and the address'
must "Nothing has been changed" 'and the refusal says nothing has been changed'
[ "$A_CODE" = '69' ] || fail "a living installation must refuse with 69, got $A_CODE"
same 'a living installation'
for state in "$ABANDON/state-a" "$ABANDON/state-b"; do
  [ "$(grep -c '^PROBE' "$state/log")" = '1' ] || fail 'the guard asked more than the first address that answered'
  ! grep -q '^GET\|^DELETE' "$state/log" || fail 'a living installation was refused and the DNS provider was still asked'
done
untouched 'a living installation'
rm -f "$ABANDON/state-a/alive" "$ABANDON/state-b/alive"
: > "$ABANDON/state-a/log"; : > "$ABANDON/state-b/log"

# ── the confirmation: anything but the master's domain stops before any write ─
run_abandon_bash no apps6.example.invalid "$ACFG"
run_abandon_pwsh no apps6.example.invalid "$ACFG"
must "abandon: registrations/digita-post/prod.yaml stands at post.example.invalid" 'a prod consumer stands at its label under the apex'
must "abandon: registrations/digita-auth/dev.yaml stands at auth.dev.example.invalid" 'a dev consumer stands at its label under the dev zone'
must_not "registrations/digita-post/build.yaml" 'a build registration names no stage and derives no record'
must "abandon: the catalog's books branch apps6.example.invalid carries registrations/t_01acme/prod.yaml, which stands at *.acme.example.invalid" 'the tenant wildcard is derived off the catalog branch'
must "abandon: the mail records of platform.invalid: platform.invalid (its address and SPF), prod._domainkey.platform.invalid (DKIM), _dmarc.platform.invalid (DMARC)" 'the mail records of the platform domain are named, the DKIM one under the stage'
must "abandon: the mail records of example.invalid:" 'and those of the unit apex'
must "abandon: apps6.example.invalid itself is the machine's name and not the installation's, so its own address record stays" "the machine's own address record is named as staying"
must "abandon: 40 names derived" 'every derived name is counted'
must "abandon: apps6.example.invalid does not answer on port 16443 at 203.0.113.6" 'the master is asked at its public address'
must "abandon: apps6.example.invalid does not answer on port 16443 at 100.64.0.1" 'and at its tailnet address'
must "abandon: apps7.example.invalid does not answer on port 16443 at 203.0.113.7" 'and the slave at its address'
must "abandon: this workstation can push a branch deletion to origin and to the catalog" 'the push access is proven before anything is written'
must "abandon: what goes: every record above that proves itself this installation's, the branches apps6.example.invalid apps7.example.invalid on origin, and the books branch apps6.example.invalid of the catalog https://github.com/acme/catalog.git. Type apps6.example.invalid to confirm" 'the operator is told what goes and asked to type the domain'
must "abandon: the answer was not apps6.example.invalid, so this stops. Nothing has been changed" 'any other answer stops the act'
[ "$A_CODE" = '65' ] || fail "a declined confirmation must end with 65, got $A_CODE"
same 'the derivation, the guard on an installation that is gone, and a declined confirmation'
untouched 'a declined confirmation'
: > "$ABANDON/state-a/log"; : > "$ABANDON/state-b/log"

# ── the planted defect for this pair, on the state nothing has changed yet ───
PLANTED_A="$WORK/planted-abandon.sh"
sed 's/keeps its books on branch/keeps its books at branch/' "$HERE/abandon-installation.sh" > "$PLANTED_A"
grep -q 'keeps its books at branch' "$PLANTED_A" || fail 'the planted line was not planted — the probe proves nothing'
A_CODE=0
( cd "$AWORK_A" && export GIT_CONFIG_GLOBAL="$ABANDON/gitconfig-a" ABANDON_STUB="$ABANDON/state-a" PATH="$ASTUB_PATH:$PATH" \
  && printf 'no\n' | bash "$PLANTED_A" apps6.example.invalid "$ACFG" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'keeps its books at branch' "$OUT/a.out" || fail 'the planted spelling printed no books line — the probe was aimed at a line the fixture does not reach'
run_abandon_pwsh no apps6.example.invalid "$ACFG"
normalise < "$OUT/a.out" > "$OUT/a.out.n"; normalise < "$OUT/b.out" > "$OUT/b.out.n"
if diff -q "$OUT/a.out.n" "$OUT/b.out.n" >/dev/null; then
  fail 'a spelling with one line changed compared EQUAL to the other — the comparison above proves nothing'
fi
ok 'the planted defect was caught — the comparison of the abandon pair can go red'
untouched 'the planted run'
: > "$ABANDON/state-a/log"; : > "$ABANDON/state-b/log"

# ── the act itself: the records that prove themselves go, the rest is listed ─
run_abandon_bash apps6.example.invalid apps6.example.invalid "$ACFG"
run_abandon_pwsh apps6.example.invalid apps6.example.invalid "$ACFG"
must "abandon: zone example.invalid: deleted A *.apps6.example.invalid -> 203.0.113.6, the platform host names of apps6.example.invalid" "the master's wildcard at its address goes"
must "abandon: zone example.invalid: deleted A argo.apps6.example.invalid -> 203.0.113.6, a platform host name of apps6.example.invalid" 'and a platform host name written on its own'
must "abandon: zone example.invalid: deleted A *.apps7.example.invalid -> 203.0.113.7, the platform host names of apps7.example.invalid" "the slave's wildcard at the slave's address goes"
must "abandon: zone example.invalid: deleted A post.example.invalid -> 203.0.113.6, the consumer digita-post at prod" "the prod consumer's record at the master goes"
must "abandon: zone example.invalid: left A post.example.invalid -> 198.51.100.9, an address this installation never had" 'the foreign record under the same name is left and named'
must "abandon: zone example.invalid: deleted A auth.dev.example.invalid -> 203.0.113.7, the consumer digita-auth at dev" "the dev consumer's record at the slave goes"
must "abandon: zone example.invalid: deleted A *.acme.example.invalid -> 203.0.113.7, the tenant t_01acme at prod" "the tenant's wildcard goes"
must "abandon: zone platform.invalid: deleted A platform.invalid -> 203.0.113.6, the sender domain platform.invalid" "the sender domain's address record at the egress goes"
must "abandon: zone example.invalid: deleted TXT example.invalid (v=spf1 ip4:203.0.113.6 -all), the sender domain example.invalid" "an SPF that authorises the installation's address alone goes"
must "abandon: zone platform.invalid: left TXT platform.invalid (v=spf1 include:_spf.other.invalid ip4:203.0.113.6 -all): it authorises senders beside this installation" 'an SPF merged with another sender is left and named'
must "abandon: zone example.invalid: left TXT prod._domainkey.example.invalid (v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ): nothing on the branch proves that content the installation's" 'the DKIM key is left, because nothing on the branch proves it'
must "abandon: zone example.invalid: left TXT _dmarc.example.invalid (v=DMARC1; p=none; rua=mailto:dmarc@example.inval): nothing on the branch proves that content the installation's" 'and so is the DMARC policy'
must "abandon: zone platform.invalid: left MX platform.invalid -> 10 mx.other.invalid: this act judges A, AAAA and TXT records only" 'a record of another type is left and named'
must "abandon: 9 records deleted, 5 left standing and listed above, 30 of the derived names carried nothing" 'the count says what went, what stayed and how many names were empty'
must "abandon: deleted branch apps6.example.invalid on origin" "the master's branch goes"
must "abandon: deleted branch apps7.example.invalid on origin" "the slave's branch goes"
must "abandon: deleted the books branch apps6.example.invalid of the catalog https://github.com/acme/catalog.git" "the catalog's books branch goes"
must "abandon: $ACFG stays. A local config is the record of the answers a machine was installed with" 'the config is named and stays'
[ "$A_CODE" = '0' ] || fail "the act must end with 0, got $A_CODE"
same 'the act on an installation that is gone'
# THE ORDER OF THE THREE BRANCHES, read off the output rather than assumed.
[ "$(grep -o 'deleted branch apps6.example.invalid on origin\|deleted branch apps7.example.invalid on origin\|deleted the books branch apps6.example.invalid' "$OUT/a.out" | tr '\n' '|')" = \
  'deleted branch apps6.example.invalid on origin|deleted branch apps7.example.invalid on origin|deleted the books branch apps6.example.invalid|' ] \
  || fail 'the three branches were not deleted in the order master, slave, catalog, or not exactly three'
[ -f "$ACFG" ] || fail 'the config is gone'
# THE CALLS THAT REACHED THE PROVIDER, exactly: nine deletions in the order the
# names were derived, forty listings — one per derived name — and never a
# listing of the machine's own name.
EXPECTED_DELETES="DELETE /zones/11111111111111111111111111111111/dns_records/a0000000000000000000000000000001
DELETE /zones/11111111111111111111111111111111/dns_records/a0000000000000000000000000000002
DELETE /zones/11111111111111111111111111111111/dns_records/a0000000000000000000000000000003
DELETE /zones/11111111111111111111111111111111/dns_records/a0000000000000000000000000000006
DELETE /zones/11111111111111111111111111111111/dns_records/a0000000000000000000000000000004
DELETE /zones/22222222222222222222222222222222/dns_records/b0000000000000000000000000000001
DELETE /zones/11111111111111111111111111111111/dns_records/a0000000000000000000000000000009
DELETE /zones/11111111111111111111111111111111/dns_records/a0000000000000000000000000000010
DELETE /zones/11111111111111111111111111111111/dns_records/a0000000000000000000000000000007"
for state in "$ABANDON/state-a" "$ABANDON/state-b"; do
  [ "$(grep '^DELETE' "$state/log")" = "$EXPECTED_DELETES" ] \
    || fail "the deletions that reached the provider are not the nine expected, in order: $(grep '^DELETE' "$state/log" | tr '\n' ' ')"
  [ "$(grep -c '/dns_records name=' "$state/log")" = '40' ] || fail 'not every derived name was listed at the provider, or one was listed twice'
  ! grep -q 'dns_records name=apps6.example.invalid$' "$state/log" || fail "the machine's own address record was asked for"
  [ "$(grep -c '^PROBE' "$state/log")" = '3' ] || fail 'the three addresses were not each asked once'
  [ "$(wc -l < "$state/zone-11111111111111111111111111111111.tsv")" = '4' ] || fail 'the first zone does not keep exactly the foreign record, the own address record, the DKIM key and the DMARC policy'
  grep -q '^a0000000000000000000000000000008	apps6.example.invalid	A	203.0.113.6$' "$state/zone-11111111111111111111111111111111.tsv" \
    || fail "the machine's own address record is gone"
  [ "$(wc -l < "$state/zone-22222222222222222222222222222222.tsv")" = '2' ] || fail 'the second zone does not keep exactly the merged SPF and the MX'
done
diff -u "$ABANDON/state-a/log" "$ABANDON/state-b/log" >/dev/null || fail 'the two spellings made different calls to the provider'
for origin in "$AORIGIN_A" "$AORIGIN_B"; do
  [ "$(git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads)" = 'refs/heads/master' ] || fail 'the platform origin still carries a branch of the installation'
done
for catalog in "$ACATALOG_A" "$ACATALOG_B"; do
  [ "$(git --git-dir="$catalog" for-each-ref --format='%(refname)' refs/heads)" = 'refs/heads/master' ] || fail 'the catalog still carries the books branch'
done
ok 'the nine attributable records went in the derived order, the six the act cannot attribute stand and are named, the three branches went in order on both origins, and both spellings made the same calls'

# ── the second run on what the first left: nothing to do, and exit 0 ─────────
: > "$ABANDON/state-a/log"; : > "$ABANDON/state-b/log"
run_abandon_bash apps6.example.invalid apps6.example.invalid "$ACFG"
run_abandon_pwsh apps6.example.invalid apps6.example.invalid "$ACFG"
must "abandon: origin carries no branch apps6.example.invalid, so no map, no address and no registration of it can be read" 'a second run finds no branch and says what that means'
must "abandon: the catalog https://github.com/acme/catalog.git carries no books branch apps6.example.invalid" 'and no books branch in the catalog'
must "nothing to do" 'and stops with nothing to do'
must "abandon: $ACFG stays" 'and still names the config as staying'
[ "$A_CODE" = '0' ] || fail "a second run with nothing to do must end with 0, got $A_CODE"
same 'a second run on what the first left'
for state in "$ABANDON/state-a" "$ABANDON/state-b"; do
  [ ! -s "$state/log" ] || fail 'a second run with no branch to derive from still reached the provider'
done
ok 'a second run derives nothing, touches nothing and ends with 0'

echo "test: GREEN — every case above was measured on both spellings and answered identically,"
echo "test:   and the owner-only guard on the bash spelling alone."
echo "test: covered — the four release refusals, the mint, the pin, the reuse of a standing"
echo "test:   tag, a tag a refused push left behind — dropped and cut again — beside one that"
echo "test:   never reached origin but names the released commit and is reused as it stands,"
echo "test:   the mint that names no installation — which pins nothing, moves no branch and"
echo "test:   says the channel ceiling went unmeasured — beside the two counter-probes that"
echo "test:   one argument and no more became optional, the config beside the tree that a"
echo "test:   release rewrites in place and that still passes the owner-only guard afterwards,"
echo "test:   the four states a report can be in and a name that is no installation; the"
echo "test:   six refusals a regeneration makes before it touches a machine, the pin it reads"
echo "test:   off the branch, and a launcher without its driver; the eight refusals a removal"
echo "test:   makes before it touches a master, the registration it reads off the master's"
echo "test:   branch and the verdict on a slave that is gone; the owner-only guard on both of"
echo "test:   its branches, against stubbed tools, and the sentence each of the three launchers"
echo "test:   builds from it; the three refusals an abandonment makes before it reads a zone,"
echo "test:   the names it derives off the install branch and the catalog's books branch, the"
echo "test:   guard that refuses a cluster whose API still answers, the confirmation, the nine"
echo "test:   records it deletes against a stand-in provider and the six it lists and leaves,"
echo "test:   the three branches it deletes in order, the config it names as staying, and a"
echo "test:   second run that finds nothing to do. Four planted defects prove the comparison"
echo "test:   can go red."
echo "test: not covered — an authenticated remote, two workstations minting at one moment, the"
echo "test:   regeneration and the removal themselves on a machine, a slave that is still"
echo "test:   answering, the PowerShell spelling's own reading of an access list, a branch"
echo "test:   deletion a remote refuses (a directory origin refuses none), and a DNS provider"
echo "test:   that fails in the middle of the abandonment."
