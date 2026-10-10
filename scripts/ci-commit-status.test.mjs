import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// The ci pipeline sets the commit status tekton/ci with this script: pending after the gate, then the outcome
// in a finally task. It is run here against a stand-in curl that records each call, so nothing leaves the
// machine. When the pipeline runs it and with which values is asserted in scripts/build-contract.test.mjs.

const SCRIPT = 'clusters/inventories/consumer-build/files/ci-commit-status.sh';
const TOKEN = 'token-that-travels-only-in-a-header-file';
const COMMIT = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const RUN_URL = 'https://tekton.example.test/#/namespaces/shop-build/pipelineruns/shop-ci-abc12';

// The stand-in logs its arguments, copies the header file it is given and the body, writes $ANSWER to -o and
// prints $CODE as the HTTP code.
const STAND_IN_CURL = `#!/usr/bin/env bash
echo "$*" >> "$CALLS"
out=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -H) case "$2" in @*) cp "\${2#@}" "$SEEN/auth";; esac; shift 2;;
    --data-binary) cp "\${2#@}" "$SEEN/body.json"; shift 2;;
    *) shift;;
  esac
done
printf '%s' "\${ANSWER:-{}}" > "$out"
printf '%s' "\${CODE:-201}"
`;

const execute = (env, {code, answer} = {}) => {
  const dir = mkdtempSync(join(tmpdir(), 'ci-commit-status-'));
  try {
    const bin = join(dir, 'bin'), seen = join(dir, 'seen'), calls = join(dir, 'calls');
    mkdirSync(bin);
    mkdirSync(seen);
    writeFileSync(join(bin, 'curl'), STAND_IN_CURL);
    chmodSync(join(bin, 'curl'), 0o755);
    const result = spawnSync('bash', [SCRIPT], {encoding: 'utf8', env: {PATH: `${bin}:${process.env.PATH}`, CALLS: calls, SEEN: seen,
      ...(code ? {CODE: String(code)} : {}), ...(answer ? {ANSWER: answer} : {}),
      GITHUB_TOKEN: TOKEN, REPOSITORY_PATH: 'digitaplatform/shop', COMMIT, RUN_URL, ...env}});
    const read = (path) => (existsSync(path) ? readFileSync(path, 'utf8') : undefined);
    const body = read(join(seen, 'body.json'));
    return {...result, calls: (read(calls) ?? '').split('\n').filter(Boolean), auth: read(join(seen, 'auth')),
      status: result.status, posted: body === undefined ? undefined : JSON.parse(body)};
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
};
const stateOf = (env) => {
  const result = execute(env);
  assert.equal(result.status, 0, result.stderr);
  return result.posted.state;
};

test('the first task sets pending on the commit, linked to the run, and the token travels only in a header file', () => {
  const result = execute({RUN_STATE: 'running'});
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.posted, {state: 'pending', target_url: RUN_URL, description: 'The check runs.', context: 'tekton/ci'});
  assert.equal(result.calls.length, 1);
  assert.match(result.calls[0], new RegExp(`-X POST .* https://api\\.github\\.com/repos/digitaplatform/shop/statuses/${COMMIT}$`));
  assert.equal(result.auth, `Authorization: Bearer ${TOKEN}\n`);
  for (const text of [result.calls[0], result.stdout, result.stderr]) assert.ok(!text.includes(TOKEN), 'the token is in no argument and no output');
  assert.match(result.stdout, /tekton\/ci is pending on digitaplatform\/shop@a1b2c3d/);
});

test('a run whose tasks all passed sets success, and a run whose tasks were skipped sets error', () => {
  assert.equal(stateOf({RUN_STATE: 'Succeeded'}), 'success', 'PLANTED INNOCENT: a run that passed');
  // A cancel between two tasks skips the rest without a failed TaskRun; the check never ran.
  assert.equal(stateOf({RUN_STATE: 'Completed'}), 'error', 'PLANTED DEFECT: a run cancelled before its check is no passed check');
});

test('a task that ran and failed sets failure, and a run that was stopped before its check finished sets error', () => {
  assert.equal(stateOf({RUN_STATE: 'Failed', TASK_REASONS: 'Succeeded Succeeded Succeeded Succeeded Succeeded Failed'}), 'failure',
    'PLANTED INNOCENT: a failed check is a failure');
  assert.equal(stateOf({RUN_STATE: 'Failed', TASK_REASONS: 'Succeeded Succeeded Succeeded Succeeded Succeeded TaskRunCancelled'}), 'error',
    'PLANTED DEFECT: a run a newer push replaced is no failure');
  assert.equal(stateOf({RUN_STATE: 'Failed', TASK_REASONS: 'Succeeded Succeeded TaskRunTimeout'}), 'error',
    'PLANTED DEFECT: a task whose time ran out never finished its check');
  assert.equal(stateOf({RUN_STATE: 'None'}), 'error', 'a run cut short before all its tasks were done');
});

test('a state that is no state of a run posts nothing and fails the task', () => {
  const result = execute({RUN_STATE: '$(tasks.status)'});
  assert.equal(result.status, 1);
  assert.equal(result.posted, undefined);
  assert.match(result.stderr, /'\$\(tasks\.status\)' is no state of a run, so a1b2c3d\S* keeps its status/);
});

test('an answer other than 201 fails the task and names the code and the message, never the token', () => {
  const result = execute({RUN_STATE: 'Succeeded'}, {code: 403, answer: '{"message":"Resource not accessible by integration"}'});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /GitHub answered HTTP 403 to success for digitaplatform\/shop@a1b2c3d\S*: Resource not accessible by integration/);
  assert.ok(!result.stderr.includes(TOKEN));
});

test('a missing input fails the task before anything is posted', () => {
  for (const name of ['GITHUB_TOKEN', 'REPOSITORY_PATH', 'COMMIT', 'RUN_URL', 'RUN_STATE']) {
    const result = execute({RUN_STATE: 'running', [name]: ''});
    assert.notEqual(result.status, 0, name);
    assert.equal(result.calls.length, 0, name);
  }
});
