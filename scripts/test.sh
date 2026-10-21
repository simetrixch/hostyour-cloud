#!/usr/bin/env bash
# Fixture suites. scripts/check.sh runs them as its last section, after it built the dependencies of every chart, so the push gate runs every
# suite on the machine and no two suites write one chart's charts/ directory together.
# The suites share nothing: each works in a temporary directory of its own and listens only on a port the kernel hands it, so TEST_JOBS of them
# run at once (4 unless set). The pool lists the dependency files of every chart before and after the suites and ends red naming each one a suite wrote in the tree.
# The output of a suite is kept in a log of its own and printed in the order
# of the list below once all have ended: a passed suite as one line with its time, a failed one in full, so the end of the output names what failed.
# A suite that leaves no status (killed by the kernel, for one, which also stops the pool) is a failed suite.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
fail() { echo "test: FAIL — $1"; exit 1; }

suite_files=()
suite_notes=()
# suite <file> [<note>]: a .sh file runs with bash, a .mjs file with node --test. The pool starts the suites in this order, the slowest first (by the times a run printed on 2026-10-19),
# so the run ends when the slowest suite ends and not after the slowest has waited for a free place.
suite() {
  suite_files+=("$1")
  suite_notes+=("${2:-}")
}

suite lifecycle/test.sh 'delivery tooling, held to its recorded bytes.'
suite scripts/build-contract.test.mjs 'production build chart and immutable-field contracts.'
suite scripts/pipeline-publish.test.sh 'what a release tag publishes to the registry, what a packed tarball may carry, and the push.'
suite scripts/zot-sync.test.mjs 'registry sync — zot asks Docker Hub on a miss for the Docker Hub repositories it lists, every one the tree names among them, and for no repository the platform publishes, so a missing owned version is a 404.'
suite scripts/forgejo-ssh.test.mjs 'forge — the Forgejo SSH check reads the announced port from the install branch, is green on an SSH banner, and red on a closed, a silent or a wrong port.'
suite scripts/test-pool.test.sh 'the pool of this script runs suites at once and ends red for a failed suite and for one that left no status.'
suite scripts/plane.test.mjs 'forge — Plane waits for the forward auth on every page but /api/v1, keeps its data beside it, and renders no public default.'
suite scripts/pipeline-release.test.sh 'release pipeline decisions.'
suite scripts/check-mirror-consumers.test.sh 'a consumer of the owner'\''s mirror that names an upstream, or a version, a sha256, a chart or an allowlist entry the table does not hold, is refused by file:line.'
suite scripts/site-telemetry.test.mjs 'site statistics read API — the gate refuses every caller that is not an administrator of the website asked for.'
suite scripts/site-telemetry-registration.test.mjs 'site statistics registrations — the books render one ConfigMap per tenant and stage, with its host, proxied hosts and websites, in the namespace of the service.'
suite scripts/site-telemetry-deployment.test.mjs 'site statistics service — the Deployment, Service, NetworkPolicy, Role, script and Ingress meet and run the tested script.'
suite scripts/release-queue.test.mjs 'release queue — nine runs at a time on the build plane, never two of one unit, and the queue may only start a run.'
suite scripts/alert-mail-sender.test.mjs 'alert mail sender — every alert mail is sent from a domain the relay admits and holds a key for.'
suite scripts/manager-generator-refresh.test.mjs 'manager-generator-refresh — approved grant only.'
suite scripts/manager-pat-storage.test.mjs
suite scripts/manager-cloudflare-zone-settings.test.mjs 'manager Cloudflare zone settings — the settings token reaches the Manager from its own Vault entry and Secret, beside the DNS token, and no other inventory reads it.'
suite scripts/installation-domain.test.mjs 'installation domain planning and its launcher.'
suite scripts/post-stage-callbacks.test.mjs 'post stage callbacks — strict nonproduction allowlist.'
suite scripts/unit-charts-consumer-project.test.mjs 'unit charts in the consumer project — no unit chart of a consumer'\''s Application renders a kind its AppProject refuses.'
suite scripts/service-provisioner-redis.test.mjs 'service-provisioner redis — a claim is served by the own Redis of its namespace where one stands, else by the shared one.'
suite scripts/service-provisioner-mariadb.test.mjs 'service-provisioner mariadb — a claim is served by the own MariaDB of its namespace, with a user that owns it and the databases it names.'
suite scripts/service-provisioner-mongodb-stage.test.mjs
suite scripts/unit-redirects.test.mjs 'unit redirects — old unit hosts answer with a permanent redirect to their twins, and nothing renders without an old apex.'
suite scripts/platform-apps-appset.test.mjs 'platform apps — every app under its Application name or its own release name, on its clusters, one of them by name.'
suite scripts/cloudflare-origin-pull.test.mjs 'cloudflare origin pull — the TLSOption of a proxied host requires the client certificate its CA verifies.'
suite scripts/workload-label.test.mjs 'workload label — a namespace carries hostyour.cloud/workload only when no Application stamped it or when one of the four platform applications that render their own namespace did, and never a tenant namespace.'
suite scripts/unit-networkpolicy.test.mjs 'unit network policy — a unit admits its own pods, Traefik and the scrapers, nothing else.'
suite scripts/e2e-runner.test.mjs 'e2e runner — the password of a demo target stays bound to its host, and a run names a path on it and a case, nothing else.'
suite scripts/platform-argo-sync.test.mjs 'platform argo-sync — every inventory a release pins lets that release read its Application, and nothing else.'
suite scripts/forgejo.test.mjs 'forge — Forgejo admits the groups admins and plane-users alone, through the identity provider, and keeps its data in one volume.'
suite scripts/plane-test-accounts.test.mjs 'forge — the Plane sign-in test accounts are in the group plane-users alone, with passwords from the environment, the provider restarts onto them, and every application admits admins, only Plane and Forgejo plane-users beside them.'
suite scripts/forward-auth-gate.test.mjs 'forge — every host behind the forward auth is answered, in the embedded outpost, by providers whose applications admit admins alone, and plane-users at plane alone.'
suite scripts/forgejo-release.test.mjs 'forge — a Forgejo delivery runs forgejo-release in forgejo-build past the guard, its tokens reach the three API Tasks alone, and GitHub and Forgejo deliveries never cross.'
suite scripts/mongod-rseq.test.mjs 'mongod — a mongod pod carries the rseq workaround and its label while the platform switch is on, and neither while it is off, in the shared instance and in every unit mode.'

# One suite of the pool: `bash scripts/test.sh --suite <file>` runs it and leaves its output and "<exit status> <seconds>" in $TEST_LOGS.
if [ "${1:-}" = --suite ]; then
  log="$TEST_LOGS/${2//\//_}"
  started="$SECONDS"
  status=0
  case "$2" in
    *.sh) bash "$2" >"$log.out" 2>&1 || status=$? ;;
    *) node --test "$2" >"$log.out" 2>&1 || status=$? ;;
  esac
  echo "$status $((SECONDS - started))" >"$log.status"
  exit 0
fi

# The files helm writes into a chart's folder (charts/*, Chart.lock, tmpcharts-*) for every folder with a Chart.yaml under clusters/ and scripts/: inode, modification time and path.
# A folder that does not exist holds no chart.
chart_dependency_files() {
  local folder chart
  for folder in clusters scripts; do
    if [ -d "$folder" ]; then find "$folder" -name Chart.yaml -printf '%h\n'; fi
  done | LC_ALL=C sort | while IFS= read -r chart; do
    find "$chart" -mindepth 1 -maxdepth 1 \( -name Chart.lock -o -name 'tmpcharts-*' \) -printf '%i %T@ %p\n'
    if [ -d "$chart/charts" ]; then find "$chart/charts" -mindepth 1 -printf '%i %T@ %p\n'; fi
  done | LC_ALL=C sort
}

TEST_LOGS="$(mktemp -d)"
export TEST_LOGS
trap 'rm -rf "$TEST_LOGS"' EXIT
chart_dependency_files >"$TEST_LOGS/charts.before" || fail "the dependency files of the charts could not be listed"
# xargs ends with 125 and starts no further suite when one of them was killed; the suites without a status are named below.
printf '%s\0' "${suite_files[@]}" | xargs -0 -n1 -P "${TEST_JOBS:-4}" bash "$root/scripts/test.sh" --suite || echo "test: the pool of suites ended with status $?, so a suite was killed"
chart_dependency_files >"$TEST_LOGS/charts.after" || fail "the dependency files of the charts could not be listed"
written="$(LC_ALL=C comm -3 "$TEST_LOGS/charts.before" "$TEST_LOGS/charts.after" | sed 's/^[[:space:]]*[0-9]* [0-9.]* //' | LC_ALL=C sort -u)"

failed=()
for index in "${!suite_files[@]}"; do
  file="${suite_files[$index]}"
  log="$TEST_LOGS/${file//\//_}"
  if [ ! -f "$log.status" ]; then
    failed+=("$file")
  else
    read -r status seconds <"$log.status"
    if [ "$status" = 0 ]; then
      echo "test: ok — $file (${seconds} s)${suite_notes[$index]:+ — ${suite_notes[$index]}}"
    else
      failed+=("$file")
    fi
  fi
done
for file in ${failed[@]+"${failed[@]}"}; do
  log="$TEST_LOGS/${file//\//_}"
  echo "test: ── $file ──"
  if [ -f "$log.status" ]; then
    cat "$log.out"
    read -r status seconds <"$log.status"
    echo "test: FAIL — $file exited $status after ${seconds} s"
  else
    echo "test: FAIL — $file left no status: it was killed, or the pool stopped before it started"
  fi
done
if [ -n "$written" ]; then
  echo "test: ── the suites wrote these chart dependency files in the tree; a suite writes them in a copy of its own ──"
  printf '%s\n' "$written" | sed 's/^/test: written — /'
fi
[ "${#failed[@]}" -eq 0 ] || fail "${failed[*]}"
[ -z "$written" ] || fail 'a suite wrote chart dependency files in the tree'
echo 'test: OK — all suites green'
