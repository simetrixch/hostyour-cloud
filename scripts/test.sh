#!/usr/bin/env bash
# Fixture suites run on the GitHub Actions runner, never on the shared workstation.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
fail() { echo "test: FAIL — $1"; exit 1; }
echo 'test: lifecycle/test.sh — delivery tooling in both spellings.'
bash lifecycle/test.sh || fail 'lifecycle/test.sh'
echo 'test: scripts/pipeline-release.test.sh — release pipeline decisions.'
bash scripts/pipeline-release.test.sh || fail 'scripts/pipeline-release.test.sh'
echo 'test: production build chart and immutable-field contracts on the public runner.'
node --test scripts/build-contract.test.mjs || fail 'scripts/build-contract.test.mjs'
echo 'test: release queue — one release at a time on the build plane, and the queue may only start a run.'
node --test scripts/release-queue.test.mjs || fail 'scripts/release-queue.test.mjs'
echo 'test: ci run keeper — a newer push replaces the older run of its branch, and the newest 20 finished ci runs of a build namespace stay.'
node --test scripts/ci-run-keeper.test.mjs || fail 'scripts/ci-run-keeper.test.mjs'
echo 'test: ci report — a failed ci run posts one alert with the last 60 lines of the failed step, and a green or cancelled run posts nothing.'
node --test scripts/ci-report-failure.test.mjs || fail 'scripts/ci-report-failure.test.mjs'
echo 'test: ci failure mail — the alert reaches its own route once, and becomes a mail that carries the error and escapes it.'
helm dependency update clusters/inventories/observability
node --test scripts/ci-failure-mail.test.mjs || fail 'scripts/ci-failure-mail.test.mjs'
echo 'test: manager-generator-refresh — approved grant only.'
helm dependency build clusters/inventories/manager
node --test scripts/manager-generator-refresh.test.mjs || fail 'scripts/manager-generator-refresh.test.mjs'
echo 'test: ingress entrypoints — the shared ingress chart writes websecure once, whatever a consumer sets.'
node --test scripts/ingress-entrypoints.test.mjs || fail 'scripts/ingress-entrypoints.test.mjs'
echo 'test: installation domain planning and paired launchers.'
node --test scripts/installation-domain.test.mjs || fail 'scripts/installation-domain.test.mjs'
node --test scripts/tenant-stage-label.test.mjs || fail 'scripts/tenant-stage-label.test.mjs'
echo 'test: post stage callbacks — strict nonproduction allowlist.'
node --test scripts/post-stage-callbacks.test.mjs || fail 'scripts/post-stage-callbacks.test.mjs'
echo 'test: https redirect — every cluster answers unclaimed plain http with a permanent redirect, below the ACME solver.'
node --test scripts/https-redirect.test.mjs || fail 'scripts/https-redirect.test.mjs'
echo 'test: redis maxmemory — a ceiling of half the limit, the shared server under noeviction, an own one under its registration'\''s policy.'
helm dependency update clusters/inventories/redis
helm dependency update clusters/units/redis
node --test scripts/redis-maxmemory.test.mjs || fail 'scripts/redis-maxmemory.test.mjs'
node --test scripts/coredns-cache.test.mjs || fail 'scripts/coredns-cache.test.mjs'
echo 'test: tenant size — every registration renders, with the word or without it.'
node --test scripts/tenant-size.test.mjs || fail 'scripts/tenant-size.test.mjs'
echo 'test: tenant own domain aliases — every member gets the list, or [] without one.'
node --test scripts/tenant-own-domain-aliases.test.mjs || fail 'scripts/tenant-own-domain-aliases.test.mjs'
node --test scripts/tenant-display-name.test.mjs || fail 'scripts/tenant-display-name.test.mjs'
echo 'test: tekton feature flags — a refresh of the vendored manifest keeps coschedule disabled and the build plane alert stands.'
node --test scripts/tekton-feature-flags.test.mjs || fail 'scripts/tekton-feature-flags.test.mjs'
echo 'test: unit alerts — the master evaluates the PostgreSQL, Redis and MariaDB alerts of every unit, the unit renders none.'
helm dependency update clusters/units/postgresql
helm dependency update clusters/units/mariadb
node --test scripts/unit-alerts.test.mjs || fail 'scripts/unit-alerts.test.mjs'
node --test scripts/manager-log-alerts.test.mjs || fail 'scripts/manager-log-alerts.test.mjs'
echo 'test: unit mongodb exporter — every member of each mode scraped as the instance root.'
helm dependency update clusters/units/mongodb
node --test scripts/unit-mongodb-exporter.test.mjs || fail 'scripts/unit-mongodb-exporter.test.mjs'
echo 'test: unit charts in the consumer project — no unit chart of a consumer'\''s Application renders a kind its AppProject refuses.'
helm dependency update clusters/units/networkpolicy
helm dependency update clusters/units/quota
node --test scripts/unit-charts-consumer-project.test.mjs || fail 'scripts/unit-charts-consumer-project.test.mjs'
echo 'test: consumer data sizes — each part at its own preset, each volume as onboarded, every preset within its row.'
node --test scripts/consumer-data-sizes.test.mjs || fail 'scripts/consumer-data-sizes.test.mjs'
echo 'test: service-provisioner redis — a claim is served by the own Redis of its namespace where one stands, else by the shared one.'
helm dependency update clusters/inventories/service-provisioner
node --test scripts/service-provisioner-redis.test.mjs || fail 'scripts/service-provisioner-redis.test.mjs'
echo 'test: service-provisioner mariadb — a claim is served by the own MariaDB of its namespace, with a user that owns it and the databases it names.'
node --test scripts/service-provisioner-mariadb.test.mjs || fail 'scripts/service-provisioner-mariadb.test.mjs'
node --test scripts/service-provisioner-mongodb-stage.test.mjs || fail 'scripts/service-provisioner-mongodb-stage.test.mjs'
echo 'test: unit redirects — old unit hosts answer with a permanent redirect to their twins, and nothing renders without an old apex.'
node --test scripts/unit-redirects.test.mjs || fail 'scripts/unit-redirects.test.mjs'
echo 'test: platform apps — every app under its Application name or its own release name, on its clusters, one of them by name.'
node --test scripts/platform-apps-appset.test.mjs || fail 'scripts/platform-apps-appset.test.mjs'
echo 'test: cert-manager adoption — the addon release in place, with the owner-ref flag.'
helm dependency update clusters/inventories/cert-manager
node --test scripts/cert-manager-adoption.test.mjs || fail 'scripts/cert-manager-adoption.test.mjs'
echo 'test: trust-manager adoption — the installer release in place, its bundle in the form of the cluster issuer.'
helm dependency update clusters/inventories/trust-manager
node --test scripts/trust-manager-adoption.test.mjs || fail 'scripts/trust-manager-adoption.test.mjs'
echo 'test: cert-manager issuers — platform-acme as every cluster holds it, or the cluster authority, nothing else.'
node --test scripts/cert-manager-issuers.test.mjs || fail 'scripts/cert-manager-issuers.test.mjs'
node --test scripts/inventory-project-fit.test.mjs || fail 'scripts/inventory-project-fit.test.mjs'
echo 'test: OK — all suites green'
