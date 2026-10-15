#!/usr/bin/env bash
# The release pipeline's own shell, where it decides something a fixture can hold it to:
# class (b) appends newly declared image pins without losing held entries; class (c) pins an
# inventory's value file on the install branch and on master, names the Application to wait for and
# the commit the pins stand on; platform_live passes that Application only once it stands on that
# commit or a later one, Synced and Healthy; class (d) pins a tenant bundle on its stage pin, only the
# appsBundle the engine checked, and
# writes no registration; the bump's push
# retries only a concurrent update (concurrent_push_refusal, and commit_push against a local bare
# repository); and a carrier's record is its `push` token, never its `pat` (carrier_credential). The functions are read out of the template
# (clusters/inventories/consumer-build/templates/pipeline-release.yaml), as the Pipeline carries
# them, and run against fixture files and repositories.
#
#   bash scripts/pipeline-release.test.sh
set -uo pipefail
root="$(git rev-parse --show-toplevel)" || exit 1
template="$root/clusters/inventories/consumer-build/templates/pipeline-release.yaml"
fail() { echo "pipeline-release.test: RED — $*" >&2; exit 1; }
ok() { echo "pipeline-release.test: ok — $*"; }
command -v yq >/dev/null 2>&1 || fail "yq is not on this path, and the functions under test run it"
work="$(mktemp -d)" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT
# No git call of a fixture leaves a process behind it, which a case removing its repository would
# race: scripts/standin/git-quiet.sh sets the template that prevents it and measures that it does.
# shellcheck disable=SC1091
. "$root/scripts/standin/git-quiet.sh"
planted="$(git_quiet_proof "$work")" || fail 'a fixture git starts a background maintenance'
ok "a fixture commits and pushes without starting a background maintenance; the planted defect, repositories made without the template, starts $planted"

# A function from its first line to the brace that closes it at the same indent.
extract() { # function name -> its text out of the template
  awk -v fn="$1" '
    $0 ~ "^ *" fn "\\(\\) \\{" { indent = match($0, /[^ ]/); on = 1 }
    on { print }
    on && /^ *\}$/ && match($0, /[^ ]/) == indent { exit }
  ' "$template"
}
for fn in concurrent_push_refusal commit_push bump_file pin_bundles carrier_credential own_stage_values; do
  extract "$fn" > "$work/$fn.sh"
  [ -s "$work/$fn.sh" ] || fail "the template carries no $fn function"
  # shellcheck source=/dev/null
  . "$work/$fn.sh"
done

# ── bump_file: a new declared image enters existing Books pins ─────────────
chart_values="$work/chart/values.yaml"
mkdir -p "$(dirname "$chart_values")"
cat > "$chart_values" <<'EOF'
builds:
  - {name: backend, image: example-backend, tag: product-default}
  - {name: frontend, image: example-frontend, tag: product-default, extra: preserved}
  - {name: other, image: another-producer, tag: product-default}
EOF
pins="$work/pins-prod.yaml"
cat > "$pins" <<'EOF'
builds:
  - {name: backend, image: example-backend, tag: old-backend}
  - {name: retained, image: another-unit, tag: held-tag}
  - {name: frontend-proxy, image: another-prefix-unit, tag: held-prefix-tag}
EOF
IMAGES='example-backend example-frontend'
IMAGE_TAG=0.4.002-stable-fixture
BUMPED=0
declare -A HIT_COUNT
HIT_COUNT[example-backend]=0; HIT_COUNT[example-frontend]=0
# No declaration input drives the old behavior as a planted defect inside a green run.
cp "$pins" "$work/old-behavior.yaml"
bump_file "$work/old-behavior.yaml" || fail 'legacy bump refused'
[ "$(yq '[.builds[] | select(.image == "example-frontend")] | length' "$work/old-behavior.yaml")" = 0 ] \
  || fail 'planted old behavior did not reproduce the missing frontend'
HIT_COUNT[example-backend]=0; HIT_COUNT[example-frontend]=0; BUMPED=0
bump_file "$pins" "$chart_values" || fail 'existing Books pins refused'
[ "$(yq -o=json -I=0 '.builds | map(.name)' "$pins")" = '["backend","retained","frontend-proxy","frontend"]' ] \
  || fail 'PLANTED DEFECT: newly declared frontend absent or existing order changed'
[ "$(yq '.builds[] | select(.name == "frontend") | .tag' "$pins")" = "$IMAGE_TAG" ] \
  || fail 'the new image was not pinned to the successful release'
[ "$(yq '.builds[] | select(.name == "frontend") | .extra' "$pins")" = preserved ] \
  || fail 'new declaration fields were dropped'
[ "$(yq '.builds[] | select(.name == "retained") | .tag' "$pins")" = held-tag ] \
  || fail 'an unrelated held image changed'
[ "$BUMPED" = 1 ] && [ "${HIT_COUNT[example-frontend]}" = 1 ] || fail 'new image was not counted as a native hit'
cp "$pins" "$work/once.yaml"
bump_file "$pins" "$chart_values" || fail 'repeated bump refused'
cmp -s "$pins" "$work/once.yaml" || fail 'repeated bump duplicated or changed an entry'
ok 'existing entries and held tags stay in order; a new chart image is appended once with all declaration fields'
# Two distinct chart names may share an image; pin hits alone cannot prove both names exist.
cat > "$work/aliases.yaml" <<'EOF'
builds:
  - {name: legacy-frontend, image: example-frontend, tag: old}
  - {name: retained, image: another-unit, tag: held}
EOF
IMAGES=example-frontend; HIT_COUNT[example-frontend]=0; BUMPED=0
bump_file "$work/aliases.yaml" "$chart_values" || fail 'a distinct name for an existing image refused'
[ "$(yq -o=json -I=0 '.builds | map(.name)' "$work/aliases.yaml")" = '["legacy-frontend","retained","frontend"]' ] \
  || fail 'PLANTED DEFECT: substring name match hid the new frontend despite a pin hit'
[ "${HIT_COUNT[example-frontend]}" = 2 ] || fail 'distinct aliases did not count both native pins'
cp "$work/aliases.yaml" "$work/aliases-once.yaml"
bump_file "$work/aliases.yaml" "$chart_values" || fail 'repeated alias bump refused'
cmp -s "$work/aliases.yaml" "$work/aliases-once.yaml" || fail 'repeated alias bump duplicated a name'
ok 'exact names distinguish legacy-frontend and frontend even when they share an image'
# A different chart must never receive this producer's undeclared image.
printf 'builds: [{name: frontend, image: another-unit, tag: held}]\n' > "$work/unrelated.yaml"
IMAGES=example-frontend
cp "$work/unrelated.yaml" "$work/unrelated-before.yaml"
bump_file "$work/unrelated.yaml" "$chart_values" >/dev/null 2>&1 && fail 'conflicting existing name was not refused'
cmp -s "$work/unrelated.yaml" "$work/unrelated-before.yaml" || fail 'a conflicting name changed before refusal'
printf 'builds: [{name: retained, image: another-unit, tag: held}]\n' > "$work/unrelated.yaml"
IMAGES=not-declared; BUMPED=0
cp "$work/unrelated.yaml" "$work/unrelated-before.yaml"
bump_file "$work/unrelated.yaml" "$chart_values" || fail 'unrelated chart refused'
cmp -s "$work/unrelated.yaml" "$work/unrelated-before.yaml" || fail 'an unrelated chart file changed'
[ "$BUMPED" = 0 ] || fail 'an undeclared image claimed a pin hit'
# Exercise the actual first-pin seed block, rather than a second implementation.
IMAGES='example-backend example-frontend'
pins="$work/fresh/pins-prod.yaml"; cdir="$work/chart/"; cname=fixture; STAGE=prod; PLACEHOLDER_TAG=unreleased-fixture
awk '/^ +SEEDED=0$/ {on=1} on {print} on && /^ +BUMPED=0$/ {exit}' "$template" > "$work/seed.sh"
[ -s "$work/seed.sh" ] || fail 'native first-pin seed block absent'
. "$work/seed.sh"
bump_file "$pins" "$chart_values" || fail 'freshly seeded pin refused'
[ "$(yq '.builds | length' "$pins")" = 3 ] || fail 'first-pin seed lost chart declarations'
[ "$(yq '.builds[] | select(.name == "other") | .tag' "$pins")" = "$PLACEHOLDER_TAG" ] || fail 'first-pin seed invented another producer release'
grep -qF 'bump_file "${pins}" "${cdir}values.yaml"' "$template" || fail 'Books caller did not supply chart declarations'
ok 'absent pins retain native full-list seeding; unrelated images stay unreleased and the Books caller uses declarations'
# A pins file written while a build was still declared keeps that build's row for good unless the
# bump drops it, and a tenant copies every row of the file into the versions it holds. The same
# block runs again over a file that exists: the chart declares backend, frontend and other, so the
# row for dropped must go, while the declared rows stay at the tag they hold, the real one and the
# placeholder.
pins="$work/stale/pins-prod.yaml"; mkdir -p "$(dirname "$pins")"
cat > "$work/stale-source.yaml" <<'EOF'
# fixture header
builds:
  - name: backend
    image: example-backend
    tag: 0.4.001-stable-held
  - name: dropped
    image: example-dropped
    tag: 0.4.001-stable-deleted
  - name: other
    image: another-producer
    tag: unreleased-fixture
EOF
cp "$work/stale-source.yaml" "$pins"
. "$work/seed.sh"
[ "$(yq -o=json -I=0 '.builds | map(.name)' "$pins")" = '["backend","other"]' ] \
  || fail 'PLANTED DEFECT: the row of a build the chart no longer declares stayed in the pins file'
[ "$(yq '.builds[] | select(.name == "backend") | .tag' "$pins")" = 0.4.001-stable-held ] \
  || fail 'a declared row at a real tag changed'
[ "$(yq '.builds[] | select(.name == "other") | .tag' "$pins")" = unreleased-fixture ] \
  || fail 'a declared row at the placeholder tag changed'
[ "$(head -1 "$pins")" = '# fixture header' ] || fail 'the pins file lost its header comment'
cp "$pins" "$work/pruned-once.yaml"
. "$work/seed.sh"
cmp -s "$pins" "$work/pruned-once.yaml" || fail 'a pins file that names only declared builds was rewritten'
ok 'a row of a build the chart no longer declares is dropped; declared rows stay at their real or placeholder tag'

# ── concurrent_push_refusal: which refusals of a bump's push are a race ──────
# A race is retried after a rebase, and anything else fails at once with git's words. Each case is
# git's or GitHub's own text: the three that name a concurrent update, and a protected branch and a
# ref that cannot be created as refusals that must not be taken for one.
refusal="$work/refusal"
races() { printf '%s\n' "$1" > "$refusal"; concurrent_push_refusal "$refusal"; }
races ' ! [rejected]        HEAD -> master (non-fast-forward)' \
  || fail "a non-fast-forward refusal was not taken for a concurrent update"
races ' ! [rejected]        HEAD -> master (fetch first)' \
  || fail "a remote that moved (fetch first) was not taken for a concurrent update"
races " ! [remote rejected] HEAD -> master.digitacloud.app (cannot lock ref 'refs/heads/master.digitacloud.app': is at 001f168 but expected 3f2ffe8)" \
  || fail "a ref GitHub found moved under the push was not taken for a concurrent update"
if races ' ! [remote rejected] HEAD -> master (protected branch hook declined)'; then
  fail "a protected branch was taken for a concurrent update, so it would be retried five times"
fi
if races " ! [remote rejected] HEAD -> a/b (cannot lock ref 'refs/heads/a/b': 'refs/heads/a' exists; cannot create 'refs/heads/a/b')"; then
  fail "a ref that cannot be created was taken for a ref that moved, so it would be retried five times"
fi
ok "a non-fast-forward, a fetch first and a moved ref are retried; a protected branch and a ref that cannot be created are not"

# ── commit_push: the bump's push against real git ───────────────────────────
# concurrent_push_refusal decides only where commit_push asks it, so commit_push pushes one pin
# change into a local bare repository whose hook refuses it: once with the ref moved under the push
# by a concurrent release, the lock refusal, and once as a protected branch. The user's own git
# configuration stays out, since a hooks path or commit signing there would change the answers.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.test
export UNIT=digita-jobs RELEASE_TAG=0.3.008 IMAGE_TAG=0.3.008-stable STAGE=prod
remote="$work/remote.git"
push_pin() { # hook name, hook text -> CODE and OUT of commit_push for one pin change on master
  rm -rf "$remote" "$work/seed" "$work/bump"
  { git init -q --bare -b master "$remote" &&
    git clone -q "$remote" "$work/seed" 2>/dev/null &&
    ( cd "$work/seed" &&
      echo 'a: 1' > pins.yaml && git add -A && git commit -q -m base && git push -q origin HEAD:master &&
      echo 'b: 1' > other.yaml && git add -A && git commit -q -m 'another release' &&
      git push -q origin HEAD:refs/heads/aside ) &&
    git clone -q "$remote" "$work/bump"; } || fail "the bare repository the push runs against could not be made"
  echo 'a: 2' > "$work/bump/pins.yaml"
  printf '%s\n' "$2" > "$remote/hooks/$1" && chmod +x "$remote/hooks/$1"
  CODE=0; OUT="$(TMPDIR="$work" commit_push "$work/bump" master 'the pin' 2>&1)" || CODE=$?
}

push_pin update "#!/bin/sh
if [ \"\$1\" = refs/heads/master ] && [ ! -e '$remote/moved-once' ]; then
  touch '$remote/moved-once' && git update-ref refs/heads/master refs/heads/aside
fi"
[ "$CODE" = 0 ] || fail "PLANTED DEFECT: a ref moved under the push must be rebased and pushed again, and commit_push answered $CODE: $OUT"
case "$OUT" in *"rejected by a concurrent update (attempt 1/5)"*) ;; *) fail "the moved ref was pushed without the retry this case exists for: $OUT" ;; esac
[ "$(git -C "$remote" log -2 --format=%s master | paste -sd '|')" = "release: digita-jobs 0.3.008 — pin 0.3.008-stable (prod)|another release" ] \
  || fail "the retried push did not land the pin on top of the concurrent release"
ok "a ref moved under the push is rebased onto the concurrent release and pushed again"

push_pin pre-receive '#!/bin/sh
echo "GH006: Protected branch update failed for refs/heads/master." >&2
exit 1'
[ "$CODE" = 1 ] || fail "a protected branch must fail the bump, and commit_push answered $CODE: $OUT"
case "$OUT" in *"rejected by a concurrent update"*) fail "a protected branch was retried as a concurrent update: $OUT" ;; esac
case "$OUT" in *"not as a concurrent release"*GH006*) ;; *) fail "a protected branch failed without git's own words: $OUT" ;; esac
ok "a protected branch fails at once with git's words, and is not retried"

# A pins file the bump only shortened has no bumped pin to ride on, so it must leave with the commit
# of the books clone all the same: commit_push stages the whole clone, and its caller runs after the
# loop whether or not any chart was bumped.
rm -rf "$remote" "$work/seed" "$work/bump"
{ git init -q --bare -b master "$remote" &&
  git clone -q "$remote" "$work/seed" 2>/dev/null &&
  ( cd "$work/seed" && mkdir -p charts/fixture && cp "$work/stale-source.yaml" charts/fixture/pins-prod.yaml &&
    git add -A && git commit -q -m base && git push -q origin HEAD:master ) &&
  git clone -q "$remote" "$work/bump"; } || fail "the bare repository the pruned pins are pushed to could not be made"
pins="$work/bump/charts/fixture/pins-prod.yaml"
. "$work/seed.sh"
[ "$BUMPED" = 0 ] || fail 'the pruned chart was counted as bumped, so this case would not prove the commit of a pruned file alone'
CODE=0; OUT="$(TMPDIR="$work" commit_push "$work/bump" master 'the pruned pins' 2>&1)" || CODE=$?
[ "$CODE" = 0 ] || fail "PLANTED DEFECT: a pruned pins file was not pushed, and commit_push answered $CODE: $OUT"
[ "$(git -C "$remote" show master:charts/fixture/pins-prod.yaml | yq -o=json -I=0 '.builds | map(.name)')" = '["backend","other"]' ] \
  || fail 'the pushed pins file still names the build the chart no longer declares'
ok 'a pins file only shortened by the bump is committed and pushed with no pin bumped'

# ── class (c): an inventory pin on the install branch and on master ─────────
# Every cluster of an installation renders its platform apps from the install branch, so a pin
# written on master alone is not live until a cluster release merges it. The block runs as the bump
# runs it, against a bare repository holding master and an install branch. Beside the inventory both
# branches carry, master holds one more, which the install branch does not carry yet.
awk '/# ── class \(c\)/ {on=1} /# ── the reach must exist/ {exit} on' "$template" > "$work/class-c.sh"
[ -s "$work/class-c.sh" ] || fail 'the template carries no class (c) block'
inventory_pins() { # class (c) block -> CODE and OUT of the block, the branches in $remote, the hits in $work/hits
  rm -rf "$remote" "$work/seed" "$work/cloud"
  { git init -q --bare -b master "$remote" &&
    git clone -q "$remote" "$work/seed" 2>/dev/null &&
    ( cd "$work/seed" && mkdir -p clusters/inventories/e2e-runner clusters/inventories/manager &&
      printf 'builds:\n  - {name: digita-testkit-e2e, image: digita-testkit-e2e, tag: "0.4.001-old"}\n' > clusters/inventories/e2e-runner/values-prod.yaml &&
      printf 'builds:\n  - {name: manager, image: hostyour-manager, tag: "held"}\n' > clusters/inventories/manager/values-prod.yaml &&
      git add -A && git commit -q -m base && git push -q origin HEAD:master HEAD:refs/heads/install.example.test &&
      mkdir -p clusters/inventories/trunk-only && cp clusters/inventories/e2e-runner/values-prod.yaml clusters/inventories/trunk-only/ &&
      git add -A && git commit -q -m 'trunk only' && git push -q origin HEAD:master ) &&
    git clone -q --branch master "$remote" "$work/cloud/hostyour-cloud" &&
    git clone -q --branch install.example.test "$remote" "$work/cloud/books"; } || fail 'the bare repository class (c) pushes to could not be made'
  : > "$work/hits"; rm -f "$work/platform-commit"
  IMAGES=digita-testkit-e2e; HIT_COUNT[digita-testkit-e2e]=0
  CODE=0; OUT="$(WORK="$work/cloud" BOOKS_BRANCH=install.example.test HITS_FILE="$work/hits" PLATFORM_COMMIT_FILE="$work/platform-commit" TMPDIR="$work"; . "$1" 2>&1)" || CODE=$?
}
tag_on() { git -C "$remote" show "$1:clusters/inventories/$2/values-prod.yaml" 2>/dev/null | yq '.builds[0].tag'; }
class_c_fault() { # the first way the branches and hits differ from what class (c) must leave, or nothing
  [ "$CODE" = 0 ] || { echo "the block failed: $OUT"; return; }
  [ "$(tag_on install.example.test e2e-runner)" = "$IMAGE_TAG" ] || { echo 'the install branch kept the old pin'; return; }
  [ "$(tag_on master e2e-runner)" = "$IMAGE_TAG" ] || { echo 'master kept the old pin'; return; }
  [ "$(tag_on master trunk-only)" = "$IMAGE_TAG" ] || { echo 'the inventory master alone carries kept the old pin'; return; }
  ! git -C "$remote" cat-file -e install.example.test:clusters/inventories/trunk-only/values-prod.yaml 2>/dev/null \
    || { echo 'the inventory master alone carries was written onto the install branch'; return; }
  [ "$(tag_on install.example.test manager)" = held ] || { echo 'an inventory pin of another image moved'; return; }
  [ "$(cat "$work/hits")" = 'platform e2e-runner-prod' ] || { echo "the hits are not exactly the install branch's inventory: $(cat "$work/hits")"; return; }
  [ "$(cat "$work/platform-commit" 2>&1)" = "$(git -C "$remote" rev-parse install.example.test)" ] \
    || { echo "the platform commit is not the install branch's pushed head: $(cat "$work/platform-commit" 2>&1)"; return; }
}
inventory_pins "$work/class-c.sh"
fault="$(class_c_fault)"
[ -z "$fault" ] || fail "class (c): $fault"
ok "class (c) pins the inventory on the install branch and on master, names its Application platform e2e-runner-prod and the install branch's pushed head"
ok 'PLANTED INNOCENT: an inventory master alone carries is pinned on master, and the install branch and the hits stay without it'
grep -vF 'pin_platform_inventories "${WORK}/books"' "$work/class-c.sh" > "$work/class-c-master-only.sh"
cmp -s "$work/class-c.sh" "$work/class-c-master-only.sh" && fail 'the mutant could not be planted: class (c) has no call for the install branch'
inventory_pins "$work/class-c-master-only.sh"
[ "$(class_c_fault)" = 'the install branch kept the old pin' ] \
  || fail "PLANTED MUTANT: a class (c) that writes master only must go red on the install branch, and the check said: $(class_c_fault)"
ok 'PLANTED MUTANT: a class (c) that writes master only goes red'

# ── platform_live: a platform hit passes once its Application is live with the pins ────────
# A refresh of the master's own Application of an inventory delivers nothing, so the argo-sync step
# waits for it. The fixture repository stands in for hostyour-cloud with three commits: the one
# before the pins, the pins, and a later one. kubectl answers one Application state per poll from a
# list, and repeats the last; a line "! <text>" is a refusal with that text.
extract platform_live > "$work/platform_live.sh"
[ -s "$work/platform_live.sh" ] || fail 'the template carries no platform_live function'
# shellcheck source=/dev/null
. "$work/platform_live.sh"
cloud_bare="$work/live-cloud.git"
{ git init -q --bare -b master "$cloud_bare" &&
  git -C "$cloud_bare" config uploadpack.allowAnySHA1InWant true &&
  git clone -q "$cloud_bare" "$work/live-seed" 2>/dev/null &&
  ( cd "$work/live-seed" && git commit -q --allow-empty -m before && git commit -q --allow-empty -m pins &&
    git commit -q --allow-empty -m later && git push -q origin HEAD:master ); } || fail 'the repository platform_live fetches from could not be made'
before="$(git -C "$work/live-seed" rev-parse HEAD~2)"; pinned="$(git -C "$work/live-seed" rev-parse HEAD~1)"; later="$(git -C "$work/live-seed" rev-parse HEAD)"
echo "$pinned" > "$work/live-pins"
application() { # revision, sync, health -> the Application kubectl prints, both sources at the revision
  printf '{"status":{"sync":{"status":"%s","revisions":["%s","%s"]},"health":{"status":"%s"}}}\n' "$2" "$1" "$1" "$3"
}
kubectl() {
  local poll line
  poll="$(($(cat "$work/polls") + 1))"; echo "$poll" > "$work/polls"
  line="$(sed -n "${poll}p" "$work/answers")"; [ -n "$line" ] || line="$(tail -n 1 "$work/answers")"
  case "$line" in '!'*) printf '%s\n' "${line#! }"; return 1 ;; *) printf '%s\n' "$line" ;; esac
}
sleep() { :; }
live() { # Application states, one per poll -> CODE and OUT of platform_live e2e-runner-prod
  printf '%s\n' "$@" > "$work/answers"; echo 0 > "$work/polls"
  CODE=0; OUT="$(PLATFORM_COMMIT_FILE="$work/live-pins" CLOUD_URL="file://$cloud_bare" PLATFORM_LIVE_SECONDS=60 PLATFORM_POLL_SECONDS=15 BOOKS_BRANCH=install.example.test TMPDIR="$work"; platform_live e2e-runner-prod 2>&1)" || CODE=$?
}
live "$(application "$before" Synced Healthy)"
[ "$CODE" = 1 ] && grep -qF 'FAIL — e2e-runner-prod is not live with this release after 60s' <<<"$OUT" && grep -qF "carries the pins of $pinned: no" <<<"$OUT" \
  || fail "PLANTED DEFECT: an Application that stays on the commit before the pins must fail at the bound, and platform_live said ($CODE): $OUT"
ok 'PLANTED DEFECT: an Application that stays Synced and Healthy on the commit before the pins fails at the bound and names the pins'
live "$(application "$before" Synced Healthy)" "$(application "$pinned" Synced Progressing)" "$(application "$pinned" Synced Healthy)"
[ "$CODE" = 0 ] && grep -qF 'e2e-runner-prod is live with this release after 30s' <<<"$OUT" \
  || fail "PLANTED INNOCENT: an Application that reaches the pins and turns Healthy must pass, and platform_live said ($CODE): $OUT"
ok 'PLANTED INNOCENT: an Application on the pinned commit passes once it is Synced and Healthy, and waits while it is Progressing'
live "$(application "$later" Synced Healthy)"
[ "$CODE" = 0 ] && grep -qF 'e2e-runner-prod is live with this release after 0s' <<<"$OUT" \
  || fail "an Application on a later commit carries the pins and must pass, and platform_live said ($CODE): $OUT"
ok 'an Application on a later commit of the branch carries the pins and passes'
live '! Error from server (NotFound): applications.argoproj.io "e2e-runner-prod" not found'
[ "$CODE" = 0 ] && grep -qF 'e2e-runner-prod in ns argocd does not exist' <<<"$OUT" \
  || fail "an Application the master does not run must pass with its reason, and platform_live said ($CODE): $OUT"
ok 'an Application the master does not run passes with its reason'
live '! Error from server (Forbidden): applications.argoproj.io "e2e-runner-prod" is forbidden'
[ "$CODE" = 1 ] && grep -qF 'cannot be read, and NOT because it is absent' <<<"$OUT" \
  || fail "PLANTED DEFECT: a Forbidden must fail as a missing reach, and platform_live said ($CODE): $OUT"
ok 'PLANTED DEFECT: a Forbidden fails as a missing reach'
live "$(application 0123456789abcdef0123456789abcdef01234567 Synced Healthy)"
[ "$CODE" = 1 ] && grep -qF 'which cannot be fetched from' <<<"$OUT" \
  || fail "a revision the repository does not hold must fail at once, and platform_live said ($CODE): $OUT"
ok 'a revision the repository does not hold fails at once instead of waiting'
unset -f kubectl sleep
grep -qF 'platform_live "${rname}" < /dev/null || exit 1' "$template" || fail 'the argo-sync loop does not wait for its platform hits'
ok 'the argo-sync loop waits for every platform hit and fails the release when one is not live'

# ── class (d): a bundle release is pinned on its stage pin, and no registration moves ──
# The tenant's Versions run in the Manager moves a tenant onto the pin, with its database lists and
# its engine-line check, so the bump writes the pin and leaves every registration as it stands.
books="$work/deploy-books"; rm -rf "$books"
mkdir -p "$books"/registrations/aaaaaaaaaaaa "$books"/registrations/bbbbbbbbbbbb "$books"/registrations/cccccccccccc "$books"/registrations/dddddddddddd
printf 'cluster: apps1\nappsImage: example-apps\nappsImageTag: "0.1.0-old"\n' > "$books/registrations/aaaaaaaaaaaa/prod.yaml"
printf 'cluster: apps1\nappsImage: example-apps\nappsImageTag: "0.1.0-old"\n' > "$books/registrations/bbbbbbbbbbbb/prod.yaml"
printf 'cluster: apps1\nappsImage: other-apps\nappsImageTag: "held"\n' > "$books/registrations/cccccccccccc/prod.yaml"
printf 'cluster: apps1\nappsImage: example-apps\nappsImageTag: "0.1.0-old"\n' > "$books/registrations/dddddddddddd/test.yaml"
cp -R "$books/registrations" "$work/registrations-before"
IMAGES='example-apps example-engine'; APPS_BUNDLE=example-apps; HIT_COUNT[example-apps]=0; HIT_COUNT[example-engine]=0
pin_bundles "$books" >/dev/null || fail 'pin_bundles refused'
[ "$(yq -o=json -I=0 . "$books/bundles/example-apps/pins-prod.yaml")" = "{\"builds\":[{\"name\":\"example-apps\",\"image\":\"example-apps\",\"tag\":\"$IMAGE_TAG\"}]}" ] \
  || fail "a bundle two tenants name was not pinned once at $IMAGE_TAG: $(cat "$books/bundles/example-apps/pins-prod.yaml" 2>&1)"
diff -r "$work/registrations-before" "$books/registrations" >/dev/null || fail 'PLANTED DEFECT: a bundle release wrote a tenant registration'
[ ! -e "$books/bundles/example-apps/pins-test.yaml" ] || fail 'a stage the release did not reach got a bundle pin'
[ ! -e "$books/bundles/example-engine" ] || fail 'PLANTED INNOCENT: an image no tenant names as appsImage got a bundle pin'
[ "${HIT_COUNT[example-apps]}" = 1 ] && [ "${HIT_COUNT[example-engine]}" = 0 ] \
  || fail "the bundle pin was counted ${HIT_COUNT[example-apps]} times, the image no tenant names ${HIT_COUNT[example-engine]} times"
ok 'a bundle release writes bundles/<image>/pins-<stage>.yaml once and leaves every registration as it stands; an image no tenant names gets no pin'
IMAGES=example-apps; IMAGE_TAG=0.1.2-stable-next
pin_bundles "$books" >/dev/null || fail 'pin_bundles refused the next release'
[ "$(yq -o=json -I=0 '.builds | map(.tag)' "$books/bundles/example-apps/pins-prod.yaml")" = '["0.1.2-stable-next"]' ] \
  || fail 'the next release did not replace the bundle pin with its own tag'
ok 'the next release replaces the bundle pin'
# The engine checks the one build the builds task hands on as apps-bundle (the `when` of
# check-definitions), so that build is the only one a release pins as a tenant bundle. A build a
# registration names as its appsImage, while the manifest names no appsBundle or another build, would
# otherwise move its pin with the check skipped.
cp -R "$books" "$work/books-before"
IMAGES='example-apps example-web'; IMAGE_TAG=0.1.3-stable-unchecked
for APPS_BUNDLE in '' example-web; do
  CODE=0; OUT="$(pin_bundles "$books" 2>&1)" || CODE=$?
  [ "$CODE" != 0 ] && grep -qF "registrations/aaaaaaaaaaaa/prod.yaml names example-apps as its appsImage" <<<"$OUT" \
    || fail "PLANTED DEFECT: a bundle pinned through its registration only, with appsBundle '${APPS_BUNDLE}', must fail the bump, and pin_bundles said ($CODE): $OUT"
  diff -r "$work/books-before" "$books" >/dev/null || fail "PLANTED DEFECT: the refused bundle moved its pin with appsBundle '${APPS_BUNDLE}'"
done
ok 'PLANTED DEFECT: a bundle a registration names as appsImage, where the manifest names no appsBundle or another build, fails the bump and moves no pin'
IMAGES=example-engine; APPS_BUNDLE=''; HIT_COUNT[example-engine]=0
pin_bundles "$books" >/dev/null || fail 'PLANTED INNOCENT: a unit with no appsBundle whose builds no tenant names was refused'
diff -r "$work/books-before" "$books" >/dev/null || fail 'PLANTED INNOCENT: a unit with no appsBundle wrote a bundle pin'
ok 'PLANTED INNOCENT: a unit with no appsBundle whose builds no tenant names as appsImage passes and pins no bundle'
grep -nE 'bundle_engine|engine_line_off|BUNDLE_HIT' "$template" && fail 'the deleted class (d) shell still stands in the template'
grep -nF '.appsImageTag = ' "$template" && fail 'the bump still writes appsImageTag on a registration'
grep -qF 'pin_bundles "${WORK}/deploy-books"' "$template" || fail 'the bump does not pin the bundles on the books clone'
ok 'the template writes no registration, calls pin_bundles on the books clone, and carries no class (d) engine-line shell'

# ── the engine's check of a tenant bundle: engine-pin, then check-definitions, before the bump ──
# The engine runs in the Pipeline's own pod; here its entry `node` is a stand-in that records what
# it was given, prints what the real one prints (a line per member) and exits as told.
for fn in engine_image bundle_members check_members; do
  extract "$fn" > "$work/$fn.sh"
  [ -s "$work/$fn.sh" ] || fail "the template carries no $fn function"
  # shellcheck source=/dev/null
  . "$work/$fn.sh"
done

# engine_image: the stage's pin of the engine build the bundle names, on the bundle's line. It reads the
# manifest the engine reads at the root of the tagged tree: tenant.yaml, then catalog.yaml, and apps.yaml
# only for the older layout.
STAGE=prod; BOOKS_BRANCH=install.example.test; REGISTRY=registry.example.test
engine_books="$work/engine-books"; mkdir -p "$engine_books/charts/example-engine"
printf 'builds:\n  - {name: example-engine, image: example-engine, tag: 0.6.021-stable-20261012165632}\n' > "$engine_books/charts/example-engine/pins-prod.yaml"
engine_apps="$work/engine-apps"; mkdir -p "$engine_apps"
printf 'engine:\n  build: example-engine\n  line: "0.6"\napps: []\n' > "$engine_apps/apps.yaml"
ENGINE_IMAGE=
engine_image "$engine_apps" "$engine_books" >/dev/null || fail 'the pin of the bundle line was refused'
[ "$ENGINE_IMAGE" = registry.example.test/example-engine:0.6.021-stable-20261012165632 ] || fail "the engine image of the pin is $ENGINE_IMAGE"
ok 'engine_image names the stage pin of the bundle engine on its line as a registry reference'
printf 'builds:\n  - {name: example-engine, image: example-engine, tag: 0.7.001-stable-20261012165632}\n' > "$engine_books/charts/example-engine/pins-test.yaml"
STAGE=test; ENGINE_IMAGE=
OUT="$(engine_image "$engine_apps" "$engine_books" 2>&1)" && fail 'PLANTED DEFECT: a stage that pins another line than the bundle names must fail'
grep -qF 'is written for example-engine 0.6' <<<"$OUT" && grep -qF 'pins example-engine 0.7.001-stable-20261012165632, of another line' <<<"$OUT" || fail "the refusal does not name both lines: $OUT"
[ -z "$ENGINE_IMAGE" ] || fail 'a pin of another line was handed on as the engine image'
STAGE=dev
OUT="$(engine_image "$engine_apps" "$engine_books" 2>&1)" && fail 'PLANTED DEFECT: a stage with no pin of the engine must fail'
grep -qF 'example-engine has no pin for dev' <<<"$OUT" || fail "the refusal does not name the missing pin: $OUT"
STAGE=prod
mkdir -p "$work/engine-float" "$work/engine-none"
printf 'engine:\n  build: example-engine\n  line: 0.6\napps: []\n' > "$work/engine-float/apps.yaml"
engine_image "$work/engine-float" "$engine_books" >/dev/null 2>&1 && fail 'PLANTED DEFECT: an unquoted line, which the Manager refuses, must fail'
printf 'apps: []\n' > "$work/engine-none/apps.yaml"
OUT="$(engine_image "$work/engine-none" "$engine_books" 2>&1)" && fail 'PLANTED DEFECT: a bundle naming no engine must fail, not pass unchecked'
grep -qF 'names no engine the check could run' <<<"$OUT" || fail "the refusal does not say that no engine is named: $OUT"
ok 'PLANTED DEFECT: a pin on another line, a stage without a pin, an unquoted line and no engine block all fail the task and name why'
# The tenant.yaml of a tenant unit the Manager creates, as digita-catalog-proofapps carries it: no apps.yaml.
engine_tenant="$work/engine-tenant"; mkdir -p "$engine_tenant"
cat > "$engine_tenant/tenant.yaml" <<'YAML'
engine: {build: example-engine, line: "0.6"}
apps:
  - {name: workshop, version: 01.02.015}
webs:
  - {name: starter}
YAML
ENGINE_IMAGE=
engine_image "$engine_tenant" "$engine_books" >/dev/null 2>&1 || fail 'PLANTED DEFECT: a tree with tenant.yaml and no apps.yaml, the layout of every tenant unit the Manager creates, was refused'
[ "$ENGINE_IMAGE" = registry.example.test/example-engine:0.6.021-stable-20261012165632 ] || fail "the engine image of a tenant.yaml tree is $ENGINE_IMAGE"
engine_catalog="$work/engine-catalog"; mkdir -p "$engine_catalog"
cp "$engine_tenant/tenant.yaml" "$engine_catalog/catalog.yaml"
ENGINE_IMAGE=
engine_image "$engine_catalog" "$engine_books" >/dev/null 2>&1 || fail 'PLANTED DEFECT: a tree with catalog.yaml and no apps.yaml was refused'
engine_both="$work/engine-both"; mkdir -p "$engine_both"
cp "$engine_tenant/tenant.yaml" "$engine_both/"
printf 'engine:\n  build: example-engine\n  line: "0.5"\napps: []\n' > "$engine_both/apps.yaml"
ENGINE_IMAGE=
engine_image "$engine_both" "$engine_books" >/dev/null 2>&1 || fail 'PLANTED DEFECT: apps.yaml was read before tenant.yaml, which the engine reads first'
mkdir -p "$work/engine-empty"
OUT="$(engine_image "$work/engine-empty" "$engine_books" 2>&1)" && fail 'PLANTED DEFECT: a tree with no manifest must fail, not pass unchecked'
grep -qF 'holds no tenant.yaml, catalog.yaml or apps.yaml' <<<"$OUT" || fail "the refusal does not name the manifests: $OUT"
ok 'engine_image reads tenant.yaml, then catalog.yaml, and apps.yaml only for the older layout, and fails where none stands'

# bundle_members: the app members, a key set each, the website members named as not checked.
bundle="$work/bundle"; settings="$work/settings"; mkdir -p "$bundle" "$settings"
cat > "$bundle/apps.yaml" <<'YAML'
engine: {build: example-engine, line: "0.6"}
apps:
  - {name: web, title: Website content, version: 01.01.046, sites: [show, other]}
  - {name: workshop, title: Workshop, version: 01.02.031}
  - {name: crm, title: CRM, version: 01.00.001}
YAML
OUT="$(bundle_members "$bundle" "$settings" 2>&1)" || fail "bundle_members refused a bundle of two apps and a website: $OUT"
[ "$(yq -o=json -I=0 . "$settings/members.json")" = "[{\"name\":\"workshop\",\"dir\":\"$bundle/workshop\",\"seedReference\":false,\"seedDemo\":false},{\"name\":\"crm\",\"dir\":\"$bundle/crm\",\"seedReference\":false,\"seedDemo\":false}]" ] \
  || fail "the members are not the two app folders: $(cat "$settings/members.json")"
[ "$(yq -o=json -I=0 'keys' "$settings/keys.json")" = '["workshop","crm"]' ] || fail "a key set is not made for each app member: $(cat "$settings/keys.json")"
[ "$(yq '[.[] | select(test("^1=[A-Za-z0-9+/]{43}=$"))] | length' "$settings/keys.json")" = 2 ] || fail 'a key set is not 1=<32 bytes in base64>'
grep -qF 'not checked: the website member web' <<<"$OUT" || fail "the log does not name the website member as not checked: $OUT"
while read -r key; do grep -qF "$key" <<<"$OUT" && fail 'a key set was printed'; done < <(yq '.[]' "$settings/keys.json")
cp "$settings/keys.json" "$work/keys-first.json"
bundle_members "$bundle" "$settings" >/dev/null 2>&1
cmp -s "$settings/keys.json" "$work/keys-first.json" && fail 'the key sets of two runs are the same'
ok 'bundle_members names one member per app folder, makes a key set each that is never printed, and names the website as not checked'
printf 'apps:\n  - {name: web, title: Website content, version: 01.01.046, sites: [show]}\n' > "$bundle/apps.yaml"
OUT="$(bundle_members "$bundle" "$settings" 2>&1)" || fail "bundle_members refused a bundle with no app folder: $OUT"
[ "$(cat "$settings/members.json")" = '[]' ] && grep -qF 'the bundle held no app folder to check' <<<"$OUT" || fail "a bundle with no app folder is not named as such: $OUT"
ok 'a bundle without an app folder passes with a log saying it held no app folder to check'
# The tenant.yaml of a tenant unit the Manager creates, as digita-catalog-proofapps carries it: the apps under
# apps:, the websites under webs:, and no apps.yaml.
cat > "$bundle/tenant.yaml" <<'YAML'
engine: {build: example-engine, line: "0.6"}
apps:
  - {name: workshop, version: 01.02.015}
webs:
  - {name: starter}
YAML
rm "$bundle/apps.yaml"
OUT="$(bundle_members "$bundle" "$settings" 2>&1)" || fail "PLANTED DEFECT: a bundle with tenant.yaml and no apps.yaml, the layout of every tenant unit the Manager creates, was refused: $OUT"
[ "$(yq -o=json -I=0 'map(.name)' "$settings/members.json")" = '["workshop"]' ] && [ "$(yq -o=json -I=0 'keys' "$settings/keys.json")" = '["workshop"]' ] \
  || fail "the member of a tenant.yaml bundle is not workshop: $(cat "$settings/members.json")"
grep -qF 'not checked: the website member starter' <<<"$OUT" || fail "the log does not name the webs: member as not checked: $OUT"
printf 'apps:\n  - {name: web, version: 01.01.046, sites: [show]}\n  - {name: workshop, version: 01.02.015}\nwebs:\n  - {name: starter}\n' > "$bundle/tenant.yaml"
OUT="$(bundle_members "$bundle" "$settings" 2>&1)" || fail "bundle_members refused a tenant.yaml with an entry with sites and a webs: list: $OUT"
[ "$(yq -o=json -I=0 'map(.name)' "$settings/members.json")" = '["workshop"]' ] && grep -qF 'the website member web, starter' <<<"$OUT" || fail "the website members are not web and starter: $OUT"
printf 'apps:\n  - {name: stale, version: 01.00.001}\n' > "$bundle/apps.yaml"
printf 'webs:\n  - {name: starter}\n' > "$bundle/tenant.yaml"
OUT="$(bundle_members "$bundle" "$settings" 2>&1)" || fail "bundle_members refused a tenant that runs a website alone: $OUT"
[ "$(cat "$settings/members.json")" = '[]' ] && grep -qF 'the bundle held no app folder to check' <<<"$OUT" || fail "PLANTED DEFECT: apps.yaml was read before tenant.yaml, or a tenant with no apps: list was not a bundle with no app folder: $OUT"
rm "$bundle/apps.yaml"
printf 'apps:\n  - {name: crm, version: 01.00.001}\n' > "$bundle/catalog.yaml"
rm "$bundle/tenant.yaml"
bundle_members "$bundle" "$settings" >/dev/null 2>&1 || fail 'PLANTED DEFECT: a bundle with catalog.yaml and no apps.yaml was refused'
[ "$(yq -o=json -I=0 'map(.name)' "$settings/members.json")" = '["crm"]' ] || fail 'the member of a catalog.yaml bundle is not crm'
ok 'bundle_members reads tenant.yaml, then catalog.yaml, and apps.yaml only for the older layout: apps: without sites are the members, apps: with sites and webs: the websites'
rm "$bundle/catalog.yaml"
OUT="$(bundle_members "$bundle" "$settings" 2>&1)" && fail 'PLANTED DEFECT: a bundle without a manifest must fail'
grep -qF 'holds no tenant.yaml, catalog.yaml or apps.yaml' <<<"$OUT" || fail "the refusal does not name the manifests: $OUT"
ok 'PLANTED DEFECT: a bundle that holds no tenant.yaml, catalog.yaml or apps.yaml fails'

# check_members: the engine's exit code is the verdict of the task.
node() {
  printf '%s\n' "$*" > "$work/engine-args"
  printf '%s\n%s\n%s\n' "$TENANT_MEMBERS" "$PASSWORD_FIELD_KEYS" "$PASSWORD_FIELD_ACTIVE_KEY_ID/$LOG_LEVEL/$LOG_PRETTY" > "$work/engine-env"
  printf '%s\n' "$ENGINE_OUT"
  return "$ENGINE_EXIT"
}
printf '[{"name":"workshop","dir":"/bundle/workshop","seedReference":false,"seedDemo":false}]' > "$settings/members.json"
printf '{"workshop":"1=%s"}' "$(printf '%044d' 0)" > "$settings/keys.json"
ENGINE_OUT=$'workshop entity_link_targets_missing An entity links to an entity the app does not load'; ENGINE_EXIT=1
CODE=0; OUT="$(check_members "$settings" 2>&1)" || CODE=$?
[ "$CODE" = 1 ] && grep -qF 'workshop entity_link_targets_missing' <<<"$OUT" && grep -qF 'FAIL — the engine refuses a member of the bundle (exit 1); no pin is written' <<<"$OUT" \
  || fail "PLANTED DEFECT: a member the engine refuses must fail the task and keep the engine's line, and check_members said ($CODE): $OUT"
ok 'PLANTED DEFECT: a member the engine refuses (exit 1) fails the task, with the refusal of the member in the log'
ENGINE_OUT='workshop servable'; ENGINE_EXIT=0
CODE=0; OUT="$(check_members "$settings" 2>&1)" || CODE=$?
[ "$CODE" = 0 ] && grep -qF 'workshop servable' <<<"$OUT" && grep -qF 'every app member of the bundle is servable' <<<"$OUT" \
  || fail "PLANTED INNOCENT: a bundle the engine finds servable must pass, and check_members said ($CODE): $OUT"
[ "$(cat "$work/engine-args")" = 'dist/server.js --check-definitions' ] || fail "the engine was started with: $(cat "$work/engine-args")"
{ read -r handed_members; read -r handed_keys; read -r handed_env; } < "$work/engine-env"
[ "$handed_members" = "$(cat "$settings/members.json")" ] && [ "$handed_keys" = "$(cat "$settings/keys.json")" ] && [ "$handed_env" = 1/error/false ] \
  || fail "the engine was not handed TENANT_MEMBERS, PASSWORD_FIELD_KEYS, key id 1 and a quiet log: $handed_members $handed_env"
ok 'PLANTED INNOCENT: a bundle the engine finds servable (exit 0) passes, and the engine gets the members, the key sets and a quiet log'
# The refused case goes red on a check that swallows the exit code of the engine.
sed 's/|| code=\$?/|| true/' "$work/check_members.sh" > "$work/check_members.swallowed.sh"
grep -qF '|| true' "$work/check_members.swallowed.sh" || fail 'the swallowed exit code was not planted'
ENGINE_OUT='workshop entity_link_targets_missing refused'; ENGINE_EXIT=1
CODE=0; ( . "$work/check_members.swallowed.sh"; check_members "$settings" ) >/dev/null 2>&1 || CODE=$?
[ "$CODE" = 0 ] || fail 'the planted check that swallows the exit code of the engine still failed, so the refused case proves nothing'
ok 'the refused case is red against a check that swallows the exit code of the engine'
printf '[]' > "$settings/members.json"; rm -f "$work/engine-args"
ENGINE_OUT=; ENGINE_EXIT=1
CODE=0; check_members "$settings" >/dev/null 2>&1 || CODE=$?
[ "$CODE" = 0 ] && [ ! -e "$work/engine-args" ] || fail 'a bundle with no app member must pass without starting the engine'
ok 'a bundle with no app member passes without starting the engine'
unset -f node

# builds: a unit that declares no appsBundle hands on an empty result, so engine-pin and check-definitions are skipped.
[ "$(grep -cF '> /tekton/results/apps-bundle' "$template")" = 1 ] || fail 'the builds task does not write the apps-bundle result once'
grep -F '> /tekton/results/apps-bundle' "$template" | sed 's#> /tekton/results/apps-bundle#> "${RESULT}"#' > "$work/apps-bundle.sh"
MANIFEST="$work/platform.yaml"; RESULT="$work/apps-bundle.result"
printf 'name: example\nbuilds:\n  - {name: example-apps}\nappsBundle: example-apps\n' > "$MANIFEST"
. "$work/apps-bundle.sh"
[ "$(cat "$RESULT")" = example-apps ] || fail "the result of a unit that names its bundle is: $(cat "$RESULT")"
printf 'name: example\nbuilds:\n  - {name: example-backend}\n' > "$MANIFEST"
. "$work/apps-bundle.sh"
[ -f "$RESULT" ] && [ ! -s "$RESULT" ] || fail "PLANTED INNOCENT: the result of a unit that names no bundle is not empty: $(cat "$RESULT")"
ok 'PLANTED INNOCENT: a unit that declares no appsBundle writes an empty result, which no attested build equals'
# The bump takes that result as its APPS_BUNDLE, and reads no appsBundle of its own off the manifest.
[ "$(grep -cF '.appsBundle // ""' "$template")" = 1 ] || fail 'the appsBundle of the manifest is read in more than one place, so the bump could pin a bundle the check did not open'
ok 'the appsBundle of the manifest is read once, by the builds task, whose result the check and the bump both take'

# ── carrier_credential: a carrier's record is its push token, never its pat ──
# Vault stands in as two shell functions: the login, and a curl that answers 200 with the fixture
# body in the file the function names with -o. Each call runs in a subshell, because the function
# turns errexit on as it returns from its curl.
vault_login() { VAULT_CLIENT_TOKEN=fixture-vault-token; }
curl() { # -o <file> and -w are what carrier_credential passes; the rest is the request
  local out=''
  while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { out="$2"; shift; }; shift; done
  printf '%s' "$carrier_body" > "$out"
  printf 200
}
VAULT_ADDR=https://vault.fixture.invalid VAULT_KV_MOUNT=secret VAULT_ROLE=fixture-bump
CREDENTIALS_FILE="$work/carrier-credentials"
carrier_body='{"data":{"data":{"pat":"pat-of-shop","packages":"","push":"push-of-shop","issues":"","statuses":"statuses-of-shop"}}}'
: > "$CREDENTIALS_FILE"
( carrier_credential shop https://github.com/acme/shop.git ) 2> "$work/carrier.err" || fail "an entry with push was refused: $(cat "$work/carrier.err")"
[ "$(cat "$CREDENTIALS_FILE")" = 'https://x-access-token:push-of-shop@github.com/acme/shop.git' ] \
  || fail 'PLANTED DEFECT: the carrier record is not the push token, path-qualified to the carrier repository'
grep -qF pat-of-shop "$CREDENTIALS_FILE" && fail 'PLANTED DEFECT: the carrier record carries the pat'
ok 'a carrier entry with pat and push appends the push token, path-qualified to its repository, and never the pat'
carrier_body='{"data":{"data":{"pat":"pat-of-shop","packages":"","issues":"","statuses":"statuses-of-shop"}}}'
: > "$CREDENTIALS_FILE"
( carrier_credential shop https://github.com/acme/shop.git ) 2> "$work/carrier.err" && fail 'PLANTED DEFECT: an entry without push was taken'
grep -qF "secret/build/shop/repo-pat carries no property 'push'" "$work/carrier.err" || fail "the refusal does not name push: $(cat "$work/carrier.err")"
[ -s "$CREDENTIALS_FILE" ] && fail 'an entry without push appended a record'
ok 'a carrier entry without push is refused by name, and appends nothing'

# ── own_stage_values: a stage file the release tree lacks is named, with the tag that was read ──
# The tree of the tag holds the dev and test files only, as hostyour-demo-consumer's tag did. The
# bump goes on without an own pin surface and, where no other class pins the image, fails with "no
# pin found": the line before that failure is what shows which tree was read, and which file lacked.
own="$work/own-tree"; mkdir -p "$own/chart"
printf 'builds: [{name: backend, image: example-backend, tag: product-default}]\n' > "$own/chart/values-dev.yaml"
cp "$own/chart/values-dev.yaml" "$own/chart/values-test.yaml"
UNIT=demo; RELEASE_TAG=0.8.374-stable-20261007003602; IMAGE_TAG=0.8.374-stable-20261007003602-fixture
IMAGES=example-backend; BUMPED=0; declare -A HIT_COUNT; HIT_COUNT[example-backend]=0
# Whether an output names the file that was looked for and the tag of the tree it was looked for in.
names_missing_file() { grep -qF "$1" <<< "$3" && grep -qF "$2" <<< "$3"; }
STAGE=prod
missing_out="$(own_stage_values "$own" chart 2>&1)" || fail 'a tree without the stage file ended the step before the search went on'
names_missing_file chart/values-prod.yaml "$RELEASE_TAG" "$missing_out" \
  || fail "the line for a missing stage values file does not name the file and the tag: $missing_out"
[ "$BUMPED" = 0 ] || fail 'a missing stage values file counted as a bumped pin'
# PLANTED DEFECT: the arm as it was, the file skipped without a word.
extract own_stage_values | grep -v 'echo "bump:' | sed 's/^\( *\)own_stage_values()/\1silent_own_stage_values()/' > "$work/silent.sh"
grep -q 'silent_own_stage_values()' "$work/silent.sh" && ! grep -q 'echo' "$work/silent.sh" || fail 'the planted silent arm was not made from the template function'
# shellcheck source=/dev/null
. "$work/silent.sh"
silent_out="$(silent_own_stage_values "$own" chart 2>&1)" || fail 'the planted silent arm refused a missing file'
names_missing_file chart/values-prod.yaml "$RELEASE_TAG" "$silent_out" \
  && fail 'PLANTED DEFECT: a missing values file skipped without a line is not seen by the check'
# PLANTED INNOCENT: a tree that holds the stage file bumps it and says nothing about a missing one.
STAGE=dev; BUMPED=0; HIT_COUNT[example-backend]=0
present_out="$(own_stage_values "$own" chart 2>&1; echo "bumped=$BUMPED")" || fail 'a tree with the stage file was refused'
grep -qF 'has no' <<< "$present_out" && fail "PLANTED INNOCENT: a present stage file is reported as missing: $present_out"
[ "$(yq '.builds[0].tag' "$own/chart/values-dev.yaml")" = "$IMAGE_TAG" ] || fail 'PLANTED INNOCENT: a present stage file was not bumped'
# The own-registration arm calls the function, and no arm tests the file itself before bumping it.
[ "$(grep -cF 'own_stage_values "${dest}" "${rchart}"' "$template")" = 1 ] || fail 'the own-registration arm does not call own_stage_values once'
grep -qF '[ -f "${vf}" ] && bump_file "${vf}"' "$template" && fail 'a stage values file is still skipped without a line in the template'
ok 'a stage values file the release tree lacks is named with the tag that was read; the silent arm is seen; a present file is bumped quietly'

pipeline-release.test: OK
