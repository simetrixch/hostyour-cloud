import test from 'node:test';
import assert from 'node:assert/strict';
import {COMMIT, NAMESPACE, RUN, SUCCESSFUL, TOKEN, execute, numbered, onlyBefore, withFailure} from './ci-report-harness.mjs';

// The report task of the ci pipeline reads what failed from the Kubernetes API and posts one alert to
// Alertmanager. Its script is run here against a stand-in curl (scripts/ci-report-harness.mjs). What the
// pipeline does with the script (when it runs, which token it holds, which pods reach the API server) is
// asserted in scripts/build-contract.test.mjs, and what Alertmanager does with the alert in
// scripts/ci-failure-mail.test.mjs.

const only = (alerts) => { assert.equal(alerts.length, 1, 'one request to Alertmanager'); assert.equal(alerts[0].length, 1, 'one alert in it'); return alerts[0][0]; };

test('a green run posts nothing', () => {
  const result = execute({taskRuns: SUCCESSFUL});
  assert.equal(result.status, 0);
  assert.deepEqual(result.alerts, [], 'PLANTED INNOCENT: nothing is posted for a run that did not fail');
  assert.match(result.stdout, /nothing to mail/);
  assert.ok(result.calls.every((call) => call.startsWith('GET ')));
});

test('a cancelled run posts nothing', () => {
  const cancelled = withFailure('check', {reason: 'TaskRunCancelled', message: 'TaskRun "x" was cancelled', steps: [{name: 'check', container: 'step-check'}]});
  const result = execute({taskRuns: cancelled});
  assert.equal(result.status, 0);
  assert.deepEqual(result.alerts, [], 'PLANTED INNOCENT: a run that a newer push replaced is no failure');
});

// The message Tekton writes to a TaskRun it cancels because the PipelineRun's time budget ran out, and the
// one for a PipelineRun that was cancelled (pkg/apis/pipeline/v1/taskrun_types.go in Tekton v1.12.0).
const CANCELLED_BY_TIMEOUT = 'TaskRun cancelled as the PipelineRun it belongs to has timed out.';
const CANCELLED_BY_PIPELINE = 'TaskRun cancelled as the PipelineRun it belongs to has been cancelled.';
const cancelled = (statusMessage) => withFailure('check', {reason: 'TaskRunCancelled', statusMessage, steps: [{name: 'check', container: 'step-check'}],
  message: `TaskRun "${RUN}-check" was cancelled. ${statusMessage ?? ''}`.trim()});

test('a task that Tekton cancelled because the run\'s time budget ran out is mailed, with the reason and a note', () => {
  const result = execute({taskRuns: cancelled(CANCELLED_BY_TIMEOUT)});
  assert.equal(result.status, 0, result.stderr);
  const alert = only(result.alerts);
  assert.equal(alert.labels.task, 'check', 'PLANTED DEFECT: a script that treats every TaskRunCancelled as no failure posts nothing here');
  assert.equal(alert.labels.step, 'check');
  assert.match(alert.annotations.failure, /^check, step check: TaskRunCancelled: .*has timed out\. The time budget of the run ran out, so Tekton cancelled this task\.$/);
  assert.match(alert.annotations.log, /^the pod of check is gone/, 'Tekton deletes the pod of a cancelled task, so the mail says so');
});

test('a task that a newer push cancelled, with or without a message, posts nothing', () => {
  for (const statusMessage of [CANCELLED_BY_PIPELINE, undefined]) {
    const result = execute({taskRuns: cancelled(statusMessage)});
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.alerts, [], `PLANTED INNOCENT: a cancel by a newer push (${statusMessage ?? 'no message'}) is no failure`);
  }
});

test('a red check posts one alert with its labels, its links and exactly the last 60 lines of the failed step', () => {
  const result = execute({taskRuns: withFailure('check'), logs: {[`${RUN}-check-pod`]: numbered(500)}});
  assert.equal(result.status, 0, result.stderr);
  const alert = only(result.alerts);
  assert.deepEqual(alert.labels, {alertname: 'CIRunFailed', repository: 'shop', branch: 'feature/vat', commit: 'a1b2c3d', task: 'check', step: 'check'});
  assert.equal(alert.annotations.log, Array.from({length: 60}, (_, i) => `line ${441 + i}`).join('\n'));
  assert.equal(alert.annotations.subject, 'Fix the rounding of VAT');
  assert.equal(alert.annotations.author, 'Ada <ada@example.com>');
  assert.equal(alert.annotations.run_url, `https://tekton.example.test/#/namespaces/${NAMESPACE}/pipelineruns/${RUN}`);
  const logsUrl = new URL(alert.annotations.logs_url);
  assert.equal(logsUrl.origin + logsUrl.pathname, 'https://grafana.example.test/explore');
  const pane = JSON.parse(logsUrl.searchParams.get('panes')).a;
  assert.equal(pane.queries[0].expr, `{namespace="${NAMESPACE}", pod=~"${RUN}-.+"}`);
  assert.equal(pane.range.from, String(Date.parse('2026-10-09T10:00:00Z')));
  assert.equal((Date.parse(alert.endsAt) - Date.parse(alert.startsAt)) / 1000, 600, 'the alert ends 10 minutes after it starts');
  assert.ok(Math.abs(Date.now() - Date.parse(alert.startsAt)) < 60000);
  assert.ok(result.calls.some((call) => call.includes(`/pods/${RUN}-check-pod/log?container=step-check&tailLines=60`)), 'the log of the step container, 60 lines');
  assert.match(result.stdout, /posted CIRunFailed for shop feature\/vat a1b2c3d, task check/);
});

test('the token goes to the API server only: no call to Alertmanager carries it, and it is in no alert', () => {
  const result = execute({taskRuns: withFailure('check'), logs: {[`${RUN}-check-pod`]: numbered(5)}});
  const gets = result.calls.filter((call) => call.startsWith('GET ')), posts = result.calls.filter((call) => call.startsWith('POST '));
  assert.ok(gets.length >= 4 && gets.every((call) => call.endsWith('auth=yes') && call.includes('https://api.test:443/')), 'PLANTED INNOCENT: every read carries the token');
  assert.deepEqual(posts, ['POST http://alertmanager.test:9093/api/v2/alerts auth='], 'PLANTED DEFECT: a post with the token would end in "auth=yes"');
  assert.ok(result.posted.every((body) => !body.includes(TOKEN)));
  assert.ok(!result.stdout.includes(TOKEN) && !result.stderr.includes(TOKEN));
});

test('a red gate mails its own 60 lines, for a task that came before the clone', () => {
  const result = execute({taskRuns: onlyBefore('gate', withFailure('gate')), logs: {[`${RUN}-gate-pod`]: numbered(90)}});
  assert.equal(result.status, 0, result.stderr);
  const alert = only(result.alerts);
  assert.equal(alert.labels.task, 'gate');
  assert.equal(alert.labels.step, 'gate');
  assert.equal(alert.annotations.log, Array.from({length: 60}, (_, i) => `line ${31 + i}`).join('\n'));
  assert.match(alert.annotations.subject, /^\(none: /, 'no commit was described, and the mail says so');
  assert.equal(alert.annotations.author, '(unknown)');
});

test('a red clone says that the commit was not cloned', () => {
  const result = execute({taskRuns: onlyBefore('clone', withFailure('clone')), logs: {[`${RUN}-clone-pod`]: 'fatal: could not read from remote\n'}});
  const alert = only(result.alerts);
  assert.equal(alert.labels.task, 'clone');
  assert.equal(alert.annotations.subject, '(none: the commit was not cloned)');
  assert.equal(alert.annotations.log, 'fatal: could not read from remote');
});

test('two failed tasks are one mail, each with its own lines', () => {
  const taskRuns = withFailure('fetch-branches', {}, withFailure('describe-commit', {steps: [{name: 'describe', container: 'step-describe', terminated: {exitCode: 128}}]}));
  delete taskRuns.check;
  const result = execute({taskRuns, logs: {[`${RUN}-describe-commit-pod`]: 'describe broke\n', [`${RUN}-fetch-branches-pod`]: 'fetch broke\n'}});
  const alert = only(result.alerts);
  assert.equal(alert.labels.task, 'describe-commit', 'the first failed task names the alert');
  assert.equal(alert.annotations.log, '== describe-commit, step describe ==\ndescribe broke\n\n== fetch-branches, step fetch-branches ==\nfetch broke');
});

test('a pod that is gone is said so, with no invented lines', () => {
  const timedOut = withFailure('check', {reason: 'TaskRunTimeout', message: '"x" failed to finish within "20m0s"', steps: [{name: 'check', container: 'step-check'}]});
  const result = execute({taskRuns: timedOut});
  assert.equal(result.status, 0, result.stderr);
  const alert = only(result.alerts);
  assert.match(alert.annotations.log, /^the pod of check is gone, so its output is behind the run link\./);
  assert.match(alert.annotations.log, /TaskRunTimeout: "x" failed to finish within "20m0s"$/);
  assert.equal(alert.annotations.log.split('\n').length, 1, 'PLANTED DEFECT: a log that is made up of lines would have more');
  assert.equal(alert.labels.step, 'check', 'a step that never ended is still the step to name');
});

test('any other API answer on the log is mailed with a note, and then fails the task', () => {
  const result = execute({taskRuns: withFailure('check'), codes: {[`/api/v1/namespaces/${NAMESPACE}/pods/${RUN}-check-pod/log`]: 500}});
  const alert = only(result.alerts);
  assert.match(alert.annotations.log, /the log of check could not be read: the API server answered HTTP 500/);
  assert.equal(result.status, 1, 'PLANTED DEFECT: a mail that lost its lines must not look complete');
  assert.match(result.stderr, /the mail is incomplete: GET the log of check answered HTTP 500/);
});

test('a run record that cannot be read is mailed with a note, and fails the task', () => {
  const result = execute({taskRuns: withFailure('check'), codes: {[`/apis/tekton.dev/v1/namespaces/${NAMESPACE}/pipelineruns/${RUN}`]: 403}});
  const alert = only(result.alerts);
  assert.equal(alert.labels.task, 'report-failure');
  assert.match(alert.annotations.log, /pipelineruns\/shop-ci-abc12 answered HTTP 403/);
  assert.equal(result.status, 1);
});

test('a post that Alertmanager does not accept fails the task with its status', () => {
  const result = execute({taskRuns: withFailure('check'), logs: {[`${RUN}-check-pod`]: numbered(5)}, postCode: '503'});
  assert.equal(result.status, 1, 'PLANTED DEFECT: a swallowed post would exit 0');
  assert.match(result.stderr, /Alertmanager answered HTTP 503 at http:\/\/alertmanager\.test:9093\/api\/v2\/alerts, so no mail left/);
  assert.ok(!result.stdout.includes('posted CIRunFailed'));
});

test('the log is cleaned of colors and carriage returns, and a line a mail cannot use is cut', () => {
  const dirty = `\u001b[31mred\u001b[0m text\r\n${'x'.repeat(1500)}\n`;
  const result = execute({taskRuns: withFailure('check'), logs: {[`${RUN}-check-pod`]: dirty}});
  const lines = only(result.alerts).annotations.log.split('\n');
  assert.deepEqual(lines, ['red text', 'x'.repeat(1000)]);
  const silent = execute({taskRuns: withFailure('check'), logs: {[`${RUN}-check-pod`]: ''}});
  assert.equal(only(silent.alerts).annotations.log, '(the step printed nothing)');
});

test('the report task itself is never read as a failed task', () => {
  const result = execute({taskRuns: withFailure('check'), logs: {[`${RUN}-check-pod`]: numbered(3)}});
  assert.ok(result.calls.every((call) => !call.includes('report-failure')));
});

test('a missing setting fails the task naming it', () => {
  for (const name of ['ALERTMANAGER_URL', 'PIPELINE_RUN', 'COMMIT']) {
    const result = execute({taskRuns: SUCCESSFUL, env: {[name]: ''}});
    assert.notEqual(result.status, 0, name);
    assert.match(result.stderr, new RegExp(name));
  }
});
