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
# its DNS records, its branches on origin and its books branch in the deploy repository.
# create-github-app is what makes an installation's GitHub App: it creates the
# App in the customer's organisation through the manifest flow, installs it
# there, and writes the three answers into the config.
# Every case runs one of them and holds what it printed to the block recorded
# for that case, which stands in this file at the case.
#
# WHAT IS RECORDED. Standard output, standard error and the exit code, for every
# path a person can reach: the mint and the pin, the mint that names no
# installation and pins nothing, the reuse of a tag that already stands, the four
# release refusals, the four states a report can be in, and the six refusals a
# regeneration makes before it touches a machine. What differs between two runs
# of one tree is normalised before the comparison, and nothing else: the fixture
# root, the folder this file stands in, the home folder, the fourteen digits of a
# mint stamp and the reason a resolver gives for a host name it cannot resolve.
# The locale is C, so a tool's own text is its English one. So a run in another
# folder, on another machine, without a network or at another time is held to
# the same bytes.
#
# WHY THE BLOCKS STAND IN THIS FILE and not in a file of their own: an install
# branch stamps its domain over the fixtures' example.invalid in every tracked
# file under lifecycle/ that is no script, and this file is a script.
#
# THE PLANTED DEFECTS. A copy of status.sh with one printed line changed is run
# where its case ran, and so is a copy of regenerate-install-branch.sh, of
# remove-slave-from-master.sh, of install-machine.sh, of abandon-installation.sh,
# of create-github-app.sh, of master-backup.sh and of master-restore.sh, and of
# the guard beside the last two. Every copy must print other bytes than its case
# recorded, in the changed line alone. Without them a green run would only prove that the comparisons found
# nothing, which is also what a comparison that stopped looking prints. The
# innocent beside them is every other case here, which must stay green.
#
# THE ABANDONMENT IS DRIVEN END TO END, in section FIVE, because everything it
# writes to is a fixture: the branches stand in directory origins, and the DNS
# provider and the liveness probe are one stand-in curl on the path, which
# answers the zone's records out of a table, takes a deletion out of it, and
# logs every call so the exact calls can be asserted rather than the printed
# lines alone. The GitHub App act is driven the same way, in section SIX: GitHub
# is a second stand-in curl that verifies every JWT it is shown, and the browser
# is a stand-in named by BROWSER that drives the act's own listener.
#
# WHAT THIS FILE CANNOT PROVE, named rather than counted: an authenticated remote
# (the fixtures' origins are directories, so a push never asks for a credential),
# two workstations minting the same version and channel at the same moment, and
# the regeneration and the removal themselves — those run on a
# machine, out of the programs repository, and nothing here can stand in for
# them. Nor a slave that is still ANSWERING, which is what
# remove-slave-from-master refuses on: a fixture cannot make a machine listen on
# port 22, so what is measured is the other verdict, that the slave is gone.
#
# THE OWNER-ONLY GUARD ON A CONFIG is require-owner-only.sh, which each launcher
# sources, and it reads a file's reach as its mode. Its cases are driven in
# section FOUR with stat stood in for by a stub, and once with the real stat,
# after a release has rewritten a config in place. A config of mode 644 is
# refused by the regeneration, install-machine, the backup and the restore, each
# in its recorded bytes. The guard beside it —
# a config standing in a git working tree that does not ignore it — is the one
# the removal's fixture config trips, which is what lets a case run all the way
# to the slave being asked whether it answers.
# ===========================================================================
set -euo pipefail

fail() { echo "test: RED — $*" >&2; exit 1; }
ok() { echo "test: ok — $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# THE GUARD THE LAUNCHERS PUT ON A CONFIG, read here so a fixture can be asked the
# same question a launcher asks, with the same tools.
# shellcheck disable=SC1091
. "$HERE/require-owner-only.sh" || fail 'require-owner-only.sh is not beside this file'

# Commits of the fixtures and of the scripts' own throwaway clones both need an
# identity, and the machine's own must not leak into a test. The dates are fixed
# so every run carries the same commit ids and a recorded block cannot pass or
# fail on a clock.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_AUTHOR_DATE='2026-01-01T00:00:00+0000'
export GIT_COMMITTER_DATE='2026-01-01T00:00:00+0000'
# What git, ssh and the other tools print is recorded in their C wording, which a
# localised machine would translate.
export LC_ALL=C

# No git call of a fixture leaves a process behind it, which a case removing its repository would
# race: scripts/standin/git-quiet.sh sets the template that prevents it and measures that it does.
# shellcheck disable=SC1091
. "$HERE/../scripts/standin/git-quiet.sh"
PLANTED="$(git_quiet_proof "$WORK")" || fail 'a fixture git starts a background maintenance'
ok 'a fixture commits and pushes without starting a background maintenance, and the push reaches its origin'
ok "the planted defect was caught — without the template the same commit and push start $PLANTED background maintenance(s)"

OUT="$WORK/out"
mkdir -p "$OUT"

# ── running one script, and holding it to the block recorded for its case ──
# WHAT DIFFERS BETWEEN TWO RUNS OF ONE TREE is the fixture root, the folder this
# file stands in, the home folder and the fourteen digits of a mint stamp. Those
# are normalised, in that order, because the first two can lie under the third.
# So is the reason ssh passes on from the resolver for a host name it cannot
# resolve: glibc answers "Name or service not known" with a network and
# "Temporary failure in name resolution" without one, and another libc words
# both its own way. The host name before it stays. So is the warning git 2.39 prints
# before the "fatal: Remote branch ... not found" of a clone of a branch that does not
# exist, which a newer git does not print: what the case records is the refusal and
# the exit, and git's own warning is no part of either. Nothing else is normalised.
#
# WRITTEN HERE RATHER THAN SHELLED OUT TO, because the filter that normalises is
# as much part of the measurement as the comparison is. A normaliser that
# quietly dropped a carriage return would leave a comparison which cannot see a
# line ending the recorded block does not carry.
normalise() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == "warning: Could not find remote branch "*" to clone." ]] && continue
    line="${line//"$WORK"/<WORK>}"; line="${line//"$HERE"/<HERE>}"; line="${line//"$HOME"/<HOME>}"
    while [[ "$line" =~ ([0-9]{14}) ]]; do line="${line//${BASH_REMATCH[1]}/TS14}"; done
    if [[ "$line" =~ (Could not resolve hostname [^:]+: )[^.]+ ]]; then
      line="${line/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}<RESOLVER>"}"
    fi
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
printf '%s\n' \
  'ssh: Could not resolve hostname door.example.invalid: Name or service not known. Nothing' \
  'ssh: Could not resolve hostname door.example.invalid: Temporary failure in name resolution. Nothing' \
  > "$OUT/probe.in"
[ "$(normalise < "$OUT/probe.in" | sort -u)" = 'ssh: Could not resolve hostname door.example.invalid: <RESOLVER>. Nothing' ] \
  || fail 'the normaliser does not read the resolver'"'"'s reason with a network and without one alike, or hides the host name'
ok 'the normaliser reads a resolver'"'"'s reason alike online and offline, and keeps the host name before it'
printf '%s\n' \
  'warning: Could not find remote branch nosuch.example.invalid to clone.' \
  'fatal: Remote branch nosuch.example.invalid not found in upstream origin' \
  'warning: Could not find remote branch is a line git does not print' \
  > "$OUT/probe.in"
[ "$(normalise < "$OUT/probe.in")" = "fatal: Remote branch nosuch.example.invalid not found in upstream origin
warning: Could not find remote branch is a line git does not print" ] \
  || fail 'the normaliser does not drop the warning git 2.39 prints before a refused clone of a missing branch, or drops a line that is not that warning'
ok 'the normaliser drops the warning git 2.39 prints before a refused clone of a missing branch, and nothing else'

A_CODE=0
# THE BLOCK A CASE IS HELD TO: the normalised standard output, a line no script
# here prints, and the normalised standard error.
block() {
  normalise < "$OUT/a.out"
  echo '~~~ standard error ~~~'
  normalise < "$OUT/a.err"
}
expect() { # what was being checked, the exit code it records; its block on standard input
  local label="$1" code="$2"
  cat > "$OUT/expected"
  block > "$OUT/actual"
  diff -u "$OUT/expected" "$OUT/actual" || fail "$label — the run printed other bytes than the block recorded for it"
  [ "$A_CODE" = "$code" ] || fail "$label — the run ended with $A_CODE, and its case records $code"
  ok "$label — the recorded bytes, exit $code"
}
# A PLANTED DEFECT is a copy of a script with one printed line changed, run where
# the case before it ran. It must print other bytes than that case recorded, and
# every line it prints otherwise must carry the planted words, or the difference
# is about something else.
caught() { # what the copy is a copy of, the words planted in it
  block > "$OUT/actual"
  if diff "$OUT/expected" "$OUT/actual" > "$OUT/planted.diff"; then
    fail "a copy of $1 with one line changed printed the bytes its case recorded — the comparison proves nothing"
  fi
  if grep '^> ' "$OUT/planted.diff" | grep -vqF -- "$2"; then
    fail "a copy of $1 printed a line the planted words are not in: $(grep '^> ' "$OUT/planted.diff" | grep -vF -- "$2")"
  fi
  ok "the planted defect was caught — a copy of $1 printing '$2' differs from the recorded bytes in that line alone"
}
must() { # a line the output has to carry
  grep -qF -- "$1" "$OUT/a.out" "$OUT/a.err" || fail "$2 — missing from the output: '$1'"
}
must_not() {
  grep -qF -- "$1" "$OUT/a.out" "$OUT/a.err" && fail "$2 — present in the output: '$1'"
  return 0
}

# ===========================================================================
# ONE — release-platform and status, against a fixture of one origin
# ===========================================================================
ORIGIN_A="$WORK/origin-a.git"
WORK_A="$WORK/checkout-a"

run_bash() { # script base name, then its arguments
  local base="$1"; shift
  A_CODE=0
  ( cd "$WORK_A" && bash "$HERE/$base.sh" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
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
# Its map states the retired word master+slave, and a regeneration has to read it as master.
seed_installation apps4.example.invalid dev '' master+slave
git -C "$SEED" checkout --quiet -b work/no-map master
git -C "$SEED" push --quiet origin work/no-map
git -C "$SEED" checkout --quiet master

git clone --quiet "$ORIGIN_A" "$WORK_A"
ok "fixture built — one origin, one trunk, four installations and one ref that is none"

# ── the clone a pin is written in leaves no maintenance behind it ──────────
# The template above keeps the fixtures quiet. The clone release-platform makes for the pin is the
# script's own, and is removed straight after its commit and push, so it is measured with the
# template taken away: one run of the script on a copy of the fixture, traced.
pin_maintenance_starts() { # the release script to run; prints how many background maintenances its pin of apps3 started
  local d
  d="$(mktemp -d "$WORK/pin.XXXXXX")" || return 1
  cp -a "$ORIGIN_A" "$d/origin.git"
  git clone --quiet "$d/origin.git" "$d/checkout"
  ( cd "$d/checkout" && unset GIT_TEMPLATE_DIR && GIT_TRACE="$d/trace" bash "$1" 0.4.0 alpha apps3.example.invalid ) > /dev/null 2>&1 || {
    echo "the traced release of $1 did not end clean" >&2
    return 1
  }
  git --git-dir="$d/origin.git" show 'apps3.example.invalid:clusters/active/apps3.example.invalid.yaml' | grep -q '^release: 0.4.0-alpha-' || {
    echo "the traced release of $1 pinned nothing on origin, so a count of nothing would prove nothing" >&2
    return 1
  }
  grep -cE 'built-in: git (maintenance run|gc) --auto' "$d/trace" || true
}
STARTED="$(pin_maintenance_starts "$HERE/release-platform.sh")" || fail 'the traced release did not pin'
[ "$STARTED" = '0' ] || fail "release-platform's clone for a pin started $STARTED background maintenance(s), which can still be writing when the clone is removed"
ok "release-platform pins an installation in a clone that starts no background maintenance, with the template taken away"
PLANTED_P="$WORK/planted-pin.sh"
sed 's/ -c maintenance.auto=false//' "$HERE/release-platform.sh" > "$PLANTED_P"
! cmp -s "$HERE/release-platform.sh" "$PLANTED_P" || fail 'the planted clone was not planted — the probe proves nothing'
PLANTED_N="$(pin_maintenance_starts "$PLANTED_P")" || fail 'the traced planted release did not pin'
[ "$PLANTED_N" -gt 0 ] || fail 'a copy of release-platform.sh whose clone does not carry the setting started no background maintenance, so the count above proves nothing'
ok "the planted defect was caught — a copy of release-platform.sh whose clone does not carry the setting starts $PLANTED_N background maintenance(s)"

# ── the refusals, which cost nothing and must leave nothing behind ──────────
run_bash release-platform 1.2 stable apps3.example.invalid
must "version must be x.y.z" 'a version that is not three numbers is refused'
[ "$A_CODE" = '64' ] || fail "a malformed version must end the run with 64, got $A_CODE"
expect 'a version that is not three numbers' 64 <<'RECORDED'
~~~ standard error ~~~
release: version must be x.y.z, the third position three digits such as 000 (got '1.2')
RECORDED

run_bash release-platform 0.1.0 golden apps3.example.invalid
must "channel must be stable, beta or alpha" 'an unknown channel is refused'
expect 'a channel outside the three' 64 <<'RECORDED'
~~~ standard error ~~~
release: channel must be stable, beta or alpha (got 'golden')
RECORDED

run_bash release-platform 0.1.0 stable nosuch.example.invalid
must "origin has no branch nosuch.example.invalid" 'a domain with no install branch is refused'
expect 'a domain that names no install branch' 66 <<'RECORDED'
~~~ standard error ~~~
fatal: Remote branch nosuch.example.invalid not found in upstream origin
release: origin has no branch nosuch.example.invalid. An installation is pinned on its own install branch, and there is none of that name
RECORDED

run_bash release-platform 0.1.0 alpha apps9.example.invalid
must "channel alpha admits only: dev" 'the channel ceiling refuses a prod installation'
expect 'an alpha release aimed at a prod installation' 65 <<'RECORDED'
~~~ standard error ~~~
release: apps9.example.invalid is stage prod and channel alpha admits only: dev. Nothing else would refuse this, so this does.
RECORDED

# NOTHING WAS MINTED BY ANY OF THAT. The refusals above all stand before the
# mint, which is the whole reason the order is what it is.
[ -z "$(git --git-dir="$ORIGIN_A" tag -l)" ] || fail 'a refused run left a tag on origin'
ok 'four refusals, and origin carries no tag — nothing is created before the target is known good'

# ── the mint and the pin ────────────────────────────────────────────────────
run_bash release-platform 0.1.0 alpha apps3.example.invalid
must "release: minted 0.1.0-alpha-" 'the first run mints'
must "release: the tag stands on the remote" 'the tag is read back off the remote before anything is pinned'
must "release: pinned apps3.example.invalid to 0.1.0-alpha-" 'the pin is written'
must "bash lifecycle/regenerate-install-branch.sh apps3.example.invalid" \
     'the second act is named, as the script that performs it'
must_not "ansiwise deploy-branch" 'the second act is a script beside this one, not a command to retype'
expect 'the mint and the pin' 0 <<'RECORDED'
release: minted 0.1.0-alpha-TS14 on origin/master (commit 784fb6e)
release: this tree builds nothing. The tree at the tag IS the release, so there is no image and nothing further to wait for
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: pinned apps3.example.invalid to 0.1.0-alpha-TS14 in clusters/active/apps3.example.invalid.yaml
release: no config beside this tree names a PLATFORM_REF, so none was written
release: no config for apps3.example.invalid beside this tree (lifecycle/config.apps3.env), so it is pinned and not regenerated. Bring it onto 0.1.0-alpha-TS14 with:
release:     bash lifecycle/regenerate-install-branch.sh apps3.example.invalid <config>
~~~ standard error ~~~
RECORDED

TAG_A="$(git --git-dir="$ORIGIN_A" tag -l)"
[ -n "$TAG_A" ] || fail 'the mint pushed no tag to origin'
[ "$(printf '%s\n' "$TAG_A" | wc -l)" = '1' ] || fail "origin carries more than one tag: $TAG_A"
ok "origin carries exactly one tag — $TAG_A"

# THE PIN IS ONE LINE AT COLUMN ONE, and the map is otherwise as it was: the
# grammar the programs checkout's own writing step uses, so a map written by either hand
# reads the same to whatever reads it next.
PINNED="$(git --git-dir="$ORIGIN_A" show "apps3.example.invalid:clusters/active/apps3.example.invalid.yaml")"
[ "$(grep -c '^release: ' <<< "$PINNED")" = '1' ] || fail 'the map does not carry exactly one top-level release line'
grep -q "^release: ${TAG_A}\$" <<< "$PINNED" || fail 'the release line does not carry the tag that was minted'
grep -q '^stage: dev$' <<< "$PINNED" || fail 'the pin disturbed the stage line'
grep -q '^  domain: apps3.example.invalid$' <<< "$PINNED" || fail 'the pin disturbed the global block'
ok 'the map carries one top-level release line and is otherwise untouched'

# ── the second run: the tag is reused and the pin is left as it stands ──────
run_bash release-platform 0.1.0 alpha apps3.example.invalid
must "release: reusing 0.1.0-alpha-" 'a second run for the same version and channel cuts nothing new'
must "already records" 'a pin that already says the right thing is left alone'
must_not "release: minted" 'a second run must not mint'
expect 'the second run for the same version and channel' 0 <<'RECORDED'
release: reusing 0.1.0-alpha-TS14. One release per version and channel, so putting it on apps3.example.invalid cuts nothing new
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: clusters/active/apps3.example.invalid.yaml already records 0.1.0-alpha-TS14, so it is left as it stands
release: no config beside this tree names a PLATFORM_REF, so none was written
release: no config for apps3.example.invalid beside this tree (lifecycle/config.apps3.env), so it is pinned and not regenerated. Bring it onto 0.1.0-alpha-TS14 with:
release:     bash lifecycle/regenerate-install-branch.sh apps3.example.invalid <config>
~~~ standard error ~~~
RECORDED
[ "$(git --git-dir="$ORIGIN_A" tag -l | wc -l)" = '1' ] || fail 'the second run minted a second tag'
ok 'the second run left the one tag standing'

# ── the report, with the installation level ─────────────────────────────────
run_bash status
must "  level: origin/master carries nothing this release does not" 'a freshly pinned installation reports level'
must "  unpinned: nothing records which platform state" 'an installation with no release line reports unpinned'
must "  unresolved: nothing here resolves that to a commit" 'a pin naming a state this repository does not carry says so'
must_not "work/no-map" 'a branch carrying no cluster map is no installation and is not reported'
expect 'the report with one installation level' 0 <<'RECORDED'
status: which platform release each install branch stands on, and what origin/master carries since. A cluster carrying only the slave part has no branch here and runs the revision of the branch that keeps its books

apps3.example.invalid
  release: 0.1.0-alpha-TS14
  level: origin/master carries nothing this release does not

apps4.example.invalid
  release: none
  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release-platform.sh beside this file writes that line.

apps5.example.invalid
  release: 9.9.9-stable-TS14
  unresolved: nothing here resolves that to a commit, so it names a state this repository does not carry: it was never pushed, or it has been deleted

apps9.example.invalid
  release: none
  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release-platform.sh beside this file writes that line.
~~~ standard error ~~~
RECORDED

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

run_bash status
must "  behind: 3 commits on origin/master since that release, 2 of them under clusters, which a regeneration has to carry" \
     'the report counts the commits since the pin and the ones a regeneration has to carry among them'
must "  regenerate: clusters/argocd/files/platform-apps-appset.yaml" 'the report names the file of the reconciler tree that moved'
must "  regenerate: clusters/platform/versions.yaml" 'and the file of the platform values chain, which nothing stamps and a regeneration still carries'
must_not "  regenerate: README.md" 'a file no cluster reads is not reported'
expect 'the report with the trunk three commits ahead' 0 <<'RECORDED'
status: which platform release each install branch stands on, and what origin/master carries since. A cluster carrying only the slave part has no branch here and runs the revision of the branch that keeps its books

apps3.example.invalid
  release: 0.1.0-alpha-TS14
  behind: 3 commits on origin/master since that release, 2 of them under clusters, which a regeneration has to carry
  regenerate: clusters/argocd/files/platform-apps-appset.yaml
  regenerate: clusters/platform/versions.yaml

apps4.example.invalid
  release: none
  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release-platform.sh beside this file writes that line.

apps5.example.invalid
  release: 9.9.9-stable-TS14
  unresolved: nothing here resolves that to a commit, so it names a state this repository does not carry: it was never pushed, or it has been deleted

apps9.example.invalid
  release: none
  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release-platform.sh beside this file writes that line.
~~~ standard error ~~~
RECORDED

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
grep -q 'behind: ' "$OUT/a.out" || fail 'the planted copy printed no behind line — the probe was aimed at a line the fixture does not reach'
caught status.sh 'changes since that release'

# ── the report, narrowed to one installation ───────────────────────────────
run_bash status apps3.example.invalid
must "apps3.example.invalid" 'the named installation is reported'
must_not "apps9.example.invalid" 'no other installation is reported'
expect 'the report narrowed to one installation' 0 <<'RECORDED'
status: which platform release each install branch stands on, and what origin/master carries since. A cluster carrying only the slave part has no branch here and runs the revision of the branch that keeps its books

apps3.example.invalid
  release: 0.1.0-alpha-TS14
  behind: 3 commits on origin/master since that release, 2 of them under clusters, which a regeneration has to carry
  regenerate: clusters/argocd/files/platform-apps-appset.yaml
  regenerate: clusters/platform/versions.yaml
~~~ standard error ~~~
RECORDED

run_bash status nosuch.example.invalid
must "origin has no installation called nosuch.example.invalid" 'a name that is no installation is refused'
[ "$A_CODE" = '66' ] || fail "a name that is no installation must end the run with 66, got $A_CODE"
expect 'a name that is no installation' 66 <<'RECORDED'
~~~ standard error ~~~
status: origin has no installation called nosuch.example.invalid. An installation is a branch of this repository named after its own domain, carrying clusters/active/<domain>.yaml
RECORDED

# ── a tag a refused push left behind is dropped, not reused ─────────────────
# THE STATE A REFUSED PUSH LEAVES. The tag is minted before it is pushed, so a
# push the hook refuses leaves it standing in the checkout and nowhere else,
# naming the commit it was minted for rather than the one a later run releases.
# Reusing it aims every retry at that same commit and is refused for the same
# reason — printed as if it were about the new attempt, until somebody deletes
# the tag by hand.
STALE='0.2.0-alpha-19700101000000'
git -C "$WORK_A" tag -a "$STALE" -m 'left behind by a refused push' origin/apps4.example.invalid
run_bash release-platform 0.2.0 alpha apps4.example.invalid
must "stands on this workstation only" 'the leftover is named as standing nowhere else'
must "it is dropped and cut again" 'and it is dropped rather than reused'
must "release: minted 0.2.0-alpha-" 'a fresh tag is cut in its place'
must_not "release: reusing $STALE" 'the leftover is never reused'
expect 'a tag a refused push left behind' 0 <<'RECORDED'
release: 0.2.0-alpha-TS14 stands on this workstation only and names 53caca1, not the commit this release is cut from. A run whose push was refused left it behind; it is dropped and cut again.
release: minted 0.2.0-alpha-TS14 on origin/master (commit ca2ef88)
release: this tree builds nothing. The tree at the tag IS the release, so there is no image and nothing further to wait for
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: pinned apps4.example.invalid to 0.2.0-alpha-TS14 in clusters/active/apps4.example.invalid.yaml
release: no config beside this tree names a PLATFORM_REF, so none was written
release: no config for apps4.example.invalid beside this tree (lifecycle/config.apps4.env), so it is pinned and not regenerated. Bring it onto 0.2.0-alpha-TS14 with:
release:     bash lifecycle/regenerate-install-branch.sh apps4.example.invalid <config>
~~~ standard error ~~~
RECORDED
[ -z "$(git -C "$WORK_A" tag -l "$STALE")" ] || fail 'the leftover tag still stands in the checkout'
[ "$(git --git-dir="$ORIGIN_A" tag -l '0.2.0-alpha-*' | wc -l)" = '1' ] \
  || fail 'origin does not carry exactly one tag for the version that was cut again'
ok 'the leftover is gone from the checkout and origin carries exactly one tag for that version'

# ── a tag that never reached origin but names the released commit IS reused ──
# The other half of the same reading, and the half that keeps the fix from
# deleting too much: a run whose push was refused for a reason that has nothing
# to do with the tag is resumable, and re-minting there would cut a second tree
# for one release. What decides is not whether the tag was pushed but whether it
# names the commit being released.
RESUMABLE='0.3.0-alpha-19700101000000'
git -C "$WORK_A" tag -a "$RESUMABLE" -m 'minted, not yet pushed' origin/master
run_bash release-platform 0.3.0 alpha apps4.example.invalid
must "release: reusing $RESUMABLE" 'a leftover naming the released commit is reused as it stands'
must_not "is dropped and cut again" 'and nothing is dropped'
must_not "release: minted 0.3.0" 'and nothing is cut a second time'
expect 'a tag that never reached origin but names the released commit' 0 <<'RECORDED'
release: reusing 0.3.0-alpha-TS14. One release per version and channel, so putting it on apps4.example.invalid cuts nothing new
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: pinned apps4.example.invalid to 0.3.0-alpha-TS14 in clusters/active/apps4.example.invalid.yaml
release: no config beside this tree names a PLATFORM_REF, so none was written
release: no config for apps4.example.invalid beside this tree (lifecycle/config.apps4.env), so it is pinned and not regenerated. Bring it onto 0.3.0-alpha-TS14 with:
release:     bash lifecycle/regenerate-install-branch.sh apps4.example.invalid <config>
~~~ standard error ~~~
RECORDED
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
# origin, every map records it, and the ref without a map did not move.
HEADS_A="$(git --git-dir="$ORIGIN_A" for-each-ref --format='%(refname) %(objectname)' refs/heads)"
run_bash release-platform 0.4.0 alpha
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
expect 'the mint that names no installation' 0 <<'RECORDED'
release: minted 0.4.0-alpha-TS14 on origin/master (commit ca2ef88)
release: this tree builds nothing. The tree at the tag IS the release, so there is no image and nothing further to wait for
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: pinned apps3.example.invalid to 0.4.0-alpha-TS14 in clusters/active/apps3.example.invalid.yaml
release: pinned apps4.example.invalid to 0.4.0-alpha-TS14 in clusters/active/apps4.example.invalid.yaml
release: apps5.example.invalid is stage test and channel alpha admits only: dev - left as it stands
release: apps9.example.invalid is stage prod and channel alpha admits only: dev - left as it stands
release: no config beside this tree names a PLATFORM_REF, so none was written
release: no config for apps3.example.invalid beside this tree (lifecycle/config.apps3.env), so it is pinned and not regenerated. Bring it onto 0.4.0-alpha-TS14 with:
release:     bash lifecycle/regenerate-install-branch.sh apps3.example.invalid <config>
release: no config for apps4.example.invalid beside this tree (lifecycle/config.apps4.env), so it is pinned and not regenerated. Bring it onto 0.4.0-alpha-TS14 with:
release:     bash lifecycle/regenerate-install-branch.sh apps4.example.invalid <config>
~~~ standard error ~~~
RECORDED
[ -n "$(git --git-dir="$ORIGIN_A" tag -l '0.4.0-alpha-*')" ] || fail 'the mint that names no installation put no tag on origin'
for ref in work/no-map apps5.example.invalid apps9.example.invalid; do
  [ "$(git --git-dir="$ORIGIN_A" rev-parse "refs/heads/$ref")" = "$(grep "^refs/heads/$ref " <<< "$HEADS_A" | cut -d' ' -f2)" ] \
    || fail "the release moved $ref, which it had no business touching"
done
for each in apps3 apps4; do
  git --git-dir="$ORIGIN_A" show "$each.example.invalid:clusters/active/$each.example.invalid.yaml" | grep -q '^release: 0.4.0-alpha-' \
    || fail "the map of $each does not record the release on origin"
done
ok 'the mint that names no installation reached origin, pinned the installations its channel admits, and moved nothing else'
# ── the counter-probes: ONE argument became optional, and no more ───────────
# Without these the case above would only prove that the arity check was
# loosened, not that it was loosened by exactly one argument.
run_bash release-platform 0.5.0
must "usage: lifecycle/release-platform.sh" 'a run naming a version and no channel is still refused'
[ "$A_CODE" = '64' ] || fail "a run naming no channel must end with 64, got $A_CODE"
expect 'a run naming a version and no channel' 64 <<'RECORDED'
~~~ standard error ~~~
release: usage: lifecycle/release-platform.sh <x.y.z> <stable|beta|alpha> [fqdn]
RECORDED

run_bash release-platform 0.4.0 stable nosuch.example.invalid
must "origin has no branch nosuch.example.invalid" 'a domain with no install branch is still refused by name'
must_not "release: reusing" 'and it is refused before the tag it would have reused is read'
[ "$A_CODE" = '66' ] || fail "a domain that names no install branch must still end with 66, got $A_CODE"
expect 'a domain with no install branch, now that the third argument is optional' 66 <<'RECORDED'
~~~ standard error ~~~
fatal: Remote branch nosuch.example.invalid not found in upstream origin
release: origin has no branch nosuch.example.invalid. An installation is pinned on its own install branch, and there is none of that name
RECORDED

# ── the configs beside the tree take the tag and keep their access list ─────
# A RELEASE REWRITES PLATFORM_REF IN PLACE, in every lifecycle/config.*.env
# beside the tree it runs in, the example excepted, and a launcher then demands
# that the file is still owner-only. The write truncates the file where it
# stands rather than moving a copy over it, which would carry the copy's mode.
# So the fixture config is made owner-only with chmod, the release runs, and the
# guard the launchers use is asked again with the real stat. The config is named
# after no installation, so no regeneration is started over a session, and the release
# names apps4, whose pin no case below reads back.
mkdir -p "$WORK_A/lifecycle"
printf "PLATFORM_REF=''\n" > "$WORK_A/lifecycle/config.example.env"
printf "PLATFORM_REF='0.0.0-alpha-19700101000000'\nFQDN='other.example.invalid'\n" > "$WORK_A/lifecycle/config.other.env"
chmod 600 "$WORK_A/lifecycle/config.other.env"
require_owner_only "$WORK_A/lifecycle/config.other.env" \
  || fail "the fixture config could not be made owner-only: it $REACH"
run_bash release-platform 0.6.0 alpha apps4.example.invalid
must "release: pinned apps4.example.invalid to 0.6.0-alpha-" 'the named installation is pinned'
must "release: PLATFORM_REF=0.6.0-alpha-" 'the tag is written into the config beside the tree'
must "written into 1 config(s) under lifecycle/" 'and the example beside it is not counted'
expect 'the mint that rewrites the config beside the tree' 0 <<'RECORDED'
release: minted 0.6.0-alpha-TS14 on origin/master (commit ca2ef88)
release: this tree builds nothing. The tree at the tag IS the release, so there is no image and nothing further to wait for
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: pinned apps4.example.invalid to 0.6.0-alpha-TS14 in clusters/active/apps4.example.invalid.yaml
release: PLATFORM_REF=0.6.0-alpha-TS14 written into 1 config(s) under lifecycle/
release: no config for apps4.example.invalid beside this tree (lifecycle/config.apps4.env), so it is pinned and not regenerated. Bring it onto 0.6.0-alpha-TS14 with:
release:     bash lifecycle/regenerate-install-branch.sh apps4.example.invalid <config>
~~~ standard error ~~~
RECORDED
grep -q "^PLATFORM_REF='0.6.0-alpha-" "$WORK_A/lifecycle/config.other.env" \
  || fail "the config does not carry the tag as PLATFORM_REF"
grep -q "^FQDN='other.example.invalid'\$" "$WORK_A/lifecycle/config.other.env" \
  || fail "the rewrite disturbed a line of the config"
grep -q "^PLATFORM_REF=''\$" "$WORK_A/lifecycle/config.example.env" \
  || fail "the rewrite touched the example"
require_owner_only "$WORK_A/lifecycle/config.other.env" \
  || fail "the rewrite took the access list off the config: it $REACH"
ok 'the release rewrote PLATFORM_REF in place, left the example alone, and the config still passes the owner-only guard asked with the real tools'

# ── a checkout that lags origin/master is brought onto it before the mint ───
# THE PUSH GATE LETS THROUGH ONLY WHAT IS CHECKED OUT, and the tag goes on
# origin/master: a unit's release pins master behind the checkout's back, and a
# mint from the lagging checkout had its tag refused after it was cut. The
# fixture's origins carry no gate, so what is measured is the precondition the
# gate holds the push to: HEAD stands on origin/master when the tag is pushed.
git -C "$WORK_A" reset --quiet --hard HEAD~1
run_bash release-platform 0.7.0 alpha apps4.example.invalid
must "release: master is fast-forwarded onto origin/master" 'a lagging master is brought onto origin/master'
must "release: minted 0.7.0-alpha-" 'and the run goes on to mint'
expect 'a checkout whose master lags origin/master' 0 <<'RECORDED'
release: master is fast-forwarded onto origin/master, where the tag goes - the push gate lets through only what is checked out
release: minted 0.7.0-alpha-TS14 on origin/master (commit ca2ef88)
release: this tree builds nothing. The tree at the tag IS the release, so there is no image and nothing further to wait for
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: pinned apps4.example.invalid to 0.7.0-alpha-TS14 in clusters/active/apps4.example.invalid.yaml
release: PLATFORM_REF=0.7.0-alpha-TS14 written into 1 config(s) under lifecycle/
release: no config for apps4.example.invalid beside this tree (lifecycle/config.apps4.env), so it is pinned and not regenerated. Bring it onto 0.7.0-alpha-TS14 with:
release:     bash lifecycle/regenerate-install-branch.sh apps4.example.invalid <config>
~~~ standard error ~~~
RECORDED
[ "$(git -C "$WORK_A" rev-parse HEAD)" = "$(git -C "$WORK_A" rev-parse origin/master)" ] \
  || fail "the checkout does not stand on origin/master after the run"
ok 'the lagging checkout stands on origin/master, the commit the tag names'

# ── a checkout with commits of its own stops before anything is cut ─────────
echo "# a line only this checkout has" >> "$WORK_A/README.md"
git -C "$WORK_A" commit --quiet -am "A commit origin does not carry"
run_bash release-platform 0.8.0 alpha apps4.example.invalid
must "carries commits origin/master does not" 'a master ahead of origin/master is refused'
must_not "release: minted" 'the refusal comes before the mint'
[ "$A_CODE" = '65' ] || fail "a checkout that cannot be brought onto origin/master must end with 65, got $A_CODE"
expect 'a checkout whose master carries its own commits' 65 <<'RECORDED'
~~~ standard error ~~~
release: this checkout is not master, or carries commits origin/master does not, so it cannot be brought onto origin/master: the tag goes there and the push gate lets through only what is checked out. Check out master and push or drop its own commits, then release again
RECORDED
[ -z "$(git -C "$WORK_A" tag -l '0.8.0-*')" ] || fail "the refused run left a tag in the checkout"
git -C "$WORK_A" reset --quiet --hard origin/master
[ -z "$(git --git-dir="$ORIGIN_A" tag -l '0.8.0-*')" ] \
  || fail 'the refused run pushed a tag'
ok 'the refused run cut no tag, here or on origin'

# ===========================================================================
# TWO — regenerate-install-branch, on the fixture the release above pinned
#
# EVERY CASE HERE IS A REFUSAL, and that is what this can measure: the act
# itself opens a session to a machine, and there is no machine. What it proves is
# the half that stands before one is touched — that a branch, a map, a pin and a
# tag are asked of the remote first, and the words each refusal is made in.
# ===========================================================================
NOCONFIG="$WORK/there-is-no-config.env"

run_bash regenerate-install-branch
must "usage: lifecycle/regenerate-install-branch.sh <fqdn>" 'a run naming no installation is refused'
[ "$A_CODE" = '64' ] || fail "a run naming no installation must end with 64, got $A_CODE"
expect 'a run naming no installation' 64 <<'RECORDED'
~~~ standard error ~~~
regenerate: usage: lifecycle/regenerate-install-branch.sh <fqdn> [config] [--discard]. Nothing has been changed
RECORDED

run_bash regenerate-install-branch nosuch.example.invalid "$NOCONFIG"
must "origin has no branch nosuch.example.invalid" 'a domain with no install branch is refused'
must "Nothing has been changed" 'a refusal says that nothing has been changed'
[ "$A_CODE" = '66' ] || fail "a domain that names no install branch must end with 66, got $A_CODE"
expect 'a domain that names no install branch' 66 <<'RECORDED'
~~~ standard error ~~~
regenerate: origin has no branch nosuch.example.invalid. An installation is regenerated on its own install branch, and there is none of that name. Nothing has been changed
RECORDED

run_bash regenerate-install-branch apps9.example.invalid "$NOCONFIG"
must "carries no release line" 'an installation whose map records no pin is refused'
must "release-platform" 'the refusal names the act that writes that line'
[ "$A_CODE" = '65' ] || fail "a map with no release line must end with 65, got $A_CODE"
expect 'an installation whose map carries no release line' 65 <<'RECORDED'
~~~ standard error ~~~
regenerate: clusters/active/apps9.example.invalid.yaml on branch apps9.example.invalid carries no release line, so nothing records which state this installation is to stand on. release-platform.sh beside this file writes that line. Nothing has been changed
RECORDED

run_bash regenerate-install-branch apps5.example.invalid "$NOCONFIG"
must "origin carries no 9.9.9-stable-19700101000000" 'a pin naming a tag the remote does not carry is refused'
[ "$A_CODE" = '69' ] || fail "a pin the remote cannot resolve must end with 69, got $A_CODE"
expect 'a pin naming a tag that is not on the remote' 69 <<'RECORDED'
~~~ standard error ~~~
regenerate: origin carries no 9.9.9-stable-TS14, and that is what clusters/active/apps5.example.invalid.yaml pins apps5.example.invalid to. The machine fetches from origin, so a state only this workstation knows is a state it cannot reach. Nothing has been changed
RECORDED

# THE PIN IS READ OFF THE BRANCH AND SAID OUT LOUD, which is the whole of what
# this act is told: the ref is nobody's to type. The run then stops on the config,
# before a session is opened, so the line above it is measured without a machine.
run_bash regenerate-install-branch apps3.example.invalid "$NOCONFIG"
must "regenerate: apps3.example.invalid is pinned to 0.4.0-alpha-" 'the pin is read off the branch and named'
must "regenerate: apps3.example.invalid carries role master in clusters/active/apps3.example.invalid.yaml" 'the role is read off the branch and named'
must "there is no config at" 'a run with no config to state the installation is refused'
[ "$A_CODE" = '66' ] || fail "a missing config must end with 66, got $A_CODE"
expect 'the pin read off the branch, and a missing config' 66 <<'RECORDED'
regenerate: apps3.example.invalid is pinned to 0.4.0-alpha-TS14 in clusters/active/apps3.example.invalid.yaml, and that is the state this brings it to
regenerate: apps3.example.invalid carries role master in clusters/active/apps3.example.invalid.yaml, and the branch is regenerated as that; the config's ROLE seeds a first installation only
~~~ standard error ~~~
regenerate: there is no config at <WORK>/there-is-no-config.env. It states the installation this regenerates: copy config.example.env beside it, fill it in, and name it as the second argument. Nothing has been changed
RECORDED

# ── the planted defect for this act ─────────────────────────────────────────
PLANTED_R="$WORK/planted-regenerate.sh"
# The planted copy looks beside itself for its driver and for the guard it reads.
cp "$HERE/regenerate-driver.sh" "$HERE/require-owner-only.sh" "$WORK/"
sed 's/is pinned to/is pinned at/' "$HERE/regenerate-install-branch.sh" > "$PLANTED_R"
grep -q 'is pinned at' "$PLANTED_R" || fail 'the planted line was not planted — the probe proves nothing'
A_CODE=0
( cd "$WORK_A" && bash "$PLANTED_R" apps3.example.invalid "$NOCONFIG" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'is pinned at' "$OUT/a.out" || fail 'the planted copy printed no pin line — the probe was aimed at a line the fixture does not reach'
caught regenerate-install-branch.sh 'is pinned at'

# A CONFIG OTHERS CAN READ is refused by the guard the launcher sources, before
# anything is read out of it. The answer is the mode, which a fixture sets with
# chmod.
REACHABLE="$WORK/config.reachable.env"
printf "FQDN='apps3.example.invalid'\n" > "$REACHABLE"
chmod 644 "$REACHABLE"
run_bash regenerate-install-branch apps3.example.invalid "$REACHABLE"
must "regenerate: $REACHABLE is mode 644 and carries credentials, the elevation password of the machine among them. Run: chmod 600 $REACHABLE. Nothing has been changed" \
  'a config others can read is refused with its mode and the command that closes it'
[ "$A_CODE" = '77' ] || fail "a config others can read must end with 77, got $A_CODE"
expect 'a config of mode 644' 77 <<'RECORDED'
regenerate: apps3.example.invalid is pinned to 0.4.0-alpha-TS14 in clusters/active/apps3.example.invalid.yaml, and that is the state this brings it to
regenerate: apps3.example.invalid carries role master in clusters/active/apps3.example.invalid.yaml, and the branch is regenerated as that; the config's ROLE seeds a first installation only
~~~ standard error ~~~
regenerate: <WORK>/config.reachable.env is mode 644 and carries credentials, the elevation password of the machine among them. Run: chmod 600 <WORK>/config.reachable.env. Nothing has been changed
RECORDED

# THE ROLE IS THE MAP'S AND NOT THE CONFIG'S, AND THE RETIRED WORD IS A MASTER. apps4's
# branch states master+slave, written before hostyour-cloud#232; the regeneration names it,
# reads it as master and appends that behind the config (hostyour-cloud#220).
run_bash regenerate-install-branch apps4.example.invalid "$NOCONFIG"
must "regenerate: apps4.example.invalid carries role master+slave in clusters/active/apps4.example.invalid.yaml, a word retired by hostyour-cloud#232" 'a map stating the retired word is named as such'
must "regenerate: apps4.example.invalid carries role master in clusters/active/apps4.example.invalid.yaml" 'and is regenerated as master, whatever a config would say'
must "there is no config at" 'and the run still stops on the config, before a session is opened'
expect 'the role read off the branch of a master that took the slave part' 66 <<'RECORDED'
regenerate: apps4.example.invalid is pinned to 0.7.0-alpha-TS14 in clusters/active/apps4.example.invalid.yaml, and that is the state this brings it to
regenerate: apps4.example.invalid carries role master+slave in clusters/active/apps4.example.invalid.yaml, a word retired by hostyour-cloud#232: a master carries the slave part as well, so it is regenerated as role master
regenerate: apps4.example.invalid carries role master in clusters/active/apps4.example.invalid.yaml, and the branch is regenerated as that; the config's ROLE seeds a first installation only
~~~ standard error ~~~
regenerate: there is no config at <WORK>/there-is-no-config.env. It states the installation this regenerates: copy config.example.env beside it, fill it in, and name it as the second argument. Nothing has been changed
RECORDED

# THE DRIVER IS WHAT RUNS ON THE MACHINE, and a launcher without it can start
# nothing. The launcher is copied where it is not, so it looks for it beside
# itself and finds nothing.
mkdir -p "$WORK/driverless"
cp "$HERE/regenerate-install-branch.sh" "$WORK/driverless/"
A_CODE=0
( cd "$WORK_A" && bash "$WORK/driverless/regenerate-install-branch.sh" apps3.example.invalid ) \
  > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
must "regenerate-driver.sh is not beside this file" 'a launcher without its driver is refused'
[ "$A_CODE" = '66' ] || fail "a missing driver must end with 66, got $A_CODE"
expect 'a launcher standing without its driver' 66 <<'RECORDED'
~~~ standard error ~~~
regenerate: regenerate-driver.sh is not beside this file. It IS the regeneration on the machine, and this only starts it. Nothing has been changed
RECORDED

# ===========================================================================
# THREE — remove-slave-from-master, against a fixture of its own
#
# EVERY CASE HERE IS A REFUSAL, for the reason every regeneration case above is
# one: the act itself opens a session to a master, and there is no master. What
# it proves is the half that stands before one is touched — that the master's
# branch, the map it keeps for the slave, what that map says the slave is, and
# whether the slave still answers are all asked first, and the words each
# refusal is made in.
# ===========================================================================
ORIGIN_S="$WORK/origin-s.git"
SLAVEWORK_A="$WORK/slave-a"

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

# A cluster map as the programs checkout's template writes one: the three top-level keys
# a reader outside Helm selects on, then the block a chart resolves through.
seed_map() { # fqdn, role, the cluster that keeps its books, the name (the first label unless said)
  local fqdn="$1" role="$2" books="$3" name="${4:-${1%%.*}}"
  {
    echo "stage: prod"
    echo "role: $role"
    echo "booksCluster: $books"
    echo ""
    echo "global:"
    echo "  domain: $fqdn"
    echo "  clusterName: $name"
    echo "  booksCluster: $books"
  } > "$SSEED/clusters/active/$fqdn.yaml"
}

# THE MASTER'S OWN BRANCH IS WHERE THE BOOKS STAND, so every map below is on it:
# its own, one slave it keeps, one cluster that is no slave at all, and one slave
# whose books are somebody else's.
git -C "$SSEED" checkout --quiet -b apps6.example.invalid master
seed_map apps6.example.invalid master apps6.example.invalid
# A SLAVE RENAMED SINCE ITS ADOPTION: its name is not the first label of the domain it stands on now,
# so a spelling that worked the name out of the domain would name what goes wrongly.
seed_map apps7.example.invalid slave apps6.example.invalid s7
seed_map apps8.example.invalid master apps8.example.invalid
seed_map apps9.example.invalid slave other.example.invalid
git -C "$SSEED" add -A
git -C "$SSEED" commit --quiet -m "Cut the master's branch with the maps it keeps"
git -C "$SSEED" push --quiet origin apps6.example.invalid
git -C "$SSEED" checkout --quiet master

git clone --quiet "$ORIGIN_S" "$SLAVEWORK_A"
ok "fixture built — one origin, a master's branch, the map of one slave it keeps and two that are not that"

# THE MASTER'S CONFIG, which this act is given and only reads. It states no
# credential worth the name and it stands INSIDE a git working tree that does not
# ignore it, which is deliberate: that is the last guard the launcher asks, and
# it is therefore where a case that has passed everything else can stop and
# still be held to its recorded bytes.
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

run_remove_bash() { # the arguments of the act
  A_CODE=0
  ( cd "$SLAVEWORK_A" && bash "$HERE/remove-slave-from-master.sh" "$@" ) \
    > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}

run_remove_bash
must "usage: lifecycle/remove-slave-from-master.sh <slave-fqdn>" 'a run naming no slave is refused'
[ "$A_CODE" = '64' ] || fail "a run naming no slave must end with 64, got $A_CODE"
expect 'a run naming no slave' 64 <<'RECORDED'
~~~ standard error ~~~
remove-slave: usage: lifecycle/remove-slave-from-master.sh <slave-fqdn> [config] [--name <slave-name>] [--even-if-running]. Nothing has been changed
RECORDED

# THE DRIVER IS WHAT RUNS ON THE MACHINE, and a launcher without it can start
# nothing. The launcher is copied where it is not, so it looks for it beside
# itself and finds nothing.
mkdir -p "$WORK/slave-driverless"
cp "$HERE/remove-slave-from-master.sh" "$WORK/slave-driverless/"
A_CODE=0
( cd "$SLAVEWORK_A" && bash "$WORK/slave-driverless/remove-slave-from-master.sh" apps7.example.invalid ) \
  > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
must "remove-slave-driver.sh is not beside this file" 'a launcher without its driver is refused'
[ "$A_CODE" = '66' ] || fail "a missing driver must end with 66, got $A_CODE"
expect 'a launcher standing without its driver' 66 <<'RECORDED'
~~~ standard error ~~~
remove-slave: remove-slave-driver.sh is not beside this file. It IS the removal on the machine, and this only starts it. Nothing has been changed
RECORDED

run_remove_bash apps7.example.invalid "$NOCONFIG"
must "there is no config at" 'a run with no config to state the master is refused'
must "Nothing has been changed" 'a refusal says that nothing has been changed'
[ "$A_CODE" = '66' ] || fail "a missing config must end with 66, got $A_CODE"
expect 'a run with no config to state the master' 66 <<'RECORDED'
~~~ standard error ~~~
remove-slave: there is no config at <WORK>/there-is-no-config.env. It states the MASTER this removal runs on: copy config.example.env beside it, fill it in, and name it as the second argument. Nothing has been changed
RECORDED

run_remove_bash apps7.example.invalid "$NOBRANCHCFG"
must "origin has no branch nomaster.example.invalid" 'a config naming a master with no install branch is refused'
[ "$A_CODE" = '66' ] || fail "a master with no branch must end with 66, got $A_CODE"
expect 'a config naming a master with no install branch' 66 <<'RECORDED'
~~~ standard error ~~~
remove-slave: origin has no branch nomaster.example.invalid, and <WORK>/slave-a/no-branch-config.env states that as the master. A master keeps its books on its own install branch, and there is none of that name. Nothing has been changed
RECORDED

run_remove_bash nosuch.example.invalid "$MASTERCFG"
# WHERE THE MAP IS GONE, THE NAME IS STATED. The name stood only in the map, and working it out of the
# domain names the wrong objects for a slave that was renamed.
must "keeps no clusters/active/nosuch.example.invalid.yaml, and the slave's name stood only there" \
  'a slave the master keeps no map for is refused until its name is stated'
[ "$A_CODE" = '64' ] || fail "a missing map with no name stated must end with 64, got $A_CODE"
expect 'a slave the master keeps no map for, and no name stated' 64 <<'RECORDED'
~~~ standard error ~~~
remove-slave: branch apps6.example.invalid keeps no clusters/active/nosuch.example.invalid.yaml, and the slave's name stood only there: state it with --name <slave-name> - the name every object of its registration carries. Nothing has been changed
RECORDED

run_remove_bash nosuch.example.invalid "$MASTERCFG" --name nosuch
# A MAP THAT IS GONE IS NOT A REFUSAL once the name is stated. Dropping the slave's part of the books
# is the git side of a removal and the program's header says the caller does it FIRST, so by the
# time the rest is wanted the map has left. What a run does instead is say so, and say what still
# protects a typed name.
must "keeps no clusters/active/nosuch.example.invalid.yaml"   'a slave the master keeps no map for is named rather than refused'
must "every row names objects after the name nosuch, so a name nothing holds removes nothing"   'and the run says what protects a typed name where the map cannot'
expect 'a slave the master keeps no map for' 77 <<'RECORDED'
remove-slave: branch apps6.example.invalid keeps no clusters/active/nosuch.example.invalid.yaml, which is what the git side of a removal leaves behind. Nothing here confirms nosuch.example.invalid stood as a slave of apps6.example.invalid, and every row names objects after the name nosuch, so a name nothing holds removes nothing
remove-slave: nosuch.example.invalid does not answer on port 22, so what this takes off apps6.example.invalid is the registration of a machine that is gone
~~~ standard error ~~~
remove-slave: <WORK>/slave-a/master-config.env stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore. Nothing has been changed
RECORDED

run_remove_bash apps7.example.invalid "$MASTERCFG" --name apps7
must "records the name 's7', and --name says 'apps7'" 'a stated name the map contradicts is refused'
[ "$A_CODE" = '65' ] || fail "a stated name the map contradicts must end with 65, got $A_CODE"
expect 'a stated name the map contradicts' 65 <<'RECORDED'
~~~ standard error ~~~
remove-slave: clusters/active/apps7.example.invalid.yaml on branch apps6.example.invalid records the name 's7', and --name says 'apps7'. The registration stands under the name the map records. Nothing has been changed
RECORDED

run_remove_bash apps8.example.invalid "$MASTERCFG"
must "states role 'master', so what stands under that name is no slave" \
  'a map that does not name the slave part is refused'
[ "$A_CODE" = '65' ] || fail "a map that names no slave part must end with 65, got $A_CODE"
expect 'a map that does not name the slave part' 65 <<'RECORDED'
~~~ standard error ~~~
remove-slave: clusters/active/apps8.example.invalid.yaml on branch apps6.example.invalid states role 'master', so what stands under that name is no slave. This takes a slave's management plane off its master. Nothing has been changed. Nothing has been changed
RECORDED

run_remove_bash apps9.example.invalid "$MASTERCFG"
must "states booksCluster 'other.example.invalid'" 'a slave whose books are another cluster is refused'
[ "$A_CODE" = '65' ] || fail "a slave of another master must end with 65, got $A_CODE"
expect 'a slave whose map names another master' 65 <<'RECORDED'
~~~ standard error ~~~
remove-slave: clusters/active/apps9.example.invalid.yaml on branch apps6.example.invalid states booksCluster 'other.example.invalid', and <WORK>/slave-a/master-config.env states the master apps6.example.invalid. A slave is registered on the master its books name. Nothing has been changed. Nothing has been changed
RECORDED

# THE TARGET IS READ OFF THE MASTER'S BRANCH AND SAID OUT LOUD, and the slave is
# then asked whether it still answers — which is the whole of what this act
# establishes before it opens a session. The fixture's slave resolves to nothing,
# so the verdict is the one this run is for: a machine that is gone. The run then
# stops on the config standing in a tree that does not ignore it.
run_remove_bash apps7.example.invalid "$MASTERCFG"
must "remove-slave: clusters/active/apps7.example.invalid.yaml on branch apps6.example.invalid records apps7.example.invalid as a slave of apps6.example.invalid" \
  'the registration is read off the master branch and named'
must "remove-slave: the name it stands under is s7" \
  "the name is the map's, not the first label of the slave's domain"
must "remove-slave: apps7.example.invalid does not answer on port 22" \
  'the slave is asked whether it is still there, and the verdict is printed'
must "stands inside a git working tree that does not ignore it" \
  'a config a commit could reach is refused before it leaves this workstation'
[ "$A_CODE" = '77' ] || fail "a config a commit could reach must end with 77, got $A_CODE"
expect 'the registration read off the master branch, a slave that is gone, and a config a commit could reach' 77 <<'RECORDED'
remove-slave: clusters/active/apps7.example.invalid.yaml on branch apps6.example.invalid records apps7.example.invalid as a slave of apps6.example.invalid, and its registration on that master is what this takes off
remove-slave: the name it stands under is s7, and every object the removal takes is named after it
remove-slave: apps7.example.invalid does not answer on port 22, so what this takes off apps6.example.invalid is the registration of a machine that is gone
~~~ standard error ~~~
remove-slave: <WORK>/slave-a/master-config.env stands inside a git working tree that does not ignore it. A file of credentials belongs nowhere a commit can reach it: move it out, or name it in that tree's .gitignore. Nothing has been changed
RECORDED

# ── the planted defect for this act ─────────────────────────────────────────
PLANTED_S="$WORK/planted-remove-slave.sh"
cp "$HERE/remove-slave-driver.sh" "$WORK/remove-slave-driver.sh"
sed 's/as a slave of/as a slave to/' "$HERE/remove-slave-from-master.sh" > "$PLANTED_S"
grep -q 'as a slave to' "$PLANTED_S" || fail 'the planted line was not planted — the probe proves nothing'
A_CODE=0
( cd "$SLAVEWORK_A" && bash "$PLANTED_S" apps7.example.invalid "$MASTERCFG" ) \
  > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'as a slave to' "$OUT/a.out" || fail 'the planted copy printed no registration line — the probe was aimed at a line the fixture does not reach'
caught remove-slave-from-master.sh 'as a slave to'

# ===========================================================================
# FOUR — the owner-only guard
#
# THE ANSWER IS THE MODE, 600 or 400. The guard is driven here with stat stood
# in for by a stub on the path, so every case answers the same whatever mode
# the probe really has. Section ONE asked the real stat once already, after the
# release's rewrite.
#
# WHAT PROVES THE STUB IS THE ONE ANSWERING: the probe has one real mode, and
# the guard passes it twice and refuses it once.
# ===========================================================================
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/stat" <<'EOF'
#!/usr/bin/env bash
case "$2" in '%a') printf '%s\n' "$STUB_MODE" ;; *) exit 1 ;; esac
EOF
chmod +x "$STUB"/*
PROBE="$WORK/probe.env"
printf "X='1'\n" > "$PROBE"

guard() { # the stubbed mode -> A_CODE, a.out, a.err
  A_CODE=0
  STUB_MODE="$1" PATH="$STUB:$PATH" \
    bash -c '. "$1/require-owner-only.sh"; require_owner_only "$2" && echo passes || { echo "refused: $2 $REACH. Run: $OWNER_ONLY_COMMAND"; exit 1; }' _ "$HERE" "$PROBE" \
    > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}

guard 600
must 'passes' 'mode 600 passes'
[ "$A_CODE" = '0' ] || fail "mode 600 must pass, got $A_CODE"
[ ! -s "$OUT/a.err" ] || fail "the guard wrote to standard error: $(cat "$OUT/a.err")"

guard 400
must 'passes' 'and so does mode 400'
[ "$A_CODE" = '0' ] || fail "mode 400 must pass, got $A_CODE"

guard 644
must "refused: $PROBE is mode 644. Run: chmod 600 $PROBE" 'mode 644 is refused with the mode sentence as it stands'
[ "$A_CODE" = '1' ] || fail "mode 644 must refuse, got $A_CODE"
ok 'the guard: 600 and 400 pass, and 644 refuses with the mode sentence'

# ── the three launchers refuse in their own sentence, from the one guard ────
# EACH LAUNCHER SAYS WHICH CREDENTIALS THE FILE CARRIES and the guard says who
# can read it and what to run. The mode case is driven through each of the
# three, so the sentences are measured as a person meets them and not only as
# the pieces they are built from.
run_guarded() { # the directory to stand in, the stubbed mode, then the script and its arguments
  local in="$1" mode="$2"; shift 2
  A_CODE=0
  ( cd "$in" && STUB_MODE="$mode" PATH="$STUB:$PATH" bash "$@" ) \
    > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
run_guarded "$WORK_A" 644 "$HERE/install-machine.sh" "$PROBE"
must "$PROBE is mode 644 and carries ten credentials, four of them tokens with WRITE access to your repositories. Run: chmod 600 $PROBE" \
  'the launcher refuses mode 644 in its own sentence'
[ "$A_CODE" = '77' ] || fail "the launcher must refuse a readable config with 77, got $A_CODE"

# The removal reads the master's branch and asks the slave first, so its config
# stands outside every git tree and the guard is the refusal it reaches.
REMOVECFG="$WORK/remove-config.env"
cp "$MASTERCFG" "$REMOVECFG"
run_guarded "$SLAVEWORK_A" 644 "$HERE/remove-slave-from-master.sh" apps7.example.invalid "$REMOVECFG"
must "remove-slave: $REMOVECFG is mode 644 and carries credentials, the elevation password of the machine among them. Run: chmod 600 $REMOVECFG. Nothing has been changed" \
  'the removal refuses mode 644 in its own sentence'
[ "$A_CODE" = '77' ] || fail "the removal must refuse a readable config with 77, got $A_CODE"

run_guarded "$WORK_A" 644 "$HERE/regenerate-install-branch.sh" apps3.example.invalid "$PROBE"
must "regenerate: $PROBE is mode 644 and carries credentials, the elevation password of the machine among them. Run: chmod 600 $PROBE. Nothing has been changed" \
  'the regeneration refuses mode 644 in its own sentence'
[ "$A_CODE" = '77' ] || fail "the regeneration must refuse mode 644 with 77, got $A_CODE"
ok 'the three launchers refuse a readable config in their own sentence, built from the one guard'

# ── install-machine refuses in its recorded sentence ─────────────────────────
# install-machine refuses a missing config and a config others can read in the
# words and with the code its cases record, and the sentence carries no exit
# code.
IMMISSING="$WORK/there-is-no-install-config.env"
run_bash install-machine "$IMMISSING"
must "there is no config at $IMMISSING. Copy config.example.env, fill it in, and make it readable by you alone" \
  'install-machine: a config that is not there is refused'
must_not "readable by you alone 66" 'install-machine: the exit code is not part of the sentence'
[ "$A_CODE" = '66' ] || fail "install-machine: a missing config must end with 66, got $A_CODE"
expect 'install-machine: a config that is not there' 66 <<'RECORDED'
~~~ standard error ~~~

  there is no config at <WORK>/there-is-no-install-config.env. Copy config.example.env, fill it in, and make it readable by you alone

RECORDED

# The planted defect: a copy of install-machine.sh with one word changed, beside a
# driver and the guard it reads, must print other bytes than its case recorded.
PLANTED_IM="$WORK/planted-install-machine"
mkdir -p "$PLANTED_IM"
cp "$HERE/driver.sh" "$HERE/require-owner-only.sh" "$PLANTED_IM/"
sed 's/make it readable by you alone/make it readable by you only/' "$HERE/install-machine.sh" > "$PLANTED_IM/install-machine.sh"
grep -q 'readable by you only' "$PLANTED_IM/install-machine.sh" \
  || fail 'the planted line was not planted in install-machine.sh — the probe proves nothing'
A_CODE=0
( cd "$WORK_A" && bash "$PLANTED_IM/install-machine.sh" "$IMMISSING" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'readable by you only' "$OUT/a.err" \
  || fail 'the planted install-machine printed no planted line — the probe was aimed at a line the fixture does not reach'
caught install-machine.sh 'readable by you only'
IMREACH="$WORK/install-machine.env"
printf "X='1'\n" > "$IMREACH"
chmod 644 "$IMREACH"
run_bash install-machine "$IMREACH"
must "$IMREACH is mode 644 and carries ten credentials, four of them tokens with WRITE access to your repositories. Run: chmod 600 $IMREACH" \
  'install-machine: a config others can read is refused with its mode and the command that closes it'
[ "$A_CODE" = '77' ] || fail "install-machine: a config others can read must end with 77, got $A_CODE"
expect 'install-machine: a config of mode 644' 77 <<'RECORDED'
~~~ standard error ~~~

  <WORK>/install-machine.env is mode 644 and carries ten credentials, four of them tokens with WRITE access to your repositories. Run: chmod 600 <WORK>/install-machine.env

RECORDED

# A RELATIVE PATH, as a person types it, is named as it was given; an absolute
# path could not tell that from a path the launcher resolved first.
printf "X='1'\n" > "$WORK_A/install-machine-relative.env"
chmod 644 "$WORK_A/install-machine-relative.env"
run_bash install-machine install-machine-relative.env
must "install-machine-relative.env is mode 644 and carries ten credentials, four of them tokens with WRITE access to your repositories. Run: chmod 600 install-machine-relative.env" \
  'install-machine: a config named by a relative path is named as it was given'
must_not "$WORK_A/install-machine-relative.env" 'install-machine: the launcher does not resolve the path it names'
expect 'install-machine: a config of mode 644 named by a relative path' 77 <<'RECORDED'
~~~ standard error ~~~

  install-machine-relative.env is mode 644 and carries ten credentials, four of them tokens with WRITE access to your repositories. Run: chmod 600 install-machine-relative.env

RECORDED

# ── install-machine refuses a first master stated on the ACME account ────────
# AN INSTALLATION IS BORN ON platform-local: a config that states ACME_CREDENTIALS_JSON is refused
# in its sentence, with 65, before the first session, and never with its value. A recording ssh
# stands first on PATH; the refusal must leave it uncalled, and a copy without the refusal calls it.
ACMESSH="$WORK/acme-ssh"
mkdir -p "$ACMESSH"
cat > "$ACMESSH/ssh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/called"
echo 'ssh: connect to host stub port 22: Connection refused' >&2
exit 255
STUB
chmod +x "$ACMESSH/ssh"
IMACME="$WORK/install-machine-acme.env"
cat > "$IMACME" <<'CONFIG'
FQDN='master.example.invalid'
OPERATOR_USER='operator'
STAGE='prod'
DEPLOY_REPO='https://example.invalid/deploy.git'
PROGRAMS_REPO='https://example.invalid/programs.git'
PLATFORM_REPO='https://example.invalid/platform.git'
PLATFORM_REF='master'
ELEVATION_PASSWORD='elevation-test'
CLUSTER_ISSUER='platform-acme'
ACME_CREDENTIALS_JSON='{"keyId":"kid-shown-nowhere","b64MacKey":"mac-shown-nowhere"}'
CONFIG
chmod 600 "$IMACME"
run_acme() { # the script, then its config
  A_CODE=0
  ( cd "$WORK_A" && PATH="$ACMESSH:$PATH" bash "$1" "$2" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
run_acme "$HERE/install-machine.sh" "$IMACME"
[ ! -e "$ACMESSH/called" ] || fail "install-machine: a config stating ACME_CREDENTIALS_JSON opened a session: $(cat "$ACMESSH/called")"
must_not 'shown-nowhere' 'install-machine: the refusal does not show the binding'
expect 'install-machine: a first master stated on the ACME account' 65 <<'RECORDED'
~~~ standard error ~~~

  <WORK>/install-machine-acme.env states ACME_CREDENTIALS_JSON, and an installation is born on platform-local, because its ACME account is delivered through a Vault that does not stand yet: install it with ACME_CREDENTIALS_JSON empty or commented out, ACME_EMAIL and ACME_SERVER still stated, and CLUSTER_ISSUER='platform-local', then state it, set CLUSTER_ISSUER='platform-acme', run regenerate-install-branch.sh master.example.invalid <WORK>/install-machine-acme.env and the Manager's cluster-redeploy of this machine

RECORDED
# The planted defect: a copy without the refusal, beside the driver and the guard, reaches the session.
PLANTED_ACME="$WORK/planted-install-machine-acme"
mkdir -p "$PLANTED_ACME"
cp "$HERE/driver.sh" "$HERE/require-owner-only.sh" "$PLANTED_ACME/"
grep -vF '[ -z "${ACME_CREDENTIALS_JSON:-}" ] ||' "$HERE/install-machine.sh" > "$PLANTED_ACME/install-machine.sh"
cmp -s "$HERE/install-machine.sh" "$PLANTED_ACME/install-machine.sh" \
  && fail 'the refusal was not taken out of the planted install-machine.sh — the probe proves nothing'
run_acme "$PLANTED_ACME/install-machine.sh" "$IMACME"
[ -e "$ACMESSH/called" ] || fail 'the planted install-machine without the refusal opened no session either — the case cannot go red'
[ "$A_CODE" = '69' ] || fail "the planted install-machine must end at the recording ssh with 69, got $A_CODE"
rm -f "$ACMESSH/called"
ok 'the planted defect was caught — a copy without the refusal opens a session with the ACME config'

# ===========================================================================
# FIVE — abandon-installation, against a fixture of an installation that is gone
#
# ONE INSTALLATION AS ITS BRANCH RECORDS IT: a master whose map lists two
# addresses in the flow spelling the branch program writes, one slave whose map
# lists one in the block spelling the Manager writes, two consumer registrations
# at two stages (and a build.yaml, which names no stage and must be passed
# over), a slave's own install branch of the earlier layout, and one tenant
# registration on the deploy repository's books branch of the same name. The zone carries
# what such an installation leaves: its wildcards and one platform host name at
# its addresses, both unit records, the tenant's wildcard, the sender domains'
# address records and SPF, and beside them everything the act must NOT touch —
# a foreign address under a unit's own name, the machine's own address record,
# a DKIM key, a DMARC policy, an SPF merged with another sender's include, and
# an MX. The second zone is the platform domain's, so the zone walk is measured
# across two zones.
# ===========================================================================
ABANDON="$WORK/abandon"
mkdir -p "$ABANDON"
AORIGIN_A="$ABANDON/origin-a.git"
ADEPLOY_A="$ABANDON/deploy-a.git"
AWORK_A="$ABANDON/checkout-a"
ASEED="$ABANDON/seed"; ACSEED="$ABANDON/cseed"

git init --quiet --bare --initial-branch=master "$AORIGIN_A"
git init --quiet --bare --initial-branch=master "$ADEPLOY_A"
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
  echo "  clusterName: s7"
  echo "  unitApex: example.invalid"
  echo "  nodeCidrs:"
  echo "    - 203.0.113.7/32"
} > "$ASEED/clusters/active/apps7.example.invalid.yaml"
mkdir -p "$ASEED/registrations/digita-post" "$ASEED/registrations/digita-auth"
printf 'name: "digita-post"\ncluster: "apps6"\nhost: "post"\n' > "$ASEED/registrations/digita-post/prod.yaml"
printf 'name: "digita-post"\nrepoURL: "https://example.invalid/post.git"\n' > "$ASEED/registrations/digita-post/build.yaml"
printf 'name: "digita-auth"\ncluster: "s7"\nhost: "auth"\n' > "$ASEED/registrations/digita-auth/dev.yaml"
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
git -C "$ACSEED" remote add origin "$ADEPLOY_A"
echo "* text=auto eol=lf" > "$ACSEED/.gitattributes"
echo "# the deploy repository" > "$ACSEED/README.md"
git -C "$ACSEED" add -A
git -C "$ACSEED" commit --quiet -m "Seed the deploy repository"
git -C "$ACSEED" push --quiet origin master
git -C "$ACSEED" checkout --quiet -b apps6.example.invalid master
mkdir -p "$ACSEED/registrations/t_01acme"
printf 'cluster: "s7"\nsubdomain: "acme"\n' > "$ACSEED/registrations/t_01acme/prod.yaml"
git -C "$ACSEED" add -A
git -C "$ACSEED" commit --quiet -m "Register a tenant"
git -C "$ACSEED" push --quiet origin apps6.example.invalid

git clone --quiet "$AORIGIN_A" "$AWORK_A"

# THE DEPLOY REPOSITORY IS REACHED BY THE ADDRESS THE ACT COMPOSES, https://github.com/<repo>.git,
# and git is told to read that address as the fixture's directory: the act gets
# a global git config of its own, handed over as GIT_CONFIG_GLOBAL, so it
# composes the real address and no test-only switch stands in it.
git config --file "$ABANDON/gitconfig-a" "url.$ADEPLOY_A.insteadOf" 'https://github.com/acme/deploy.git'

# THE INSTALLATION'S CONFIG, read for two values and never run: it states the
# token the stand-in expects and the deploy repository.
ACFG="$ABANDON/config.apps6.env"
{
  echo "FQDN='apps6.example.invalid'"
  echo "CLOUDFLARE_DNS_API_TOKEN='cf-token-of-the-fixture'"
  echo "DEPLOY_REPO='acme/deploy'"
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
chmod +x "$ASTUB/curl"

# THE ZONES, one table each, as they stand before the act. The first column is
# the record id the act has to delete by.
seed_zones() { # the state directory to seed
  mkdir -p "$1"
  printf '%s\t%s\t%s\t%s\n' \
    a0000000000000000000000000000001 '*.apps6.example.invalid' A 203.0.113.6 \
    a0000000000000000000000000000002 argo.apps6.example.invalid A 203.0.113.6 \
    a0000000000000000000000000000003 '*.apps7.example.invalid' CNAME apps7.example.invalid \
    a0000000000000000000000000000014 vault.apps7.example.invalid CNAME other.invalid \
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
ok "fixture built — an origin and a deploy repository carrying one installation, two zones carrying what it left, and a stand-in curl"

# The first argument is what the operator types at the confirmation; the rest
# are the act's own arguments.
run_abandon_bash() {
  local answer="$1"; shift
  A_CODE=0
  ( cd "$AWORK_A" && export GIT_CONFIG_GLOBAL="$ABANDON/gitconfig-a" ABANDON_STUB="$ABANDON/state-a" PATH="$ASTUB:$PATH" \
    && printf '%s\n' "$answer" | bash "$HERE/abandon-installation.sh" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
untouched() { # what was being checked -> the origin, the deploy repository and every zone table stand as seeded
  local label="$1" state="$ABANDON/state-a"
  [ "$(git --git-dir="$AORIGIN_A" for-each-ref --format='%(refname)' refs/heads | wc -l)" = '3' ] || fail "$label — a branch of the platform origin moved"
  [ "$(git --git-dir="$ADEPLOY_A" for-each-ref --format='%(refname)' refs/heads | wc -l)" = '2' ] || fail "$label — a branch of the deploy repository moved"
  [ "$(wc -l < "$state/zone-11111111111111111111111111111111.tsv")" = '13' ] || fail "$label — a record of the first zone went"
  [ "$(wc -l < "$state/zone-22222222222222222222222222222222.tsv")" = '3' ] || fail "$label — a record of the second zone went"
  ! grep -q '^DELETE' "$state/log" || fail "$label — a deletion reached the DNS provider"
}

run_abandon_bash ''
must "usage: lifecycle/abandon-installation.sh <master-fqdn>" 'a run naming no installation is refused'
[ "$A_CODE" = '64' ] || fail "a run naming no installation must end with 64, got $A_CODE"
expect 'a run naming no installation' 64 <<'RECORDED'
~~~ standard error ~~~
abandon: usage: lifecycle/abandon-installation.sh <master-fqdn> [config]
RECORDED

run_abandon_bash '' apps6.example.invalid "$NOCONFIG"
must "there is no config at" 'a run with no config to read the token from is refused'
[ "$A_CODE" = '66' ] || fail "a missing config must end with 66, got $A_CODE"
expect 'a run with no config' 66 <<'RECORDED'
~~~ standard error ~~~
abandon: there is no config at <WORK>/there-is-no-config.env. It is the installation's own, the one it was installed with: name it as the second argument
RECORDED

run_abandon_bash '' apps6.example.invalid "$OTHERCFG"
must "states FQDN='apps9.example.invalid', and this abandons apps6.example.invalid" 'a config of another installation is refused by name'
[ "$A_CODE" = '65' ] || fail "another installation's config must end with 65, got $A_CODE"
expect "another installation's config" 65 <<'RECORDED'
~~~ standard error ~~~
abandon: <WORK>/abandon/config.apps9.env states FQDN='apps9.example.invalid', and this abandons apps6.example.invalid. The config has to be the installation's own, because its token and its deploy repository are what this writes with
RECORDED
untouched 'the three refusals'

# ── the guard: a cluster whose API still answers refuses before any write ────
touch "$ABANDON/state-a/alive"
run_abandon_bash apps6.example.invalid apps6.example.invalid "$ACFG"
must "abandon: apps6.example.invalid keeps its books on branch apps6.example.invalid of origin" 'the books are read off origin and said so'
must "abandon: clusters/active/apps6.example.invalid.yaml records apps6.example.invalid as master at 203.0.113.6, 100.64.0.1" 'the master and its two addresses are read off its map, in the flow spelling'
must "abandon: clusters/active/apps7.example.invalid.yaml records apps7.example.invalid as slave at 203.0.113.7" 'the slave and its address are read off its map, in the block spelling'
must "abandon: the platform host names of apps7.example.invalid: *.apps7.example.invalid, argo-s7.apps6.example.invalid"   "the slave's reconciler is named after the name its map records, not the first label of its domain"
must "abandon: apps6.example.invalid answers on port 16443 at 203.0.113.6 (curl exit 0), so this is a LIVING installation" 'a cluster whose API answers refuses, naming the cluster and the address'
must "Nothing has been changed" 'and the refusal says nothing has been changed'
[ "$A_CODE" = '69' ] || fail "a living installation must refuse with 69, got $A_CODE"
expect 'a living installation' 69 <<'RECORDED'
abandon: apps6.example.invalid keeps its books on branch apps6.example.invalid of origin, and everything below is read there
abandon: clusters/active/apps6.example.invalid.yaml records apps6.example.invalid as master at 203.0.113.6, 100.64.0.1
abandon: the platform host names of apps6.example.invalid: *.apps6.example.invalid and the labels argo build gate grafana idp kube loki-push mail manager prom-push tale tekton vault zot below it
abandon: clusters/active/apps7.example.invalid.yaml records apps7.example.invalid as slave at 203.0.113.7
abandon: the platform host names of apps7.example.invalid: *.apps7.example.invalid, argo-s7.apps6.example.invalid and the labels argo build gate grafana idp kube loki-push mail manager prom-push tale tekton vault zot below apps7.example.invalid
abandon: registrations/digita-auth/dev.yaml stands at auth.dev.example.invalid
abandon: registrations/digita-post/prod.yaml stands at post.example.invalid
abandon: the mail records of platform.invalid: platform.invalid (its address and SPF), prod._domainkey.platform.invalid (DKIM), _dmarc.platform.invalid (DMARC)
abandon: the mail records of example.invalid: example.invalid (its address and SPF), prod._domainkey.example.invalid (DKIM), _dmarc.example.invalid (DMARC)
abandon: the deploy repository's books branch apps6.example.invalid carries registrations/t_01acme/prod.yaml, which stands at *.acme.example.invalid
abandon: apps6.example.invalid itself is the machine's name and not the installation's, so its own address record stays
abandon: 40 names derived; an A or AAAA record among them at 203.0.113.6, 100.64.0.1, 203.0.113.7 is this installation's, so is a CNAME to one of its own cluster names, and so is an SPF that authorises those addresses and nobody else
~~~ standard error ~~~
abandon: apps6.example.invalid answers on port 16443 at 203.0.113.6 (curl exit 0), so this is a LIVING installation. A living installation is offboarded through the Manager and taken back with remove-slave-from-master and the reset, never abandoned. Nothing has been changed
RECORDED
[ "$(grep -c '^PROBE' "$ABANDON/state-a/log")" = '1' ] || fail 'the guard asked more than the first address that answered'
! grep -q '^GET\|^DELETE' "$ABANDON/state-a/log" || fail 'a living installation was refused and the DNS provider was still asked'
untouched 'a living installation'
rm -f "$ABANDON/state-a/alive"
: > "$ABANDON/state-a/log"

# ── the confirmation: anything but the master's domain stops before any write ─
run_abandon_bash no apps6.example.invalid "$ACFG"
must "abandon: registrations/digita-post/prod.yaml stands at post.example.invalid" 'a prod consumer stands at its label under the apex'
must "abandon: registrations/digita-auth/dev.yaml stands at auth.dev.example.invalid" 'a dev consumer stands at its label under the dev zone'
must_not "registrations/digita-post/build.yaml" 'a build registration names no stage and derives no record'
must "abandon: the deploy repository's books branch apps6.example.invalid carries registrations/t_01acme/prod.yaml, which stands at *.acme.example.invalid" 'the tenant wildcard is derived off the deploy repository branch'
must "abandon: the mail records of platform.invalid: platform.invalid (its address and SPF), prod._domainkey.platform.invalid (DKIM), _dmarc.platform.invalid (DMARC)" 'the mail records of the platform domain are named, the DKIM one under the stage'
must "abandon: the mail records of example.invalid:" 'and those of the unit apex'
must "abandon: apps6.example.invalid itself is the machine's name and not the installation's, so its own address record stays" "the machine's own address record is named as staying"
must "abandon: 40 names derived" 'every derived name is counted'
must "abandon: apps6.example.invalid does not answer on port 16443 at 203.0.113.6" 'the master is asked at its public address'
must "abandon: apps6.example.invalid does not answer on port 16443 at 100.64.0.1" 'and at its tailnet address'
must "abandon: apps7.example.invalid does not answer on port 16443 at 203.0.113.7" 'and the slave at its address'
must "abandon: this workstation can push a branch deletion to origin and to the deploy repository" 'the push access is proven before anything is written'
must "abandon: what goes: every record above that proves itself this installation's, the branches apps6.example.invalid apps7.example.invalid on origin, and the books branch apps6.example.invalid of the deploy repository https://github.com/acme/deploy.git. Type apps6.example.invalid to confirm" 'the operator is told what goes and asked to type the domain'
must "abandon: the answer was not apps6.example.invalid, so this stops. Nothing has been changed" 'any other answer stops the act'
[ "$A_CODE" = '65' ] || fail "a declined confirmation must end with 65, got $A_CODE"
expect 'the derivation, the guard on an installation that is gone, and a declined confirmation' 65 <<'RECORDED'
abandon: apps6.example.invalid keeps its books on branch apps6.example.invalid of origin, and everything below is read there
abandon: clusters/active/apps6.example.invalid.yaml records apps6.example.invalid as master at 203.0.113.6, 100.64.0.1
abandon: the platform host names of apps6.example.invalid: *.apps6.example.invalid and the labels argo build gate grafana idp kube loki-push mail manager prom-push tale tekton vault zot below it
abandon: clusters/active/apps7.example.invalid.yaml records apps7.example.invalid as slave at 203.0.113.7
abandon: the platform host names of apps7.example.invalid: *.apps7.example.invalid, argo-s7.apps6.example.invalid and the labels argo build gate grafana idp kube loki-push mail manager prom-push tale tekton vault zot below apps7.example.invalid
abandon: registrations/digita-auth/dev.yaml stands at auth.dev.example.invalid
abandon: registrations/digita-post/prod.yaml stands at post.example.invalid
abandon: the mail records of platform.invalid: platform.invalid (its address and SPF), prod._domainkey.platform.invalid (DKIM), _dmarc.platform.invalid (DMARC)
abandon: the mail records of example.invalid: example.invalid (its address and SPF), prod._domainkey.example.invalid (DKIM), _dmarc.example.invalid (DMARC)
abandon: the deploy repository's books branch apps6.example.invalid carries registrations/t_01acme/prod.yaml, which stands at *.acme.example.invalid
abandon: apps6.example.invalid itself is the machine's name and not the installation's, so its own address record stays
abandon: 40 names derived; an A or AAAA record among them at 203.0.113.6, 100.64.0.1, 203.0.113.7 is this installation's, so is a CNAME to one of its own cluster names, and so is an SPF that authorises those addresses and nobody else
abandon: apps6.example.invalid does not answer on port 16443 at 203.0.113.6
abandon: apps6.example.invalid does not answer on port 16443 at 100.64.0.1
abandon: apps7.example.invalid does not answer on port 16443 at 203.0.113.7
abandon: this workstation can push a branch deletion to origin and to the deploy repository, so every branch below can follow the records
abandon: what goes: every record above that proves itself this installation's, the branches apps6.example.invalid apps7.example.invalid on origin, and the books branch apps6.example.invalid of the deploy repository https://github.com/acme/deploy.git. Type apps6.example.invalid to confirm, or anything else to stop
~~~ standard error ~~~
abandon: the answer was not apps6.example.invalid, so this stops. Nothing has been changed
RECORDED
untouched 'a declined confirmation'
: > "$ABANDON/state-a/log"

# ── the planted defect for this act, on the state nothing has changed yet ────
PLANTED_A="$WORK/planted-abandon.sh"
sed 's/keeps its books on branch/keeps its books at branch/' "$HERE/abandon-installation.sh" > "$PLANTED_A"
grep -q 'keeps its books at branch' "$PLANTED_A" || fail 'the planted line was not planted — the probe proves nothing'
A_CODE=0
( cd "$AWORK_A" && export GIT_CONFIG_GLOBAL="$ABANDON/gitconfig-a" ABANDON_STUB="$ABANDON/state-a" PATH="$ASTUB:$PATH" \
  && printf 'no\n' | bash "$PLANTED_A" apps6.example.invalid "$ACFG" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'keeps its books at branch' "$OUT/a.out" || fail 'the planted copy printed no books line — the probe was aimed at a line the fixture does not reach'
caught abandon-installation.sh 'keeps its books at branch'
untouched 'the planted run'
: > "$ABANDON/state-a/log"

# ── the act itself: the records that prove themselves go, the rest is listed ─
run_abandon_bash apps6.example.invalid apps6.example.invalid "$ACFG"
must "abandon: zone example.invalid: deleted A *.apps6.example.invalid -> 203.0.113.6, the platform host names of apps6.example.invalid" "the master's wildcard at its address goes"
must "abandon: zone example.invalid: deleted A argo.apps6.example.invalid -> 203.0.113.6, a platform host name of apps6.example.invalid" 'and a platform host name written on its own'
must "abandon: zone example.invalid: deleted CNAME *.apps7.example.invalid -> apps7.example.invalid, the platform host names of apps7.example.invalid" "the slave's wildcard, the CNAME deploy-branch writes, goes"
must "abandon: zone example.invalid: left CNAME vault.apps7.example.invalid -> other.invalid, an alias to a name that is no cluster of this installation" 'an alias to a foreign name under a platform host name is left and named'
must "abandon: zone example.invalid: deleted A post.example.invalid -> 203.0.113.6, the consumer digita-post at prod" "the prod consumer's record at the master goes"
must "abandon: zone example.invalid: left A post.example.invalid -> 198.51.100.9, an address this installation never had" 'the foreign record under the same name is left and named'
must "abandon: zone example.invalid: deleted A auth.dev.example.invalid -> 203.0.113.7, the consumer digita-auth at dev" "the dev consumer's record at the slave goes"
must "abandon: zone example.invalid: deleted A *.acme.example.invalid -> 203.0.113.7, the tenant t_01acme at prod" "the tenant's wildcard goes"
must "abandon: zone platform.invalid: deleted A platform.invalid -> 203.0.113.6, the sender domain platform.invalid" "the sender domain's address record at the egress goes"
must "abandon: zone example.invalid: deleted TXT example.invalid (v=spf1 ip4:203.0.113.6 -all), the sender domain example.invalid" "an SPF that authorises the installation's address alone goes"
must "abandon: zone platform.invalid: left TXT platform.invalid (v=spf1 include:_spf.other.invalid ip4:203.0.113.6 -all): it authorises senders beside this installation" 'an SPF merged with another sender is left and named'
must "abandon: zone example.invalid: left TXT prod._domainkey.example.invalid (v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ): nothing on the branch proves that content the installation's" 'the DKIM key is left, because nothing on the branch proves it'
must "abandon: zone example.invalid: left TXT _dmarc.example.invalid (v=DMARC1; p=none; rua=mailto:dmarc@example.inval): nothing on the branch proves that content the installation's" 'and so is the DMARC policy'
must "abandon: zone platform.invalid: left MX platform.invalid -> 10 mx.other.invalid: this act judges A, AAAA, CNAME and TXT records only" 'a record of another type is left and named'
must "abandon: 9 records deleted, 6 left standing and listed above, 29 of the derived names carried nothing" 'the count says what went, what stayed and how many names were empty'
must "abandon: deleted branch apps6.example.invalid on origin" "the master's branch goes"
must "abandon: deleted branch apps7.example.invalid on origin" "the slave's branch goes"
must "abandon: deleted the books branch apps6.example.invalid of the deploy repository https://github.com/acme/deploy.git" "the deploy repository's books branch goes"
must "abandon: $ACFG stays. A local config is the record of the answers a machine was installed with" 'the config is named and stays'
[ "$A_CODE" = '0' ] || fail "the act must end with 0, got $A_CODE"
expect 'the act on an installation that is gone' 0 <<'RECORDED'
abandon: apps6.example.invalid keeps its books on branch apps6.example.invalid of origin, and everything below is read there
abandon: clusters/active/apps6.example.invalid.yaml records apps6.example.invalid as master at 203.0.113.6, 100.64.0.1
abandon: the platform host names of apps6.example.invalid: *.apps6.example.invalid and the labels argo build gate grafana idp kube loki-push mail manager prom-push tale tekton vault zot below it
abandon: clusters/active/apps7.example.invalid.yaml records apps7.example.invalid as slave at 203.0.113.7
abandon: the platform host names of apps7.example.invalid: *.apps7.example.invalid, argo-s7.apps6.example.invalid and the labels argo build gate grafana idp kube loki-push mail manager prom-push tale tekton vault zot below apps7.example.invalid
abandon: registrations/digita-auth/dev.yaml stands at auth.dev.example.invalid
abandon: registrations/digita-post/prod.yaml stands at post.example.invalid
abandon: the mail records of platform.invalid: platform.invalid (its address and SPF), prod._domainkey.platform.invalid (DKIM), _dmarc.platform.invalid (DMARC)
abandon: the mail records of example.invalid: example.invalid (its address and SPF), prod._domainkey.example.invalid (DKIM), _dmarc.example.invalid (DMARC)
abandon: the deploy repository's books branch apps6.example.invalid carries registrations/t_01acme/prod.yaml, which stands at *.acme.example.invalid
abandon: apps6.example.invalid itself is the machine's name and not the installation's, so its own address record stays
abandon: 40 names derived; an A or AAAA record among them at 203.0.113.6, 100.64.0.1, 203.0.113.7 is this installation's, so is a CNAME to one of its own cluster names, and so is an SPF that authorises those addresses and nobody else
abandon: apps6.example.invalid does not answer on port 16443 at 203.0.113.6
abandon: apps6.example.invalid does not answer on port 16443 at 100.64.0.1
abandon: apps7.example.invalid does not answer on port 16443 at 203.0.113.7
abandon: this workstation can push a branch deletion to origin and to the deploy repository, so every branch below can follow the records
abandon: what goes: every record above that proves itself this installation's, the branches apps6.example.invalid apps7.example.invalid on origin, and the books branch apps6.example.invalid of the deploy repository https://github.com/acme/deploy.git. Type apps6.example.invalid to confirm, or anything else to stop
abandon: zone example.invalid: deleted A *.apps6.example.invalid -> 203.0.113.6, the platform host names of apps6.example.invalid
abandon: zone example.invalid: deleted A argo.apps6.example.invalid -> 203.0.113.6, a platform host name of apps6.example.invalid
abandon: zone example.invalid: deleted CNAME *.apps7.example.invalid -> apps7.example.invalid, the platform host names of apps7.example.invalid
abandon: zone example.invalid: left CNAME vault.apps7.example.invalid -> other.invalid, an alias to a name that is no cluster of this installation
abandon: zone example.invalid: deleted A auth.dev.example.invalid -> 203.0.113.7, the consumer digita-auth at dev
abandon: zone example.invalid: deleted A post.example.invalid -> 203.0.113.6, the consumer digita-post at prod
abandon: zone example.invalid: left A post.example.invalid -> 198.51.100.9, an address this installation never had
abandon: zone platform.invalid: deleted A platform.invalid -> 203.0.113.6, the sender domain platform.invalid
abandon: zone platform.invalid: left TXT platform.invalid (v=spf1 include:_spf.other.invalid ip4:203.0.113.6 -all): it authorises senders beside this installation, or none of its addresses; take its mechanism out by hand
abandon: zone platform.invalid: left MX platform.invalid -> 10 mx.other.invalid: this act judges A, AAAA, CNAME and TXT records only
abandon: zone example.invalid: deleted A example.invalid -> 203.0.113.6, the sender domain example.invalid
abandon: zone example.invalid: deleted TXT example.invalid (v=spf1 ip4:203.0.113.6 -all), the sender domain example.invalid
abandon: zone example.invalid: left TXT prod._domainkey.example.invalid (v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ): nothing on the branch proves that content the installation's
abandon: zone example.invalid: left TXT _dmarc.example.invalid (v=DMARC1; p=none; rua=mailto:dmarc@example.inval): nothing on the branch proves that content the installation's
abandon: zone example.invalid: deleted A *.acme.example.invalid -> 203.0.113.7, the tenant t_01acme at prod
abandon: 9 records deleted, 6 left standing and listed above, 29 of the derived names carried nothing
abandon: deleted branch apps6.example.invalid on origin
abandon: deleted branch apps7.example.invalid on origin
abandon: deleted the books branch apps6.example.invalid of the deploy repository https://github.com/acme/deploy.git
abandon: <WORK>/abandon/config.apps6.env stays. A local config is the record of the answers a machine was installed with, and the next machine of that name is installed from it
~~~ standard error ~~~
RECORDED
# THE ORDER OF THE THREE BRANCHES, read off the output rather than assumed.
[ "$(grep -o 'deleted branch apps6.example.invalid on origin\|deleted branch apps7.example.invalid on origin\|deleted the books branch apps6.example.invalid' "$OUT/a.out" | tr '\n' '|')" = \
  'deleted branch apps6.example.invalid on origin|deleted branch apps7.example.invalid on origin|deleted the books branch apps6.example.invalid|' ] \
  || fail 'the three branches were not deleted in the order master, slave, deploy repository, or not exactly three'
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
state="$ABANDON/state-a"
[ "$(grep '^DELETE' "$state/log")" = "$EXPECTED_DELETES" ] \
  || fail "the deletions that reached the provider are not the nine expected, in order: $(grep '^DELETE' "$state/log" | tr '\n' ' ')"
[ "$(grep -c '/dns_records name=' "$state/log")" = '40' ] || fail 'not every derived name was listed at the provider, or one was listed twice'
! grep -q 'dns_records name=apps6.example.invalid$' "$state/log" || fail "the machine's own address record was asked for"
[ "$(grep -c '^PROBE' "$state/log")" = '3' ] || fail 'the three addresses were not each asked once'
[ "$(wc -l < "$state/zone-11111111111111111111111111111111.tsv")" = '5' ] || fail 'the first zone does not keep exactly the foreign record, the foreign alias, the own address record, the DKIM key and the DMARC policy'
grep -q '^a0000000000000000000000000000008	apps6.example.invalid	A	203.0.113.6$' "$state/zone-11111111111111111111111111111111.tsv" \
  || fail "the machine's own address record is gone"
[ "$(wc -l < "$state/zone-22222222222222222222222222222222.tsv")" = '2' ] || fail 'the second zone does not keep exactly the merged SPF and the MX'
[ "$(git --git-dir="$AORIGIN_A" for-each-ref --format='%(refname)' refs/heads)" = 'refs/heads/master' ] || fail 'the platform origin still carries a branch of the installation'
[ "$(git --git-dir="$ADEPLOY_A" for-each-ref --format='%(refname)' refs/heads)" = 'refs/heads/master' ] || fail 'the deploy repository still carries the books branch'
ok 'the nine attributable records went in the derived order, the six the act cannot attribute stand and are named, and the three branches went in order'

# ── the second run on what the first left: nothing to do, and exit 0 ─────────
: > "$ABANDON/state-a/log"
run_abandon_bash apps6.example.invalid apps6.example.invalid "$ACFG"
must "abandon: origin carries no branch apps6.example.invalid, so no map, no address and no registration of it can be read" 'a second run finds no branch and says what that means'
must "abandon: the deploy repository https://github.com/acme/deploy.git carries no books branch apps6.example.invalid" 'and no books branch in the deploy repository'
must "nothing to do" 'and stops with nothing to do'
must "abandon: $ACFG stays" 'and still names the config as staying'
[ "$A_CODE" = '0' ] || fail "a second run with nothing to do must end with 0, got $A_CODE"
expect 'a second run on what the first left' 0 <<'RECORDED'
abandon: origin carries no branch apps6.example.invalid, so no map, no address and no registration of it can be read: no DNS record can be derived or attributed, and the zone is left as it stands
abandon: the deploy repository https://github.com/acme/deploy.git carries no books branch apps6.example.invalid
abandon: nothing of apps6.example.invalid stands on origin or in the deploy repository, and nothing can be derived without its branch: nothing to do
abandon: <WORK>/abandon/config.apps6.env stays. A local config is the record of the answers a machine was installed with, and the next machine of that name is installed from it
~~~ standard error ~~~
RECORDED
[ ! -s "$ABANDON/state-a/log" ] || fail 'a second run with no branch to derive from still reached the provider'
ok 'a second run derives nothing, touches nothing and ends with 0'

# ===========================================================================
# SIX — create-github-app, against a stand-in GitHub and a stand-in browser
#
# EVERYTHING THE ACT REACHES IS A FIXTURE: GitHub's API is a stand-in curl on
# the path, which answers the conversion of the fixture's code with an App whose
# key was minted here, verifies every JWT it is shown against that key's public
# half with openssl, and answers the installation out of a state file; the
# browser is a stand-in named by BROWSER, which fetches the manifest page off
# the act's own listener the way a browser would, reads the state the form
# carries, and sends the browser back with the code — so the listener, the
# page, the nonce and the conversion are all driven end to end. The stand-in
# browser does its work behind and returns at once, the way a real opener does.
#
# WHAT THIS CANNOT PROVE, named rather than counted: GitHub's own answers — the
# shape of the conversion, whether the manifest's hook_attributes without a url
# is accepted, and the real redirect —, a real browser, and the two ten-minute
# bounds. The key minted here is whatever this openssl writes; GitHub hands out
# a PKCS#1 one, and both signers read both.
# ===========================================================================
GHAPP="$WORK/github-app"
GSTUB="$GHAPP/stub"
mkdir -p "$GSTUB" "$GHAPP/a"
REAL_CURL="$(command -v curl)"
openssl genrsa 2048 > "$GHAPP/key.pem" 2>/dev/null || fail 'openssl could not mint the fixture key'
openssl rsa -in "$GHAPP/key.pem" -pubout > "$GHAPP/pub.pem" 2>/dev/null || fail 'openssl could not derive the public half of the fixture key'
# The key as GitHub's JSON spells it: one line, \n for each line break.
awk '{ printf "%s\\n", $0 }' "$GHAPP/key.pem" > "$GHAPP/pem.json"
NINE_PERMISSIONS='"actions":"write","administration":"write","contents":"write","issues":"read","metadata":"read","packages":"read","statuses":"write","webhooks":"write","workflows":"write"'
EIGHT_PERMISSIONS='"actions":"write","administration":"write","contents":"write","issues":"read","metadata":"read","packages":"read","webhooks":"write","workflows":"write"'

# THE STAND-IN FOR curl against api.github.com. Every call is logged as its
# method and path, and a call carrying a JWT logs the verdict on it: the
# signature against the public half, the header, and the claims.
cat > "$GSTUB/curl" <<'EOF'
#!/usr/bin/env bash
state="$GITHUB_STUB"
method=GET; url=''; stdin=''; wantstatus=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -K) shift; stdin="$(cat)" ;;
    -w) shift; wantstatus=1 ;;
    -H) shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
path="${url#https://api.github.com}"
b64url_decode() { tr '_-' '/+' | awk '{ n = length($0) % 4; if (n == 2) print $0 "=="; else if (n == 3) print $0 "="; else print $0 }' | openssl base64 -d -A; }
verdict='none'
case "$stdin" in
  *'Authorization: Bearer '*)
    jwt="${stdin#*Authorization: Bearer }"; jwt="${jwt%%\"*}"
    h="${jwt%%.*}"; s="${jwt##*.}"; p="${jwt#*.}"; p="${p%.*}"
    printf '%s.%s' "$h" "$p" > "$state/signing-input"
    printf '%s' "$s" | b64url_decode > "$state/signature"
    if ! openssl dgst -sha256 -verify "$GITHUB_PUB" -signature "$state/signature" "$state/signing-input" >/dev/null 2>&1; then verdict='bad: signature'
    elif [ "$(printf '%s' "$h" | b64url_decode)" != '{"alg":"RS256","typ":"JWT"}' ]; then verdict='bad: header'
    else
      claims="$(printf '%s' "$p" | b64url_decode)"
      if [[ $claims =~ ^\{\"iat\":([0-9]+),\"exp\":([0-9]+),\"iss\":\"([0-9]+)\"\}$ ]]; then
        iat="${BASH_REMATCH[1]}"; exp="${BASH_REMATCH[2]}"; iss="${BASH_REMATCH[3]}"; now="$(date +%s)"
        if [ $((exp - iat)) -ne 600 ] || [ "$iat" -gt "$now" ] || [ $((now - iat)) -gt 120 ]; then verdict="bad: claims $claims at $now"
        else verdict="verified iss=$iss"; fi
      else verdict="bad: claims $claims"; fi
    fi ;;
esac
log() { printf '%s\n' "$1" >> "$state/log"; }
owner='"owner":{"login":"acme","id":99,"node_id":"O_99","avatar_url":"https://avatars.githubusercontent.com/u/99","html_url":"https://github.com/acme","type":"Organization","site_admin":false}'
case "$method $path" in
  'POST /app-manifests/'*'/conversions')
    code="${path#/app-manifests/}"; code="${code%/conversions}"
    log "POST /app-manifests/$code/conversions"
    if [ "$code" != "$(cat "$state/code")" ]; then
      status=404; body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/apps/apps#create-a-github-app-from-a-manifest","status":"404"}'
    else
      status=201
      body="{\"id\":4711,\"slug\":\"acme-platform-manager\",\"node_id\":\"A_4711\",$owner,\"name\":\"acme-platform-manager\",\"description\":null,\"external_url\":\"https://manager.example.invalid\",\"html_url\":\"https://github.com/apps/acme-platform-manager\",\"created_at\":\"2026-01-01T00:00:00Z\",\"updated_at\":\"2026-01-01T00:00:00Z\",\"permissions\":{$(cat "$state/permissions")},\"events\":[],\"client_id\":\"Iv1.fixture\",\"client_secret\":\"fixture-client-secret\",\"webhook_secret\":null,\"pem\":\"$(cat "$GITHUB_PEM_JSON")\"}"
    fi ;;
  'GET /app')
    log "GET /app jwt=$verdict"
    case "$verdict" in
      verified*) status=200; body="{\"id\":4711,\"slug\":\"acme-platform-manager\",\"node_id\":\"A_4711\",$owner,\"name\":\"acme-platform-manager\",\"description\":null,\"external_url\":\"https://manager.example.invalid\",\"html_url\":\"https://github.com/apps/acme-platform-manager\",\"created_at\":\"2026-01-01T00:00:00Z\",\"updated_at\":\"2026-01-01T00:00:00Z\",\"permissions\":{$(cat "$state/permissions")},\"events\":[]}" ;;
      *) status=401; body='{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest","status":"401"}' ;;
    esac ;;
  'GET /orgs/'*'/installation')
    org="${path#/orgs/}"; org="${org%/installation}"
    log "GET /orgs/$org/installation jwt=$verdict"
    installed="$(cat "$state/installation")"
    case "$verdict" in verified*) ;; *) installed=unauthorised ;; esac
    case "$installed" in
      absent-then-all) printf 'all' > "$state/installation"; status=404; body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/apps/apps#get-an-organization-installation-for-the-authenticated-app","status":"404"}' ;;
      absent) status=404; body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/apps/apps#get-an-organization-installation-for-the-authenticated-app","status":"404"}' ;;
      unauthorised) status=401; body='{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest","status":"401"}' ;;
      *) status=200; body="{\"id\":815,\"account\":{\"login\":\"$org\",\"id\":99,\"node_id\":\"O_99\",\"avatar_url\":\"https://avatars.githubusercontent.com/u/99\",\"html_url\":\"https://github.com/$org\",\"type\":\"Organization\",\"site_admin\":false},\"repository_selection\":\"$installed\",\"access_tokens_url\":\"https://api.github.com/app/installations/815/access_tokens\",\"repositories_url\":\"https://api.github.com/installation/repositories\",\"html_url\":\"https://github.com/organizations/$org/settings/installations/815\",\"app_id\":4711,\"app_slug\":\"acme-platform-manager\",\"target_id\":99,\"target_type\":\"Organization\",\"permissions\":{$(cat "$state/permissions")},\"events\":[],\"created_at\":\"2026-01-01T00:00:00Z\",\"updated_at\":\"2026-01-01T00:00:00Z\",\"single_file_name\":null,\"has_multiple_single_files\":false,\"single_file_paths\":[],\"suspended_by\":null,\"suspended_at\":null}" ;;
    esac ;;
  *) log "$method $path"; status=404; body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}' ;;
esac
printf '%s' "$body"
[ "$wantstatus" = 1 ] && printf '\n%s' "$status"
exit 0
EOF

# THE STAND-IN FOR THE BROWSER. Given the listener's address it fetches the
# manifest page, keeps a copy, reads the state the form carries — or sends a
# wrong one where the state directory says so — and sends the browser back
# with the fixture's code, the way GitHub would after the click, keeping the
# listener's answer. Given any other address it only records it.
cat > "$GSTUB/browser" <<'EOF'
#!/usr/bin/env bash
state="$GITHUB_STUB"
printf '%s\n' "$1" >> "$state/opened"
case "$1" in
  http://127.0.0.1:*/)
    (
      "$REAL_CURL" -sS -o "$state/page.html" "$1"
      nonce="$(sed -n 's/.*settings\/apps\/new?state=\([0-9a-f]*\)".*/\1/p' "$state/page.html")"
      [ -f "$state/wrong-state" ] && nonce=not-this-runs
      "$REAL_CURL" -sS -o "$state/answer" "$1?code=$(cat "$state/code")&state=$nonce"
    ) < /dev/null > "$state/browser.log" 2>&1 &
    ;;
esac
exit 0
EOF
chmod +x "$GSTUB/curl" "$GSTUB/browser"

seed_github() { # the state directory, the permissions the conversion answers, the installation's state
  mkdir -p "$1"
  rm -f "$1"/*
  printf 'c0de0fthefixture' > "$1/code"
  printf '%s' "$2" > "$1/permissions"
  printf '%s' "$3" > "$1/installation"
  : > "$1/log"
}
seed_config() { # a directory -> config.apps6.env there, owner-only, with the three keys empty
  {
    echo "FQDN='apps6.example.invalid'"
    echo "GITHUB_APP_PRIVATE_KEY=''"
    echo "UNIT_APEX='example.invalid'"
    echo "DEPLOY_REPO='acme/deploy'"
    echo "GITHUB_APP_ID=''"
    echo "GITHUB_APP_INSTALLATION_ID=''"
  } > "$1/config.apps6.env"
  chmod 600 "$1/config.apps6.env"
  require_owner_only "$1/config.apps6.env" || fail "the fixture config under $1 could not be made owner-only: it $REACH"
}
run_app_bash() {
  A_CODE=0
  ( cd "$GHAPP/a" && export GITHUB_STUB="$GHAPP/state-a" GITHUB_PUB="$GHAPP/pub.pem" GITHUB_PEM_JSON="$GHAPP/pem.json" REAL_CURL="$REAL_CURL" BROWSER=browser PATH="$GSTUB:$PATH" \
    && bash "$HERE/create-github-app.sh" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
config_line() { # the key -> the value of that key in the config
  sed -n "s/^$1='\(.*\)'\$/\1/p" "$GHAPP/a/config.apps6.env"
}
nothing_written() { # what was being checked -> the config stands as seeded and nothing reached GitHub's writes
  [ "$(config_line GITHUB_APP_ID)" = '' ] || fail "$1 — GITHUB_APP_ID was written"
  [ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '' ] || fail "$1 — GITHUB_APP_INSTALLATION_ID was written"
  [ "$(config_line GITHUB_APP_PRIVATE_KEY)" = '' ] || fail "$1 — GITHUB_APP_PRIVATE_KEY was written"
}
page_holds() { # what was being checked -> the act served a page carrying the manifest asked for
  local page="$GHAPP/state-a/page.html"
  [ -s "$page" ] || fail "$1 — the stand-in browser fetched no page from the listener"
  grep -qF '<form method="post" action="https://github.com/organizations/acme/settings/apps/new?state=' "$page" || fail "$1 — the page does not post to the organisation's new-App page with a state"
  if grep -qF '&quot;' "$page"; then fail "$1 — the page escaped the manifest's quotes, which a single-quoted attribute does not need"; fi
  grep -qF "\"default_permissions\":{$NINE_PERMISSIONS}" "$page" || fail "$1 — the manifest does not carry exactly the nine permissions"
  grep -qF '"hook_attributes":{"active":false}' "$page" || fail "$1 — the manifest does not switch the webhook off"
  grep -qF '"public":false' "$page" || fail "$1 — the manifest does not make the App private"
  grep -qF '"name":"acme-platform-manager","url":"https://manager.example.invalid","redirect_url":"http://127.0.0.1:' "$page" || fail "$1 — the manifest does not name the App, its homepage and the listener"
  grep -qF 'onload="document.forms[0].submit()"' "$page" || fail "$1 — the page does not submit itself"
  [ "$(cat "$GHAPP/state-a/answer")" = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>done</title></head><body>done, back to the terminal</body></html>' ] \
    || fail "$1 — the listener did not answer the redirect with the one line"
}
seed_github "$GHAPP/state-a" "$NINE_PERMISSIONS" all
seed_config "$GHAPP/a"
ok 'fixture built — a key, a stand-in GitHub that verifies every JWT against it, a stand-in browser, and an owner-only config'

# ── the refusals before anything is reached ─────────────────────────────────
run_app_bash
must 'usage: lifecycle/create-github-app.sh <config> [organisation]' 'a run naming no config is refused'
[ "$A_CODE" = '64' ] || fail "a run naming no config must end with 64, got $A_CODE"
expect 'a run naming no config' 64 <<'RECORDED'
~~~ standard error ~~~
create-github-app: usage: lifecycle/create-github-app.sh <config> [organisation]
RECORDED

run_app_bash "$NOCONFIG"
must "there is no config at $NOCONFIG" 'a run with no config is refused'
[ "$A_CODE" = '66' ] || fail "a missing config must end with 66, got $A_CODE"
expect 'a run with no config' 66 <<'RECORDED'
~~~ standard error ~~~
create-github-app: there is no config at <WORK>/there-is-no-config.env. It is the installation's own, the one install-machine is given: name it as the first argument
RECORDED

FULLCFG="$GHAPP/config.full.env"
printf "GITHUB_APP_ID='1'\nGITHUB_APP_INSTALLATION_ID='2'\nGITHUB_APP_PRIVATE_KEY='k'\nDEPLOY_REPO='acme/deploy'\nUNIT_APEX='example.invalid'\n" > "$FULLCFG"
run_app_bash "$FULLCFG"
must "create-github-app: $FULLCFG already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY. Nothing has been changed" 'a config carrying the three answers is refused by name'
[ "$A_CODE" = '65' ] || fail "a config carrying the three answers must end with 65, got $A_CODE"
expect 'a config carrying the three answers' 65 <<'RECORDED'
~~~ standard error ~~~
create-github-app: <WORK>/github-app/config.full.env already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY. Nothing has been changed
RECORDED

PARTCFG="$GHAPP/config.part.env"
printf "GITHUB_APP_ID=''\nGITHUB_APP_INSTALLATION_ID=''\nGITHUB_APP_PRIVATE_KEY='k'\nDEPLOY_REPO='acme/deploy'\nUNIT_APEX='example.invalid'\n" > "$PARTCFG"
run_app_bash "$PARTCFG"
must "create-github-app: $PARTCFG carries GITHUB_APP_PRIVATE_KEY and not GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, and this act cannot tell which App they belong to" 'a config carrying a key and no id is refused, naming what stands and what does not'
[ "$A_CODE" = '65' ] || fail "a config carrying one of the three must end with 65, got $A_CODE"
expect 'a config carrying one of the three answers' 65 <<'RECORDED'
~~~ standard error ~~~
create-github-app: <WORK>/github-app/config.part.env carries GITHUB_APP_PRIVATE_KEY and not GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, and this act cannot tell which App they belong to. Empty all three to create an App, or fill all three by hand. Nothing has been changed
RECORDED

NOORGCFG="$GHAPP/config.noorg.env"
printf "GITHUB_APP_ID=''\nGITHUB_APP_INSTALLATION_ID=''\nGITHUB_APP_PRIVATE_KEY=''\nUNIT_APEX='example.invalid'\n" > "$NOORGCFG"
run_app_bash "$NOORGCFG"
must "create-github-app: $NOORGCFG states no DEPLOY_REPO, and the organisation the App is created in is its owner" 'a config with no DEPLOY_REPO and no organisation argument is refused'
[ "$A_CODE" = '65' ] || fail "a config with no organisation must end with 65, got $A_CODE"
expect 'a config with no organisation' 65 <<'RECORDED'
~~~ standard error ~~~
create-github-app: <WORK>/github-app/config.noorg.env states no DEPLOY_REPO, and the organisation the App is created in is its owner: state it, or name the organisation as the second argument
RECORDED
[ ! -s "$GHAPP/state-a/log" ] || fail 'a refusal before the browser still reached GitHub'
[ ! -f "$GHAPP/state-a/opened" ] || fail 'a refusal before the browser still opened one'

# ── the owner-only guard, before the browser ────────────────────────────────
run_guarded "$GHAPP/a" 644 "$HERE/create-github-app.sh" config.apps6.env
must "create-github-app: config.apps6.env is mode 644 and is where the App's private key lands. Run: chmod 600 config.apps6.env. Nothing has been changed" \
  'a readable config is refused before the browser opens, in the act`s own sentence'
[ "$A_CODE" = '77' ] || fail "a readable config must refuse with 77, got $A_CODE"
[ ! -f "$GHAPP/state-a/opened" ] || fail 'a readable config was refused and the browser was still opened'
nothing_written 'the owner-only guard'
ok 'the five refusals before the browser, and the guard on a readable config'

# ── the state GitHub sends back is held to this run's ────────────────────────
touch "$GHAPP/state-a/wrong-state"
run_app_bash config.apps6.env
must 'create-github-app: the App acme-platform-manager is created in the organisation acme, the owner of DEPLOY_REPO in config.apps6.env, with its homepage https://manager.example.invalid' 'the organisation is read off DEPLOY_REPO and said so'
must 'create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes' 'the listener is announced'
must 'create-github-app: opened the manifest page in the browser; it posts to https://github.com/organizations/acme/settings/apps/new. In the browser: click Create GitHub App' 'the person is told the one click'
must "create-github-app: GitHub sent the browser back with a state that is not this run's, so the code is not trusted. Nothing has been written" 'a redirect carrying another state is refused'
[ "$A_CODE" = '65' ] || fail "a wrong state must refuse with 65, got $A_CODE"
expect 'a redirect carrying another state' 65 <<'RECORDED'
create-github-app: the App acme-platform-manager is created in the organisation acme, the owner of DEPLOY_REPO in config.apps6.env, with its homepage https://manager.example.invalid
create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes
create-github-app: opened the manifest page in the browser; it posts to https://github.com/organizations/acme/settings/apps/new. In the browser: click Create GitHub App
~~~ standard error ~~~
create-github-app: GitHub sent the browser back with a state that is not this run's, so the code is not trusted. Nothing has been written
RECORDED
page_holds 'a redirect carrying another state'
[ ! -s "$GHAPP/state-a/log" ] || fail 'a wrong state was refused and the code was still sent to GitHub'
nothing_written 'a redirect carrying another state'
rm -f "$GHAPP/state-a/wrong-state"
ok 'the manifest page carries the nine permissions, no webhook, private, the listener, and submits itself; the listener answers the redirect with one line; a redirect with another state is refused before the code reaches GitHub'

# ── an App answered with eight permissions is refused, and named ───────────
seed_github "$GHAPP/state-a" "$EIGHT_PERMISSIONS" all
run_app_bash config.apps6.env
must "create-github-app: GitHub sent the browser back with a code, and the state is this run's" 'the code and the state are taken off the redirect'
must 'create-github-app: the App was created at https://github.com/apps/acme-platform-manager with the permissions actions:write administration:write contents:write issues:read metadata:read packages:read webhooks:write workflows:write and not the nine asked: actions:write administration:write contents:write issues:read metadata:read packages:read statuses:write webhooks:write workflows:write. Delete it there and run this again. Nothing has been written' \
  'an App answered with eight permissions is refused, both lists named'
[ "$A_CODE" = '65' ] || fail "eight permissions must refuse with 65, got $A_CODE"
expect 'an App answered with eight permissions' 65 <<'RECORDED'
create-github-app: the App acme-platform-manager is created in the organisation acme, the owner of DEPLOY_REPO in config.apps6.env, with its homepage https://manager.example.invalid
create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes
create-github-app: opened the manifest page in the browser; it posts to https://github.com/organizations/acme/settings/apps/new. In the browser: click Create GitHub App
create-github-app: GitHub sent the browser back with a code, and the state is this run's
~~~ standard error ~~~
create-github-app: the App was created at https://github.com/apps/acme-platform-manager with the permissions actions:write administration:write contents:write issues:read metadata:read packages:read webhooks:write workflows:write and not the nine asked: actions:write administration:write contents:write issues:read metadata:read packages:read statuses:write webhooks:write workflows:write. Delete it there and run this again. Nothing has been written
RECORDED
[ "$(cat "$GHAPP/state-a/log")" = 'POST /app-manifests/c0de0fthefixture/conversions' ] || fail "the conversion was not the one call, or not with the fixture's code: $(tr '\n' ' ' < "$GHAPP/state-a/log")"
nothing_written 'an App answered with eight permissions'
ok 'the conversion is asked with the code off the redirect, and an App answered with eight permissions is refused by both lists with nothing written'

# ── the act itself, both clicks in one run ──────────────────────────────────
seed_github "$GHAPP/state-a" "$NINE_PERMISSIONS" all
run_app_bash config.apps6.env
must 'create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711) with the nine permissions actions:write administration:write contents:write issues:read metadata:read packages:read statuses:write webhooks:write workflows:write' 'the App is named with its id and its permissions'
must 'create-github-app: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY written into config.apps6.env in place' 'the id and the key are written before the installation is asked for'
must 'create-github-app: opened https://github.com/apps/acme-platform-manager/installations/new in the browser. In the browser: choose All repositories and click Install' 'the person is told the second click'
must 'create-github-app: asking GitHub every 5 seconds whether the App is installed in acme, for up to 10 minutes' 'the poll is announced'
must 'create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815' 'the installation is named with its page'
must 'create-github-app: GITHUB_APP_INSTALLATION_ID written into config.apps6.env in place' 'the installation id is written'
must 'create-github-app: config.apps6.env carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY, and nobody but the owner can read it. The App: https://github.com/apps/acme-platform-manager. Its installation: https://github.com/organizations/acme/settings/installations/815' 'the three keys are named, never a value'
must_not 'BEGIN' 'no line of the key is printed'
[ "$A_CODE" = '0' ] || fail "the act must end with 0, got $A_CODE"
expect 'the act, both clicks in one run' 0 <<'RECORDED'
create-github-app: the App acme-platform-manager is created in the organisation acme, the owner of DEPLOY_REPO in config.apps6.env, with its homepage https://manager.example.invalid
create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes
create-github-app: opened the manifest page in the browser; it posts to https://github.com/organizations/acme/settings/apps/new. In the browser: click Create GitHub App
create-github-app: GitHub sent the browser back with a code, and the state is this run's
create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711) with the nine permissions actions:write administration:write contents:write issues:read metadata:read packages:read statuses:write webhooks:write workflows:write
create-github-app: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY written into config.apps6.env in place
create-github-app: opened https://github.com/apps/acme-platform-manager/installations/new in the browser. In the browser: choose All repositories and click Install
create-github-app: asking GitHub every 5 seconds whether the App is installed in acme, for up to 10 minutes
create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815
create-github-app: GITHUB_APP_INSTALLATION_ID written into config.apps6.env in place
create-github-app: config.apps6.env carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY, and nobody but the owner can read it. The App: https://github.com/apps/acme-platform-manager. Its installation: https://github.com/organizations/acme/settings/installations/815
~~~ standard error ~~~
RECORDED
page_holds 'the act'
state="$GHAPP/state-a"
[ "$(cat "$state/log")" = "POST /app-manifests/c0de0fthefixture/conversions
GET /orgs/acme/installation jwt=verified iss=4711" ] || fail "the calls are not the conversion and one installation question with a verified JWT: $(tr '\n' ' ' < "$state/log")"
[ "$(cat "$state/opened")" = "http://127.0.0.1:$(sed -n 's/.*redirect_url":"http:\/\/127.0.0.1:\([0-9]*\)\/.*/\1/p' "$state/page.html")/
https://github.com/apps/acme-platform-manager/installations/new" ] || fail "the browser was not opened on the listener and then on the installation page: $(tr '\n' ' ' < "$state/opened")"
[ "$(config_line GITHUB_APP_ID)" = '4711' ] || fail "the config does not carry the App id"
[ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '815' ] || fail "the config does not carry the installation id"
[ "$(config_line GITHUB_APP_PRIVATE_KEY)" = "$(cat "$GHAPP/pem.json")" ] || fail "the config does not carry the key as one line with \\n for each line break"
config_line GITHUB_APP_PRIVATE_KEY | perl -pe 's/\\n/\n/g' | openssl rsa -check -noout >/dev/null 2>&1 || fail "the key in the config, its line breaks turned back, is not a key openssl reads"
[ "$(grep -c . "$GHAPP/a/config.apps6.env")" = '6' ] || fail "the config gained or lost a line"
grep -q "^FQDN='apps6.example.invalid'\$" "$GHAPP/a/config.apps6.env" || fail "the rewrite disturbed a line of the config"
[ "$(sed -n '2p' "$GHAPP/a/config.apps6.env" | cut -c1-24)" = "GITHUB_APP_PRIVATE_KEY='" ] || fail "the key was not written on the line the template declares it on"
require_owner_only "$GHAPP/a/config.apps6.env" || fail "the rewrite took the access list off the config: it $REACH"
ok 'the act: the page, the redirect, the conversion, the two writes in place on the lines the template declares, the JWT verified with the key`s public half, the installation read, and the config still owner-only with the real tools'

# ── a second run on what the first wrote refuses ────────────────────────────
run_app_bash config.apps6.env
must 'create-github-app: config.apps6.env already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY. Nothing has been changed' 'a second run on a config the first filled is refused'
[ "$A_CODE" = '65' ] || fail "a second run must refuse with 65, got $A_CODE"
expect 'a second run on what the first wrote' 65 <<'RECORDED'
~~~ standard error ~~~
create-github-app: config.apps6.env already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY. Nothing has been changed
RECORDED

# ── an installation on selected repositories refuses, and the next run fills what is missing ─
seed_github "$GHAPP/state-a" "$NINE_PERMISSIONS" selected
seed_config "$GHAPP/a"
run_app_bash config.apps6.env
must 'create-github-app: the App is installed in acme with repository_selection selected, and the Manager needs all. Choose All repositories at https://github.com/organizations/acme/settings/installations/815, then run this again: The App stands, and config.apps6.env carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY, and the next run writes GITHUB_APP_INSTALLATION_ID' \
  'an installation on selected repositories is refused, naming what stands and what the next run does'
[ "$A_CODE" = '65' ] || fail "selected repositories must refuse with 65, got $A_CODE"
expect 'an installation on selected repositories' 65 <<'RECORDED'
create-github-app: the App acme-platform-manager is created in the organisation acme, the owner of DEPLOY_REPO in config.apps6.env, with its homepage https://manager.example.invalid
create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes
create-github-app: opened the manifest page in the browser; it posts to https://github.com/organizations/acme/settings/apps/new. In the browser: click Create GitHub App
create-github-app: GitHub sent the browser back with a code, and the state is this run's
create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711) with the nine permissions actions:write administration:write contents:write issues:read metadata:read packages:read statuses:write webhooks:write workflows:write
create-github-app: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY written into config.apps6.env in place
create-github-app: opened https://github.com/apps/acme-platform-manager/installations/new in the browser. In the browser: choose All repositories and click Install
create-github-app: asking GitHub every 5 seconds whether the App is installed in acme, for up to 10 minutes
~~~ standard error ~~~
create-github-app: the App is installed in acme with repository_selection selected, and the Manager needs all. Choose All repositories at https://github.com/organizations/acme/settings/installations/815, then run this again: The App stands, and config.apps6.env carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY, and the next run writes GITHUB_APP_INSTALLATION_ID
RECORDED
[ "$(config_line GITHUB_APP_ID)" = '4711' ] || fail "the config does not carry the App id after the refusal"
[ "$(config_line GITHUB_APP_PRIVATE_KEY)" = "$(cat "$GHAPP/pem.json")" ] || fail "the config does not carry the key after the refusal"
[ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '' ] || fail "the config carries an installation id the refusal should not have written"
# THE NEXT RUN finds the App in the config, asks GitHub for it with the key,
# and installs — polling once through a 404 before the installation appears.
seed_github "$GHAPP/state-a" "$NINE_PERMISSIONS" absent-then-all
run_app_bash config.apps6.env
must 'create-github-app: config.apps6.env carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY and no GITHUB_APP_INSTALLATION_ID, so the App stands and this run installs it' 'a config carrying the App and no installation skips the creation'
must 'create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711)' 'the App is asked of GitHub with the key and named'
must 'create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815' 'the installation is found'
must 'create-github-app: GITHUB_APP_INSTALLATION_ID written into config.apps6.env in place' 'and its id written'
must_not 'the manifest page' 'no page is served on a run that only installs'
[ "$A_CODE" = '0' ] || fail "the installing run must end with 0, got $A_CODE"
expect 'the run that only installs' 0 <<'RECORDED'
create-github-app: config.apps6.env carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY and no GITHUB_APP_INSTALLATION_ID, so the App stands and this run installs it
create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711)
create-github-app: opened https://github.com/apps/acme-platform-manager/installations/new in the browser. In the browser: choose All repositories and click Install
create-github-app: asking GitHub every 5 seconds whether the App is installed in acme, for up to 10 minutes
create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815
create-github-app: GITHUB_APP_INSTALLATION_ID written into config.apps6.env in place
create-github-app: config.apps6.env carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY, and nobody but the owner can read it. The App: https://github.com/apps/acme-platform-manager. Its installation: https://github.com/organizations/acme/settings/installations/815
~~~ standard error ~~~
RECORDED
state="$GHAPP/state-a"
[ "$(cat "$state/log")" = 'GET /app jwt=verified iss=4711
GET /orgs/acme/installation jwt=verified iss=4711
GET /orgs/acme/installation jwt=verified iss=4711' ] || fail "the calls are not the App question and two installation questions, every JWT verified: $(tr '\n' ' ' < "$state/log")"
[ "$(cat "$state/opened")" = 'https://github.com/apps/acme-platform-manager/installations/new' ] || fail "the browser was not opened on the installation page alone: $(tr '\n' ' ' < "$state/opened")"
[ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '815' ] || fail "the config does not carry the installation id"
require_owner_only "$GHAPP/a/config.apps6.env" || fail "the rewrite took the access list off the config: it $REACH"
ok 'an installation on selected repositories is refused with the id and the key already written; the next run signs with the key out of the config, polls through a 404, and writes the installation id'

# ── the planted defect for this act, in the state the run that only installs ran in ─
PLANTED_G="$WORK/planted-create-github-app.sh"
cp "$HERE/require-owner-only.sh" "$WORK/"
sed 's/so the App stands and this run installs it/so the App stands and this run will install it/' "$HERE/create-github-app.sh" > "$PLANTED_G"
grep -q 'this run will install it' "$PLANTED_G" || fail 'the planted line was not planted — the probe proves nothing'
seed_github "$GHAPP/state-a" "$NINE_PERMISSIONS" absent-then-all
sed -i.bak "s/^GITHUB_APP_INSTALLATION_ID=.*/GITHUB_APP_INSTALLATION_ID=''/" "$GHAPP/a/config.apps6.env" && rm -f "$GHAPP/a/config.apps6.env.bak"
chmod 600 "$GHAPP/a/config.apps6.env"
A_CODE=0
( cd "$GHAPP/a" && export GITHUB_STUB="$GHAPP/state-a" GITHUB_PUB="$GHAPP/pub.pem" GITHUB_PEM_JSON="$GHAPP/pem.json" REAL_CURL="$REAL_CURL" BROWSER=browser PATH="$GSTUB:$PATH" \
  && bash "$PLANTED_G" config.apps6.env ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'this run will install it' "$OUT/a.out" || fail 'the planted copy printed no installing line — the probe was aimed at a line the fixture does not reach'
caught create-github-app.sh 'this run will install it'

# ===========================================================================
# SEVEN — master-backup and master-restore, up to the session they would open
# ===========================================================================
# THE ACTS THEMSELVES RUN ON A MACHINE, and no fixture here is one: what is
# measured is everything a launcher decides BEFORE it opens its session — the
# usage, the config it refuses and why, the door it composes —, plus the one
# probe that proves the door: a config naming a MACHINE_HOST that resolves to
# nothing makes the launcher print ssh's own sentence about THAT name, not the
# FQDN. The two drivers are held to one list
# of stores, because a store taken by one and unknown to the other would be
# backed up and never placed.
MASTER="$WORK/master"
mkdir -p "$MASTER"
MCFG="$MASTER/config.master.env"
{
  echo "FQDN='master.example.invalid'"
  echo "MACHINE_HOST='door.example.invalid'"
  echo "OPERATOR_USER='op'"
  echo "STAGE='prod'"
  echo "ELEVATION_PASSWORD='x'"
  echo "PLATFORM_REPO='acme/cloud'"
  echo "PLATFORM_BRANCH='master'"
  echo "PLATFORM_REPO_READ_PAT='t'"
  echo "STORAGE_BOX_HOST='box.example.invalid'"
  echo "STORAGE_BOX_USER='u'"
  echo "STORAGE_BOX_PASSWORD='p'"
  echo "BACKUP_PASSPHRASE='s'"
} > "$MCFG"
chmod 600 "$MCFG"
MNOPASS="$MASTER/config.nopass.env"
grep -v '^BACKUP_PASSPHRASE=' "$MCFG" > "$MNOPASS"
chmod 600 "$MNOPASS"
MNOBOX="$MASTER/config.nobox.env"
grep -v '^STORAGE_BOX_USER=' "$MCFG" > "$MNOBOX"
chmod 600 "$MNOBOX"
MNOCONFIG="$MASTER/there-is-no-config.env"
# A config others can read, by its mode.
MREACH="$MASTER/config.reach.env"
cp "$MCFG" "$MREACH"
chmod 644 "$MREACH"

run_master_bash() { # script base name, then its arguments
  local base="$1"; shift
  A_CODE=0
  ( cd "$MASTER" && bash "$HERE/$base.sh" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}

for act in master-backup master-restore; do
  run_master_bash "$act"
  must "usage: lifecycle/$act.sh <config>" "$act: a run naming no config is refused"
  [ "$A_CODE" = '64' ] || fail "$act: a run naming no config must end with 64, got $A_CODE"
  case "$act" in
    master-backup) expect "$act: a run naming no config" 64 <<'RECORDED' ;;
~~~ standard error ~~~
backup: usage: lifecycle/master-backup.sh <config>. Nothing has been changed
RECORDED
    master-restore) expect "$act: a run naming no config" 64 <<'RECORDED' ;;
~~~ standard error ~~~
restore: usage: lifecycle/master-restore.sh <config> [backup-id]. Nothing has been changed
RECORDED
  esac

  run_master_bash "$act" "$MNOCONFIG"
  must "there is no config at $MNOCONFIG" "$act: a config that is not there is refused"
  must "Nothing has been changed" "$act: a refusal says that nothing has been changed"
  [ "$A_CODE" = '66' ] || fail "$act: a missing config must end with 66, got $A_CODE"
  case "$act" in
    master-backup) expect "$act: a config that is not there" 66 <<'RECORDED' ;;
~~~ standard error ~~~
backup: there is no config at <WORK>/master/there-is-no-config.env. It states the installation this backs up: copy config.example.env beside it, fill it in, and name it as the argument. Nothing has been changed
RECORDED
    master-restore) expect "$act: a config that is not there" 66 <<'RECORDED' ;;
~~~ standard error ~~~
restore: there is no config at <WORK>/master/there-is-no-config.env. It states the installation this restores: copy config.example.env beside it, fill it in, and name it as the first argument. Nothing has been changed
RECORDED
  esac

  run_master_bash "$act" "$MNOPASS"
  must "states no BACKUP_PASSPHRASE" "$act: a config without the passphrase is refused"
  [ "$A_CODE" = '65' ] || fail "$act: a config without the passphrase must end with 65, got $A_CODE"
  case "$act" in
    master-backup) expect "$act: a config without the passphrase" 65 <<'RECORDED' ;;
~~~ standard error ~~~
backup: <WORK>/master/config.nopass.env states no BACKUP_PASSPHRASE, and a backup of a master's every credential leaves the machine sealed or not at all. Nothing has been changed
RECORDED
    master-restore) expect "$act: a config without the passphrase" 65 <<'RECORDED' ;;
~~~ standard error ~~~
restore: <WORK>/master/config.nopass.env states no BACKUP_PASSPHRASE, and a backup is opened with it or not at all. Nothing has been changed
RECORDED
  esac

  run_master_bash "$act" "$MREACH"
  must "$MREACH is mode 644 and carries credentials, the elevation password of the machine among them. Run: chmod 600 $MREACH. Nothing has been changed" \
    "$act: a config others can read is refused with its mode and the command that closes it"
  [ "$A_CODE" = '77' ] || fail "$act: a config others can read must end with 77, got $A_CODE"
  case "$act" in
    master-backup) expect "$act: a config of mode 644" 77 <<'RECORDED' ;;
~~~ standard error ~~~
backup: <WORK>/master/config.reach.env is mode 644 and carries credentials, the elevation password of the machine among them. Run: chmod 600 <WORK>/master/config.reach.env. Nothing has been changed
RECORDED
    master-restore) expect "$act: a config of mode 644" 77 <<'RECORDED' ;;
~~~ standard error ~~~
restore: <WORK>/master/config.reach.env is mode 644 and carries credentials, the elevation password of the machine among them. Run: chmod 600 <WORK>/master/config.reach.env. Nothing has been changed
RECORDED
  esac

  # The planted defect for the guard: a copy of the launcher and its driver beside a
  # guard with one word changed. The refusal must carry the changed word, which proves
  # the launcher reads the guard beside itself, and differ from the recorded bytes.
  mkdir -p "$MASTER/planted-guard"
  cp "$HERE/$act.sh" "$HERE/$act-driver.sh" "$MASTER/planted-guard/"
  sed 's/is mode /has mode /' "$HERE/require-owner-only.sh" > "$MASTER/planted-guard/require-owner-only.sh"
  grep -q 'has mode ' "$MASTER/planted-guard/require-owner-only.sh" \
    || fail 'the planted line was not planted in require-owner-only.sh — the probe proves nothing'
  A_CODE=0
  ( cd "$MASTER" && bash "$MASTER/planted-guard/$act.sh" "$MREACH" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
  grep -q "$MREACH has mode 644" "$OUT/a.err" \
    || fail "$act beside the planted guard printed no planted mode line — it does not read the guard beside itself"
  caught "the guard beside $act.sh" 'has mode 644'

  run_master_bash "$act" "$MNOBOX"
  must "states no STORAGE_BOX_USER" "$act: a config without the storage box is refused"
  [ "$A_CODE" = '65' ] || fail "$act: a config without the storage box must end with 65, got $A_CODE"
  case "$act" in
    master-backup) expect "$act: a config without the storage box" 65 <<'RECORDED' ;;
~~~ standard error ~~~
backup: <WORK>/master/config.nobox.env states no STORAGE_BOX_USER, and the storage box is where a backup goes. Nothing has been changed
RECORDED
    master-restore) expect "$act: a config without the storage box" 65 <<'RECORDED' ;;
~~~ standard error ~~~
restore: <WORK>/master/config.nobox.env states no STORAGE_BOX_USER, and the storage box is where a backup comes from. Nothing has been changed
RECORDED
  esac

  # THE DOOR IS MACHINE_HOST. The name resolves to nothing, so ssh refuses at once and names it:
  # the launcher composed the session to the door and not to the identity.
  run_master_bash "$act" "$MCFG"
  must "op@door.example.invalid could not be reached" "$act: the session is opened to MACHINE_HOST, never to the FQDN"
  must_not "op@master.example.invalid" "$act: the identity is not the door"
  [ "$A_CODE" = '69' ] || fail "$act: a door that resolves to nothing must end with 69, got $A_CODE"
  case "$act" in
    master-backup) expect "$act: the door composed from MACHINE_HOST, refused by name" 69 <<'RECORDED' ;;
~~~ standard error ~~~
backup: op@door.example.invalid could not be reached: ssh: Could not resolve hostname door.example.invalid: <RESOLVER>. Nothing has been changed
RECORDED
    master-restore) expect "$act: the door composed from MACHINE_HOST, refused by name" 69 <<'RECORDED' ;;
~~~ standard error ~~~
restore: op@door.example.invalid could not be reached: ssh: Could not resolve hostname door.example.invalid: <RESOLVER>. Nothing has been changed
RECORDED
  esac

  # The planted defect for this act: a copy with its reach sentence changed, beside its driver.
  PLANTED_M="$MASTER/planted-$act.sh"
  sed 's/could not be reached: /could not be reached — /' "$HERE/$act.sh" > "$PLANTED_M"
  cp "$HERE/$act-driver.sh" "$HERE/require-owner-only.sh" "$MASTER/"
  grep -q 'could not be reached — ' "$PLANTED_M" || fail "the planted line was not planted in $act — the probe proves nothing"
  A_CODE=0
  ( cd "$MASTER" && bash "$PLANTED_M" "$MCFG" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
  grep -q 'could not be reached — ' "$OUT/a.err" || fail "the planted $act copy printed no reach line — the probe was aimed at a line the fixture does not reach"
  caught "$act.sh" 'could not be reached — '

  mkdir -p "$MASTER/driverless"
  cp "$HERE/$act.sh" "$MASTER/driverless/"
  A_CODE=0
  ( cd "$MASTER" && bash "$MASTER/driverless/$act.sh" "$MCFG" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
  must "$act-driver.sh is not beside this file" "$act: a launcher without its driver is refused"
  [ "$A_CODE" = '66' ] || fail "$act: a missing driver must end with 66, got $A_CODE"
  case "$act" in
    master-backup) expect "$act: a launcher standing without its driver" 66 <<'RECORDED' ;;
~~~ standard error ~~~
backup: master-backup-driver.sh is not beside this file. It IS the backup on the machine, and this only starts it. Nothing has been changed
RECORDED
    master-restore) expect "$act: a launcher standing without its driver" 66 <<'RECORDED' ;;
~~~ standard error ~~~
restore: master-restore-driver.sh is not beside this file. It IS the staging on the machine, and this only starts it. Nothing has been changed
RECORDED
  esac
done

run_master_bash master-restore "$MCFG" nope
must 'a backup is named by the moment it was taken' 'restore: an id that is no moment is refused'
[ "$A_CODE" = '64' ] || fail "restore: an id that is no moment must end with 64, got $A_CODE"
expect 'restore: an id that is no moment' 64 <<'RECORDED'
~~~ standard error ~~~
restore: a backup is named by the moment it was taken, like 20260922T031500Z, and "nope" is not one. Run this without an id to see the ones the storage box holds. Nothing has been changed
RECORDED

run_master_bash master-backup "$MCFG" extra
must 'was given more than it takes: extra' 'backup: a third argument is refused'
[ "$A_CODE" = '64' ] || fail "backup: a third argument must end with 64, got $A_CODE"
expect 'backup: a third argument' 64 <<'RECORDED'
~~~ standard error ~~~
backup: lifecycle/master-backup.sh was given more than it takes: extra. Nothing has been changed
RECORDED

# ── one list of stores in both drivers ───────────────────────────────────────
# master-backup-driver.sh names namespace|claim|workload|kind, master-restore-driver.sh
# namespace|claim|size: the namespace and the claim, in order, have to be the same rows.
stores_of() { sed -n '/^STORES=($/,/^)$/p' "$1" | grep -E '^  "' | sed 's/^  "//; s/"$//' | cut -d'|' -f1,2; }
stores_of "$HERE/master-backup-driver.sh" > "$OUT/stores-backup"
stores_of "$HERE/master-restore-driver.sh" > "$OUT/stores-restore"
[ -s "$OUT/stores-backup" ] || fail 'the backup driver names no store — the list it takes from could not be read'
diff -u "$OUT/stores-backup" "$OUT/stores-restore" \
  || fail 'the two drivers name different stores — a store taken by one and unknown to the other is backed up and never placed'
ok "the two drivers name the same $(wc -l < "$OUT/stores-backup" | tr -d ' ') stores, in the same order"

# ── one folder in both drivers ───────────────────────────────────────────────
# A backup written where the restore does not look never comes back, so both drivers name the
# installation's machine-backup folder in one identical line, and neither names the old one.
folder_of() { grep -E '^BACKUPS=' "$1"; }
[ "$(folder_of "$HERE/master-backup-driver.sh")" = 'BACKUPS="box:$FQDN/master"' ] \
  || fail 'the backup driver does not write under box:$FQDN/master, the folder of the installation'
[ "$(folder_of "$HERE/master-backup-driver.sh")" = "$(folder_of "$HERE/master-restore-driver.sh")" ] \
  || fail 'the two drivers name different folders — a backup written where the restore does not look never comes back'
! grep -n 'box:master/' "$HERE/master-backup-driver.sh" "$HERE/master-restore-driver.sh" \
  || fail 'a driver still names the old folder box:master/'
ok 'the two drivers write and read one folder, box:$FQDN/master'

# ===========================================================================
# EIGHT — the engine held against its digests, as both drivers place it on a machine
# ===========================================================================
# driver.sh arms a machine and regenerate-driver.sh regenerates one, and each places the engine
# where it is off the pin. Neither is run here whole. What runs is each driver's own text, taken out
# of the file: its check, its clean-up and traps, and the whole block that decides, fetches, holds
# and installs. Only /usr/local/bin is moved into a sandbox, and curl and root are stand-ins, so
# what a machine does is what is measured. The cases: a clean machine; a swapped asset; a digest file
# of another release, of one executable, naming one twice, or with a digest in capitals; a machine
# left half placed; and a TERM after the first install. Each guard has a planted defect of its own,
# driven through the same probe that measures the real driver. The two drivers carry one check, and
# the digest file this tree commits names the assets of the pin it commits.
ENGINE_WORK="$WORK/engine"
SERVED="$ENGINE_WORK/served"
mkdir -p "$SERVED"
ENGINE_PIN='0.8.307-stable-20260930202014'
asset_text() { printf '#!/bin/sh\necho %s\n# %s\n' "$2" "$1"; } # <tool> <the version it answers>
for tool in ansiwise ansiwise-rest; do asset_text "$tool" "$ENGINE_PIN" > "$SERVED/$tool-$ENGINE_PIN-linux-x64"; done
PINNED_DIGESTS="$(cd "$SERVED" && sha256sum "ansiwise-$ENGINE_PIN-linux-x64" "ansiwise-rest-$ENGINE_PIN-linux-x64")"
check_of() { sed -n '/^hold_engine_against_digests() {/,/^}/p' "$1"; }
# The names a driver blanks, its cleanup() and its traps, in the order the driver states them.
guard_of() { sed -n "/^# EMPTY UNTIL THIS SCRIPT SETS THEM/,/^trap .*TERM\$/p" "$1"; }
held() { # <driver file> <digest file text> — runs the check as that driver carries it, and answers its exit code
  ( eval "$(check_of "$1")"
    hold_engine_against_digests "$SERVED" "$2" "$ENGINE_PIN" ) > "$OUT/held.out" 2>&1
}
# The driver's placement as a machine runs it: its clean-up and traps, its check, and the block from
# asking the engine to the read-back, with /usr/local/bin moved into the sandbox. [served digests]
# is what the digest file answers, and $SERVED holds what the release answers.
SANDBOX="$ENGINE_WORK/machine"
placed() { # <driver file> <served digests> [<the asset served in place of ansiwise-rest>] — answers the block's exit code
  local driver="$1"
  ( SERVED_DIGESTS="$2" SWAPPED="${3:-}"
    ENGINE="$SANDBOX/bin/ansiwise" PIN="$ENGINE_PIN" CONFIG="$ENGINE_WORK/no-config"
    RELEASES='https://releases.example.invalid' DIGESTS_URL='https://pins.example.invalid/ansiwise.sha256'
    say() { echo "say: $*"; }; good() { echo "good: $*"; }; summary() { echo 'summary'; }
    die() { echo "die: $1" >&2; exit "${2:-1}"; }
    root() { "$@" && { [ -z "${TERM_AFTER_FIRST_INSTALL:-}" ] || { TERM_AFTER_FIRST_INSTALL=''; kill -TERM "$BASHPID"; }; }; }
    curl() { # -fsSL [-o <file>] <url>
      local out='' url=''
      while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
      case "$url" in
        "$DIGESTS_URL") printf '%s\n' "$SERVED_DIGESTS" ;;
        "$RELEASES"/*/ansiwise-rest-*) if [ -n "$SWAPPED" ]; then cp "$SWAPPED" "$out"; else cp "$SERVED/${url##*/}" "$out"; fi ;;
        "$RELEASES"/*) cp "$SERVED/${url##*/}" "$out" ;;
        *) return 22 ;;
      esac
    }
    eval "$(guard_of "$driver")"
    eval "$(check_of "$driver")"
    eval "$(sed -n '/^ENGINE_ANSWERS=\$("\$ENGINE" --version/,/^fi$/p' "$driver" | sed "s#/usr/local/bin/#$SANDBOX/bin/#g")"
  ) > "$OUT/placed.out" 2>&1
}
fresh_machine() { rm -rf "$SANDBOX"; mkdir -p "$SANDBOX/bin"; }
carries() { cat "$SANDBOX/bin/$1" 2>/dev/null; } # <tool> — what the machine holds under that name
released() { cat "$SERVED/$1-$ENGINE_PIN-linux-x64"; } # <tool> — what the release built
SWAPPED_ASSET="$ENGINE_WORK/swapped"
asset_text ansiwise-rest "$ENGINE_PIN" > "$SWAPPED_ASSET"; echo '# swapped after the release' >> "$SWAPPED_ASSET"

for engine_driver in driver.sh regenerate-driver.sh; do
  D="$HERE/$engine_driver"
  check_of "$D" | grep -q 'sha256sum --check' \
    || fail "$engine_driver carries no hold_engine_against_digests that runs sha256sum --check — nothing below measures the machine"

  held "$D" "$PINNED_DIGESTS" || fail "$engine_driver: the pinned digests of both assets were refused: $(cat "$OUT/held.out")"
  if held "$D" "$(printf '%s\n' "$PINNED_DIGESTS" | sed "s/$ENGINE_PIN/0.8.306-stable-20260929191649/")"; then
    fail "$engine_driver: a digest file naming another release passed — the pin and its digests came apart unnoticed"
  fi
  grep -q "the digests name no ansiwise-$ENGINE_PIN-linux-x64" "$OUT/held.out" \
    || fail "$engine_driver: a digest file naming another release was not refused as such: $(cat "$OUT/held.out")"
  if held "$D" "$(printf '%s\n' "$PINNED_DIGESTS" | head -1)"; then
    fail "$engine_driver: a digest file naming one executable passed — the other would be placed unchecked"
  fi
  grep -q "the digests name no ansiwise-rest-$ENGINE_PIN-linux-x64" "$OUT/held.out" \
    || fail "$engine_driver: a digest file naming one executable was not refused for the other: $(cat "$OUT/held.out")"
  if held "$D" "$(printf '%s\n%s\n' "$PINNED_DIGESTS" "$(printf '%s\n' "$PINNED_DIGESTS" | tail -1 | sed 's/^./0/')")"; then
    fail "$engine_driver: a digest file naming an executable twice passed — the Manager refuses it, and the two would accept different bytes"
  fi
  grep -q "the digests name ansiwise-rest-$ENGINE_PIN-linux-x64 more than once" "$OUT/held.out" \
    || fail "$engine_driver: a digest file naming an executable twice was not refused as such: $(cat "$OUT/held.out")"
  if held "$D" "$(printf '%s\n' "$PINNED_DIGESTS" | sed '2s/^\([0-9a-f]*\)/\U\1/')"; then
    fail "$engine_driver: a digest in capitals passed — sha256sum would accept it, and the Manager refuses it"
  fi
  grep -q "the digests name ansiwise-rest-$ENGINE_PIN-linux-x64 with no SHA-256 of 64 lowercase hex digits" "$OUT/held.out" \
    || fail "$engine_driver: a digest in capitals was not refused as such: $(cat "$OUT/held.out")"
  ok "$engine_driver: the check passes the pinned digests and refuses another release, one executable, a name given twice and capitals"

  fresh_machine
  placed "$D" "$PINNED_DIGESTS" || fail "$engine_driver: a clean machine was refused the engine at its pinned digests: $(cat "$OUT/placed.out")"
  [ "$(carries ansiwise)" = "$(released ansiwise)" ] && [ "$(carries ansiwise-rest)" = "$(released ansiwise-rest)" ] \
    || fail "$engine_driver: a clean machine does not carry the release's bytes after the placement"
  ok "$engine_driver: a clean machine is given both executables at their pinned digests"

  fresh_machine
  CODE=0; placed "$D" "$PINNED_DIGESTS" "$SWAPPED_ASSET" || CODE=$?
  [ "$CODE" = 65 ] || fail "$engine_driver: a swapped asset must end the placement with 65, got $CODE: $(cat "$OUT/placed.out")"
  [ -z "$(ls -A "$SANDBOX/bin")" ] || fail "$engine_driver: a swapped asset was refused, and something was placed all the same: $(ls "$SANDBOX/bin")"
  ok "$engine_driver: a swapped asset is refused and nothing is placed"

  fresh_machine
  released ansiwise > "$SANDBOX/bin/ansiwise"; asset_text ansiwise-rest '0.8.306-stable-20260929191649' > "$SANDBOX/bin/ansiwise-rest"
  chmod +x "$SANDBOX/bin/ansiwise" "$SANDBOX/bin/ansiwise-rest"
  placed "$D" "$PINNED_DIGESTS" || fail "$engine_driver: a half-placed machine was refused: $(cat "$OUT/placed.out")"
  [ "$(carries ansiwise-rest)" = "$(released ansiwise-rest)" ] \
    || fail "$engine_driver: a machine with ansiwise at the pin and ansiwise-rest off it was passed over"
  ok "$engine_driver: a machine left half placed is placed again, not passed over"

  fresh_machine
  CODE=0; TERM_AFTER_FIRST_INSTALL=1 placed "$D" "$PINNED_DIGESTS" || CODE=$?
  [ "$CODE" = 143 ] || fail "$engine_driver: a TERM after the first install must end the run with 143, got $CODE: $(cat "$OUT/placed.out")"
  [ ! -e "$SANDBOX/bin/ansiwise-rest" ] || fail "$engine_driver: the run went on after a TERM and placed ansiwise-rest"
  ok "$engine_driver: a TERM ends the run where it stands, and the next run places what is missing"
done

# The planted defects, each through the probe that measures the real driver.
plant() { sed "$2" "$HERE/driver.sh" > "$ENGINE_WORK/planted-driver.sh"; grep -q "$3" "$ENGINE_WORK/planted-driver.sh" \
  || fail "the planted line was not planted ($1) — the probe proves nothing"; }
plant 'a refusal that does not stop the install' 's/^    die "the engine fetched for \$PIN does not hold.*" 65$/    :/' '^    :$'
fresh_machine
CODE=0; placed "$ENGINE_WORK/planted-driver.sh" "$PINNED_DIGESTS" "$SWAPPED_ASSET" || CODE=$?
[ -n "$(ls -A "$SANDBOX/bin")" ] || fail 'a driver whose refusal does not stop the install placed nothing over a swapped asset — the probe proves nothing'
ok 'the planted defect was caught — a driver whose refusal does not stop the install places the swapped asset'
plant 'a handler that resumes after a TERM' "s/^trap 'summary; exit 143' TERM$/trap cleanup TERM/" '^trap cleanup TERM$'
fresh_machine
CODE=0; TERM_AFTER_FIRST_INSTALL=1 placed "$ENGINE_WORK/planted-driver.sh" "$PINNED_DIGESTS" || CODE=$?
[ "$CODE" != 143 ] || fail 'a driver that resumes after a TERM ended with 143 all the same — the probe proves nothing'
ok "the planted defect was caught — a driver that resumes after a TERM ends with $CODE, not 143"
plant 'a skip that asks ansiwise alone' 's/^if \[ "\$ENGINE_ANSWERS" = "\$PIN" \] && \[ "\$SERVING_ANSWERS" = "\$PIN" \]; then$/if [ "$ENGINE_ANSWERS" = "$PIN" ]; then/' '^if \[ "\$ENGINE_ANSWERS" = "\$PIN" \]; then$'
fresh_machine
released ansiwise > "$SANDBOX/bin/ansiwise"; asset_text ansiwise-rest '0.8.306-stable-20260929191649' > "$SANDBOX/bin/ansiwise-rest"
chmod +x "$SANDBOX/bin/ansiwise" "$SANDBOX/bin/ansiwise-rest"
placed "$ENGINE_WORK/planted-driver.sh" "$PINNED_DIGESTS" || true
[ "$(carries ansiwise-rest)" != "$(released ansiwise-rest)" ] || fail 'a driver that asks ansiwise alone placed ansiwise-rest all the same — the probe proves nothing'
ok 'the planted defect was caught — a driver that asks ansiwise alone leaves a half-placed machine as it is'

# A name the environment carries survives a run that ends before it sets one, because the driver
# blanks it before it arms the trap that removes it.
survives_an_early_end() { # <driver file> — answers 0 when both directories named in the environment survive
  local kept="$ENGINE_WORK/kept"
  rm -rf "$kept"; mkdir -p "$kept/answers" "$kept/fetched"
  ( export ANSWERS_DIR="$kept/answers" FETCHED="$kept/fetched" CONFIG="$ENGINE_WORK/no-config"
    summary() { :; }
    eval "$(guard_of "$1")"
    exit 3 ) > /dev/null 2>&1
  [ -d "$kept/answers" ] && [ -d "$kept/fetched" ]
}
for engine_driver in driver.sh regenerate-driver.sh; do
  survives_an_early_end "$HERE/$engine_driver" \
    || fail "$engine_driver removed a directory the environment named before the run set it"
done
plant 'a FETCHED left as the environment set it' "s/^FETCHED=''$/: FETCHED left as the environment set it/" '^: FETCHED left as the environment set it$'
if survives_an_early_end "$ENGINE_WORK/planted-driver.sh"; then
  fail 'a driver that does not blank FETCHED kept the directory the environment named — the probe proves nothing'
fi
ok 'both drivers blank ANSWERS_DIR and FETCHED before the trap, and a driver that does not is caught'

# The check refuses a digest that is not 64 lowercase hex digits, which sha256sum would accept.
plant 'a check that takes any digest' 's/^    printf .%s\\n. "\$line" | awk .{ exit !(length(\$1) == 64 \&\& \$1 ~ \/^\[0-9a-f\]+\$\/) }. \\$/    true \\/' '^    true \\$'
if ! held "$ENGINE_WORK/planted-driver.sh" "$(printf '%s\n' "$PINNED_DIGESTS" | sed '2s/^\([0-9a-f]*\)/\U\1/')"; then
  fail 'a check without the lowercase rule refused a digest in capitals all the same — the probe proves nothing'
fi
ok 'the planted defect was caught — a check without the lowercase rule accepts a digest in capitals'

# A signal mid-program stops the heartbeat ticker: cleanup() kills the one run_program records.
stops_the_ticker() { sed -n '/^cleanup() {/,/^}/p' "$1" | grep -q 'kill "\$TICKER"' && grep -q '^  TICKER=\$!$' "$1"; }
stops_the_ticker "$HERE/driver.sh" || fail 'driver.sh does not stop the heartbeat ticker when a signal ends the run'
plant 'a cleanup that leaves the ticker running' 's/^  \[ -z "\${TICKER:-}" \] || kill "\$TICKER" 2>\/dev\/null || true$/  : the ticker is left running/' '^  : the ticker is left running$'
if stops_the_ticker "$ENGINE_WORK/planted-driver.sh"; then
  fail 'a driver whose cleanup() leaves the ticker running passed — the probe proves nothing'
fi
ok 'driver.sh stops its heartbeat ticker when a signal ends the run, and a cleanup that leaves it running is caught'

one_check() { diff -u <(check_of "$1") <(check_of "$2") > "$OUT/one-check.out"; }
one_check "$HERE/driver.sh" "$HERE/regenerate-driver.sh" \
  || fail "the two drivers carry different checks — a machine regenerated is held to other bytes than one installed: $(cat "$OUT/one-check.out")"
sed 's/more than once/twice/' "$HERE/regenerate-driver.sh" > "$ENGINE_WORK/planted-regenerate-driver.sh"
if one_check "$HERE/driver.sh" "$ENGINE_WORK/planted-regenerate-driver.sh"; then
  fail 'a regenerate-driver.sh with one word changed compared EQUAL to driver.sh — the comparison proves nothing'
fi
ok 'driver.sh and regenerate-driver.sh carry one check, word for word, and a copy with one word changed is caught'

# The digest file this tree commits, held to the pin it commits by the drivers' own rule: each asset
# named once, and that line well formed. A pin moved by hand without its digests is caught here,
# before a machine refuses the pin.
names_the_pin() { # <digest file text> <pin>
  local tool
  for tool in ansiwise ansiwise-rest; do
    printf '%s\n' "$1" | awk -v asset="$tool-$2-linux-x64" \
      '$2 == asset { n++; ok = length($1) == 64 && $1 ~ /^[0-9a-f]+$/ } END { exit !(n == 1 && ok) }' || return 1
  done
}
TREE_PIN=$(yq e '.cliTools.ansiwise.version' "$HERE/../clusters/platform/versions.yaml")
[ -n "$TREE_PIN" ] && [ "$TREE_PIN" != null ] || fail 'clusters/platform/versions.yaml states no cliTools.ansiwise.version yq could read'
names_the_pin "$(cat "$HERE/../clusters/platform/ansiwise.sha256")" "$TREE_PIN" \
  || fail "clusters/platform/ansiwise.sha256 does not name the two assets of the pin $TREE_PIN once each — every machine off the pin would be refused its engine"
if names_the_pin "$(sed "s/$TREE_PIN/0.8.306-stable-20260929191649/" "$HERE/../clusters/platform/ansiwise.sha256")" "$TREE_PIN"; then
  fail 'a digest file naming another release passed the probe of the committed file — the probe proves nothing'
fi
if names_the_pin "$(cat "$HERE/../clusters/platform/ansiwise.sha256"; echo "BAD  ansiwise-rest-$TREE_PIN-linux-x64")" "$TREE_PIN"; then
  fail 'a digest file naming an asset a second time, in a line the drivers refuse, passed the probe of the committed file'
fi
ok "clusters/platform/ansiwise.sha256 names both assets of the committed pin $TREE_PIN once each, and a file of another release or a second line is caught"

# ── THE OWNER'S ACME BLOCK, read by both drivers' composition of the answers ──
# ACME_SERVER and ACME_EMAIL alone answer letsencrypt_server and letsencrypt_email, and
# ACME_CREDENTIALS_JSON, one line of JSON, gives the External Account Binding's two halves as
# acme_eab_key_id and acme_eab_mac_key. The LETSENCRYPT lines older configs carry are read by nothing
# so a config with them alone composes none of the four.
# Each driver's own COMPOSE block is run out of its own text, against a stand-in config and a
# stand-in declaration, so what is measured is what a machine runs. Every value is synthetic, and
# the MAC key is a sentinel no refusal may print.
ACME_WORK="$WORK/acme"
mkdir -p "$ACME_WORK"
composer_of() { sed -n "/<<'COMPOSE'\$/,/^COMPOSE\$/p" "$1" | sed '1d;$d'; } # <driver> -> its COMPOSE program
cat > "$ACME_WORK/declares.yaml" <<'DECLARES'
name: check
answers:
  - name: letsencrypt_email
    kind: text
  - name: letsencrypt_server
    kind: text
  - name: acme_eab_key_id
    kind: text
  - name: acme_eab_mac_key
    kind: text
steps: []
DECLARES
LEGACY_LINES="LETSENCRYPT_EMAIL='legacy@example.invalid'
LETSENCRYPT_SERVER='https://acme-v02.api.letsencrypt.org/directory'"
acme_config() { # <file> [<ACME_CREDENTIALS_JSON value>] -> a config with the legacy lines, and with the owner's four after them when a value is given
  printf '%s\n' "$LEGACY_LINES" > "$1"
  [ $# -lt 2 ] || printf "%s\n" "ACME_PROVIDER='gts'" "ACME_EMAIL='owner@example.invalid'" \
    "ACME_SERVER='https://dv.acme-v02.api.pki.goog/directory'" "ACME_CREDENTIALS_JSON='$2'" >> "$1"
}
composed() { # <composer> <config> -> its code; the answers in $ACME_WORK/answers.json, what it printed in $ACME_WORK/composed.out
  rm -f "$ACME_WORK/answers.json"
  python3 "$1" "$2" "$ACME_WORK/declares.yaml" "$ACME_WORK/answers.json" > "$ACME_WORK/composed.out" 2>&1
}
ACME_ANSWERS='{
  "answers": {
    "letsencrypt_email": "owner@example.invalid",
    "letsencrypt_server": "https://dv.acme-v02.api.pki.goog/directory",
    "acme_eab_key_id": "synthetic-key-id",
    "acme_eab_mac_key": "SYNTHETIC-MAC-SENTINEL"
  }
}'
LEGACY_ANSWERS='{
  "answers": {}
}'
acme_cases() { # <composer> — every case, or the first that fails, named on standard error
  local composer="$1" json
  acme_config "$ACME_WORK/legacy.env"
  composed "$composer" "$ACME_WORK/legacy.env" || { echo 'a config without the block was refused' >&2; return 1; }
  [ "$(cat "$ACME_WORK/answers.json")" = "$LEGACY_ANSWERS" ] || { echo "a config without the block composed out of the LETSENCRYPT lines: $(cat "$ACME_WORK/answers.json")" >&2; return 1; }
  [ "$(cat "$ACME_WORK/composed.out")" = '0 of the 4 it declares, and 4 left to its own default: letsencrypt_email letsencrypt_server acme_eab_key_id acme_eab_mac_key' ] \
    || { echo "a config without the block printed: $(cat "$ACME_WORK/composed.out")" >&2; return 1; }
  acme_config "$ACME_WORK/owner.env" '{"keyId":"synthetic-key-id","b64MacKey":"SYNTHETIC-MAC-SENTINEL"}'
  composed "$composer" "$ACME_WORK/owner.env" || { echo 'the owner'"'"'s block was refused' >&2; return 1; }
  [ "$(cat "$ACME_WORK/answers.json")" = "$ACME_ANSWERS" ] || { echo "the owner's block composed: $(cat "$ACME_WORK/answers.json")" >&2; return 1; }
  [ "$(cat "$ACME_WORK/composed.out")" = '4 of the 4 it declares' ] || { echo "the owner's block printed: $(cat "$ACME_WORK/composed.out")" >&2; return 1; }
  for json in '{not json SYNTHETIC-MAC-SENTINEL' '["SYNTHETIC-MAC-SENTINEL"]' '{"b64MacKey":"SYNTHETIC-MAC-SENTINEL"}' \
      '{"keyId":"SYNTHETIC-MAC-SENTINEL"}' '{"keyId":"","b64MacKey":"SYNTHETIC-MAC-SENTINEL"}' '{"keyId":"k","b64MacKey":["SYNTHETIC-MAC-SENTINEL"]}'; do
    acme_config "$ACME_WORK/bad.env" "$json"
    if composed "$composer" "$ACME_WORK/bad.env"; then echo "ACME_CREDENTIALS_JSON $json was not refused" >&2; return 1; fi
    grep -q 'ACME_CREDENTIALS_JSON' "$ACME_WORK/composed.out" || { echo "the refusal of $json does not name ACME_CREDENTIALS_JSON" >&2; return 1; }
    if grep -q 'SENTINEL' "$ACME_WORK/composed.out"; then echo "the refusal of $json prints the value" >&2; return 1; fi
    [ ! -e "$ACME_WORK/answers.json" ] || { echo "the refusal of $json still wrote answers" >&2; return 1; }
  done
}
for driver in driver.sh regenerate-driver.sh; do
  composer_of "$HERE/$driver" > "$ACME_WORK/$driver.py"
  [ -s "$ACME_WORK/$driver.py" ] || fail "$driver carries no COMPOSE block to measure"
  acme_cases "$ACME_WORK/$driver.py" 2> "$ACME_WORK/why" || fail "$driver: $(cat "$ACME_WORK/why")"
done
# PLANTED: a composer that lets LETSENCRYPT_SERVER stand over ACME_SERVER, one that still reads
# LETSENCRYPT_SERVER where ACME_SERVER is not stated, and one whose refusal prints the value it
# refuses. Each is caught, or the cases above prove nothing.
sed "s/stated\['letsencrypt_server'\] = stated\['acme_server'\]/pass/" "$ACME_WORK/driver.sh.py" > "$ACME_WORK/planted-server.py"
sed "/stated.pop('letsencrypt_server', None)/d" "$ACME_WORK/driver.sh.py" > "$ACME_WORK/planted-fallback.py"
sed "s/; its value is not shown'/: ' + stated['acme_credentials_json']/" "$ACME_WORK/driver.sh.py" > "$ACME_WORK/planted-print.py"
for planted in planted-server planted-fallback planted-print; do
  ! cmp -s "$ACME_WORK/driver.sh.py" "$ACME_WORK/$planted.py" || fail "the plant $planted changed nothing in the composer"
  if acme_cases "$ACME_WORK/$planted.py" 2>/dev/null; then fail "a composer with the plant $planted passed every ACME case"; fi
done
ok "both drivers compose letsencrypt_server and letsencrypt_email from ACME_SERVER and ACME_EMAIL, and acme_eab_key_id and acme_eab_mac_key from ACME_CREDENTIALS_JSON; a malformed or incomplete binding is refused by its key's name without its value, a config with only the LETSENCRYPT lines composes none of the four, and three planted composers are caught"

echo "test: GREEN — every case above printed the bytes and ended with the code recorded for it,"
echo "test:   with the fixture root, this folder, the home folder, a mint stamp and a resolver's"
echo "test:   reason for a host name it cannot resolve normalised, in the C locale."
echo "test: covered — a fixture's commit and push start no background maintenance, at either end,"
echo "test:   that could still be writing when a case removes its repository, and a planted run"
echo "test:   without the template that prevents it is caught, and so is a copy of release-platform whose"
echo "test:   clone for a pin does not carry the setting; the four release refusals, the mint, the pin, the reuse of a standing"
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
echo "test:   branch and the verdict on a slave that is gone; the owner-only guard against a"
echo "test:   stubbed stat, and the sentence each of the three launchers"
echo "test:   builds from it; the three refusals an abandonment makes before it reads a zone,"
echo "test:   the names it derives off the install branch and the deploy repository's books branch, the"
echo "test:   guard that refuses a cluster whose API still answers, the confirmation, the nine"
echo "test:   records it deletes against a stand-in provider and the six it lists and leaves,"
echo "test:   the three branches it deletes in order, the config it names as staying, and a"
echo "test:   second run that finds nothing to do; the five refusals the GitHub App act makes"
echo "test:   before it opens a browser and its guard on a readable config, the manifest page"
echo "test:   it serves with the nine permissions and no webhook, the redirect it holds to its"
echo "test:   own state, an App answered with eight permissions, the App created and installed"
echo "test:   in one run with every JWT verified against the key's public half and the three"
echo "test:   answers written in place under a kept access list, a second run refused, an"
echo "test:   installation on selected repositories refused with two answers written, and the"
echo "test:   run after it that installs alone; the refusals a master backup and a master restore"
echo "test:   make before they open a session, the door each composes from MACHINE_HOST and not"
echo "test:   from the identity, the id a restore refuses, and the one list of stores both drivers"
echo "test:   carry; install-machine's refusal of a missing config, with no exit code in its"
echo "test:   sentence, and of a first master stated on the ACME account before any session,"
echo "test:   where a copy without that refusal opens one. Eight planted defects, a copy of each act with one printed line changed,"
echo "test:   prove the comparison can go red."
echo "test:   Both drivers' placement, run from their own text in a sandbox, gives a clean machine the"
echo "test:   engine at its pinned digests, refuses a swapped asset with nothing placed, places a"
echo "test:   half-placed machine again and ends the run on a TERM; their one check refuses another"
echo "test:   release, one executable, a name given twice and capitals; the committed digest file names"
echo "test:   the committed pin; both drivers blank the names they remove before the trap, and driver.sh"
echo "test:   stops its heartbeat ticker on a signal. A refusal that does not stop the install, a handler"
echo "test:   that resumes after a TERM, a skip that asks ansiwise alone, a FETCHED left as the environment"
echo "test:   set it, a check that takes any digest and a cleanup that leaves the ticker running are each"
echo "test:   planted, and each is caught."
echo "test:   Both drivers' composition of the answers, run from their own text: the owner's ACME block"
echo "test:   alone and the binding's two halves out of its JSON, six bindings refused by"
echo "test:   name without their value, the LETSENCRYPT lines read by nothing, and three planted composers."
echo "test: covered — a config of mode 644, refused in its recorded sentence by the"
echo "test:   regeneration, the backup, the restore and install-machine, and a planted defect in"
echo "test:   the guard beside the backup and beside the restore that proves the launcher reads it."
echo "test: not covered — an authenticated remote, two workstations minting at one moment, the"
echo "test:   regeneration and the removal themselves on a machine, a slave that is still"
echo "test:   answering, a branch"
echo "test:   deletion a remote refuses (a directory origin refuses none), a DNS provider"
echo "test:   that fails in the middle of the abandonment, GitHub's own answers to a manifest"
echo "test:   and a real browser, the two ten-minute bounds of the GitHub App act, and the backup"
echo "test:   and the restore themselves on a machine — the drill on two masters is what proves those."
