import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// A failed Manager run, a nightly backup that did not start, and a run that waits behind a failed run's
// lock reach Alertmanager through a rule of the master's Loki: the Manager writes them only to its
// process log ("run failed" at error, "nightly backup was not started today" and "a run waits behind a
// failed run's lock" at warn), and Alloy ships that log to Loki under namespace="manager".
// The single-binary Loki renders no `ruler.directories`, so the rules come as this chart's ConfigMap,
// mounted where the ruler's local storage reads the rules of its one tenant, "fake".

const VALUES = 'clusters/inventories/observability/values-common.yaml';
const yq = (expr) => JSON.parse(execFileSync('yq', ['-o=json', expr, VALUES], {encoding: 'utf8'}));
// The template alone, in a chart of its own: the observability chart's dependencies are fetched at
// deploy and are not in the tree, and this template reads none of them.
const rendered = () => {
  const chart = mkdtempSync(join(tmpdir(), 'loki-rules-'));
  try {
    mkdirSync(join(chart, 'templates'));
    writeFileSync(join(chart, 'Chart.yaml'), 'apiVersion: v2\nname: observability\nversion: 1.0.0\n');
    copyFileSync('clusters/inventories/observability/templates/loki-rules.yaml', join(chart, 'templates/loki-rules.yaml'));
    const out = execFileSync('helm', ['template', 'observability', chart, '--namespace', 'observability'], {encoding: 'utf8'});
    return JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(. != null)]', '-'], {encoding: 'utf8', input: out}));
  } finally {
    rmSync(chart, {recursive: true, force: true});
  }
};

const rulesOf = (docs) => {
  const map = docs.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'loki-rules');
  assert.ok(map, 'no ConfigMap loki-rules is rendered');
  return Object.values(map.data).flatMap((file) => JSON.parse(execFileSync('yq', ['-o=json', '.groups'], {encoding: 'utf8', input: file})).flatMap((g) => g.rules));
};

test('the ruler reads local rules and sends to the master\'s Alertmanager', () => {
  const ruler = yq('.loki.loki.rulerConfig');
  assert.equal(ruler.storage?.type, 'local');
  assert.equal(ruler.storage?.local?.directory, '/etc/loki/rules');
  assert.equal(ruler.alertmanager_url, 'http://observability-alertmanager.observability.svc.cluster.local:9093');
  const mount = (yq('.loki.singleBinary.extraVolumeMounts') ?? []).find((m) => m.mountPath === '/etc/loki/rules/fake');
  assert.ok(mount, 'the rules are not mounted where the ruler reads tenant "fake"');
  const volume = (yq('.loki.singleBinary.extraVolumes') ?? []).find((v) => v.name === mount.name);
  assert.equal(volume?.configMap?.name, 'loki-rules');
});

test('PLANTED DEFECT: each Manager line has its alert, on the manager namespace, never at severity info', () => {
  const rules = rulesOf(rendered());
  const expected = {
    ManagerRunFailed: '"msg":"run failed"',
    ManagerRunWaitsBehindFailedRun: '"msg":"a run waits behind a failed run\'s lock"',
    NightlyBackupNotStarted: 'nightly backup was not started today',
  };
  for (const [alert, line] of Object.entries(expected)) {
    const rule = rules.find((r) => r.alert === alert);
    assert.ok(rule, `no ${alert} rule`);
    assert.match(rule.expr, /\{namespace="manager"\}/, `${alert} reads another namespace`);
    assert.ok(rule.expr.includes(line.replaceAll('"', '\\"')) || rule.expr.includes(line), `${alert} does not match the Manager's line ${line}`);
    assert.notEqual(rule.labels?.severity, 'info', `${alert} is info, which platform-default does not route`);
  }
});

// What LogQL matches each log line against: the string of the rule's `|=` filter.
const lineFilterOf = (expr) => {
  const filter = expr.match(/\|= "((?:[^"\\]|\\.)*)"/);
  assert.ok(filter, `no line filter in ${expr}`);
  return JSON.parse(`"${filter[1]}"`);
};

test('PLANTED DEFECT: a run that waits behind a failed run is alerted by the holder, with what the log line carries', () => {
  const rules = rulesOf(rendered());
  const rule = rules.find((r) => r.alert === 'ManagerRunWaitsBehindFailedRun');
  assert.ok(rule, 'no ManagerRunWaitsBehindFailedRun rule');
  assert.equal(rule.labels?.severity, 'warning');
  assert.match(rule.expr, /^sum by \(holderRunId\) \(count_over_time\(.* \| json holderRunId="holderRunId" \[15m\]\)\) > 0$/);
  assert.match(rule.annotations?.summary, /\{\{ \$labels\.holderRunId \}\}/);
  for (const field of ['waitingRunId', 'holderRunId', 'holderFailedStep', 'holderError']) assert.match(rule.annotations?.description, new RegExp(field));
  assert.match(rule.annotations?.description, /retried, aborted or deleted/);

  // The line the Manager writes (hostyour-manager server/executor/queue-dispatch.ts), as pino prints it.
  const planted = JSON.stringify({
    level: 40, time: 1791543396858, waitingRunId: 'run_waiting', waitingKind: 'tenant-refresh-members', holderRunId: 'run_holder', holderKind: 'tenant-refresh-members',
    holderStatus: 'failed', holderFailedStep: 'Wait for the Applications to converge', holderError: 'three Applications are Degraded', resource: 'master-kube', key: 'master', msg: "a run waits behind a failed run's lock",
  });
  assert.ok(planted.includes(lineFilterOf(rule.expr)), 'the rule does not match the line the Manager writes');
  assert.ok(!planted.includes(lineFilterOf(rules.find((r) => r.alert === 'ManagerRunFailed').expr)), 'a waiting run would also read as a failed run');
});

test('PLANTED INNOCENT: the lines of a failed run and of a nightly backup are not a run waiting behind a failed run', () => {
  const filter = lineFilterOf(rulesOf(rendered()).find((r) => r.alert === 'ManagerRunWaitsBehindFailedRun').expr);
  const failedRun = JSON.stringify({level: 50, runId: 'run_holder', kind: 'tenant-refresh-members', runError: 'three Applications are Degraded', msg: 'run failed'});
  const backup = JSON.stringify({level: 40, kind: 'consumer', err: 'busy', msg: 'nightly backup was not started today'});
  assert.ok(!failedRun.includes(filter));
  assert.ok(!backup.includes(filter));
});
