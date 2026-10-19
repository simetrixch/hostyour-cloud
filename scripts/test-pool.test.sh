#!/usr/bin/env bash
# The pool of scripts/test.sh: its text runs here in a temporary repository, with the list of suites replaced by planted
# ones and a stand-in helm that logs its calls. The pool must run suites at once, build every chart dependency before any
# suite starts, print a passed suite as one line and a failed one in full, and end red for a failed suite and for one that
# leaves no status. Each case plants the defect it must catch and has an innocent that must pass.
#
#   bash scripts/test-pool.test.sh
set -uo pipefail
root="$(git rev-parse --show-toplevel)" || exit 1
fail() { echo "test-pool.test: RED — $*" >&2; exit 1; }
ok() { echo "test-pool.test: ok — $*"; }
work="$(mktemp -d)" || fail "no temporary directory could be made"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/bin" "$repo/suites"
git -C "$repo" init -q || fail "no repository could be made"
# Planted charts: one in each folder scripts/test.sh walks, each naming a repository, and a vendored one that names none.
for chart in clusters/inventories/app clusters/units/unit clusters/slaves/slave clusters/argocd; do
  mkdir -p "$repo/$chart"
  printf 'apiVersion: v2\nname: %s\ndependencies:\n  - name: common\n    repository: file://../common\n' "${chart##*/}" >"$repo/$chart/Chart.yaml"
done
mkdir -p "$repo/clusters/inventories/vendored"
printf 'apiVersion: v2\nname: vendored\ndependencies:\n  - name: inside\n' >"$repo/clusters/inventories/vendored/Chart.yaml"
dependencies=4
updated="$(printf 'update clusters/argocd\nupdate clusters/inventories/app\nupdate clusters/slaves/slave\nupdate clusters/units/unit')"

# A stand-in helm: it logs "<verb> <chart>" and answers 0.
cat >"$repo/bin/helm" <<'SH'
#!/usr/bin/env bash
echo "$2 $3" >>"$HELM_LOG"
SH
chmod +x "$repo/bin/helm"

# Builds the test copy of scripts/test.sh with the suites named in "$work/planted".
build_pool() {
  : >"$work/planted"
  for suite in "$@"; do printf 'suite %s\n' "$suite" >>"$work/planted"; done
  awk -v planted="$work/planted" '
    /^# One suite of the pool/ { while ((getline line < planted) > 0) print line }
    /^suite / { next }
    { print }
  ' "$root/scripts/test.sh" >"$repo/scripts/test.sh"
}
run_pool() { # jobs -> output in $work/out, status in $work/status
  : >"$work/helm.log"
  (cd "$repo" && HELM_LOG="$work/helm.log" PATH="$repo/bin:$PATH" TEST_JOBS="$1" bash scripts/test.sh >"$work/out" 2>&1; echo "$?" >"$work/status")
}
suite_file() { # name, body
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$repo/suites/$1"
}

# 1. The innocent: two passing suites, one writing to stderr, end green with a line each and no output of their own.
suite_file one.sh 'echo noise-of-one; echo warning-of-one >&2'
suite_file two.sh 'true'
build_pool suites/one.sh "suites/two.sh 'the second'"
run_pool 2
[ "$(cat "$work/status")" = 0 ] || { cat "$work/out"; fail "two passing suites did not end green"; }
grep -q '^test: ok — suites/one.sh (' "$work/out" || fail "a passed suite is not printed as a line"
grep -q '^test: ok — suites/two.sh ([0-9]* s) — the second$' "$work/out" || fail "the note of a suite is not printed beside it"
grep -q 'noise-of-one' "$work/out" && fail "the output of a passed suite is printed"
grep -q '^test: OK — all suites green$' "$work/out" || fail "a green run does not say so"
ok "two passing suites end green, one line each with their time and note, and their own output stays out"

# 2. The suites run at once: each waits for the other's marker, which only a second suite running beside it can leave.
for name in left right; do
  other=right; [ "$name" = left ] || other=left
  suite_file "$name.sh" "touch '$work/$name.up'; for _ in \$(seq 1 50); do [ -f '$work/$other.up' ] && exit 0; sleep 0.1; done; echo 'the other suite did not run beside this one'; exit 1"
done
build_pool suites/left.sh suites/right.sh
rm -f "$work"/*.up
run_pool 2
[ "$(cat "$work/status")" = 0 ] || { cat "$work/out"; fail "two suites that wait for each other did not run at once with TEST_JOBS=2"; }
rm -f "$work"/*.up
run_pool 1
[ "$(cat "$work/status")" != 0 ] || fail "PLANTED DEFECT: suites run one after the other were not seen red"
ok "TEST_JOBS=2 runs two suites at once; the planted defect, TEST_JOBS=1, is red because neither suite sees the other"

# 3. The dependencies of every chart that names a repository stand before the first suite starts, and a vendored chart is
# left alone, as scripts/check.sh leaves it.
suite_file early.sh "[ \"\$(wc -l <'$work/helm.log')\" -eq $dependencies ] || { echo \"only \$(wc -l <'$work/helm.log') of $dependencies chart dependencies stood at the start\"; exit 1; }"
build_pool suites/early.sh
run_pool 2
[ "$(cat "$work/status")" = 0 ] || { cat "$work/out"; fail "the chart dependencies did not all stand before the first suite"; }
[ "$(sort "$work/helm.log")" = "$updated" ] || { cat "$work/helm.log"; fail "the charts updated are not the four that name a repository"; }
ok "the dependencies of all $dependencies charts that name a repository are built before a suite starts, and the vendored chart is left alone"
sed -i '/repository:.*Chart.yaml/d' "$repo/scripts/test.sh"
run_pool 2
grep -qx 'update clusters/inventories/vendored' "$work/helm.log" || fail "PLANTED DEFECT: a loop without the repository guard did not update the vendored chart"
ok "the planted defect, a loop without the repository guard, updates the vendored chart, which helm refuses"

# 4. A failed suite ends red, prints its whole output after the passed ones and names itself last; the others still ran.
suite_file bad.sh 'echo first-line-of-bad; echo last-line-of-bad >&2; exit 3'
suite_file good.sh 'true'
build_pool suites/bad.sh suites/good.sh
run_pool 2
[ "$(cat "$work/status")" != 0 ] || fail "PLANTED DEFECT: a failed suite ended green"
grep -q '^test: ok — suites/good.sh (' "$work/out" || fail "the suite beside the failed one did not run"
grep -q '^first-line-of-bad$' "$work/out" && grep -q '^last-line-of-bad$' "$work/out" || fail "a failed suite is not printed in full"
grep -q '^test: FAIL — suites/bad.sh exited 3 after ' "$work/out" || fail "a failed suite does not name its exit status"
[ "$(tail -n 1 "$work/out")" = 'test: FAIL — suites/bad.sh' ] || fail "the last line does not name the failed suite"
grep -q 'all suites green' "$work/out" && fail "a red run says it is green"
ok "a failed suite ends the run red, in full after the passed ones and named on the last line; the suite beside it still ran"

# 5. A suite that kills the process running it leaves no status, which is a failure and not a green.
suite_file gone.sh 'kill -9 "$PPID"'
build_pool suites/gone.sh suites/good.sh
run_pool 2
[ "$(cat "$work/status")" != 0 ] || fail "PLANTED DEFECT: a suite that left no status ended green"
grep -q '^test: FAIL — suites/gone.sh left no status: it was killed' "$work/out" || fail "a suite without a status is not named"
ok "a suite that leaves no status ends the run red"

# 6. A .mjs suite runs with node --test.
cat >"$repo/suites/node.test.mjs" <<'JS'
import {test} from 'node:test';
import assert from 'node:assert/strict';
test('holds', () => assert.equal(1 + 1, 2));
JS
build_pool suites/node.test.mjs
run_pool 2
[ "$(cat "$work/status")" = 0 ] || { cat "$work/out"; fail "a node test suite did not end green"; }
cat >"$repo/suites/node.test.mjs" <<'JS'
import {test} from 'node:test';
import assert from 'node:assert/strict';
test('breaks', () => assert.equal(1 + 1, 3));
JS
run_pool 2
[ "$(cat "$work/status")" != 0 ] || fail "PLANTED DEFECT: a node test that fails ended green"
ok "a .mjs suite runs with node --test and its failure ends the run red"
