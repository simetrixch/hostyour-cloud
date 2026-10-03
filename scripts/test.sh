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
echo 'test: OK — both suites green'
