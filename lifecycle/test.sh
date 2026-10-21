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
# there, and writes its answers into the config.
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
# is a stand-in named by BROWSER that drives the act's own listener. The two
# origin pull acts are node tests beside them: create-origin-pull-certificate is
# run three times and its answers are checked with openssl verify, and
# apply-cloudflare-zone-security runs against a stand-in curl that answers as the
# Cloudflare API does; each carries its own planted defects.
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
# file stands in, the home folder, the fourteen digits of a mint stamp and the
# date and time (eight digits, a dash, six) install-machine names a transcript folder after. Those
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
    while [[ "$line" =~ ([0-9]{8}-[0-9]{6}) ]]; do line="${line//${BASH_REMATCH[1]}/TS14}"; done # the folder install-machine names its transcript after
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
  grep '^> ' "$OUT/planted.diff" > "$OUT/planted.added" || true
  if grep -vqF -- "$2" "$OUT/planted.added"; then
    fail "a copy of $1 printed a line the planted words are not in: $(grep -vF -- "$2" "$OUT/planted.added")"
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

# THE MIRROR A RELEASE READS ITS IMAGES BACK FROM is a stand-in curl first on the path of every
# run here. It answers a GET of /v2/<repository>/manifests/<digest> with 200 and that digest where
# serves holds <host>/<repository>@<digest>, and a GET of /v2/<repository>/manifests/<tag> with 200 and a
# manifest of one layer of <sha256> where serves-sources holds <host>/<repository>:<tag> <sha256>, with
# 404 everywhere else, logs every address it is asked, and logs a login it is handed, which a read of
# the mirror never carries. A release here waits for it not at all.
MIRROR_NET="$WORK/mirror-net"
mkdir -p "$MIRROR_NET"
HEX_A="$(printf 'a%.0s' $(seq 64))"
HEX_B="$(printf 'b%.0s' $(seq 64))"
HEX_C="$(printf 'c%.0s' $(seq 64))"
HEX_D="$(printf 'd%.0s' $(seq 64))"
cat > "$MIRROR_NET/curl" <<'STUB'
#!/usr/bin/env bash
headers=/dev/null url="" out=/dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D) headers="$2"; shift ;;
    -u|--user) echo "login: $2" >> "$(dirname "$0")/requests.log"; shift ;;
    -o) out="$2"; shift ;;
    -w|-H|--connect-timeout|--max-time) shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
echo "GET $url" >> "$(dirname "$0")/requests.log"
if [[ "$url" =~ ^https://([^/]+)/v2/(.+)/manifests/(sha256:[0-9a-f]{64})$ ]] \
  && grep -qxF "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}@${BASH_REMATCH[3]}" "$(dirname "$0")/serves"; then
  printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: %s\r\n\r\n' "${BASH_REMATCH[3]}" > "$headers"
  printf 200
elif [[ "$url" =~ ^https://([^/]+)/v2/(.+)/manifests/([A-Za-z0-9_][A-Za-z0-9._-]*)$ ]] \
  && held="$(grep -F "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}:${BASH_REMATCH[3]} " "$(dirname "$0")/serves-sources")"; then
  printf '{"schemaVersion":2,"layers":[{"digest":"sha256:%s"}]}' "${held##* }" > "$out"
  printf 200
else
  printf 'HTTP/1.1 404 Not Found\r\n\r\n' > "$headers"
  printf 404
fi
STUB
chmod +x "$MIRROR_NET/curl"
printf '%s\n' "zot.example.invalid/owner/ghcr.io/fixture/one@sha256:$HEX_A" "zot.example.invalid/owner/ghcr.io/fixture/two@sha256:$HEX_B" > "$MIRROR_NET/serves"
printf '%s\n' "zot.example.invalid/owner/charts.example.invalid/fixture-one:1.0.0 $HEX_C" "zot.example.invalid/owner/charts.example.invalid/fixture-two:2.0.0 $HEX_D" > "$MIRROR_NET/serves-sources"
export RELEASE_MIRROR_WAIT=0

run_bash() { # script base name, then its arguments
  local base="$1"; shift
  A_CODE=0
  ( cd "$WORK_A" && PATH="$MIRROR_NET:$PATH" bash "$HERE/$base.sh" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
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
# The list a release reads its images off, as the tree at the tag prints it: two images, each
# beside its name in the mirror.
mkdir -p "$SEED/scripts"
cat > "$SEED/scripts/list-mirror-images.sh" <<STUB
#!/usr/bin/env bash
# The images of the fixture tree: two on ghcr.io, each beside its name in the mirror.
printf '%s\n' \\
  'ghcr.io/fixture/one:1.0.0@sha256:$HEX_A zot.example.invalid/owner/ghcr.io/fixture/one:1.0.0@sha256:$HEX_A' \\
  'ghcr.io/fixture/two:2.0.0@sha256:$HEX_B zot.example.invalid/owner/ghcr.io/fixture/two:2.0.0@sha256:$HEX_B'
STUB
# The tools and charts of the fixture tree: two charts on a repository of no upstream, each beside its name in the
# mirror, and the file of the real tree that reads a row back, as the tree at a tag carries it.
cat > "$SEED/scripts/list-mirror-sources.sh" <<STUB
#!/usr/bin/env bash
# The tools and charts of the fixture tree: two charts, each beside its name in the mirror.
printf '%s\n' \\
  'chart https://charts.example.invalid fixture-one 1.0.0 $HEX_C zot.example.invalid/owner/charts.example.invalid/fixture-one:1.0.0 oci://zot.example.invalid/owner/charts.example.invalid' \\
  'chart https://charts.example.invalid fixture-two 2.0.0 $HEX_D zot.example.invalid/owner/charts.example.invalid/fixture-two:2.0.0 oci://zot.example.invalid/owner/charts.example.invalid'
STUB
mkdir -p "$SEED/clusters/inventories/consumer-build/files"
cp "$HERE/../clusters/inventories/consumer-build/files/mirror-sources.sh" "$SEED/clusters/inventories/consumer-build/files/mirror-sources.sh"
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
  local d origin_map
  d="$(mktemp -d "$WORK/pin.XXXXXX")" || return 1
  cp -a "$ORIGIN_A" "$d/origin.git"
  git clone --quiet "$d/origin.git" "$d/checkout"
  ( cd "$d/checkout" && unset GIT_TEMPLATE_DIR && PATH="$MIRROR_NET:$PATH" GIT_TRACE="$d/trace" bash "$1" 0.4.0 alpha apps3.example.invalid ) > /dev/null 2>&1 || {
    echo "the traced release of $1 did not end clean" >&2
    return 1
  }
  origin_map="$(git --git-dir="$d/origin.git" show 'apps3.example.invalid:clusters/active/apps3.example.invalid.yaml')" && grep -q '^release: 0.4.0-alpha-' <<< "$origin_map" || {
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
release: minted 0.1.0-alpha-TS14 on origin/master (commit aa499c5)
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: the mirror serves all 2 images of 0.1.0-alpha-TS14 at their digests, read without a login
release: the mirror serves all 2 tools and charts of 0.1.0-alpha-TS14
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
release: the mirror serves all 2 images of 0.1.0-alpha-TS14 at their digests, read without a login
release: the mirror serves all 2 tools and charts of 0.1.0-alpha-TS14
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
cp "$HERE/check-forgejo-ssh.sh" "$WORK/"
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
release: 0.2.0-alpha-TS14 stands on this workstation only and names 778a9c6, not the commit this release is cut from. A run whose push was refused left it behind; it is dropped and cut again.
release: minted 0.2.0-alpha-TS14 on origin/master (commit 9aec6ae)
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: the mirror serves all 2 images of 0.2.0-alpha-TS14 at their digests, read without a login
release: the mirror serves all 2 tools and charts of 0.2.0-alpha-TS14
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
release: the mirror serves all 2 images of 0.3.0-alpha-TS14 at their digests, read without a login
release: the mirror serves all 2 tools and charts of 0.3.0-alpha-TS14
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
release: minted 0.4.0-alpha-TS14 on origin/master (commit 9aec6ae)
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: the mirror serves all 2 images of 0.4.0-alpha-TS14 at their digests, read without a login
release: the mirror serves all 2 tools and charts of 0.4.0-alpha-TS14
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
  origin_map="$(git --git-dir="$ORIGIN_A" show "$each.example.invalid:clusters/active/$each.example.invalid.yaml")" && grep -q '^release: 0.4.0-alpha-' <<< "$origin_map" \
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
release: minted 0.6.0-alpha-TS14 on origin/master (commit 9aec6ae)
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: the mirror serves all 2 images of 0.6.0-alpha-TS14 at their digests, read without a login
release: the mirror serves all 2 tools and charts of 0.6.0-alpha-TS14
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
release: minted 0.7.0-alpha-TS14 on origin/master (commit 9aec6ae)
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: the mirror serves all 2 images of 0.7.0-alpha-TS14 at their digests, read without a login
release: the mirror serves all 2 tools and charts of 0.7.0-alpha-TS14
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

# ── a mirror that lacks one image of the tag stops the release before the pin ──
# THE PUBLISH RUN OF THE TAG COPIES THE IMAGES INTO THE MIRROR, and a pin before the copy is a pod
# that cannot pull. The stand-in mirror serves the second image of the list only: the release mints
# and pushes its tag, lists the images off the tree at the tag, reads each back by its digest, names
# the one the mirror lacks, and pins, writes and regenerates nothing. The innocent case is every
# release above, against a mirror that serves both.
HEAD_APPS4="$(git --git-dir="$ORIGIN_A" rev-parse refs/heads/apps4.example.invalid)"
CONFIG_BEFORE="$(cat "$WORK_A/lifecycle/config.other.env")"
cp "$MIRROR_NET/serves" "$MIRROR_NET/serves.all"
grep -vF fixture/one "$MIRROR_NET/serves.all" > "$MIRROR_NET/serves"
: > "$MIRROR_NET/requests.log"
run_bash release-platform 0.9.0 alpha apps4.example.invalid
cp "$MIRROR_NET/serves.all" "$MIRROR_NET/serves"
must "release: the mirror does not serve 1 of the 2 images of 0.9.0-alpha-" 'a mirror that lacks one image of the tag stops the release'
must "zot.example.invalid/owner/ghcr.io/fixture/one:1.0.0@sha256:$HEX_A;" 'and names the image the mirror lacks'
must_not "release: pinned" 'nothing is pinned before the mirror serves every image of the tag'
expect 'a mirror that lacks one image of the tag' 69 <<RECORDED
release: minted 0.9.0-alpha-TS14 on origin/master (commit 9aec6ae)
release: the tag stands on the remote, so a machine that fetches origin can resolve it
~~~ standard error ~~~
release: the mirror does not serve 1 of the 2 images of 0.9.0-alpha-TS14 after 0s: zot.example.invalid/owner/ghcr.io/fixture/one:1.0.0@sha256:$HEX_A; the publish run of 0.9.0-alpha-TS14 on the owner's master copies them. Nothing was pinned. Read that run, then release again: the tag is reused
RECORDED
[ "$(cat "$MIRROR_NET/requests.log")" = "GET https://zot.example.invalid/v2/owner/ghcr.io/fixture/one/manifests/sha256:$HEX_A
GET https://zot.example.invalid/v2/owner/ghcr.io/fixture/two/manifests/sha256:$HEX_B" ] \
  || fail "the release did not read every image of the list once, by its digest and without a login: $(cat "$MIRROR_NET/requests.log")"
[ "$(git --git-dir="$ORIGIN_A" rev-parse refs/heads/apps4.example.invalid)" = "$HEAD_APPS4" ] \
  || fail 'the release moved the branch of apps4 although the mirror lacked an image of the tag'
[ "$(cat "$WORK_A/lifecycle/config.other.env")" = "$CONFIG_BEFORE" ] \
  || fail 'the release wrote PLATFORM_REF although the mirror lacked an image of the tag'
ok 'a mirror that lacks one image stops the release by name after the tag and before the pin, the config and the regeneration'

# ── a mirror that lacks a tool or chart of the tag, or serves another file for it, stops the release before the pin ──
# THE TOOLS AND CHARTS OF THE TAG ARE COPIED BY THE SAME RUN, and a pin before the copy is a master that cannot
# fetch its own tools. The tree at the tag lists them (scripts/list-mirror-sources.sh) and the release reads
# each row by the manifest of its tag, which has to name one layer of the row's sha256. The first stand-in
# mirror lacks the first row, the second serves the second row as a layer of another sha256: each stops the
# release after the images were read, naming the row and what the mirror answered, and pins, writes and
# regenerates nothing. The innocent case is every release above, against a mirror that serves both rows.
cp "$MIRROR_NET/serves-sources" "$MIRROR_NET/serves-sources.all"
grep -vF fixture-one "$MIRROR_NET/serves-sources.all" > "$MIRROR_NET/serves-sources"
: > "$MIRROR_NET/requests.log"
run_bash release-platform 0.9.1 alpha apps4.example.invalid
cp "$MIRROR_NET/serves-sources.all" "$MIRROR_NET/serves-sources"
must "release: the mirror does not serve 1 of the 2 tools and charts of 0.9.1-alpha-" 'a mirror that lacks one row of the tag stops the release'
must "zot.example.invalid/owner/charts.example.invalid/fixture-one:1.0.0 (absent answered 404);" 'and names the row the mirror lacks and what it answered'
must_not "release: the mirror serves all 2 tools and charts" 'a mirror that lacks a row is not reported as serving them'
must_not "release: pinned" 'nothing is pinned before the mirror serves every tool and chart of the tag'
expect 'a mirror that lacks one tool or chart of the tag' 69 <<RECORDED
release: minted 0.9.1-alpha-TS14 on origin/master (commit 9aec6ae)
release: the tag stands on the remote, so a machine that fetches origin can resolve it
release: the mirror serves all 2 images of 0.9.1-alpha-TS14 at their digests, read without a login
~~~ standard error ~~~
release: the mirror does not serve 1 of the 2 tools and charts of 0.9.1-alpha-TS14 after 0s: zot.example.invalid/owner/charts.example.invalid/fixture-one:1.0.0 (absent answered 404); the publish run of 0.9.1-alpha-TS14 on the owner's master copies them. Nothing was pinned. Read that run, then release again: the tag is reused
RECORDED
[ "$(grep -c 'manifests/[0-9]' "$MIRROR_NET/requests.log")" = 2 ] && grep -qxF 'GET https://zot.example.invalid/v2/owner/charts.example.invalid/fixture-one/manifests/1.0.0' "$MIRROR_NET/requests.log" \
  && grep -qxF 'GET https://zot.example.invalid/v2/owner/charts.example.invalid/fixture-two/manifests/2.0.0' "$MIRROR_NET/requests.log" \
  || fail "the release did not read every tool and chart of the list once, by its tag and without a login: $(cat "$MIRROR_NET/requests.log")"
! grep -q '^login' "$MIRROR_NET/requests.log" || fail 'the release handed the mirror a login'
[ "$(git --git-dir="$ORIGIN_A" rev-parse refs/heads/apps4.example.invalid)" = "$HEAD_APPS4" ] \
  || fail 'the release moved the branch of apps4 although the mirror lacked a tool or chart of the tag'
[ "$(cat "$WORK_A/lifecycle/config.other.env")" = "$CONFIG_BEFORE" ] \
  || fail 'the release wrote PLATFORM_REF although the mirror lacked a tool or chart of the tag'
ok 'a mirror that lacks one tool or chart stops the release by name after the images and before the pin, the config and the regeneration'

grep -vF fixture-two "$MIRROR_NET/serves-sources.all" > "$MIRROR_NET/serves-sources"
printf '%s\n' "zot.example.invalid/owner/charts.example.invalid/fixture-two:2.0.0 $HEX_C" >> "$MIRROR_NET/serves-sources"
run_bash release-platform 0.9.2 alpha apps4.example.invalid
cp "$MIRROR_NET/serves-sources.all" "$MIRROR_NET/serves-sources"
must "release: the mirror does not serve 1 of the 2 tools and charts of 0.9.2-alpha-" 'a mirror that serves another file for a row stops the release'
must "zot.example.invalid/owner/charts.example.invalid/fixture-two:2.0.0 (other answered 200 with the one layer sha256:$HEX_C);" 'and names the row and the layer the mirror answered with'
must_not "release: pinned" 'nothing is pinned before the mirror serves the file of every row'
[ "$A_CODE" = 69 ] || fail "a mirror that serves another file for a row ended the release with $A_CODE, not 69"
ok 'a mirror that serves another file for a row stops the release by name, with the layer it answered with'

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
cp "$HERE/regenerate-driver.sh" "$HERE/require-owner-only.sh" "$HERE/require-config-assignments.sh" "$HERE/require-forgejo-destinations.sh" "$WORK/"
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
cp "$HERE/driver.sh" "$HERE/require-owner-only.sh" "$HERE/require-config-assignments.sh" "$HERE/require-forgejo-destinations.sh" "$PLANTED_IM/"
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
FORGEJO_PLATFORM_REPOSITORY='platform-team/platform'
FORGEJO_DEPLOY_REPOSITORY='deploy-team/deploy'
FORGEJO_ORGANISATIONS='platform-team,deploy-team'
FORGEJO_HOST='forgejo.master.example.invalid'
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
cp "$HERE/driver.sh" "$HERE/require-owner-only.sh" "$HERE/require-config-assignments.sh" "$HERE/require-forgejo-destinations.sh" "$PLANTED_ACME/"
grep -vF '[ -z "${ACME_CREDENTIALS_JSON:-}" ] ||' "$HERE/install-machine.sh" > "$PLANTED_ACME/install-machine.sh"
cmp -s "$HERE/install-machine.sh" "$PLANTED_ACME/install-machine.sh" \
  && fail 'the refusal was not taken out of the planted install-machine.sh — the probe proves nothing'
run_acme "$PLANTED_ACME/install-machine.sh" "$IMACME"
[ -e "$ACMESSH/called" ] || fail 'the planted install-machine without the refusal opened no session either — the case cannot go red'
[ "$A_CODE" = '69' ] || fail "the planted install-machine must end at the recording ssh with 69, got $A_CODE"
rm -f "$ACMESSH/called"
ok 'the planted defect was caught — a copy without the refusal opens a session with the ACME config'

# ── both launchers refuse Forgejo destinations that omit a repository owner ──
# THE OWNER OF EACH DESTINATION REPOSITORY MUST BE ONE OF THE ORGANISATIONS, and no step of a program
# reads two answers, so the launchers refuse it where the config is read, before the first session.
# The recording ssh stands first on PATH: a refusal leaves it uncalled, and a launcher without the
# check calls it.
forgejo_destinations_config() { # file, fqdn, platform repository, deploy repository, organisations
  cat > "$1" <<CONFIG
FQDN='$2'
OPERATOR_USER='operator'
STAGE='prod'
DEPLOY_REPO='https://example.invalid/deploy.git'
PROGRAMS_REPO='https://example.invalid/programs.git'
PLATFORM_REPO='https://example.invalid/platform.git'
PLATFORM_REF='master'
ELEVATION_PASSWORD='elevation-test'
FORGEJO_PLATFORM_REPOSITORY='$3'
FORGEJO_DEPLOY_REPOSITORY='$4'
FORGEJO_ORGANISATIONS='$5'
FORGEJO_HOST='forgejo.$2'
CONFIG
  chmod 600 "$1"
}
run_destinations() { # the launcher, then its arguments
  A_CODE=0
  ( cd "$WORK_A" && PATH="$ACMESSH:$PATH" bash "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
launch_destinations() { # the directory of the launcher, the launcher, then the config
  local dir="$1" launcher="$2" config="$3"
  case "$launcher" in
    install-machine) run_destinations "$dir/install-machine.sh" "$config" ;;
    regenerate-install-branch) run_destinations "$dir/regenerate-install-branch.sh" apps3.example.invalid "$config" ;;
  esac
}
FDEST="$WORK/forgejo-destinations"
mkdir -p "$FDEST"
FD_FQDN_install_machine='master.example.invalid'
FD_FQDN_regenerate_install_branch='apps3.example.invalid'
for launcher in install-machine regenerate-install-branch; do
  fqdn_of="FD_FQDN_${launcher//-/_}"
  config="$FDEST/$launcher.env"
  # PLANTED: the case of the finding, organisations that name neither owner, and each owner alone.
  for organisations in foreign-team platform-team deploy-team; do
    forgejo_destinations_config "$config" "${!fqdn_of}" platform-team/platform deploy-team/deploy "$organisations"
    rm -f "$ACMESSH/called"
    launch_destinations "$HERE" "$launcher" "$config"
    [ ! -e "$ACMESSH/called" ] || fail "$launcher: organisations $organisations opened a session: $(cat "$ACMESSH/called")"
    [ "$A_CODE" = '65' ] || fail "$launcher: organisations $organisations must end with 65, got $A_CODE"
    must 'FORGEJO_ORGANISATIONS' "$launcher: the refusal names the answer"
    case "$organisations" in
      foreign-team) must 'platform-team' "$launcher: the refusal names an owner it misses" ;;
      platform-team) must 'deploy-team' "$launcher: the refusal names the owner it misses" ;;
      deploy-team) must 'platform-team' "$launcher: the refusal names the owner it misses" ;;
    esac
  done
  # PLANTED: each destination answer left empty is refused by its name.
  for name in FORGEJO_PLATFORM_REPOSITORY FORGEJO_DEPLOY_REPOSITORY FORGEJO_ORGANISATIONS FORGEJO_HOST; do
    forgejo_destinations_config "$config" "${!fqdn_of}" platform-team/platform deploy-team/deploy platform-team,deploy-team
    sed -i "s/^$name='.*'/$name=''/" "$config"
    rm -f "$ACMESSH/called"
    launch_destinations "$HERE" "$launcher" "$config"
    [ ! -e "$ACMESSH/called" ] || fail "$launcher: an empty $name opened a session"
    [ "$A_CODE" = '65' ] || fail "$launcher: an empty $name must end with 65, got $A_CODE"
    must "states no $name" "$launcher: the refusal names $name"
  done
  # INNOCENT: the owners listed among more organisations, in another letter case, go on to the session.
  for organisations in platform-team,deploy-team Deploy-Team,PLATFORM-team,other-team; do
    forgejo_destinations_config "$config" "${!fqdn_of}" platform-team/platform deploy-team/deploy "$organisations"
    rm -f "$ACMESSH/called"
    launch_destinations "$HERE" "$launcher" "$config"
    [ -e "$ACMESSH/called" ] || fail "$launcher: organisations $organisations that cover both owners were refused: $(cat "$OUT/a.err")"
  done
  # PLANTED LAUNCHER: a copy without the call reaches the session with the finding's organisations.
  planted="$FDEST/planted-$launcher"
  mkdir -p "$planted"
  cp "$HERE/$launcher.sh" "$HERE/driver.sh" "$HERE/regenerate-driver.sh" "$HERE/require-owner-only.sh" "$HERE/require-config-assignments.sh" "$HERE/require-forgejo-destinations.sh" "$planted/"
  grep -vF 'require_forgejo_destinations ||' "$HERE/$launcher.sh" > "$planted/$launcher.sh"
  cmp -s "$HERE/$launcher.sh" "$planted/$launcher.sh" \
    && fail "the call was not taken out of the planted $launcher.sh — the probe proves nothing"
  forgejo_destinations_config "$config" "${!fqdn_of}" platform-team/platform deploy-team/deploy foreign-team
  rm -f "$ACMESSH/called"
  launch_destinations "$planted" "$launcher" "$config"
  [ -e "$ACMESSH/called" ] || fail "the planted $launcher without the check opened no session either — the case cannot go red"
  rm -f "$ACMESSH/called"
done
ok 'both launchers refuse destinations that omit an owner or leave an answer empty before any session, and let covered owners through; a launcher without the check is caught'

# ── the Forgejo SSH row: status and install-machine ask the port an install branch announces ──
# check-forgejo-ssh.sh is called where a person meets it, on the operator's machine: one row of
# status.sh for an installation whose branch runs Forgejo, and the end of install-machine.sh. The
# fixture is one origin of three installation branches: a Forgejo whose announced port answers, one
# whose port does not, and one that runs no Forgejo. The network is one stand-in curl that gives an
# SSH banner on the first port alone, so a green and a red row are the branch's port and nothing else.
ORIGIN_F="$WORK/origin-f.git"
WORK_F="$WORK/checkout-f"
git init --quiet --bare --initial-branch=master "$ORIGIN_F"
SEED_F="$WORK/seed-f"
git init --quiet --initial-branch=master "$SEED_F"
git -C "$SEED_F" remote add origin "$ORIGIN_F"
echo '# the product tree' > "$SEED_F/README.md"
git -C "$SEED_F" add -A
git -C "$SEED_F" commit --quiet -m 'Seed the trunk'
git -C "$SEED_F" push --quiet origin master
seed_forgejo_installation() { # fqdn, announced ssh port (empty for an installation that runs no Forgejo)
  git -C "$SEED_F" checkout --quiet -b "$1" master
  mkdir -p "$SEED_F/clusters/active" "$SEED_F/installation/values"
  printf 'stage: dev\nrole: master\n' > "$SEED_F/clusters/active/$1.yaml"
  [ -z "$2" ] || printf 'forgejo:\n  gitea:\n    config:\n      server:\n        SSH_DOMAIN: forgejo.example.invalid\n        SSH_PORT: %s\n' "$2" > "$SEED_F/installation/values/forgejo.yaml"
  git -C "$SEED_F" add -A
  git -C "$SEED_F" commit --quiet -m "Generate the branch of $1"
  git -C "$SEED_F" push --quiet origin "$1"
  git -C "$SEED_F" checkout --quiet master
}
seed_forgejo_installation forge-green.example.invalid 2323
seed_forgejo_installation forge-red.example.invalid 2424
seed_forgejo_installation forge-none.example.invalid ''
git clone --quiet "$ORIGIN_F" "$WORK_F"
FORGEJO_NET="$WORK/forgejo-net"
mkdir -p "$FORGEJO_NET"
cat > "$FORGEJO_NET/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/asked"
case "$*" in *telnet://forgejo.example.invalid:2323) printf 'SSH-2.0-Go\r\n' ;; esac
exit 28
STUB
chmod +x "$FORGEJO_NET/curl"
run_forgejo() { # the script, then its arguments; run in the clone, with the stand-in curl first on the path
  local script="$1"; shift
  A_CODE=0
  ( cd "$WORK_F" && PATH="$FORGEJO_NET:$PATH" bash "$script" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
ok 'fixture built — one origin, a Forgejo with an open port, a Forgejo with a closed one, and an installation without Forgejo'

run_forgejo "$HERE/status.sh"
expect 'status: a Forgejo row green for an open port, red for a closed one, and none where no Forgejo runs' 0 <<'RECORDED'
status: which platform release each install branch stands on, and what origin/master carries since. A cluster carrying only the slave part has no branch here and runs the revision of the branch that keeps its books

forge-green.example.invalid
  release: none
  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release-platform.sh beside this file writes that line.
  forgejo-ssh: green, forgejo.example.invalid:2323 answers SSH-2.0-Go

forge-none.example.invalid
  release: none
  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release-platform.sh beside this file writes that line.

forge-red.example.invalid
  release: none
  unpinned: nothing records which platform state this installation stands on, so nothing can say whether it is behind. release-platform.sh beside this file writes that line.
  forgejo-ssh: RED, forgejo.example.invalid:2424 gave no SSH banner
~~~ standard error ~~~
RECORDED
grep -qx -- '-sS --connect-timeout 5 --max-time 8 telnet://forgejo.example.invalid:2323' "$FORGEJO_NET/asked" \
  || fail "status: the port was not the branch's announced one: $(cat "$FORGEJO_NET/asked")"
[ "$(grep -c . "$FORGEJO_NET/asked")" = '2' ] || fail 'status: the probe must be asked once per Forgejo installation, and not for the one without'
rm -f "$FORGEJO_NET/asked"
# The planted defect: a copy of status.sh that reports a closed port green.
PLANTED_FS="$WORK/planted-status-forgejo"
mkdir -p "$PLANTED_FS"
cp "$HERE/check-forgejo-ssh.sh" "$PLANTED_FS/"
sed 's/forgejo-ssh: RED/forgejo-ssh: green/' "$HERE/status.sh" > "$PLANTED_FS/status.sh"
cmp -s "$HERE/status.sh" "$PLANTED_FS/status.sh" && fail 'the red row was not planted in status.sh — the probe proves nothing'
run_forgejo "$PLANTED_FS/status.sh"
grep -q 'forgejo-ssh: green, forgejo.example.invalid:2424' "$OUT/a.out" || fail 'the planted status printed no row for the closed port — the probe was aimed at a line the fixture does not reach'
caught status.sh 'forgejo-ssh: green, forgejo.example.invalid:2424'
rm -f "$FORGEJO_NET/asked"

# install-machine: the same two rows at its end, and none after an installation that failed.
FORGEJO_IM="$WORK/forgejo-install-machine"
mkdir -p "$FORGEJO_IM"
cp "$HERE/install-machine.sh" "$HERE/driver.sh" "$HERE/require-owner-only.sh" "$HERE/require-config-assignments.sh" "$HERE/require-forgejo-destinations.sh" "$HERE/check-forgejo-ssh.sh" "$FORGEJO_IM/"
cat > "$FORGEJO_NET/ssh" <<'STUB'
#!/usr/bin/env bash
case "$*" in *' true') exit 0 ;; esac
cat > /dev/null
[ ! -e "$(dirname "$0")/fail" ] || exit 3
STUB
chmod +x "$FORGEJO_NET/ssh"
forgejo_install_config() { # fqdn
  local file="$WORK/forgejo-install-$1.env"
  cat > "$file" <<CONFIG
FQDN='$1'
OPERATOR_USER='operator'
STAGE='prod'
DEPLOY_REPO='https://example.invalid/deploy.git'
PROGRAMS_REPO='https://example.invalid/programs.git'
PLATFORM_REPO='https://example.invalid/platform.git'
PLATFORM_REF='master'
ELEVATION_PASSWORD='elevation-test'
FORGEJO_PLATFORM_REPOSITORY='platform-team/platform'
FORGEJO_DEPLOY_REPOSITORY='deploy-team/deploy'
FORGEJO_ORGANISATIONS='platform-team,deploy-team'
FORGEJO_HOST='forgejo.$1'
CONFIG
  chmod 600 "$file"
  printf '%s\n' "$file"
}
IM_GREEN="$(forgejo_install_config forge-green.example.invalid)"
IM_RED="$(forgejo_install_config forge-red.example.invalid)"
IM_NONE="$(forgejo_install_config forge-none.example.invalid)"
run_forgejo "$FORGEJO_IM/install-machine.sh" "$IM_GREEN"
must 'forgejo-ssh: green, forgejo.example.invalid:2323 answers SSH-2.0-Go' 'install-machine: an open port is reported green at the end'
[ "$A_CODE" = '0' ] || fail "install-machine: an installation that ended well must end with 0, got $A_CODE"
run_forgejo "$FORGEJO_IM/install-machine.sh" "$IM_NONE"
must_not 'forgejo-ssh' 'install-machine: an installation without Forgejo says nothing about its port'
run_forgejo "$FORGEJO_IM/install-machine.sh" "$IM_RED"
expect 'install-machine: a closed Forgejo port is reported red at the end, and the installation still ends 0' 0 <<'RECORDED'
~~~ standard error ~~~

  forge-red.example.invalid  ·  stage prod
  Everything said here is also kept in <WORK>/forgejo-install-machine/install-transcripts/forge-red.example.invalid-TS14/session.log
  operator@forge-red.example.invalid opens to the operator key
  The machine named no runs — read the transcript above; nothing was recorded to fetch.

  forgejo-ssh: RED, forgejo.example.invalid:2424 gave no SSH banner. Forward FORGEJO_SSH_PORT on the router to the master's 2222; until it answers no clone over SSH works.

RECORDED
# The planted defect: the same copy, in the same folder (its transcript path is part of the block), reporting a closed port green.
sed 's/forgejo-ssh: RED/forgejo-ssh: green/' "$HERE/install-machine.sh" > "$FORGEJO_IM/install-machine.sh"
cmp -s "$HERE/install-machine.sh" "$FORGEJO_IM/install-machine.sh" && fail 'the red row was not planted in install-machine.sh — the probe proves nothing'
run_forgejo "$FORGEJO_IM/install-machine.sh" "$IM_RED"
grep -q 'forgejo-ssh: green, forgejo.example.invalid:2424' "$OUT/a.err" || fail 'the planted install-machine printed no row for the closed port — the probe was aimed at a line the fixture does not reach'
caught install-machine.sh 'forgejo-ssh: green, forgejo.example.invalid:2424'
cp "$HERE/install-machine.sh" "$FORGEJO_IM/install-machine.sh"
touch "$FORGEJO_NET/fail"
run_forgejo "$FORGEJO_IM/install-machine.sh" "$IM_GREEN"
[ "$A_CODE" = '3' ] || fail "install-machine: an installation that failed must end with its own code 3, got $A_CODE"
must_not 'forgejo-ssh' 'install-machine: a failed installation has no branch to ask about, so it reports no port'
rm -f "$FORGEJO_NET/fail"
ok 'install-machine reports the Forgejo port at the end of an installation that ended well, and only there'

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
command -v jq > /dev/null 2>&1 || fail 'jq is not on this path, and the stand-in GitHub pretty-prints its answers with it'
openssl genrsa 2048 > "$GHAPP/key.pem" 2>/dev/null || fail 'openssl could not mint the fixture key'
openssl rsa -in "$GHAPP/key.pem" -pubout > "$GHAPP/pub.pem" 2>/dev/null || fail 'openssl could not derive the public half of the fixture key'
# The key as GitHub's JSON spells it: one line, \n for each line break.
awk '{ printf "%s\\n", $0 }' "$GHAPP/key.pem" > "$GHAPP/pem.json"
SIX_PERMISSIONS='"administration":"write","contents":"write","metadata":"read","packages":"read","webhooks":"write","workflows":"write"'
FIVE_PERMISSIONS='"administration":"write","contents":"write","metadata":"read","webhooks":"write","workflows":"write"'

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
  'GET /app/installations/'*)
    log "GET $path jwt=$verdict"
    installed="$(cat "$state/installation")"
    case "$verdict" in verified*) ;; *) installed=unauthorised ;; esac
    account='"account":{"login":"acme","id":99,"node_id":"O_99","type":"Organization","site_admin":false},'
    [ -f "$state/no-account" ] && account=''
    case "$installed" in
      absent|absent-then-all) status=404; body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/apps/apps#get-an-installation-for-the-authenticated-app","status":"404"}' ;;
      unauthorised) status=401; body='{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest","status":"401"}' ;;
      *) status=200; body="{\"id\":815,$account\"repository_selection\":\"$installed\",\"app_id\":4711,\"app_slug\":\"acme-platform-manager\",\"target_id\":99,\"target_type\":\"Organization\",\"events\":[]}" ;;
    esac ;;
  *) log "$method $path"; status=404; body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}' ;;
esac
if [ -f "$state/pretty" ]; then
  body="$(printf '%s' "$body" | jq .)"
  printf '%s' "$body" > "$state/last-body"
fi
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
    echo "GITHUB_APP_OWNER=''"
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
  [ "$(config_line GITHUB_APP_OWNER)" = '' ] || fail "$1 — GITHUB_APP_OWNER was written"
}
page_holds() { # what was being checked -> the act served a page carrying the manifest asked for
  local page="$GHAPP/state-a/page.html"
  [ -s "$page" ] || fail "$1 — the stand-in browser fetched no page from the listener"
  grep -qF '<form method="post" action="https://github.com/organizations/acme/settings/apps/new?state=' "$page" || fail "$1 — the page does not post to the organisation's new-App page with a state"
  if grep -qF '&quot;' "$page"; then fail "$1 — the page escaped the manifest's quotes, which a single-quoted attribute does not need"; fi
  grep -qF "\"default_permissions\":{$SIX_PERMISSIONS}" "$page" || fail "$1 — the manifest does not carry exactly the six permissions"
  grep -qF '"hook_attributes":{"active":false}' "$page" || fail "$1 — the manifest does not switch the webhook off"
  grep -qF '"public":false' "$page" || fail "$1 — the manifest does not make the App private"
  grep -qF '"name":"acme-platform-manager","url":"https://manager.example.invalid","redirect_url":"http://127.0.0.1:' "$page" || fail "$1 — the manifest does not name the App, its homepage and the listener"
  grep -qF 'onload="document.forms[0].submit()"' "$page" || fail "$1 — the page does not submit itself"
  [ "$(cat "$GHAPP/state-a/answer")" = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>done</title></head><body>done, back to the terminal</body></html>' ] \
    || fail "$1 — the listener did not answer the redirect with the one line"
}
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" all
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
printf "GITHUB_APP_ID='1'\nGITHUB_APP_INSTALLATION_ID='2'\nGITHUB_APP_PRIVATE_KEY='k'\nGITHUB_APP_OWNER='acme'\nDEPLOY_REPO='acme/deploy'\nUNIT_APEX='example.invalid'\n" > "$FULLCFG"
run_app_bash "$FULLCFG"
must "create-github-app: $FULLCFG already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY and GITHUB_APP_OWNER. Nothing has been changed" 'a config carrying the four answers is refused by name'
[ "$A_CODE" = '65' ] || fail "a config carrying the four answers must end with 65, got $A_CODE"
expect 'a config carrying the four answers' 65 <<'RECORDED'
~~~ standard error ~~~
create-github-app: <WORK>/github-app/config.full.env already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY and GITHUB_APP_OWNER. Nothing has been changed
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
ok 'the manifest page carries the six permissions, no webhook, private, the listener, and submits itself; the listener answers the redirect with one line; a redirect with another state is refused before the code reaches GitHub'

# ── an App answered with five permissions is refused, and named ───────────
seed_github "$GHAPP/state-a" "$FIVE_PERMISSIONS" all
run_app_bash config.apps6.env
must "create-github-app: GitHub sent the browser back with a code, and the state is this run's" 'the code and the state are taken off the redirect'
must 'create-github-app: the App was created at https://github.com/apps/acme-platform-manager with the permissions administration:write contents:write metadata:read webhooks:write workflows:write and not the six asked: administration:write contents:write metadata:read packages:read webhooks:write workflows:write. Delete it there and run this again. Nothing has been written' \
  'an App answered with five permissions is refused, both lists named'
[ "$A_CODE" = '65' ] || fail "five permissions must refuse with 65, got $A_CODE"
expect 'an App answered with five permissions' 65 <<'RECORDED'
create-github-app: the App acme-platform-manager is created in the organisation acme, the owner of DEPLOY_REPO in config.apps6.env, with its homepage https://manager.example.invalid
create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes
create-github-app: opened the manifest page in the browser; it posts to https://github.com/organizations/acme/settings/apps/new. In the browser: click Create GitHub App
create-github-app: GitHub sent the browser back with a code, and the state is this run's
~~~ standard error ~~~
create-github-app: the App was created at https://github.com/apps/acme-platform-manager with the permissions administration:write contents:write metadata:read webhooks:write workflows:write and not the six asked: administration:write contents:write metadata:read packages:read webhooks:write workflows:write. Delete it there and run this again. Nothing has been written
RECORDED
[ "$(cat "$GHAPP/state-a/log")" = 'POST /app-manifests/c0de0fthefixture/conversions' ] || fail "the conversion was not the one call, or not with the fixture's code: $(tr '\n' ' ' < "$GHAPP/state-a/log")"
nothing_written 'an App answered with five permissions'
ok 'the conversion is asked with the code off the redirect, and an App answered with five permissions is refused by both lists with nothing written'

# ── the act itself, both clicks in one run ──────────────────────────────────
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" all
run_app_bash config.apps6.env
must 'create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711) with the six permissions administration:write contents:write metadata:read packages:read webhooks:write workflows:write' 'the App is named with its id and its permissions'
must 'create-github-app: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY written into config.apps6.env in place' 'the id and the key are written before the installation is asked for'
must 'create-github-app: opened https://github.com/apps/acme-platform-manager/installations/new in the browser. In the browser: choose All repositories and click Install' 'the person is told the second click'
must 'create-github-app: asking GitHub every 5 seconds whether the App is installed in acme, for up to 10 minutes' 'the poll is announced'
must 'create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815' 'the installation is named with its page'
must 'create-github-app: GITHUB_APP_INSTALLATION_ID and GITHUB_APP_OWNER (acme) written into config.apps6.env in place' 'the installation id and its owner are written'
must 'create-github-app: config.apps6.env carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY and GITHUB_APP_OWNER, and nobody but the owner can read it. The App: https://github.com/apps/acme-platform-manager. Its installation: https://github.com/organizations/acme/settings/installations/815' 'the four keys are named, never a value'
must_not 'BEGIN' 'no line of the key is printed'
[ "$A_CODE" = '0' ] || fail "the act must end with 0, got $A_CODE"
expect 'the act, both clicks in one run' 0 <<'RECORDED'
create-github-app: the App acme-platform-manager is created in the organisation acme, the owner of DEPLOY_REPO in config.apps6.env, with its homepage https://manager.example.invalid
create-github-app: listening on 127.0.0.1 for GitHub to send the browser back, for up to 10 minutes
create-github-app: opened the manifest page in the browser; it posts to https://github.com/organizations/acme/settings/apps/new. In the browser: click Create GitHub App
create-github-app: GitHub sent the browser back with a code, and the state is this run's
create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711) with the six permissions administration:write contents:write metadata:read packages:read webhooks:write workflows:write
create-github-app: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY written into config.apps6.env in place
create-github-app: opened https://github.com/apps/acme-platform-manager/installations/new in the browser. In the browser: choose All repositories and click Install
create-github-app: asking GitHub every 5 seconds whether the App is installed in acme, for up to 10 minutes
create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815
create-github-app: GITHUB_APP_INSTALLATION_ID and GITHUB_APP_OWNER (acme) written into config.apps6.env in place
create-github-app: config.apps6.env carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY and GITHUB_APP_OWNER, and nobody but the owner can read it. The App: https://github.com/apps/acme-platform-manager. Its installation: https://github.com/organizations/acme/settings/installations/815
~~~ standard error ~~~
RECORDED
page_holds 'the act'
cp "$OUT/a.out" "$GHAPP/act.out"
state="$GHAPP/state-a"
[ "$(cat "$state/log")" = "POST /app-manifests/c0de0fthefixture/conversions
GET /orgs/acme/installation jwt=verified iss=4711" ] || fail "the calls are not the conversion and one installation question with a verified JWT: $(tr '\n' ' ' < "$state/log")"
[ "$(cat "$state/opened")" = "http://127.0.0.1:$(sed -n 's/.*redirect_url":"http:\/\/127.0.0.1:\([0-9]*\)\/.*/\1/p' "$state/page.html")/
https://github.com/apps/acme-platform-manager/installations/new" ] || fail "the browser was not opened on the listener and then on the installation page: $(tr '\n' ' ' < "$state/opened")"
[ "$(config_line GITHUB_APP_ID)" = '4711' ] || fail "the config does not carry the App id"
[ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '815' ] || fail "the config does not carry the installation id"
[ "$(config_line GITHUB_APP_OWNER)" = 'acme' ] || fail "the config does not carry the account the installation belongs to"
[ "$(config_line GITHUB_APP_PRIVATE_KEY)" = "$(cat "$GHAPP/pem.json")" ] || fail "the config does not carry the key as one line with \\n for each line break"
config_line GITHUB_APP_PRIVATE_KEY | perl -pe 's/\\n/\n/g' | openssl rsa -check -noout >/dev/null 2>&1 || fail "the key in the config, its line breaks turned back, is not a key openssl reads"
[ "$(grep -c . "$GHAPP/a/config.apps6.env")" = '7' ] || fail "the config gained or lost a line"
grep -q "^FQDN='apps6.example.invalid'\$" "$GHAPP/a/config.apps6.env" || fail "the rewrite disturbed a line of the config"
[ "$(sed -n '2p' "$GHAPP/a/config.apps6.env" | cut -c1-24)" = "GITHUB_APP_PRIVATE_KEY='" ] || fail "the key was not written on the line the template declares it on"
require_owner_only "$GHAPP/a/config.apps6.env" || fail "the rewrite took the access list off the config: it $REACH"
ok 'the act: the page, the redirect, the conversion, the two writes in place on the lines the template declares, the JWT verified with the key`s public half, the installation read, and the config still owner-only with the real tools'

# ── a second run on what the first wrote refuses ────────────────────────────
run_app_bash config.apps6.env
must 'create-github-app: config.apps6.env already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY and GITHUB_APP_OWNER. Nothing has been changed' 'a second run on a config the first filled is refused'
[ "$A_CODE" = '65' ] || fail "a second run must refuse with 65, got $A_CODE"
expect 'a second run on what the first wrote' 65 <<'RECORDED'
~~~ standard error ~~~
create-github-app: config.apps6.env already carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY and GITHUB_APP_OWNER. Nothing has been changed
RECORDED

# ── an installation on selected repositories refuses, and the next run fills what is missing ─
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" selected
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
create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711) with the six permissions administration:write contents:write metadata:read packages:read webhooks:write workflows:write
create-github-app: GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY written into config.apps6.env in place
create-github-app: opened https://github.com/apps/acme-platform-manager/installations/new in the browser. In the browser: choose All repositories and click Install
create-github-app: asking GitHub every 5 seconds whether the App is installed in acme, for up to 10 minutes
~~~ standard error ~~~
create-github-app: the App is installed in acme with repository_selection selected, and the Manager needs all. Choose All repositories at https://github.com/organizations/acme/settings/installations/815, then run this again: The App stands, and config.apps6.env carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY, and the next run writes GITHUB_APP_INSTALLATION_ID
RECORDED
[ "$(config_line GITHUB_APP_ID)" = '4711' ] || fail "the config does not carry the App id after the refusal"
[ "$(config_line GITHUB_APP_PRIVATE_KEY)" = "$(cat "$GHAPP/pem.json")" ] || fail "the config does not carry the key after the refusal"
[ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '' ] || fail "the config carries an installation id the refusal should not have written"
[ "$(config_line GITHUB_APP_OWNER)" = '' ] || fail "the config carries an owner the refusal should not have written"
# THE NEXT RUN finds the App in the config, asks GitHub for it with the key,
# and installs — polling once through a 404 before the installation appears.
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" absent-then-all
run_app_bash config.apps6.env
must 'create-github-app: config.apps6.env carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY and no GITHUB_APP_INSTALLATION_ID, so the App stands and this run installs it' 'a config carrying the App and no installation skips the creation'
must 'create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711)' 'the App is asked of GitHub with the key and named'
must 'create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815' 'the installation is found'
must 'create-github-app: GITHUB_APP_INSTALLATION_ID and GITHUB_APP_OWNER (acme) written into config.apps6.env in place' 'and its id and owner written'
must_not 'the manifest page' 'no page is served on a run that only installs'
[ "$A_CODE" = '0' ] || fail "the installing run must end with 0, got $A_CODE"
expect 'the run that only installs' 0 <<'RECORDED'
create-github-app: config.apps6.env carries GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY and no GITHUB_APP_INSTALLATION_ID, so the App stands and this run installs it
create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711)
create-github-app: opened https://github.com/apps/acme-platform-manager/installations/new in the browser. In the browser: choose All repositories and click Install
create-github-app: asking GitHub every 5 seconds whether the App is installed in acme, for up to 10 minutes
create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815
create-github-app: GITHUB_APP_INSTALLATION_ID and GITHUB_APP_OWNER (acme) written into config.apps6.env in place
create-github-app: config.apps6.env carries GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY and GITHUB_APP_OWNER, and nobody but the owner can read it. The App: https://github.com/apps/acme-platform-manager. Its installation: https://github.com/organizations/acme/settings/installations/815
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
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" absent-then-all
sed -i.bak "s/^GITHUB_APP_INSTALLATION_ID=.*/GITHUB_APP_INSTALLATION_ID=''/" "$GHAPP/a/config.apps6.env" && rm -f "$GHAPP/a/config.apps6.env.bak"
chmod 600 "$GHAPP/a/config.apps6.env"
A_CODE=0
( cd "$GHAPP/a" && export GITHUB_STUB="$GHAPP/state-a" GITHUB_PUB="$GHAPP/pub.pem" GITHUB_PEM_JSON="$GHAPP/pem.json" REAL_CURL="$REAL_CURL" BROWSER=browser PATH="$GSTUB:$PATH" \
  && bash "$PLANTED_G" config.apps6.env ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
grep -q 'this run will install it' "$OUT/a.out" || fail 'the planted copy printed no installing line — the probe was aimed at a line the fixture does not reach'
caught create-github-app.sh 'this run will install it'

# ── a config that predates the owner has it recorded, and a failed lookup writes nothing ─
blank_owner() { # the config the installing run filled, with its owner taken out again
  sed -i.bak "s/^GITHUB_APP_OWNER=.*/GITHUB_APP_OWNER=''/" "$GHAPP/a/config.apps6.env" && rm -f "$GHAPP/a/config.apps6.env.bak"
  chmod 600 "$GHAPP/a/config.apps6.env"
}
blank_owner
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" absent
run_app_bash config.apps6.env
must 'create-github-app: GitHub does not answer the installation 815 for the App in config.apps6.env (HTTP 404: Not Found). Nothing has been changed' 'an installation GitHub does not know is refused, named, and nothing is written'
[ "$A_CODE" = '69' ] || fail "an unknown installation must refuse with 69, got $A_CODE"
[ "$(config_line GITHUB_APP_OWNER)" = '' ] || fail 'an unknown installation was refused and the owner was still written'
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" all
touch "$GHAPP/state-a/no-account"
run_app_bash config.apps6.env
must "create-github-app: GitHub's answer for the installation 815 carries no account login. Nothing has been changed" 'an installation answered without its account is refused, and nothing is written'
[ "$A_CODE" = '69' ] || fail "an installation without an account must refuse with 69, got $A_CODE"
[ "$(config_line GITHUB_APP_OWNER)" = '' ] || fail 'an installation without an account was refused and the owner was still written'
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" all
run_app_bash config.apps6.env
[ "$A_CODE" = '0' ] || fail "recording the owner must end with 0, got $A_CODE"
expect 'the run that only records the owner' 0 <<'RECORDED'
create-github-app: installation 815 belongs to acme; GITHUB_APP_OWNER written into config.apps6.env in place
~~~ standard error ~~~
RECORDED
[ "$(cat "$GHAPP/state-a/log")" = 'GET /app/installations/815 jwt=verified iss=4711' ] || fail "the calls are not the one installation question with a verified JWT: $(tr '\n' ' ' < "$GHAPP/state-a/log")"
[ ! -f "$GHAPP/state-a/opened" ] || fail 'the run that only records the owner opened a browser'
[ "$(config_line GITHUB_APP_OWNER)" = 'acme' ] || fail "the config does not carry the account the installation belongs to"
[ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '815' ] && [ "$(config_line GITHUB_APP_ID)" = '4711' ] || fail 'recording the owner disturbed the id or the installation'
[ "$(grep -c . "$GHAPP/a/config.apps6.env")" = '7' ] || fail "the config gained or lost a line"
require_owner_only "$GHAPP/a/config.apps6.env" || fail "recording the owner took the access list off the config: it $REACH"
ok 'a config of the three answers records the account the installation belongs to as the owner, with one signed question and no browser; an unknown installation and one without an account are refused with nothing written'

# ── GitHub pretty-prints its answers: every field is read from them as from the compact ones, with the same refusals ─
# The stand-in answers pretty-printed JSON, as GitHub does, once the state directory holds the file `pretty`.
pretty_github() { # after seed_github, which empties the state directory
  touch "$GHAPP/state-a/pretty"
}
pretty_was_served() { # what was being checked -> the last answer of the stand-in stood on lines of its own
  grep -qxF '{' "$GHAPP/state-a/last-body" && grep -qE '^  "[a-z_]+": ' "$GHAPP/state-a/last-body" \
    || fail "$1 — the stand-in did not answer pretty-printed JSON, so the case proves nothing about it"
}
blank_installation() { # the config the act filled, with its installation id and its owner taken out again
  sed -i.bak -e "s/^GITHUB_APP_INSTALLATION_ID=.*/GITHUB_APP_INSTALLATION_ID=''/" -e "s/^GITHUB_APP_OWNER=.*/GITHUB_APP_OWNER=''/" "$GHAPP/a/config.apps6.env" && rm -f "$GHAPP/a/config.apps6.env.bak"
  chmod 600 "$GHAPP/a/config.apps6.env"
}
blank_owner
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" all
pretty_github
run_app_bash config.apps6.env
[ "$A_CODE" = '0' ] || fail "recording the owner from a pretty-printed installation must end with 0, got $A_CODE: $(cat "$OUT/a.err")"
must 'create-github-app: installation 815 belongs to acme; GITHUB_APP_OWNER written into config.apps6.env in place' 'the owner is read off a pretty-printed installation'
[ "$(config_line GITHUB_APP_OWNER)" = 'acme' ] || fail "the config does not carry the account a pretty-printed installation belongs to"
grep -qxF '  "account": {' "$GHAPP/state-a/last-body" || fail 'the installation was not served with its account object on lines of its own, so the case proves nothing about it'
pretty_was_served 'the owner off a pretty-printed installation'
blank_owner
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" absent
pretty_github
run_app_bash config.apps6.env
must 'create-github-app: GitHub does not answer the installation 815 for the App in config.apps6.env (HTTP 404: Not Found). Nothing has been changed' 'the message of a pretty-printed refusal is named'
[ "$A_CODE" = '69' ] || fail "an unknown installation, pretty-printed, must refuse with 69, got $A_CODE"
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" all
touch "$GHAPP/state-a/no-account"
pretty_github
run_app_bash config.apps6.env
must "create-github-app: GitHub's answer for the installation 815 carries no account login. Nothing has been changed" 'a pretty-printed installation without its account is refused'
[ "$A_CODE" = '69' ] || fail "a pretty-printed installation without an account must refuse with 69, got $A_CODE"
[ "$(config_line GITHUB_APP_OWNER)" = '' ] || fail 'a pretty-printed installation without an account was refused and the owner was still written'
pretty_was_served 'a pretty-printed installation without an account'

seed_config "$GHAPP/a"
seed_github "$GHAPP/state-a" "$FIVE_PERMISSIONS" all
pretty_github
run_app_bash config.apps6.env
must 'create-github-app: the App was created at https://github.com/apps/acme-platform-manager with the permissions administration:write contents:write metadata:read webhooks:write workflows:write and not the six asked' 'five permissions, pretty-printed, are refused by both lists'
[ "$A_CODE" = '65' ] || fail "five permissions, pretty-printed, must refuse with 65, got $A_CODE"
nothing_written 'an App answered with five permissions, pretty-printed'
pretty_was_served 'an App answered with five permissions'

seed_config "$GHAPP/a"
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" all
pretty_github
run_app_bash config.apps6.env
[ "$A_CODE" = '0' ] || fail "the act on pretty-printed answers must end with 0, got $A_CODE: $(cat "$OUT/a.err")"
cmp -s "$GHAPP/act.out" "$OUT/a.out" || fail "the act on pretty-printed answers printed other bytes than on compact ones: $(diff "$GHAPP/act.out" "$OUT/a.out")"
[ "$(config_line GITHUB_APP_ID)" = '4711' ] && [ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '815' ] && [ "$(config_line GITHUB_APP_OWNER)" = 'acme' ] \
  || fail 'the config does not carry the id, the installation and the owner read off pretty-printed answers'
[ "$(config_line GITHUB_APP_PRIVATE_KEY)" = "$(cat "$GHAPP/pem.json")" ] || fail 'the config does not carry the key as one line with \n for each line break when GitHub pretty-prints its answer'
pretty_was_served 'the act on pretty-printed answers'

blank_installation
seed_github "$GHAPP/state-a" "$SIX_PERMISSIONS" absent-then-all
pretty_github
run_app_bash config.apps6.env
[ "$A_CODE" = '0' ] || fail "the run that only installs, on pretty-printed answers, must end with 0, got $A_CODE: $(cat "$OUT/a.err")"
must 'create-github-app: the App stands at https://github.com/apps/acme-platform-manager (id 4711)' 'the App is read off a pretty-printed answer'
must 'create-github-app: installed in acme on all repositories, installation 815: https://github.com/organizations/acme/settings/installations/815' 'the installation is read off a pretty-printed answer'
[ "$(config_line GITHUB_APP_INSTALLATION_ID)" = '815' ] && [ "$(config_line GITHUB_APP_OWNER)" = 'acme' ] || fail 'the config does not carry the installation and the owner read off pretty-printed answers'
pretty_was_served 'the run that only installs'
ok 'GitHub pretty-printed: the owner is read off the installation, the message of a refusal, a missing account and five permissions are named as before, and the act, whole or only installing, writes what it writes off compact answers'

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

# plant_tree DIR: DIR/lifecycle holds the launchers and what they source, and DIR/clusters the files read_rclone_pin reads
# from the tree above its folder, so a copy of a launcher runs as the released one does.
plant_tree() {
  mkdir -p "$1/lifecycle" "$1/clusters/platform" "$1/clusters/inventories/consumer-build/files"
  cp "$HERE/master-backup.sh" "$HERE/master-restore.sh" "$HERE/master-backup-driver.sh" "$HERE/master-restore-driver.sh" \
    "$HERE/require-owner-only.sh" "$HERE/require-config-assignments.sh" "$HERE/read-rclone-pin.sh" "$HERE/require-rclone.sh" "$1/lifecycle/"
  cp "$HERE/../clusters/platform/versions.yaml" "$HERE/../clusters/platform/mirror-sources.table" "$HERE/../clusters/platform/values-common.yaml" "$1/clusters/platform/"
  cp "$HERE/../clusters/inventories/consumer-build/files/mirror-sources.sh" "$1/clusters/inventories/consumer-build/files/"
}
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
restore: usage: lifecycle/master-restore.sh <config> [backup-id] [--rclone-package <local .deb>]. Nothing has been changed
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
  plant_tree "$MASTER/planted-guard"
  sed 's/is mode /has mode /' "$HERE/require-owner-only.sh" > "$MASTER/planted-guard/lifecycle/require-owner-only.sh"
  grep -q 'has mode ' "$MASTER/planted-guard/lifecycle/require-owner-only.sh" \
    || fail 'the planted line was not planted in require-owner-only.sh — the probe proves nothing'
  A_CODE=0
  ( cd "$MASTER" && bash "$MASTER/planted-guard/lifecycle/$act.sh" "$MREACH" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
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
  plant_tree "$MASTER/planted-reach"
  PLANTED_M="$MASTER/planted-reach/lifecycle/$act.sh"
  sed 's/could not be reached: /could not be reached — /' "$HERE/$act.sh" > "$PLANTED_M"
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
# Forgejo's SQLite and its repositories share this one claim, and the equal lists above hold a
# store that both drivers lack just as green.
grep -qx 'forgejo|gitea-shared-storage' "$OUT/stores-backup" \
  || fail 'the drivers do not name the claim gitea-shared-storage of the namespace forgejo — Forgejo'"'"'s database and repositories are backed up by nobody'
ok "the drivers name Forgejo's claim gitea-shared-storage"

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

# ── the quorum, checked by the account that owns it ──────────────────────────
# Vault's quorum is the operator's own file at mode 600, and the backup runs as the operator. Its
# check is the backup driver's own function, lifted and run against files this account plants, with
# root a stand-in that fails the run on any call. Where the OS's test is uutils, an elevated
# test -r judges root by the mode bits and answers no for a 0600 file root does not own, which the
# driver then reports as a file that is not on the host.
quorum_check_of() { sed -n '/^require_quorum() {/,/^}/p' "$1"; }
# shellcheck disable=SC2034 # QUORUM is read by the lifted require_quorum
quorum_checked() { # <the check's text> <the quorum's path> — ends with the code the check dies with, 0 when it passes; what it printed stands in $OUT/quorum.err
  ( QUORUM="$2"
    die() { echo "die: $1" >&2; exit "${2:-1}"; }
    root() { echo 'the quorum was read elevated' >&2; exit 99; }
    eval "$1"
    require_quorum ) > /dev/null 2> "$OUT/quorum.err"
}
QUORUM_DIR="$WORK/quorum"
mkdir -p "$QUORUM_DIR"
echo probe > "$QUORUM_DIR/own.txt"; chmod 600 "$QUORUM_DIR/own.txt"
echo probe > "$QUORUM_DIR/closed.txt"; chmod 000 "$QUORUM_DIR/closed.txt"
BACKUP_CHECK="$(quorum_check_of "$HERE/master-backup-driver.sh")"
[ -n "$BACKUP_CHECK" ] || fail 'master-backup-driver.sh carries no require_quorum — nothing below measures its check of the quorum'

Q_CODE=0; quorum_checked "$BACKUP_CHECK" "$QUORUM_DIR/own.txt" || Q_CODE=$?
[ "$Q_CODE" = 0 ] || fail "backup: the runner's own quorum file at mode 600 was refused with $Q_CODE: $(cat "$OUT/quorum.err")"
[ ! -s "$OUT/quorum.err" ] || fail "backup: a quorum file the runner reads printed words: $(cat "$OUT/quorum.err")"
ok "backup: the runner's own quorum file at mode 600 passes, without root and without a word"

Q_CODE=0; quorum_checked "$BACKUP_CHECK" "$QUORUM_DIR/absent.txt" || Q_CODE=$?
[ "$Q_CODE" = 66 ] || fail "backup: no quorum file must end with 66, got $Q_CODE: $(cat "$OUT/quorum.err")"
grep -qF "$QUORUM_DIR/absent.txt is not on this host — a master keeps Vault's quorum there" "$OUT/quorum.err" \
  || fail "backup: no quorum file was not refused as such: $(cat "$OUT/quorum.err")"
ok 'backup: no quorum file ends with 66 and says it is not on this host'

RUNNER="$(id -un 2>/dev/null || true)"
if [ "$(id -u)" = 0 ] || [ -z "$RUNNER" ]; then
  echo 'test: NOT RUN — the quorum file the runner cannot read: uid 0 reads a file of mode 000, and an account without a name cannot be named, so this run plants and names nothing; a run as a named user that is not root checks it'
else
  Q_CODE=0; quorum_checked "$BACKUP_CHECK" "$QUORUM_DIR/closed.txt" || Q_CODE=$?
  [ "$Q_CODE" = 66 ] || fail "backup: a quorum file the runner cannot read must end with 66, got $Q_CODE: $(cat "$OUT/quorum.err")"
  grep -qF "$QUORUM_DIR/closed.txt stands on this host, but $RUNNER, who runs this backup, cannot read it" "$OUT/quorum.err" \
    || fail "backup: a quorum file the runner cannot read was not refused naming $RUNNER: $(cat "$OUT/quorum.err")"
  ok "backup: a quorum file the runner cannot read ends with 66 and names $RUNNER"

  # planted defect: a check that lets any file that stands there through
  PLANTED_OPEN="$(printf '%s\n' "$BACKUP_CHECK" | sed 's/\[ -r "\$QUORUM" \]/true/')"
  [ "$PLANTED_OPEN" != "$BACKUP_CHECK" ] || fail 'the planted open check was not planted — the probe proves nothing'
  Q_CODE=0; quorum_checked "$PLANTED_OPEN" "$QUORUM_DIR/closed.txt" || Q_CODE=$?
  [ "$Q_CODE" = 0 ] || fail "the planted open check was not the defect it is: it ended with $Q_CODE"
  ok 'the planted open check lets the unreadable quorum through, where the real one ends with 66'
fi

# planted defect: the check as it was asked through root
PLANTED_ELEVATED="$(printf '%s\n' "$BACKUP_CHECK" | sed 's/\[ -r "\$QUORUM" \]/root test -r "$QUORUM"/')"
[ "$PLANTED_ELEVATED" != "$BACKUP_CHECK" ] || fail 'the planted elevated check was not planted — the probe proves nothing'
Q_CODE=0; quorum_checked "$PLANTED_ELEVATED" "$QUORUM_DIR/own.txt" || Q_CODE=$?
[ "$Q_CODE" = 99 ] && grep -qF 'the quorum was read elevated' "$OUT/quorum.err" \
  || fail "the planted elevated check was not caught: it ended with $Q_CODE and printed: $(cat "$OUT/quorum.err")"
ok 'the planted elevated check is caught: root is called for a file the runner owns'

# Neither driver asks root for a file's mode.
elevated_reads_in() { grep -vE '^[[:space:]]*#' "$1" | grep -E 'root (test|\[) -[rwx]( |$)'; }
for driver in master-backup-driver.sh master-restore-driver.sh; do
  ! elevated_reads_in "$HERE/$driver" > "$OUT/elevated.out" \
    || fail "$driver asks root for a file's mode: $(cat "$OUT/elevated.out")"
done
for planted_line in 'root test -r "$QUORUM" || die gone 66' 'root test -x "$sealed" || die gone 66' 'root [ -w "$sealed" ] || die gone 66'; do
  { cat "$HERE/master-backup-driver.sh"; echo "$planted_line"; } > "$OUT/planted-elevated.sh"
  elevated_reads_in "$OUT/planted-elevated.sh" > /dev/null \
    || fail "the guard did not catch a driver carrying: $planted_line"
done
{ cat "$HERE/master-restore-driver.sh"
  echo '# root test -r "$sealed" was wrong: root is judged by the mode bits'
  echo 'root test -f "$sealed" || die gone 66'
  echo 'root test -e "$sealed" || die gone 66'
  echo 'root test -d "$sealed" || die gone 66'
  echo 'root cat "$sealed" > /dev/null'; } > "$OUT/innocent-elevated.sh"
! elevated_reads_in "$OUT/innocent-elevated.sh" > "$OUT/elevated.out" \
  || fail "the guard caught a comment and the tests of existence and kind: $(cat "$OUT/elevated.out")"
ok 'neither driver asks root for a file'"'"'s mode; the guard catches each planted form and passes the innocent lines'

# Neither driver pipes or redirects anything into an elevated command: root() replaces its standard input
# with the password line. A heredoc on a descriptor of its own inside a quoted script (3<<EOF) is no
# input of root, and stays. The second bar of || is no pipe.
piped_into_root_in() { grep -vE '^[[:space:]]*#' "$1" | grep -E '(^|[^|])\| *(root|seal)( |$)|(root|seal) .* <<'; }
for driver in master-backup-driver.sh master-restore-driver.sh; do
  ! piped_into_root_in "$HERE/$driver" > "$OUT/piped.out" \
    || fail "$driver pipes or redirects into an elevated command, which reads root()'s password line instead: $(cat "$OUT/piped.out")"
done
for planted_line in 'root tar -cf - . | seal "$out"' 'cat "$QUORUM" | seal "$out"' 'cat "$x" | root tee "$y" > /dev/null' 'root sh -c "cat > $PLACE" <<EOF' 'root sh -c "cat > $PLACE" <<<"$PLACEMENT"'; do
  { cat "$HERE/master-restore-driver.sh"; echo "$planted_line"; } > "$OUT/planted-piped.sh"
  piped_into_root_in "$OUT/planted-piped.sh" > /dev/null \
    || fail "the guard did not catch a driver carrying: $planted_line"
done
{ cat "$HERE/master-backup-driver.sh"
  echo '# root tar -cf - . | seal "$out" lost its data'
  echo 'seal "$out" tar -cf - .'
  echo 'seal "$out" cat "$QUORUM"'
  echo "root env X=1 sh -c 'gpg -d \"\$1\" 3<<EOF | tar -xf -'"
  echo 'root cat "$sealed" | wc -c'
  echo '[ -z "$pid" ] || root kill -TERM "$pid"'; } > "$OUT/innocent-piped.sh"
! piped_into_root_in "$OUT/innocent-piped.sh" > "$OUT/piped.out" \
  || fail "the guard caught a comment, a seal that takes its command, a heredoc on a descriptor of its own, the output of root piped on and an or-list that runs root: $(cat "$OUT/piped.out")"
ok 'neither driver pipes or redirects into an elevated command; the guard catches each planted form and passes the innocent lines'
# The file of mode 000 is removed here: the recursive greps over $WORK further down (no_session) cannot read it.
rm -rf "$QUORUM_DIR"

# ── the data handed to an elevated command arrives, whatever the sudo does with its standard input ─
# root() hands sudo the elevation password on standard input: printf pw | sudo -S -p '' "$@". What a
# caller pipes or redirects into root() is replaced by that line. A sudo that asks for no password, as
# the operator's NOPASSWD rule on a master does, never reads the line, so the command reads it as its
# data; a sudo that asks reads the line, so the command reads nothing. Either way the data is lost.
# That is why a store, the quorum and the placement script reach their elevated command inside the
# one elevated bash that makes or takes them. The cases run each driver's own root(), seal() and
# placement text against a stand-in of each kind of sudo, with gpg, tar and microk8s stand-ins that
# record what they are handed, and hold the password out of every file and every line.
# And no secret is an argument. sudo-rs writes every command it runs, with its arguments, to the system
# log before it runs it, and any local account reads an argument in the process list. So the stand-ins
# write their arguments to argv.log, and the cases hold the passphrase, the storage box password and the
# read token out of every line of it, for the store seal, the quorum seal and the restore's fetch,
# clone, fetch, quorum opening and store openings, and hold the folder of secret files to mode 700 in
# /dev/shm, its files to 600, and the folder gone when the driver ends.
PLANTED_PASSWORD='planted-elevation-password-9c41'
PLANTED_PASSPHRASE='planted-backup-passphrase-5d27'
PLANTED_BOX_PASSWORD='planted-box-password-71e8'
PLANTED_PAT='ghp_planted-read-token-3b6a'
PLANTED_PAT_BASE64="$(printf 'x-access-token:%s' "$PLANTED_PAT" | base64 | tr -d '\n')"
STANDIN="$WORK/standin"
mkdir -p "$STANDIN"
BOX_HOST='box.example.invalid'
BOX_USER='boxuser'
printf '%s\n' "$BOX_HOST" "$BOX_USER" "obscured-of-$PLANTED_BOX_PASSWORD" > "$STANDIN/box.expected"
printf 'AUTHORIZATION: basic %s\n' "$PLANTED_PAT_BASE64" > "$STANDIN/git.expected"
cat > "$STANDIN/sudo" <<'STANDIN_SUDO'
#!/usr/bin/env bash
# sudo as root() calls it: sudo -S -p '' [-u USER] COMMAND... SUDO_STANDIN=nopasswd reads nothing, as a
# NOPASSWD rule does; SUDO_STANDIN=password reads the first line of standard input as the password and
# passes on the rest. The command runs with the environment cleared, as sudo's env_reset does, and with
# STANDIN_ELEVATED=1, the one thing that tells the rclone stand-in a command was raised. Every call
# writes its arguments to argv.log beside it first, as sudo-rs writes them to the system log.
printf 'sudo %s\n' "$*" >> "$(dirname "$0")/argv.log"
[ "$#" -ge 4 ] && [ "$1" = -S ] && [ "$2" = -p ] && [ -z "$3" ] || { echo 'sudo stand-in: not called as root() calls it' >&2; exit 2; }
shift 3
[ "$1" != -u ] || shift 2
if [ "$SUDO_STANDIN" = password ]; then
  IFS= read -r given
  [ "$given" = "$SUDO_STANDIN_PASSWORD" ] || { echo 'sudo stand-in: a wrong password' >&2; exit 1; }
fi
exec env -i PATH="$PATH" STANDIN_ELEVATED=1 "$@"
STANDIN_SUDO
cat > "$STANDIN/gpg" <<'STANDIN_GPG'
#!/usr/bin/env bash
# gpg as the drivers call it. The passphrase comes from descriptor 3 (--passphrase-fd 3) or from the first
# line of a file (--passphrase-file FILE), whose folder and mode it records in secrets.seen beside it.
# Sealing (--symmetric, the data on standard input): the "sealed" file is the passphrase line, then the
# data, so a case reads both back. Opening (-d FILE): ends 2 unless the file was sealed with the
# passphrase it is given; writes the data to -o, or to standard output.
printf 'gpg %s\n' "$*" >> "$(dirname "$0")/argv.log"
out=''; fd=''; file=''; open=''; src=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --batch|--yes|--quiet|--symmetric) shift ;;
    --pinentry-mode) [ "$2" = loopback ] || exit 2; shift 2 ;;
    --cipher-algo) [ "$2" = AES256 ] || exit 2; shift 2 ;;
    --passphrase-fd) fd="$2"; shift 2 ;;
    --passphrase-file) file="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -d) open=1; src="$2"; shift 2 ;;
    *) echo "gpg stand-in: an argument the drivers do not pass: $1" >&2; exit 2 ;;
  esac
done
pass=''
if [ -n "$file" ] && [ -z "$fd" ]; then
  printf '%s %s %s\n' "$(stat -c %a "$(dirname "$file")")" "$(stat -c %a "$file")" "$(dirname "$file")" >> "$(dirname "$0")/secrets.seen"
  IFS= read -r pass < "$file" || [ -n "$pass" ] || exit 2
elif [ "$fd" = 3 ] && [ -z "$file" ]; then
  IFS= read -r pass <&3 || exit 2
else
  exit 2
fi
if [ -n "$open" ]; then
  IFS= read -r first < "$src"
  [ "$first" = "sealed with: $pass" ] || { echo 'gpg: decryption failed: Bad session key' >&2; exit 2; }
  if [ -n "$out" ]; then tail -n +2 "$src" > "$out"; else tail -n +2 "$src"; fi
else
  [ -n "$out" ] || exit 2
  { printf 'sealed with: %s\n' "$pass"; cat; } > "$out"
fi
STANDIN_GPG
cat > "$STANDIN/tar" <<'STANDIN_TAR'
#!/usr/bin/env bash
# tar as the drivers call it: tar --numeric-owner -C DIR -cf - . writes DIR/payload to standard output, and
# ends 70 half way where DIR/fails stands; tar --numeric-owner -C DIR -xf - writes standard input to DIR/payload.
printf 'tar %s\n' "$*" >> "$(dirname "$0")/argv.log"
dir=''; stream=''; extract=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --numeric-owner|.) shift ;;
    -C) dir="$2"; shift 2 ;;
    -cf) stream="$2"; shift 2 ;;
    -xf) stream="$2"; extract=1; shift 2 ;;
    *) echo "tar stand-in: an argument the drivers do not pass: $1" >&2; exit 2 ;;
  esac
done
[ "$stream" = - ] && [ -n "$dir" ] || exit 2
if [ -n "$extract" ]; then cat > "$dir/payload"; exit 0; fi
if [ -e "$dir/fails" ]; then head -c 1000 "$dir/payload"; exit 70; fi
cat "$dir/payload"
STANDIN_TAR
cat > "$STANDIN/microk8s" <<'STANDIN_MICROK8S'
#!/usr/bin/env bash
# microk8s kubectl as the drivers call it. apply -f - (the placement script) appends what it is handed to
# kubectl.log. Every other call is appended as it was made to kubectl-calls.log, and answers from the state of a
# cluster that stands in cluster/ beside it: the replicas and the ready count of each workload (one replica, all
# ready, until a scale says otherwise), the suspend of the CronJob release-queue, and the Jobs and pipeline runs
# of the release queue. A scale sets the ready count to the new replicas, and a patch of the CronJob sets its
# suspend; each writes the world it was made in (the Manager's replicas, the queue's suspend, whether the planted run
# and the planted Job still work, the stores that were stopped and are not back and ready) to world.log first, and
# the value it sets under the key to=, which is the new replicas of a scale and the new suspend of a patch.
# A call it does not know ends 2, and a rollout status of vault/vault is refused as kubectl refuses it for a
# StatefulSet that is not a RollingUpdate. The knobs are the files knob-* of cluster/: run-running (a release
# run that reads running for the driver's first two looks at the release runs, then True), run-forever (one that
# never ends), late-job (a Job of the queue that is not listed at the first look at the Jobs, is unfinished at the
# second and third, finished from the fourth, and that .status.active names at its third and fourth look),
# no-cronjob, no-claims (a get of a claim ends 1, as on a machine that stands bare), not-ready (workload names, one a line, that do not read ready after a scale up), scale-fails
# (workload names whose scale up ends 1), stop-fails (workload names whose scale to 0 ends 1 and changes nothing)
# and stop-lost (workload names whose scale to 0 takes effect and ends 1, as an answer lost on the way back does). The first scale call, while block-first-scale stands beside it, claims
# the folder blocked and then waits until the file release stands (or 60 seconds pass), which is how a case holds
# one driver inside its store loop. It lets go of descriptor 9, the backup's lock: a real kubectl call ends in
# seconds, and this one waits on purpose, so it must not stand in for the holder of the lock when the case kills
# the driver that started it.
exec 9>&-
here="$(dirname "$0")"
state="$here/cluster"
[ "$1" = kubectl ] || { echo 'microk8s stand-in: not called as microk8s kubectl' >&2; exit 2; }
shift
if [ "$*" = 'apply -f -' ]; then cat >> "$here/kubectl.log"; exit 0; fi
printf 'kubectl %s\n' "$*" >> "$here/kubectl-calls.log"
mkdir -p "$state"
namespace=''
if [ "$1" = -n ]; then namespace="$2"; shift 2; fi
value_of() { if [ -f "$state/$1" ]; then cat "$state/$1"; else echo "$2"; fi; } # a file of cluster/, or its default
knob() { [ -e "$state/knob-$1" ]; }
listed() { [ -f "$state/knob-$1" ] && grep -qxF "$2" "$state/knob-$1"; }
look() { local n; n=$(( $(value_of "looks-$1" 0) + 1 )); echo "$n" > "$state/looks-$1"; echo "$n"; } # counts a look and answers its number
world() {
  local run=none job=none others='' file name replicas ready
  if knob run-running; then if [ "$(value_of looks-runs 0)" -lt 3 ]; then run=running; else run=ended; fi; fi
  if knob run-forever; then run=running; fi
  if knob late-job; then if [ "$(value_of looks-jobs 0)" -lt 4 ]; then job=unfinished; else job=ended; fi; fi
  for file in "$state"/*.replicas; do
    [ -e "$file" ] || continue
    name="$(basename "$file" .replicas)"
    case "$name" in manager--*) continue ;; esac
    replicas="$(cat "$file")"; ready="$(value_of "$name.ready" "$replicas")"
    if [ "$replicas" -lt 1 ] || [ "$ready" -lt 1 ]; then others="$others${others:+,}$name"; fi
  done
  printf 'manager=%s suspend=%s run=%s job=%s others=%s' "$(value_of manager--manager.replicas 1)" "$(value_of suspend false)" "$run" "$job" "${others:-none}"
}
jsonpath=''; label=''; patch=''; args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) jsonpath="${2#jsonpath=}"; shift 2 ;;
    -l) label="$2"; shift 2 ;;
    -p) patch="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
case "$1" in
  get)
    case "$2" in
      nodes|pods) exit 0 ;;
      pvc)
        if knob no-claims; then echo 'Error from server (NotFound): persistentvolumeclaims "data-vault-0" not found' >&2; exit 1; fi
        echo 1; exit 0 ;;
      cronjob/release-queue)
        if knob no-cronjob; then echo 'Error from server (NotFound): cronjobs.batch "release-queue" not found' >&2; exit 1; fi
        case "$jsonpath" in
          *spec.suspend*) value_of suspend false ;;
          *status.active*)
            looks="$(look active)"
            if knob late-job && { [ "$looks" = 3 ] || [ "$looks" = 4 ]; }; then echo release-queue-late; fi ;;
          *) echo "microk8s stand-in: a read of the CronJob the backup does not make: $jsonpath" >&2; exit 2 ;;
        esac
        exit 0 ;;
      jobs)
        looks="$(look jobs)"
        echo 'release-queue-29874554|CronJob/release-queue |SuccessCriteriaMet Complete '
        echo 'unrelated-job|CronJob/unrelated |'
        if knob late-job; then
          if [ "$looks" -ge 4 ]; then echo 'release-queue-late|CronJob/release-queue |Complete '
          elif [ "$looks" -ge 2 ]; then echo 'release-queue-late|CronJob/release-queue |'; fi
        fi
        exit 0 ;;
      pipelineruns)
        case "$label" in
          image-builder.io/consumer)
            looks="$(look runs)"
            echo 'hostyour-manager-build/hostyour-manager-release-done||True'
            if knob run-running; then
              if [ "$looks" -ge 3 ]; then echo 'hostyour-manager-build/hostyour-manager-release-live||True'
              else echo 'hostyour-manager-build/hostyour-manager-release-live||Unknown'; fi
            fi
            if knob run-forever; then echo 'hostyour-manager-build/hostyour-manager-release-stuck||Unknown'; fi ;;
          image-builder.io/publish)
            echo 'hostyour-manager-build/hostyour-manager-publish-waiting|PipelineRunPending|'
            echo 'hostyour-manager-build/hostyour-manager-publish-done||True' ;;
          *) echo "microk8s stand-in: pipeline runs by a label the backup does not read: $label" >&2; exit 2 ;;
        esac
        exit 0 ;;
      */*)
        workload="${2#*/}"
        case "$jsonpath" in
          *spec.replicas*) value_of "$namespace--$workload.replicas" 1 ;;
          *status.readyReplicas*)
            ready="$(value_of "$namespace--$workload.ready" "$(value_of "$namespace--$workload.replicas" 1)")"
            [ "$ready" = 0 ] || echo "$ready" ;;
          *) echo "microk8s stand-in: a read of a workload the backup does not make: $jsonpath" >&2; exit 2 ;;
        esac
        exit 0 ;;
      *) echo "microk8s stand-in: a get the backup does not make: $2" >&2; exit 2 ;;
    esac ;;
  rollout)
    if [ "$namespace/${3#*/}" = vault/vault ]; then echo 'error: rollout status is only available for RollingUpdate strategy type' >&2; exit 1; fi
    exit 0 ;;
  scale)
    workload="${2#*/}"; wanted="${3#--replicas=}"
    if [ "$wanted" -gt 0 ] && listed scale-fails "$namespace/$workload"; then echo 'microk8s stand-in: the server did not answer' >&2; exit 1; fi
    if [ "$wanted" = 0 ] && listed stop-fails "$namespace/$workload"; then echo 'microk8s stand-in: the server did not answer' >&2; exit 1; fi
    if [ -e "$here/block-first-scale" ] && mkdir "$here/blocked" 2> /dev/null; then
      for _ in $(seq 1 600); do [ -e "$here/release" ] && break; sleep 0.1; done
    fi
    printf 'scale target=%s/%s to=%s %s\n' "$namespace" "$workload" "$wanted" "$(world)" >> "$state/world.log"
    echo "$wanted" > "$state/$namespace--$workload.replicas"
    if [ "$wanted" -gt 0 ] && listed not-ready "$namespace/$workload"; then echo 0 > "$state/$namespace--$workload.ready"; else echo "$wanted" > "$state/$namespace--$workload.ready"; fi
    if [ "$wanted" = 0 ] && listed stop-lost "$namespace/$workload"; then echo 'microk8s stand-in: the answer was lost' >&2; exit 1; fi
    exit 0 ;;
  patch)
    [ "$namespace" = image-builder ] && [ "$2" = cronjob/release-queue ] || { echo "microk8s stand-in: a patch the backup does not make: $namespace $2" >&2; exit 2; }
    case "$patch" in
      '{"spec":{"suspend":true}}') suspend=true ;;
      '{"spec":{"suspend":false}}') suspend=false ;;
      *) echo "microk8s stand-in: a patch of the CronJob the backup does not make: $patch" >&2; exit 2 ;;
    esac
    printf 'patch to=%s %s\n' "$suspend" "$(world)" >> "$state/world.log"
    echo "$suspend" > "$state/suspend"
    echo 'cronjob.batch/release-queue patched'
    exit 0 ;;
  *) echo "microk8s stand-in: a kubectl call the backup does not make: $1" >&2; exit 2 ;;
esac
STANDIN_MICROK8S
cat > "$STANDIN/rclone" <<'STANDIN_RCLONE'
#!/usr/bin/env bash
# rclone as the drivers call it. obscure takes the password on standard input (obscure -) or as an argument
# and answers obscured-of-<it>. Every other call needs the remote box defined, as rclone reads it: by the
# file --config or RCLONE_CONFIG names, or by RCLONE_CONFIG_BOX_* variables, with the host, the user and
# the obscured password box.expected holds; it ends 1 otherwise. The folder and the mode of a config file it
# reads go to secrets.seen, as the gpg stand-in's passphrase file does. copy from the box puts what a copy to
# that remote path left in box-uploaded/ into its destination, or box-backup/ where nothing was copied there;
# copy to the box puts its source into box-uploaded/ under the remote path, runs the file after-upload beside it on
# what it put there if that file is executable, as a box that holds other bytes than were sent would, and ends
# 1 on a source that rootonly names unless sudo raised the caller, as a folder of root's at mode 700 is
# refused to any other account. lsf of a remote path that was copied to lists what it holds.
# Every call that loads the config saves into it what rclone 1.60.1's sftp backend detects (shell_type, and
# while the hash check is on md5sum_command and sha1sum_command) by renaming a file the caller wrote over it.
# So a call that sudo raised leaves the config root's, at its old mode 600: rootonly names it, and any later
# call that sudo did not raise ends 1 on it, as rclone does on a config it cannot load.
# The storage box refuses the md5sum command rclone sends it over its shell (read on the dev machine on
# 2026-10-20: every file failed three times with the words below). So a copy from the box ends 1 with those
# words unless the config it loaded names disable_hashcheck = true, or RCLONE_CONFIG_BOX_DISABLE_HASHCHECK=true
# stands in its environment; a copy to the box is not refused, as the carry of 2026-10-19 was not.
# The first copy to the box, while block-first-upload stands beside it, claims the folder blocked and then
# waits until the file release stands (or 60 seconds pass), which is how a case holds one driver in its
# upload. Like the microk8s stand-in it lets go of descriptor 9, the backup's lock, so that the driver
# alone holds the lock while it waits.
# Every refusal goes to standard error and to rclone-errors.log, which is where a case reads what refused a call: the drivers
# print nothing of rclone's own words, except the wording of its message templates in the diagnosis of the read-back. Where the file box-fails names a call (lsd, lsf, upload or download), that call ends 1
# with the words rclone gives a box that refuses it, the host and the user of the box among them. size answers the bytes
# of the files under a path, as rclone size --json does. A copy to a path that is not on the box is a local copy. With
# --use-json-log, a copy prints the statistics line rclone 1.60.1 prints (the key order of its output) when it ends.
# Where the file readback-plan stands, a copy from the box prints a statistics line after each tick, one tick for each
# --stats interval. The clock is the machine's: the line says the real time since the copy started and the bytes the plan
# has moved by then, so the rate a driver measures is the plan's however long a tick takes. A line of the plan is
# "rate BYTES_A_SECOND MILLISECONDS|forever" (the segments in order, counted from the start of the copy), "garbage"
# (statistics that no number can be read from), "ignore-term" (a copy that ignores TERM), "exit CODE" (the copy ends
# with that code and an error once its segments are used up; without it, the rest is moved at once), "every SECONDS"
# (a tick after that long, whatever --stats says) or "slow SECONDS" (every tick takes that long more, as on a machine
# under load). The last line it printed is kept in readback-emitted, and its pid in transfer.pid.
# Once the plan has moved every byte, the copy has written every file whole and reports the same count. "hold SECONDS|forever"
# keeps it running that long, a statistics line after each tick, and then it ends 0, or with the code "finish CODE" gives and
# an error. While it holds, "over N" reports N bytes more than the box holds, "over grow" one more at each tick, "reset" a
# count of zero, "silent" no line at all, "flip" one byte of an archive changed to another at the same size, "field NAME VALUE" sets a counter of the statistics from the start and
# "held-field NAME VALUE" from the hold on, "active transferring|checking NAME" names a file the statistics list as in
# progress from the start and "held-active" from the hold on (@archive is the first archive of the backup, @manifest its
# manifest). "log start|before|after|end RECORD" prints that line as it
# stands: at the start, just before the first statistics line that holds every byte, right after it, or when the copy ends.
# readback-timeline holds the nanosecond clock of the start, of the first statistics line that held every byte
# ("complete") and of a natural end ("exit"): a killed copy leaves no "exit". readback-stats-path holds the file its standard
# error was, which is where the driver keeps the log of the copy. A record that starts with STDOUT: is written to standard output.
exec 9>&-
here="$(dirname "$0")"
printf 'rclone %s\n' "$*" >> "$here/argv.log"
# --version answers what rclone-answer holds, and what rclone-answer-root holds where sudo raised the caller, as the executable of each account would.
if [ "${1:-}" = --version ]; then
  if [ -n "${STANDIN_ELEVATED:-}" ] && [ -f "$here/rclone-answer-root" ]; then cat "$here/rclone-answer-root"; else cat "$here/rclone-answer"; fi
  exit 0
fi
err() { echo "rclone stand-in: $*" >&2; echo "$*" >> "$here/rclone-errors.log"; }
conf="${RCLONE_CONFIG:-}"
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) conf="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
json_log=''; stats_every=5; previous=''
for argument in "$@"; do
  [ "$previous" != --stats ] || stats_every="${argument%s}"
  [ "$argument" != --use-json-log ] || json_log=1
  previous="$argument"
done
if [ "$1" = obscure ]; then
  if [ "$2" = - ]; then IFS= read -r given; else given="$2"; fi
  printf 'obscured-of-%s\n' "$given"
  exit 0
fi
{ IFS= read -r host; IFS= read -r user; IFS= read -r pass; } < "$here/box.expected"
hashcheck_off=''
if [ -n "$conf" ] && [ -f "$conf" ]; then
  if grep -qxF "$conf" "$here/rootonly" 2> /dev/null && [ -z "${STANDIN_ELEVATED:-}" ]; then
    err "Failed to load config file \"$conf\": permission denied"; exit 1
  fi
  [ "$(grep -vE '^(shell_type|md5sum_command|sha1sum_command) = ' "$conf" | grep -vxF 'disable_hashcheck = true' | sed -E 's/^([a-z]+) *= */\1=/')" = "$(printf '[box]\ntype=sftp\nhost=%s\nuser=%s\npass=%s' "$host" "$user" "$pass")" ] \
    || { err 'the config does not define the remote box'; exit 1; }
  printf '%s %s %s\n' "$(stat -c %a "$(dirname "$conf")")" "$(stat -c %a "$conf")" "$(dirname "$conf")" >> "$here/secrets.seen"
  saved_keys=('shell_type = unix')
  if grep -qxF 'disable_hashcheck = true' "$conf"; then hashcheck_off=1; else saved_keys+=('md5sum_command = md5sum' 'sha1sum_command = sha1sum'); fi
  for saved in "${saved_keys[@]}"; do
    grep -qxF "$saved" "$conf" || printf '%s\n' "$saved" >> "$conf"
  done
  [ -z "${STANDIN_ELEVATED:-}" ] || printf '%s\n' "$conf" >> "$here/rootonly"
elif [ "${RCLONE_CONFIG_BOX_TYPE:-}" = sftp ] && [ "${RCLONE_CONFIG_BOX_HOST:-}" = "$host" ] && [ "${RCLONE_CONFIG_BOX_USER:-}" = "$user" ] && [ "${RCLONE_CONFIG_BOX_PASS:-}" = "$pass" ]; then
  [ "${RCLONE_CONFIG_BOX_DISABLE_HASHCHECK:-}" != true ] || hashcheck_off=1
else
  err 'the remote box is not defined'; exit 1
fi
box_fails() { [ -f "$here/box-fails" ] && grep -qxF "$1" "$here/box-fails"; }
box_refuses() {
  err "Failed to create file system for \"box:\": sftp: dial tcp $host:22: ssh: handshake failed for user $user: unable to authenticate"; exit 1
}
timeline() { echo "$1 $(date +%s%N)" >> "$here/readback-timeline"; } # the real time of an event of the copy, in nanoseconds
emit_logs() { local line; for line; do case "$line" in STDOUT:*) printf '%s\n' "${line#STDOUT:}" ;; *) printf '%s\n' "$line" >&2 ;; esac; done; } # the records the plan gives, on standard error as rclone writes its log, or on standard output where the record starts with STDOUT:
json_names() { local item out='' sep=''; for item; do out="$out$sep\"$item\""; sep=,; done; printf '[%s]' "$out"; }
json_transfers() { local item out='' sep=''; for item; do out="$out$sep{\"bytes\":0,\"eta\":null,\"name\":\"$item\",\"percentage\":50,\"size\":2,\"speed\":0,\"speedAvg\":0}"; sep=,; done; printf '[%s]' "$out"; }
f_checks=0 f_deletedDirs=0 f_deletes=0 f_errors=0 f_fatalError=false f_retryError=false f_totalChecks=0 f_totalTransfers=1 f_transfers=0
act_checking=() act_transferring=()
stats_line() { # BYTES TOTAL MILLISECONDS — the statistics record of rclone 1.60.1 (the key order of its output) with the fields and the active files the plan gives
  local pairs='' key value
  for key in bytes checking checks deletedDirs deletes elapsedTime errors eta fatalError lastError renames retryError speed totalBytes totalChecks totalTransfers transferTime transferring transfers; do
    value=''
    case "$key" in
      bytes) value="$1" ;;
      checking) [ "${#act_checking[@]}" -eq 0 ] || value="$(json_names "${act_checking[@]}")" ;;
      elapsedTime) value="$(( $3 / 1000 )).$(printf '%03d' $(( $3 % 1000 )))" ;;
      eta) value=null ;;
      lastError) [ "$f_errors" = 0 ] || value="\"sftp: dial tcp $host:22: connection to $user lost\"" ;;
      renames|speed|transferTime) value=0 ;;
      totalBytes) value="$2" ;;
      transferring) [ "${#act_transferring[@]}" -eq 0 ] || value="$(json_transfers "${act_transferring[@]}")" ;;
      *) eval "value=\${f_$key}" ;;
    esac
    if [ -n "$value" ] && [ "$value" != - ]; then pairs="$pairs${pairs:+,}\"$key\":$value"; fi
  done
  printf '{"level":"warning","msg":"\\nTransferred: %s bytes\\n%s","source":"accounting/stats.go:482","stats":{%s},"time":"2026-10-21T00:00:00+00:00"}\n' "$1" "$([ "$f_errors" = 0 ] || printf 'Errors: %s, last at %s as %s\\n' "$f_errors" "$host" "$user")" "$pairs" >&2
  echo "$1 $3" > "$here/readback-emitted"
}
bytes_under() { find "$1" -type f -exec cat {} + | wc -c | tr -d ' '; }
progressive() { # FROM TO — the copy of the plan: each tick has moved what the plan gives for the real time since the copy started
  local from="$1" to="$2" kind a b rates=() spans=() code='' garbage='' slow='' every="$stats_every" file total=0 sent=0 tick=0 started elapsed due at span len n take index=0 offset=0 files=() sizes=() segment used_up
  local hold='' finish=0 over='' reset='' silent='' flip='' completed='' first_complete='' held_since beat shown pair bit
  named() { case "$1" in @archive) ls "$from" | grep -vx manifest.txt | head -n 1 ;; @manifest) echo manifest.txt ;; *) echo "$1" ;; esac; } # the first archive of the backup, its manifest, or the name as it stands
  local log_start=() log_before=() log_after=() log_end=() held=() held_transferring=() held_checking=() held_set_transferring='' held_set_checking=''
  while read -r kind a b; do
    case "$kind" in
      rate) rates+=("$a"); spans+=("$b") ;;
      garbage) garbage=1 ;;
      ignore-term) trap '' TERM ;;
      exit) code="$a" ;;
      slow) slow="$a" ;;
      every) every="$a" ;;
      hold) hold="$a" ;;
      finish) finish="$a" ;;
      over) over="$a" ;;
      reset) reset=1 ;;
      silent) silent=1 ;;
      flip) flip=1 ;;
      field) case "$a" in checks|deletedDirs|deletes|errors|fatalError|retryError|totalChecks|totalTransfers|transfers) printf -v "f_$a" '%s' "$b" ;; *) echo "rclone stand-in: the plan sets no field $a" >&2; exit 2 ;; esac ;;
      held-field) held+=("$a=$b") ;;
      active) case "$a" in transferring) act_transferring+=("$(named "$b")") ;; checking) act_checking+=("$(named "$b")") ;; esac ;;
      held-active) case "$a" in transferring) held_transferring+=("$(named "$b")"); held_set_transferring=1 ;; checking) held_checking+=("$(named "$b")"); held_set_checking=1 ;; esac ;;
      log) case "$a" in start) log_start+=("$b") ;; before) log_before+=("$b") ;; after) log_after+=("$b") ;; end) log_end+=("$b") ;; esac ;;
    esac
  done < "$here/readback-plan"
  echo $$ > "$here/transfer.pid"
  readlink "/proc/$$/fd/2" > "$here/readback-stats-path"
  while IFS= read -r file; do
    files+=("$file"); sizes+=("$(wc -c < "$from/$file" | tr -d ' ')"); total=$(( total + ${sizes[${#sizes[@]} - 1]} ))
    : > "$to/$file"
  done < <(cd "$from" && find . -type f | sort)
  started=$(date +%s%N)
  timeline start
  emit_logs "${log_start[@]}"
  while :; do
    sleep "$every"
    [ -z "$slow" ] || sleep "$slow"
    tick=$(( tick + 1 )); elapsed=$(( ($(date +%s%N) - started) / 1000000 ))
    [ "$tick" -le 3000 ] || exit 1
    if [ -n "$garbage" ]; then
      echo "not json: user $user at $host" >&2
      echo "{\"level\":\"error\",\"msg\":\"dial tcp $host:22 as $user\",\"stats\":{\"bytes\":-5,\"elapsedTime\":1.5,\"totalBytes\":9}}" >&2
      echo "{\"stats\":{\"bytes\":99999999999999999999999,\"elapsedTime\":1.5,\"totalBytes\":9}} $host" >&2
      echo "{\"stats\":{\"bytes\":7,\"elapsedTime\":\"$user\",\"totalBytes\":9}}" >&2
      continue
    fi
    due=0 at=0 used_up=1
    for segment in "${!rates[@]}"; do
      span="${spans[$segment]}"; [ "$span" != forever ] || span=999999999999
      len=$(( elapsed - at )); [ "$len" -le "$span" ] || len="$span"; [ "$len" -ge 0 ] || len=0
      due=$(( due + rates[segment] * len / 1000 )); at=$(( at + span ))
      [ "$elapsed" -ge "$at" ] || used_up=''
    done
    if [ -n "$used_up" ] && [ -z "$code" ]; then due="$total"; fi
    [ "$due" -le "$total" ] || due="$total"
    n=$(( due - sent )); sent="$due"
    while [ "$n" -gt 0 ]; do
      if [ "$offset" -ge "${sizes[$index]}" ]; then index=$(( index + 1 )); offset=0; continue; fi
      take=$(( ${sizes[$index]} - offset )); [ "$take" -le "$n" ] || take="$n"
      tail -c +$(( offset + 1 )) "$from/${files[$index]}" | head -c "$take" >> "$to/${files[$index]}"
      offset=$(( offset + take )); n=$(( n - take ))
    done
    first_complete=''
    if [ "$sent" -ge "$total" ] && [ -z "$completed" ]; then
      completed=1 first_complete=1
      if [ -n "$flip" ]; then
        for file in "${files[@]}"; do
          [ "$file" != ./manifest.txt ] || continue
          bit=$(head -c 1 "$to/$file" | od -An -tu1 | tr -d ' ')
          printf "\\$(printf '%03o' $(( (bit + 1) % 256 )))" | dd of="$to/$file" bs=1 count=1 conv=notrunc 2> /dev/null
          break
        done
      fi
      emit_logs "${log_before[@]}"
    fi
    stats_line "$sent" "$total" "$elapsed"
    if [ -n "$first_complete" ]; then
      timeline complete
      emit_logs "${log_after[@]}"
      if [ -n "$hold" ]; then
        for pair in "${held[@]}"; do printf -v "f_${pair%%=*}" '%s' "${pair#*=}"; done
        [ -z "$held_set_transferring" ] || act_transferring=("${held_transferring[@]}")
        [ -z "$held_set_checking" ] || act_checking=("${held_checking[@]}")
        held_since=$(date +%s%N); beat=0
        while [ "$hold" = forever ] || [ $(( ($(date +%s%N) - held_since) / 1000000 )) -lt $(( hold * 1000 )) ]; do
          sleep "$every"
          [ -z "$slow" ] || sleep "$slow"
          tick=$(( tick + 1 )); beat=$(( beat + 1 ))
          [ "$tick" -le 3000 ] || exit 1
          [ -z "$silent" ] || continue
          shown="$total"
          case "$over" in grow) shown=$(( total + beat )) ;; '') ;; *) shown=$(( total + over )) ;; esac
          [ -z "$reset" ] || shown=0
          stats_line "$shown" "$total" $(( ($(date +%s%N) - started) / 1000000 ))
        done
        emit_logs "${log_end[@]}"
        timeline exit
        if [ "$finish" != 0 ]; then err "Failed to copy: sftp: dial tcp $host:22: connection to $user lost"; exit "$finish"; fi
        exit 0
      fi
    fi
    if [ -n "$used_up" ] && [ -n "$code" ]; then err "Failed to copy: sftp: dial tcp $host:22: connection to $user lost"; exit "$code"; fi
    [ "$sent" -lt "$total" ] || { emit_logs "${log_end[@]}"; timeline exit; exit 0; }
  done
}
case "$1" in
  lsd) if box_fails lsd; then box_refuses; fi; exit 0 ;;
  lsf) if box_fails lsf; then box_refuses; fi; if [ -d "$here/box-uploaded/${2#box:}" ]; then ls "$here/box-uploaded/${2#box:}"; fi; exit 0 ;;
  size) printf '{"count":%d,"bytes":%d,"sizeless":0}\n' "$(find "$2" -type f | wc -l | tr -d ' ')" "$(bytes_under "$2")"; exit 0 ;;
  copy)
    case "$2" in
      box:*)
        if box_fails download; then box_refuses; fi
        from="$here/box-uploaded/${2#box:}"; [ -d "$from" ] || from="$here/box-backup"
        if [ -z "$hashcheck_off" ]; then
          first="$(ls "$from" | head -n 1)"
          err "Failed to calculate src hash: failed to calculate md5 hash: failed to run \"md5sum ${2#box:}$first\""
          err "corrupted on transfer: md5 hashes differ src \"\" vs dst \"$(md5sum < "$from/$first" | cut -d' ' -f1)\""
          exit 1
        fi
        if [ -e "$here/readback-plan" ]; then progressive "$from" "$3"; exit $?; fi
        cp -R "$from/." "$3"
        if [ -n "$json_log" ]; then stats_line "$(bytes_under "$from")" "$(bytes_under "$from")" 12; fi ;;
      *)
        case "$3" in
          box:*)
            if box_fails upload; then box_refuses; fi
            if [ -e "$here/block-first-upload" ] && mkdir "$here/blocked" 2> /dev/null; then
              for _ in $(seq 1 600); do [ -e "$here/release" ] && break; sleep 0.1; done
            fi
            if grep -qxF "$2" "$here/rootonly" 2> /dev/null && [ -z "${STANDIN_ELEVATED:-}" ]; then
              err "open $2: permission denied"; exit 1
            fi
            mkdir -p "$here/box-uploaded/${3#box:}" && cp -R "$2/." "$here/box-uploaded/${3#box:}" || exit 1
            if [ -x "$here/after-upload" ]; then "$here/after-upload" "$here/box-uploaded/${3#box:}" || exit 1; fi ;;
          *)
            cp -R "$2/." "$3"
            if [ -n "$json_log" ]; then stats_line "$(bytes_under "$2")" "$(bytes_under "$2")" 12; fi ;;
        esac ;;
    esac ;;
  *) echo "rclone stand-in: a call the drivers do not make: $1" >&2; exit 2 ;;
esac
STANDIN_RCLONE
cat > "$STANDIN/git" <<'STANDIN_GIT'
#!/usr/bin/env bash
# git as the restore calls it: git [-C DIR] [-c KEY=VALUE] clone|fetch|rev-parse ... clone and fetch need the
# header git.expected holds for https://github.com/, read the way git reads it: from -c, and from the file
# GIT_CONFIG_GLOBAL names. Without it they end 128. clone makes its destination's .git; rev-parse answers a hash.
here="$(dirname "$0")"
printf 'git %s\n' "$*" >> "$here/argv.log"
real="$(PATH="${PATH#"$here:"}" command -v git)"
globals=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) shift 2 ;;
    -c) globals+=(-c "$2"); shift 2 ;;
    *) break ;;
  esac
done
cmd="$1"; shift
case "$cmd" in
  rev-parse) echo abc1234; exit 0 ;;
  clone|fetch) ;;
  *) echo "git stand-in: a command the restore does not run: $cmd" >&2; exit 2 ;;
esac
header="$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-/dev/null}" "$real" "${globals[@]}" config --get-urlmatch http.extraheader https://github.com/ 2>/dev/null)"
[ "$header" = "$(cat "$here/git.expected")" ] || { echo 'fatal: could not read Username for https://github.com: terminal prompts disabled' >&2; exit 128; }
if [ "$cmd" = clone ]; then for last; do :; done; mkdir -p "$last/.git"; fi
STANDIN_GIT
cat > "$STANDIN/install" <<'STANDIN_INSTALL'
#!/usr/bin/env bash
# install as the drivers call it as root. An account that is not root cannot give a folder away, so -o and -g
# go. A folder it was asked to make root's is written to rootonly beside it, one path a line: the rclone
# stand-in reads that file to refuse the folder to a caller that sudo did not raise, as the kernel refuses a
# mode-700 folder to an account that does not own it.
real="$(PATH="${PATH#"$(dirname "$0"):"}" command -v install)"
args=(); paths=(); owner=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) owner="$2"; shift 2 ;;
    -g) shift 2 ;;
    -m) args+=(-m "$2"); shift 2 ;;
    -*) args+=("$1"); shift ;;
    *) args+=("$1"); paths+=("$1"); shift ;;
  esac
done
[ "$owner" != root ] || printf '%s\n' "${paths[@]}" >> "$(dirname "$0")/rootonly"
exec "$real" "${args[@]}"
STANDIN_INSTALL
printf '%s\n' '#!/usr/bin/env bash' '# chown as the restore calls it as root: an account that is not root cannot give a file away.' 'exit 0' > "$STANDIN/chown"
cat > "$STANDIN/awk" <<'STANDIN_AWK'
#!/usr/bin/env bash
# awk as the backup driver reads the log of the copy with it: its arguments go to argv.log, the machine's own awk does the work.
here="$(dirname "$0")"
printf 'awk %s\n' "$*" >> "$here/argv.log"
exec REAL_AWK "$@"
STANDIN_AWK
sed -i "s#REAL_AWK#$(command -v awk)#" "$STANDIN/awk"
 # the rclone the platform pins answers its version, and the stand-ins of the package manager and of the fetch log what they are asked
RCLONE_PIN_OF_TREE="$(yq e '.cliTools.rclone.version' "$HERE/../clusters/platform/versions.yaml")"
[ -n "$RCLONE_PIN_OF_TREE" ] && [ "$RCLONE_PIN_OF_TREE" != null ] || fail 'clusters/platform/versions.yaml states no cliTools.rclone.version yq could read'
printf 'rclone %s\n- os/version: stand-in\n' "$RCLONE_PIN_OF_TREE" > "$STANDIN/rclone-answer"
cat > "$STANDIN/dpkg" <<'STANDIN_DPKG'
#!/usr/bin/env bash
# dpkg as require-rclone.sh calls it: --print-architecture answers the file dpkg-arch (amd64 if there is none); -i FILE logs the call
# and, unless the file dpkg-fails stands, puts the rclone stand-in back where it was hidden as rclone.hidden, as an installed package would.
here="$(dirname "$0")"
printf 'dpkg %s\n' "$*" >> "$here/dpkg.log"
case "$1" in
  --print-architecture) cat "$here/dpkg-arch" 2> /dev/null || echo amd64 ;;
  -i) [ ! -e "$here/dpkg-fails" ] || { echo 'dpkg: error processing archive (stand-in)' >&2; exit 1; }
      [ ! -e "$here/rclone.hidden" ] || mv "$here/rclone.hidden" "$here/rclone"
      [ ! -e "$here/dpkg-installs-answer" ] || cp "$here/dpkg-installs-answer" "$here/rclone-answer" ;;
  *) echo "dpkg stand-in: a call the driver does not make: $*" >&2; exit 2 ;;
esac
STANDIN_DPKG
cat > "$STANDIN/curl" <<'STANDIN_CURL'
#!/usr/bin/env bash
# curl as require-rclone.sh calls it: every call is logged with its arguments, and none is answered: the machine has no route to the mirror.
printf 'curl %s\n' "$*" >> "$(dirname "$0")/curl.log"
echo 'curl: (6) Could not resolve host (stand-in)' >&2
exit 6
STANDIN_CURL
chmod 700 "$STANDIN/sudo" "$STANDIN/dpkg" "$STANDIN/curl" "$STANDIN/gpg" "$STANDIN/tar" "$STANDIN/microk8s" "$STANDIN/rclone" "$STANDIN/git" "$STANDIN/install" "$STANDIN/chown" "$STANDIN/awk"

BACKUP_ROOT="$(grep '^root() ' "$HERE/master-backup-driver.sh")"
BACKUP_SEAL="$(sed -n '/^seal() {/,/^}/p' "$HERE/master-backup-driver.sh")"
RESTORE_ROOT="$(grep '^root() ' "$HERE/master-restore-driver.sh")"
RESTORE_STORES="$(sed -n '/^STORES=($/,/^)$/p' "$HERE/master-restore-driver.sh")"
RESTORE_PLACEMENT="$(sed -n '/^PLACE=/,/^root chmod 700 "\$PLACE"$/p' "$HERE/master-restore-driver.sh")"
BACKUP_CLEANUP="$(sed -n "/^SECRETS=''/,/^trap cleanup/p" "$HERE/master-backup-driver.sh")"
BACKUP_READBACK_TIMINGS="$(grep -E '^readonly READBACK_[A-Z_]+=' "$HERE/master-backup-driver.sh")"
BACKUP_SECRETS="$(sed -n '/^SECRETS="\$(mktemp/,/^( umask 077/p' "$HERE/master-backup-driver.sh")"
BACKUP_RCLONE_CONF="$(sed -n '/^RCLONE_CONF=/,/^export RCLONE_CONFIG=/p' "$HERE/master-backup-driver.sh")"
BACKUP_WORK="$(sed -n '/^ID=/,/^root install -d -m 700/p' "$HERE/master-backup-driver.sh")"
BACKUP_WAY_OUT="$(sed -n '/^step "the manifest, and the way out"/,/^printf .BACKUP %s/p' "$HERE/master-backup-driver.sh")"
RESTORE_CLEANUP="$(sed -n "/^SECRETS=''/,/^trap cleanup/p" "$HERE/master-restore-driver.sh")"
RESTORE_SECRETS="$(sed -n '/^SECRETS="\$(mktemp/,/^export RCLONE_CONFIG=/p' "$HERE/master-restore-driver.sh")"
RESTORE_FETCHED="$(sed -n '/^step "the backup \$ID, fetched and checked"/,/^good "\${#STORES\[@\]} store(s) stand opened/p' "$HERE/master-restore-driver.sh")"
for lifted in BACKUP_ROOT BACKUP_SEAL BACKUP_CLEANUP BACKUP_READBACK_TIMINGS BACKUP_SECRETS BACKUP_RCLONE_CONF BACKUP_WORK BACKUP_WAY_OUT RESTORE_ROOT RESTORE_STORES RESTORE_PLACEMENT RESTORE_CLEANUP RESTORE_SECRETS RESTORE_FETCHED; do
  [ -n "${!lifted}" ] || fail "the drivers carry no text for $lifted — nothing below measures what reaches an elevated command"
done
BACKUP_TEXT="$BACKUP_CLEANUP"$'\n'"$BACKUP_READBACK_TIMINGS"$'\n'"$BACKUP_SECRETS"$'\n'"$BACKUP_ROOT"$'\n'"$BACKUP_RCLONE_CONF"$'\n'"$BACKUP_SEAL"

commands_wrong() { # says which planted secret stands in a line of $STANDIN/argv.log, which every stand-in writes its arguments to; ends 0
  grep -qF "$PLANTED_PASSPHRASE" "$STANDIN/argv.log" && echo 'the backup passphrase stands on a command line'
  grep -qF "$PLANTED_BOX_PASSWORD" "$STANDIN/argv.log" && echo 'the storage box password stands on a command line'
  grep -qF "$PLANTED_PAT" "$STANDIN/argv.log" && echo 'the read token stands on a command line'
  grep -qF "$PLANTED_PAT_BASE64" "$STANDIN/argv.log" && echo 'the read token stands on a command line, in base64'
  grep -qF "$PLANTED_PASSWORD" "$STANDIN/argv.log" && echo 'the elevation password stands on a command line'
  return 0
}
secrets_wrong() { # <secrets.seen> — says what is wrong with the folders the gpg stand-in was handed its passphrase file in, and removes them; ends 0
  local mode_folder mode_file folder
  if [ ! -s "$1" ]; then echo 'no passphrase reached gpg through a file'; return 0; fi
  while read -r mode_folder mode_file folder; do
    [ "$mode_folder $mode_file" = '700 600' ] || echo "the folder of secrets stood at mode $mode_folder and its file at $mode_file, not at 700 and 600"
    case "$folder" in /dev/shm/*) ;; *) echo "the folder of secrets stood in $folder, not in /dev/shm" ;; esac
    if [ -e "$folder" ]; then echo "the folder of secrets $folder stands after the driver ended"; rm -rf "$folder"; fi
  done < "$1"
  return 0
}
# shellcheck disable=SC2034 # the lifted text reads these
sealed_by() { # <sudo kind> <the text lifted first> <command line...> — its code is the command line's; what it printed stands in $OUT/sealed.out and $OUT/sealed.err, what every stand-in was handed in $STANDIN/argv.log
  local kind="$1" text="$2"; shift 2
  rm -rf "$STANDIN/secrets.seen" "$STANDIN/rootonly" "$STANDIN/box-uploaded" "$STANDIN/rclone-errors.log"; : > "$STANDIN/argv.log"
  ( export SUDO_STANDIN="$kind" SUDO_STANDIN_PASSWORD="$PLANTED_PASSWORD" PATH="$STANDIN:$PATH"
    umask 022
    set -uo pipefail
    die() { echo "die: $1" >&2; exit "${2:-1}"; }; say() { echo "say: $*"; }; step() { echo "step: $*"; }
    good() { # the claim that nothing is left on the machine is held to the folders at the moment it is made
      echo "good: $*"
      case "$*" in *'nothing of it is left on this machine'*)
        [ ! -e "$WORK" ] || echo 'claim: the work folder stood' >&2
        [ ! -e "${READBACK:-}" ] || echo 'claim: the read-back folder stood' >&2 ;;
      esac
    }
    CONFIG="$WORK/seal-config"; : > "$CONFIG"
    ELEVATION_PASSWORD="$PLANTED_PASSWORD"; BACKUP_PASSPHRASE="$PLANTED_PASSPHRASE"; STORAGE_BOX_PASSWORD="$PLANTED_BOX_PASSWORD"
    STORAGE_BOX_HOST="$BOX_HOST"; STORAGE_BOX_USER="$BOX_USER"
    . "$HERE/require-rclone.sh"
    eval "$text"
    "$@" ) < /dev/null > "$OUT/sealed.out" 2> "$OUT/sealed.err"
}
seal_holds() { # <sudo kind> <text> <sealed file> <the bytes it must hold> <command line...> — ends 0 when the sealed file is the passphrase line and those bytes, no secret stands on a command line, and the folder of secrets was right and is gone; what is wrong stands in $OUT/verdict
  local kind="$1" text="$2" sealed="$3" expected="$4"; shift 4
  local code=0
  : > "$OUT/verdict"
  rm -f "$sealed"
  sealed_by "$kind" "$text" "$@" || code=$?
  [ "$code" = 0 ] || echo "the seal ended with $code" >> "$OUT/verdict"
  if [ ! -f "$sealed" ]; then
    echo 'no sealed file was written' >> "$OUT/verdict"
  elif ! { printf 'sealed with: %s\n' "$PLANTED_PASSPHRASE"; cat "$expected"; } | cmp -s - "$sealed"; then
    echo "the sealed file holds other bytes than the passphrase line and the planted ones ($(wc -c < "$sealed" | tr -d ' ') bytes, $(wc -c < "$expected" | tr -d ' ') planted)" >> "$OUT/verdict"
  fi
  if [ -f "$sealed" ] && grep -qF "$PLANTED_PASSWORD" "$sealed" "$OUT/sealed.out" "$OUT/sealed.err"; then
    echo 'the elevation password stands in the sealed file or in what the seal printed' >> "$OUT/verdict"
  fi
  commands_wrong >> "$OUT/verdict"
  secrets_wrong "$STANDIN/secrets.seen" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}

SEAL_DIR="$WORK/seal"
mkdir -p "$SEAL_DIR/store" "$SEAL_DIR/store-failing"
seq 1 20000 > "$SEAL_DIR/store/payload" # more than a pipe holds, so the stream is read to its end
cp "$SEAL_DIR/store/payload" "$SEAL_DIR/store-failing/payload"
: > "$SEAL_DIR/store-failing/fails"
printf 'planted-unseal-key-1\nplanted-unseal-key-2\n' > "$SEAL_DIR/quorum.txt"
chmod 600 "$SEAL_DIR/quorum.txt"

for kind in nopasswd password; do
  seal_holds "$kind" "$BACKUP_TEXT" "$SEAL_DIR/store.gpg" "$SEAL_DIR/store/payload" \
    seal "$SEAL_DIR/store.gpg" tar --numeric-owner -C "$SEAL_DIR/store" -cf - . \
    || fail "backup: a store is not sealed whole under a sudo that reads $kind: $(cat "$OUT/verdict")"
  seal_holds "$kind" "$BACKUP_TEXT" "$SEAL_DIR/quorum.gpg" "$SEAL_DIR/quorum.txt" \
    seal "$SEAL_DIR/quorum.gpg" cat "$SEAL_DIR/quorum.txt" \
    || fail "backup: the quorum is not sealed whole under a sudo that reads $kind: $(cat "$OUT/verdict")"
  S_CODE=0; sealed_by "$kind" "$BACKUP_TEXT" seal "$SEAL_DIR/failing.gpg" tar --numeric-owner -C "$SEAL_DIR/store-failing" -cf - . || S_CODE=$?
  [ "$S_CODE" = 70 ] || fail "backup: a tar that fails half way did not fail the seal with its code under a sudo that reads $kind: got $S_CODE"
done
ok 'backup: a store and the quorum are sealed whole, and a tar that fails fails the seal, under a sudo that asks no password and under one that does'

# planted defects: the seal as it was, whose data came on a standard input that root() replaces
IFS= read -r -d '' OLD_SEAL <<'OLD' || true
seal() { # a file on stdin, sealed to $1 as root
  root env BACKUP_PASSPHRASE="$BACKUP_PASSPHRASE" sh -c 'exec gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 -o "$1" 3<<EOF
$BACKUP_PASSPHRASE
EOF
' _ "$1"
}
old_store() { root tar --numeric-owner -C "$1" -cf - . | seal "$2"; }
old_quorum() { cat "$1" | seal "$2"; }
OLD
OLD_TEXT="$BACKUP_ROOT"$'\n'"$OLD_SEAL"
for kind in nopasswd password; do
  ! seal_holds "$kind" "$OLD_TEXT" "$SEAL_DIR/old-store.gpg" "$SEAL_DIR/store/payload" old_store "$SEAL_DIR/store" "$SEAL_DIR/old-store.gpg" \
    || fail "the planted old store sealing was not caught under a sudo that reads $kind — the probe proves nothing"
  ! seal_holds "$kind" "$OLD_TEXT" "$SEAL_DIR/old-quorum.gpg" "$SEAL_DIR/quorum.txt" old_quorum "$SEAL_DIR/quorum.txt" "$SEAL_DIR/old-quorum.gpg" \
    || fail "the planted old quorum sealing was not caught under a sudo that reads $kind — the probe proves nothing"
done
seal_holds nopasswd "$OLD_TEXT" "$SEAL_DIR/old-store.gpg" "$SEAL_DIR/store/payload" old_store "$SEAL_DIR/store" "$SEAL_DIR/old-store.gpg" || true
grep -qF 'the elevation password stands in the sealed file' "$OUT/verdict" \
  || fail "the planted old store sealing under a sudo that asks no password did not seal the password line: $(cat "$OUT/verdict")"
ok 'the planted old sealing is caught for a store and for the quorum, under each sudo: where none asks, it seals the password line'
# planted defect: a seal that does not fail when its tar does
NO_PIPEFAIL="$(printf '%s\n' "$BACKUP_SEAL" | sed 's/set -o pipefail//')"
[ "$NO_PIPEFAIL" != "$BACKUP_SEAL" ] || fail 'the planted seal without pipefail was not planted — the probe proves nothing'
S_CODE=0; sealed_by nopasswd "${BACKUP_TEXT/"$BACKUP_SEAL"/"$NO_PIPEFAIL"}" seal "$SEAL_DIR/failing.gpg" tar --numeric-owner -C "$SEAL_DIR/store-failing" -cf - . || S_CODE=$?
[ "$S_CODE" = 0 ] || fail "the planted seal without pipefail was not the defect it is: it ended with $S_CODE"
ok 'the planted seal without pipefail ends 0 on a tar that failed, where the real one ends 70'

# The placement: written by root, then run as driver.sh runs it. The written script is the heredoc's lines.
PLACEMENT_ID=20261018T000000Z
# shellcheck disable=SC2034 # the lifted placement text reads these
placement_holds() { # <sudo kind> <the placement text> — fresh staging, the placement written, then run; ends 0 when it was written whole, ran, and the password stands nowhere; what is wrong stands in $OUT/verdict
  local kind="$1" text="$2" dir="$WORK/placement-$1" code=0 stores
  stores="$(printf '%s\n' "$RESTORE_STORES" | grep -c '^  "')"
  : > "$OUT/verdict"
  rm -rf "$dir"; mkdir -p "$dir/storage" "$dir/staging"
  : > "$STANDIN/kubectl.log"
  ( export SUDO_STANDIN="$kind" SUDO_STANDIN_PASSWORD="$PLANTED_PASSWORD" PATH="$STANDIN:$PATH"
    set -uo pipefail
    ELEVATION_PASSWORD="$PLANTED_PASSWORD"
    ID="$PLACEMENT_ID" STAGE=prod STAGING="$dir/staging" STORAGE_ROOT="$dir/storage"
    PLAIN="$STAGING/$ID/stores"
    eval "$RESTORE_ROOT"
    eval "$RESTORE_STORES"
    for row in "${STORES[@]}"; do
      IFS='|' read -r ns pvc size <<< "$row"
      mkdir -p "$PLAIN/${ns}--${pvc}"; echo planted > "$PLAIN/${ns}--${pvc}/data"
    done
    eval "$text" > "$OUT/place.out" 2> "$OUT/place.err"
    printf '%s\n' "$ID" > "$STAGING/pending"
    root bash "$STAGING/restore-data.sh" > "$OUT/placed.out" 2> "$OUT/placed.err" ) < /dev/null || code=$?
  [ "$code" = 0 ] || echo "the placement script ended with $code when run as driver.sh runs it" >> "$OUT/verdict"
  [ "$(head -n 1 "$dir/staging/restore-data.sh" 2> /dev/null)" = '#!/usr/bin/env bash' ] \
    || echo 'the written restore-data.sh does not begin with the heredoc'"'"'s first line' >> "$OUT/verdict"
  [ "$(grep -c "store(s) placed from backup $PLACEMENT_ID" "$OUT/placed.out" 2> /dev/null)" = 1 ] \
    || echo 'the placement script did not report its stores placed' >> "$OUT/verdict"
  [ "$(grep -c '^kind: PersistentVolume$' "$STANDIN/kubectl.log")" = "$stores" ] \
    || echo "the placement script did not declare $stores volumes" >> "$OUT/verdict"
  [ "$(find "$dir/storage" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "$stores" ] \
    || echo "the placement script did not place $stores store directories" >> "$OUT/verdict"
  if grep -rqF "$PLANTED_PASSWORD" "$dir" "$OUT/place.out" "$OUT/place.err" "$OUT/placed.out" "$OUT/placed.err" "$STANDIN/kubectl.log"; then
    echo 'the elevation password stands in restore-data.sh or in a line the restore or driver.sh prints' >> "$OUT/verdict"
  fi
  [ ! -s "$OUT/verdict" ]
}
for kind in nopasswd password; do
  placement_holds "$kind" "$RESTORE_PLACEMENT" \
    || fail "restore: the placement script is not written whole and run clean under a sudo that reads $kind: $(cat "$OUT/verdict")"
done
ok 'restore: restore-data.sh holds the heredoc'"'"'s lines, runs as driver.sh runs it, and carries the password nowhere, under a sudo that asks no password and under one that does'
# planted defect: the placement handed to root as a heredoc, as it was
WRITE_LINE="$(printf '%s\n' "$RESTORE_PLACEMENT" | grep '^root env PLACEMENT=')"
[ -n "$WRITE_LINE" ] || fail 'the placement carries no root env PLACEMENT= line — the planted old placement cannot be built'
OLD_WRITE='root sh -c "cat > $PLACE" <<<"$PLACEMENT"'
OLD_PLACEMENT="${RESTORE_PLACEMENT/"$WRITE_LINE"/"$OLD_WRITE"}"
[ "$OLD_PLACEMENT" != "$RESTORE_PLACEMENT" ] || fail 'the planted old placement was not planted — the probe proves nothing'
for kind in nopasswd password; do
  ! placement_holds "$kind" "$OLD_PLACEMENT" \
    || fail "the planted old placement was not caught under a sudo that reads $kind — the probe proves nothing"
done
placement_holds nopasswd "$OLD_PLACEMENT" || true
grep -qF 'the elevation password stands in restore-data.sh' "$OUT/verdict" \
  || fail "the planted old placement under a sudo that asks no password did not write the password into restore-data.sh: $(cat "$OUT/verdict")"
ok 'the planted old placement is caught under each sudo: where none asks, restore-data.sh holds the password line and driver.sh prints it'

# ── no secret is an argument of any command, and the files that carry them are right and gone ─
# The backup: its seal of a store and of the quorum, and the line that obscures the storage box password.
plant() { # <text> <the line it carries> <the line to put in its place> — the text so changed stands in $PLANTED_TEXT; a line the text does not carry fails the run
  PLANTED_TEXT="${1/"$2"/"$3"}"
  [ "$PLANTED_TEXT" != "$1" ] || fail "a planted defect was not planted — the probe proves nothing: $2"
}
caught_for() { # <the name of the planted defect> <what the verdict must say> [<what else it may say>...] — the case just run was refused for the first, and for nothing but those
  local name="$1" line fragment said=''
  shift
  while IFS= read -r line; do
    said=''
    for fragment in "$@"; do case "$line" in *"$fragment"*) said=1 ;; esac; done
    [ -n "$said" ] || fail "the planted $name was refused for more than it is: $line"
  done < "$OUT/verdict"
  grep -qF "$1" "$OUT/verdict" || fail "the planted $name was not refused for what it is: $(cat "$OUT/verdict")"
}
for kind in nopasswd password; do
  seal_holds "$kind" "$BACKUP_TEXT" "$SEAL_DIR/store.gpg" "$SEAL_DIR/store/payload" \
    seal "$SEAL_DIR/store.gpg" tar --numeric-owner -C "$SEAL_DIR/store" -cf - . \
    || fail "backup: a store was sealed with a secret on a command line, or its secrets were not kept right, under a sudo that reads $kind: $(cat "$OUT/verdict")"
  grep -qF -- '--passphrase-file' "$STANDIN/argv.log" || fail 'backup: the seal did not give gpg its passphrase as a file'
  seal_holds "$kind" "$BACKUP_TEXT" "$SEAL_DIR/quorum.gpg" "$SEAL_DIR/quorum.txt" \
    seal "$SEAL_DIR/quorum.gpg" cat "$SEAL_DIR/quorum.txt" \
    || fail "backup: the quorum was sealed with a secret on a command line, or its secrets were not kept right, under a sudo that reads $kind: $(cat "$OUT/verdict")"
done
ok 'backup: no secret stands on a command line for a store or the quorum, the passphrase file is at 600 in a folder at 700 in /dev/shm, and the folder is gone when the driver ends'

# planted defects, one line each: the seal as it was (the passphrase handed to root through env), the obscure
# of the box password on the operator's own command line, a clean-up that leaves the folder, a file written
# under an open umask
IFS= read -r -d '' PRIOR_SEAL <<'PRIOR' || true
seal() {
  root env BACKUP_PASSPHRASE="$BACKUP_PASSPHRASE" bash -c 'set -o pipefail
out=$1; shift
"$@" | gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 -o "$out" 3<<EOF
$BACKUP_PASSPHRASE
EOF
' _ "$@"
}
PRIOR
plant "$BACKUP_TEXT" "$BACKUP_SEAL" "${PRIOR_SEAL%$'\n'}"; PLANTED_PRIOR_SEAL="$PLANTED_TEXT"
OBSCURE_LINE='"$(printf '"'%s\\n'"' "$STORAGE_BOX_PASSWORD" | rclone obscure -)"'
plant "$BACKUP_TEXT" "$OBSCURE_LINE" '"$(rclone obscure "$STORAGE_BOX_PASSWORD")"'; PLANTED_OBSCURE="$PLANTED_TEXT"
plant "$BACKUP_TEXT" 'rm -rf "$SECRETS" 2>/dev/null || true' 'true'; PLANTED_KEPT="$PLANTED_TEXT"
plant "$BACKUP_TEXT" '( umask 077; printf' '( printf'; PLANTED_OPEN_UMASK="$PLANTED_TEXT"
for kind in nopasswd password; do
  ! seal_holds "$kind" "$PLANTED_PRIOR_SEAL" "$SEAL_DIR/prior.gpg" "$SEAL_DIR/store/payload" seal "$SEAL_DIR/prior.gpg" tar --numeric-owner -C "$SEAL_DIR/store" -cf - . \
    || fail "the planted seal that hands the passphrase to root through env was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'seal with the passphrase in env' 'the backup passphrase stands on a command line' 'no passphrase reached gpg through a file'
  ! seal_holds "$kind" "$PLANTED_OBSCURE" "$SEAL_DIR/obscure.gpg" "$SEAL_DIR/store/payload" seal "$SEAL_DIR/obscure.gpg" tar --numeric-owner -C "$SEAL_DIR/store" -cf - . \
    || fail "the planted obscure of the box password as an argument was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'obscure of the box password as an argument' 'the storage box password stands on a command line'
  ! seal_holds "$kind" "$PLANTED_KEPT" "$SEAL_DIR/kept.gpg" "$SEAL_DIR/store/payload" seal "$SEAL_DIR/kept.gpg" tar --numeric-owner -C "$SEAL_DIR/store" -cf - . \
    || fail "the planted clean-up that leaves the folder was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'clean-up that leaves the folder' 'stands after the driver ended'
  ! seal_holds "$kind" "$PLANTED_OPEN_UMASK" "$SEAL_DIR/umask.gpg" "$SEAL_DIR/store/payload" seal "$SEAL_DIR/umask.gpg" tar --numeric-owner -C "$SEAL_DIR/store" -cf - . \
    || fail "the planted passphrase file written under an open umask was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'passphrase file written under an open umask' 'its file at 644'
done
ok 'the planted seals are caught under each sudo: the passphrase in env, the box password as an argument, a folder left behind, a file under an open umask'

# ── root carries what root made ─────────────────────────────────────────────────────────────────────
# The work folder is root's at mode 700, and so is every archive and the manifest in it. The operator, who
# runs this driver, cannot read it, so a copy run by the operator carries nothing and ends 69. The stand-ins
# model that: install records a folder made root's, and the rclone stand-in refuses it to a caller sudo did
# not raise. rclone saves into the config it loaded, so after root's copy the config is root's too, at its
# old mode 600, and a listing the operator runs on it ends 1: the rclone stand-in models that the same way.
# The cases run the driver's own text for the work folder, the seals and the way out against a
# box the stand-in serves, then read what reached the box. The model is declared by the stand-ins; the
# account that runs this suite owns every file in it. The real folder is the one on a master.
CARRY_FQDN=master.example.invalid
# shellcheck disable=SC2034 # the lifted text reads these
carry_run() { # the driver's own lines: the work folder made, one store and the quorum sealed into it, then the way out
  FQDN="$CARRY_FQDN" STAGE=prod TAKEN=1
  STORES=("ns|pvc|workload|deployment")
  eval "$CARRY_WORK"
  seal "$WORK/ns--pvc.tar.gpg" tar --numeric-owner -C "$SEAL_DIR/store" -cf - .
  seal "$WORK/host--vault-${STAGE}.txt.gpg" cat "$SEAL_DIR/quorum.txt"
  eval "$CARRY_WAY_OUT"
}
refusals_said() { # says what the rclone stand-in refused in the case just run, in one line, since the drivers print none of rclone's words; ends 0
  if [ -s "$STANDIN/rclone-errors.log" ]; then echo "the rclone stand-in refused: $(tr '\n' ' ' < "$STANDIN/rclone-errors.log")"; fi
  return 0
}
printed_wrong() { # <file>... — says which planted line stands in those files, whole: the quorum, the passphrase and the passwords reach the operator's terminal and the log of the run, so none may; ends 0
  local planted
  for planted in planted-unseal-key-1 planted-unseal-key-2 "$PLANTED_PASSPHRASE" "$PLANTED_BOX_PASSWORD" "$PLANTED_PASSWORD"; do
    grep -qF -- "$planted" "$@" && echo "the run printed the planted line $planted"
  done
  return 0
}
carry_holds() { # <sudo kind> <the text lifted first> <the way out> — ends 0 when the way out ran to its end and the box holds the sealed archives and a manifest that holds them, the work folder and the read-back folder are gone, and nothing planted was printed; what is wrong stands in $OUT/verdict
  local kind="$1" text="$2" code=0 landed
  CARRY_WAY_OUT="$3"
  : > "$OUT/verdict"
  rm -rf "$SEAL_DIR/backups"
  sealed_by "$kind" "$text" carry_run || code=$?
  printed_wrong "$OUT/sealed.out" "$OUT/sealed.err" >> "$OUT/verdict"
  refusals_said >> "$OUT/verdict"
  ! grep -q 'command not found' "$OUT/sealed.err" || echo "the way out called a command the case does not define: $(grep 'command not found' "$OUT/sealed.err" | head -n 1)" >> "$OUT/verdict"
  if [ "$code" != 0 ]; then
    echo "the way out ended with $code: $(tail -n 2 "$OUT/sealed.err" | tr '\n' ' ')" >> "$OUT/verdict"
    return 1
  fi
  landed="$(find "$STANDIN/box-uploaded/$CARRY_FQDN/master" -mindepth 1 -maxdepth 1 -type d 2> /dev/null)"
  if [ "$(printf '%s\n' "$landed" | grep -c .)" != 1 ]; then
    echo 'the box holds no one backup folder' >> "$OUT/verdict"
  else
    [ "$(ls "$landed" | tr '\n' ' ')" = 'host--vault-prod.txt.gpg manifest.txt ns--pvc.tar.gpg ' ] || echo "the box holds other files than the two archives and the manifest: $(ls "$landed" | tr '\n' ' ')" >> "$OUT/verdict"
    ( cd "$landed" && grep -E '^[0-9a-f]{64}  ' manifest.txt | sha256sum -c --quiet ) > /dev/null 2>&1 || echo 'the checksums in the manifest on the box do not hold' >> "$OUT/verdict"
    grep -qx 'STORES=1' "$landed/manifest.txt" || echo 'the manifest on the box does not count the one store' >> "$OUT/verdict"
    { printf 'sealed with: %s\n' "$PLANTED_PASSPHRASE"; cat "$SEAL_DIR/store/payload"; } | cmp -s - "$landed/ns--pvc.tar.gpg" || echo 'the archive on the box is not the sealed store' >> "$OUT/verdict"
    { printf 'sealed with: %s\n' "$PLANTED_PASSPHRASE"; cat "$SEAL_DIR/quorum.txt"; } | cmp -s - "$landed/host--vault-prod.txt.gpg" || echo 'the archive on the box is not the sealed quorum' >> "$OUT/verdict"
    [ "$(tail -n 1 "$OUT/sealed.out")" = "BACKUP $(basename "$landed")" ] || echo 'the last line is not BACKUP and the id the box holds' >> "$OUT/verdict"
    [ ! -e "$SEAL_DIR/backups/$(basename "$landed")" ] || echo 'the work folder stands after the way out' >> "$OUT/verdict"
    [ ! -e "$SEAL_DIR/backups/$(basename "$landed").readback" ] || echo 'the read-back folder stands after the way out' >> "$OUT/verdict"
  fi
  ! grep -qF -- 'claim: the work folder stood' "$OUT/sealed.err" || echo 'the way out said that nothing of it is left on this machine while the work folder stood' >> "$OUT/verdict"
  ! grep -qF -- 'claim: the read-back folder stood' "$OUT/sealed.err" || echo 'the way out said that nothing of it is left on this machine while the read-back folder stood' >> "$OUT/verdict"
  commands_wrong >> "$OUT/verdict"
  secrets_wrong "$STANDIN/secrets.seen" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
CARRY_WORK="${BACKUP_WORK//\/var\/lib\/master-backup/$SEAL_DIR/backups}"
[ "$CARRY_WORK" != "$BACKUP_WORK" ] || fail 'the work folder of the driver is not moved into the sandbox — the carry cases would reach /var/lib'
for kind in nopasswd password; do
  carry_holds "$kind" "$BACKUP_TEXT" "$BACKUP_WAY_OUT" \
    || fail "backup: the archives and the manifest of a work folder only root reads did not reach the box under a sudo that reads $kind: $(cat "$OUT/verdict")"
done
ok 'backup: a work folder only root reads is carried to the box by root, listed back by root on the config it saved into, whole, with its manifest, and removed, under a sudo that asks no password and under one that does'

# planted defects: the copy as the operator runs it (the work folder is refused to it), and root's copy
# without the config by path (sudo resets the environment, so the box is not defined for root)
COPY_LINE='root rclone --config "$RCLONE_CONF" copy "$WORK"'
plant "$BACKUP_WAY_OUT" "$COPY_LINE" 'rclone copy "$WORK"'; BY_OPERATOR="$PLANTED_TEXT"
plant "$BACKUP_WAY_OUT" "$COPY_LINE" 'root rclone copy "$WORK"'; WITHOUT_CONFIG="$PLANTED_TEXT"
plant "$BACKUP_TEXT" "( umask 077; printf '[box]" "( printf '[box]"; OPEN_CONFIG_UMASK="$PLANTED_TEXT"
for kind in nopasswd password; do
  ! carry_holds "$kind" "$BACKUP_TEXT" "$BY_OPERATOR" || fail "the planted copy run by the operator was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'copy run by the operator' 'the way out ended with 69' 'permission denied'
  grep -qF 'permission denied' "$OUT/verdict" || fail "the planted copy run by the operator was not refused for the folder it cannot read: $(cat "$OUT/verdict")"
  ! carry_holds "$kind" "$BACKUP_TEXT" "$WITHOUT_CONFIG" || fail "the planted root copy without the config by path was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'root copy without the config by path' 'the way out ended with 69' 'the remote box is not defined'
  grep -qF 'the remote box is not defined' "$OUT/verdict" || fail "the planted root copy without the config by path was not refused for the box it does not know: $(cat "$OUT/verdict")"
  ! carry_holds "$kind" "$OPEN_CONFIG_UMASK" "$BACKUP_WAY_OUT" || fail "the planted box config written under an open umask was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'box config written under an open umask' 'its file at 644'
done
ok 'the planted copies are caught under each sudo: the operator refused the work folder, root without the config by path refused the box, the box config under an open umask'

# planted defects of the listing, which follows root's copy: the copy has just saved into the config what
# the box answered, so the config is root's, and a listing run by the operator cannot load it (it ends 1,
# and the error stays on the screen); a listing root runs without the config by path does not know the box
LIST_LINE='root rclone --config "$RCLONE_CONF" lsf'
plant "$BACKUP_WAY_OUT" "$LIST_LINE" 'rclone lsf'; LIST_BY_OPERATOR="$PLANTED_TEXT"
plant "$BACKUP_WAY_OUT" "$LIST_LINE" 'root rclone lsf'; LIST_WITHOUT_CONFIG="$PLANTED_TEXT"
for kind in nopasswd password; do
  ! carry_holds "$kind" "$BACKUP_TEXT" "$LIST_BY_OPERATOR" || fail "the planted listing run by the operator was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'listing run by the operator' 'the way out ended with 69' 'Failed to load config file'
  grep -qF 'Failed to load config file' "$OUT/verdict" || fail "the planted listing run by the operator did not show the error rclone ended with: $(cat "$OUT/verdict")"
  ! carry_holds "$kind" "$BACKUP_TEXT" "$LIST_WITHOUT_CONFIG" || fail "the planted root listing without the config by path was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'root listing without the config by path' 'the way out ended with 69' 'the remote box is not defined'
  grep -qF 'the remote box is not defined' "$OUT/verdict" || fail "the planted root listing without the config by path did not show the error rclone ended with: $(cat "$OUT/verdict")"
done
ok 'the planted listings are caught under each sudo: the operator cannot load the config root saved into, root without the config by path does not know the box, and each shows the error rclone ended with'

# ── what stands on the box is read back, and a box that holds other bytes than were sent is refused ─
# The count of file names and the size check rclone makes while it copies look at no byte of what the box
# keeps. So after the count, the driver copies the backup back from the box into a folder of root's and
# checks it there: the manifest's checksums, the manifest's count of stores against the rows of STORES, and
# that the quorum archive opens with the passphrase, which writes the opened quorum nowhere. Each case makes
# the box hold other bytes than the driver sent, by the script after-upload that the rclone stand-in runs on
# what it was handed, as a copy that lost a connection half way would leave it. The refusal ends 69, names
# the check that failed, removes the read-back folder, and leaves the work folder where the archives stand.
BOX_FLIPPED_BYTE='printf Z | dd of="$1/ns--pvc.tar.gpg" bs=1 count=1 conv=notrunc 2> /dev/null'
BOX_OTHER_COUNT='sed -i "s/^STORES=.*/STORES=2/" "$1/manifest.txt"'
BOX_LOST_SHAPE='sed -i "/ ns--pvc.tar.gpg\$/s/^./g/" "$1/manifest.txt"'
BOX_LOST_SHAPE_AND_FLIPPED="$BOX_LOST_SHAPE"$'\n'"$BOX_FLIPPED_BYTE"
{ printf 'sealed with: another-passphrase\n'; cat "$SEAL_DIR/quorum.txt"; } > "$STANDIN/other-quorum.gpg"
BOX_OTHER_PASSPHRASE='cp "$(dirname "$0")/other-quorum.gpg" "$1/host--vault-prod.txt.gpg"
( cd "$1" && { head -n 5 manifest.txt; sha256sum -- *.gpg; } > manifest.new && mv manifest.new manifest.txt )'
carry_refused() { # <sudo kind> <the way out> <what the box does to the upload: a script that is handed its folder> <what the refusal must say> [<the text lifted first>] — ends 0 when the way out ended 69 saying that, the read-back folder is gone and the work folder stands, and nothing planted was printed; what is wrong stands in $OUT/verdict
  local kind="$1" says="$4" text="${5:-$BACKUP_TEXT}" code=0 folders
  CARRY_WAY_OUT="$2"
  : > "$OUT/verdict"
  rm -rf "$SEAL_DIR/backups"
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$STANDIN/after-upload"; chmod 700 "$STANDIN/after-upload"
  sealed_by "$kind" "$text" carry_run || code=$?
  rm -f "$STANDIN/after-upload"
  printed_wrong "$OUT/sealed.out" "$OUT/sealed.err" >> "$OUT/verdict"
  refusals_said >> "$OUT/verdict"
  if [ "$code" = 0 ]; then
    echo 'the way out ended with 0 although the box holds other bytes than were sent' >> "$OUT/verdict"
  else
    [ "$code" = 69 ] || echo "the way out ended with $code, not 69: $(tail -n 2 "$OUT/sealed.err" | tr '\n' ' ')" >> "$OUT/verdict"
    grep -qF -- "$says" "$OUT/sealed.err" || echo "the way out did not say '$says': $(tail -n 2 "$OUT/sealed.err" | tr '\n' ' ')" >> "$OUT/verdict"
    folders="$(ls "$SEAL_DIR/backups" 2> /dev/null)"
    case "$folders" in *.readback*) echo 'the read-back folder stands after the way out' >> "$OUT/verdict" ;; esac
    [ "$(printf '%s\n' "$folders" | grep -c '^[0-9]\{8\}T[0-9]\{6\}Z$')" = 1 ] \
      || echo "the work folder does not stand after the way out: $(printf '%s' "$folders" | tr '\n' ' ')" >> "$OUT/verdict"
  fi
  [ ! -s "$OUT/verdict" ]
}
for kind in nopasswd password; do
  carry_refused "$kind" "$BACKUP_WAY_OUT" "$BOX_FLIPPED_BYTE" 'do not match the checksums' \
    || fail "backup: a box that holds a flipped byte in an archive was not refused under a sudo that reads $kind: $(cat "$OUT/verdict")"
  carry_refused "$kind" "$BACKUP_WAY_OUT" "$BOX_OTHER_COUNT" 'counts other stores' \
    || fail "backup: a manifest on the box that counts other stores than STORES has rows was not refused under a sudo that reads $kind: $(cat "$OUT/verdict")"
  carry_refused "$kind" "$BACKUP_WAY_OUT" "$BOX_OTHER_PASSPHRASE" 'does not open' \
    || fail "backup: a quorum archive on the box sealed with another passphrase was not refused under a sudo that reads $kind: $(cat "$OUT/verdict")"
  carry_refused "$kind" "$BACKUP_WAY_OUT" "$BOX_LOST_SHAPE" 'is not the manifest that was sent' \
    || fail "backup: a manifest on the box whose checksum line lost its form was not refused under a sudo that reads $kind: $(cat "$OUT/verdict")"
  carry_refused "$kind" "$BACKUP_WAY_OUT" "$BOX_LOST_SHAPE_AND_FLIPPED" 'is not the manifest that was sent' \
    || fail "backup: an archive on the box with a flipped byte under a checksum line that lost its form was not refused under a sudo that reads $kind: $(cat "$OUT/verdict")"
done
ok 'backup: a flipped byte in an archive on the box, a manifest that counts other stores than STORES has rows, a quorum archive sealed with another passphrase, and a manifest whose checksum line lost its form, with its archive flipped or not, are each refused with 69, naming the check; the read-back folder is gone and the work folder stands'

# planted defects of the read-back, each of which lets its case through (the way out ends 0), or prints, or
# leaves its folder
plant "$BACKUP_WAY_OUT" 'copy "$BACKUPS/$ID/" "$READBACK" --use-json-log' 'copy "$WORK" "$READBACK" --use-json-log'; READS_WORK="$PLANTED_TEXT"
plant "$BACKUP_WAY_OUT" "root bash -c 'echo \"\$\$\" > \"\$1\"; shift; exec \"\$@\"'" "bash -c 'echo \"\$\$\" > \"\$1\"; shift; exec \"\$@\"'"; READS_BY_OPERATOR="$PLANTED_TEXT"
plant "$BACKUP_WAY_OUT" 'sha256sum -c) || exit 11' 'sed "s/^[0-9a-f]*  //; s/\$/: OK/") || exit 11'; NO_CHECKSUMS="$PLANTED_TEXT"
plant "$BACKUP_WAY_OUT" $'\ncmp -s manifest.txt "$5" || exit 14' ''; NO_COMPARISON_ONLY="$PLANTED_TEXT"
# the coverage refuses a manifest that lost the form of a checksum line as well, so the comparison is planted away in a driver without it
plant "$BACKUP_WAY_OUT" 'if [ "$READBACK_VERIFIED" != "$READBACK_EXPECTED_ARCHIVES" ] || [ "$READBACK_OTHER" != 0 ]; then' 'if false; then'; NO_COVERAGE="$PLANTED_TEXT"
plant "$NO_COVERAGE" $'\ncmp -s manifest.txt "$5" || exit 14' ''; NO_MANIFEST_COMPARISON="$PLANTED_TEXT"
# the comparison would refuse the damage of the next two cases first, so they are planted in a driver without it
plant "$NO_MANIFEST_COMPARISON" 'grep -qx "STORES=$2" manifest.txt || exit 12' 'true'; NO_STORE_COUNT="$PLANTED_TEXT"
plant "$NO_MANIFEST_COMPARISON" 'gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$3" -o /dev/null -d "host--vault-$4.txt.gpg" || exit 13' 'true'; NO_QUORUM_OPENING="$PLANTED_TEXT"
plant "$BACKUP_WAY_OUT" '-o /dev/null -d "host--vault-$4.txt.gpg"' '-d "host--vault-$4.txt.gpg"'; OPENS_TO_OUTPUT="$PLANTED_TEXT"
plant "$BACKUP_WAY_OUT" '-o /dev/null -d "host--vault-$4.txt.gpg"' '-d "host--vault-$4.txt.gpg" >&2'; OPENS_TO_TERMINAL="$PLANTED_TEXT"
TRAP_REMOVAL='if [ -n "$READBACK" ]; then root rm -rf "$READBACK" >/dev/null 2>&1; fi'
plant "$BACKUP_TEXT" "$TRAP_REMOVAL" 'true'; KEEPS_AFTER_REFUSAL="$PLANTED_TEXT"
plant "$BACKUP_WAY_OUT" 'root rm -rf "$WORK" "$READBACK"' 'root rm -rf "$WORK"'; KEEPS_AFTER_SUCCESS="$PLANTED_TEXT"
plant "$KEEPS_AFTER_SUCCESS" 'if root test -e "$WORK" || root test -e "$READBACK"; then' 'if false; then'; KEEPS_UNCHECKED="$PLANTED_TEXT"
plant "$BACKUP_TEXT" 'pass = %s\ndisable_hashcheck = true\n' 'pass = %s\n'; HASH_CHECK_ON="$PLANTED_TEXT"
plant "$BACKUP_TEXT" '\nuser = %s' ''; CONFIG_WITHOUT_USER="$PLANTED_TEXT"
for kind in nopasswd password; do
  ! carry_refused "$kind" "$READS_WORK" "$BOX_FLIPPED_BYTE" 'do not match the checksums' \
    || fail "the planted read-back of the work folder was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'read-back of the work folder' 'the way out ended with 0'
  ! carry_holds "$kind" "$BACKUP_TEXT" "$READS_BY_OPERATOR" \
    || fail "the planted read-back copy run by the operator was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'read-back copy run by the operator' 'the way out ended with 69' 'Failed to load config file'
  ! carry_refused "$kind" "$NO_CHECKSUMS" "$BOX_FLIPPED_BYTE" 'do not match the checksums' \
    || fail "the planted read-back without the checksums was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'read-back without the checksums' 'the way out ended with 0'
  ! carry_refused "$kind" "$NO_MANIFEST_COMPARISON" "$BOX_LOST_SHAPE" 'is not the manifest that was sent' \
    || fail "the planted read-back without the comparison of the manifest was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'read-back without the comparison of the manifest' 'the way out ended with 0'
  carry_refused "$kind" "$NO_COMPARISON_ONLY" "$BOX_LOST_SHAPE" 'archives of this backup' \
    || fail "the planted read-back without the comparison of the manifest let a checksum line that lost its form through the coverage under a sudo that reads $kind: $(cat "$OUT/verdict")"
  ! carry_refused "$kind" "$NO_MANIFEST_COMPARISON" "$BOX_LOST_SHAPE_AND_FLIPPED" 'is not the manifest that was sent' \
    || fail "the planted read-back without the comparison of the manifest was not caught on a flipped archive under a sudo that reads $kind — the probe proves nothing"
  caught_for 'read-back without the comparison of the manifest, on a flipped archive' 'the way out ended with 0'
  ! carry_refused "$kind" "$NO_STORE_COUNT" "$BOX_OTHER_COUNT" 'counts other stores' \
    || fail "the planted read-back without the count of stores was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'read-back without the count of stores' 'the way out ended with 0'
  ! carry_refused "$kind" "$NO_QUORUM_OPENING" "$BOX_OTHER_PASSPHRASE" 'does not open' \
    || fail "the planted read-back without the opening of the quorum was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'read-back without the opening of the quorum' 'the way out ended with 0'
  ! carry_holds "$kind" "$BACKUP_TEXT" "$OPENS_TO_TERMINAL" \
    || fail "the planted opening of the quorum to the terminal was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'opening of the quorum to the terminal' 'the run printed the planted line planted-unseal-key-1' 'the run printed the planted line planted-unseal-key-2'
  carry_refused "$kind" "$OPENS_TO_OUTPUT" 'true' 'other answer(s)' \
    || fail "the planted opening of the quorum to the output of the read-back was not refused as an answer that is no checksum, and unprinted, under a sudo that reads $kind: $(cat "$OUT/verdict")"
  ! carry_refused "$kind" "$BACKUP_WAY_OUT" "$BOX_FLIPPED_BYTE" 'do not match the checksums' "$KEEPS_AFTER_REFUSAL" \
    || fail "the planted clean-up that leaves the read-back folder after a refusal was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'clean-up that leaves the read-back folder after a refusal' 'the read-back folder stands after the way out'
  ! carry_holds "$kind" "$BACKUP_TEXT" "$KEEPS_AFTER_SUCCESS" \
    || fail "the planted way out that leaves the read-back folder was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'way out that leaves the read-back folder' 'the way out ended with 70'
  ! carry_holds "$kind" "$BACKUP_TEXT" "$KEEPS_UNCHECKED" \
    || fail "the planted way out that leaves the read-back folder and does not look for it was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'way out that leaves the read-back folder and does not look for it' 'the way out said that nothing of it is left on this machine while the read-back folder stood' 'the read-back folder stands after the way out'
  ! carry_holds "$kind" "$HASH_CHECK_ON" "$BACKUP_WAY_OUT" \
    || fail "the planted box config that leaves the remote hash check on was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'box config that leaves the remote hash check on' 'the way out ended with 69' 'md5 hashes differ'
  grep -qF 'md5 hashes differ' "$OUT/verdict" || fail "the planted box config that leaves the remote hash check on was not refused for the hash the box cannot give: $(cat "$OUT/verdict")"
  ! carry_holds "$kind" "$CONFIG_WITHOUT_USER" "$BACKUP_WAY_OUT" \
    || fail "the planted box config without a user was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'box config without a user' 'the way out ended with 69' 'the config does not define the remote box'
  grep -qF 'the config does not define the remote box' "$OUT/verdict" || fail "the planted box config without a user was not refused for the box it does not define: $(cat "$OUT/verdict")"
done
ok 'the planted read-backs are caught under each sudo: the work folder read in place of the box, the copy run by the operator, each check removed (the comparison of the manifest with the one sent among them), the quorum opened to the output, a folder left behind after a refusal and after a success, a box config that leaves the remote hash check on, a box config that does not define the box'

# ── one backup at a time on a machine ───────────────────────────────────────────────────────────────
# Two backups at once leave a store at 0 replicas (the second reads 0 where the first holds the store
# stopped, and starts it again with 0) and copy a store the first has started again. The cases run the
# driver whole, against the stand-ins, with its four paths moved into the sandbox (the work folder, the
# volumes, the quorum and the lock file); the lock is the kernel's, so flock is the real one. The first
# driver is held inside its store loop by the microk8s stand-in, and a second one is started beside it.
LOCK_DIR="$WORK/lock"
BACKUP_STORES="$(sed -n '/^STORES=($/,/^)$/p' "$HERE/master-backup-driver.sh")"
[ -n "$BACKUP_STORES" ] || fail 'the backup driver carries no STORES rows — the lock cases cannot give it volumes'
mkdir -p "$LOCK_DIR/srv/secrets"
cp "$SEAL_DIR/quorum.txt" "$LOCK_DIR/srv/secrets/vault-prod.txt"
while IFS='|' read -r ns pvc _ _; do
  mkdir -p "$LOCK_DIR/storage/${ns}-${pvc}-pvc-0000"
  echo planted-store > "$LOCK_DIR/storage/${ns}-${pvc}-pvc-0000/payload"
done < <(STAGE=prod; eval "$BACKUP_STORES"; printf '%s\n' "${STORES[@]}")
LOCK_STORES="$(ls "$LOCK_DIR/storage" | wc -l | tr -d ' ')"
lock_reset() { # <free|block|block-upload> — the stand-ins forget the last case; block holds the first scale call of the next one, block-upload its first copy to the box
  rm -rf "$STANDIN/blocked" "$STANDIN/release" "$STANDIN/block-first-scale" "$STANDIN/block-first-upload" "$STANDIN/readback-plan" "$STANDIN/readback-emitted" "$STANDIN/readback-timeline" "$STANDIN/readback-stats-path" "$STANDIN/transfer.pid" "$STANDIN/box-uploaded" "$STANDIN/rootonly" "$STANDIN/secrets.seen" "$STANDIN/cluster" "$STANDIN/box-fails" "$STANDIN/rclone-errors.log" "$LOCK_DIR/master-backup.lock"
  : > "$STANDIN/kubectl-calls.log"
  case "$1" in
    block) : > "$STANDIN/block-first-scale" ;;
    block-upload) : > "$STANDIN/block-first-upload" ;;
  esac
}
driver_names_literal() { grep -qF -- "$2" <<< "$1"; } # <the driver's text> <literal> — the text goes in as a here-string, since grep -q closes a pipe at its first match and the writer is cut off
PREAMBLE_TREE="$HERE/.." # the tree the metadata is read from: this one, or a copy whose rclone rows hold the digests of a fixture package
rclone_preamble() { # what a launcher sends ahead of a driver: the helper that puts the pinned rclone on the machine, and the metadata read from the tree
  tr -d $'\r' < "$HERE/require-rclone.sh"
  ( . "$HERE/read-rclone-pin.sh"; read_rclone_pin "$PREAMBLE_TREE" && printf '%s\n' "$RCLONE_METADATA" ) || fail 'read-rclone-pin.sh could not read the pin of the tree'
}
lock_driver() { # <run> <the driver's text> [NAME=value...] — the run's folder, with the driver and its paths moved into the sandbox, the waits of its hold shortened, NAME=value moving a named value of the driver on from there, and a config beside it
  local dir="$LOCK_DIR/$1" text="$2" literal pair moved=()
  shift 2
  for pair in QUEUE_POLL_SECONDS=0.05 STORE_POLL_SECONDS=0.05 READBACK_POLL_SECONDS=0.05 QUEUE_WAIT_SECONDS=20 STORE_WAIT_SECONDS=5 "$@"; do
    moved+=(-e "s#^readonly ${pair%%=*}=.*#readonly ${pair%%=*}=${pair#*=}#")
  done
  rm -rf "$dir"; mkdir -p "$dir"
  for literal in /var/lib/master-backup /var/snap/microk8s/common/default-storage /srv/hostyour-cloud /run/lock/master-backup.lock; do
    driver_names_literal "$text" "$literal" || fail "the backup driver names no $literal — the sandbox of the lock cases proves nothing"
  done
  { rclone_preamble; printf '%s\n' "$text"; } | sed -e "s#/var/lib/master-backup#$dir/backups#g" -e "s#/var/snap/microk8s/common/default-storage#$LOCK_DIR/storage#g" \
    -e "s#/srv/hostyour-cloud#$LOCK_DIR/srv#g" -e "s#/run/lock/master-backup.lock#$LOCK_DIR/master-backup.lock#g" "${moved[@]}" > "$dir/driver.sh"
  for literal in /var/lib/master-backup /var/snap/microk8s/common/default-storage /srv/hostyour-cloud /run/lock/master-backup.lock; do
    ! grep -qF -- "$literal" "$dir/driver.sh" || fail "the sandboxed backup driver still names $literal — the lock cases would reach this machine"
  done
  { printf "FQDN='%s'\nOPERATOR_USER='op'\nSTAGE='prod'\nELEVATION_PASSWORD='%s'\n" "$CARRY_FQDN" "$PLANTED_PASSWORD"
    printf "STORAGE_BOX_HOST='%s'\nSTORAGE_BOX_USER='%s'\nSTORAGE_BOX_PASSWORD='%s'\nBACKUP_PASSPHRASE='%s'\n" "$BOX_HOST" "$BOX_USER" "$PLANTED_BOX_PASSWORD" "$PLANTED_PASSPHRASE"; } > "$dir/config"
}
lock_start() { # <run> — starts the run in the background as the launcher starts a driver (umask 077, no input); its pid stands in $LOCK_PID
  local dir="$LOCK_DIR/$1"
  ( export SUDO_STANDIN=nopasswd SUDO_STANDIN_PASSWORD="$PLANTED_PASSWORD" PATH="$STANDIN:$PATH"
    umask 077
    exec bash "$dir/driver.sh" "$dir/config" ) < /dev/null > "$dir/out" 2> "$dir/err" &
  LOCK_PID=$!
}
lock_run() { # <run> — runs it in front, ended after two minutes at the latest; its code stands in $LOCK_CODE
  local dir="$LOCK_DIR/$1"
  LOCK_CODE=0
  ( export SUDO_STANDIN=nopasswd SUDO_STANDIN_PASSWORD="$PLANTED_PASSWORD" PATH="$STANDIN:$PATH"
    umask 077
    exec timeout 120 bash "$dir/driver.sh" "$dir/config" ) < /dev/null > "$dir/out" 2> "$dir/err" || LOCK_CODE=$?
}
lock_held() { # <run> — waits until a stand-in holds the run, inside its store loop or in its upload
  local _
  for _ in $(seq 1 300); do [ -d "$STANDIN/blocked" ] && return 0; sleep 0.1; done
  fail "the first driver did not reach the call that holds it in 30 seconds: $(tail -n 2 "$LOCK_DIR/$1/err" | tr '\n' ' ')"
}
lock_let_go() { # lets the held run go on, waits for it to end; its code stands in $LOCK_CODE
  : > "$STANDIN/release"
  LOCK_CODE=0; wait "$LOCK_PID" || LOCK_CODE=$?
}
scale_calls() { grep -c ' scale ' "$STANDIN/kubectl-calls.log" || true; }
patch_calls() { grep -c ' patch ' "$STANDIN/kubectl-calls.log" || true; }
lock_refuses() { # <the driver's text> [<scale|upload>] — holds a first run in its store loop, or in the upload of its archives, and starts a second: ends 0 when the second ended 75, named the first run's id and start, scaled nothing and made no folder, and the first ran to its end once let go; what is wrong stands in $OUT/verdict
  local text="$1" held="${2:-scale}" first_id started second scaled scaled_before patched patched_before
  : > "$OUT/verdict"
  if [ "$held" = upload ]; then lock_reset block-upload; else lock_reset block; fi
  lock_driver first "$text"; lock_driver second "$text"
  lock_start first; lock_held first
  first_id="$(ls "$LOCK_DIR/first/backups" 2> /dev/null | head -n 1 || true)"
  started="${first_id:0:4}-${first_id:4:2}-${first_id:6:2} ${first_id:9:2}:${first_id:11:2}:${first_id:13:2} UTC"
  [ -n "$first_id" ] || echo 'the first driver made no folder, so there is no run to name' >> "$OUT/verdict"
  scaled_before="$(scale_calls)"; patched_before="$(patch_calls)"
  lock_run second; second="$LOCK_CODE"
  scaled=$(( $(scale_calls) - scaled_before )); patched=$(( $(patch_calls) - patched_before ))
  lock_let_go
  [ "$second" = 75 ] || echo "the second driver ended with $second, not 75" >> "$OUT/verdict"
  { [ -n "$first_id" ] && grep -qF -- "$first_id" "$LOCK_DIR/second/err" && grep -qF -- "$started" "$LOCK_DIR/second/err"; } \
    || echo "the refusal did not name the running run $first_id, started $started: $(tail -n 1 "$LOCK_DIR/second/err")" >> "$OUT/verdict"
  [ "$scaled" = 0 ] || echo "the second driver scaled $scaled time(s) while the first held the stores" >> "$OUT/verdict"
  [ "$patched" = 0 ] || echo "the second driver patched $patched time(s) while the first held the queue" >> "$OUT/verdict"
  [ ! -e "$LOCK_DIR/second/backups" ] || echo 'the refused driver made a folder before it was refused' >> "$OUT/verdict"
  [ "$LOCK_CODE" = 0 ] || echo "the first driver ended with $LOCK_CODE once let go" >> "$OUT/verdict"
  [ "$(tail -n 1 "$LOCK_DIR/first/out")" = "BACKUP $first_id" ] || echo 'the first driver did not end with BACKUP and its id once let go' >> "$OUT/verdict"
  printed_wrong "$LOCK_DIR/first/out" "$LOCK_DIR/first/err" "$LOCK_DIR/second/out" "$LOCK_DIR/second/err" >> "$OUT/verdict"
  secrets_wrong "$STANDIN/secrets.seen" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
lock_frees_on_death() { # <the driver's text> — a first run is killed inside its store loop, and a second starts: ends 0 when the lock file stands and the second ended 0 with a backup of all the stores; what is wrong stands in $OUT/verdict
  local text="$1"
  : > "$OUT/verdict"
  lock_reset block
  lock_driver killed "$text"; lock_driver after "$text"
  lock_start killed; lock_held killed
  kill -KILL "$LOCK_PID"
  { wait "$LOCK_PID"; } 2> /dev/null || true
  : > "$STANDIN/release"; rm -f "$STANDIN/block-first-scale"
  secrets_wrong "$STANDIN/secrets.seen" > /dev/null
  [ -s "$LOCK_DIR/master-backup.lock" ] || echo 'the killed driver left no lock file with its record, so the case does not show a lock left behind' >> "$OUT/verdict"
  lock_run after
  if [ "$LOCK_CODE" != 0 ]; then
    echo "the driver started after the holder was killed ended with $LOCK_CODE: $(tail -n 1 "$LOCK_DIR/after/err")" >> "$OUT/verdict"
  elif [ "$(tail -n 1 "$LOCK_DIR/after/out" | cut -c1-7)" != 'BACKUP ' ]; then
    echo 'the driver started after the holder was killed did not end with BACKUP and an id' >> "$OUT/verdict"
  fi
  [ ! -s "$OUT/verdict" ]
}
lock_refused_by_hand() { # <the driver's text> <none|ended|killed> — a process that is no backup holds the lock file, as flock(1) with a command does, after no run, after a run that ended or after one that was killed, each of which leaves its record in the file: ends 0 when the driver ended 75 saying the record names no run that is alive, without naming the earlier run, before it scaled or made anything; what is wrong stands in $OUT/verdict
  local text="$1" earlier="$2" earlier_id='' holder _
  : > "$OUT/verdict"
  lock_reset free
  lock_driver by-hand "$text"
  case "$earlier" in
    ended)
      lock_driver earlier "$text"
      lock_run earlier
      [ "$LOCK_CODE" = 0 ] || fail "backup: the run that ends before the lock is held by hand ended with $LOCK_CODE: $(tail -n 2 "$LOCK_DIR/earlier/err")"
      earlier_id="$(tail -n 1 "$LOCK_DIR/earlier/out" | cut -d' ' -f2)" ;;
    killed)
      lock_reset block
      lock_driver earlier "$text"
      lock_start earlier; lock_held earlier
      earlier_id="$(ls "$LOCK_DIR/earlier/backups" | head -n 1)"
      kill -KILL "$LOCK_PID"
      { wait "$LOCK_PID"; } 2> /dev/null || true
      : > "$STANDIN/release"; rm -f "$STANDIN/block-first-scale" ;;
  esac
  if [ -n "$earlier_id" ]; then
    grep -qF -- "$earlier_id" "$LOCK_DIR/master-backup.lock" || fail "backup: the $earlier run left no record of its id in the lock file, so the case does not show a record left behind"
  fi
  : > "$STANDIN/kubectl-calls.log"
  ( exec 7<>"$LOCK_DIR/master-backup.lock"; flock -n 7 || exit 1; : > "$LOCK_DIR/held-by-hand"; exec sleep 60 ) &
  holder=$!
  for _ in $(seq 1 50); do [ -e "$LOCK_DIR/held-by-hand" ] && break; sleep 0.1; done
  [ -e "$LOCK_DIR/held-by-hand" ] || fail 'the case could not hold the lock file by hand'
  lock_run by-hand
  kill "$holder"; { wait "$holder"; } 2> /dev/null || true
  rm -f "$LOCK_DIR/held-by-hand"
  [ "$LOCK_CODE" = 75 ] || echo "the driver ended with $LOCK_CODE, not 75, on a lock held by hand: $(tail -n 1 "$LOCK_DIR/by-hand/err")" >> "$OUT/verdict"
  grep -qF 'its record is empty or names a run that is not alive' "$LOCK_DIR/by-hand/err" || echo "the refusal did not say that the record names no run that is alive: $(tail -n 1 "$LOCK_DIR/by-hand/err")" >> "$OUT/verdict"
  [ -z "$earlier_id" ] || ! grep -qF -- "$earlier_id" "$LOCK_DIR/by-hand/err" || echo "the refusal named the $earlier run $earlier_id, which does not hold the lock: $(tail -n 1 "$LOCK_DIR/by-hand/err")" >> "$OUT/verdict"
  [ "$(scale_calls)" = 0 ] || echo 'the driver scaled a store on a lock held by hand' >> "$OUT/verdict"
  [ ! -e "$LOCK_DIR/by-hand/backups" ] || echo 'the refused driver made a folder before it was refused' >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
LOCK_TEXT="$(cat "$HERE/master-backup-driver.sh")"
# The literal check of lock_driver on a text larger than a pipe buffer (64 KiB on Linux) that names the literal in its first line, so grep stops at its first read while a writer would still hold the rest.
LARGE_TEXT="$(awk 'BEGIN { print "/run/lock/master-backup.lock"; for (line = 1; line <= 2400; line++) print "readonly A_LINE_OF_THE_DRIVER_THAT_HOLDS_NO_LITERAL_" line }')"
[ "${#LARGE_TEXT}" -ge 131072 ] || fail "backup: the text of the literal check is ${#LARGE_TEXT} bytes, not larger than 128 KiB"
for _ in $(seq 1 3000); do
  driver_names_literal "$LARGE_TEXT" /run/lock/master-backup.lock \
    || fail "backup: the literal check reported /run/lock/master-backup.lock missing from a text of ${#LARGE_TEXT} bytes that names it in its first line"
done
CUT_OFF=0
for _ in $(seq 1 3000); do
  printf '%s\n' "$LARGE_TEXT" | grep -qF -- /run/lock/master-backup.lock || { CUT_OFF=1; break; }
done
[ "$CUT_OFF" = 1 ] || fail 'backup: the planted pipe into grep -q was not cut off once in 3000 checks of a text larger than a pipe buffer — the case proves nothing'
if ( lock_driver without-lock "${LOCK_TEXT//\/run\/lock\/master-backup.lock/}" ) 2> "$OUT/without-lock.err"; then
  fail 'backup: a driver text without /run/lock/master-backup.lock was taken for a sandbox of the lock cases'
fi
grep -qF 'the backup driver names no /run/lock/master-backup.lock — the sandbox of the lock cases proves nothing' "$OUT/without-lock.err" \
  || fail "backup: a driver text without /run/lock/master-backup.lock was refused for another reason: $(cat "$OUT/without-lock.err")"
ok 'backup: the literal check of the lock cases found the literal in a text of 128 KiB 3000 times, the planted pipe into grep -q was cut off, and a driver text without /run/lock/master-backup.lock is still refused'
lock_refuses "$LOCK_TEXT" || fail "backup: a second driver was not refused while the first held the stores: $(cat "$OUT/verdict")"
lock_refuses "$LOCK_TEXT" upload || fail "backup: a second driver was not refused while the first uploaded its archives, after its store loop: $(cat "$OUT/verdict")"
for earlier in none ended killed; do
  lock_refused_by_hand "$LOCK_TEXT" "$earlier" || fail "backup: a lock held by hand (earlier run: $earlier) was not refused with a record that names no run: $(cat "$OUT/verdict")"
done
lock_frees_on_death "$LOCK_TEXT" || fail "backup: a lock left by a killed driver blocked the next one: $(cat "$OUT/verdict")"
# innocent: two runs one after the other both pass, each stopping and starting every store
lock_reset free
lock_driver one "$LOCK_TEXT"; lock_driver two "$LOCK_TEXT"
lock_run one; [ "$LOCK_CODE" = 0 ] || fail "backup: a first run alone ended with $LOCK_CODE: $(tail -n 2 "$LOCK_DIR/one/err")"
[ -e "$LOCK_DIR/master-backup.lock" ] || fail 'backup: the lock file is not left on disk after a run, so the case does not show that a file left behind does not block'
lock_run two; [ "$LOCK_CODE" = 0 ] || fail "backup: a run after a finished run was refused or failed, ended with $LOCK_CODE: $(tail -n 2 "$LOCK_DIR/two/err")"
[ "$(scale_calls)" = "$(( 4 * LOCK_STORES ))" ] || fail "backup: two runs one after the other did not stop and start every one of the $LOCK_STORES stores twice: $(scale_calls) scale call(s)"
printed_wrong "$LOCK_DIR/one/out" "$LOCK_DIR/one/err" "$LOCK_DIR/two/out" "$LOCK_DIR/two/err" > "$OUT/verdict"
[ ! -s "$OUT/verdict" ] || fail "backup: a whole run printed a planted line: $(cat "$OUT/verdict")"
secrets_wrong "$STANDIN/secrets.seen" > "$OUT/verdict"
[ ! -s "$OUT/verdict" ] || fail "backup: a whole run left its secrets wrong: $(cat "$OUT/verdict")"
ok 'backup: a second driver started while the first holds the stores, or uploads its archives, is refused with 75, naming the first run, before it scales or makes anything, and so is one that finds the lock held by hand, which it does not name a run for, whether the file holds no record or the record of a run that ended or was killed; a killed holder and a finished run leave a lock file that does not block; no run prints a planted line'

# planted defects: the lock lines removed, the lock taken after the folder is made, the lock file opened for
# writing (which wipes the record of the run that holds it), a lock that is the file's presence (which a
# killed holder leaves behind), a lock let go of after the store loop, a record trusted without the process it
# names (which a run that ended or was killed leaves behind), and a record never trusted
LOCK_LINES="$(printf '%s\n' "$LOCK_TEXT" | sed -n '/^exec 9<>/,/^fi$/p')"
[ -n "$LOCK_LINES" ] || fail 'the backup driver carries no lock lines — the planted defects cannot be built'
INSTALL_LINE='root install -d -m 700 -o root -g root /var/lib/master-backup "$WORK" || die "could not make $WORK" 78'
NO_LOCK="${LOCK_TEXT/"$LOCK_LINES"/true}"
[ "$NO_LOCK" != "$LOCK_TEXT" ] || fail 'the planted driver without the lock was not planted — the probe proves nothing'
LATE_LOCK="${NO_LOCK/"$INSTALL_LINE"/"$INSTALL_LINE"$'\n'"$LOCK_LINES"}"
[ "$LATE_LOCK" != "$NO_LOCK" ] || fail 'the planted driver with the lock after the folder was not planted — the probe proves nothing'
plant "$LOCK_TEXT" 'exec 9<>"$LOCK_FILE"' 'exec 9>"$LOCK_FILE"'; TRUNCATING_LOCK="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'flock -n -E 75 9 || LOCKED=$?' '[ ! -s "$LOCK_FILE" ] || LOCKED=75'; FILE_AS_LOCK="$PLANTED_TEXT"
plant "$LOCK_TEXT" ' && [ "/proc/$HOLDER_PID/fd/9" -ef "$LOCK_FILE" ]' ''; TRUSTS_RECORD="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'step "the host'"'"'s own file"' $'exec 9>&-\nstep "the host\'s own file"'; LETS_GO_EARLY="$PLANTED_TEXT"
plant "$LOCK_TEXT" '[ "/proc/$HOLDER_PID/fd/9" -ef "$LOCK_FILE" ]' 'false'; NEVER_TRUSTS_RECORD="$PLANTED_TEXT"
! lock_refuses "$NO_LOCK" || fail 'the planted driver without the lock was not caught — the probe proves nothing'
caught_for 'driver without the lock' 'the second driver scaled' 'the second driver patched' 'the second driver ended with 0' 'did not name the running run' 'made a folder'
! lock_refuses "$LATE_LOCK" || fail 'the planted driver that takes the lock after it made its folder was not caught — the probe proves nothing'
caught_for 'driver that takes the lock after it made its folder' 'made a folder'
! lock_refuses "$TRUNCATING_LOCK" || fail 'the planted driver that opens the lock file for writing was not caught — the probe proves nothing'
caught_for 'driver that opens the lock file for writing' 'did not name the running run'
lock_precedes_provisioning() { # <the driver's text> — a first run holds the lock inside its store loop, then the machine's rclone is old and a second run starts: ends 0 when the second ended 75 without a request for a package or an installation, and the first went on to its end; what is wrong stands in $OUT/verdict
  local text="$1"
  : > "$OUT/verdict"
  lock_reset block
  lock_driver first "$text"; lock_driver second "$text"
  lock_start first; lock_held first
  echo 'rclone v1.60.1-DEV' > "$STANDIN/rclone-answer"; : > "$STANDIN/dpkg.log"; : > "$STANDIN/curl.log"
  lock_run second
  printf 'rclone %s\n- os/version: stand-in\n' "$RCLONE_PIN_OF_TREE" > "$STANDIN/rclone-answer"
  [ "$LOCK_CODE" = 75 ] || echo "the second driver ended with $LOCK_CODE, not 75, on an old rclone while the first held the lock" >> "$OUT/verdict"
  [ ! -s "$STANDIN/curl.log" ] || echo 'the second driver asked for a package while the first held the lock' >> "$OUT/verdict"
  ! grep -q '^dpkg -i ' "$STANDIN/dpkg.log" || echo 'the second driver installed a package while the first held the lock' >> "$OUT/verdict"
  lock_let_go
  [ "$LOCK_CODE" = 0 ] || echo "the first driver ended with $LOCK_CODE once let go" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
lock_precedes_provisioning "$LOCK_TEXT" || fail "backup: a second driver reached the provisioning of rclone while the first held the lock: $(cat "$OUT/verdict")"
plant "$LOCK_TEXT" 'LOCK_FILE=/run/lock/master-backup.lock' 'require_rclone || die "rclone could not be provided: $RCLONE_REFUSAL" 69
LOCK_FILE=/run/lock/master-backup.lock'; PROVISIONING_BEFORE_LOCK="$PLANTED_TEXT"
! lock_precedes_provisioning "$PROVISIONING_BEFORE_LOCK" || fail 'the planted driver that provisions rclone before it takes the lock was not caught — the probe proves nothing'
ok 'backup: a second driver started while the first holds the lock, on a machine whose rclone is old, ends 75 before it asks for a package or installs one, and the first goes on to its end; a driver that provisions rclone before it takes the lock is caught'
! lock_frees_on_death "$FILE_AS_LOCK" || fail 'the planted driver whose lock is the presence of a file was not caught — the probe proves nothing'
caught_for 'driver whose lock is the presence of a file' 'ended with 75'
for earlier in ended killed; do
  ! lock_refused_by_hand "$TRUSTS_RECORD" "$earlier" || fail "the planted driver that trusts the record of a run that $earlier was not caught — the probe proves nothing"
  caught_for "driver that trusts the record of a run that $earlier" 'the refusal named the' 'did not say that the record names no run'
done
lock_refuses "$LETS_GO_EARLY" || fail 'the planted driver that lets go of the lock after its store loop was refused while the first held the stores, so the case that holds the upload adds nothing'
! lock_refuses "$LETS_GO_EARLY" upload || fail 'the planted driver that lets go of the lock after its store loop was not caught while the first uploaded — the probe proves nothing'
caught_for 'driver that lets go of the lock after its store loop' 'the second driver scaled' 'the second driver patched' 'the second driver ended with 0' 'did not name the running run' 'made a folder'
! lock_refuses "$NEVER_TRUSTS_RECORD" || fail 'the planted driver that never trusts the record was not caught — the probe proves nothing'
caught_for 'driver that never trusts the record' 'did not name the running run'
ok 'the planted drivers are caught: no lock, a lock taken after the folder, a lock file opened for writing, a lock that is the presence of a file, a lock let go of after the store loop, a record trusted without the process it names, a record never trusted'

# ── the Manager's runs are held while the stores are taken ──────────────────────────────────────────
# A run of the Manager that is in flight while a store it reads is stopped fails, and a failed run keeps its locks. So the
# driver suspends the release queue, waits until no job of the queue and no release or publish run runs, stops the Manager,
# takes the stores, and starts the Manager and lets the queue go only once every store it stopped reads ready. The cases run
# the whole driver against the microk8s stand-in, which keeps the cluster's state, and read the world each scale and patch
# was made in from its world.log: a store other than the Manager scaled to 0 while the Manager stands above 0, while the
# queue is not held, while the planted run still reads running or while the planted Job of the queue is unfinished; the
# Manager started or the queue let go while a store this run stopped is not back and ready; and a run that ends with the
# Manager at 0 or the queue held although every store is back and ready, are each red.
for named in QUEUE_POLL_SECONDS QUEUE_WAIT_SECONDS STORE_POLL_SECONDS STORE_WAIT_SECONDS READBACK_WAIT_SECONDS READBACK_POLL_SECONDS READBACK_REPORT_SECONDS READBACK_GRACE_SECONDS READBACK_FINISH_SECONDS READBACK_SLOWDOWN_FACTOR; do
  grep -q "^readonly $named=[0-9]" "$HERE/master-backup-driver.sh" || fail "the backup driver names no $named on a line of its own — the hold cases cannot move its wait into the sandbox"
done
hold_run() { # <the driver's text> [<knob>...] — the stand-ins forget the last case and take the knobs, then the whole driver runs once; its code stands in $LOCK_CODE. A knob is NAME (the file knob-NAME), NAME=content (the file of cluster/ so named), copy-fails=<ns>-<claim> (the copy of that store fails) or a NAME=value of the driver, which a shortened wait is
  local text="$1" knob timings=()
  shift
  lock_reset free
  find "$LOCK_DIR/storage" -name fails -delete
  mkdir -p "$STANDIN/cluster"
  for knob in "$@"; do
    case "$knob" in
      QUEUE_*=*|STORE_*=*) timings+=("$knob") ;;
      copy-fails=*) : > "$(ls -d "$LOCK_DIR/storage/${knob#*=}-pvc-"* | head -n 1)/fails" ;;
      *=*) printf '%s\n' "${knob#*=}" > "$STANDIN/cluster/${knob%%=*}" ;;
      *) : > "$STANDIN/cluster/knob-$knob" ;;
    esac
  done
  lock_driver hold "$text" ${timings[@]+"${timings[@]}"}
  lock_run hold
  find "$LOCK_DIR/storage" -name fails -delete
}
box_account_wrong() { # <standard output file> <standard error file> — says on which stream the host and the user of the fixture stand; ends 0
  grep -qF -- "$BOX_HOST" "$1" && echo 'the host of the box stands on standard output'
  grep -qF -- "$BOX_HOST" "$2" && echo 'the host of the box stands on standard error'
  grep -qF -- "$BOX_USER" "$1" && echo 'the user of the box stands on standard output'
  grep -qF -- "$BOX_USER" "$2" && echo 'the user of the box stands on standard error'
  return 0
}
hold_wrong() { # <the Manager's replicas before the run> <the queue's suspend before the run> — says what is wrong with the world the last run left, in the order it was made; ends 0
  local world="$STANDIN/cluster/world.log" file name replicas ready back=1
  [ ! -f "$world" ] || awk '
    { split("", f); for (i = 2; i <= NF; i++) { k = $i; sub(/=.*/, "", k); v = $i; sub(/^[^=]*=/, "", v); f[k] = v }
      if ($1 == "scale" && f["to"] == 0 && f["target"] != "manager/manager") {
        if (f["manager"] > 0) print "a store other than the Manager was scaled to 0 while the Manager stood above 0: " f["target"]
        if (f["suspend"] != "true") print "a store other than the Manager was scaled to 0 while the queue was not held: " f["target"]
        if (f["run"] == "running") print "a store other than the Manager was scaled to 0 while the planted run still read running: " f["target"]
        if (f["job"] == "unfinished") print "a store other than the Manager was scaled to 0 while the planted job of the queue was unfinished: " f["target"]
      }
      if ($1 == "scale" && f["target"] == "manager/manager" && f["to"] > 0 && f["others"] != "none")
        print "the Manager was started while these stores were not back and ready: " f["others"]
      if ($1 == "patch" && f["to"] != "true" && f["others"] != "none")
        print "the queue was let go while these stores were not back and ready: " f["others"]
    }' "$world"
  for file in "$STANDIN"/cluster/*.replicas; do
    [ -e "$file" ] || continue
    name="$(basename "$file" .replicas)"
    case "$name" in manager--*) continue ;; esac
    replicas="$(cat "$file")"; ready="$(cat "$STANDIN/cluster/$name.ready" 2> /dev/null || echo "$replicas")"
    if [ "$replicas" -lt 1 ] || [ "$ready" -lt 1 ]; then back=0; fi
  done
  if [ "$back" = 1 ]; then
    replicas="$(cat "$STANDIN/cluster/manager--manager.replicas" 2> /dev/null || echo 1)"
    [ "$replicas" = "$1" ] || echo "the run ended with the Manager at $replicas, although it stood at $1 before it and every store is back and ready"
    ready="$(cat "$STANDIN/cluster/suspend" 2> /dev/null || echo false)"
    [ "$ready" = "$2" ] || echo "the run ended with the queue at suspend=$ready, although it stood at $2 before the run and every store is back and ready"
  fi
  return 0
}
hold_holds() { # <the driver's text> <the Manager's replicas before> <the queue's suspend before> [<knob>...] — ends 0 when the run ended 0 with a backup and left nothing wrong in the world, and printed nothing planted; what is wrong stands in $OUT/verdict
  local text="$1" manager="$2" suspend="$3"
  shift 3
  hold_run "$text" "$@"
  hold_wrong "$manager" "$suspend" > "$OUT/verdict"
  [ "$LOCK_CODE" = 0 ] || echo "the run ended with $LOCK_CODE: $(tail -n 2 "$LOCK_DIR/hold/err" | tr '\n' ' ')" >> "$OUT/verdict"
  [ "$(tail -n 1 "$LOCK_DIR/hold/out" | cut -c1-7)" = 'BACKUP ' ] || echo 'the run did not end with BACKUP and an id' >> "$OUT/verdict"
  printed_wrong "$LOCK_DIR/hold/out" "$LOCK_DIR/hold/err" >> "$OUT/verdict"
  secrets_wrong "$STANDIN/secrets.seen" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
hold_refused() { # <the driver's text> <the Manager's replicas before> <the queue's suspend before> <the code> <what the output says> [<knob>...] — ends 0 when the run ended with that code, said that, and left nothing wrong in the world; what is wrong stands in $OUT/verdict
  local text="$1" manager="$2" suspend="$3" code="$4" said="$5"
  shift 5
  hold_run "$text" "$@"
  hold_wrong "$manager" "$suspend" > "$OUT/verdict"
  [ "$LOCK_CODE" = "$code" ] || echo "the run ended with $LOCK_CODE, not $code: $(tail -n 2 "$LOCK_DIR/hold/err" | tr '\n' ' ')" >> "$OUT/verdict"
  hold_says "$said" || echo "the run did not say: $said" >> "$OUT/verdict"
  printed_wrong "$LOCK_DIR/hold/out" "$LOCK_DIR/hold/err" >> "$OUT/verdict"
  if [ -s "$STANDIN/secrets.seen" ]; then secrets_wrong "$STANDIN/secrets.seen" >> "$OUT/verdict"; fi
  [ ! -s "$OUT/verdict" ]
}
hold_says() { grep -qF -- "$1" "$LOCK_DIR/hold/out" "$LOCK_DIR/hold/err"; } # the last run printed that, to its output or its error

# the whole driver, with a release run that runs for two looks: the queue is held and the run waited for before the Manager and the stores stop
hold_holds "$LOCK_TEXT" 1 false run-running || fail "backup: a run of the queue in flight was not waited for: $(cat "$OUT/verdict")"
hold_says 'waiting for run hostyour-manager-build/hostyour-manager-release-live to end' \
  || fail 'backup: the driver did not name the running release run it waited for'
grep -qE 'waiting for (run hostyour-manager-build/hostyour-manager-(release-done|publish-waiting|publish-done)|job image-builder/(release-queue-29874554|unrelated-job))' "$LOCK_DIR/hold/out" \
  && fail 'backup: the driver waited for a run that ended, a run that waits on the queue, a Job that finished or a Job of another CronJob'
[ "$(grep -c ' scale ' "$STANDIN/kubectl-calls.log")" = "$(( 2 * LOCK_STORES ))" ] || fail "backup: the run did not stop and start each of the $LOCK_STORES stores once: $(scale_calls) scale call(s)"
[ "$(patch_calls)" = 2 ] || fail 'backup: the run did not hold the queue once and let it go once'
# the order the operator reads: the queue held, the Manager stopped, each store ready, the Manager started, the queue let go
HOLD_ORDER="$(sed -nE 's#.*(is held|manager/deployment/manager stopped|reads ready|manager/deployment/manager started again|is let go).*#\1#p' "$LOCK_DIR/hold/out" | uniq | tr '\n' ',')"
[ "$HOLD_ORDER" = 'is held,manager/deployment/manager stopped,reads ready,manager/deployment/manager started again,is let go,' ] \
  || fail "backup: the lines of the hold are not in the order held, stopped, ready, started, let go: $HOLD_ORDER"
hold_says 'idp/statefulset/idp-postgresql reads ready: 1 of 1' || fail 'backup: the driver did not read idp-postgresql ready'
hold_says 'vault/statefulset/vault reads ready: 1 of 1' || fail 'backup: the driver did not read vault/vault ready, the store rollout status refuses'
# a Job of the queue that the CronJob creates just after a look, and names active one look later than the Jobs list it
hold_holds "$LOCK_TEXT" 1 false late-job || fail "backup: a late Job of the queue was not waited for: $(cat "$OUT/verdict")"
hold_says 'waiting for job image-builder/release-queue-late to end' || fail 'backup: the driver did not name the late Job it waited for'
# innocents: the Manager at 0 and no run of the queue to wait for, the queue suspended before the run
hold_holds "$LOCK_TEXT" 0 false manager--manager.replicas=0 || fail "backup: a Manager at 0 changed the backup of the stores: $(cat "$OUT/verdict")"
[ "$(cat "$STANDIN/cluster/manager--manager.replicas")" = 0 ] || fail 'backup: a Manager that stood at 0 was started by the run'
[ "$(scale_calls)" = "$(( 2 * LOCK_STORES ))" ] || fail "backup: with the Manager at 0 the stores were not taken as before: $(scale_calls) scale call(s)"
hold_holds "$LOCK_TEXT" 1 true suspend=true || fail "backup: a queue suspended before the run was not left suspended: $(cat "$OUT/verdict")"
[ "$(cat "$STANDIN/cluster/suspend")" = true ] || fail 'backup: a queue that was suspended before the run was let go by it'
# a store that is stopped when its copy fails is started again and the hold is let go, a store that cannot be started again is not hidden
hold_refused "$LOCK_TEXT" 1 false 70 'the copy of mongodb/data-mongodb-prod-1 failed; mongodb-prod was started again with 1 replica(s)' copy-fails=mongodb-data-mongodb-prod-1 \
  || fail "backup: the failed copy of a later store left the hold on, or lost the store: $(cat "$OUT/verdict")"
[ "$(cat "$STANDIN/cluster/manager--manager.replicas")" = 1 ] || fail 'backup: the Manager was not started again after a failed copy of a later store'
hold_refused "$LOCK_TEXT" 1 false 70 'could not be started again — it stands at 0 replicas' copy-fails=idp-data-idp-postgresql-0 knob-scale-fails=idp/idp-postgresql \
  || fail "backup: a store whose scale back failed was not named or the Manager was started under it: $(cat "$OUT/verdict")"
[ "$(cat "$STANDIN/cluster/manager--manager.replicas")" = 0 ] && [ "$(cat "$STANDIN/cluster/suspend")" = true ] \
  || fail 'backup: the Manager was started or the queue let go while a store stood at 0'
hold_says 'these stores were asked to stop and do not read the replicas they had: idp/statefulset/idp-postgresql reads 0 replica(s) of the 1 it had' || fail 'backup: the driver did not name the store at 0 with the replicas the cluster reads'
# a scale to 0 that fails and changes nothing leaves a store that runs: it is read as it is, and the Manager and the queue go
hold_refused "$LOCK_TEXT" 1 false 70 'could not stop idp/idp-postgresql' knob-stop-fails=idp/idp-postgresql \
  || fail "backup: a store whose scale to 0 failed and changed nothing kept the Manager stopped and the queue held: $(cat "$OUT/verdict")"
hold_says 'idp/statefulset/idp-postgresql reads ready: 1 of 1' || fail 'backup: the driver did not read the store whose stop failed as it stands'
! hold_says 'asked to stop' || fail 'backup: the driver called a store at 0 that still ran'
[ "$(cat "$STANDIN/cluster/manager--manager.replicas")" = 1 ] && [ "$(cat "$STANDIN/cluster/suspend")" = false ] \
  || fail 'backup: a store that still ran after its failed stop left the Manager stopped or the queue held'
# a scale to 0 that took effect and whose answer was lost leaves a store at 0: it is named with what the cluster reads, and nothing starts
hold_refused "$LOCK_TEXT" 1 false 70 'could not stop idp/idp-postgresql' knob-stop-lost=idp/idp-postgresql \
  || fail "backup: a store whose stop took effect and whose answer was lost was not refused as it must be: $(cat "$OUT/verdict")"
hold_says 'these stores were asked to stop and do not read the replicas they had: idp/statefulset/idp-postgresql reads 0 replica(s) of the 1 it had' || fail 'backup: the driver did not name the store whose stop took effect'
[ "$(cat "$STANDIN/cluster/manager--manager.replicas")" = 0 ] && [ "$(cat "$STANDIN/cluster/suspend")" = true ] \
  || fail 'backup: the Manager was started or the queue let go while a store stood at 0 after a lost answer'
# a store that does not read ready: neither the Manager nor the queue is let go, the store is named with the two commands, nothing is uploaded
hold_refused "$LOCK_TEXT" 1 false 70 'idp/statefulset/idp-postgresql reads 0 ready replica(s) of the 1 it had' knob-not-ready=idp/idp-postgresql STORE_WAIT_SECONDS=1 \
  || fail "backup: a store that does not read ready was not refused as it must be: $(cat "$OUT/verdict")"
hold_says 'microk8s kubectl -n manager scale deployment/manager --replicas=1' || fail 'backup: the refusal did not print the command that starts the Manager'
hold_says "microk8s kubectl -n image-builder patch cronjob/release-queue --type=merge -p '{\"spec\":{\"suspend\":false}}'" || fail 'backup: the refusal did not print the command that lets the queue go'
[ "$(cat "$STANDIN/cluster/manager--manager.replicas")" = 0 ] && [ "$(cat "$STANDIN/cluster/suspend")" = true ] || fail 'backup: a store that did not read ready did not keep the Manager stopped and the queue held'
[ ! -d "$STANDIN/box-uploaded" ] || fail 'backup: a store that did not read ready did not stop the upload'
[ -n "$(ls -A "$LOCK_DIR/hold/backups")" ] || fail 'backup: the archives of a refused release do not stand on the machine'
# no CronJob release-queue: refused before anything is held or stopped
hold_refused "$LOCK_TEXT" 1 false 66 'the CronJob image-builder/release-queue is not in the cluster' no-cronjob \
  || fail "backup: a cluster with no release queue was not refused as it must be: $(cat "$OUT/verdict")"
[ "$(scale_calls)" = 0 ] && [ "$(patch_calls)" = 0 ] || fail 'backup: a driver refused for want of the queue scaled or patched'
# a run of the queue that never ends: past the limit the queue is let go again, nothing is stopped, and the run says what still runs
hold_refused "$LOCK_TEXT" 1 false 75 'still has: run hostyour-manager-build/hostyour-manager-release-stuck' run-forever QUEUE_WAIT_SECONDS=2 \
  || fail "backup: a release run that never ends was not given up on as it must be: $(cat "$OUT/verdict")"
[ "$(scale_calls)" = 0 ] && [ "$(patch_calls)" = 2 ] && [ "$(cat "$STANDIN/cluster/suspend")" = false ] || fail 'backup: past its limit the driver did not stop nothing and let the queue go'

# the limit stays above what a run that runs can last: the pipelines' own timeout
timeout_seconds() { sed -nE 's/^ +pipeline: ([0-9]+)h([0-9]+)m([0-9]+)s$/\1 \2 \3/p' "$HERE/../clusters/inventories/image-builder/templates/triggers/$1" | { read -r h m sec || true; echo $(( ${h:-0} * 3600 + ${m:-0} * 60 + ${sec:-0} )); }; }
limit_above_timeouts() { # <the driver's text> — ends 0 when its QUEUE_WAIT_SECONDS is above the timeout of both pipelines; what is wrong stands in $OUT/verdict
  local limit file timeout
  : > "$OUT/verdict"
  limit="$(printf '%s\n' "$1" | sed -n 's/^readonly QUEUE_WAIT_SECONDS=//p')"
  for file in github-deploy-request.yaml github-release-publish.yaml; do
    timeout="$(timeout_seconds "$file")"
    [ "$timeout" -gt 0 ] || echo "no timeouts.pipeline stands in $file" >> "$OUT/verdict"
    [ "$limit" -gt "$timeout" ] || echo "the driver waits ${limit} s, which is not above the ${timeout} s a run of $file can last" >> "$OUT/verdict"
  done
  [ ! -s "$OUT/verdict" ]
}
limit_above_timeouts "$LOCK_TEXT" || fail "backup: the wait of the hold is not above the timeout of the pipelines: $(cat "$OUT/verdict")"
plant "$LOCK_TEXT" 'readonly QUEUE_WAIT_SECONDS=3900' 'readonly QUEUE_WAIT_SECONDS=3600'; SHORT_LIMIT="$PLANTED_TEXT"
! limit_above_timeouts "$SHORT_LIMIT" || fail 'the planted wait that is not above the pipelines'"'"' timeout was not caught — the probe proves nothing'
caught_for 'wait that is not above the pipelines'"'"' timeout' 'is not above the'

# the holds stand against a sync: Argo CD keeps the replicas of the Manager's Deployment and the suspend of the queue where the driver put them
hold_row_wrong() { # <app.yaml> <kind> <name> <pointer> — says what is wrong with the rule that keeps that field from a sync; ends 0
  local rows
  [ "$(yq '.respectIgnoreDifferences' "$1")" = true ] || echo "$1 does not set respectIgnoreDifferences to true, so a sync writes the ignored field all the same"
  rows="$(yq '.ignoreDifferences | from_yaml | .[] | select(.kind == "'"$2"'" and .name == "'"$3"'") | .jsonPointers[]' "$1" 2> /dev/null || true)"
  grep -qxF -- "$4" <<< "$rows" || echo "$1 has no rule that keeps $4 of the $2 $3"
  return 0
}
hold_rows_wrong() { # <the Manager's app.yaml> <the image-builder's app.yaml> — what is wrong with the two rules; ends 0
  hold_row_wrong "$1" Deployment "$(printf '%s\n' "$LOCK_TEXT" | sed -n 's/^  "manager|manager-data|\([a-z]*\)|.*/\1/p')" /spec/replicas
  hold_row_wrong "$2" CronJob "$(printf '%s\n' "$LOCK_TEXT" | sed -n 's/^readonly QUEUE_CRONJOB=//p')" /spec/suspend
}
HOLD_APPS="$HERE/../clusters/inventories"
hold_rows_wrong "$HOLD_APPS/manager/app.yaml" "$HOLD_APPS/image-builder/app.yaml" > "$OUT/verdict"
[ ! -s "$OUT/verdict" ] || fail "backup: the two holds do not stand against a sync: $(cat "$OUT/verdict")"
mkdir -p "$WORK/hold-apps"
grep -v '^respectIgnoreDifferences:' "$HOLD_APPS/manager/app.yaml" > "$WORK/hold-apps/manager-no-respect.yaml"
sed '/^ignoreDifferences:/,$d' "$HOLD_APPS/manager/app.yaml" > "$WORK/hold-apps/manager-no-row.yaml"
sed 's#/spec/suspend#/spec/schedule#' "$HOLD_APPS/image-builder/app.yaml" > "$WORK/hold-apps/builder-other-field.yaml"
sed '/^ignoreDifferences:/,$d' "$HOLD_APPS/image-builder/app.yaml" > "$WORK/hold-apps/builder-no-row.yaml"
hold_rows_wrong "$WORK/hold-apps/manager-no-respect.yaml" "$HOLD_APPS/image-builder/app.yaml" > "$OUT/verdict"
caught_for "Manager's app.yaml without respectIgnoreDifferences" 'does not set respectIgnoreDifferences to true'
hold_rows_wrong "$WORK/hold-apps/manager-no-row.yaml" "$HOLD_APPS/image-builder/app.yaml" > "$OUT/verdict"
caught_for "Manager's app.yaml without the row" 'does not set respectIgnoreDifferences to true' 'has no rule that keeps /spec/replicas'
hold_rows_wrong "$HOLD_APPS/manager/app.yaml" "$WORK/hold-apps/builder-other-field.yaml" > "$OUT/verdict"
caught_for "image-builder's app.yaml with the row for another field" 'has no rule that keeps /spec/suspend'
hold_rows_wrong "$HOLD_APPS/manager/app.yaml" "$WORK/hold-apps/builder-no-row.yaml" > "$OUT/verdict"
caught_for "image-builder's app.yaml without the row" 'does not set respectIgnoreDifferences to true' 'has no rule that keeps /spec/suspend'
ok 'backup: the queue is held and the running release and publish runs and the Jobs of the queue are waited for (a late Job too) before the Manager and the stores stop; the Manager is started and the queue let go only after every store reads ready, vault/vault among them; a Manager at 0 stays at 0 and a queue suspended before the run stays suspended; a failed copy lets the hold go, a store that cannot be started or does not read ready keeps it and is named with the two commands; a cluster with no release queue is refused before anything is held; a run that never ends is given up on after a limit above the pipelines'"'"' timeout; the two app.yaml rows keep a sync from undoing either hold'

# planted defects, each in a copy of the driver, each of which a case above must turn red: today's order with no hold at all; the queue
# held but the running run not read; the wait left out, so the Manager is stopped before the running run ended and the stores right after;
# the wait ended on one quiet pass; the wait that reads the CronJob's active list alone; the Manager started in the store loop, before the
# last store; the queue let go in the store loop, before the last store; a release that reads readiness by rollout status, which kubectl
# refuses for vault/vault; an exit that does not release what the run holds; a failed copy that forgets the store it could not start
# again; a release that does not read the stores ready; a release that lets the queue go before it read the stores ready, with the
# Manager never started; a release that trusts its record of the stopped stores instead of the cluster
HOLD_BLOCK="$(printf '%s\n' "$LOCK_TEXT" | sed -n '/^step "the Manager.s runs, held"/,/^good "manager\/${MANAGER_KIND}\/${MANAGER_WORKLOAD} stopped/p')"
[ -n "$HOLD_BLOCK" ] || fail 'the backup driver carries no hold — the planted defects cannot be built'
READY_LINE="$(printf '%s\n' "$LOCK_TEXT" | grep '^ready_of() ')"
RELEASE_CALL='release_hold || die "the Manager and the queue were not let go; the archives stand in $WORK on this machine" 70'
STARTS_MANAGER_LATE='    say "${ns}/${workload} stays stopped until every other store is back"'
plant "$LOCK_TEXT" "$HOLD_BLOCK" "STOPPED='' STARTED=''"; NO_HOLD="$PLANTED_TEXT"
plant "$NO_HOLD" 'if [ "$ns" = manager ]; then' 'if false; then'; NO_HOLD="$PLANTED_TEXT"
plant "$NO_HOLD" "$RELEASE_CALL" 'true'; NO_HOLD="$PLANTED_TEXT"
plant "$LOCK_TEXT" '"$active" "$jobs" "$runs"' '"$active" "$jobs" ""'; RUN_NOT_READ="$PLANTED_TEXT"
plant "$LOCK_TEXT" $'\nwait_for_queue\n' $'\n'; NO_WAIT="$PLANTED_TEXT"
plant "$LOCK_TEXT" '[ "$quiet" -ge 2 ] && break' '[ "$quiet" -ge 1 ] && break'; ONE_QUIET_PASS="$PLANTED_TEXT"
plant "$LOCK_TEXT" '"$active" "$jobs" "$runs"' '"$active" "" ""'; ACTIVE_ALONE="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$STARTS_MANAGER_LATE" '    start_store manager "$MANAGER_WORKLOAD" "$MANAGER_KIND" "$MANAGER_WAS"'; MANAGER_EARLY="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$STARTS_MANAGER_LATE" '    K -n "$QUEUE_NAMESPACE" patch "cronjob/$QUEUE_CRONJOB" --type=merge -p "{\"spec\":{\"suspend\":${QUEUE_WAS}}}" >/dev/null'; QUEUE_EARLY="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$READY_LINE" 'ready_of() { if K -n "$1" rollout status "$3/$2" --timeout=180s >/dev/null 2>&1; then replicas_of "$1" "$2" "$3"; else echo 0; fi; }'; READY_BY_ROLLOUT="$PLANTED_TEXT"
plant "$LOCK_TEXT" '[ -z "$HELD" ] || release_hold || true; ' ''; EXIT_KEEPS_HOLD="$PLANTED_TEXT"
plant "$LOCK_TEXT" '    die "the copy of ${ns}/${pvc} failed, and' $'    STOPPED=\'\'; die "the copy of ${ns}/${pvc} failed, and'; FORGETS_STORE="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$READY_LINE" 'ready_of() { echo 99; }'; NEVER_NOT_READY="$PLANTED_TEXT"
plant "$LOCK_TEXT" $'  for row in $STARTED; do\n' $'  K -n "$QUEUE_NAMESPACE" patch "cronjob/$QUEUE_CRONJOB" --type=merge -p "{\\"spec\\":{\\"suspend\\":${QUEUE_WAS}}}" >/dev/null\n  for row in $STARTED; do\n'; LET_GO_FIRST="$PLANTED_TEXT"
plant "$LOCK_TEXT" '    got=$(replicas_of "$ns" "$workload" "$kind")
    if [ "$got" -ge "$want" ]' '    got=0
    if [ "$got" -ge "$want" ]'; TRUSTS_RECORD="$PLANTED_TEXT"
hold_caught() { # <the name of the planted defect> <the driver's text> <the knobs> -> <what the verdict must say first> [<what else it may say>...]
  local name="$1" text="$2" knobs="$3"
  shift 3
  # shellcheck disable=SC2086 # the knobs are words
  ! hold_holds "$text" 1 false $knobs || fail "the planted driver with $name was not caught — the probe proves nothing"
  caught_for "driver with $name" "$@"
}
hold_caught 'no hold' "$NO_HOLD" run-running 'while the Manager stood above 0' 'while the queue was not held' 'while the planted run still read running'
hold_caught 'the running run not read' "$RUN_NOT_READ" run-running 'while the planted run still read running'
hold_caught 'no wait, so the Manager stops before the running run ended and the stores right after' "$NO_WAIT" run-running 'while the planted run still read running'
hold_caught 'the wait ended on one quiet pass' "$ONE_QUIET_PASS" late-job 'while the planted job of the queue was unfinished'
hold_caught 'a wait that reads the active list alone' "$ACTIVE_ALONE" late-job 'while the planted job of the queue was unfinished'
hold_caught 'the Manager started before the last store' "$MANAGER_EARLY" '' 'while the Manager stood above 0'
hold_caught 'the queue let go before the last store' "$QUEUE_EARLY" '' 'while the queue was not held'
hold_caught 'readiness read by rollout status' "$READY_BY_ROLLOUT" 'STORE_WAIT_SECONDS=1' 'the run ended with the Manager at 0' 'the run ended with' 'the run did not end with BACKUP'
hold_caught 'an exit that does not release the hold' "$EXIT_KEEPS_HOLD" 'copy-fails=mongodb-data-mongodb-prod-1' 'the run ended with the Manager at 0' 'the run ended with' 'the run did not end with BACKUP'
hold_caught 'a failed copy that forgets the store it could not start again' "$FORGETS_STORE" 'copy-fails=idp-data-idp-postgresql-0 knob-scale-fails=idp/idp-postgresql' 'the Manager was started while these stores were not back and ready' 'the queue was let go while these stores were not back and ready' 'the run ended with' 'the run did not end with BACKUP'
hold_caught 'a release that does not read the stores ready' "$NEVER_NOT_READY" 'knob-not-ready=idp/idp-postgresql STORE_WAIT_SECONDS=1' 'the Manager was started while these stores were not back and ready' 'the queue was let go while these stores were not back and ready'
# the Manager is never started here, so the world rule's half for the Manager is satisfied and the let-go half has to fire on its own
hold_caught 'a queue let go before the stores were read ready, the Manager never started' "$LET_GO_FIRST" 'knob-not-ready=idp/idp-postgresql STORE_WAIT_SECONDS=1' 'the queue was let go while these stores were not back and ready' 'the run ended with' 'the run did not end with BACKUP'
hold_caught 'a release that trusts its record of the stopped stores instead of the cluster' "$TRUSTS_RECORD" 'knob-stop-fails=idp/idp-postgresql' 'the run ended with the Manager at 0' 'the run ended with' 'the run did not end with BACKUP'
ok 'backup: the planted drivers are caught: no hold, the running run not read, no wait, a wait ended on one quiet pass, a wait that reads the active list alone, the Manager or the queue let go before the last store, readiness read by rollout status, an exit that does not release the hold, a failed copy that forgets its store, a release that does not read the stores ready, a queue let go before the stores were read ready, a release that trusts its record of the stopped stores'

# ── the read-back measures the box's rate and ends a copy that stands still or falls behind, and what it left is removed when the ssh session ends ─
# The read-back is the one step that waits on the storage box alone. The driver reads rclone's own statistics of the copy: the bytes it has
# moved and the time it has run. After READBACK_WAIT_SECONDS it freezes a floor of half the rate it measured, and gives the whole backup the
# time it takes at that floor, counted from there; a copy that moves no byte for READBACK_WAIT_SECONDS is ended. Once a statistics line holds
# every expected byte, none of that applies and READBACK_FINISH_SECONDS is the only bound. The cases run the whole driver
# against the rclone stand-in, whose copy from the box follows a plan: it prints the statistics line rclone 1.60.1 prints after each tick, with
# the real time since the copy started and the bytes the plan has moved by then, so the driver's measurement reads what it reads in production
# and its clock and the stand-in's are one clock: no case depends on how long a tick takes. RB_SLOW is the seconds a tick takes longer, and the
# cases that hold a rate or a stall run once more with it set. One volume weighs about 3 MiB more in the cases that need a backup that takes
# seconds. The waits are shortened as the lock cases shorten theirs, READBACK_WAIT_SECONDS to two seconds: the driver counts whole seconds,
# and two are at least one real second.
READBACK_PAD=3145728
RB_LIMIT=25
RB_SLOW=''
volume_padded() { # <on|off> — one volume of the lock cases weighs about 3 MiB more, or is put back
  local payload
  payload="$LOCK_DIR/storage/$(ls "$LOCK_DIR/storage" | head -n 1)/payload"
  if [ "$1" = on ]; then cp "$payload" "$payload.plain"; head -c "$READBACK_PAD" /dev/zero >> "$payload"; else mv -f "$payload.plain" "$payload"; fi
}
backup_bytes() { find "$STANDIN/box-uploaded" -type f -exec cat {} + 2> /dev/null | wc -c | tr -d ' '; } # what the box holds of the backup just run
readback_start() { # <run> <the driver's text> <padded: 0|1> <the plan, one line each> [NAME=value...] — starts the whole driver against a box whose copy back follows the plan; its pid stands in $LOCK_PID
  local run="$1" text="$2" padded="$3" plan="$4"
  shift 4
  lock_reset free
  if [ -n "$plan" ]; then printf '%s\n' "$plan" > "$STANDIN/readback-plan"; fi
  if [ -n "$plan" ] && [ -n "$RB_SLOW" ]; then printf 'slow %s\n' "$RB_SLOW" >> "$STANDIN/readback-plan"; fi
  : > "$STANDIN/argv.log"
  if [ "$padded" = 1 ]; then volume_padded on; fi
  lock_driver "$run" "$text" READBACK_POLL_SECONDS=0.1 READBACK_REPORT_SECONDS=1 READBACK_WAIT_SECONDS=2 "$@"
  RB_STARTED=$SECONDS
  lock_start "$run"
}
readback_finish() { # <padded: 0|1> <seconds> — waits that long for the driver, ends it where it still runs and says so in $OUT/verdict; its code stands in $LOCK_CODE, the seconds it ran in $RB_RAN
  local _
  for _ in $(seq 1 $(( $2 * 10 ))); do kill -0 "$LOCK_PID" 2> /dev/null || break; sleep 0.1; done
  RB_RAN=$(( SECONDS - RB_STARTED ))
  if kill -0 "$LOCK_PID" 2> /dev/null; then
    echo "the driver still ran $2 seconds after it started" >> "$OUT/verdict"
    kill -KILL "$LOCK_PID"
  fi
  LOCK_CODE=0; { wait "$LOCK_PID"; } 2> /dev/null || LOCK_CODE=$?
  if [ -s "$STANDIN/transfer.pid" ] && kill -0 "$(cat "$STANDIN/transfer.pid")" 2> /dev/null; then
    echo 'the transfer still ran after the driver ended' >> "$OUT/verdict"
    kill -KILL "$(cat "$STANDIN/transfer.pid")" 2> /dev/null || true
  fi
  if [ "$1" = 1 ]; then volume_padded off; fi
}
readback_wrong() { # <run> — says what is wrong with any run: the box named, a secret printed or on a command line, the Manager or the queue not let go, a folder left; ends 0
  local dir="$LOCK_DIR/$1" folders
  box_account_wrong "$dir/out" "$dir/err"
  printed_wrong "$dir/out" "$dir/err"
  commands_wrong
  secrets_wrong "$STANDIN/secrets.seen"
  hold_wrong 1 false
  folders="$(ls "$dir/backups" 2> /dev/null || true)"
  case "$folders" in *.readback*) echo 'the read-back folder stands after the driver ended' ;; esac
  return 0
}
readback_refused() { # <run> <what the error says> — ends 0 when the driver ended 69, said that, and left the work folder with its archives; what is wrong is added to $OUT/verdict
  local dir="$LOCK_DIR/$1" folders id
  [ "$LOCK_CODE" = 69 ] || echo "the driver ended with $LOCK_CODE, not 69: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
  grep -qF -- "$2" "$dir/err" || echo "the driver did not say '$2': $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
  folders="$(ls "$dir/backups" 2> /dev/null || true)"; id="${folders%%$'\n'*}"
  if [ "$(grep -c '^[0-9]\{8\}T[0-9]\{6\}Z$' <<< "$folders")" != 1 ]; then
    echo "the work folder does not stand after the driver ended: $(tr '\n' ' ' <<< "$folders")" >> "$OUT/verdict"
  elif [ "$(ls "$dir/backups/$id" | wc -l | tr -d ' ')" != "$(( LOCK_STORES + 2 ))" ]; then
    echo "the work folder holds $(ls "$dir/backups/$id" | wc -l | tr -d ' ') file(s), not the $LOCK_STORES stores, the quorum and the manifest" >> "$OUT/verdict"
  fi
}
rate_agrees() { # <bytes> <seconds> <rate> — ends 0 when the rate stated is the bytes over the seconds, to the three places it is stated in
  awk -v bytes="$1" -v seconds="$2" -v rate="$3" 'BEGIN { d = bytes / seconds - rate; if (d < 0) d = -d; exit !(d < 0.002) }'
}
readback_figures() { # <run> <the bytes the transfer had moved, or any> — checks the "read N of E expected bytes in S s, R bytes a second" of the error: E is what the box holds, N the given figure, R is N over S; ends 0 with what is wrong added to $OUT/verdict
  local dir="$LOCK_DIR/$1" line moved total seconds rate
  line="$(sed -n 's/.*read \([0-9]*\) of \([0-9]*\) expected bytes in \([0-9.]*\) s, \([0-9.]*\) bytes a second.*/\1 \2 \3 \4/p' "$dir/err" | head -n 1)"
  if [ -z "$line" ]; then echo "the error does not state the bytes read of the bytes expected, the time and the rate: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"; return 0; fi
  read -r moved total seconds rate <<< "$line"
  [ "$total" = "$(backup_bytes)" ] || echo "the error states $total expected bytes, and the box holds $(backup_bytes)" >> "$OUT/verdict"
  if [ "$2" != any ] && [ "$moved" != "$2" ]; then echo "the error states $moved bytes read, and the transfer had moved $2" >> "$OUT/verdict"; fi
  rate_agrees "$moved" "$seconds" "$rate" || echo "the error states $rate bytes a second for $moved bytes in $seconds s" >> "$OUT/verdict"
  return 0
}
emitted_bytes() { cut -d' ' -f1 "$STANDIN/readback-emitted"; } # the bytes of the last statistics line the stand-in printed
allowance_of() { # <expected bytes> <bytes read> <seconds, to three places> — the seconds the whole backup takes at half the rate those give, rounded up
  local milli="${3/./}"
  milli=$(( 10#$milli ))
  printf '%d' $(( ($1 * 2 * milli + $2 * 1000 - 1) / ($2 * 1000) ))
}
rate_near() { awk -v got="$1" -v want="$2" 'BEGIN { d = got - want; if (d < 0) d = -d; exit !(d <= want / 1000) }'; } # <rate stated> <rate planned> — ends 0 when they differ by no more than a thousandth
readback_measured() { # <run> — reads the line "measured N bytes in S s, R bytes a second; policy: a floor of 1/2 of it, F bytes a second; the T bytes are given A s more" of the run into M_BYTES M_SECONDS M_RATE M_FLOOR M_TOTAL M_ALLOWED; what is wrong with its figures is added to $OUT/verdict; ends 0
  local dir="$LOCK_DIR/$1" line
  M_BYTES='' M_SECONDS='' M_RATE='' M_FLOOR='' M_TOTAL='' M_ALLOWED=''
  line="$(sed -n 's/.*measured \([0-9]*\) bytes in \([0-9.]*\) s, \([0-9.]*\) bytes a second; policy: a floor of 1\/2 of it, \([0-9.]*\) bytes a second; the \([0-9]*\) bytes are given \([0-9]*\) s more.*/\1 \2 \3 \4 \5 \6/p' "$dir/out" | head -n 1)"
  if [ -z "$line" ]; then
    echo "the driver did not print the rate it measured, the floor it froze and the time it gave the rest: $(grep -a 'measured' "$dir/out" | head -n 1 | cut -c1-300)" >> "$OUT/verdict"
    return 0
  fi
  read -r M_BYTES M_SECONDS M_RATE M_FLOOR M_TOTAL M_ALLOWED <<< "$line"
  rate_agrees "$M_BYTES" "$M_SECONDS" "$M_RATE" || echo "the driver states $M_RATE bytes a second for $M_BYTES bytes in $M_SECONDS s" >> "$OUT/verdict"
  rate_agrees "$M_BYTES" "$(awk -v s="$M_SECONDS" 'BEGIN { printf "%.3f", s * 2 }')" "$M_FLOOR" || echo "the driver froze a floor of $M_FLOOR bytes a second, not half of the $M_RATE it measured" >> "$OUT/verdict"
  [ "$M_TOTAL" = "$(backup_bytes)" ] || echo "the driver expected $M_TOTAL bytes, and the box holds $(backup_bytes)" >> "$OUT/verdict"
  [ "$M_ALLOWED" = "$(allowance_of "$M_TOTAL" "$M_BYTES" "$M_SECONDS")" ] || echo "the driver gave the rest $M_ALLOWED s, not the $(allowance_of "$M_TOTAL" "$M_BYTES" "$M_SECONDS") s the whole backup takes at the floor" >> "$OUT/verdict"
  return 0
}

readback_paced() { # <the driver's text> — a copy back at half a MiB a second, three times the old floor's pace of the size of the backup: ends 0 when the driver ended 0 after the old size-derived limit, read every byte, and said what it measured; what is wrong stands in $OUT/verdict
  local text="$1" dir="$LOCK_DIR/paced" total old_limit
  : > "$OUT/verdict"
  readback_start paced "$text" 1 'rate 524288 forever'
  readback_finish 1 $RB_LIMIT
  total="$(backup_bytes)"
  old_limit=$(( 2 + total / 1048576 ))
  [ "$LOCK_CODE" = 0 ] || echo "the driver ended with $LOCK_CODE, not 0, on a box that gives half a MiB a second: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
  [ "$(tail -n 1 "$dir/out" | cut -c1-7)" = 'BACKUP ' ] || echo 'the driver did not end with BACKUP and an id' >> "$OUT/verdict"
  [ "$RB_RAN" -gt "$old_limit" ] || echo "the driver ran $RB_RAN s, not past the $old_limit s the old rule gave this backup, so the case does not hold a slow box that the old rule ended" >> "$OUT/verdict"
  readback_measured paced
  if [ -n "$M_RATE" ]; then rate_near "$M_RATE" 524288 || echo "the driver measured $M_RATE bytes a second, not the 524288 the stand-in moves" >> "$OUT/verdict"; fi
  grep -qF -- "read back $total of $total expected bytes in " "$dir/out" || echo "the driver did not say that it read back $total of $total expected bytes" >> "$OUT/verdict"
  readback_wrong paced >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_stalled() { # <the driver's text> <the plan> <padded: 0|1> <moved: zero|some> — a copy that moves no byte for READBACK_WAIT_SECONDS, from the start or after some progress: ends 0 when the driver ended 69 saying so, with the bytes and the rate it had read, and the transfer ended and reaped; what is wrong stands in $OUT/verdict
  local text="$1" dir="$LOCK_DIR/stalled" moved
  : > "$OUT/verdict"
  readback_start stalled "$text" "$3" "$2"
  readback_finish "$3" $RB_LIMIT
  readback_refused stalled 'moved no byte for 2 s and was ended'
  if [ "$4" = zero ]; then moved=0; else moved="$(emitted_bytes)"; [ "$moved" -gt 0 ] || echo 'the stand-in moved no byte before it stood still, so the case does not hold a stall after progress' >> "$OUT/verdict"; fi
  readback_figures stalled "$moved"
  if [ "$4" = zero ]; then grep -qF -- ', 0.000 bytes a second' "$dir/err" || echo "the error does not state a measured rate of 0.000 bytes a second for the zero bytes: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"; fi
  grep -qF -- 'transfer exit status 143' "$dir/err" || echo "the error does not state the transfer ended by TERM, exit status 143: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
  readback_wrong stalled >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_slowed() { # <the driver's text> — a copy that falls to a four-hundredth of its rate after the measurement and still moves a byte every tick: ends 0 when the driver ended 69 once the time the measured rate gave the whole backup had passed; what is wrong stands in $OUT/verdict
  local text="$1" dir="$LOCK_DIR/slowed"
  : > "$OUT/verdict"
  readback_start slowed "$text" 1 $'rate 786432 3500\nrate 2048 forever'
  readback_finish 1 $RB_LIMIT
  readback_measured slowed
  if [ -n "$M_RATE" ]; then rate_near "$M_RATE" 786432 || echo "the driver measured $M_RATE bytes a second, not the 786432 of the fast part, so it did not end the measurement before the fast part ended" >> "$OUT/verdict"; fi
  readback_refused slowed "did not finish within the $M_ALLOWED s its measured rate allows and was ended"
  readback_figures slowed any
  readback_wrong slowed >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_unmeasured() { # <the driver's text> — statistics that no number can be read from: ends 0 when the driver ended 69 saying it had none, and printed nothing of what they said; what is wrong stands in $OUT/verdict
  local text="$1"
  : > "$OUT/verdict"
  readback_start unmeasured "$text" 0 'garbage'
  readback_finish 0 $RB_LIMIT
  readback_refused unmeasured 'gave no statistics within 2 s, so its rate could not be measured'
  grep -qF -- "no statistics were read of $(backup_bytes) expected bytes" "$LOCK_DIR/unmeasured/err" || echo "the error does not say that no statistics were read of the $(backup_bytes) expected bytes" >> "$OUT/verdict"
  readback_wrong unmeasured >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_failed() { # <the driver's text> — the transfer ends 7 with an error after some progress: ends 0 when the driver ended 69 stating the exit status and what it had read, and not what rclone said; what is wrong stands in $OUT/verdict
  local text="$1"
  : > "$OUT/verdict"
  readback_start failed "$text" 1 $'rate 524288 500\nexit 7'
  readback_finish 1 $RB_LIMIT
  readback_refused failed 'could not be read back'
  grep -qF -- 'transfer exit status 7' "$LOCK_DIR/failed/err" || echo "the error does not state the exit status 7 of the transfer: $(tail -n 1 "$LOCK_DIR/failed/err" | cut -c1-300)" >> "$OUT/verdict"
  readback_figures failed "$(emitted_bytes)"
  if ! grep -qF -- 'connection to' "$STANDIN/rclone-errors.log"; then echo 'the stand-in gave no error that carries the host and the user of the box, so the case proves nothing' >> "$OUT/verdict"; fi
  readback_wrong failed >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_killed() { # <the driver's text> — a copy that stands still and ignores TERM: ends 0 when the driver killed it once READBACK_GRACE_SECONDS had passed and reaped it, ending 69 with exit status 137; what is wrong stands in $OUT/verdict
  local text="$1"
  : > "$OUT/verdict"
  readback_start killed "$text" 0 $'rate 0 forever\nignore-term' READBACK_GRACE_SECONDS=1
  readback_finish 0 $RB_LIMIT
  readback_refused killed 'moved no byte for 2 s and was ended'
  grep -qF -- 'transfer exit status 137' "$LOCK_DIR/killed/err" || echo "the error does not state the transfer was killed, exit status 137: $(tail -n 1 "$LOCK_DIR/killed/err" | cut -c1-300)" >> "$OUT/verdict"
  readback_wrong killed >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_quick() { # <the driver's text> — a copy that ends before the measurement is over: ends 0 when the driver went straight to the checks and stated the bytes and the time it read; what is wrong stands in $OUT/verdict
  local text="$1" dir="$LOCK_DIR/quick" total milli
  : > "$OUT/verdict"
  readback_start quick "$text" 0 '' READBACK_WAIT_SECONDS=300
  readback_finish 0 $RB_LIMIT
  total="$(backup_bytes)"
  milli=$(( total * 1000000 / 12 ))
  [ "$LOCK_CODE" = 0 ] || echo "the driver ended with $LOCK_CODE, not 0: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
  grep -qF -- "read back $total of $total expected bytes in 0.012 s, $(( milli / 1000 )).$(printf '%03d' $(( milli % 1000 ))) bytes a second" "$dir/out" || echo "the driver did not state the $total bytes it read back in the 0.012 s the copy ran: $(grep -a 'read back' "$dir/out" | head -n 1 | cut -c1-300)" >> "$OUT/verdict"
  ! grep -qF -- 'measured ' "$dir/out" || echo 'the driver froze a floor for a copy that ended before the measurement was over' >> "$OUT/verdict"
  readback_wrong quick >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_late() { # <the driver's text> — a copy that ends 0 inside the last poll period before the deadline its measured rate gave it: ends 0 when the driver took it for one that ended, read every byte and went on to the checks; what is wrong stands in $OUT/verdict
  local text="$1" dir="$LOCK_DIR/late" total
  : > "$OUT/verdict"
  readback_start late "$text" 1 $'rate 600000 5000\nrate 17400 forever\nevery 0.1' READBACK_POLL_SECONDS=3
  readback_finish 1 $RB_LIMIT
  total="$(backup_bytes)"
  readback_measured late
  if [ -n "$M_RATE" ]; then rate_near "$M_RATE" 600000 || echo "the driver measured $M_RATE bytes a second, not the 600000 of the fast part, so it did not end the measurement before the fast part ended" >> "$OUT/verdict"; fi
  [ "$M_ALLOWED" = 11 ] || echo "the driver gave the rest $M_ALLOWED s, not the 11 s this case is cut for, so its copy does not end in the last poll period before the deadline" >> "$OUT/verdict"
  if grep -qF -- 'transfer exit status 0' "$dir/err"; then echo "the driver ended a copy that had finished, as one that passed its allowance: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"; fi
  [ "$LOCK_CODE" = 0 ] || echo "the driver ended with $LOCK_CODE, not 0, on a copy that finished inside its allowance: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
  [ "$(tail -n 1 "$dir/out" | cut -c1-7)" = 'BACKUP ' ] || echo 'the driver did not end with BACKUP and an id' >> "$OUT/verdict"
  grep -qF -- "read back $total of $total expected bytes in " "$dir/out" || echo "the driver did not say that it read back $total of $total expected bytes" >> "$OUT/verdict"
  readback_wrong late >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_orphaned() { # <the driver's text> [<the plan>] — the ssh session ends while the copy runs, or after it has read every byte and runs on: ends 0 when the driver ended 141, the copy was ended with it and the work folder stands with its archives; what is wrong stands in $OUT/verdict
  local text="$1" plan="${2:-rate 524288 forever}" dir="$LOCK_DIR/orphaned" session reader _
  : > "$OUT/verdict"
  lock_reset free
  printf '%s\n' "$plan" > "$STANDIN/readback-plan"
  : > "$STANDIN/argv.log"
  volume_padded on
  lock_driver orphaned "$text" READBACK_POLL_SECONDS=0.1 READBACK_REPORT_SECONDS=1 READBACK_WAIT_SECONDS=2
  session="$dir/session"; mkfifo "$session"; : > "$dir/err"
  cat "$session" > "$dir/out" 2>&1 &
  reader=$!
  ( export SUDO_STANDIN=nopasswd SUDO_STANDIN_PASSWORD="$PLANTED_PASSWORD" PATH="$STANDIN:$PATH"
    umask 077
    exec env --default-signal=PIPE bash "$dir/driver.sh" "$dir/config" ) < /dev/null > "$session" 2>&1 &
  LOCK_PID=$!
  RB_STARTED=$SECONDS
  for _ in $(seq 1 600); do [ -s "$STANDIN/transfer.pid" ] && break; kill -0 "$LOCK_PID" 2> /dev/null || break; sleep 0.1; done
  [ -s "$STANDIN/transfer.pid" ] || echo "the driver did not start the copy back: $(tail -n 2 "$dir/out" | tr '\n' ' ' | cut -c1-300)" >> "$OUT/verdict"
  case "$plan" in *hold*) for _ in $(seq 1 100); do [ -z "$(timeline_ms complete)" ] || break; sleep 0.1; done; sleep 1.5 ;; esac
  kill "$reader"; { wait "$reader"; } 2> /dev/null || true
  readback_finish 1 15
  [ "$LOCK_CODE" = 141 ] || echo "the driver ended with $LOCK_CODE, not 141 — bash dies of SIGPIPE on the next line it prints once the session has ended" >> "$OUT/verdict"
  readback_wrong orphaned >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}

# What follows the last byte: a copy that has read every expected byte and still runs is given READBACK_FINISH_SECONDS, one wait that
# starts when a statistics line first holds every byte and that nothing restarts; none of the rules for a copy that is still reading
# applies in it. The stand-in writes every file whole, reports the same count and then holds, and the clock of its events stands in
# readback-timeline.
timeline_ms() { # <event> — the milliseconds from the start of the copy to the event, or nothing where the copy never reached it
  awk -v want="$1" '$1 == "start" { s = $2 } $1 == want && s != "" { printf "%d", ($2 - s) / 1000000; exit }' "$STANDIN/readback-timeline" 2> /dev/null || true
}
readback_held() { # <the driver's text> <run> <the plan> <READBACK_FINISH_SECONDS> <the least seconds the copy runs on after its last byte> <measured: yes|no> [<knob>...] — a copy that reads every byte, runs on and then ends 0: ends 0 when the driver let it end and went on to the checks; what is wrong stands in $OUT/verdict, the real times in $RB_TIMES
  local text="$1" run="$2" plan="$3" finish="$4" least="$5" measured="$6" dir="$LOCK_DIR/$2" complete exit_ms coverage covered covered_of covered_names
  shift 6
  : > "$OUT/verdict"
  : > "$STANDIN/argv.log"
  readback_start "$run" "$text" 1 "$plan" READBACK_FINISH_SECONDS="$finish" "$@"
  readback_finish 1 "$RB_LIMIT"
  complete="$(timeline_ms complete)"; exit_ms="$(timeline_ms exit)"
  RB_TIMES="every byte read ${complete:-never} ms and the copy ended ${exit_ms:-never} ms after its start, the driver ran ${RB_RAN} s"
  if [ -z "$complete" ] || [ -z "$exit_ms" ]; then
    echo "the copy did not read every byte and end by itself, so the case holds nothing: $RB_TIMES" >> "$OUT/verdict"
  elif [ $(( exit_ms - complete )) -lt $(( least * 1000 )) ]; then
    echo "the copy ran on $(( exit_ms - complete )) ms after its last byte, not the $least s this case holds it" >> "$OUT/verdict"
  fi
  [ "$LOCK_CODE" = 0 ] || echo "the driver ended with $LOCK_CODE, not 0, on a copy that read every byte and ended 0 by itself: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
  [ "$(tail -n 1 "$dir/out" | cut -c1-7)" = 'BACKUP ' ] || echo 'the driver did not end with BACKUP and an id' >> "$OUT/verdict"
  grep -qF -- 'the checksums hold' "$dir/out" || echo 'the driver did not reach the checksums of the manifest' >> "$OUT/verdict"
  grep -qF -- 'the transfer was seen to have ended' "$dir/out" || echo 'the driver did not say that the copy that had read every byte ended' >> "$OUT/verdict"
  grep -qE 'read back: first complete sample: [0-9]+ of [0-9]+ expected bytes in [0-9.]+ s, [0-9.]+ bytes a second, so the transfer is given' "$dir/out" || echo 'the line of the first complete sample states no bytes, time and rate' >> "$OUT/verdict"
  grep -qE 'first complete sample: [0-9]+ of [0-9]+ expected bytes in [0-9.]+ s, [0-9.]+ bytes a second; the transfer was seen to have ended' "$dir/out" || echo 'the line of the end of the copy states no first complete sample with its rate' >> "$OUT/verdict"
  grep -qE "copy .* --timeout ${finish}s( |\$)" "$STANDIN/argv.log" || echo "the read-back was not run under --timeout ${finish}s, the idle limit of rclone that READBACK_FINISH_SECONDS sets" >> "$OUT/verdict"
  coverage="$(sed -n 's/.*the checksums hold for \([0-9]*\) of \([0-9]*\) archives (\(.*\)), the manifest counts.*/\1 \2 \3/p' "$dir/out")"
  read -r covered covered_of covered_names <<< "$coverage"
  { [ -n "$coverage" ] && [ "$covered" = "$covered_of" ] && [ "$covered_of" = $(( LOCK_STORES + 1 )) ] && [[ "$covered_names" == *"host--vault-prod.txt.gpg"* ]] && [[ "$covered_names" != *manifest* ]]; } \
    || echo "the checksum coverage is not every archive of the backup, the stores and the quorum, by name: $coverage" >> "$OUT/verdict"
  if [ "$measured" = no ]; then
    ! grep -qF -- 'measured ' "$dir/out" || echo 'the driver froze a rate for a copy that had read every byte before the measurement was over' >> "$OUT/verdict"
  else
    readback_measured "$run"
    if [ -n "$M_ALLOWED" ] && [ -n "$exit_ms" ] && [ "$exit_ms" -le $(( (RB_WAIT + M_ALLOWED) * 1000 )) ]; then
      echo "the copy ended $exit_ms ms after its start, inside the $(( RB_WAIT + M_ALLOWED )) s the measured rate gave it, so the case does not hold a copy past that deadline" >> "$OUT/verdict"
    fi
  fi
  readback_wrong "$run" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
RB_WAIT=2 # READBACK_WAIT_SECONDS of every case here, as readback_start sets it
readback_bounded() { # <the driver's text> <run> <the plan> <the bound in seconds> <the exit status of the ended copy: 143|137> [<knob>...] — a copy that has read every byte and runs on past READBACK_FINISH_SECONDS: ends 0 when the driver ended 69 with the named failure once the bound passed, the copy ended and reaped and no checksum run; what is wrong stands in $OUT/verdict
  local text="$1" run="$2" plan="$3" bound="$4" status="$5" dir="$LOCK_DIR/$2" line fields latest counted total waited stated_bound stated_id stated_status first_seconds first_rate latest_bytes latest_seconds latest_rate
  shift 5
  : > "$OUT/verdict"
  readback_start "$run" "$text" 1 "$plan" READBACK_FINISH_SECONDS="$bound" "$@"
  readback_finish 1 "$RB_LIMIT"
  readback_refused "$run" 'read-back completion did not finish'
  line="$(tail -n 1 "$dir/err")"
  fields="$(sed -n 's/.*rclone reported every expected byte read, the completion wait ran \([0-9]*\) s to its bound of \([0-9]*\) s with the transfer still running, and it was ended (backup \([0-9]\{8\}T[0-9]\{6\}Z\)); first complete sample: \([0-9]*\) of \([0-9]*\) expected bytes in \([0-9.]*\) s, \([0-9.]*\) bytes a second; latest sample: read \([0-9]*\) of [0-9]* expected bytes in .*/\1 \2 \3 \4 \5 \6 \7 \8/p' <<< "$line")"
  latest="$(sed -n 's/.*latest sample: read \([0-9]*\) of [0-9]* expected bytes in \([0-9.]*\) s, \([0-9.]*\) bytes a second, transfer exit status \([0-9]*\);.*/\1 \2 \3 \4/p' <<< "$line")"
  if [ -z "$fields" ]; then
    echo "the error does not say that rclone reported every expected byte, how long the wait ran, its bound, the backup, the first complete sample with its rate, and the latest sample with the exit status: $(cut -c1-400 <<< "$line")" >> "$OUT/verdict"
  else
    read -r waited stated_bound stated_id counted total first_seconds first_rate _ <<< "$fields"
    read -r latest_bytes latest_seconds latest_rate stated_status <<< "$latest"
    rate_agrees "$counted" "$first_seconds" "$first_rate" || echo "the error states $first_rate bytes a second for the first complete sample of $counted bytes in $first_seconds s" >> "$OUT/verdict"
    rate_agrees "${latest_bytes:-0}" "${latest_seconds:-1}" "${latest_rate:-x}" || echo "the error states ${latest_rate:-no rate} bytes a second for the latest sample of ${latest_bytes:-no} bytes in ${latest_seconds:-no} s" >> "$OUT/verdict"
    [ "$total" = "$(backup_bytes)" ] || echo "the error states $total expected bytes, and the box holds $(backup_bytes)" >> "$OUT/verdict"
    [ "$counted" -ge "$total" ] || echo "the error states $counted bytes reported, fewer than the $total expected" >> "$OUT/verdict"
    [ "$stated_bound" = "$bound" ] || echo "the error states a bound of $stated_bound s, not the $bound s of the case" >> "$OUT/verdict"
    { [ "$waited" -ge "$bound" ] && [ "$waited" -le $(( bound + 3 )) ]; } || echo "the error states a wait of $waited s, not one of $bound s to $(( bound + 3 )) s" >> "$OUT/verdict"
    [ "$stated_status" = "$status" ] || echo "the error states the exit status $stated_status of the ended copy, not $status" >> "$OUT/verdict"
    grep -qF -- "$stated_id" "$dir/out" || echo "the backup $stated_id of the error is not the backup the run made" >> "$OUT/verdict"
  fi
  case "$line" in *box:*) echo "the error names the path on the box: $(cut -c1-300 <<< "$line")" >> "$OUT/verdict" ;; esac
  case "$line" in *"the archives stand in "*) ;; *) echo 'the error does not say where the archives stand' >> "$OUT/verdict" ;; esac
  case "$plan" in *active*) ;; *) case "$line" in *'an empty list does not show that rclone is idle'*) ;; *) echo 'the failure of a copy whose statistics list no active file does not say that an empty list is no proof that rclone is idle' >> "$OUT/verdict" ;; esac ;; esac
  [ -z "$(timeline_ms exit)" ] || echo 'the copy ended by itself, so the driver did not end it' >> "$OUT/verdict"
  ! grep -qF -- 'the checksums hold' "$dir/out" || echo 'the driver ran the checksums of the manifest on a copy it had ended' >> "$OUT/verdict"
  ! grep -qF -- 'do not match the checksums' "$dir/err" || echo 'the driver ran the checksums of the manifest on a copy it had ended' >> "$OUT/verdict"
  grep -qF -- 'read-back completion (backup ' "$dir/out" || echo 'the driver printed nothing of what rclone reported before it ended the copy' >> "$OUT/verdict"
  [ ! -e "$(cat "$STANDIN/readback-stats-path")" ] || echo 'the file with the log of the copy stands after the driver ended' >> "$OUT/verdict"
  readback_wrong "$run" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
# The log of the copy is read for a diagnosis that is printed before the copy is ended, or when it ends by itself. Whatever rclone writes is
# data from outside: the diagnosis shows its message templates (the cases write them as rclone 1.60.1 does, with the host, the user, the
# account and the path of the box planted where rclone puts a value it took from outside), numbers, times, the version and the names of
# this backup's files, and nothing else.
PLANTED_ACCOUNT=planted-box-account
PLANTED_REMOTE_PATH="/home/$PLANTED_ACCOUNT/secret-backups/planted-backup-id"
rb_record() { # <second> <level> <source> <message> [<object>] — a log record as rclone 1.60.1 writes it: compact JSON, the keys in alphabetical order, the time to the microsecond
  local message="${4//\\/\\\\}" object=''
  message="${message//\"/\\\"}"; message="${message//$'\n'/\\n}"
  if [ -n "${5:-}" ]; then object=",\"object\":\"$5\",\"objectType\":\"*sftp.Object\""; fi
  printf '{"level":"%s","msg":"%s"%s,"source":"%s","time":"2026-10-21T08:%02d:%02d.123456+00:00"}' "$2" "$message" "$object" "$3" $(( $1 / 60 )) $(( $1 % 60 ))
}
retry_line_wrong() { # <the plain output> <retry records> <log records> <least unreadable lines> <the rest of the line> — says what is wrong with "retry records: R of L log record(s) read (U line(s) unreadable, 0 statistics record(s) not valid); REST"; U may be more than the lines the case wrote, because whatever a loaded machine writes beside rclone's records is counted as unreadable too; ends 0
  local line unreadable
  line="$(grep -a '^retry records: ' "$1" | head -n 1)"
  unreadable="$(sed -n 's/^retry records: [0-9]* of [0-9]* log record(s) read (\([0-9]*\) line(s) unreadable, .*/\1/p' <<< "$line")"
  case "$line" in
    "retry records: $2 of $3 log record(s) read ("[0-9]*" line(s) unreadable, 0 statistics record(s) not valid); $5") ;;
    *) echo "the driver did not print the retry records as 'retry records: $2 of $3 log record(s) read (N line(s) unreadable, 0 statistics record(s) not valid); $5'; it printed '$(cut -c1-400 <<< "$line")'"; return 0 ;;
  esac
  [ "$unreadable" -ge "$4" ] || echo "the driver counted $unreadable unreadable lines, fewer than the $4 the case wrote"
  return 0
}
rb_time() { printf '2026-10-21T08:%02d:%02d.123456+00:00' $(( $1 / 60 )) $(( $1 % 60 )); } # <second> — the time rb_record writes
plain_of() { sed 's/\x1b\[[0-9;]*m//g; s/^ *//' "$1" > "$1.plain"; } # <file> — the file without its colors and indents, in <file>.plain
rb_planted="sftp: dial tcp $BOX_HOST:22: ssh: handshake failed for user $BOX_USER: $PLANTED_ACCOUNT $PLANTED_REMOTE_PATH"
# one row for each message template of rclone 1.60.1 the driver shows: level|source|message as rclone writes it|message as the driver shows it|object
RB_ROWS=(
  'info|cmd/cmd.go:263|Attempt 1/3 succeeded|Attempt 1/3 succeeded|'
  "error|cmd/cmd.go:283|Attempt 2/3 failed with 1 errors and: $rb_planted|Attempt 2/3 failed with 1 errors and: [redacted]|"
  'error|cmd/cmd.go:285|Attempt 2/3 failed with 1 errors|Attempt 2/3 failed with 1 errors|'
  'error|cmd/cmd.go:268|Fatal error received - not attempting retries|Fatal error received - not attempting retries|'
  "error|cmd/cmd.go:272|Can't retry any of the errors - not attempting retries|Can't retry any of the errors - not attempting retries|"
  'info|cmd/cmd.go:298|7 go routines active\n|7 go routines active|'
  "debug|cmd/cmd.go:414|Version \"v1.60.1\" starting with parameters [\"rclone\" \"--config\" \"$PLANTED_REMOTE_PATH/rclone.conf\" \"copy\" \"box:$BOX_HOST/$PLANTED_REMOTE_PATH/\" \"/dev/shm/x\"]|Version \"v1.60.1\" starting with parameters [redacted]|"
  "error|operations/operations.go:529|Received error: $rb_planted - low level retry 1/10|Received error: [redacted] - low level retry 1/10|"
  "error|operations/operations.go:538|Failed to copy: $rb_planted|Failed to copy: [redacted]|"
  "error|operations/operations.go:103|Failed to calculate src hash: failed to run \"md5sum $PLANTED_REMOTE_PATH/a.tar.gpg\" for $BOX_USER|Failed to calculate src hash: [redacted]|"
  "error|operations/operations.go:107|Failed to calculate dst hash: $rb_planted|Failed to calculate dst hash: [redacted]|"
  'error|operations/operations.go:545|corrupted on transfer: sizes differ 3147722 vs 3147721|corrupted on transfer: sizes differ 3147722 vs 3147721|'
  'info|operations/operations.go:566|Copied (new)|Copied (new)|manifest.txt'
  'info|operations/operations.go:566|Copied (replaced existing)|Copied (replaced existing)|manifest.txt'
  'info|operations/operations.go:566|Copied (server-side copy)|Copied (server-side copy)|manifest.txt'
  'info|operations/operations.go:566|Multi-thread Copied (new)|Multi-thread Copied (new)|manifest.txt'
  'info|operations/operations.go:566|Multi-thread Copied (replaced existing)|Multi-thread Copied (replaced existing)|manifest.txt'
  'info|operations/operations.go:566|Copied (Rcat, new)|Copied (Rcat, new)|manifest.txt'
  'info|operations/operations.go:566|Copied (Rcat, replaced existing)|Copied (Rcat, replaced existing)|manifest.txt'
  'info|sync/sync.go:441|Waiting for checks to finish|Waiting for checks to finish|'
  'info|sync/sync.go:457|Waiting for transfers to finish|Waiting for transfers to finish|'
  'info|sync/sync.go:479|Waiting for renames to finish|Waiting for renames to finish|'
  'info|sync/sync.go:891|Checks finished, now starting transfers|Checks finished, now starting transfers|'
)
readback_private_wrong() { # <run> — says which planted value of the box stands in the output of the run, on either stream, and which stands on the command line of awk, which reads the log of the copy; ends 0
  local dir="$LOCK_DIR/$1" planted
  for planted in "$BOX_HOST" "$BOX_USER" "$PLANTED_ACCOUNT" "$PLANTED_REMOTE_PATH" "$PLANTED_BOX_PASSWORD" "$PLANTED_PASSPHRASE" "$PLANTED_PASSWORD"; do
    ! grep -qaF -- "$planted" "$dir/out" "$dir/err" || echo "the run printed the planted value $planted"
    ! grep -a '^awk ' "$STANDIN/argv.log" | grep -qaF -- "$planted" || echo "the planted value $planted stands on the command line of awk"
  done
  return 0
}
readback_templates() { # <the driver's text> — every message template the driver shows, written as rclone 1.60.1 writes it with the host, the user, the account and the path of the box planted in it: ends 0 when each comes out as its template with the planted values gone, and each that carries none as it went in; what is wrong stands in $OUT/verdict
  local text="$1" dir="$LOCK_DIR/templates" plan=$'rate 4194304 forever\nhold forever' row level source message expected object n=0 want
  : > "$OUT/verdict"
  for row in "${RB_ROWS[@]}"; do
    n=$(( n + 1 ))
    IFS='|' read -r level source message expected object <<< "$row"
    message="${message//\\n/$'\n'}"
    plan+=$'\n'"log after $(rb_record "$n" "$level" "$source" "$message" "$object")"
  done
  readback_start templates "$text" 1 "$plan" READBACK_FINISH_SECONDS=3
  readback_finish 1 "$RB_LIMIT"
  plain_of "$dir/out"
  n=0
  for row in "${RB_ROWS[@]}"; do
    n=$(( n + 1 ))
    IFS='|' read -r level source message expected object <<< "$row"
    want="$(rb_time "$n") $level $source $expected${object:+ [$object]}"
    grep -qxF -- "$want" "$dir/out.plain" || echo "the driver did not show the record of $source as '$want'" >> "$OUT/verdict"
  done
  grep -qF -- "log of the completion phase, ${#RB_ROWS[@]} of ${#RB_ROWS[@]} record(s)" "$dir/out.plain" || echo "the driver did not say that it shows all ${#RB_ROWS[@]} records of the completion phase" >> "$OUT/verdict"
  readback_private_wrong templates >> "$OUT/verdict"
  readback_wrong templates >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_diagnosed() { # <the driver's text> — a copy that has read every byte with work still listed, a retry counter, an error, 36 log records after its last byte, one before it and lines that are no record: ends 0 when the driver printed the first and the last record of the completion phase with their counters, the active files, the retry figures, the last 30 log records in order, the record before as prior context only, and the last record of the log as what is unfinished; what is wrong stands in $OUT/verdict
  local text="$1" dir="$LOCK_DIR/diagnosed" total plan n=0 archive ring want_ring want
  local -a ring_lines=()
  : > "$OUT/verdict"
  plan=$'rate 4194304 forever\nfield totalTransfers 2\nfield totalChecks 3\nheld-field checks 1\nheld-field transfers 1\nheld-field errors 1\nheld-field retryError true\nheld-active transferring @archive\nheld-active checking @manifest\nhold forever'
  plan+=$'\n'"log start $(rb_record 1 debug cmd/cmd.go:414 'Version "v1.60.1" starting with parameters ["rclone" "copy"]')"
  plan+=$'\n'"log before $(rb_record 2 info sync/sync.go:441 'Waiting for checks to finish')"
  plan+=$'\n'"log after $(rb_record 3 error cmd/cmd.go:283 "Attempt 1/3 failed with 1 errors and: $rb_planted")"
  plan+=$'\n'"log after not json: $BOX_USER at $BOX_HOST"
  plan+=$'\n'"log after STDOUT:$(rb_record 4 info sync/sync.go:457 'Waiting for transfers to finish')"
  plan+=$'\n'"log after {\"level\":\"info\",\"msg\":\"cut off $BOX_HOST"
  plan+=$'\n'"log after $(rb_record 5 error cmd/cmd.go:285 'Attempt 1/3 failed with 1 errors')"
  plan+=$'\n'"log after $(rb_record 6 info cmd/cmd.go:263 'Attempt 2/3 succeeded')"
  ring_lines+=("$(rb_time 3) error cmd/cmd.go:283 Attempt 1/3 failed with 1 errors and: [redacted]" "$(rb_time 4) info sync/sync.go:457 Waiting for transfers to finish" "$(rb_time 5) error cmd/cmd.go:285 Attempt 1/3 failed with 1 errors")
  ring_lines+=("$(rb_time 6) info cmd/cmd.go:263 Attempt 2/3 succeeded")
  for n in $(seq 7 36); do
    plan+=$'\n'"log after $(rb_record "$n" info operations/operations.go:566 'Copied (new)' manifest.txt)"
    ring_lines+=("$(rb_time "$n") info operations/operations.go:566 Copied (new) [manifest.txt]")
  done
  plan+=$'\n'"log after $(rb_record 37 error operations/operations.go:529 "Received error: $rb_planted - low level retry 2/10")"
  plan+=$'\n'"log after $(rb_record 38 info operations/operations.go:566 'Copied (replaced existing)' manifest.txt)"
  ring_lines+=("$(rb_time 37) error operations/operations.go:529 Received error: [redacted] - low level retry 2/10" "$(rb_time 38) info operations/operations.go:566 Copied (replaced existing) [manifest.txt]")
  readback_start diagnosed "$text" 1 "$plan" READBACK_FINISH_SECONDS=3
  readback_finish 1 "$RB_LIMIT"
  total="$(backup_bytes)"
  readback_refused diagnosed 'read-back completion did not finish'
  plain_of "$dir/out"
  archive="$(find "$STANDIN/box-uploaded" -type f | head -n 1)"
  archive="$(ls "${archive%/*}" | grep -vx manifest.txt | head -n 1)"
  for want in \
    'rclone version: v1.60.1' \
    "first complete record: $total of $total bytes, transfers 0/2, checks 0/3, errors 0, deletes 0, deletedDirs 0, elapsedTime " \
    'active in it: no file transferring listed, no file checking listed' \
    "$total of $total bytes, transfers 1/2, checks 1/3, errors 1, deletes 0, deletedDirs 0, elapsedTime " \
    ", retryError true, fatalError false, written at 2026-10-21T00:00:00+00:00" \
    "active in it: 1 file(s) transferring [$archive], 1 file(s) checking [manifest.txt]" \
    "prior context, the record before the byte count was complete (not proof that its operation is still running): $(rb_time 2) info sync/sync.go:441 Waiting for checks to finish" \
    "unfinished: the last statistics record reports 1 file(s) transferring [$archive], 1 file(s) checking [manifest.txt]; the last log record reads: $(rb_time 38) info operations/operations.go:566 Copied (replaced existing) [manifest.txt]" \
    'log of the completion phase, 30 of 36 record(s), oldest first:'; do
    case "$want" in unfinished:*) grep -qF -- "${want#unfinished: }" "$LOCK_DIR/diagnosed/err" || echo "the error does not say '${want#unfinished: }'" >> "$OUT/verdict" ;; *) grep -qF -- "$want" "$dir/out.plain" || echo "the driver did not print '$want'; it printed '$(grep -aF -- "${want:0:14}" "$dir/out.plain" | head -n 1 | cut -c1-400)'" >> "$OUT/verdict" ;; esac
  done
  retry_line_wrong "$dir/out.plain" 4 38 2 'attempts 3: 1/3 failed with 1 errors; 1/3 failed with 1 errors; 2/3 succeeded; low-level retries 1, the latest 2/10' >> "$OUT/verdict"
  ring="$(sed -n '/^log of the completion phase, /,$p' "$dir/out.plain" | sed '1d')"
  want_ring="$(printf '%s\n' "${ring_lines[@]:6}")"
  [ "$ring" = "$want_ring" ] || echo "the 30 records of the completion phase are not the last 30 of the 36, in order: $(head -n 2 <<< "$ring" | cut -c1-200 | tr '\n' ' ')" >> "$OUT/verdict"
  readback_private_wrong diagnosed >> "$OUT/verdict"
  readback_wrong diagnosed >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_private() { # <the driver's text> <run> <the end: success|failure|bound> — a copy whose log and statistics carry the host, the user, the account, the path and the passwords of the box in every field, in escaped forms and in lines that are no record: ends 0 when the driver ended as that end says, showed what is safe of the log and printed nothing planted on either stream or on the command line of awk (the failure end counts one more unreadable line, the error the stand-in itself writes); what is wrong stands in $OUT/verdict
  local text="$1" run="$2" end="$3" dir="$LOCK_DIR/$2" plan line finish=20 unreadable=3
  : > "$OUT/verdict"
  plan=$'rate 4194304 forever\nfield errors 1\nfield retryError true'
  plan+=$'\n'"active transferring $PLANTED_REMOTE_PATH/a.tar.gpg"$'\n'"active checking $BOX_HOST"$'\n'"held-active transferring $PLANTED_ACCOUNT"$'\n'"held-active checking $BOX_USER"
  case "$end" in
    success) plan+=$'\nhold 3' ;;
    failure) plan+=$'\nhold 3\nfinish 7' ;;
    bound) plan+=$'\nhold forever'; finish=3 ;;
  esac
  plan+=$'\n'"log start $(rb_record 1 debug cmd/cmd.go:414 "Version \"v1.60.1\" starting with parameters [\"rclone\" \"--config\" \"$PLANTED_REMOTE_PATH/rclone.conf\" \"copy\" \"box:$BOX_HOST/$PLANTED_REMOTE_PATH/\" \"$BOX_USER\"]")"
  plan+=$'\n'"log before {\"level\":\"info\",\"msg\":\"$PLANTED_REMOTE_PATH\",\"object\":\"$PLANTED_REMOTE_PATH\",\"source\":\"$PLANTED_REMOTE_PATH.go:3\",\"time\":\"$BOX_HOST\"}"
  plan+=$'\n'"log after $(rb_record 2 error operations/operations.go:538 "Failed to copy: dial $BOX_HOST as $BOX_USER ($PLANTED_ACCOUNT) $PLANTED_REMOTE_PATH password $PLANTED_BOX_PASSWORD passphrase $PLANTED_PASSPHRASE elevation $PLANTED_PASSWORD")"
  plan+=$'\n'"log after $(rb_record 3 info operations/operations.go:566 'Copied (new)' "$PLANTED_REMOTE_PATH/manifest.txt")"
  plan+=$'\n'"log after $(rb_record 4 info operations/operations.go:566 'Copied (new)' "$PLANTED_ACCOUNT")"
  plan+=$'\n''log after {"level":"info","msg":"Failed to copy: boxuser at box.example.invalid","object":"planted-box-account","source":"operations/operations.go:538","time":"2026-10-21T08:00:05.123456+00:00"}'
  plan+=$'\n'"log after not json: user $BOX_USER at $BOX_HOST password $PLANTED_BOX_PASSWORD"
  plan+=$'\n'"log after {\"level\":\"info\",\"msg\":\"cut off $BOX_HOST"
  plan+=$'\n'"log after {\"level\":\"info\",\"msg\":\"tab"$'\t'"here $BOX_USER\"}"
  plan+=$'\n'"log after {\"level\":\"$BOX_USER\",\"msg\":\"Copied (new)\",\"object\":\"manifest.txt\",\"source\":\"$BOX_HOST/x.go:1\",\"time\":\"$PLANTED_ACCOUNT\",\"user\":\"$BOX_USER\",\"host\":\"$BOX_HOST\",\"extra\":{\"a\":\"$PLANTED_ACCOUNT\"}}"
  plan+=$'\n'"log after $(rb_record 6 error cmd/cmd.go:283 "Attempt 1/3 failed with 1 errors and: $PLANTED_REMOTE_PATH")"
  readback_start "$run" "$text" 1 "$plan" READBACK_FINISH_SECONDS="$finish"
  readback_finish 1 "$RB_LIMIT"
  plain_of "$dir/out"
  case "$end" in
    success)
      [ "$LOCK_CODE" = 0 ] || echo "the driver ended with $LOCK_CODE, not 0: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
      [ "$(tail -n 1 "$dir/out" | cut -c1-7)" = 'BACKUP ' ] || echo 'the driver did not end with BACKUP and an id' >> "$OUT/verdict" ;;
    failure) unreadable=4; readback_refused "$run" 'could not be read back'; grep -qF -- 'transfer exit status 7' "$dir/err" || echo 'the error does not state the exit status 7 of the transfer' >> "$OUT/verdict" ;;
    bound) readback_refused "$run" 'read-back completion did not finish' ;;
  esac
  for line in \
    'rclone version: v1.60.1' \
    'errors 1, deletes 0, deletedDirs 0, elapsedTime ' \
    ', retryError true, fatalError false' \
    '1 file(s) transferring [1 name(s) not shown], 1 file(s) checking [1 name(s) not shown]' \
    'time unavailable info source unavailable [text redacted]' \
    "$(rb_time 2) error operations/operations.go:538 Failed to copy: [redacted]" \
    "$(rb_time 3) info operations/operations.go:566 Copied (new)" \
    "$(rb_time 4) info operations/operations.go:566 Copied (new)" \
    "$(rb_time 5) info operations/operations.go:538 Failed to copy: [redacted]" \
    'time unavailable level unavailable source unavailable Copied (new) [manifest.txt]' \
    "$(rb_time 6) error cmd/cmd.go:283 Attempt 1/3 failed with 1 errors and: [redacted]"; do
    grep -qF -- "$line" "$dir/out.plain" || echo "the driver did not print '$line'" >> "$OUT/verdict"
  done
  retry_line_wrong "$dir/out.plain" 1 8 "$unreadable" 'attempts 1: 1/3 failed with 1 errors; low-level retries 0' >> "$OUT/verdict"
  for line in "$(rb_time 3) info operations/operations.go:566 Copied (new) [" "$(rb_time 4) info operations/operations.go:566 Copied (new) ["; do
    ! grep -qF -- "$line" "$dir/out.plain" || echo "the driver printed an object that is no file of the backup: $line" >> "$OUT/verdict"
  done
  readback_private_wrong "$run" >> "$OUT/verdict"
  readback_wrong "$run" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_ended_badly() { # <the driver's text> <run> <the plan> <what the error says> <the exit status of the copy> — a copy that has read every byte and then ends by itself with an error, or with the bytes of an archive changed at the same size: ends 0 when the driver ended 69 saying so, and ran the checksums only where the copy ended 0; what is wrong stands in $OUT/verdict
  local text="$1" run="$2" dir="$LOCK_DIR/$2"
  : > "$OUT/verdict"
  readback_start "$run" "$text" 1 "$3" READBACK_FINISH_SECONDS=20
  readback_finish 1 "$RB_LIMIT"
  readback_refused "$run" "$4"
  [ -n "$(timeline_ms exit)" ] || echo 'the copy was ended by the driver, it did not end by itself' >> "$OUT/verdict"
  if [ "$5" != 0 ]; then
    grep -qF -- "transfer exit status $5" "$dir/err" || echo "the error does not state the exit status $5 of the transfer: $(tail -n 1 "$dir/err" | cut -c1-300)" >> "$OUT/verdict"
    ! grep -qF -- 'the checksums hold' "$dir/out" || echo 'the driver ran the checksums of the manifest on a copy that ended with an error' >> "$OUT/verdict"
    ! grep -qF -- 'do not match the checksums' "$dir/err" || echo 'the driver ran the checksums of the manifest on a copy that ended with an error' >> "$OUT/verdict"
  fi
  grep -qF -- 'read-back completion (backup ' "$dir/out" || echo 'the driver printed nothing of what rclone reported' >> "$OUT/verdict"
  readback_wrong "$run" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}

readback_unavailable() { # <the driver's text> — statistics from the hold on that lack a counter or carry one that is no count: ends 0 when the driver ended 69 at the bound and printed each such counter as unavailable, not as 0 or as a ratio, and the other figures as they are; what is wrong stands in $OUT/verdict
  local text="$1" dir="$LOCK_DIR/unavailable" total
  : > "$OUT/verdict"
  readback_start unavailable "$text" 1 $'rate 4194304 forever\nheld-field transfers -\nheld-field checks "seven"\nheld-field errors 1.5\nheld-field deletes -1\nheld-field deletedDirs -\nheld-field retryError "yes"\nhold forever' READBACK_FINISH_SECONDS=3
  readback_finish 1 "$RB_LIMIT"
  total="$(backup_bytes)"
  readback_refused unavailable 'read-back completion did not finish'
  plain_of "$dir/out"
  grep -qF -- "$total of $total bytes, transfers unavailable, checks unavailable, errors unavailable, deletes unavailable, deletedDirs unavailable, elapsedTime " "$dir/out.plain" || echo 'the driver did not print the counters that are missing or no count as unavailable' >> "$OUT/verdict"
  grep -qF -- ', retryError unavailable, fatalError false, written at 2026-10-21T00:00:00+00:00' "$dir/out.plain" || echo 'the driver did not print a retry flag that is no boolean as unavailable' >> "$OUT/verdict"
  readback_wrong unavailable >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
readback_paced "$LOCK_TEXT" || fail "backup: a read-back at half a MiB a second, which the old fixed floor would have ended, was not finished as it must be: $(cat "$OUT/verdict")"
readback_quick "$LOCK_TEXT" || fail "backup: a read-back that ends before its measurement is over was not taken to the checks as it must be: $(cat "$OUT/verdict")"
readback_stalled "$LOCK_TEXT" 'rate 0 forever' 0 zero || fail "backup: a read-back that moved no byte at all was not ended as it must be: $(cat "$OUT/verdict")"
readback_stalled "$LOCK_TEXT" $'rate 524288 300\nrate 0 forever' 1 some || fail "backup: a read-back that stood still after some progress was not ended as it must be: $(cat "$OUT/verdict")"
readback_slowed "$LOCK_TEXT" || fail "backup: a read-back that slowed after its measurement was not ended once the measured rate's time had passed: $(cat "$OUT/verdict")"
readback_unmeasured "$LOCK_TEXT" || fail "backup: a read-back whose statistics hold no number was not ended as it must be: $(cat "$OUT/verdict")"
readback_failed "$LOCK_TEXT" || fail "backup: a read-back whose transfer failed was not reported as it must be: $(cat "$OUT/verdict")"
readback_killed "$LOCK_TEXT" || fail "backup: a read-back that ignores TERM was not killed after its grace as it must be: $(cat "$OUT/verdict")"
readback_late "$LOCK_TEXT" || fail "backup: a read-back that ended inside the last poll period before its deadline was not taken as finished: $(cat "$OUT/verdict")"
RB_SLOW=0.4
readback_paced "$LOCK_TEXT" || fail "backup: a read-back at half a MiB a second, when every tick of the copy took 0.4 s longer, was not finished as it must be: $(cat "$OUT/verdict")"
readback_stalled "$LOCK_TEXT" $'rate 524288 300\nrate 0 forever' 1 some || fail "backup: a read-back that stood still after some progress, when every tick of the copy took 0.4 s longer, was not ended as it must be: $(cat "$OUT/verdict")"
RB_SLOW=''
readback_orphaned "$LOCK_TEXT" || fail "backup: the transfer, the read-back folder, the secrets or the work folder were left wrong when the ssh session ended during the read-back: $(cat "$OUT/verdict")"
readback_orphaned "$LOCK_TEXT" $'rate 4194304 forever\nhold forever' || fail "backup: the transfer, the read-back folder, the secrets or the work folder were left wrong when the ssh session ended while the copy that had read every byte ran on: $(cat "$OUT/verdict")"
readback_held "$LOCK_TEXT" held_after_last_byte $'rate 4194304 forever\nhold 5' 20 4 no || fail "backup: a read-back that reads every byte and then runs on for longer than READBACK_WAIT_SECONDS was not taken to the checksums: $(cat "$OUT/verdict")"
HELD_TIMES="$RB_TIMES"
RB_LIMIT=45 readback_held "$LOCK_TEXT" held_past_old_deadline $'rate 786432 forever\nhold 12' 30 11 yes || fail "backup: a read-back that reads every byte and ends after the time its measured rate gave it was not taken to the checksums: $(cat "$OUT/verdict")"
RB_LIMIT=45 readback_held "$LOCK_TEXT" held_at_deadline $'rate 600000 5000\nrate 17400 forever\nevery 0.1\nhold 6' 30 5 yes READBACK_POLL_SECONDS=3 || fail "backup: a read-back that is first seen to have read every byte when its measured deadline has passed was not taken to the checksums: $(cat "$OUT/verdict")"
readback_held "$LOCK_TEXT" held_late_completed $'rate 4194304 forever\nevery 0.1\nhold 6' 5 5 no READBACK_POLL_SECONDS=3 || fail "backup: a read-back whose copy ended inside the last poll period before its completion bound was not taken as finished: $(cat "$OUT/verdict")"
readback_held "$LOCK_TEXT" held_over $'rate 4194304 forever\nhold 4\nover 100' 20 3 no || fail "backup: a read-back whose count rose above the expected bytes was not taken to the checksums: $(cat "$OUT/verdict")"
readback_bounded "$LOCK_TEXT" bounded_repeated $'rate 4194304 forever\nhold forever' 3 143 || fail "backup: a read-back that repeats every byte read and never ends was not ended at its completion bound: $(cat "$OUT/verdict")"
readback_bounded "$LOCK_TEXT" bounded_ignores_term $'rate 4194304 forever\nhold forever\nignore-term' 3 137 READBACK_GRACE_SECONDS=1 || fail "backup: a read-back at its completion bound that ignores TERM was not killed after its grace: $(cat "$OUT/verdict")"
readback_bounded "$LOCK_TEXT" bounded_growing $'rate 4194304 forever\nhold forever\nover grow' 3 143 || fail "backup: a read-back whose count grows after every byte was read, and never ends, did not end at its first completion bound: $(cat "$OUT/verdict")"
readback_bounded "$LOCK_TEXT" bounded_reset $'rate 4194304 forever\nhold forever\nreset' 3 143 || fail "backup: a read-back whose count falls to zero after every byte was read, and never ends, was not ended at its completion bound: $(cat "$OUT/verdict")"
readback_bounded "$LOCK_TEXT" bounded_silent $'rate 4194304 forever\nhold forever\nsilent' 3 143 || fail "backup: a read-back that writes no statistics after every byte was read, and never ends, was not ended at its completion bound: $(cat "$OUT/verdict")"
readback_ended_badly "$LOCK_TEXT" ended_with_error $'rate 4194304 forever\nhold 3\nfinish 7' 'could not be read back' 7 || fail "backup: a read-back that read every byte and ended 7 was not ended as a failure: $(cat "$OUT/verdict")"
readback_ended_badly "$LOCK_TEXT" ended_flipped $'rate 4194304 forever\nflip\nhold 2' 'do not match the checksums of their manifest' 0 || fail "backup: a read-back that read every byte of an archive changed at the same size and ended 0 did not reach the checksums that refuse it: $(cat "$OUT/verdict")"
readback_templates "$LOCK_TEXT" || fail "backup: the records of the message templates of rclone 1.60.1, with the host, the user, the account and the path of the box in them, were not shown as their templates: $(cat "$OUT/verdict")"
readback_diagnosed "$LOCK_TEXT" || fail "backup: the diagnosis of a copy that read every byte and did not end was not printed as it must be: $(cat "$OUT/verdict")"
readback_private "$LOCK_TEXT" private_success success || fail "backup: the log and the statistics of a copy that ended 0 carried what the operator must not see, or the diagnosis was not shown: $(cat "$OUT/verdict")"
readback_private "$LOCK_TEXT" private_failure failure || fail "backup: the log and the statistics of a copy that ended 7 carried what the operator must not see, or the diagnosis was not shown: $(cat "$OUT/verdict")"
readback_private "$LOCK_TEXT" private_bound bound || fail "backup: the log and the statistics of a copy ended at its completion bound carried what the operator must not see, or the diagnosis was not shown: $(cat "$OUT/verdict")"
readback_unavailable "$LOCK_TEXT" || fail "backup: statistics that lack a counter or carry one that is no count were not printed as unavailable: $(cat "$OUT/verdict")"
ok "backup: a copy that has read every expected byte and runs on is given READBACK_FINISH_SECONDS once, and no rule for a copy that is still reading ends it: it is taken to the checksums when it ends 0 by itself after 5 s with READBACK_WAIT_SECONDS at 2 s ($HELD_TIMES), before the measurement, after the measured deadline, first seen after that deadline, inside the last poll period before the bound, with a count above the expected bytes; a copy that runs on past the bound, with its count repeating, growing, falling to zero or no longer written, ends 69 with 'read-back completion did not finish', TERM or KILL and reaped, the archives kept and no checksum run; one that ends 7 or ends 0 with an archive changed at the same size is refused, the second by the checksums; the diagnosis shows a counter that is missing or no count as unavailable, the first and the last record of the completion phase, the active files, the retry figures and the last 30 log records of 36, shows the message templates of rclone 1.60.1 with the host, the user, the account and the path of the box planted in them as the templates alone, and prints nothing planted on either stream or on the command line of awk when the copy ends 0, 7 or at the bound; a driver whose session ended while the copy ran on ends its copy and leaves the work folder only"
ok 'backup: a read-back at half a MiB a second, slower than the old floor of a MiB a second, is finished, with the rate it measured, the floor of half of it and the time the whole backup takes at that floor stated; a copy that ends within the measurement goes straight to the checks, stating its bytes and time, and so does one that ends inside the last poll period before its deadline; the cases that hold a rate or a stall give the same answers when every tick of the copy takes 0.4 s longer; a copy that moves no byte for READBACK_WAIT_SECONDS, from the first byte or after some, one that slows past its allowance, one whose statistics hold no number, one whose transfer fails and one that ignores TERM each end 69 stating the bytes read of the bytes expected, the time, the rate and the transfer exit status, with the transfer ended and reaped, the archives on the machine, the Manager started and the queue let go; a driver whose ssh session ended during the read-back ends its transfer and leaves the work folder only'

# The arithmetic of the measurement: rate to three places, seconds to three places, and the allowance rounded up, on the vectors below.
READBACK_ARITHMETIC="$(sed -n '/^rate_of() {/,/^}/p;/^seconds_of() /p;/^readback_allowance_seconds() /p' "$HERE/master-backup-driver.sh")"
[ -n "$READBACK_ARITHMETIC" ] || fail 'the backup driver carries no arithmetic of the read-back to measure'
arithmetic_wrong() { # <the arithmetic's text> — says which vector it answers wrongly, evaluated with the driver's own READBACK values; ends 0
  local want call got
  while IFS='|' read -r want call; do
    got="$( eval "$BACKUP_READBACK_TIMINGS"; eval "$1"; eval "$call" )"
    [ "$got" = "$want" ] || echo "$call answered '$got', not '$want'"
  done <<'VECTORS'
524288.000|rate_of 3145728 6000
0.333|rate_of 1 3000
0.500|rate_of 1 2000
0.000|rate_of 1 86400000
0.000|rate_of 0 5000
unavailable|rate_of 100 0
999999999999000.000|rate_of 999999999999 1
1.500|seconds_of 1500
0.012|seconds_of 12
12|readback_allowance_seconds 3145728 1048576 2000
7|readback_allowance_seconds 10 3 1000
600|readback_allowance_seconds 100 1 3000
1999999799980001|readback_allowance_seconds 99999999999 1 9999999
VECTORS
  return 0
}
[ -z "$(arithmetic_wrong "$READBACK_ARITHMETIC")" ] || fail "backup: the arithmetic of the read-back answers wrongly: $(arithmetic_wrong "$READBACK_ARITHMETIC")"
ok 'backup: the rate and the seconds of the read-back are stated to three places, a rate below one byte a second is stated as it is and not as none, no time passed is "unavailable" and not 0.000, the allowance is rounded up, and the largest figures the driver accepts do not overflow'

# planted defects of the read-back: the old fixed floor, a stall that is not ended, a deadline that is not enforced, a copy that ended while the poll
# slept and is judged by the rules for a running one, a transfer that is not killed after its grace, a byte count that is not the transfer's, a cleanup
# that leaves the transfer, an access value in the statistics line, and the three arithmetic mistakes; each is refused for its own defect only
ALLOWANCE_LINE='readback_allowance_seconds() { printf '"'"'%d'"'"' $(( ($1 * READBACK_SLOWDOWN_FACTOR * $3 + $2 * 1000 - 1) / ($2 * 1000) )); }'
# a driver that is ended by the case after the seconds it was given, with what that leaves behind
DRIVER_RAN_ON=('the driver still ran' 'the transfer still ran after the driver ended' 'the driver ended with' 'the driver did not say' 'the error does not state' 'stands after the driver ended')
plant "$LOCK_TEXT" "$ALLOWANCE_LINE" 'readback_allowance_seconds() { printf '"'"'%d'"'"' $(( $1 / 1048576 )); }'; OLD_FIXED_FLOOR="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'readback_fail "moved no byte for $READBACK_WAIT_SECONDS s and was ended"' 'true'; NO_STALL_RULE="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'readback_fail "did not finish within the $READBACK_ALLOWED_SECONDS s its measured rate allows and was ended"' 'true'; NO_DEADLINE="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'root kill -KILL "$pid" >/dev/null 2>&1;' 'true;'; NO_KILL="$PLANTED_TEXT"
plant "$LOCK_TEXT" "expected bytes in %s s, %s bytes a second' \"\$SAMPLE_BYTES\" \"\$READBACK_EXPECTED\"" "expected bytes in %s s, %s bytes a second' \"\$READBACK_EXPECTED\" \"\$READBACK_EXPECTED\""; FALSE_BYTE_COUNT="$PLANTED_TEXT"
plant "$LOCK_TEXT" $'now=$SECONDS\n    kill -0 "$TRANSFER_JOB" 2>/dev/null || break' 'now=$SECONDS'; JUDGES_ENDED_COPY_AS_RUNNING="$PLANTED_TEXT"
plant "$LOCK_TEXT" '[ -z "$TRANSFER_JOB" ] || readback_end' 'true'; KEEPS_TRANSFER="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$TRAP_REMOVAL" 'true'; NO_READBACK_REMOVAL="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'die "the archives could not be read back from $BACKUPS/$ID/: $(readback_state); they stand in $WORK on this machine" 69' 'die "the archives could not be read back from $BACKUPS/$ID/: $(readback_state) $(tail -n 1 "$READBACK_STATS"); they stand in $WORK on this machine" 69'; PRINTS_STATISTICS="$PLANTED_TEXT"
! readback_paced "$OLD_FIXED_FLOOR" || fail 'the planted old fixed floor was not caught on a box that gives half a MiB a second — the probe proves nothing'
caught_for 'old fixed floor' 'the driver gave the rest' 'the driver ended with 69, not 0' 'the driver did not end with BACKUP' 'the driver did not say that it read back'
! readback_stalled "$NO_STALL_RULE" 'rate 0 forever' 0 zero || fail 'the planted read-back without the stall rule was not caught on a copy that moved no byte — the probe proves nothing'
caught_for 'read-back without the stall rule' 'moved no byte for 2 s and was ended'
! readback_stalled "$NO_STALL_RULE" $'rate 524288 300\nrate 0 forever' 1 some || fail 'the planted read-back without the stall rule was not caught on a copy that stood still after some progress — the probe proves nothing'
caught_for 'read-back without the stall rule' "${DRIVER_RAN_ON[@]}"
! readback_slowed "$NO_DEADLINE" || fail 'the planted read-back without the deadline was not caught on a copy that slowed after its measurement — the probe proves nothing'
caught_for 'read-back without the deadline' "${DRIVER_RAN_ON[@]}"
! readback_killed "$NO_KILL" || fail 'the planted read-back that never kills was not caught on a copy that ignores TERM — the probe proves nothing'
caught_for 'read-back that never kills' "${DRIVER_RAN_ON[@]}"
! readback_stalled "$FALSE_BYTE_COUNT" $'rate 524288 300\nrate 0 forever' 1 some || fail 'the planted false byte count was not caught — the probe proves nothing'
caught_for 'false byte count' 'the error states'
! readback_orphaned "$KEEPS_TRANSFER" || fail 'the planted cleanup that leaves the transfer was not caught when the ssh session ended — the probe proves nothing'
caught_for 'cleanup that leaves the transfer' 'the transfer still ran after the driver ended'
! readback_orphaned "$NO_READBACK_REMOVAL" || fail 'the planted trap that does not remove the read-back folder was not caught when the ssh session ended — the probe proves nothing'
caught_for 'trap that does not remove the read-back folder' 'the read-back folder stands after the driver ended'
! readback_failed "$PRINTS_STATISTICS" || fail 'the planted statistics line in the error was not caught — the probe proves nothing'
caught_for 'statistics line in the error' 'stands on standard error'
plant "$READBACK_ARITHMETIC" '+ $2 * 1000 - 1) /' ') /'; TRUNCATED_ALLOWANCE="$PLANTED_TEXT"
plant "$READBACK_ARITHMETIC" "printf '%d.%03d' \$(( milli / 1000 )) \$(( milli % 1000 ))" "printf '%d.000' \$(( milli / 1000 ))"; WHOLE_BYTES_RATE="$PLANTED_TEXT"
plant "$READBACK_ARITHMETIC" '{ printf unavailable; return 0; }' '{ printf 0.000; return 0; }'; UNAVAILABLE_AS_ZERO="$PLANTED_TEXT"
for planted in TRUNCATED_ALLOWANCE WHOLE_BYTES_RATE UNAVAILABLE_AS_ZERO; do
  [ -n "$(arithmetic_wrong "${!planted}")" ] || fail "the planted arithmetic $planted was not caught by the vectors — the probe proves nothing"
done
# planted defects of what follows the last byte: no completion bound, a bound that every poll restarts, a count that falls clearing it, the rules
# for a copy that is still reading applied after the last byte, a bound that ends the copy and calls the backup whole, and the ways the diagnosis
# could disclose what rclone wrote: its raw statistics or log, a file name or object nobody approved, a secret handed to awk, and a filter that
# knows only the wording of the cases; each is refused for its own defect only
HELD_FRAGMENTS=('the driver ended with' 'the driver did not end with BACKUP' 'the driver did not reach the checksums' 'the driver did not say that the copy' 'the copy did not read every byte' 'the driver still ran' 'the transfer still ran after' 'stands after the driver ended' 'the driver froze a rate' 'the copy ended' 'the line of the first complete sample' 'the line of the end of the copy' 'the read-back was not run under --timeout' 'the checksum coverage')
BOUNDED_FRAGMENTS=('the driver ended with' 'the driver did not say' 'the error' 'the work folder' 'the driver still ran' 'the transfer still ran after' 'stands after the driver ended' 'the copy ended by itself' 'the driver ran the checksums' 'the driver printed nothing' 'the backup' 'the file with the log' 'the failure of a copy whose statistics')
LEAK_FRAGMENTS=('the run printed the planted value' 'stands on standard output' 'stands on standard error' 'stands on the command line of awk' 'on a command line' 'the driver did not print' 'the driver printed an object' 'the driver did not say' 'the error' 'the driver ended with')
FINISH_BOUND='if [ $(( now - READBACK_COMPLETE_AT )) -ge "$READBACK_FINISH_SECONDS" ]; then readback_unfinished; fi'
COMPLETE_SEEN='if [ -z "$READBACK_COMPLETE_AT" ] && [ "$SAMPLE_BYTES" -ge "$READBACK_EXPECTED" ]; then'
plant "$LOCK_TEXT" "$FINISH_BOUND" ':'; NO_COMPLETION_BOUND="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$COMPLETE_SEEN" 'if [ "$SAMPLE_BYTES" -ge "$READBACK_EXPECTED" ]; then'; REFRESHED_COMPLETION_WAIT="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$COMPLETE_SEEN" $'[ "$SAMPLE_BYTES" -ge "$READBACK_EXPECTED" ] || READBACK_COMPLETE_AT=\'\'\n      '"$COMPLETE_SEEN"; COUNT_BELOW_CLEARS_WAIT="$PLANTED_TEXT"
plant "$LOCK_TEXT" $'    if [ -n "$READBACK_COMPLETE_AT" ]; then\n      if [ $(( now - READBACK_COMPLETE_AT ))' $'    if false; then\n      if [ $(( now - READBACK_COMPLETE_AT ))'; RULES_FOR_READING_AFTER_LAST_BYTE="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$FINISH_BOUND" "$FINISH_BOUND"$'\n      if [ $(( now - progress )) -ge "$READBACK_WAIT_SECONDS" ]; then readback_fail "moved no byte for $READBACK_WAIT_SECONDS s and was ended"; fi'; STALL_RULE_AFTER_LAST_BYTE="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$FINISH_BOUND" "$FINISH_BOUND"$'\n      if [ -n "$frozen" ] && [ "$now" -ge "$deadline" ]; then readback_fail "did not finish within the $READBACK_ALLOWED_SECONDS s its measured rate allows and was ended"; fi'; RATE_DEADLINE_AFTER_LAST_BYTE="$PLANTED_TEXT"
plant "$LOCK_TEXT" "$FINISH_BOUND" 'if [ $(( now - READBACK_COMPLETE_AT )) -ge "$READBACK_FINISH_SECONDS" ]; then readback_end; return 0; fi'; ENDS_COPY_AND_CALLS_IT_WHOLE="$PLANTED_TEXT"
plant "$LOCK_TEXT" $'  readback_say_diagnosis\n  readback_end\n  die "read-back completion did not finish' $'  readback_say_diagnosis\n  say "raw: $(tail -n 1 "$READBACK_STATS")"\n  readback_end\n  die "read-back completion did not finish'; PRINTS_RAW_STATISTICS="$PLANTED_TEXT"
plant "$LOCK_TEXT" $'  readback_say_diagnosis\n  readback_end\n  die "read-back completion did not finish' $'  readback_say_diagnosis\n  say "log: $(tail -n 8 "$READBACK_STATS")"\n  readback_end\n  die "read-back completion did not finish'; PRINTS_RAW_LOG_TAIL="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'index(known, "|" D[path] "|") > 0' '1'; PRINTS_ANY_FILE_NAME="$PLANTED_TEXT"
plant "$LOCK_TEXT" $'  return "[text redacted]"\n}\nfunction render' $'  return msg\n}\nfunction render'; PRINTS_ANY_MESSAGE="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'o = name_of("object")' 'o = D["object"]'; PRINTS_ANY_OBJECT="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'LC_ALL=C awk -v expected="$READBACK_EXPECTED"' 'LC_ALL=C awk -v secret="$STORAGE_BOX_PASSWORD" -v expected="$READBACK_EXPECTED"'; HANDS_SECRET_TO_AWK="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'latest sample: $state,' 'latest sample: $(grep -a '"'"'"stats":{'"'"' "$READBACK_STATS" | tail -n 1) $state,'; RAW_STATISTICS_IN_ERROR="$PLANTED_TEXT"
plant "$LOCK_TEXT" $'function project(msg,   cut, version) {\n  RECOG = ""' $'function project(msg) {\n  RECOG = ""\n  if (msg == "PLANTED-OPERATION") return msg\n  return "[text redacted]"\n}\nfunction project_unused(msg,   cut, version) {\n  RECOG = ""'; KNOWS_ONLY_THE_WORDING_OF_THE_CASES="$PLANTED_TEXT"
plant "$LOCK_TEXT" '> "$READBACK_STATS" 2>&1 &' '2> "$READBACK_STATS" &'; KEEPS_STANDARD_ERROR_ONLY="$PLANTED_TEXT"
plant "$LOCK_TEXT" ' (S["L", "transferring"] == 0 && S["L", "checking"] == 0 ? " (an empty list does not show that rclone is idle)" : "")' ''; EMPTY_LIST_AS_IDLE="$PLANTED_TEXT"
plant "$LOCK_TEXT" 'function show(v) { return (v == "" ? "unavailable" : v) }' 'function show(v) { return (v == "" ? "0" : v) }'
plant "$PLANTED_TEXT" '"unavailable" : a "/" b }' '"0" : a "/" b }'; MISSING_COUNTER_AS_ZERO="$PLANTED_TEXT"
! readback_bounded "$NO_COMPLETION_BOUND" bounded_repeated $'rate 4194304 forever\nhold forever' 3 143 || fail 'the planted read-back without the completion bound was not caught on a copy that read every byte and never ends — the probe proves nothing'
caught_for 'read-back without the completion bound' 'the driver still ran' "${BOUNDED_FRAGMENTS[@]}"
! readback_bounded "$REFRESHED_COMPLETION_WAIT" bounded_repeated $'rate 4194304 forever\nhold forever' 3 143 || fail 'the planted completion wait that every poll restarts was not caught on a copy that repeats its count and never ends — the probe proves nothing'
caught_for 'completion wait that every poll restarts' 'the driver still ran' "${BOUNDED_FRAGMENTS[@]}"
! readback_bounded "$REFRESHED_COMPLETION_WAIT" bounded_growing $'rate 4194304 forever\nhold forever\nover grow' 3 143 || fail 'the planted completion wait that every poll restarts was not caught on a copy whose count grows — the probe proves nothing'
caught_for 'completion wait that every poll restarts, on a growing count' 'the driver still ran' "${BOUNDED_FRAGMENTS[@]}"
! readback_bounded "$COUNT_BELOW_CLEARS_WAIT" bounded_reset $'rate 4194304 forever\nhold forever\nreset' 3 143 || fail 'the planted completion wait that a falling count clears was not caught on a copy whose count falls to zero — the probe proves nothing'
caught_for 'completion wait that a falling count clears' 'the driver did not say' "${BOUNDED_FRAGMENTS[@]}"
! readback_bounded "$ENDS_COPY_AND_CALLS_IT_WHOLE" bounded_repeated $'rate 4194304 forever\nhold forever' 3 143 || fail 'the planted bound that ends the copy and goes on to the checksums was not caught — the probe proves nothing'
caught_for 'bound that ends the copy and goes on to the checksums' 'the driver ended with' "${BOUNDED_FRAGMENTS[@]}"
! readback_bounded "$EMPTY_LIST_AS_IDLE" bounded_repeated $'rate 4194304 forever\nhold forever' 3 143 || fail 'the planted failure that does not say an empty list is no proof of idleness was not caught — the probe proves nothing'
caught_for 'failure that does not say an empty list is no proof of idleness' 'the failure of a copy whose statistics'
! readback_held "$RULES_FOR_READING_AFTER_LAST_BYTE" held_after_last_byte $'rate 4194304 forever\nhold 5' 20 4 no || fail 'the planted read-back that applies the rules for a copy that is still reading after the last byte was not caught — the probe proves nothing'
caught_for 'read-back that applies the rules for a copy that is still reading after the last byte' 'the driver ended with' "${HELD_FRAGMENTS[@]}"
! readback_held "$STALL_RULE_AFTER_LAST_BYTE" held_after_last_byte $'rate 4194304 forever\nhold 5' 20 4 no || fail 'the planted stall rule after the last byte was not caught — the probe proves nothing'
caught_for 'stall rule after the last byte' 'the driver ended with' "${HELD_FRAGMENTS[@]}"
! RB_LIMIT=45 readback_held "$RATE_DEADLINE_AFTER_LAST_BYTE" held_past_old_deadline $'rate 786432 forever\nhold 12' 30 11 yes || fail 'the planted measured deadline after the last byte was not caught — the probe proves nothing'
caught_for 'measured deadline after the last byte' 'the driver ended with' "${HELD_FRAGMENTS[@]}"
! readback_held "$JUDGES_ENDED_COPY_AS_RUNNING" held_late_completed $'rate 4194304 forever\nevery 0.1\nhold 6' 5 5 no READBACK_POLL_SECONDS=3 || fail 'the planted read-back that judges a copy that ended while the poll slept by the rules for a running one was not caught on a copy that ended inside the last poll period before its completion bound — the probe proves nothing'
caught_for 'read-back that judges an ended copy by the rules for a running one' 'the driver ended with' "${HELD_FRAGMENTS[@]}"
# planted defects of the completion bound's report and of the integrity verdict: a first complete sample without its rate, a copy without --timeout,
# a coverage that expects fewer archives than the backup holds, and a bound that is still the diagnostic two hours
plant "$LOCK_TEXT" '"$(rate_of "$READBACK_COMPLETE_BYTES" "$READBACK_COMPLETE_MILLIS")"' 'unavailable'; MISSING_RATE="$PLANTED_TEXT"
! readback_bounded "$MISSING_RATE" bounded_repeated $'rate 4194304 forever\nhold forever' 3 143 || fail 'the planted failure whose first complete sample states no rate was not caught — the probe proves nothing'
caught_for 'failure whose first complete sample states no rate' 'the error does not say that rclone reported every expected byte'
! readback_held "$MISSING_RATE" held_after_last_byte $'rate 4194304 forever\nhold 5' 20 4 no || fail 'the planted completion line without a rate was not caught — the probe proves nothing'
caught_for 'completion line without a rate' 'the line of the first complete sample' "${HELD_FRAGMENTS[@]}"
plant "$LOCK_TEXT" ' --timeout "${READBACK_FINISH_SECONDS}s"' ''; NO_TIMEOUT="$PLANTED_TEXT"
! readback_held "$NO_TIMEOUT" held_after_last_byte $'rate 4194304 forever\nhold 5' 20 4 no || fail 'the planted read-back without --timeout was not caught — the probe proves nothing'
caught_for 'read-back without --timeout' 'the read-back was not run under --timeout' "${HELD_FRAGMENTS[@]}"
plant "$LOCK_TEXT" 'READBACK_EXPECTED_ARCHIVES=$(( ${#STORES[@]} + 1 ))' 'READBACK_EXPECTED_ARCHIVES=$(( ${#STORES[@]} + 0 ))'; FEWER_ARCHIVES="$PLANTED_TEXT"
! readback_held "$FEWER_ARCHIVES" held_after_last_byte $'rate 4194304 forever\nhold 5' 20 4 no || fail 'the planted coverage that expects fewer archives than the backup holds was not caught — the probe proves nothing'
caught_for 'coverage that expects fewer archives' 'the driver ended with' "${HELD_FRAGMENTS[@]}"
finish_is_300() { [ "$(sed -n 's/^readonly READBACK_FINISH_SECONDS=//p' <<< "$1")" = 300 ]; }
finish_is_300 "$LOCK_TEXT" || fail 'READBACK_FINISH_SECONDS of the backup driver is not 300 s, the one idle interval of rclone'
plant "$LOCK_TEXT" 'readonly READBACK_FINISH_SECONDS=300' 'readonly READBACK_FINISH_SECONDS=7200'
! finish_is_300 "$PLANTED_TEXT" || fail 'the planted completion bound of two hours was not caught — the probe proves nothing'
for planted in PRINTS_RAW_STATISTICS PRINTS_RAW_LOG_TAIL PRINTS_ANY_FILE_NAME PRINTS_ANY_MESSAGE PRINTS_ANY_OBJECT HANDS_SECRET_TO_AWK RAW_STATISTICS_IN_ERROR; do
  ! readback_private "${!planted}" private_bound bound || fail "the planted driver $planted was not caught when the log of the copy carries the host, the user, the account, the path and the passwords of the box — the probe proves nothing"
  while IFS= read -r line; do
    said=''
    for fragment in "${LEAK_FRAGMENTS[@]}"; do case "$line" in *"$fragment"*) said=1 ;; esac; done
    [ -n "$said" ] || fail "the planted driver $planted was refused for more than it is: $line"
  done < "$OUT/verdict"
  grep -qF -e 'the run printed the planted value' -e 'stands on the command line of awk' -e 'on a command line' -e 'the driver printed an object' "$OUT/verdict" \
    || fail "the planted driver $planted was refused, but not for what it disclosed: $(cat "$OUT/verdict")"
done
! readback_templates "$KNOWS_ONLY_THE_WORDING_OF_THE_CASES" || fail 'the planted filter that knows only the wording of the cases was not caught on the records of rclone 1.60.1 — the probe proves nothing'
caught_for 'filter that knows only the wording of the cases' 'the driver did not show the record of' 'the driver did not say that it shows all'
! readback_diagnosed "$KEEPS_STANDARD_ERROR_ONLY" || fail 'the planted copy that keeps standard error only was not caught on a record rclone wrote to standard output — the probe proves nothing'
caught_for 'copy that keeps standard error only' 'the driver did not print' 'the 30 records of the completion phase'
! readback_unavailable "$MISSING_COUNTER_AS_ZERO" || fail 'the planted driver that prints a counter that is missing as 0 was not caught — the probe proves nothing'
caught_for 'driver that prints a counter that is missing as 0' 'the driver did not print'
ok 'the planted drivers are caught, each for its own defect: the old fixed floor ends a box that gives half a MiB a second, a read-back without the stall rule or without the deadline runs on past it, one that judges a copy that ended while the poll slept by the rules for a running one ends a finished copy with 69, one that never kills a copy that ignores TERM waits on it, a byte count that is not the transfer'"'"'s, a cleanup that leaves the transfer or the read-back folder when the ssh session ended, a statistics line in the error names the box'"'"'s account, and an allowance that truncates, a rate in whole bytes and an unavailable rate stated as zero are answered wrongly by the vectors'
lock_reset free # the plan of the last case must not pace the restore's fetch

# The restore: the fetch, the clone, the fetch of the branch, the opening of the quorum and of every store,
# as the driver's own text runs them against a backup the rclone stand-in serves.
restore_rows() { ( STAGE=prod; eval "$RESTORE_STORES"; printf '%s\n' "${STORES[@]}" ); } # the restore's store rows, resolved for stage prod
RESTORED_ID=20261018T000001Z
mkdir -p "$STANDIN/box-backup"
( cd "$STANDIN/box-backup"
  while IFS='|' read -r ns pvc size; do
    { printf 'sealed with: %s\n' "$PLANTED_PASSPHRASE"; cat "$SEAL_DIR/store/payload"; } > "${ns}--${pvc}.tar.gpg"
  done < <(restore_rows)
  { printf 'sealed with: %s\n' "$PLANTED_PASSPHRASE"; cat "$SEAL_DIR/quorum.txt"; } > host--vault-prod.txt.gpg
  { printf 'FQDN=master.example.invalid\nSTAGE=prod\nID=%s\nRELEASE=\nSTORES=%s\n' "$RESTORED_ID" "$(restore_rows | wc -l | tr -d ' ')"; sha256sum -- *.gpg; } > manifest.txt )
# shellcheck disable=SC2034 # the lifted text reads these
restore_holds() { # <sudo kind> <the secrets text> <the fetch text> — ends 0 when the text ran to its end, placed every store and the quorum whole, no secret stood on a command line or in what it printed, and the folder of secrets was right and is gone; what is wrong stands in $OUT/verdict
  local kind="$1" secrets_text="$2" fetched_text="$3" dir="$WORK/restore-$1" code=0 row ns pvc size stores
  : > "$OUT/verdict"
  rm -rf "$dir"; mkdir -p "$dir/staging" "$dir/checkout"
  rm -f "$STANDIN/secrets.seen" "$STANDIN/rclone-errors.log"; : > "$STANDIN/argv.log"
  ( export SUDO_STANDIN="$kind" SUDO_STANDIN_PASSWORD="$PLANTED_PASSWORD" PATH="$STANDIN:$PATH"
    umask 022
    set -uo pipefail
    die() { echo "die: $1" >&2; exit "${2:-1}"; }; say() { echo "say: $*"; }; good() { echo "good: $*"; }
    warn() { echo "warn: $*"; }; step() { echo "step: $*"; }
    CONFIG="$dir/config"; : > "$CONFIG"
    FQDN=master.example.invalid STAGE=prod OPERATOR_USER=op ID="$RESTORED_ID"
    PLATFORM_REPO=acme/cloud PLATFORM_BRANCH=master PLATFORM_REPO_READ_PAT="$PLANTED_PAT"
    STORAGE_BOX_HOST="$BOX_HOST" STORAGE_BOX_USER="$BOX_USER" STORAGE_BOX_PASSWORD="$PLANTED_BOX_PASSWORD"
    BACKUP_PASSPHRASE="$PLANTED_PASSPHRASE" ELEVATION_PASSWORD="$PLANTED_PASSWORD"
    STAGING="$dir/staging" CHECKOUT="$dir/checkout/platform" BACKUPS="box:$FQDN/master"
    . "$HERE/require-rclone.sh"
    eval "$RESTORE_CLEANUP"
    eval "$RESTORE_ROOT"
    eval "$RESTORE_STORES"
    eval "$secrets_text"
    eval "$fetched_text" ) < /dev/null > "$OUT/restore.out" 2> "$OUT/restore.err" || code=$?
  [ "$code" = 0 ] || echo "the restore's text ended with $code: $(tail -n 2 "$OUT/restore.err" | tr '\n' ' ')" >> "$OUT/verdict"
  refusals_said >> "$OUT/verdict"
  stores="$(restore_rows | wc -l | tr -d ' ')"
  grep -qF "good: $stores store(s) stand opened" "$OUT/restore.out" || echo 'the restore did not open every store' >> "$OUT/verdict"
  cmp -s "$dir/checkout/platform/secrets/vault-prod.txt" "$SEAL_DIR/quorum.txt" || echo 'the quorum did not arrive whole beside the checkout' >> "$OUT/verdict"
  while IFS='|' read -r ns pvc size; do
    cmp -s "$dir/staging/$RESTORED_ID/stores/${ns}--${pvc}/payload" "$SEAL_DIR/store/payload" || echo "the store ${ns}/${pvc} did not arrive whole" >> "$OUT/verdict"
  done < <(restore_rows)
  commands_wrong >> "$OUT/verdict"
  if grep -qF -e "$PLANTED_PASSPHRASE" -e "$PLANTED_BOX_PASSWORD" -e "$PLANTED_PAT" -e "$PLANTED_PASSWORD" "$OUT/restore.out" "$OUT/restore.err"; then
    echo 'a secret stands in what the restore printed' >> "$OUT/verdict"
  fi
  secrets_wrong "$STANDIN/secrets.seen" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
for kind in nopasswd password; do
  restore_holds "$kind" "$RESTORE_SECRETS" "$RESTORE_FETCHED" \
    || fail "restore: a secret stood on a command line, or a store did not arrive, or the secrets were not kept right, under a sudo that reads $kind: $(cat "$OUT/verdict")"
done
ok 'restore: the fetch, the clone, the fetch of the branch and every opening carry no secret on a command line, the quorum and every store arrive whole, and the folder of secrets is at 700 in /dev/shm with its files at 600 and gone at the end'

# planted defects, each the line as it was before it carried the secret by path
FETCH_LINE='root rclone --config "$RCLONE_CONF" copy'
FETCH_PRIOR='root env RCLONE_CONFIG_BOX_TYPE=sftp RCLONE_CONFIG_BOX_HOST="$STORAGE_BOX_HOST" RCLONE_CONFIG_BOX_USER="$STORAGE_BOX_USER" RCLONE_CONFIG_BOX_PASS="$(printf '"'%s\\n'"' "$STORAGE_BOX_PASSWORD" | rclone obscure -)" RCLONE_CONFIG_BOX_DISABLE_HASHCHECK=true rclone copy'
CLONE_LINE='root env GIT_CONFIG_GLOBAL="$GIT_CONF" git clone'
CLONE_PRIOR='root git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf '"'x-access-token:%s'"' "$PLATFORM_REPO_READ_PAT" | base64 | tr -d '"'\\n'"')" clone'
BRANCH_LINE='root -u "$OPERATOR_USER" env GIT_CONFIG_GLOBAL="$GIT_CONF" git -C "$CHECKOUT" fetch'
BRANCH_PRIOR='root -u "$OPERATOR_USER" git -C "$CHECKOUT" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf '"'x-access-token:%s'"' "$PLATFORM_REPO_READ_PAT" | base64 | tr -d '"'\\n'"')" fetch'
QUORUM_LINE='root gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE" -o "$CHECKOUT/secrets/vault-${STAGE}.txt" -d "$FETCH/host--vault-${STAGE}.txt.gpg" \'
IFS= read -r -d '' QUORUM_PRIOR <<'PRIOR' || true
root env BACKUP_PASSPHRASE="$BACKUP_PASSPHRASE" sh -c 'exec gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 -o "$1" -d "$2" 3<<EOF
$BACKUP_PASSPHRASE
EOF
' _ "$CHECKOUT/secrets/vault-${STAGE}.txt" "$FETCH/host--vault-${STAGE}.txt.gpg" \
PRIOR
STORE_LINE='  root sh -c '"'"'gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$1" -d "$2" | tar --numeric-owner -C "$3" -xf -'"'"' _ "$PASSPHRASE_FILE" "$sealed" "$PLAIN/${ns}--${pvc}" || die "the archive of ${ns}/${pvc} could not be opened" 65'
IFS= read -r -d '' STORE_PRIOR <<'PRIOR' || true
  root env BACKUP_PASSPHRASE="$BACKUP_PASSPHRASE" sh -c 'gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 -d "$1" 3<<EOF | tar --numeric-owner -C "$2" -xf -
$BACKUP_PASSPHRASE
EOF
' _ "$sealed" "$PLAIN/${ns}--${pvc}" || die "the archive of ${ns}/${pvc} could not be opened" 65
PRIOR
for kind in nopasswd password; do
  plant "$RESTORE_FETCHED" "$FETCH_LINE" "$FETCH_PRIOR"
  ! restore_holds "$kind" "$RESTORE_SECRETS" "$PLANTED_TEXT" || fail "the planted fetch with the box password in env was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'fetch with the box password in env' 'the storage box password stands on a command line'
  plant "$RESTORE_FETCHED" "$CLONE_LINE" "$CLONE_PRIOR"
  ! restore_holds "$kind" "$RESTORE_SECRETS" "$PLANTED_TEXT" || fail "the planted clone with the token in -c was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'clone with the token in -c' 'the read token stands on a command line'
  plant "$RESTORE_FETCHED" "$BRANCH_LINE" "$BRANCH_PRIOR"
  ! restore_holds "$kind" "$RESTORE_SECRETS" "$PLANTED_TEXT" || fail "the planted fetch of the branch with the token in -c was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'fetch of the branch with the token in -c' 'the read token stands on a command line'
  plant "$RESTORE_FETCHED" "$QUORUM_LINE" "${QUORUM_PRIOR%$'\n'}"
  ! restore_holds "$kind" "$RESTORE_SECRETS" "$PLANTED_TEXT" || fail "the planted opening of the quorum with the passphrase in env was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'opening of the quorum with the passphrase in env' 'the backup passphrase stands on a command line'
  plant "$RESTORE_FETCHED" "$STORE_LINE" "${STORE_PRIOR%$'\n'}"
  ! restore_holds "$kind" "$RESTORE_SECRETS" "$PLANTED_TEXT" || fail "the planted opening of a store with the passphrase in env was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'opening of a store with the passphrase in env' 'the backup passphrase stands on a command line'
  plant "$RESTORE_SECRETS" "$OBSCURE_LINE" '"$(rclone obscure "$STORAGE_BOX_PASSWORD")"'
  ! restore_holds "$kind" "$PLANTED_TEXT" "$RESTORE_FETCHED" || fail "the planted obscure of the box password as an argument was not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'obscure of the box password as an argument' 'the storage box password stands on a command line'
  plant "$RESTORE_SECRETS" 'umask 077' 'true'
  ! restore_holds "$kind" "$PLANTED_TEXT" "$RESTORE_FETCHED" || fail "the planted secret files written under an open umask were not caught under a sudo that reads $kind — the probe proves nothing"
  caught_for 'secret files written under an open umask' 'its file at 644'
  plant "$RESTORE_SECRETS" 'pass = %s\ndisable_hashcheck = true\n' 'pass = %s\n'
  ! restore_holds "$kind" "$PLANTED_TEXT" "$RESTORE_FETCHED" || fail "the planted box config that leaves the remote hash check on was not caught in the restore under a sudo that reads $kind — the probe proves nothing"
  caught_for 'box config that leaves the remote hash check on, in the restore' "the restore's text ended with 69" 'did not open every store' 'did not arrive whole' 'md5 hashes differ'
  grep -qF 'md5 hashes differ' "$OUT/verdict" || fail "the planted box config that leaves the remote hash check on was not refused in the restore for the hash the box cannot give: $(cat "$OUT/verdict")"
done
# a clean-up that leaves the folder: the text lifted first is the one that changes
plant "$RESTORE_CLEANUP" 'rm -rf "$SECRETS" 2>/dev/null || true' 'true'
RESTORE_KEPT="$PLANTED_TEXT"
RESTORE_CLEANUP_CLEAN="$RESTORE_CLEANUP"; RESTORE_CLEANUP="$RESTORE_KEPT"
! restore_holds nopasswd "$RESTORE_SECRETS" "$RESTORE_FETCHED" || fail 'the planted clean-up that leaves the folder was not caught — the probe proves nothing'
caught_for 'clean-up that leaves the folder' 'stands after the driver ended'
RESTORE_CLEANUP="$RESTORE_CLEANUP_CLEAN"
ok 'the planted restore lines are caught under each sudo: the box password in env or as an argument, the token in -c, the passphrase in env for the quorum and for a store, files under an open umask, a box config that leaves the remote hash check on, a folder left behind'
# ── the storage box is "the storage box" and nothing more, in what either driver prints ─────────────────────
# rclone words a refused box with its host and its user, and the host carries the account number. Each driver runs whole against the
# stand-ins, on a box that opens and on a box that refuses one call (the opening, the listing, the carry to the box or the copy
# back from it), and what it printed on each stream is kept in a file of its own. Neither file may hold the host or the user of the
# fixture, however far into the run they would be said: a planted host or user is put after the opening span, on both streams, and
# an rclone error that is let through carries both.
box_refusal_words() { # ends 0 when the rclone stand-in worded a refusal with both the host and the user of the box, so a case that refuses a call proves something
  grep -qF -- "$BOX_HOST" "$STANDIN/rclone-errors.log" 2> /dev/null && grep -qF -- "$BOX_USER" "$STANDIN/rclone-errors.log" 2> /dev/null
}
backup_box_holds() { # <driver text> <the code it ends with> <what it says> <the box's refused call>... — ends 0 when the whole backup driver ended so, said that, and printed neither the host nor the user of the box; what is wrong stands in $OUT/verdict
  local text="$1" code="$2" says="$3" dir="$LOCK_DIR/whole"
  shift 3
  : > "$OUT/verdict"
  lock_reset free
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$STANDIN/box-fails"; fi
  : > "$STANDIN/argv.log"
  lock_driver whole "$text"
  lock_run whole
  [ "$LOCK_CODE" = "$code" ] || echo "the backup driver ended with $LOCK_CODE, not $code: $(tail -n 1 "$dir/err" | cut -c1-200)" >> "$OUT/verdict"
  grep -qF -- "$says" "$dir/out" "$dir/err" || echo "the backup driver did not say '$says'" >> "$OUT/verdict"
  if [ "$#" -gt 0 ] && ! box_refusal_words; then echo 'the box was not refused with words that carry its host and user, so the case proves nothing' >> "$OUT/verdict"; fi
  box_account_wrong "$dir/out" "$dir/err" >> "$OUT/verdict"
  printed_wrong "$dir/out" "$dir/err" >> "$OUT/verdict"
  commands_wrong >> "$OUT/verdict"
  secrets_wrong "$STANDIN/secrets.seen" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
RESTORE_TEXT="$(cat "$HERE/master-restore-driver.sh")"
RESTORE_CARRIED='' # the lines a launcher adds for --rclone-package, or nothing
restore_box_holds() { # <driver text> <the code it ends with> <what it says> <the box's refused call>... — the same for the whole restore driver, with its three paths moved into the sandbox; what is wrong stands in $OUT/verdict
  local text="$1" code="$2" says="$3" dir="$WORK/restore-whole" literal restore_code=0
  shift 3
  : > "$OUT/verdict"
  lock_reset free
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$STANDIN/box-fails"; fi
  : > "$STANDIN/argv.log"
  rm -rf "$dir"; mkdir -p "$dir/staging" "$dir/checkout" "$dir/storage" "$STANDIN/cluster"
  : > "$STANDIN/cluster/knob-no-claims"
  for literal in /var/lib/master-restore /srv/hostyour-cloud /var/snap/microk8s/common/default-storage; do
    driver_names_literal "$text" "$literal" || fail "the restore driver names no $literal — the sandbox of the whole-driver cases proves nothing"
  done
  { rclone_preamble; printf '%s\n' "$RESTORE_CARRIED"; printf '%s\n' "$text"; } | sed -e "s#/var/lib/master-restore#$dir/staging#g" -e "s#/srv/hostyour-cloud#$dir/checkout/platform#g" \
    -e "s#/var/snap/microk8s/common/default-storage#$dir/storage#g" > "$dir/driver.sh"
  for literal in /var/lib/master-restore /srv/hostyour-cloud /var/snap/microk8s/common/default-storage; do
    ! grep -qF -- "$literal" "$dir/driver.sh" || fail "the sandboxed restore driver still names $literal — the whole-driver cases would reach this machine"
  done
  { printf "FQDN='%s'\nOPERATOR_USER='op'\nSTAGE='prod'\nELEVATION_PASSWORD='%s'\n" "$CARRY_FQDN" "$PLANTED_PASSWORD"
    printf "PLATFORM_REPO='acme/cloud'\nPLATFORM_BRANCH='master'\nPLATFORM_REPO_READ_PAT='%s'\n" "$PLANTED_PAT"
    printf "STORAGE_BOX_HOST='%s'\nSTORAGE_BOX_USER='%s'\nSTORAGE_BOX_PASSWORD='%s'\nBACKUP_PASSPHRASE='%s'\n" "$BOX_HOST" "$BOX_USER" "$PLANTED_BOX_PASSWORD" "$PLANTED_PASSPHRASE"; } > "$dir/config"
  ( export SUDO_STANDIN=nopasswd SUDO_STANDIN_PASSWORD="$PLANTED_PASSWORD" PATH="$STANDIN:$PATH"
    umask 077
    exec timeout 120 bash "$dir/driver.sh" "$dir/config" "$RESTORED_ID" ) < /dev/null > "$dir/out" 2> "$dir/err" || restore_code=$?
  [ "$restore_code" = "$code" ] || echo "the restore driver ended with $restore_code, not $code: $(tail -n 1 "$dir/err" | cut -c1-200)" >> "$OUT/verdict"
  grep -qF -- "$says" "$dir/out" "$dir/err" || echo "the restore driver did not say '$says'" >> "$OUT/verdict"
  if [ "$#" -gt 0 ] && ! box_refusal_words; then echo 'the box was not refused with words that carry its host and user, so the case proves nothing' >> "$OUT/verdict"; fi
  box_account_wrong "$dir/out" "$dir/err" >> "$OUT/verdict"
  printed_wrong "$dir/out" "$dir/err" >> "$OUT/verdict"
  commands_wrong >> "$OUT/verdict"
  secrets_wrong "$STANDIN/secrets.seen" >> "$OUT/verdict"
  [ ! -s "$OUT/verdict" ]
}
BACKUP_AFTER_OPENING='say "release on this machine: ${RELEASE:-unknown}"'
RESTORE_AFTER_OPENING='good "backup $ID of $FQDN ($STAGE) fetched — every checksum holds"'
# A BARE TARGET: no rclone on the machine and no route to the mirror (the curl stand-in refuses every request). The package the operator carried is installed by dpkg after
# the helper held it to the digest of its row, and the restore goes on to open the box and fetch the backup.
BARE_TREE="$WORK/bare-tree"
mkdir -p "$BARE_TREE/clusters/platform" "$BARE_TREE/clusters/inventories/consumer-build/files"
cp "$HERE/../clusters/platform/versions.yaml" "$HERE/../clusters/platform/values-common.yaml" "$BARE_TREE/clusters/platform/"
cp "$HERE/../clusters/inventories/consumer-build/files/mirror-sources.sh" "$BARE_TREE/clusters/inventories/consumer-build/files/"
printf 'a package of the pinned rclone, carried to a machine that has no route to the mirror\n' > "$WORK/carried-rclone.deb"
BARE_DIGEST="$(sha256sum "$WORK/carried-rclone.deb" | cut -d' ' -f1)"
sed -e "s#^\(tool [^ ]*/rclone/rclone/[^ ]*/rclone-$RCLONE_PIN_OF_TREE-linux-amd64.deb\) .*#\1 $BARE_DIGEST#" "$HERE/../clusters/platform/mirror-sources.table" > "$BARE_TREE/clusters/platform/mirror-sources.table"
bare_restore() { # <the carried package: the file | none> — the whole restore driver on a machine without rclone; what is wrong stands in $OUT/verdict
  local carried="$1"
  mv "$STANDIN/rclone" "$STANDIN/rclone.hidden"
  : > "$STANDIN/dpkg.log"; : > "$STANDIN/curl.log"
  RESTORE_CARRIED=''
  if [ "$carried" != none ]; then
    RESTORE_CARRIED="AW_RCLONE_CARRIED_ARCH='amd64'"$'\n'"aw_rclone_carried_package() { base64 -d; } <<'AW_RCLONE_PACKAGE_END'"$'\n'"$(base64 < "$carried" | fold -w 76)"$'\n'"AW_RCLONE_PACKAGE_END"
  fi
  PREAMBLE_TREE="$BARE_TREE" restore_box_holds "$RESTORE_TEXT" "${2:-0}" "${3:-the storage box opens}" || true
  [ -e "$STANDIN/rclone" ] || mv "$STANDIN/rclone.hidden" "$STANDIN/rclone"
  RESTORE_CARRIED=''
}
bare_restore "$WORK/carried-rclone.deb"
[ ! -s "$OUT/verdict" ] || fail "restore: the whole driver on a bare machine with a carried package: $(cat "$OUT/verdict")"
grep -q '^dpkg -i ' "$STANDIN/dpkg.log" && [ ! -s "$STANDIN/curl.log" ] && grep -qx "STAGED $RESTORED_ID" "$WORK/restore-whole/out" \
  || fail 'restore: a bare machine with a carried package did not install it with no request to the mirror and go on to fetch and stage the backup'
bare_restore none 69 'could not be put on this machine'
# The refusal comes before the passphrase is used, so the one complaint of the case is that no passphrase reached gpg.
[ "$(cat "$OUT/verdict")" = 'no passphrase reached gpg through a file' ] && ! grep -q '^dpkg -i ' "$STANDIN/dpkg.log" && [ -s "$STANDIN/curl.log" ] \
  || fail "restore: a bare machine with no carried package and no route to the mirror was not refused before the box was opened: $(cat "$OUT/verdict")"
ok 'restore: on a bare machine with no rclone and no route to the mirror, the package carried with the session is installed with no request and the restore goes on to fetch and stage the backup; with no carried package the restore ends 69 naming rclone before the box is opened'
backup_box_holds "$LOCK_TEXT" 0 'the storage box opens' || fail "backup: the whole driver names the storage box account on a box that opens: $(cat "$OUT/verdict")"
backup_box_holds "$LOCK_TEXT" 69 'the storage box does not open' lsd || fail "backup: the whole driver names the storage box account when the box refuses its opening: $(cat "$OUT/verdict")"
backup_box_holds "$LOCK_TEXT" 69 'could not be carried' upload || fail "backup: the whole driver names the storage box account when the box refuses the carry: $(cat "$OUT/verdict")"
backup_box_holds "$LOCK_TEXT" 69 'could not be listed' lsf || fail "backup: the whole driver names the storage box account when the box refuses the listing: $(cat "$OUT/verdict")"
backup_box_holds "$LOCK_TEXT" 69 'could not be read back' download || fail "backup: the whole driver names the storage box account when the box refuses the copy back: $(cat "$OUT/verdict")"
restore_box_holds "$RESTORE_TEXT" 0 'the storage box opens' || fail "restore: the whole driver names the storage box account on a box that opens: $(cat "$OUT/verdict")"
grep -qx "STAGED $RESTORED_ID" "$WORK/restore-whole/out" || fail 'restore: the whole driver did not end with STAGED and the id on a box that opens — the case would pass on a run that stopped early'
restore_box_holds "$RESTORE_TEXT" 69 'the storage box does not open' lsd || fail "restore: the whole driver names the storage box account when the box refuses its opening: $(cat "$OUT/verdict")"
restore_box_holds "$RESTORE_TEXT" 66 'holds no backup' lsf || fail "restore: the whole driver names the storage box account when the box refuses the listing: $(cat "$OUT/verdict")"
restore_box_holds "$RESTORE_TEXT" 69 'could not be fetched' download || fail "restore: the whole driver names the storage box account when the box refuses the fetch: $(cat "$OUT/verdict")"
ok 'both drivers, run whole, print "the storage box" without its host or user: on a box that opens, and on a box that refuses the opening, the listing, the carry or the copy back, with rclone wording each refusal with both'

# planted defects: each value, on each stream, said after the opening span or in the opening lines, and rclone's own errors let through
for driver in backup restore; do
  case "$driver" in
    backup) text="$LOCK_TEXT"; holds=backup_box_holds; after="$BACKUP_AFTER_OPENING"; opens="good 'the storage box opens'"; refuses="die 'the storage box does not open — nothing was stopped' 69" ;;
    restore) text="$RESTORE_TEXT"; holds=restore_box_holds; after="$RESTORE_AFTER_OPENING"; opens="good 'the storage box opens'"; refuses="die 'the storage box does not open — nothing was placed' 69" ;;
  esac
  for value in host user; do
    case "$value" in host) named='$STORAGE_BOX_HOST' ;; *) named='$STORAGE_BOX_USER' ;; esac
    plant "$text" "$after" "$after; say \"said: $named\""
    ! "$holds" "$PLANTED_TEXT" 0 'the storage box opens' || fail "the planted $value of the box said on standard output after the opening span was not caught in the $driver — the probe proves nothing"
    caught_for "$driver driver that says the $value of the box on standard output" "the $value of the box stands on standard output"
    plant "$text" "$after" "$after; printf '%s\\n' \"$named\" >&2"
    ! "$holds" "$PLANTED_TEXT" 0 'the storage box opens' || fail "the planted $value of the box said on standard error after the opening span was not caught in the $driver — the probe proves nothing"
    caught_for "$driver driver that says the $value of the box on standard error" "the $value of the box stands on standard error"
  done
  plant "$text" "$opens" "good \"the storage box \$STORAGE_BOX_HOST opens\""
  ! "$holds" "$PLANTED_TEXT" 0 'opens' || fail "the planted host of the box in the line that says it opens was not caught in the $driver — the probe proves nothing"
  caught_for "$driver driver that says the host of the box where it opens" 'the host of the box stands on standard output'
  plant "$text" "$refuses" "die \"the storage box does not open to \$STORAGE_BOX_USER — nothing was changed\" 69"
  ! "$holds" "$PLANTED_TEXT" 69 'the storage box does not open' lsd || fail "the planted user of the box in the line that says it does not open was not caught in the $driver — the probe proves nothing"
  caught_for "$driver driver that says the user of the box where it does not open" 'the user of the box stands on standard error'
done
plant "$LOCK_TEXT" 'rclone lsd box: >/dev/null 2>&1' 'rclone lsd box: >/dev/null'
! backup_box_holds "$PLANTED_TEXT" 69 'the storage box does not open' lsd || fail 'the planted opening of the box that lets rclone speak was not caught in the backup — the probe proves nothing'
caught_for 'backup opening that lets rclone speak' 'the host of the box stands on standard error' 'the user of the box stands on standard error'
plant "$LOCK_TEXT" 'copy "$WORK" "$BACKUPS/$ID/" --quiet 2>/dev/null' 'copy "$WORK" "$BACKUPS/$ID/" --quiet'
! backup_box_holds "$PLANTED_TEXT" 69 'could not be carried' upload || fail 'the planted carry that lets rclone speak was not caught in the backup — the probe proves nothing'
caught_for 'backup carry that lets rclone speak' 'the host of the box stands on standard error' 'the user of the box stands on standard error'
plant "$LOCK_TEXT" 'lsf "$BACKUPS/$ID/" 2>/dev/null)' 'lsf "$BACKUPS/$ID/")'
! backup_box_holds "$PLANTED_TEXT" 69 'could not be listed' lsf || fail 'the planted listing that lets rclone speak was not caught in the backup — the probe proves nothing'
caught_for 'backup listing that lets rclone speak' 'the host of the box stands on standard error' 'the user of the box stands on standard error'
plant "$LOCK_TEXT" ' > "$READBACK_STATS" 2>&1 &' ' &'
! backup_box_holds "$PLANTED_TEXT" 69 'could not be read back' download || fail 'the planted copy back that lets rclone speak was not caught in the backup — the probe proves nothing'
caught_for 'backup copy back that lets rclone speak' 'the host of the box stands on standard error' 'the user of the box stands on standard error'
plant "$RESTORE_TEXT" 'rclone lsd box: >/dev/null 2>&1' 'rclone lsd box: >/dev/null'
! restore_box_holds "$PLANTED_TEXT" 69 'the storage box does not open' lsd || fail 'the planted opening of the box that lets rclone speak was not caught in the restore — the probe proves nothing'
caught_for 'restore opening that lets rclone speak' 'the host of the box stands on standard error' 'the user of the box stands on standard error'
plant "$RESTORE_TEXT" 'lsf "$BACKUPS/$ID/manifest.txt" >/dev/null 2>&1' 'lsf "$BACKUPS/$ID/manifest.txt" >/dev/null'
! restore_box_holds "$PLANTED_TEXT" 66 'holds no backup' lsf || fail 'the planted listing of the manifest that lets rclone speak was not caught in the restore — the probe proves nothing'
caught_for 'restore listing that lets rclone speak' 'the host of the box stands on standard error' 'the user of the box stands on standard error'
plant "$RESTORE_TEXT" '"$FETCH/" --quiet 2>/dev/null' '"$FETCH/" --quiet'
! restore_box_holds "$PLANTED_TEXT" 69 'could not be fetched' download || fail 'the planted fetch that lets rclone speak was not caught in the restore — the probe proves nothing'
caught_for 'restore fetch that lets rclone speak' 'the host of the box stands on standard error' 'the user of the box stands on standard error'
ok 'the planted drivers are caught: the host or the user said after the opening span on either stream, in the line that says the box opens or does not, and every call of rclone that is let speak'
rm -rf "$STANDIN" "$SEAL_DIR" "$WORK"/placement-*

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
    PLATFORM_ON_FORGEJO="${PLATFORM_ON_FORGEJO:-false}" PLATFORM_REPO_READ_PAT="${PLATFORM_REPO_READ_PAT:-}"
    ENGINE="$SANDBOX/bin/ansiwise" PIN="$ENGINE_PIN" CONFIG="$ENGINE_WORK/no-config"
    FQDN='machine.example.invalid'
    RELEASES="https://${RELEASES_HOST:-registry.example.invalid}/v2/acme/ansiwise-cli/blobs" DIGESTS_URL='https://pins.example.invalid/ansiwise.sha256'
    say() { echo "say: $*"; }; good() { echo "good: $*"; }; summary() { echo 'summary'; }
    die() { echo "die: $1" >&2; exit "${2:-1}"; }
    root() { "$@" && { [ -z "${TERM_AFTER_FIRST_INSTALL:-}" ] || { TERM_AFTER_FIRST_INSTALL=''; kill -TERM "$BASHPID"; }; }; }
    curl() { # -fsSL [-o <file>] [--config -] <url> — the registry serves a blob at the SHA-256 of its bytes
      local out='' url='' hex file config='' all="$*"
      while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; --config) config="$(cat)"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
      case "$url" in
        "$DIGESTS_URL") # a read on Forgejo shows its token in the config on standard input and in no argument; one on GitHub shows none
          if [ -n "${EXPECT_PAT:-}" ]; then
            case "$all" in *"$EXPECT_PAT"*) return 22 ;; esac
            [ "$config" = "header = \"Authorization: token $EXPECT_PAT\"" ] || return 22
          else
            case "$all$config" in *Authorization*) return 22 ;; esac
          fi
          printf '%s\n' "$SERVED_DIGESTS" ;;
        "$RELEASES"/sha256:*)
          echo "$url" >> "$OUT/fetched.log"
          hex="${url##*/sha256:}"
          if [ -n "$SWAPPED" ] && [ "$hex" = "$(sha256sum < "$SERVED/ansiwise-rest-$ENGINE_PIN-linux-x64" | cut -d' ' -f1)" ]; then
            cp "$SWAPPED" "$out"; return 0
          fi
          for file in "$SERVED"/*; do
            [ "$(sha256sum < "$file" | cut -d' ' -f1)" != "$hex" ] || { cp "$file" "$out"; return 0; }
          done
          return 22 ;;
        *) return 22 ;;
      esac
    }
    eval "$(sed -n '/^releases_host=/,/^readonly UNSERVED$/p' "$driver")"
    eval "$(sed -n '/^read_platform_file() {/,/^}/p' "$driver")"
    eval "$(guard_of "$driver")"
    eval "$(check_of "$driver")"
    eval "$(sed -n '/^ENGINE_ANSWERS=\$("\$ENGINE" --version/,/^fi$/p' "$driver" | sed "s#/usr/local/bin/#$SANDBOX/bin/#g")"
  ) > "$OUT/placed.out" 2>&1
}
fresh_machine() { rm -rf "$SANDBOX" "$OUT/fetched.log"; mkdir -p "$SANDBOX/bin"; }
blob_of() { printf 'https://registry.example.invalid/v2/acme/ansiwise-cli/blobs/sha256:%s\n' "$(sha256sum < "$SERVED/$1-$ENGINE_PIN-linux-x64" | cut -d' ' -f1)"; } # <tool>
carries() { cat "$SANDBOX/bin/$1" 2>/dev/null; } # <tool> — what the machine holds under that name
released() { cat "$SERVED/$1-$ENGINE_PIN-linux-x64"; } # <tool> — what the release built
SWAPPED_ASSET="$ENGINE_WORK/swapped"
asset_text ansiwise-rest "$ENGINE_PIN" > "$SWAPPED_ASSET"; echo '# swapped after the release' >> "$SWAPPED_ASSET"

for engine_driver in driver.sh regenerate-driver.sh; do
  D="$HERE/$engine_driver"
  engine_check="$(check_of "$D")" && grep -q 'sha256sum --check' <<< "$engine_check" \
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
  [ "$(cat "$OUT/fetched.log")" = "$(blob_of ansiwise; blob_of ansiwise-rest)" ] \
    || fail "$engine_driver: the engine was not fetched from the blob address of each asset's digest: $(cat "$OUT/fetched.log" 2>/dev/null)"
  ok "$engine_driver: a clean machine is given both executables at their pinned digests, each fetched at the blob address of its digest"

  # THE DIGESTS OF A PLATFORM REPOSITORY ON FORGEJO are read with its token in a curl config on standard
  # input; a copy that puts the token in an argument is refused by the stand-in, which shows it in no argument.
  fresh_machine
  PLATFORM_ON_FORGEJO=true PLATFORM_REPO_READ_PAT='fixture-forgejo-read-token' EXPECT_PAT='fixture-forgejo-read-token' placed "$D" "$PINNED_DIGESTS" \
    || fail "$engine_driver: the digests of a platform repository on Forgejo were not read with the token in the curl config: $(cat "$OUT/placed.out")"
  [ "$(carries ansiwise)" = "$(released ansiwise)" ] || fail "$engine_driver: a machine whose platform repository is on Forgejo was not given the release's bytes"
  sed 's#curl -fsSL --config - "\$1"#curl -fsSL -H "Authorization: token $PLATFORM_REPO_READ_PAT" "$1"#' "$D" > "$ENGINE_WORK/planted-token-in-argument.sh"
  cmp -s "$D" "$ENGINE_WORK/planted-token-in-argument.sh" && fail "$engine_driver: the token was not moved into an argument — the probe proves nothing"
  fresh_machine
  CODE=0; PLATFORM_ON_FORGEJO=true PLATFORM_REPO_READ_PAT='fixture-forgejo-read-token' EXPECT_PAT='fixture-forgejo-read-token' placed "$ENGINE_WORK/planted-token-in-argument.sh" "$PINNED_DIGESTS" || CODE=$?
  [ "$CODE" = 69 ] || fail "$engine_driver: a copy that puts the token in an argument must be refused with 69, got $CODE: $(cat "$OUT/placed.out")"
  [ -z "$(ls -A "$SANDBOX/bin")" ] || fail "$engine_driver: a token in an argument was refused and the engine was placed all the same"
  ok "$engine_driver: the digests on Forgejo are read with the token in the curl config on standard input, and a copy with the token in an argument is caught"

  fresh_machine
  CODE=0; placed "$D" "$(printf '%s\n' "$PINNED_DIGESTS" | head -1)" || CODE=$?
  [ "$CODE" = 65 ] || fail "$engine_driver: a digest file without the ansiwise-rest line must end the placement with 65, got $CODE: $(cat "$OUT/placed.out")"
  [ ! -s "$OUT/fetched.log" ] || fail "$engine_driver: a digest file without the ansiwise-rest line still downloaded $(cat "$OUT/fetched.log")"
  grep -q "states no single SHA-256 for ansiwise-rest-$ENGINE_PIN-linux-x64" "$OUT/placed.out" \
    || fail "$engine_driver: the missing digest line was not named: $(cat "$OUT/placed.out")"
  ok "$engine_driver: an asset with no digest line has no address, and nothing is downloaded"

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

# THE OWNER'S MASTER IS THE REGISTRY RELEASES NAMES, so nothing serves its engine before it is installed. The
# fetch fails there as on any machine whose registry lacks the blob, and its message says which of the two it is.
UNSERVED_DIGESTS="$(printf '%s\n' "$PINNED_DIGESTS" | sed "1s/^[0-9a-f]*/$(printf 'served by nobody' | sha256sum | cut -d' ' -f1)/")"
unserved() { # <driver file> <the host RELEASES names> — the exit code of the placement and what its refusal says after "served nothing — "
  local code=0
  fresh_machine
  RELEASES_HOST="$2" placed "$1" "$UNSERVED_DIGESTS" || code=$?
  echo "$code $(ls -A "$SANDBOX/bin" | wc -l | tr -d ' ') placed, $(sed -n 's/^die: .* served nothing — //p' "$OUT/placed.out")"
}
[ "$(unserved "$HERE/driver.sh" registry.example.invalid)" = '69 0 placed, the registry holds no blob of that digest' ] \
  || fail "driver.sh: a machine whose registry lacks the blob was not told so: $(cat "$OUT/placed.out")"
[ "$(unserved "$HERE/driver.sh" zot.machine.example.invalid)" = '69 0 placed, zot.machine.example.invalid is the registry of this machine, which serves nothing before this machine is installed, so a first installation or a restore of machine.example.invalid has no source for its engine' ] \
  || fail "driver.sh: the machine that is the registry RELEASES names was not told that it has no source for its engine: $(cat "$OUT/placed.out")"
ok "driver.sh: a fetch that finds nothing says that the registry lacks the blob, and on the machine that is that registry, that this machine has no source for its engine"
plant 'one message for every machine' 's/^  || UNSERVED=.*$/  || true/' '^  || true$'
[ "$(unserved "$ENGINE_WORK/planted-driver.sh" zot.machine.example.invalid)" = '69 0 placed, the registry holds no blob of that digest' ] \
  || fail "a driver with one message for every machine told the owner's master something else — the probe proves nothing: $(cat "$OUT/placed.out")"
ok "the planted defect was caught — a driver with one message for every machine tells the owner's master only that a blob is missing"

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
stops_the_ticker() { local cleanup; cleanup="$(sed -n '/^cleanup() {/,/^}/p' "$1")" && grep -q 'kill "\$TICKER"' <<< "$cleanup" && grep -q '^  TICKER=\$!$' "$1"; }
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

# The destination inputs use each driver's declared-answer projection unchanged.
FORGEJO_ANSWERS_WORK="$WORK/forgejo-answers"
mkdir -p "$FORGEJO_ANSWERS_WORK"
forgejo_answers_cases() { # <composer> <example config>
  python3 - "$1" "$2" "$FORGEJO_ANSWERS_WORK" <<'FORGEJO_ANSWERS_TEST'
import json, pathlib, subprocess, sys
composer, example, work = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
names = ['forgejo_platform_repository', 'forgejo_deploy_repository', 'forgejo_organisations', 'forgejo_host']
expected = dict(zip(names, ['platform-team/platform', 'deploy-team/deploy', 'platform-team,deploy-team', 'forgejo.master.example.org']))
for name in names:
    assert name.upper() + "=''" in example.read_text(), name + ' is missing from config.example.env'
declares = work / 'declares.yaml'
declares.write_text('answers:\n' + ''.join('  - name: ' + name + '\n    kind: text\n' for name in names))
config, output = work / 'config.env', work / 'answers.json'
config.write_text("PLATFORM_REPO_URL='https://github.com/current/platform.git'\nDEPLOY_REPO_URL='https://github.com/current/deploy.git'\n" +
                  ''.join(name.upper() + "='" + value + "'\n" for name, value in expected.items()))
subprocess.run([sys.executable, composer, str(config), str(declares), str(output)], check=True, stdout=subprocess.DEVNULL)
assert json.loads(output.read_text()) == {'answers': expected}, 'Forgejo destinations changed or were inferred from clone URLs'
# Innocent: unrelated configuration does not become an answer.
config.write_text(config.read_text() + "UNRELATED='innocent'\n")
subprocess.run([sys.executable, composer, str(config), str(declares), str(output)], check=True, stdout=subprocess.DEVNULL)
assert json.loads(output.read_text()) == {'answers': expected}
FORGEJO_ANSWERS_TEST
}
for driver in driver.sh regenerate-driver.sh; do
  composer_of "$HERE/$driver" > "$FORGEJO_ANSWERS_WORK/$driver.py"
  forgejo_answers_cases "$FORGEJO_ANSWERS_WORK/$driver.py" "$HERE/config.example.env" || fail "$driver lost the Forgejo destinations"
  sed "s/name in stated and name != BESIDE/name in stated and name != BESIDE and name != 'forgejo_platform_repository'/" \
    "$FORGEJO_ANSWERS_WORK/$driver.py" > "$FORGEJO_ANSWERS_WORK/planted.py"
  if forgejo_answers_cases "$FORGEJO_ANSWERS_WORK/planted.py" "$HERE/config.example.env" 2>/dev/null; then
    fail "$driver's projection passed with forgejo_platform_repository removed"
  fi
done
for dropped in FORGEJO_PLATFORM_REPOSITORY FORGEJO_DEPLOY_REPOSITORY FORGEJO_ORGANISATIONS FORGEJO_HOST; do
  sed "/^$dropped=/d" "$HERE/config.example.env" > "$FORGEJO_ANSWERS_WORK/planted.env"
  if forgejo_answers_cases "$FORGEJO_ANSWERS_WORK/driver.sh.py" "$FORGEJO_ANSWERS_WORK/planted.env" 2>/dev/null; then
    fail "an example config without $dropped passed"
  fi
done
ok 'both drivers retain the three configured Forgejo destinations and the Forgejo host with GitHub clone URLs; missing config keys and a dropped line of the example are caught'

# THE EXAMPLE STATES EVERY ONE OF THE FOUR APP ANSWERS the programs require (github_app_id, github_app_installation_id,
# github_app_private_key, github_app_owner), because a config written from it is what a first install is read from.
app_keys_of_example() { # <example> -> 0 when it carries a line for each of the four, else the first one it lacks, named
  local key
  for key in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_OWNER; do
    grep -q "^$key=''\$" "$1" || { echo "$key is missing from config.example.env" >&2; return 1; }
  done
}
app_keys_of_example "$HERE/config.example.env" || fail 'the example config lacks an App key'
for dropped in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_OWNER; do
  sed "/^$dropped=/d" "$HERE/config.example.env" > "$FORGEJO_ANSWERS_WORK/planted-app.env"
  if app_keys_of_example "$FORGEJO_ANSWERS_WORK/planted-app.env" 2>/dev/null; then
    fail "an example config without $dropped passed"
  fi
done
ok 'the example config carries a line for each of the four App answers, and a copy without any one of them is caught'

# ===========================================================================
# EIGHT, continued — which forge the drivers read the platform repository from
# ===========================================================================
# BOTH DRIVERS CHOOSE BY THE SAME TWO ANSWERS the programs choose their rows by: PLATFORM_REPO and
# FORGEJO_PLATFORM_REPOSITORY naming one repository puts the tree on this installation's Forgejo, where it is
# private. What runs is each driver's own text, taken out of the file: the block that decides, and for
# driver.sh the block that asks which branches the repository carries. A stand-in git logs what it is
# handed, its arguments and the variables of its environment that carry a header, so "the token stands in
# no word of the command" is measured on the process that would be listed.
FORGE_WORK="$WORK/forge-choice"
mkdir -p "$FORGE_WORK/bin"
FORGE_TOKEN='fixture-forgejo-read-token'
FORGE_TOKEN_BASIC="$(printf 'oauth2:%s' "$FORGE_TOKEN" | base64 -w0)"

block_of() { # <driver> -> the block that decides where the platform repository stands
  case "$1" in
    *regenerate-driver.sh) sed -n '/^readonly PLATFORM_REPO=/,/^readonly PLATFORM_ON_FORGEJO$/p' "$1" ;;
    *) sed -n '/^readonly STAGE=/,/^readonly PLATFORM_ON_FORGEJO$/p' "$1" ;;
  esac
}
decided() { # <block file> then the config as NAME=value words — the exit code, and what it said in $FORGE_WORK/decided.out
  local block="$1"; shift
  ( for assignment in "$@"; do export "$assignment"; done
    die() { echo "die: $1" >&2; exit "${2:-1}"; }
    set -uo pipefail
    . "$block"
    echo "PLATFORM_ON_FORGEJO=$PLATFORM_ON_FORGEJO" ) > "$FORGE_WORK/decided.out" 2>&1
}
decides_cases() { # <block file> — every case, or the first that fails, named on standard error
  local block="$1" common=(STAGE=prod DEPLOY_REPO=acme/deploy PROGRAMS_REPO=acme/programs OPERATOR_USER=operator FQDN=master.example.org ROLE=master)
  decided "$block" "${common[@]}" PLATFORM_REPO=platform-team/platform FORGEJO_PLATFORM_REPOSITORY=platform-team/platform \
    FORGEJO_HOST=forgejo.master.example.org PLATFORM_REPO_READ_PAT="$FORGE_TOKEN" \
    || { echo "a platform repository on Forgejo with its host and its reader was refused: $(cat "$FORGE_WORK/decided.out")" >&2; return 1; }
  grep -qx 'PLATFORM_ON_FORGEJO=true' "$FORGE_WORK/decided.out" || { echo "the same repository under both answers was not read from Forgejo" >&2; return 1; }
  decided "$block" "${common[@]}" PLATFORM_REPO=acme/platform FORGEJO_PLATFORM_REPOSITORY=platform-team/platform \
    || { echo "a platform repository on GitHub, with no Forgejo host and no reader, was refused: $(cat "$FORGE_WORK/decided.out")" >&2; return 1; }
  grep -qx 'PLATFORM_ON_FORGEJO=false' "$FORGE_WORK/decided.out" || { echo "two different repositories were not read from GitHub" >&2; return 1; }
  local missing code
  for missing in FORGEJO_HOST PLATFORM_REPO_READ_PAT; do
    code=0
    decided "$block" "${common[@]}" PLATFORM_REPO=platform-team/platform FORGEJO_PLATFORM_REPOSITORY=platform-team/platform \
      FORGEJO_HOST=forgejo.master.example.org PLATFORM_REPO_READ_PAT="$FORGE_TOKEN" "$missing=" || code=$?
    [ "$code" = 64 ] || { echo "a platform repository on Forgejo with $missing empty must be refused with 64, got $code" >&2; return 1; }
    grep -q "says nothing under $missing" "$FORGE_WORK/decided.out" || { echo "the refusal does not name $missing: $(cat "$FORGE_WORK/decided.out")" >&2; return 1; }
    if grep -qF "$FORGE_TOKEN" "$FORGE_WORK/decided.out"; then echo "the refusal prints the token" >&2; return 1; fi
  done
  code=0
  decided "$block" "${common[@]}" PLATFORM_REPO=acme/platform FORGEJO_PLATFORM_REPOSITORY= || code=$?
  [ "$code" = 64 ] || { echo "an empty FORGEJO_PLATFORM_REPOSITORY must be refused with 64, got $code" >&2; return 1; }
  grep -q 'FORGEJO_PLATFORM_REPOSITORY' "$FORGE_WORK/decided.out" || { echo "the refusal does not name FORGEJO_PLATFORM_REPOSITORY" >&2; return 1; }
}
for engine_driver in driver.sh regenerate-driver.sh; do
  block_of "$HERE/$engine_driver" > "$FORGE_WORK/$engine_driver.block"
  [ -s "$FORGE_WORK/$engine_driver.block" ] || fail "$engine_driver carries no block that decides where the platform repository stands"
  decides_cases "$FORGE_WORK/$engine_driver.block" 2> "$FORGE_WORK/why" || fail "$engine_driver: $(cat "$FORGE_WORK/why")"
  # PLANTED: a block that no longer asks for the host, one that no longer asks for the reader, and one that
  # always reads from GitHub. Each is caught, or the cases above prove nothing.
  sed 's/for named in FORGEJO_HOST PLATFORM_REPO_READ_PAT; do/for named in PLATFORM_REPO_READ_PAT; do/' "$FORGE_WORK/$engine_driver.block" > "$FORGE_WORK/$engine_driver.no-host"
  sed 's/for named in FORGEJO_HOST PLATFORM_REPO_READ_PAT; do/for named in FORGEJO_HOST; do/' "$FORGE_WORK/$engine_driver.block" > "$FORGE_WORK/$engine_driver.no-reader"
  sed 's/^if \[ "\$PLATFORM_REPO" = "\$FORGEJO_PLATFORM_REPOSITORY" \]; then$/if false; then/' "$FORGE_WORK/$engine_driver.block" > "$FORGE_WORK/$engine_driver.always-github"
  for planted in no-host no-reader always-github; do
    ! cmp -s "$FORGE_WORK/$engine_driver.block" "$FORGE_WORK/$engine_driver.$planted" || fail "$engine_driver: the plant $planted changed nothing"
    if decides_cases "$FORGE_WORK/$engine_driver.$planted" 2>/dev/null; then fail "$engine_driver: a block with the plant $planted passed every case"; fi
  done
done
ok 'both drivers read the platform repository from Forgejo when PLATFORM_REPO and FORGEJO_PLATFORM_REPOSITORY name one repository, refuse a missing host or reader by name without showing the token, read it from GitHub with neither, and three planted blocks are caught'

# THE BRANCH ASK of driver.sh: a stand-in git that answers what the case says, and logs its arguments and the
# variables of its environment that carry a header.
cat > "$FORGE_WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")"
printf '%s\n' "$*" > "$dir/arguments"
env | grep -E '^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)=' | sort > "$dir/environment" || true
case "$(cat "$dir/mode")" in
  refused) echo 'fatal: could not read Username for '"'"'https://forgejo.master.example.org'"'"': terminal prompts disabled' >&2; exit 128 ;;
  tip) printf 'warning: redirecting to the canonical address\n' >&2
       printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/other.example.org\n'
       printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/heads/master.example.org\n' ;;
  none) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/other.example.org\n' ;;
esac
STUB
chmod +x "$FORGE_WORK/bin/git"
branch_ask_of() { sed -n '/^# THE CREDENTIAL STANDS IN THE ENVIRONMENT/,/^BRANCH_TIP=/p' "$1"; }
asked() { # <driver file> <mode> <true|false> — the exit code; $FORGE_WORK/asked.out holds what it said and the tip it read
  printf '%s' "$2" > "$FORGE_WORK/bin/mode"
  rm -f "$FORGE_WORK/bin/arguments" "$FORGE_WORK/bin/environment"
  ( unset GIT_CONFIG_COUNT "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}" # a caller's own git configuration in the environment is no input of the case
    export PATH="$FORGE_WORK/bin:$PATH" FQDN=master.example.org PLATFORM_REPO=platform-team/platform FORGEJO_HOST=forgejo.master.example.org \
      PLATFORM_REPO_READ_PAT="$FORGE_TOKEN" PLATFORM_ON_FORGEJO="$3"
    die() { echo "die: $1" >&2; exit "${2:-1}"; }
    set -euo pipefail
    eval "$(branch_ask_of "$1")"
    echo "BRANCH_TIP=$BRANCH_TIP" ) > "$FORGE_WORK/asked.out" 2>&1
}
ask_cases() { # <driver file> — every case, or the first that fails, named on standard error
  local code=0
  asked "$1" refused true || code=$?
  [ "$code" = 69 ] || { echo "a refused ask on Forgejo must end the run with 69, got $code: $(cat "$FORGE_WORK/asked.out")" >&2; return 1; }
  grep -qF 'git could not ask platform-team/platform (https://forgejo.master.example.org/platform-team/platform.git) whether it carries a branch named master.example.org' "$FORGE_WORK/asked.out" \
    || { echo "the refusal does not name the repository and the branch: $(cat "$FORGE_WORK/asked.out")" >&2; return 1; }
  grep -qF 'could not read Username' "$FORGE_WORK/asked.out" || { echo "the refusal does not carry git's words" >&2; return 1; }
  if grep -qF -e "$FORGE_TOKEN" -e "$FORGE_TOKEN_BASIC" "$FORGE_WORK/asked.out"; then echo "the refusal prints the token" >&2; return 1; fi
  code=0; asked "$1" refused false || code=$?
  [ "$code" = 69 ] || { echo "a refused ask on GitHub must end the run with 69, got $code" >&2; return 1; }
  asked "$1" tip true || { echo "an ask that found the branch was refused: $(cat "$FORGE_WORK/asked.out")" >&2; return 1; }
  grep -qx 'BRANCH_TIP=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$FORGE_WORK/asked.out" || { echo "the tip of the branch of this machine was not read: $(cat "$FORGE_WORK/asked.out")" >&2; return 1; }
  asked "$1" none true || { echo "an ask that found no branch of this machine was refused: $(cat "$FORGE_WORK/asked.out")" >&2; return 1; }
  grep -qx 'BRANCH_TIP=' "$FORGE_WORK/asked.out" || { echo "another branch was read as this machine's: $(cat "$FORGE_WORK/asked.out")" >&2; return 1; }
  # THE TOKEN IS IN THE ENVIRONMENT OF THE ASK AND IN NO WORD OF IT, and goes to the Forgejo host only.
  asked "$1" tip true || return 1
  [ "$(cat "$FORGE_WORK/bin/arguments")" = 'ls-remote --heads https://forgejo.master.example.org/platform-team/platform.git refs/heads/master.example.org' ] \
    || { echo "the ask on Forgejo was not git ls-remote of the Forgejo address: $(cat "$FORGE_WORK/bin/arguments")" >&2; return 1; }
  if grep -qF -e "$FORGE_TOKEN" -e "$FORGE_TOKEN_BASIC" "$FORGE_WORK/bin/arguments"; then echo "the token stands in an argument of the ask" >&2; return 1; fi
  [ "$(cat "$FORGE_WORK/bin/environment")" = "GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=http.https://forgejo.master.example.org/.extraHeader
GIT_CONFIG_VALUE_0=Authorization: Basic $FORGE_TOKEN_BASIC" ] \
    || { echo "the header did not reach git through GIT_CONFIG_COUNT, KEY_0 and VALUE_0 for the Forgejo host: $(cat "$FORGE_WORK/bin/environment")" >&2; return 1; }
  # INNOCENT: on GitHub the address is github.com and nothing is sent.
  asked "$1" tip false || return 1
  [ "$(cat "$FORGE_WORK/bin/arguments")" = 'ls-remote --heads https://github.com/platform-team/platform.git refs/heads/master.example.org' ] \
    || { echo "the ask on GitHub was not git ls-remote of the github.com address: $(cat "$FORGE_WORK/bin/arguments")" >&2; return 1; }
  [ ! -s "$FORGE_WORK/bin/environment" ] || { echo "the ask on GitHub sent a header: $(cat "$FORGE_WORK/bin/environment")" >&2; return 1; }
}
ask_cases "$HERE/driver.sh" 2> "$FORGE_WORK/why" || fail "driver.sh: $(cat "$FORGE_WORK/why")"
# PLANTED: an ask whose refusal reads as "no branch stands there", one that puts the header in an argument,
# one that sends the header to every host, and one that reads any branch as this machine's.
sed 's/^BRANCH_ASKED=\$(ask_platform_branches) \\$/BRANCH_ASKED=$(ask_platform_branches || true) \\/' "$HERE/driver.sh" > "$FORGE_WORK/planted-ignored.sh"
sed 's/^      git ls-remote --heads "\$PLATFORM_URL" "refs\/heads\/\$FQDN" 2>&1$/      git -c "http.extraHeader=$GIT_CONFIG_VALUE_0" ls-remote --heads "$PLATFORM_URL" "refs\/heads\/$FQDN" 2>\&1/' "$HERE/driver.sh" > "$FORGE_WORK/planted-argument.sh"
sed 's/GIT_CONFIG_KEY_0="http.https:\/\/\$FORGEJO_HOST\/.extraHeader"/GIT_CONFIG_KEY_0="http.extraHeader"/' "$HERE/driver.sh" > "$FORGE_WORK/planted-every-host.sh"
sed "s/awk -v ref=\"refs\/heads\/\$FQDN\" '\$2 == ref {print \$1}'/awk '{print \$1}'/" "$HERE/driver.sh" > "$FORGE_WORK/planted-any-branch.sh"
for planted in planted-ignored planted-argument planted-every-host planted-any-branch; do
  ! cmp -s "$HERE/driver.sh" "$FORGE_WORK/$planted.sh" || fail "the plant $planted changed nothing in driver.sh"
  if ask_cases "$FORGE_WORK/$planted.sh" 2>/dev/null; then fail "a driver with the plant $planted passed every branch-ask case"; fi
done
ok 'driver.sh asks Forgejo which branches the platform repository carries with the token in the environment of that one command and in no argument, ends with 69 and git'"'"'s words on a refused ask, reads the tip of its own branch alone, asks github.com with no header; four planted asks are caught'

# THE OWNER AND THE HOST REACH THE PROGRAMS: both drivers project the config keys whose lower-cased names a
# program declares, so GITHUB_APP_OWNER and FORGEJO_HOST arrive as answers with no line of code of their own.
cat > "$FORGE_WORK/declares.yaml" <<'DECLARES'
answers:
  - name: github_app_owner
    kind: text
  - name: forgejo_host
    kind: text
  - name: platform_repo_read_pat
    kind: text
DECLARES
for engine_driver in driver.sh regenerate-driver.sh; do
  printf "GITHUB_APP_OWNER='acme'\nFORGEJO_HOST='forgejo.master.example.org'\nPLATFORM_REPO_READ_PAT='%s'\nUNRELATED='innocent'\n" "$FORGE_TOKEN" > "$FORGE_WORK/projected.env"
  python3 "$FORGEJO_ANSWERS_WORK/$engine_driver.py" "$FORGE_WORK/projected.env" "$FORGE_WORK/declares.yaml" "$FORGE_WORK/projected.json" > /dev/null \
    || fail "$engine_driver: the projection of the owner, the host and the reader was refused"
  [ "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$FORGE_WORK/projected.json")" \
    = "{\"answers\": {\"forgejo_host\": \"forgejo.master.example.org\", \"github_app_owner\": \"acme\", \"platform_repo_read_pat\": \"$FORGE_TOKEN\"}}" ] \
    || fail "$engine_driver: the owner, the host and the reader did not arrive as answers: $(cat "$FORGE_WORK/projected.json")"
done
ok 'both drivers hand GITHUB_APP_OWNER, FORGEJO_HOST and PLATFORM_REPO_READ_PAT to a program that declares them, and nothing it does not declare'

# ===========================================================================
# NINE — release-unit, against a stand-in Manager behind a stand-in ssh and kubectl
# ===========================================================================
# THE WHOLE ACT RUNS, from the door to the run's end, and only the Manager is a stand-in
# (scripts/standin/release-unit-manager.mjs): ssh runs the command it is handed the way a remote
# shell does, kubectl runs the relay with the three values the Manager's container carries, and the
# relay is the act's own. The stand-in mints sentinel sessions and refreshes them on every call, logs
# whether each call carried the session issued last, and plays the release the case names. Each case
# is held to its recorded bytes, to the calls the Manager saw (a release request with the body it
# sent), and to no sentinel standing in any file, argument or environment the run left. The act runs
# with its home and temporary folders inside the fixture root, and /tmp is read for any file written
# while it ran, so a session written to either is found. The planted defects are copies of the act
# that print the session, hand it on in an environment variable, or write it to its temporary folder,
# its home folder or /tmp: the sentinel check must find each, beside every case here that finds none.
RU="$WORK/release-unit"
mkdir -p "$RU/bin" "$RU/home" "$RU/tmp"
# Every sentinel names this run of the suite, so a scan of /tmp never finds another run's.
SENTINEL_RUN="${WORK##*/}"
cat > "$RU/bin/ssh" <<'STANDIN'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$RU/argv"; env >> "$RU/env"
while [ "$1" = '-o' ]; do shift 2; done
shift # the door
exec bash -c "$*"
STANDIN
cat > "$RU/bin/microk8s.kubectl" <<'STANDIN'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$RU/argv"; env >> "$RU/env"
[ "${*:1:8}" = 'exec -i -n manager deploy/manager -c manager --' ] || { echo "kubectl stand-in: not the Manager's container: $*" >&2; exit 2; }
shift 8
hangs="$(cat "$RU/relay-hangs" 2>/dev/null || echo 0)"
if [ "$hangs" -gt 0 ]; then
  echo $((hangs - 1)) > "$RU/relay-hangs"
  exec sleep 20
fi
fails="$(cat "$RU/relay-fails" 2>/dev/null || echo 0)"
if [ "$fails" -gt 0 ]; then
  echo $((fails - 1)) > "$RU/relay-fails"
  echo 'error: unable to upgrade connection: container not found ("manager")' >&2
  exit 1
fi
ADMIN_SOCKET_PATH="$RU/sock" PUBLIC_URL='https://manager.example.invalid' PORT="$(cat "$RU/port")" exec "$@"
STANDIN
chmod +x "$RU/bin/ssh" "$RU/bin/microk8s.kubectl"

RELEASE_UNIT="$HERE/release-unit.sh"
run_release_unit() { # the scenario the stand-in Manager plays, then the act's arguments; FOLLOW_SECONDS bounds the wait for the following tenants
  local scenario="$1" fake i
  shift
  rm -f "$RU/port" "$RU/sock" "$RU/relay-fails" "$RU/relay-hangs"
  : > "$RU/calls"; : > "$RU/argv"; : > "$RU/env"; touch "$RU/started"
  SCENARIO="$scenario" RU="$RU" SENTINEL_RUN="$SENTINEL_RUN" node "$HERE/../scripts/standin/release-unit-manager.mjs" &
  fake=$!
  for i in $(seq 100); do [ -s "$RU/port" ] && [ -S "$RU/sock" ] && break; sleep 0.05; done
  [ -s "$RU/port" ] || fail "the stand-in Manager of '$scenario' did not start"
  A_CODE=0
  ( PATH="$RU/bin:$PATH" RU="$RU" HOME="$RU/home" TMPDIR="$RU/tmp" RELEASE_UNIT_POLL_SECONDS=0 RELEASE_UNIT_RETRIES=4 RELEASE_UNIT_EXCHANGE_SECONDS=3 RELEASE_UNIT_FOLLOW_SECONDS="${FOLLOW_SECONDS:-60}" timeout 15 bash "$RELEASE_UNIT" "$@" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
  kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null || true
}
# The calls the stand-in Manager saw, in order, held to the case's own list.
calls() { # what was being checked; the calls on standard input
  diff -u - "$RU/calls" || fail "$1 — the Manager saw other calls than the case records"
}
# No sentinel the stand-in issued stands in what the run printed, in any argument or environment of
# a process it started, in any file under the fixture root, or in a file under /tmp written since the
# case began.
no_session() { # what was being checked
  { grep -rlF "SENTINEL-$SENTINEL_RUN-" "$WORK" || true
    find /tmp -xdev -type f -newer "$RU/started" ! -path "$WORK/*" -exec grep -lF "SENTINEL-$SENTINEL_RUN-" {} + 2>/dev/null || true
  } > "$OUT/leaks"
  if [ -s "$OUT/leaks" ]; then
    fail "$1 — a session stands in $(tr '\n' ' ' < "$OUT/leaks")"
  fi
}
B="$(printf 'b%.0s' $(seq 40))"; C="$(printf 'c%.0s' $(seq 40))"; D="$(printf 'd%.0s' $(seq 40))"

run_release_unit success manager@master.example.invalid shop --prod-to-test
expect 'the prod release, put on test as its one put-release' 0 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: succeeded (put-release ok)
run run_1 succeeded
no following tenant at test renders shop
~~~ standard error ~~~
RECORDED
calls 'the prod release, put on test as its one put-release' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
RECORDED
no_session 'the prod release, put on test as its one put-release'

run_release_unit success manager@master.example.invalid shop test stable 0.3.004 $B
expect 'an explicit release of a commit, its plan approved as it stands' 0 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
no following tenant at test renders shop
~~~ standard error ~~~
RECORDED
calls 'an explicit release of a commit, its plan approved as it stands' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
RECORDED
no_session 'an explicit release of a commit, its plan approved as it stands'

run_release_unit success manager@master.example.invalid ghost prod stable 0.2.001 $C
expect 'a unit the Manager has no registration of, refused at its plan' 1 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: failed (mint-release pending, watch-release-build pending)
~~~ standard error ~~~
release-unit: run run_1 was refused at its plan (failed): open /runs/run_1 for why
RECORDED
calls 'a unit the Manager has no registration of, refused at its plan' <<'RECORDED'
MINT
POST /api/units/ghost/release cookie=current origin=ok
  body {"stage":"prod","channel":"stable","version":"0.2.001","commit":"cccccccccccccccccccccccccccccccccccccccc"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a unit the Manager has no registration of, refused at its plan'

run_release_unit success manager@master.example.invalid shop prod stable 0.2.001 $D
expect 'a commit that is not on the default branch, refused at its plan' 1 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: failed (mint-release pending, watch-release-build pending)
~~~ standard error ~~~
release-unit: run run_1 was refused at its plan (failed): open /runs/run_1 for why
RECORDED
calls 'a commit that is not on the default branch, refused at its plan' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"prod","channel":"stable","version":"0.2.001","commit":"dddddddddddddddddddddddddddddddddddddddd"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a commit that is not on the default branch, refused at its plan'

run_release_unit success manager@master.example.invalid shop prod stable 0.2.000 $C
expect 'a version that stands on another commit, refused at its plan' 1 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: failed (mint-release pending, watch-release-build pending)
~~~ standard error ~~~
release-unit: run run_1 was refused at its plan (failed): open /runs/run_1 for why
RECORDED
calls 'a version that stands on another commit, refused at its plan' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"prod","channel":"stable","version":"0.2.000","commit":"cccccccccccccccccccccccccccccccccccccccc"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a version that stands on another commit, refused at its plan'

run_release_unit success manager@master.example.invalid ghost --prod-to-test
expect 'a unit with no release at prod to read' 1 <<'RECORDED'
~~~ standard error ~~~
release-unit: the prod release of ghost could not be read: the Manager answered 404 NOT_FOUND: no unit "ghost" is registered, so there is nothing to release; nothing was planned
RECORDED
calls 'a unit with no release at prod to read' <<'RECORDED'
MINT
GET /api/units/ghost/release?stage=prod cookie=current origin=n/a
RECORDED
no_session 'a unit with no release at prod to read'

run_release_unit mixed manager@master.example.invalid shop --prod-to-test
expect 'a prod whose pins name two releases' 1 <<'RECORDED'
~~~ standard error ~~~
release-unit: the prod release of shop could not be read: the Manager answered 400 VALIDATION: the release "shop" runs at prod cannot be read: its pins name 2 image tags, and one release is one image tag; nothing was planned
RECORDED
calls 'a prod whose pins name two releases' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
RECORDED
no_session 'a prod whose pins name two releases'

run_release_unit promotion-reattest manager@master.example.invalid shop --prod-to-test
expect 'a prod-to-test plan with a step of its own besides the put-release' 0 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending, reattest-smtp-entry pending)
run run_1: planned (put-release pending, reattest-smtp-entry pending)
run run_1: queued (put-release pending, reattest-smtp-entry pending)
run run_1: running (put-release running, reattest-smtp-entry running)
run run_1: succeeded (put-release ok, reattest-smtp-entry ok)
run run_1 succeeded
no following tenant at test renders shop
~~~ standard error ~~~
RECORDED
calls 'a prod-to-test plan with a step of its own besides the put-release' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
RECORDED
no_session 'a prod-to-test plan with a step of its own besides the put-release'

run_release_unit promotion-mints manager@master.example.invalid shop --prod-to-test
expect 'a prod-to-test plan that mints a release' 1 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (mint-release pending)
run run_1: planned (mint-release pending)
~~~ standard error ~~~
release-unit: run run_1 plans mint-release, and a release from prod to test mints and builds nothing; it is not approved. Discard it on /runs/run_1
RECORDED
calls 'a prod-to-test plan that mints a release' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a prod-to-test plan that mints a release'

run_release_unit promotion-builds manager@master.example.invalid shop --prod-to-test
expect 'a prod-to-test plan that watches a release build' 1 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (watch-release-build pending)
run run_1: planned (watch-release-build pending)
~~~ standard error ~~~
release-unit: run run_1 plans watch-release-build, and a release from prod to test mints and builds nothing; it is not approved. Discard it on /runs/run_1
RECORDED
calls 'a prod-to-test plan that watches a release build' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a prod-to-test plan that watches a release build'

run_release_unit secrets manager@master.example.invalid shop prod stable 0.3.004 $B
expect 'a plan that asks for a secret to be typed' 1 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
~~~ standard error ~~~
release-unit: run run_1 asks for secrets to be typed, which this script does not do; it is not approved. Open /runs/run_1
RECORDED
calls 'a plan that asks for a secret to be typed' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"prod","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a plan that asks for a secret to be typed'

run_release_unit failed manager@master.example.invalid shop --prod-to-test
expect 'a release run that fails' 1 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: failed (put-release failed)
~~~ standard error ~~~
release-unit: run run_1 failed: open /runs/run_1
RECORDED
calls 'a release run that fails' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a release run that fails'

run_release_unit cancelled manager@master.example.invalid shop --prod-to-test
expect 'a release run that is cancelled' 1 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: cancelled (put-release pending)
~~~ standard error ~~~
release-unit: run run_1 cancelled: open /runs/run_1
RECORDED
calls 'a release run that is cancelled' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a release run that is cancelled'

run_release_unit relay-lost manager@master.example.invalid shop --prod-to-test
expect 'three relays lost to a rollout while the run goes on' 0 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: succeeded (put-release ok)
run run_1 succeeded
no following tenant at test renders shop
~~~ standard error ~~~
RECORDED
calls 'three relays lost to a rollout while the run goes on' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
RECORDED
no_session 'three relays lost to a rollout while the run goes on'
[ "$(cat "$RU/relay-fails")" = '0' ] || fail 'three relays lost to a rollout — the stand-in kubectl did not fail the three exchanges it was told to'
ok 'three relays lost to a rollout — the watch read through them on the one session it minted'

run_release_unit relay-hangs manager@master.example.invalid shop --prod-to-test
expect 'two relays that hang past the bound of an exchange' 0 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: succeeded (put-release ok)
run run_1 succeeded
no following tenant at test renders shop
~~~ standard error ~~~
RECORDED
calls 'two relays that hang past the bound of an exchange' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
RECORDED
no_session 'two relays that hang past the bound of an exchange'
[ "$(cat "$RU/relay-hangs")" = '0' ] || fail 'two relays that hang — the stand-in kubectl did not hang the two exchanges it was told to'
ok 'two relays that hang — each was ended at the bound of an exchange, and the watch read on'
# PLANTED: a copy whose exchanges have no bound waits on each hanging relay for its whole 20
# seconds, and is still waiting when the 15 seconds every case is allowed run out.
PLANT="$WORK/release-unit-unbound"
mkdir -p "$PLANT"
cp "$HERE/release-unit.sh" "$PLANT/release-unit.sh"
sed 's/const bound = setTimeout(() => child.kill("SIGKILL"), EXCHANGE_MS);/const bound = undefined;/' "$HERE/release-unit.mjs" > "$PLANT/release-unit.mjs"
! cmp -s "$HERE/release-unit.mjs" "$PLANT/release-unit.mjs" || fail 'the plant that drops the bound of an exchange changed nothing in release-unit.mjs'
RELEASE_UNIT="$PLANT/release-unit.sh"
run_release_unit relay-hangs manager@master.example.invalid shop --prod-to-test
RELEASE_UNIT="$HERE/release-unit.sh"
[ "$A_CODE" = '124' ] || fail "a copy with no bound on an exchange ended with $A_CODE, where the 15 seconds of its case should have run out"
ok 'the planted defect was caught — a copy with no bound on an exchange still waits on a hanging relay when its case'"'"'s 15 seconds run out'
rm -rf "$PLANT"

run_release_unit watch-exhausted manager@master.example.invalid shop --prod-to-test
expect 'relays lost for longer than the watch waits' 75 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
~~~ standard error ~~~
release-unit: the watch on run run_1 stopped: 5 reads in a row got no answer. The run goes on in the Manager: open /runs/run_1
RECORDED
calls 'relays lost for longer than the watch waits' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
RECORDED
no_session 'relays lost for longer than the watch waits'

run_release_unit expired manager@master.example.invalid shop --prod-to-test
expect 'a session that expires while the run goes on' 75 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
~~~ standard error ~~~
release-unit: the watch on run run_1 stopped: the session is no longer valid (expired or revoked), and no other is minted. The run goes on in the Manager: open /runs/run_1
RECORDED
calls 'a session that expires while the run goes on' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
no_session 'a session that expires while the run goes on'

run_release_unit lost-post manager@master.example.invalid shop --prod-to-test
expect 'a release request whose answer is lost' 75 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
~~~ standard error ~~~
release-unit: the release request of shop got no answer, so whether the Manager made a run of it is not known; it is not sent again. Read the Runs page
RECORDED
calls 'a release request whose answer is lost' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
RECORDED
no_session 'a release request whose answer is lost'

run_release_unit lost-approve manager@master.example.invalid shop --prod-to-test
expect 'an approval whose answer is lost after it took' 0 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: the approval got no answer; it is not sent again, and the run is read
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: succeeded (put-release ok)
run run_1 succeeded
no following tenant at test renders shop
~~~ standard error ~~~
RECORDED
calls 'an approval whose answer is lost after it took' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=stale origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
RECORDED
no_session 'an approval whose answer is lost after it took'

run_release_unit dropped-approve manager@master.example.invalid shop --prod-to-test
expect 'an approval that never reached the Manager' 1 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: the approval got no answer; it is not sent again, and the run is read
run run_1: planned (put-release pending)
~~~ standard error ~~~
release-unit: run run_1 stands planned: the approval did not reach it, and it is not sent again. Approve it on /runs/run_1
RECORDED
calls 'an approval that never reached the Manager' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=stale origin=n/a
RECORDED
no_session 'an approval that never reached the Manager'

run_release_unit success manager@master.example.invalid shop
expect 'a run naming a unit and nothing else' 64 <<'RECORDED'
~~~ standard error ~~~
release-unit: usage: lifecycle/release-unit.sh <user@master-host> <unit> --prod-to-test
       lifecycle/release-unit.sh <user@master-host> <unit> <dev|test|prod|none> <alpha|beta|stable> <x.y.z> <commit>
RECORDED
calls 'a run naming a unit and nothing else' <<'RECORDED'
RECORDED
no_session 'a run naming a unit and nothing else'

# THE TENANTS THAT FOLLOW RELEASES. A succeeded release run proves only that the stage pin stands; the
# act then waits until every active following tenant at the stage that renders the unit runs the
# stage's release tag, and prints one line for each. The stand-in plays a world of tenants per
# scenario named follow-*: each read of GET /api/tenants/<id>/versions moves that tenant one round on,
# and the decoys (suspended, not following, on another stage, not active, rendering no part of the unit)
# stay in the call lists as the calls the act must not make for them. A tenant is judged by its own
# reads: the Versions run that moved its part to the release's image tag (the part's `runs`) and the
# tags its Application renders (the live answer's `versions`). A wait that may not take longer than
# FOLLOW_SECONDS=0 is one look, which is how a tenant that never moves is told apart from one that is
# late without a clock in a recorded block.
FOLLOW_ARGS=(manager@master.example.invalid shop test stable 0.3.004 "$B")
# THE COMPACT FORM of a case in the tenants' world holds the exit code, the lines the act printed about
# the source and the tenants (standard input), the last line of standard error ('-' for none), and that
# the act never read the global list of runs, which holds every run of every tenant and kind and answers
# the newest hundred: a tenant is judged by its own reads.
follow_case() { # what was being checked; the exit code; the last line of standard error; the lines on standard input
  local label="$1" code="$2" last="$3" ended
  cat > "$OUT/expected"
  normalise < "$OUT/a.out" | grep -E '^(source:|tenant |waiting for |no following tenant )' > "$OUT/actual" || true
  diff -u "$OUT/expected" "$OUT/actual" || fail "$label — the run printed other lines about the tenants than the case records"
  [ "$A_CODE" = "$code" ] || fail "$label — the run ended with $A_CODE, and its case records $code"
  ended="$(normalise < "$OUT/a.err" | tail -n 1)"
  [ "$last" != '-' ] || last=''
  [ "$ended" = "$last" ] || fail "$label — the run ended on '$ended', and its case records '$last'"
  ! grep -q '^GET /api/runs cookie' "$RU/calls" || fail "$label — the act read the global list of runs"
  no_session "$label"
  ok "$label — the recorded lines, exit $code, and no read of the global list of runs"
}

run_release_unit follow-moves "${FOLLOW_ARGS[@]}"
expect 'a following tenant that moves after the release, beside the tenants that are not waited for' 0 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
tenant tnt_1: runs 0.3.004-stable-TS14 (Versions run run_v1 succeeded)
~~~ standard error ~~~
RECORDED
calls 'a following tenant that moves after the release, beside the tenants that are not waited for' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_other/versions?offered=false cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_1/live cookie=current origin=n/a
RECORDED
no_session 'a following tenant that moves after the release, beside the tenants that are not waited for'

FOLLOW_SECONDS=0 run_release_unit follow-never "${FOLLOW_ARGS[@]}"
expect 'a following tenant that never moves' 75 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
~~~ standard error ~~~
release-unit: tnt_1 (it runs 0.3.003-stable-TS14-1111111, and no Versions run after this release started has moved it to 0.3.004-stable-TS14) did not run 0.3.004-stable-TS14 within 0 seconds. The run run_1 succeeded: open /runs
RECORDED
calls 'a following tenant that never moves' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
RECORDED
no_session 'a following tenant that never moves'

run_release_unit follow-failed "${FOLLOW_ARGS[@]}"
expect 'a following tenant whose Versions run failed, beside one that landed' 1 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
tenant tnt_2: runs 0.3.004-stable-TS14 (Versions run run_v2 succeeded)
~~~ standard error ~~~
release-unit: tenant tnt_1: its Versions run run_v1 failed: open /runs/run_v1
RECORDED
calls 'a following tenant whose Versions run failed, beside one that landed' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_2/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_2/live cookie=current origin=n/a
RECORDED
no_session 'a following tenant whose Versions run failed, beside one that landed'

run_release_unit follow-line "${FOLLOW_ARGS[@]}"
expect 'a following tenant on another version line than the release' 0 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
tenant tnt_1: stays on line 0.2, and 0.3.004-stable-TS14 is on line 0.3; Move to line on /tenants/tnt_1, not waited for
~~~ standard error ~~~
RECORDED
calls 'a following tenant on another version line than the release' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
RECORDED
no_session 'a following tenant on another version line than the release'

run_release_unit follow-unrelated "${FOLLOW_ARGS[@]}"
expect 'a unit that no following tenant renders' 0 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
no following tenant at test renders shop
~~~ standard error ~~~
RECORDED
calls 'a unit that no following tenant renders' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_other/versions?offered=false cookie=current origin=n/a
RECORDED
no_session 'a unit that no following tenant renders'

run_release_unit follow-relay-lost "${FOLLOW_ARGS[@]}"
expect 'three relays lost while the following tenants are read' 0 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
tenant tnt_1: runs 0.3.004-stable-TS14 (Versions run run_v1 succeeded)
~~~ standard error ~~~
RECORDED
calls 'three relays lost while the following tenants are read' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_1/live cookie=current origin=n/a
RECORDED
no_session 'three relays lost while the following tenants are read'
[ "$(cat "$RU/relay-fails")" = '0' ] || fail 'three relays lost while the following tenants are read — the stand-in kubectl did not fail the three exchanges it was told to'
ok 'three relays lost while the following tenants are read — the reads were repeated on the one session'


run_release_unit follow-discarded "${FOLLOW_ARGS[@]}"
follow_case 'a Versions run discarded after the release started, then the run that moves the tag' 0 - <<'RECORDED'
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
tenant tnt_1: runs 0.3.004-stable-TS14 (Versions run run_v1 succeeded)
RECORDED

run_release_unit follow-other-tag "${FOLLOW_ARGS[@]}"
follow_case 'a failed move to another tag, then the run that moves this one' 0 - <<'RECORDED'
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
tenant tnt_1: runs 0.3.004-stable-TS14 (Versions run run_v1 succeeded)
RECORDED

run_release_unit follow-many-runs "${FOLLOW_ARGS[@]}"
follow_case 'the run that moved the tag, older than a hundred other runs' 0 - <<'RECORDED'
tenant tnt_1: runs 0.3.004-stable-TS14 (Versions run run_v1 succeeded)
RECORDED

run_release_unit follow-cancelled "${FOLLOW_ARGS[@]}"
follow_case 'a cancelled move to the tag while the tenant is off it' 1 'release-unit: tenant tnt_1: its Versions run run_v1 cancelled: open /runs/run_v1' <<'RECORDED'
RECORDED

run_release_unit follow-rendered-cancelled "${FOLLOW_ARGS[@]}"
follow_case 'a tenant that renders the tag, whose move was cancelled' 0 - <<'RECORDED'
tenant tnt_1: runs 0.3.004-stable-TS14 (its Application renders it)
RECORDED

run_release_unit follow-rendered-failed "${FOLLOW_ARGS[@]}"
follow_case 'a tenant that renders the tag, whose move failed' 0 - <<'RECORDED'
tenant tnt_1: runs 0.3.004-stable-TS14 (its Application renders it)
RECORDED

run_release_unit follow-rendered "${FOLLOW_ARGS[@]}"
follow_case 'a tenant that renders the tag, with no move at all' 0 - <<'RECORDED'
tenant tnt_1: runs 0.3.004-stable-TS14 (its Application renders it)
RECORDED

FOLLOW_SECONDS=0 run_release_unit follow-builds "${FOLLOW_ARGS[@]}"
follow_case 'a tenant that renders every build of its part, beside one that lacks a build' 75 'release-unit: tnt_2 (it records the release, and neither its Application nor a Versions run of this release proves it) did not run 0.3.004-stable-TS14 within 0 seconds. The run run_1 succeeded: open /runs' <<'RECORDED'
tenant tnt_1: runs 0.3.004-stable-TS14 (its Application renders it)
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_2
RECORDED

FOLLOW_SECONDS=0 run_release_unit follow-bundle "${FOLLOW_ARGS[@]}"
follow_case 'a tenant whose bundle renders the tag, beside one whose bundle renders the old tag' 75 'release-unit: tnt_2 (it records the release, and neither its Application nor a Versions run of this release proves it) did not run 0.3.004-stable-TS14 within 0 seconds. The run run_1 succeeded: open /runs' <<'RECORDED'
tenant tnt_1: runs 0.3.004-stable-TS14 (its Application renders it)
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_2
RECORDED

run_release_unit follow-no-runs "${FOLLOW_ARGS[@]}"
follow_case 'a Manager that names no Versions runs for a part' 75 'release-unit: the versions of tenant tnt_1 carry no Versions runs for shop, so a run that moved it to 0.3.004-stable-TS14-bbbbbbb cannot be told from one that did not. The run run_1 succeeded; whether the following tenants run it is not known: open /runs' <<'RECORDED'
RECORDED

run_release_unit follow-no-versions "${FOLLOW_ARGS[@]}"
follow_case 'a Manager that names no rendered versions for a tenant' 75 'release-unit: the live state of tenant tnt_1 names no rendered versions, so whether its Application renders 0.3.004-stable-TS14-bbbbbbb cannot be told. The run run_1 succeeded; whether the following tenants run it is not known: open /runs' <<'RECORDED'
RECORDED

run_release_unit follow-no-commit "${FOLLOW_ARGS[@]}"
follow_case 'a Manager that names no commit for the release the stage runs' 75 'release-unit: the Manager names no full commit for the release of shop, so the image tag its tenants run cannot be told. The run run_1 succeeded; whether the following tenants run it is not known: open /runs' <<'RECORDED'
RECORDED

# THE COPY FROM PROD TO TEST reads the same rule before the release request: a tenant that records the
# tag while its newest move failed and whose Application does not render it is the retry after a red
# copy, which the Manager's put-release would end green without changing anything for it. A tenant whose
# Application renders the tag is not waited for, whatever its move ended as.
run_release_unit follow-held manager@master.example.invalid shop --prod-to-test
expect 'a tenant that records the tag while the Versions run that moved it to the tag failed' 1 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
~~~ standard error ~~~
release-unit: tenant tnt_1: its Versions run run_v1 failed: open /runs/run_v1; the release would change nothing for it, so nothing was planned
RECORDED
calls 'a tenant that records the tag while the Versions run that moved it to the tag failed' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_1/live cookie=current origin=n/a
RECORDED
no_session 'a tenant that records the tag while the Versions run that moved it to the tag failed'

run_release_unit follow-held-succeeded manager@master.example.invalid shop --prod-to-test
expect 'the same tenant after its Application rendered the tag and a Versions run of it succeeded' 0 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
tenant tnt_1: already runs 0.3.004-stable-TS14
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: succeeded (put-release ok)
run run_1 succeeded
~~~ standard error ~~~
RECORDED
calls 'the same tenant after its Application rendered the tag and a Versions run of it succeeded' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_1/live cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
RECORDED
no_session 'the same tenant after its Application rendered the tag and a Versions run of it succeeded'

FOLLOW_SECONDS=0 run_release_unit follow-unsynced manager@master.example.invalid shop --prod-to-test
expect 'a tenant that records the tag while its Application is not Synced' 75 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: succeeded (put-release ok)
run run_1 succeeded
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
~~~ standard error ~~~
release-unit: tnt_1 (it records the release, and neither its Application nor a Versions run of this release proves it) did not run 0.3.004-stable-TS14 within 0 seconds. The run run_1 succeeded: open /runs
RECORDED
calls 'a tenant that records the tag while its Application is not Synced' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_1/live cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_1/live cookie=current origin=n/a
RECORDED
no_session 'a tenant that records the tag while its Application is not Synced'


run_release_unit follow-held-rendered-failed manager@master.example.invalid shop --prod-to-test
follow_case 'a tenant that renders the tag, whose newest move failed' 0 - <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
tenant tnt_1: already runs 0.3.004-stable-TS14
RECORDED

run_release_unit follow-held-rendered-cancelled manager@master.example.invalid shop --prod-to-test
follow_case 'a tenant that renders the tag, whose newest move was cancelled' 0 - <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
tenant tnt_1: already runs 0.3.004-stable-TS14
RECORDED

FOLLOW_SECONDS=0 run_release_unit follow-old-render manager@master.example.invalid shop --prod-to-test
follow_case 'a tenant whose Application is Synced and Healthy on the old tag' 75 'release-unit: tnt_1 (it records the release, and neither its Application nor a Versions run of this release proves it) did not run 0.3.004-stable-TS14 within 0 seconds. The run run_1 succeeded: open /runs' <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
RECORDED

FOLLOW_SECONDS=0 run_release_unit follow-unreadable manager@master.example.invalid shop --prod-to-test
follow_case 'a tenant whose Application cannot be read' 75 'release-unit: tnt_1 (it records the release, and neither its Application nor a Versions run of this release proves it) did not run 0.3.004-stable-TS14 within 0 seconds. The run run_1 succeeded: open /runs' <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
RECORDED

# THE PROMOTION AFTER A RELEASE WITH A LAGGING TENANT. The release of the unit to prod ends once its
# tenant runs the tag; the next invocation copies prod's release to test, reads the release prod offers
# (with the tenant still on the earlier tag among its carriers), reaches its release request and its
# approval, and ends once the tenant at test runs the tag. No step between the two is done by hand.
run_release_unit follow-promotion manager@master.example.invalid shop prod stable 0.3.004 $B
follow_case 'the release to prod, whose tenant is still on the earlier tag when the run succeeds' 0 - <<'RECORDED'
waiting for 1 following tenant at prod to run 0.3.004-stable-TS14: tnt_prod
tenant tnt_prod: runs 0.3.004-stable-TS14 (Versions run run_p1 succeeded)
RECORDED
run_release_unit follow-promotion manager@master.example.invalid shop --prod-to-test
follow_case 'the copy to test right after it, with the tenant at test on the earlier tag' 0 - <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
tenant tnt_1: runs 0.3.004-stable-TS14 (Versions run run_v1 succeeded)
RECORDED
grep -q '^POST /api/units/shop/release ' "$RU/calls" && grep -q '^POST /api/runs/run_1/approve ' "$RU/calls" \
  || fail 'the copy to test right after the release to prod did not reach its release request and its approval'
ok 'the copy to test right after the release to prod reached its release request and its approval'

# THE TAG THE STAGE PINS must be the release this run put there. Another release of the unit that reaches
# the stage between the run's `succeeded` and the read of the stage would otherwise be waited for and
# reported as this one: the act ends 1 and names what the stage pins.
FOLLOW_SECONDS=0 run_release_unit follow-raced "${FOLLOW_ARGS[@]}"
expect 'a stage that pins another release than the one this run put there' 1 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
~~~ standard error ~~~
release-unit: run run_1 succeeded, but test pins shop at 0.3.005-stable-TS14, and this release is 0.3.004-stable-<14 digits>: another release of shop reached test, so the tenants are not waited for. Open /runs
RECORDED
calls 'a stage that pins another release than the one this run put there' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
RECORDED
no_session 'a stage that pins another release than the one this run put there'

FOLLOW_SECONDS=0 run_release_unit follow-raced manager@master.example.invalid shop --prod-to-test
expect 'the copy from prod, where test pins another release than prod runs' 1 <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run: run_1
run run_1: planning (put-release pending)
run run_1: planned (put-release pending)
run run_1: queued (put-release pending)
run run_1: running (put-release running)
run run_1: succeeded (put-release ok)
run run_1 succeeded
~~~ standard error ~~~
release-unit: run run_1 succeeded, but test pins shop at 0.3.005-stable-TS14, and this release is 0.3.004-stable-TS14: another release of shop reached test, so the tenants are not waited for. Open /runs
RECORDED
calls 'the copy from prod, where test pins another release than prod runs' <<'RECORDED'
MINT
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceStage":"prod","sourceTag":"0.3.004-stable-20261010101010"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
RECORDED
no_session 'the copy from prod, where test pins another release than prod runs'


# A RECORD IS NOT A RUN, AND NOT A RENDERING. After `run succeeded`, a tenant whose part already records
# the tag, but whose Application does not render it and whose move did not follow this release, is not
# proven by the record, which turns at the pin write: the act waits, and names the tenant when none comes.
FOLLOW_SECONDS=0 run_release_unit follow-recorded "${FOLLOW_ARGS[@]}"
expect 'a tenant that records the tag after the release, with no Versions run after it and no rendered tag' 75 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
~~~ standard error ~~~
release-unit: tnt_1 (it records the release, and neither its Application nor a Versions run of this release proves it) did not run 0.3.004-stable-TS14 within 0 seconds. The run run_1 succeeded: open /runs
RECORDED
calls 'a tenant that records the tag after the release, with no Versions run after it and no rendered tag' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/tenants/tnt_1/live cookie=current origin=n/a
RECORDED
no_session 'a tenant that records the tag after the release, with no Versions run after it and no rendered tag'


# A REFUSED FOLLOW ENDS THE WAIT. A tenant whose Versions request was refused at its plan has no run of
# the release to wait for, and the request may be one that moves other parts than the unit's: a bundle
# that links a website the tenant does not run holds the platform release back with it. The Manager names
# each such tenant in `standing.followRefused` of the stage's release view, with its run and the reason of
# the run's record, and the act reads that view again on every look. The first look that finds a tenant
# which has not landed in the list ends the act with 1, the tenant, the run, the reason and the run's link:
# a refusal predating the invocation is named as the one that follows it, and a tenant that renders the
# release is not called refused. The stand-in proves what the act does with the answers; the Manager's
# own route test proves that the Manager gives them.
REFUSAL_REASON='release 0.4.002 of shop-apps links members the tenant does not run: the site news-web, linked from the card of the app shop: run tenant-add-app with the website {folder: web, site: news-web} before the bundle moves'
REFUSAL_LINE="release-unit: tenant tnt_1: its Versions run run_r1 was refused at its plan, so it does not move to 0.3.004-stable-TS14: $REFUSAL_REASON; open /runs/run_r1"
MISSING_LINE='release-unit: the release test runs of shop names no list of the follows that were refused. The run run_1 succeeded; whether the following tenants run it is not known: open /runs'
PLATFORM_ARGS=(manager@master.example.invalid platform test stable 0.3.004 "$B")

run_release_unit follow-refused "${FOLLOW_ARGS[@]}"
expect 'a refusal that stood before the act looked, named at the first look' 1 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
~~~ standard error ~~~
release-unit: tenant tnt_1: its Versions run run_r1 was refused at its plan, so it does not move to 0.3.004-stable-TS14: release 0.4.002 of shop-apps links members the tenant does not run: the site news-web, linked from the card of the app shop: run tenant-add-app with the website {folder: web, site: news-web} before the bundle moves; open /runs/run_r1
RECORDED
calls 'a refusal that stood before the act looked, named at the first look' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
RECORDED
no_session 'a refusal that stood before the act looked, named at the first look'

run_release_unit follow-refused-lag "${FOLLOW_ARGS[@]}"
expect 'a refusal that appears after the first look, named at the next one' 1 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
~~~ standard error ~~~
release-unit: tenant tnt_1: its Versions run run_r1 was refused at its plan, so it does not move to 0.3.004-stable-TS14: release 0.4.002 of shop-apps links members the tenant does not run: the site news-web, linked from the card of the app shop: run tenant-add-app with the website {folder: web, site: news-web} before the bundle moves; open /runs/run_r1
RECORDED
calls 'a refusal that appears after the first look, named at the next one' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"test","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
GET /api/units/shop/release?stage=test cookie=current origin=n/a
GET /api/tenants/tnt_1/versions?offered=false cookie=current origin=n/a
RECORDED
no_session 'a refusal that appears after the first look, named at the next one'

# THE PLATFORM CASES. The unit released is the platform part, and the refused request is the tenant's one
# combined request, refused for the bundle's website. The refusal predating the invocation leaves the
# tenant waiting under the old reader; the failed run that follows the invocation is the newest failed
# exact-tag run of the platform part, which the generic failure of a run named without its reason.
run_release_unit follow-refused-platform-cached "${PLATFORM_ARGS[@]}"
follow_case 'the platform release, whose tenant met a cached refusal of the combined request for the bundle' 1 "${REFUSAL_LINE}" <<'RECORDED'
RECORDED

run_release_unit follow-refused-platform-failed "${PLATFORM_ARGS[@]}"
follow_case 'the platform release, whose tenant met a refusal that is its newest failed run of the platform tag' 1 "${REFUSAL_LINE}" <<'RECORDED'
RECORDED

# The same stand-in whose response omits the list's entry: the tenant is then only late, and the act waits
# as it did, so the two platform cases above rest on the response and on nothing else.
FOLLOW_SECONDS=0 run_release_unit follow-refused-platform-omitted "${PLATFORM_ARGS[@]}"
follow_case 'the platform release, where the Manager names no refusal for the tenant' 75 'release-unit: tnt_1 (it runs 0.3.003-stable-TS14-1111111, and no Versions run after this release started has moved it to 0.3.004-stable-TS14) did not run 0.3.004-stable-TS14 within 0 seconds. The run run_1 succeeded: open /runs' <<'RECORDED'
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
RECORDED

# THE INNOCENTS. A tenant whose Application renders the release has landed, whatever else the view says,
# and a refusal of a tenant the act does not wait for (another stage, suspended, rendering no part of the
# unit) is no refusal of this wait. A prod view that names a refusal is the source of the copy to test and
# is not read for the tenants of test.
run_release_unit follow-refused-rendered "${FOLLOW_ARGS[@]}"
follow_case 'a tenant that renders the tag and failed its move, which the view names as refused' 0 - <<'RECORDED'
tenant tnt_1: runs 0.3.004-stable-TS14 (its Application renders it)
RECORDED

run_release_unit follow-refused-elsewhere "${FOLLOW_ARGS[@]}"
follow_case 'refusals of tenants that are not waited for, beside a tenant that moves' 0 - <<'RECORDED'
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
tenant tnt_1: runs 0.3.004-stable-TS14 (Versions run run_v1 succeeded)
RECORDED

run_release_unit follow-refused-prod manager@master.example.invalid shop --prod-to-test
follow_case 'the copy to test, where the prod view names a refusal of the tenant at test' 0 - <<'RECORDED'
source: prod release 0.3.004-stable-TS14 of shop on bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
tenant tnt_1: runs 0.3.004-stable-TS14 (Versions run run_v1 succeeded)
RECORDED

# THE RELEASE VIEW MUST BE READABLE AND STILL BE THE RELEASE AWAITED. A stage response without the list,
# with a list that is none, or with an entry that names no run is an unreadable view and stops the watch
# as every unreadable read does; so is a list that goes missing between two looks. A stage that pins another
# release when the view is read again ends the act with the tag it now pins, and its list is not used.
run_release_unit follow-refused-missing "${FOLLOW_ARGS[@]}"
follow_case 'a stage response with no list of refused follows' 75 "$MISSING_LINE" <<'RECORDED'
RECORDED

run_release_unit follow-refused-malformed "${FOLLOW_ARGS[@]}"
follow_case 'a stage response whose list of refused follows is a string' 75 "$MISSING_LINE" <<'RECORDED'
RECORDED

run_release_unit follow-refused-nameless "${FOLLOW_ARGS[@]}"
follow_case 'a stage response whose entry names a tenant and no run' 75 "$MISSING_LINE" <<'RECORDED'
RECORDED

run_release_unit follow-refused-lost "${FOLLOW_ARGS[@]}"
follow_case 'a list of refused follows that goes missing at the next look' 75 "$MISSING_LINE" <<'RECORDED'
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
RECORDED

run_release_unit follow-refused-raced "${FOLLOW_ARGS[@]}"
follow_case 'a stage that pins another release at the next look, whose view names a refusal' 1 "release-unit: test no longer runs the release of shop that was waited for: it was 0.3.004-stable-TS14 on $B and the Manager now names 0.3.005-stable-TS14 on $B, so the tenants are not waited for. The run run_1 succeeded: open /runs" <<'RECORDED'
waiting for 1 following tenant at test to run 0.3.004-stable-TS14: tnt_1
RECORDED

# PLANTED: a copy of the act with one rule of the refusal changed must end other than the case that holds
# the rule records, in its exit code or in the last line it says. The first never reads the list (a tenant
# is then waited for until the limit); the second lets the generic failure of a run speak before the known
# reason; the third attributes a refusal to the unit by the words of its reason; the fourth reads the
# prod view for the tenants of test; the fifth lets a stage that moved on keep its list in use; the sixth
# takes a response without the list for an empty one. A copy that crashes or is killed by the time limit
# was not caught by its change, so it fails the case instead of passing it.
plant_refusal() { # what the copy does; the sed expression that makes it; the scenario; the exit code and the last line the act records; the act's arguments
  local what="$1" expression="$2" scenario="$3" recorded="$4" line="$5" ended
  shift 5
  PLANT="$WORK/release-unit-refusal"
  mkdir -p "$PLANT"
  cp "$HERE/release-unit.sh" "$PLANT/release-unit.sh"
  sed -e "$expression" "$HERE/release-unit.mjs" > "$PLANT/release-unit.mjs"
  ! cmp -s "$HERE/release-unit.mjs" "$PLANT/release-unit.mjs" || fail "the plant that $what changed nothing in release-unit.mjs"
  RELEASE_UNIT="$PLANT/release-unit.sh"
  FOLLOW_SECONDS="${PLANT_FOLLOW_SECONDS:-0}" run_release_unit "$scenario" "$@"
  RELEASE_UNIT="$HERE/release-unit.sh"
  ended="$(normalise < "$OUT/a.err" | tail -n 1)"
  ! grep -qE '^Node\.js v[0-9]' "$OUT/a.err" || fail "a copy of release-unit that $what crashed instead of running: $(grep -m1 -E '^[A-Za-z]*Error' "$OUT/a.err")"
  [ "$A_CODE" != 124 ] || fail "a copy of release-unit that $what did not end within the time limit of the case"
  { [ "$A_CODE" != "$recorded" ] || [ "$ended" != "$line" ]; } || fail "a copy of release-unit that $what ended as the act does, with $recorded on '$line'"
  ok "the planted defect was caught — a copy of release-unit that $what ends with $A_CODE on '$(printf '%.70s' "${ended#release-unit: }")' where the act ends with $recorded on '$(printf '%.70s' "${line#release-unit: }")'"
  rm -rf "$PLANT"
}
plant_refusal 'never reads the list of refused follows' '/^    if (refused.length > 0) stop/d' follow-refused-platform-cached 1 "$REFUSAL_LINE" "${PLATFORM_ARGS[@]}"
plant_refusal 'lets the generic failure of a run win over the known reason' '/^    if (refused.length > 0) stop/{h;d};/^    if (seen.failed.length > 0) stop/{G}' follow-refused-platform-failed 1 "$REFUSAL_LINE" "${PLATFORM_ARGS[@]}"
plant_refusal 'attributes a refusal to the unit by the words of its reason' 's|notLanded.has(r.tenantId)|(r.planError ?? "").includes(unit)|' follow-refused-platform-cached 1 "$REFUSAL_LINE" "${PLATFORM_ARGS[@]}"
plant_refusal 'reads the prod view for the tenants of test' 's|await readStageRelease(stage, unit, on)|await readStageRelease("prod", unit, on)|g' follow-refused-prod 0 '' manager@master.example.invalid shop --prod-to-test
PLANT_FOLLOW_SECONDS=60 plant_refusal 'keeps using the list of a stage that moved on' '/^    if (view.tag !== standing.tag/d' follow-refused-raced 1 "release-unit: test no longer runs the release of shop that was waited for: it was 0.3.004-stable-TS14 on $B and the Manager now names 0.3.005-stable-TS14 on $B, so the tenants are not waited for. The run run_1 succeeded: open /runs" "${FOLLOW_ARGS[@]}"
plant_refusal 'takes a response without the list for an empty one' 's|const refused = standing.followRefused;|const refused = standing.followRefused ??= [];|' follow-refused-missing 75 "$MISSING_LINE" "${FOLLOW_ARGS[@]}"

# PLANTED: a copy of the act that ends at `run succeeded`, as it did before, must end 0 where the
# tenant that never moves is recorded to end 75, and print none of the tenant lines.
PLANT="$WORK/release-unit-no-follow"
mkdir -p "$PLANT"
cp "$HERE/release-unit.sh" "$PLANT/release-unit.sh"
sed '/^if (release.stage !== null) await waitForFollowing/d' "$HERE/release-unit.mjs" > "$PLANT/release-unit.mjs"
! cmp -s "$HERE/release-unit.mjs" "$PLANT/release-unit.mjs" || fail 'the plant that drops the wait for the following tenants changed nothing in release-unit.mjs'
RELEASE_UNIT="$PLANT/release-unit.sh"
FOLLOW_SECONDS=0 run_release_unit follow-never "${FOLLOW_ARGS[@]}"
RELEASE_UNIT="$HERE/release-unit.sh"
[ "$A_CODE" = '0' ] || fail "a copy of release-unit that ends at run succeeded ended with $A_CODE, and the green it reports is the defect"
! grep -q '^tenant ' "$OUT/a.out" || fail 'a copy of release-unit that ends at run succeeded printed a tenant line'
ok 'the planted defect was caught — a copy of release-unit that ends at run succeeded reports green with a tenant that never moved'
rm -rf "$PLANT"

# PLANTED: a copy of the act with one rule of the judgment of a tenant changed must end other than the case
# that holds the rule records: one that takes the first run of the part for the run that moves the tag, one
# that does not read what the Application renders, and one that takes a Synced Application for one that
# renders the tag.
plant_judgment() { # what the copy does; the sed expression that makes it; the scenario; the exit code the act records; the act's arguments
  local what="$1" expression="$2" scenario="$3" recorded="$4"
  shift 4
  PLANT="$WORK/release-unit-judgment"
  mkdir -p "$PLANT"
  cp "$HERE/release-unit.sh" "$PLANT/release-unit.sh"
  sed -e "$expression" "$HERE/release-unit.mjs" > "$PLANT/release-unit.mjs"
  ! cmp -s "$HERE/release-unit.mjs" "$PLANT/release-unit.mjs" || fail "the plant that $what changed nothing in release-unit.mjs"
  RELEASE_UNIT="$PLANT/release-unit.sh"
  FOLLOW_SECONDS=0 run_release_unit "$scenario" "$@"
  RELEASE_UNIT="$HERE/release-unit.sh"
  [ "$A_CODE" != "$recorded" ] || fail "a copy of release-unit that $what ended with $recorded, as the act that does not does"
  ok "the planted defect was caught — a copy of release-unit that $what ends with $A_CODE where the act ends with $recorded"
  rm -rf "$PLANT"
}
plant_judgment 'takes the first run of a part for the run that moves the tag' 's|const moved = part.runs.find((r) => r.tag === image);|const moved = part.runs[0];|' follow-other-tag 0 "${FOLLOW_ARGS[@]}"
plant_judgment 'does not read what the Application renders' 's|if (runsImage && await rendersImage(tenant, part, image, on)) {|if (false) {|' follow-rendered-cancelled 0 "${FOLLOW_ARGS[@]}"
plant_judgment 'takes a Synced Application for one that renders the tag' 's|return live.versions !== null .*$|return live.argo?.sync === "Synced";|' follow-old-render 75 manager@master.example.invalid shop --prod-to-test

# THE STAGE WORD none is the release of a library: the Manager plans only its tag and the publish of
# its package, and takes no stage, so the request carries a JSON null. A stage word that is none of
# the four is refused before the door is even called.
run_release_unit success manager@master.example.invalid digita-plugins-free none stable 0.6.025 $B
expect 'the release of a library, which has no stage' 0 <<'RECORDED'
run: run_1
run run_1: planning (mint-release pending, watch-release-build pending)
run run_1: planned (mint-release pending, watch-release-build pending)
run run_1: queued (mint-release pending, watch-release-build pending)
run run_1: running (mint-release running, watch-release-build running)
run run_1: succeeded (mint-release ok, watch-release-build ok)
run run_1 succeeded
~~~ standard error ~~~
RECORDED
LIBRARY_CALLS="$OUT/library-calls"
cat > "$LIBRARY_CALLS" <<'RECORDED'
MINT
POST /api/units/digita-plugins-free/release cookie=current origin=ok
  body {"stage":null,"channel":"stable","version":"0.6.025","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
RECORDED
calls 'the release of a library, which has no stage' < "$LIBRARY_CALLS"
no_session 'the release of a library, which has no stage'

run_release_unit success manager@master.example.invalid shop staging stable 0.3.004 $B
expect 'a stage word that is none of dev, test, prod and none' 64 <<'RECORDED'
~~~ standard error ~~~
release-unit: the stage must be dev, test, prod or none (got 'staging')
RECORDED
calls 'a stage word that is none of dev, test, prod and none' <<'RECORDED'
RECORDED
no_session 'a stage word that is none of dev, test, prod and none'

# PLANTED: a copy of the act that sends the word none as the string "none", and one that lets any
# stage word through to the Manager. The first must send other bytes than the library case recorded,
# in the body's stage alone; the second must call the Manager where the refusal recorded no call. The
# innocent beside them is the same first copy given prod, which sends what the act itself sends.
PLANT="$WORK/release-unit-stage"
mkdir -p "$PLANT"
cp "$HERE/release-unit.sh" "$PLANT/release-unit.sh"
RELEASE_UNIT="$PLANT/release-unit.sh"
sed 's/release = { stage: stage === "none" ? null : stage, channel, version, commit };/release = { stage, channel, version, commit };/' "$HERE/release-unit.mjs" > "$PLANT/release-unit.mjs"
! cmp -s "$HERE/release-unit.mjs" "$PLANT/release-unit.mjs" || fail 'the plant that sends none as a string changed nothing in release-unit.mjs'
run_release_unit success manager@master.example.invalid digita-plugins-free none stable 0.6.025 $B
# The copy goes on to wait for the following tenants of a stage named "none", which the act never does; only
# the request is compared.
if diff <(sed -n '1,3p' "$LIBRARY_CALLS") <(sed -n '1,3p' "$RU/calls") > "$OUT/planted.diff"; then
  fail 'a copy of release-unit that sends none as the string "none" sent the calls the library case recorded — the check proves nothing'
fi
grep '^[<>] ' "$OUT/planted.diff" > "$OUT/planted.changed" || true
if grep -vqF '"stage":' "$OUT/planted.changed"; then
  fail "a copy of release-unit that sends none as a string differs in a line that is not the stage: $(cat "$OUT/planted.diff")"
fi
grep -qF '> ' "$OUT/planted.diff" && grep -qF '"stage":"none"' "$OUT/planted.diff" \
  || fail "a copy of release-unit that sends none as a string did not send the string: $(cat "$OUT/planted.diff")"
ok 'the planted defect was caught — a copy of release-unit that sends none as the string "none" differs from the recorded calls in the stage of the body alone'
run_release_unit success manager@master.example.invalid shop prod stable 0.3.004 $B
calls 'the copy that sends none as a string, given prod' <<'RECORDED'
MINT
POST /api/units/shop/release cookie=current origin=ok
  body {"stage":"prod","channel":"stable","version":"0.3.004","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
POST /api/runs/run_1/approve cookie=current origin=ok
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/runs/run_1 cookie=current origin=n/a
GET /api/units/shop/release?stage=prod cookie=current origin=n/a
GET /api/tenants cookie=current origin=n/a
RECORDED
ok 'the innocent beside it stayed green — the same copy given prod sends the stage prod, as the act does'
sed '/the stage must be dev, test, prod or none/d' "$HERE/release-unit.mjs" > "$PLANT/release-unit.mjs"
! cmp -s "$HERE/release-unit.mjs" "$PLANT/release-unit.mjs" || fail 'the plant that drops the refusal of a stage word changed nothing in release-unit.mjs'
run_release_unit success manager@master.example.invalid shop staging stable 0.3.004 $B
[ -s "$RU/calls" ] || fail 'a copy of release-unit with no refusal of a stage word called nothing where the act refuses before any call — the check proves nothing'
[ "$A_CODE" != 64 ] || fail 'a copy of release-unit with no refusal of a stage word still ended with 64 — the check proves nothing'
ok 'the planted defect was caught — a copy of release-unit that lets any stage word through calls the Manager with it and does not end with 64'
RELEASE_UNIT="$HERE/release-unit.sh"
rm -rf "$PLANT"

# PLANTED: a copy of the act that prints its session once, right where the mint lands, one that
# hands it to ssh in an environment variable, and three that write it to a file: in the temporary
# folder and the home folder node names, and in /tmp by its literal path. The sentinel check above
# must find each; every case above, each printing its progress, is the innocent beside them.
PLANT="$WORK/release-unit-leak"
mkdir -p "$PLANT"
cp "$HERE/release-unit.sh" "$PLANT/release-unit.sh"
RELEASE_UNIT="$PLANT/release-unit.sh"
WRITES='s/^import { spawn } from "node:child_process";$/import { spawn } from "node:child_process"; import { writeFileSync } from "node:fs"; import { tmpdir, homedir } from "node:os";/'
LITERAL="/tmp/release-unit-plant-$SENTINEL_RUN"
trap 'rm -rf "$WORK" "$LITERAL"' EXIT
for plant in 's/^held\.add(session);$/held.add(session); process.stderr.write(`${session}\\n`);/' \
    's/{ stdio: \["pipe", "pipe", "pipe"\] }/{ stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, MANAGER_SESSION: String(session) } }/' \
    "$WRITES"$'\n''s/^held\.add(session);$/held.add(session); writeFileSync(`${tmpdir()}\/release-unit-session`, session);/' \
    "$WRITES"$'\n''s/^held\.add(session);$/held.add(session); writeFileSync(`${homedir()}\/.release-unit-session`, session);/' \
    "$WRITES"$'\n''s|^held\.add(session);$|held.add(session); writeFileSync("'"$LITERAL"'", session);|'; do
  sed "$plant" "$HERE/release-unit.mjs" > "$PLANT/release-unit.mjs"
  ! cmp -s "$HERE/release-unit.mjs" "$PLANT/release-unit.mjs" || fail "the plant $plant changed nothing in release-unit.mjs"
  run_release_unit success manager@master.example.invalid shop --prod-to-test
  if ( no_session "a copy of release-unit planted with $plant" ) 2>/dev/null; then
    fail "a copy of release-unit planted with $plant left no sentinel the check could find — the check proves nothing"
  fi
  ok "the planted defect was caught — a copy of release-unit that leaks its session leaves it in $(sed "s|$WORK|<WORK>|g" "$OUT/leaks" | tr '\n' ' ')"
  : > "$OUT/a.out"; : > "$OUT/a.err"; : > "$RU/argv"; : > "$RU/env"
  rm -rf "$RU/home" "$RU/tmp" "$LITERAL"; mkdir -p "$RU/home" "$RU/tmp"
done
[ -e "$LITERAL" ] && fail "the plant's file $LITERAL was not removed"
trap 'rm -rf "$WORK"' EXIT
RELEASE_UNIT="$HERE/release-unit.sh"
rm -rf "$PLANT"

# ===========================================================================
# TEN — a config line that fails the shape check is named by its number, and never printed
# ===========================================================================
# A CONFIG IS READ BY THE SHELL, so five launchers and five drivers refuse a line that is not a
# comment or NAME='value' before they read it. The line they refuse is the line an operator
# mistyped, and the credentials of an installation are lines of that file: a closing quote
# forgotten on STORAGE_BOX_PASSWORD makes the refusal itself print the password, to a terminal
# and to any `| tee` log. The refusal names the line by its number, and adds the NAME only when
# that name is a key of config.example.env: a token that is not a key may be a piece of a value
# (a line of base32 ends in `====`, a quote opened on one line closes on the next), so it is
# never printed, and neither is the rest of the line.
#
# The launchers share the function in require-config-assignments.sh and hand it the keys of the
# config.example.env beside them. The drivers cannot read a file beside them, because they arrive
# on one ssh session, so each carries the same function inline, hands it no keys and names line
# numbers only; this section holds every copy byte-equal to the sibling's. The planted lines are
# fixtures: no value here is a credential.
SHAPE="$WORK/shape"
mkdir -p "$SHAPE"
# each planted line with what a launcher names for it, what a driver names for it, and the pieces
# of it (split at |) that no output may carry; the last line is two lines, a quote that opens on
# the first and closes on the second
SHAPE_LABELS=(SECRET_X STORAGE_BOX_PASSWORD base32 open-quote)
SHAPE_LINES=("SECRET_X=abc def" "STORAGE_BOX_PASSWORD='planted-secret" "GEZDGNBVGY3TQOJQ====" "X='zqa
ZQPART2=zqb'")
SHAPE_LAUNCHER_NAMES=('line 3' 'line 3 (STORAGE_BOX_PASSWORD)' 'line 3' 'line 3, line 4')
SHAPE_DRIVER_NAMES=('line 3' 'line 3' 'line 3' 'line 3, line 4')
SHAPE_LAUNCHER_LEAKS=('abc def|SECRET_X' 'planted-secret' 'GEZDGNBVGY3TQOJQ' 'zqa|zqb|ZQPART2')
SHAPE_DRIVER_LEAKS=('abc def|SECRET_X' 'planted-secret|STORAGE_BOX_PASSWORD' 'GEZDGNBVGY3TQOJQ' 'zqa|zqb|ZQPART2')
SHAPE_LAUNCHERS=(master-backup master-restore regenerate-install-branch remove-slave-from-master install-machine)
SHAPE_DRIVERS=(master-backup-driver master-restore-driver regenerate-driver remove-slave-driver driver)

plant_shape() { # the file, the line to plant as its third; the drivers remove the file they are given
  printf '%s\n' '# the planted config' "FQDN='shape.example.invalid'" "$2" "OPERATOR_USER='op'" > "$1"
  chmod 600 "$1"
}
launch_shape() { # the folder the launcher stands in, the launcher, the config it is given
  local dir="$1" launcher="$2" config="$3" cwd="$WORK_A" args=("$3")
  case "$launcher" in
    regenerate-install-branch) args=(apps3.example.invalid "$config") ;;
    remove-slave-from-master) args=(apps7.example.invalid "$config"); cwd="$SLAVEWORK_A" ;;
    master-backup|master-restore) cwd="$MASTER" ;;
  esac
  A_CODE=0
  ( cd "$cwd" && bash "$dir/$launcher.sh" "${args[@]}" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
}
refused_by_number() { # what ran, the lines it must name as the refusal prints them, the pieces (split at |) no output may carry
  local piece
  [ "$A_CODE" = 65 ] || fail "$1 — the planted line ended with $A_CODE, and a refused config ends with 65"
  must 'neither a comment nor NAME=' "$1 — the shape check did not refuse the planted line"
  must ": $2. They are named" "$1 — the refusal does not name exactly '$2'"
  while IFS= read -r piece; do
    must_not "$piece" "$1 — the refusal prints a piece of the planted line"
  done <<< "${3//|/$'\n'}"
}

# ── the five launchers, run up to the refusal ──
for i in 0 1 2 3; do
  for launcher in "${SHAPE_LAUNCHERS[@]}"; do
    plant_shape "$SHAPE/launcher.env" "${SHAPE_LINES[$i]}"
    launch_shape "$HERE" "$launcher" "$SHAPE/launcher.env"
    refused_by_number "$launcher refusing ${SHAPE_LABELS[$i]}" "${SHAPE_LAUNCHER_NAMES[$i]}" "${SHAPE_LAUNCHER_LEAKS[$i]}"
    ok "$launcher refuses the planted ${SHAPE_LABELS[$i]} line as '${SHAPE_LAUNCHER_NAMES[$i]}' and prints no piece of it, exit 65"
  done
done

# ── the five drivers, run as the machine runs them: the config is their one argument ──
for i in 0 1 2 3; do
  for driver in "${SHAPE_DRIVERS[@]}"; do
    plant_shape "$SHAPE/driver.env" "${SHAPE_LINES[$i]}"
    A_CODE=0
    ( cd "$SHAPE" && bash "$HERE/$driver.sh" "$SHAPE/driver.env" ) > "$OUT/a.out" 2> "$OUT/a.err" || A_CODE=$?
    refused_by_number "$driver refusing ${SHAPE_LABELS[$i]}" "${SHAPE_DRIVER_NAMES[$i]}" "${SHAPE_DRIVER_LEAKS[$i]}"
    ok "$driver refuses the planted ${SHAPE_LABELS[$i]} line as '${SHAPE_DRIVER_NAMES[$i]}' and prints no piece of it, exit 65"
  done
done

# ── the innocent case: a well-formed config passes the shape check ──
# It states FQDN and OPERATOR_USER and nothing else, so each launcher reads it and ends on the first
# name it requires and does not find, STAGE, before any session is opened.
printf '%s\n' '# an innocent config' "FQDN='shape.example.invalid'" "OPERATOR_USER='op' # a trailing comment" '' > "$SHAPE/innocent.env"
chmod 600 "$SHAPE/innocent.env"
for launcher in "${SHAPE_LAUNCHERS[@]}"; do
  launch_shape "$HERE" "$launcher" "$SHAPE/innocent.env"
  must_not 'neither a comment nor NAME=' "$launcher — a well-formed config was refused by the shape check"
  must 'states no STAGE' "$launcher — a well-formed config did not reach the names it requires"
  [ "$A_CODE" = 65 ] || fail "$launcher — a well-formed config without STAGE ended with $A_CODE, and the missing name ends with 65"
  ok "$launcher passes a well-formed config through the shape check and stops on the name it lacks, exit 65"
done

# ── a launcher without the sibling is refused, and says which file is missing ──
mkdir -p "$SHAPE/no-sibling"
cp "$HERE"/*.sh "$SHAPE/no-sibling/"
rm "$SHAPE/no-sibling/require-config-assignments.sh"
for launcher in "${SHAPE_LAUNCHERS[@]}"; do
  launch_shape "$SHAPE/no-sibling" "$launcher" "$SHAPE/innocent.env"
  must 'require-config-assignments.sh is not beside this file' "$launcher — a missing sibling is not named"
  [ "$A_CODE" = 66 ] || fail "$launcher — a missing require-config-assignments.sh ended with $A_CODE, and a missing sibling ends with 66"
  ok "$launcher without require-config-assignments.sh beside it is refused, exit 66"
done

# ── a launcher without config.example.env beside it knows no key and names line numbers only ──
mkdir -p "$SHAPE/no-keys"
cp "$HERE"/*.sh "$SHAPE/no-keys/"
plant_shape "$SHAPE/launcher.env" "${SHAPE_LINES[1]}"
for launcher in "${SHAPE_LAUNCHERS[@]}"; do
  launch_shape "$SHAPE/no-keys" "$launcher" "$SHAPE/launcher.env"
  refused_by_number "$launcher without the example beside it, refusing ${SHAPE_LABELS[1]}" 'line 3' "${SHAPE_DRIVER_LEAKS[1]}"
  ok "$launcher without config.example.env beside it refuses the planted ${SHAPE_LABELS[1]} line as 'line 3', exit 65"
done

# ── the function, asked directly ──
# shellcheck disable=SC1091
. "$HERE/require-config-assignments.sh" || fail 'require-config-assignments.sh is not beside this file'
for key in FQDN STORAGE_BOX_PASSWORD; do
  case " $CONFIG_EXAMPLE_KEYS " in
    *" $key "*) ;;
    *) fail "the keys read from config.example.env do not hold $key — the launchers would name no line of it" ;;
  esac
done
ok 'the keys the launchers read from config.example.env hold FQDN and STORAGE_BOX_PASSWORD'
shape_ask() { # the function, the file; leaves SHAPE_RC and SHAPE_GOT; the locale is SHAPE_LOCALE, C where unset, the keys SHAPE_KEYS, none where unset
  SHAPE_RC=0
  SHAPE_GOT="$( export LC_ALL="${SHAPE_LOCALE:-C}"; BAD_LINES=''; rc=0; "$1" "$2" "${SHAPE_KEYS:-}" >/dev/null 2> "$SHAPE/ask.err" || rc=$?; printf '%s' "$BAD_LINES"; exit "$rc" )" || SHAPE_RC=$?
}
shape_is() { # the case, the return code, the BAD_LINES it must leave, then the lines of a config; the keys are SHAPE_KEYS
  local label="$1" code="$2" want="$3"
  shift 3
  printf '%s\n' "$@" > "$SHAPE/f.env"
  shape_ask require_config_assignments "$SHAPE/f.env"
  [ "$SHAPE_RC" = "$code" ] && [ "$SHAPE_GOT" = "$want" ] \
    || fail "$label — it ended with $SHAPE_RC and left '$SHAPE_GOT', and the case records $code and '$want'"
  ok "$label — return $code, '$want'"
}
SHAPE_KEYS='FQDN STAGE STORAGE_BOX_PASSWORD A_ONE C_THREE'
shape_is 'a well-formed config' 0 '' \
  '# a comment' '' "FQDN='shape.example.invalid'" '   # an indented comment' "STAGE='prod' # a trailing comment" "PW='a b \$c \"d\"'"
for i in 0 1 2; do
  shape_is "the planted ${SHAPE_LABELS[$i]} line" 1 "${SHAPE_LAUNCHER_NAMES[$i]}" \
    '# the planted config' "FQDN='shape.example.invalid'" "${SHAPE_LINES[$i]}" "OPERATOR_USER='op'"
done
shape_is "the planted ${SHAPE_LABELS[3]} lines" 1 "${SHAPE_LAUNCHER_NAMES[3]}" \
  '# the planted config' "FQDN='shape.example.invalid'" "${SHAPE_LINES[3]}" "OPERATOR_USER='op'"
shape_is 'four bad lines, of which three are named and two are keys' 1 'line 1 (A_ONE), line 2, line 3 (C_THREE)' \
  'A_ONE=x y' 'B_TWO=x y' 'C_THREE=x y' 'D_FOUR=x y'
shape_is 'a name that only starts with a key' 1 'line 1' 'FQDN_EXTRA=a b'
shape_is 'a key whose value carries an equals sign' 1 'line 1 (FQDN)' 'FQDN=a=b c'
shape_is 'a command, a lowercase name and an indented name, which have no NAME to read' 1 'line 1, line 2, line 3' \
  'echo hello' 'lower_x=abc def' ' INDENTED_X=abc def'
SHAPE_KEYS=''
shape_is 'a broken line of a real key, with no keys given' 1 'line 3' \
  '# the planted config' "FQDN='shape.example.invalid'" "${SHAPE_LINES[1]}" "OPERATOR_USER='op'"
unset SHAPE_KEYS

# ── a line that is not text: bytes no UTF-8 locale decodes, and a NUL ──
# The planted function without its own locale is told from the real one by a value of Latin-1
# bytes: the real function reads bytes and accepts it under any locale, and under a UTF-8
# locale grep cannot match those bytes with [^'] and refuses the line.
printf 'SECRET_X=abc \377\376 def\n' > "$SHAPE/bytes.env"
printf 'SECRET_X=abc\000def\n' > "$SHAPE/nul.env"
printf "FQDN='caf\351'\n" > "$SHAPE/latin1.env"
SHAPE_LOCALES="$(locale -a 2>/dev/null || true)"
SHAPE_LOCALE_LIST=C
SHAPE_HAS_UTF8=0
if grep -qiE '^C\.utf-?8$' <<< "$SHAPE_LOCALES"; then
  SHAPE_HAS_UTF8=1
  SHAPE_LOCALE_LIST='C C.UTF-8'
fi
shape_bytes_is() { # the function, the file, the locale, the return code and the BAD_LINES it must leave
  SHAPE_KEYS=SECRET_X SHAPE_LOCALE="$3" shape_ask "$1" "$2"
  [ "$SHAPE_RC" = "$4" ] && [ "$SHAPE_GOT" = "$5" ] && [ ! -s "$SHAPE/ask.err" ]
}
for locale in $SHAPE_LOCALE_LIST; do
  shape_bytes_is require_config_assignments "$SHAPE/bytes.env" "$locale" 1 'line 1 (SECRET_X)' \
    || fail "bytes no UTF-8 locale decodes, under $locale: it ended with $SHAPE_RC and left '$SHAPE_GOT' and $(wc -c < "$SHAPE/ask.err") bytes on stderr, and the case records 1, 'line 1 (SECRET_X)' and none"
  shape_bytes_is require_config_assignments "$SHAPE/nul.env" "$locale" 1 'line 1 (SECRET_X)' \
    || fail "a NUL, under $locale: it ended with $SHAPE_RC and left '$SHAPE_GOT' and $(wc -c < "$SHAPE/ask.err") bytes on stderr, and the case records 1, 'line 1 (SECRET_X)' and none"
  shape_bytes_is require_config_assignments "$SHAPE/latin1.env" "$locale" 0 '' \
    || fail "a value of Latin-1 bytes, under $locale: it ended with $SHAPE_RC and left '$SHAPE_GOT', and the case records 0 and nothing — the answer depends on the locale of the caller"
done
ok "bytes no UTF-8 locale decodes and a NUL are named by line and name alike under $SHAPE_LOCALE_LIST, a value of Latin-1 bytes passes under each, and nothing reaches stderr"

# ── a NUL followed by text with a colon: BusyBox awk ends a record at a NUL ──
# It reads the bytes after the NUL as a record of its own and its text before the first colon
# would print as a line number, a part of the value. The second line is that part shaped as a number.
printf 'SECRET_X=abc\000plantedpart:rest def\nSECRET_X=abc\0004711:rest\n' > "$SHAPE/nul-colon.env"
shape_nul_colon_is() { # the awk's folder put first on PATH, or empty for the awk on PATH; leaves SHAPE_GOT
  SHAPE_AWK_PATH="${1:+$1:}$PATH"
  PATH="$SHAPE_AWK_PATH" SHAPE_KEYS=SECRET_X shape_ask require_config_assignments "$SHAPE/nul-colon.env"
  [ "$SHAPE_RC" = 1 ] && [ "$SHAPE_GOT" = 'line 1 (SECRET_X), line 2 (SECRET_X)' ] && [ ! -s "$SHAPE/ask.err" ]
}
shape_nul_colon_is '' \
  || fail "a NUL before a colon, under the awk on PATH: it ended with $SHAPE_RC and left '$SHAPE_GOT', and the case records 1 and 'line 1 (SECRET_X), line 2 (SECRET_X)'"
ok "a NUL before a colon is named by its line number and key alone under the awk on PATH — '$SHAPE_GOT'"
SHAPE_HAS_BUSYBOX_AWK=0
if command -v busybox > /dev/null 2>&1 && busybox_applets="$(busybox --list 2> /dev/null)" && grep -qx awk <<< "$busybox_applets"; then
  SHAPE_HAS_BUSYBOX_AWK=1
  mkdir -p "$SHAPE/busybox-awk"
  ln -sf "$(command -v busybox)" "$SHAPE/busybox-awk/awk"
  shape_nul_colon_is "$SHAPE/busybox-awk" \
    || fail "a NUL before a colon, under BusyBox awk: it ended with $SHAPE_RC and left '$SHAPE_GOT', and the case records 1 and 'line 1 (SECRET_X), line 2 (SECRET_X)'"
  ok "a NUL before a colon is named by its line number and key alone under BusyBox awk — '$SHAPE_GOT'"
else
  echo 'test: NOT RUN — busybox is not on this machine, so a NUL before a colon is not run under BusyBox awk and is run under the awk on PATH only'
fi

# ── the copies the drivers carry are the sibling's function, byte for byte ──
SHAPE_SPAN='/^require_config_assignments() {$/,/^}$/p'
SHAPE_FN="$(sed -n "$SHAPE_SPAN" "$HERE/require-config-assignments.sh")"
[ -n "$SHAPE_FN" ] || fail 'require-config-assignments.sh holds no function require_config_assignments to compare the drivers to'
for driver in "${SHAPE_DRIVERS[@]}"; do
  [ "$(sed -n "$SHAPE_SPAN" "$HERE/$driver.sh")" = "$SHAPE_FN" ] \
    || fail "$driver carries a require_config_assignments that is not the one in require-config-assignments.sh"
done
sed 's/head -3/head -4/' "$HERE/driver.sh" > "$SHAPE/planted-driver.sh"
[ "$(sed -n "$SHAPE_SPAN" "$SHAPE/planted-driver.sh")" != "$SHAPE_FN" ] \
  || fail 'a driver whose function was changed by one word compared equal — the comparison proves nothing'
ok 'the five drivers carry the function of require-config-assignments.sh byte for byte, and a copy with one word changed is caught'

# ── planted defects in the function: each must leave an answer the cases above refuse ──
mutant() { # the new name of the function, then the sed script that plants the defect in its text
  local name="$1" script="$2" renamed text
  renamed="$(printf '%s\n' "$SHAPE_FN" | sed "s/^require_config_assignments() {\$/$name() {/")"
  text="$(printf '%s\n' "$renamed" | sed "$script")"
  [ "$text" != "$renamed" ] || fail "the plant for $name changed nothing in the function — the probe proves nothing"
  eval "$text"
}
printf '%s\n' '# the planted config' "FQDN='shape.example.invalid'" "${SHAPE_LINES[0]}" > "$SHAPE/f.env"
# the line comes out as grep found it: the print that cuts it down to its number and name is replaced by one of the whole line
mutant shape_prints_line 's/printf "%sline.*/print $0/'
SHAPE_KEYS=SECRET_X shape_ask shape_prints_line "$SHAPE/f.env"
[[ "$SHAPE_GOT" == *'abc def'* ]] \
  || fail "a function that prints the line left '$SHAPE_GOT' — the planted defect was not caught"
ok "the planted defect was caught — a function that prints the line leaves '$SHAPE_GOT'"
# a token that is not a key is named: the test against the keys is gone
printf '%s\n' '# the planted config' "FQDN='shape.example.invalid'" "${SHAPE_LINES[2]}" > "$SHAPE/f.env"
mutant shape_names_any_token 's/if (index(keys, " " name " ") == 0) name = ""//'
SHAPE_KEYS=FQDN shape_ask shape_names_any_token "$SHAPE/f.env"
[[ "$SHAPE_GOT" == *GEZDGNBVGY3TQOJQ* ]] \
  || fail "a function that names any token left '$SHAPE_GOT' for a line that is no key — the planted defect was not caught"
ok "the planted defect was caught — a function that names any token leaves '$SHAPE_GOT'"
# no text mode for grep: a NUL makes the file binary, and grep names the file instead of the line
mutant shape_without_text 's/grep -anvE/grep -nvE/'
SHAPE_KEYS=SECRET_X SHAPE_LOCALE=C shape_ask shape_without_text "$SHAPE/nul.env"
[ "$SHAPE_GOT" != 'line 1 (SECRET_X)' ] \
  || fail 'a function whose grep has no text mode answered a NUL line as the real one does — the planted defect was not caught'
ok "the planted defect was caught — a function without grep -a leaves '$SHAPE_GOT' for a line with a NUL"
# no locale of its own: under a UTF-8 locale grep cannot match the Latin-1 value, so the caller's locale decides
mutant shape_without_locale '/export LC_ALL=C/d'
if [ "$SHAPE_HAS_UTF8" = 1 ]; then
  SHAPE_KEYS=FQDN SHAPE_LOCALE=C.UTF-8 shape_ask shape_without_locale "$SHAPE/latin1.env"
  [ "$SHAPE_RC" = 1 ] \
    || fail "a function that keeps the caller's UTF-8 locale ended with $SHAPE_RC and left '$SHAPE_GOT' for a value of Latin-1 bytes, as the real one does — the planted defect was not caught"
  ok "the planted defect was caught — a function that keeps the caller's UTF-8 locale leaves '$SHAPE_GOT' for a value of Latin-1 bytes"
else
  echo 'test: NOT RUN — locale -a lists no C.UTF-8 on this machine, so the planted function without its own locale is not told apart from the real one, and the real one is not run under a UTF-8 locale'
fi
# no removal of the NUL: BusyBox awk reads what follows it as a record of its own and names a part of the value
mutant shape_keeps_nul "/tr -d/d"
if [ "$SHAPE_HAS_BUSYBOX_AWK" = 1 ]; then
  PATH="$SHAPE/busybox-awk:$PATH" SHAPE_KEYS=SECRET_X shape_ask shape_keeps_nul "$SHAPE/nul-colon.env"
  [[ "$SHAPE_GOT" == *plantedpart* ]] \
    || fail "a function that keeps the NUL left '$SHAPE_GOT' under BusyBox awk for a NUL before a colon — the planted defect was not caught"
  ok "the planted defect was caught — a function that keeps the NUL leaves '$SHAPE_GOT' under BusyBox awk"
else
  echo 'test: NOT RUN — busybox is not on this machine, so the planted function that keeps the NUL is not told apart from the real one'
fi
unset -f shape_prints_line shape_names_any_token shape_without_text shape_without_locale shape_keeps_nul

echo "test: covered — a config line that fails the shape check is refused by the five launchers and the five drivers by its number,"
echo "test:   and by its NAME only where the launchers read that name as a key of config.example.env, and never by its value or by a token"
echo "test:   that is no key, for a value with a blank in it, a value missing its closing quote, a line inside an open quote, a bare token and a NUL before a colon;"
echo "test:   a well-formed config passes each launcher's shape check; a launcher without require-config-assignments.sh is refused;"
echo "test:   the drivers' inline function is held byte-equal to the sibling's; a function that prints the line, one that names any token,"
echo "test:   one without grep -a, one that keeps a NUL, run under BusyBox awk where busybox is on the machine, and, where locale -a lists"
echo "test:   C.UTF-8, one without its own locale are each planted and caught."
echo "test: GREEN — every case above printed the bytes and ended with the code recorded for it,"
echo "test:   with the fixture root, this folder, the home folder, a mint stamp and a resolver's"
echo "test:   reason for a host name it cannot resolve normalised, in the C locale."
echo "test:   release-unit, run whole against a stand-in Manager behind a stand-in ssh and kubectl:"
echo "test:   prod's release put on test as its one put-release and with a step of its own, an explicit release, the three"
echo "test:   refusals of the plan and two of the source read, a prod-to-test plan that mints and one that watches a build,"
echo "test:   a failed and a cancelled run, relays lost to a rollout or hanging on one session, a watch that"
echo "test:   stops, an expired session, a lost release request and approve never sent again, a plan"
echo "test:   that asks for a secret left unapproved, the following tenants of the stage waited for until they"
echo "test:   run the tag (one that moves, one that never moves, one whose Versions run failed, a failed run that a"
echo "test:   newer one superseded, another version line, a unit no tenant renders, relays lost while they are"
echo "test:   read, and the retry after a red copy read before the release request), each release request held to the body it sent, and"
echo "test:   no session in any output, argument, environment or file, its home and temporary folders and"
echo "test:   /tmp included; copies that print it, pass it on or write it to any of those are caught."
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
echo "test:   it serves with the six permissions and no webhook, the redirect it holds to its"
echo "test:   own state, an App answered with five permissions, the App created and installed"
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
echo "test:   planted, and each is caught. A fetch that finds nothing says that the registry lacks the blob,"
echo "test:   and on the owner's master, which is that registry, that this machine has no source for its"
echo "test:   engine; a driver with one message for every machine is planted and caught."
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

node --test "$HERE/create-origin-pull-certificate.test.mjs" || fail 'origin pull certificate'
node --test "$HERE/apply-cloudflare-zone-security.test.mjs" || fail 'Cloudflare zone security'
bash "$HERE/rclone.test.sh" || fail 'the rclone of the master backup and restore (lifecycle/rclone.test.sh)'
