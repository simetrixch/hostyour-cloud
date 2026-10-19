#!/usr/bin/env bash
# Fixture suites run in the ci of the master (the check step of the ci pipeline, after scripts/check.sh), never on the shared workstation.
# The suites share nothing: each works in a temporary directory of its own and listens only on a port the kernel hands it, so TEST_JOBS of them
# run at once (4 unless set). The charts they render get their dependencies first, one chart after the other, because two suites that rendered
# one chart before its charts/ directory stood would write it together. The output of a suite is kept in a log of its own and printed in the order
# of the list below once all have ended: a passed suite as one line with its time, a failed one in full, so the end of the output names what failed.
# A suite that leaves no status (killed by the kernel, for one, which also stops the pool) is a failed suite.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
fail() { echo "test: FAIL — $1"; exit 1; }

# The chart dependencies the suites render: "<update|build> <chart>".
chart_dependencies=(
  "update clusters/inventories/observability"
  "update clusters/inventories/postfix"
  "build clusters/inventories/manager"
  "update clusters/inventories/redis"
  "update clusters/units/redis"
  "update clusters/units/postgresql"
  "update clusters/units/mariadb"
  "update clusters/units/mongodb"
  "update clusters/units/networkpolicy"
  "update clusters/units/quota"
  "update clusters/inventories/service-provisioner"
  "update clusters/inventories/cert-manager"
  "update clusters/inventories/trust-manager"
  "build clusters/inventories/e2e-runner"
  "build clusters/inventories/gate-runner"
  "update clusters/inventories/forgejo"
  "update clusters/inventories/plane"
  "update clusters/inventories/forgejo-build"
  "update clusters/inventories/image-builder"
  "build clusters/inventories/registry"
)

suite_files=()
suite_notes=()
# suite <file> [<note>]: a .sh file runs with bash, a .mjs file with node --test. The pool starts the suites in this order.
suite() {
  suite_files+=("$1")
  suite_notes+=("${2:-}")
}

suite lifecycle/test.sh 'delivery tooling, held to its recorded bytes.'
suite scripts/pipeline-release.test.sh 'release pipeline decisions.'
suite scripts/pipeline-publish.test.sh 'what a release tag publishes to the registry, what a packed tarball may carry, and the push.'
suite scripts/check-mirror-consumers.test.sh 'a consumer of the owner'\''s mirror that names an upstream, or a version, a sha256, a chart or an allowlist entry the table does not hold, is refused by file:line.'
suite scripts/test-pool.test.sh 'the pool of this script runs suites at once, builds the chart dependencies first, and ends red for a failed suite and for one that left no status.'
suite scripts/build-contract.test.mjs 'production build chart and immutable-field contracts.'
suite scripts/site-telemetry.test.mjs 'site statistics read API — the gate refuses every caller that is not an administrator of the website asked for.'
suite scripts/alloy-access-log-strip.test.mjs 'alloy access-log strip — the query of a URL is cut off the request path and the referrer of Traefik'\''s access log before Loki, and off nothing else.'
suite scripts/site-telemetry-registration.test.mjs 'site statistics registrations — the books render one ConfigMap per tenant and stage, with its host, proxied hosts and websites, in the namespace of the service.'
suite scripts/site-telemetry-deployment.test.mjs 'site statistics service — the Deployment, Service, NetworkPolicy, Role, script and Ingress meet and run the tested script.'
suite scripts/release-queue.test.mjs 'release queue — four runs at a time on the build plane, never two of one unit, and the queue may only start a run.'
suite scripts/ci-run-keeper.test.mjs 'ci run keeper — at most 7 ci runs run at once, a newer push or a deleted branch ends the older run of its branch, and the newest 20 finished ci runs of a build namespace stay.'
suite scripts/ci-report-failure.test.mjs 'ci report — a failed ci run posts one alert with the last 60 lines of the failed step, and a green or cancelled run posts nothing.'
suite scripts/ci-commit-status.test.mjs 'ci commit status — tekton/ci is pending while a run runs, then success, failure or error, and the token travels only in a header file.'
suite scripts/ci-green-status.test.mjs 'ci green status — a commit that carries a green tekton/ci names the run that set it, and any other answer leaves the check to run.'
suite scripts/ci-failure-mail.test.mjs 'ci failure mail — the alert reaches its own route once, and becomes a mail that carries the error and escapes it; every alert mail is sent from a domain the relay holds a key for.'
suite scripts/manager-generator-refresh.test.mjs 'manager-generator-refresh — approved grant only.'
suite scripts/manager-pat-storage.test.mjs
suite scripts/manager-forge-env.test.mjs 'manager forge env — the platform and deploy repositories whole, the Forgejo host, its webhook key and the scope table reach the Manager.'
suite scripts/ingress-entrypoints.test.mjs 'ingress entrypoints — the shared ingress chart writes websecure once, whatever a consumer sets.'
suite scripts/installation-domain.test.mjs 'installation domain planning and its launcher.'
suite scripts/tenant-stage-label.test.mjs
suite scripts/post-stage-callbacks.test.mjs 'post stage callbacks — strict nonproduction allowlist.'
suite scripts/operator-sign-in-length.test.mjs 'operator sign-in length — Argo CD, Headlamp and the kube gate keep an operator signed in for at least a day.'
suite scripts/https-redirect.test.mjs 'https redirect — every cluster answers unclaimed plain http with a permanent redirect, below the ACME solver.'
suite scripts/redis-maxmemory.test.mjs 'redis maxmemory — a ceiling of half the limit, the shared server under noeviction, an own one under its registration'\''s policy.'
suite scripts/coredns-cache.test.mjs
suite scripts/tenant-appset.test.mjs 'tenant appset — one Application, one namespace and one project per tenant stage, every chart handed the whole member set.'
suite scripts/tenant-size.test.mjs 'tenant size — every registration renders, with the word or without it.'
suite scripts/tenant-own-domain-aliases.test.mjs 'tenant own domain aliases — every chart gets the list, or [] without one.'
suite scripts/tenant-proxied-hosts.test.mjs
suite scripts/tenant-display-name.test.mjs
suite scripts/tekton-feature-flags.test.mjs 'tekton feature flags — a refresh of the vendored manifest keeps coschedule disabled and the build plane alert stands.'
suite scripts/unit-alerts.test.mjs 'unit alerts — the master evaluates the PostgreSQL, Redis and MariaDB alerts of every unit, the unit renders none.'
suite scripts/manager-log-alerts.test.mjs
suite scripts/unit-mongodb-exporter.test.mjs 'unit mongodb exporter — every member of each mode scraped as the instance root.'
suite scripts/unit-charts-consumer-project.test.mjs 'unit charts in the consumer project — no unit chart of a consumer'\''s Application renders a kind its AppProject refuses.'
suite scripts/consumer-data-sizes.test.mjs 'consumer data sizes — each part at its own preset, each volume as onboarded, every preset within its row.'
suite scripts/service-provisioner-redis.test.mjs 'service-provisioner redis — a claim is served by the own Redis of its namespace where one stands, else by the shared one.'
suite scripts/service-provisioner-mariadb.test.mjs 'service-provisioner mariadb — a claim is served by the own MariaDB of its namespace, with a user that owns it and the databases it names.'
suite scripts/service-provisioner-mongodb-stage.test.mjs
suite scripts/unit-redirects.test.mjs 'unit redirects — old unit hosts answer with a permanent redirect to their twins, and nothing renders without an old apex.'
suite scripts/platform-apps-appset.test.mjs 'platform apps — every app under its Application name or its own release name, on its clusters, one of them by name.'
suite scripts/cert-manager-adoption.test.mjs 'cert-manager adoption — the addon release in place, with the owner-ref flag.'
suite scripts/trust-manager-adoption.test.mjs 'trust-manager adoption — the installer release in place.'
suite scripts/trust-manager-bundles.test.mjs 'trust-manager bundles — the Bundle after trust-manager, in the form of the cluster issuer.'
suite scripts/cert-manager-issuers.test.mjs 'cert-manager issuers — platform-acme as every cluster holds it, or the cluster authority, nothing else.'
suite scripts/cloudflare-origin-pull.test.mjs 'cloudflare origin pull — the TLSOption of a proxied host requires the client certificate its CA verifies.'
suite scripts/tenant-limits.test.mjs 'tenant limits — Traefik 3.6.2 answers 429 to one flooding visitor per chain and serves the next.'
suite scripts/unit-networkpolicy.test.mjs 'unit network policy — a unit admits its own pods, Traefik and the scrapers, nothing else.'
suite scripts/loki-retention.test.mjs 'Loki retention — logs are kept at most 30 days on every stage.'
suite scripts/ingress-access-log-alert.test.mjs 'ingress access log — Loki 3.7.4 alerts on an ingress that wrote access lines in the last day and none in the last hour.'
suite scripts/inventory-project-fit.test.mjs
suite scripts/e2e-runner.test.mjs 'e2e runner — the password of a demo target stays bound to its host, and a run names a path on it and a case, nothing else.'
suite scripts/platform-argo-sync.test.mjs 'platform argo-sync — every inventory a release pins lets that release read its Application, and nothing else.'
suite scripts/forgejo.test.mjs 'forge — Forgejo admits the groups admins and plane-users alone, through the identity provider, and keeps its data in one volume.'
suite scripts/plane-test-accounts.test.mjs 'forge — the Plane sign-in test accounts are in the group plane-users alone, with passwords from the environment, the provider restarts onto them, and every application admits admins, only Plane and Forgejo plane-users beside them.'
suite scripts/forward-auth-gate.test.mjs 'forge — every host behind the forward auth is answered, in the embedded outpost, by providers whose applications admit admins alone, and plane-users at plane alone.'
suite scripts/plane.test.mjs 'forge — Plane waits for the forward auth on every page but /api/v1, keeps its data beside it, and renders no public default.'
suite scripts/forgejo-release.test.mjs 'forge — a Forgejo delivery runs forgejo-release in forgejo-build past the guard, its tokens reach the three API Tasks alone, and GitHub and Forgejo deliveries never cross.'
suite scripts/forgejo-ssh.test.mjs 'forge — the Forgejo SSH check reads the announced port from the install branch, is green on an SSH banner, and red on a closed, a silent or a wrong port.'
suite scripts/zot-sync.test.mjs 'registry sync — zot asks Docker Hub on a miss for the Docker Hub repositories it lists, every one the tree names among them, and for no repository the platform publishes, so a missing owned version is a 404.'

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

for dependency in "${chart_dependencies[@]}"; do
  # shellcheck disable=SC2086 # "<verb> <chart>" is two words
  helm dependency $dependency || fail "helm dependency $dependency"
done

TEST_LOGS="$(mktemp -d)"
export TEST_LOGS
trap 'rm -rf "$TEST_LOGS"' EXIT
# xargs ends with 125 and starts no further suite when one of them was killed; the suites without a status are named below.
printf '%s\0' "${suite_files[@]}" | xargs -0 -n1 -P "${TEST_JOBS:-4}" bash "$root/scripts/test.sh" --suite || echo "test: the pool of suites ended with status $?, so a suite was killed"

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
[ "${#failed[@]}" -eq 0 ] || fail "${failed[*]}"
echo 'test: OK — all suites green'
