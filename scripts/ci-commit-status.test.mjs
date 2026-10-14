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
// prints the HTTP code of its call: the Nth word of $CODES, the last word for every call after them (000 is
// what curl prints when GitHub gave no answer at all). The stand-in sleep only logs how long it was asked to wait.
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
codes=(\${CODES:-201})
n=$(wc -l < "$CALLS")
printf '%s' "\${codes[$((n > \${#codes[@]} ? \${#codes[@]} - 1 : n - 1))]}"
`;
const STAND_IN_SLEEP = `#!/usr/bin/env bash
echo "$1" >> "$SLEEPS"
`;

const execute = (env, {codes, answer} = {}) => {
  const dir = mkdtempSync(join(tmpdir(), 'ci-commit-status-'));
  try {
    const bin = join(dir, 'bin'), seen = join(dir, 'seen'), calls = join(dir, 'calls'), sleeps = join(dir, 'sleeps');
    mkdirSync(bin);
    mkdirSync(seen);
    for (const [name, text] of [['curl', STAND_IN_CURL], ['sleep', STAND_IN_SLEEP]]) {
      writeFileSync(join(bin, name), text);
      chmodSync(join(bin, name), 0o755);
    }
    const result = spawnSync('bash', [SCRIPT], {encoding: 'utf8', env: {PATH: `${bin}:${process.env.PATH}`, CALLS: calls, SEEN: seen, SLEEPS: sleeps,
      ...(codes ? {CODES: codes} : {}), ...(answer ? {ANSWER: answer} : {}),
      GITHUB_TOKEN: TOKEN, REPOSITORY_PATH: 'digitaplatform/shop', COMMIT, RUN_URL, ...env}});
    const read = (path) => (existsSync(path) ? readFileSync(path, 'utf8') : undefined);
    const body = read(join(seen, 'body.json'));
    return {...result, calls: (read(calls) ?? '').split('\n').filter(Boolean), sleeps: (read(sleeps) ?? '').split('\n').filter(Boolean),
      auth: read(join(seen, 'auth')),
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
  const result = execute({RUN_STATE: 'Succeeded'}, {codes: '403', answer: '{"message":"Resource not accessible by integration"}'});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /GitHub answered HTTP 403 to success for digitaplatform\/shop@a1b2c3d\S*: Resource not accessible by integration/);
  assert.ok(!result.stderr.includes(TOKEN));
  assert.equal(result.calls.length, 1, 'PLANTED DEFECT: a wrong token or permission is not retried');
});

// A blip of GitHub on the pending status must not skip a ci run: the status is only a signal, the check is the
// run. The retry is 3 tries with a short wait between them, the same count as the download retry of the Manager.
const warningsOf = (result) => result.stderr.split('\n').filter((line) => /commit-status: warning/.test(line));

test('a 5xx on the pending status that recovers on the next try sets pending, with one warning', () => {
  const result = execute({RUN_STATE: 'running'}, {codes: '500 201', answer: '{"message":"Server Error"}'});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.length, 2, 'PLANTED DEFECT: a 5xx is no retry');
  assert.equal(result.sleeps.length, 1, 'one wait between two tries');
  assert.equal(warningsOf(result).length, 1);
  assert.match(warningsOf(result)[0], /attempt 1 of 3: GitHub answered HTTP 500 to pending for digitaplatform\/shop@a1b2c3d\S*: Server Error/);
  assert.match(result.stdout, /tekton\/ci is pending on digitaplatform\/shop@a1b2c3d/);
  assert.ok(!result.stderr.includes(TOKEN));
});

test('no answer at all from GitHub is retried like a 5xx', () => {
  const result = execute({RUN_STATE: 'running'}, {codes: '000 000 201'});
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.calls.length, 3, 'PLANTED DEFECT: a connection failure is no retry');
  assert.equal(warningsOf(result).length, 2);
});

test('a 5xx on every try of the pending status lets the run go on to the check, with a warning that names the three tries', () => {
  const result = execute({RUN_STATE: 'running'}, {codes: '500', answer: '{"message":"Server Error"}'});
  assert.equal(result.status, 0, 'PLANTED DEFECT: one blip of GitHub skips the whole ci run: ' + result.stderr);
  assert.equal(result.calls.length, 3, 'three tries, no more');
  assert.equal(result.sleeps.length, 2, 'a wait between the tries, none after the last');
  assert.ok(result.sleeps.every((seconds) => Number(seconds) <= 5), 'the wait is short: the task has 2 minutes');
  assert.match(warningsOf(result).at(-1), /GitHub answered HTTP 500 to pending .*after 3 attempts.*the run goes on to the check/);
  assert.ok(!result.stderr.includes(TOKEN));
});

test('the outcome is retried the same way, but a result that GitHub never got fails the task', () => {
  const recovered = execute({RUN_STATE: 'Succeeded'}, {codes: '502 201'});
  assert.equal(recovered.status, 0, recovered.stderr);
  assert.equal(recovered.posted.state, 'success');
  const lost = execute({RUN_STATE: 'Succeeded'}, {codes: '503'});
  assert.equal(lost.status, 1, 'PLANTED DEFECT: a run whose result GitHub never got looks green');
  assert.equal(lost.calls.length, 3);
  assert.match(lost.stderr, /GitHub answered HTTP 503 to success .*after 3 attempts/);
});

test('a missing input fails the task before anything is posted', () => {
  for (const name of ['GITHUB_TOKEN', 'REPOSITORY_PATH', 'COMMIT', 'RUN_URL', 'RUN_STATE']) {
    const result = execute({RUN_STATE: 'running', [name]: ''});
    assert.notEqual(result.status, 0, name);
    assert.equal(result.calls.length, 0, name);
  }
});
