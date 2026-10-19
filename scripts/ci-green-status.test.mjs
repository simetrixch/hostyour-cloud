import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// earlier_green_run asks GitHub for the combined status of a commit and names the run that set a green tekton/ci on it. The ci
// pipeline skips the clone and the check of a commit that has one. Everything but a green tekton/ci, a failed read included,
// must leave the check to run, so a run never skips its check on an answer it did not get. It is run here against a stand-in
// curl, so nothing leaves the machine; where the pipeline runs it is asserted in scripts/build-contract.test.mjs.

const SCRIPT = 'clusters/inventories/consumer-build/files/ci-green-status.sh';
const TOKEN = 'token-that-travels-only-in-a-header-file';
const COMMIT = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const URL_OF = (run) => `https://tekton.example.test/#/namespaces/shop-build/pipelineruns/${run}`;

// The stand-in logs its arguments, copies the header file it is given, writes $ANSWER to -o and prints $CODE.
const STAND_IN_CURL = `#!/usr/bin/env bash
echo "$*" >> "$CALLS"
out=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -H) case "$2" in @*) cp "\${2#@}" "$SEEN/auth";; esac; shift 2;;
    *) shift;;
  esac
done
printf '%s' "$ANSWER" > "$out"
printf '%s' "$CODE"
`;

const earlierGreenRun = ({code = '200', answer = '{"statuses":[]}'} = {}) => {
  const dir = mkdtempSync(join(tmpdir(), 'ci-green-status-'));
  try {
    const bin = join(dir, 'bin'), seen = join(dir, 'seen'), calls = join(dir, 'calls');
    mkdirSync(bin);
    mkdirSync(seen);
    writeFileSync(join(bin, 'curl'), STAND_IN_CURL);
    chmodSync(join(bin, 'curl'), 0o755);
    const result = spawnSync('bash', ['-c', `set -euo pipefail\n${readFileSync(SCRIPT, 'utf8')}\nif run="$(earlier_green_run)"; then echo "green:\${run}"; else echo "not green"; fi`],
      {encoding: 'utf8', env: {PATH: `${bin}:${process.env.PATH}`, CALLS: calls, SEEN: seen, CODE: code, ANSWER: answer,
        GITHUB_TOKEN: TOKEN, REPOSITORY_PATH: 'digitaplatform/shop', COMMIT}});
    const read = (path) => (existsSync(path) ? readFileSync(path, 'utf8') : undefined);
    return {...result, calls: (read(calls) ?? '').split('\n').filter(Boolean), auth: read(join(seen, 'auth'))};
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
};
const status = (...statuses) => JSON.stringify({state: 'success', statuses: statuses.map(([context, state, run]) => ({context, state, target_url: URL_OF(run)}))});

test('a commit with a green tekton/ci names the run that set it, and the token travels only in a header file', () => {
  const result = earlierGreenRun({answer: status(['tekton/ci', 'success', 'shop-ci-first'])});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'green:shop-ci-first\n', 'PLANTED DEFECT: a green status on the commit is found, and the run is the last segment of its link');
  assert.equal(result.calls.length, 1);
  assert.match(result.calls[0], new RegExp(`https://api\\.github\\.com/repos/digitaplatform/shop/commits/${COMMIT}/status\\?per_page=100$`));
  assert.equal(result.auth, `Authorization: Bearer ${TOKEN}\n`);
  for (const text of [result.calls[0], result.stdout, result.stderr]) assert.ok(!text.includes(TOKEN), 'the token is in no argument and no output');
  const many = earlierGreenRun({answer: status(['ci/other', 'failure', 'other-1'], ['tekton/ci', 'success', 'shop-ci-first'], ['lint', 'success', 'lint-1'])});
  assert.equal(many.stdout, 'green:shop-ci-first\n', 'the green status among several contexts');
});

test('no status, a red or pending tekton/ci, a green of another context and a link-less status leave the check to run', () => {
  const cases = {
    'no status at all': '{"state":"pending","statuses":[]}',
    'a failure': status(['tekton/ci', 'failure', 'shop-ci-red']),
    'an error': status(['tekton/ci', 'error', 'shop-ci-stopped']),
    'a pending': status(['tekton/ci', 'pending', 'shop-ci-open']),
    'a green of another context': status(['other/ci', 'success', 'other-1']),
    'a green of a similar context': status(['tekton/ci-extra', 'success', 'other-2']),
    'no statuses field': '{"state":"pending"}',
    'a green status with no link': JSON.stringify({statuses: [{context: 'tekton/ci', state: 'success'}]}),
  };
  for (const [name, answer] of Object.entries(cases)) {
    const result = earlierGreenRun({answer});
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'not green\n', `PLANTED INNOCENT: ${name}`);
  }
});

test('a read that fails is no green status, and says so on stderr without the token', () => {
  for (const code of ['500', '403', '404', '000']) {
    const result = earlierGreenRun({code, answer: status(['tekton/ci', 'success', 'shop-ci-first'])});
    assert.equal(result.stdout, 'not green\n', `PLANTED DEFECT: HTTP ${code} carrying a green body is no answer`);
    assert.match(result.stderr, new RegExp(`earlier-green: GitHub answered HTTP ${code} to the status of digitaplatform/shop@a1b2c3d`));
    assert.ok(!result.stderr.includes(TOKEN));
  }
  const notJson = earlierGreenRun({answer: '<html>bad gateway</html>'});
  assert.equal(notJson.stdout, 'not green\n', 'PLANTED DEFECT: an answer that is no JSON is no green status');
  assert.match(notJson.stderr, /earlier-green: the status of digitaplatform\/shop@a1b2c3d\S* is no JSON answer/);
});
