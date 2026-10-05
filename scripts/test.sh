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
echo 'test: manager-generator-refresh — approved grant only.'
helm dependency build clusters/inventories/manager
node --test scripts/manager-generator-refresh.test.mjs || fail 'scripts/manager-generator-refresh.test.mjs'
echo 'test: installation domain planning and paired launchers.'
node --test scripts/installation-domain.test.mjs || fail 'scripts/installation-domain.test.mjs'
node --test scripts/tenant-stage-label.test.mjs || fail 'scripts/tenant-stage-label.test.mjs'
echo 'test: post stage callbacks — strict nonproduction allowlist.'
node --test scripts/post-stage-callbacks.test.mjs || fail 'scripts/post-stage-callbacks.test.mjs'
echo 'test: redis maxmemory — a ceiling of half the limit, under noeviction.'
helm dependency update clusters/inventories/redis
node --test scripts/redis-maxmemory.test.mjs || fail 'scripts/redis-maxmemory.test.mjs'
echo 'test: tenant size — every registration renders, with the word or without it.'
node --test scripts/tenant-size.test.mjs || fail 'scripts/tenant-size.test.mjs'
echo 'test: tenant own domain aliases — every member gets the list, or [] without one.'
node --test scripts/tenant-own-domain-aliases.test.mjs || fail 'scripts/tenant-own-domain-aliases.test.mjs'
echo 'test: unit alerts — the master evaluates the PostgreSQL alerts of every unit, the unit renders none.'
helm dependency update clusters/units/postgresql
node --test scripts/unit-alerts.test.mjs || fail 'scripts/unit-alerts.test.mjs'
echo 'test: unit mongodb exporter — every member of each mode scraped as the instance root.'
helm dependency update clusters/units/mongodb
node --test scripts/unit-mongodb-exporter.test.mjs || fail 'scripts/unit-mongodb-exporter.test.mjs'
echo 'test: consumer data sizes — each part at its own preset, each volume as onboarded, every preset within its row.'
node --test scripts/consumer-data-sizes.test.mjs || fail 'scripts/consumer-data-sizes.test.mjs'
echo 'test: OK — all suites green'
