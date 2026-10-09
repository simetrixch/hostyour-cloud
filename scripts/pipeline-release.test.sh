#!/usr/bin/env bash
# The release pipeline's own shell, where it decides something a fixture can hold it to:
# class (b) appends newly declared image pins without losing held entries;
# class (d) of the bump moves a tenant onto the bundle it just built only where the bundle and
# the tenant's engines are of one line (clusters/inventories/consumer-build/templates/
# pipeline-release.yaml, bundle_engine and engine_line_off), and the bump's push retries only a
# concurrent update (concurrent_push_refusal, and commit_push against a local bare repository).
# The functions are read out of the template, as the Pipeline carries them, and run against
# fixture files; the engine-line call is held to standing before the registration is written.
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

# A function from its first line to the brace that closes it at the same indent.
extract() { # function name -> its text out of the template
  awk -v fn="$1" '
    $0 ~ "^ *" fn "\\(\\) \\{" { indent = match($0, /[^ ]/); on = 1 }
    on { print }
    on && /^ *\}$/ && match($0, /[^ ]/) == indent { exit }
  ' "$template"
}
for fn in bundle_engine engine_line_off concurrent_push_refusal commit_push bump_file; do
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

# ── bundle_engine: the engine read the way the Manager reads it ─────────────
apps="$work/apps.yaml"
engine_of() { # apps.yaml text -> CODE, and what bundle_engine set
  printf '%s' "$1" > "$apps"
  CODE=0
  bundle_engine "$apps" || CODE=$?
}

rm -f "$apps"
CODE=0; bundle_engine "$apps" || CODE=$?
[ "$CODE" = 0 ] && [ -z "$BUNDLE_ENGINE_BUILD" ] || fail "a release without apps.yaml was taken for one with an engine, or refused (exit $CODE)"
engine_of $'apps:\n  - { name: erp }\n'
[ "$CODE" = 0 ] && [ -z "$BUNDLE_ENGINE_BUILD" ] && [ -z "$BUNDLE_ENGINE_LINE" ] \
  || fail "an apps.yaml without engine was taken for one with an engine, or refused (exit $CODE: $ENGINE_REFUSAL)"
engine_of ''
[ "$CODE" = 0 ] && [ -z "$BUNDLE_ENGINE_BUILD" ] || fail "an empty apps.yaml was taken for one with an engine, or refused (exit $CODE: $ENGINE_REFUSAL)"
ok "a release without apps.yaml, an empty apps.yaml and one without engine declare no engine and are not refused"

engine_of $'engine:\n  build: digita-engine\n  line: "0.3"\n'
[ "$CODE" = 0 ] && [ "$BUNDLE_ENGINE_BUILD" = digita-engine ] && [ "$BUNDLE_ENGINE_LINE" = 0.3 ] \
  || fail "an engine the Manager reads was refused or misread (exit $CODE, '$BUNDLE_ENGINE_BUILD' '$BUNDLE_ENGINE_LINE': $ENGINE_REFUSAL)"
ok "build digita-engine with the quoted line \"0.3\" is read as the Manager reads it"

refused() { # label, apps.yaml text, a phrase the refusal carries
  engine_of "$2"
  [ "$CODE" = 1 ] || fail "PLANTED DEFECT: $1 must be refused, and bundle_engine answered $CODE with '$BUNDLE_ENGINE_BUILD' '$BUNDLE_ENGINE_LINE'"
  [ -z "$BUNDLE_ENGINE_BUILD" ] && [ -z "$BUNDLE_ENGINE_LINE" ] || fail "$1 was refused and still left an engine behind"
  case "$ENGINE_REFUSAL" in *"$3"*) ;; *) fail "$1 was refused without saying '$3': $ENGINE_REFUSAL" ;; esac
}
refused 'an unquoted line 0.3' $'engine:\n  build: digita-engine\n  line: 0.3\n' 'a quoted x.y'
refused 'an unquoted line 0.10, the number 0.1 to the Manager' $'engine:\n  build: digita-engine\n  line: 0.10\n' 'a quoted x.y'
refused 'a build without a line' $'engine:\n  build: digita-engine\n' 'declares an engine the Manager cannot read'
refused 'a line without a build' $'engine:\n  line: "0.3"\n' 'declares an engine the Manager cannot read'
refused 'a build of other characters' $'engine:\n  build: \'x"] | [load("/etc/hostname")] | .[0] // ["\'\n  line: "0.3"\n' 'lowercase letters, digits and dashes'
refused 'an engine that is no map' $'engine: digita-engine\n' 'declares an engine the Manager cannot read'
refused 'an engine key with no value' $'engine: null\n' 'declares an engine the Manager cannot read'
refused 'an engine key written ~' $'engine: ~\n' 'declares an engine the Manager cannot read'
refused 'an apps.yaml yq cannot parse' $'engine: [digita-engine\n' 'cannot be read:'
refused 'an apps.yaml that is a list' $'- erp\n' 'cannot be read:'
ok "an unquoted line, a half-declared engine, a build of other characters, an engine that is no map or null, and an apps.yaml yq cannot read are refused by name"

# ── engine_line_off: the versions of the build a registration holds off the line ──
reg="$work/registration.yaml"
cat > "$reg" <<'EOF'
approvedTags:
  erp: { digita-engine: "0.3.004-stable-20260928080242-a1b2c3d", digita-app: "0.3.004-stable-20260928080242-a1b2c3d" }
  auth: { digita-auth-backend: "0.4.000-stable-20261001000000-abc1234" }
  crm: { digita-engine: "0.3.005-stable-20260929080242-b2c3d4e" }
EOF
[ -z "$(engine_line_off digita-engine 0.3 "$reg")" ] \
  || fail "a tenant whose engines run 0.3.004 and 0.3.005 was taken for one of another line than 0.3"
ok "a tenant whose engines run 0.3.x fits a bundle written for 0.3, and a member without the engine pairs with nothing"

off="$(engine_line_off digita-engine 0.4 "$reg")"
[ "$off" = "0.3.004-stable-20260928080242-a1b2c3d, 0.3.005-stable-20260929080242-b2c3d4e" ] \
  || fail "PLANTED DEFECT: a tenant on 0.3 beside a bundle written for 0.4 must be named with each tag it runs, joined with a comma, and the answer was '$off'"
ok "a tenant on 0.3 beside a bundle written for 0.4 is named with each tag it runs"

cat > "$reg" <<'EOF'
approvedTags:
  erp: { digita-engine: "0.4.001-stable-20261010000000-3333333", digita-app: "0.4.001-stable-20261010000000-3333333" }
EOF
[ -z "$(engine_line_off digita-engine 0.4 "$reg")" ] \
  || fail "a tenant moved to 0.4 was taken for one of another line beside a bundle written for 0.4, so it could not follow 0.4 releases"
ok "a tenant whose engines run 0.4.x fits a bundle written for 0.4, so after its line move it follows 0.4 releases"
cat > "$reg" <<'EOF'
approvedTags:
  erp: { digita-engine: "0.3.004-stable-20260928080242-a1b2c3d", digita-app: "0.3.004-stable-20260928080242-a1b2c3d" }
  auth: { digita-auth-backend: "0.4.000-stable-20261001000000-abc1234" }
  crm: { digita-engine: "0.3.005-stable-20260929080242-b2c3d4e" }
EOF

# THE BUILD IS DATA TO yq, never text of its expression: a build shaped to close the key and
# call load() must find no member, and must not hand the file it names back.
printf 'the-secret-this-step-can-read\n' > "$work/secret"
off="$(engine_line_off "x\"] | [load(\"$work/secret\")] | .[0] // [\"" 0.4 "$reg" 2>&1)"
case "$off" in *the-secret-this-step-can-read*) fail "PLANTED DEFECT: a build out of the tenant's apps.yaml ran yq's load() and read a file back: '$off'" ;; esac
[ -z "$off" ] || fail "a build that names no member of the registration was answered with '$off'"
ok "a build shaped as a yq expression is a key no member holds, and reads no file"

cat > "$reg" <<'EOF'
cluster: s1
appsImage: example-apps-acme
EOF
[ -z "$(engine_line_off digita-engine 0.3 "$reg")" ] || fail "a registration that holds no versions was taken for one off the line"
ok "a registration that holds no versions pairs with nothing"

# ── the order inside class (d) ──────────────────────────────────────────────
# The call has to stand before the write it guards: a check placed after the registration is
# written would report a mismatch it had already committed.
call="$(grep -n 'off="$(engine_line_off ' "$template" | head -1 | cut -d: -f1)"
write="$(grep -n 'yq eval -i ".appsImageTag = ' "$template" | head -1 | cut -d: -f1)"
read="$(grep -n 'if ! bundle_engine "${SRC}/apps.yaml"' "$template" | head -1 | cut -d: -f1)"
[ -n "$call" ] && [ -n "$write" ] && [ -n "$read" ] \
  || fail "the template lost the engine read, the engine-line call or the appsImageTag write"
[ "$read" -lt "$call" ] && [ "$call" -lt "$write" ] \
  || fail "class (d) must read the engine (line $read), then judge the line (line $call), then write appsImageTag (line $write)"
ok "class (d) reads the engine (line $read), judges the line (line $call), then writes appsImageTag (line $write)"

# The refusal names the way forward, which exists: the Manager's tenant-line-move, offered in the
# tenant's Versions dialog. A refusal saying that nothing moves a tenant to a new line would be false.
refusal_line="$(sed -n "${call},\$p" "$template" | grep -m1 'bump: FAIL — ')"
case "$refusal_line" in
  *'Move to line'*'tenant-line-move'*) ;;
  *) fail "PLANTED DEFECT: class (d)'s line refusal must name the dialog's Move to line and the Manager run tenant-line-move: $refusal_line" ;;
esac
case "$refusal_line" in *'which nothing does yet'*) fail "class (d)'s line refusal still says nothing moves a tenant to a new line" ;; esac
ok "class (d)'s line refusal names the dialog's Move to line and the run tenant-line-move"

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

echo "pipeline-release.test: OK"
