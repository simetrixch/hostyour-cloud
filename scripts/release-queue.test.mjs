import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// The release queue starts one release at a time on the build plane. Its decision is the jq program
// in clusters/inventories/image-builder/files, run here on planted PipelineRuns; the charts are
// rendered for the pieces that make it work: runs created waiting, the CronJob, and its rights.

const QUEUE = 'clusters/inventories/image-builder/files/release-queue.jq';

let clock = 0;
const run = (ns, tag, {pending = false, succeeded, pipeline = ns.replace(/-build$/, '-release'), behind} = {}) => ({
  metadata: {namespace: ns, name: `${tag}-${++clock}`, creationTimestamp: `2026-10-08T05:${String(clock).padStart(2, '0')}:00Z`,
    ...(behind ? {annotations: {'image-builder.io/queued-behind': behind}} : {})},
  spec: {pipelineRef: {name: pipeline}, params: [{name: 'release-tag', value: tag}], ...(pending ? {status: 'PipelineRunPending'} : {})},
  status: succeeded === undefined ? {} : {conditions: [{type: 'Succeeded', status: succeeded}]},
});

const decide = (items) => execFileSync('jq', ['-c', '-f', QUEUE], {input: JSON.stringify({items}), encoding: 'utf8'})
  .split('\n').filter(Boolean).map((line) => JSON.parse(line));
const started = (changes) => changes.filter((c) => c.type === 'json').map((c) => c.name);
const waiting = (changes) => changes.filter((c) => c.type === 'merge')
  .map((c) => [c.name, c.patch.metadata.annotations['image-builder.io/queued-behind']]);

test('with nothing running, the oldest waiting release starts with all its stages and the next waits for it', () => {
  const a1 = run('shop-build', 'a', {pending: true}), a2 = run('shop-build', 'a', {pending: true}), b = run('post-build', 'b', {pending: true});
  const changes = decide([b, a2, a1]);
  assert.deepEqual(started(changes).sort(), [a1.metadata.name, a2.metadata.name].sort());
  assert.deepEqual(waiting(changes), [[b.metadata.name, 'shop-build/a']]);
  assert.deepEqual(changes.find((c) => c.name === a1.metadata.name).patch, [{op: 'remove', path: '/spec/status'}]);
});

test('planted defect: a release that runs holds every other release back', () => {
  const a = run('shop-build', 'a'), b = run('post-build', 'b', {pending: true});
  const changes = decide([a, b]);
  assert.deepEqual(started(changes), []);
  assert.deepEqual(waiting(changes), [[b.metadata.name, 'shop-build/a']]);
});

test('the second stage of the release that runs starts beside it', () => {
  const test_ = run('shop-build', 'a'), prod = run('shop-build', 'a', {pending: true});
  assert.deepEqual(started(decide([test_, prod])), [prod.metadata.name]);
});

test('planted innocent: finished runs, succeeded or failed, hold nothing back', () => {
  const b = run('post-build', 'b', {pending: true});
  const changes = decide([run('shop-build', 'a', {succeeded: 'True'}), run('auth-build', 'c', {succeeded: 'False'}), b]);
  assert.deepEqual(started(changes), [b.metadata.name]);
});

test('runs of other pipelines neither hold a release back nor are touched', () => {
  const b = run('post-build', 'b', {pending: true});
  const changes = decide([run('shop-build', 't', {pipeline: 'shop-tests'}), run('shop-build', 'u', {pipeline: 'shop-tests', pending: true}), b]);
  assert.deepEqual(changes.map((c) => c.name), [b.metadata.name]);
});

test('a running ci run neither holds a release back nor is touched, and the waiting release starts', () => {
  const b = run('post-build', 'b', {pending: true});
  const changes = decide([run('shop-build', 'c', {pipeline: 'shop-ci'}), run('post-build', 'd', {pipeline: 'post-ci'}), b]);
  assert.deepEqual(changes.map((c) => c.name), [b.metadata.name]);
  assert.deepEqual(started(changes), [b.metadata.name]);
});

test('a run that already notes what it waits for is not patched again, and its note goes when it starts', () => {
  const a = run('shop-build', 'a'), b = run('post-build', 'b', {pending: true, behind: 'shop-build/a'});
  assert.deepEqual(decide([a, b]), []);
  const later = decide([run('shop-build', 'a', {succeeded: 'True'}), b]);
  assert.deepEqual(later[0].patch, [{op: 'remove', path: '/spec/status'}, {op: 'remove', path: '/metadata/annotations/image-builder.io~1queued-behind'}]);
});

function renderChart(chart, extra = []) {
  const rendered = execFileSync('helm', ['template', chart, 'clusters/inventories/' + chart,
    '--namespace', chart === 'image-builder' ? 'image-builder' : 'argocd',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
    '-f', 'clusters/inventories/' + chart + '/values-common.yaml',
    ...(existsSync('clusters/inventories/' + chart + '/values-prod.yaml') ?
      ['-f', 'clusters/inventories/' + chart + '/values-prod.yaml'] : []),
    '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/registration.yaml', ...extra],
    {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
  return JSON.parse(execFileSync('yq', ['eval-all', '-o=json', '-I=0', '[.]', '-'],
    {input: rendered, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024})).filter(Boolean);
}

test('release runs are created waiting, and the queue runs every minute with read-only cluster rights', () => {
  const docs = renderChart('image-builder');
  const template = docs.find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === 'deploy-request');
  assert.equal(template.spec.resourcetemplates[0].spec.status, 'PipelineRunPending');
  const cron = docs.find((d) => d.kind === 'CronJob' && d.metadata.name === 'release-queue');
  assert.equal(cron.spec.schedule, '* * * * *');
  assert.equal(cron.spec.jobTemplate.spec.template.spec.serviceAccountName, 'release-queue');
  const read = docs.find((d) => d.kind === 'ClusterRole' && d.metadata.name === 'image-builder-release-queue-read');
  assert.deepEqual(read.rules, [{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['get', 'list', 'watch']}]);
  const map = docs.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'release-queue');
  assert.ok(map.data['release-queue.jq'].includes('PipelineRunPending'));
  const guard = docs.find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');
  assert.ok(guard.spec.variables.find((v) => v.name === 'isReleaseQueue').expression.includes("'image-builder' + ':release-queue'"));
  assert.ok(guard.spec.validations.some((v) => v.expression.includes('variables.isReleaseQueue')));
});

test('each build namespace grants the queue patch and delete on its PipelineRuns and nothing else', () => {
  const docs = renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name: 'shop', repoURL: 'https://github.com/check/shop.git', buildsJson: '[]'})]);
  const role = docs.find((d) => d.kind === 'Role' && d.metadata.name === 'release-queue-start-and-prune-pipelineruns');
  assert.equal(role.metadata.namespace, 'shop-build');
  assert.deepEqual(role.rules, [{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['patch', 'delete']}]);
  const binding = docs.find((d) => d.kind === 'RoleBinding' && d.metadata.name === 'release-queue-start-and-prune-pipelineruns');
  assert.deepEqual(binding.subjects, [{kind: 'ServiceAccount', name: 'release-queue', namespace: 'image-builder'}]);
});

const deleted = (changes) => changes.filter((c) => c.verb === 'delete').map((c) => c.name);
const finished = (ns, count, pipeline) => Array.from({length: count}, (_, i) => run(ns, `done${i}`, {succeeded: i % 2 ? 'True' : 'False', pipeline}));

test('a namespace keeps its newest 20 finished release runs, and a waiting or running release is never deleted', () => {
  const old = finished('shop-build', 21);
  const waitingRun = run('shop-build', 'next', {pending: true}), runningRun = run('post-build', 'now');
  const changes = decide([...old, waitingRun, runningRun, ...finished('post-build', 20)]);
  assert.deepEqual(deleted(changes), [old[0].metadata.name], 'only the oldest of 21 finished runs goes; 20 in post-build stay');
  assert.equal(changes.at(-1).verb, 'delete', 'deletes come after every start and note');
  assert.deepEqual(waiting(changes), [[waitingRun.metadata.name, 'post-build/now']], 'the waiting run stays, behind the running release');
});

test('planted defect: a queue that deletes by age alone, finished or not, is caught', () => {
  const dir = mkdtempSync(join(tmpdir(), 'release-queue-'));
  try {
    const byAge = join(dir, 'release-queue.jq');
    writeFileSync(byAge, readFileSync(QUEUE, 'utf8').replace('| ([.items[] | select(isRelease) | select(isDone)]', '| ([.items[] | select(isRelease)]'));
    const waitingRun = run('shop-build', 'next', {pending: true});
    const items = [...finished('shop-build', 20), waitingRun];
    const changes = execFileSync('jq', ['-c', '-f', byAge], {input: JSON.stringify({items}), encoding: 'utf8'}).split('\n').filter(Boolean).map((l) => JSON.parse(l));
    assert.notDeepEqual(deleted(changes), deleted(decide(items)), 'the planted queue deletes what the real one keeps');
    assert.deepEqual(deleted(decide(items)), [], 'PLANTED INNOCENT: 20 finished runs and a waiting one: nothing is deleted');
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
});

test('ci runs are not the queue\'s to delete, and a namespace\'s ci runs do not count against its releases', () => {
  const changes = decide([...finished('shop-build', 30, 'shop-ci'), ...finished('shop-build', 20)]);
  assert.deepEqual(deleted(changes), []);
});

test('starts come before notes, so a note that cannot be written never holds a start back', () => {
  const a = run('shop-build', 'a'), b = run('post-build', 'b', {pending: true}), a2 = run('shop-build', 'a', {pending: true});
  assert.deepEqual(decide([a, b, a2]).map((c) => c.type), ['json', 'merge']);
});

test('planted defect: a patch that fails is reported, the next one still runs, and the tick fails', () => {
  const bin = mkdtempSync(join(tmpdir(), 'release-queue-'));
  try {
    const runs = join(bin, 'runs.json'), log = join(bin, 'log');
    writeFileSync(runs, JSON.stringify({items: [run('shop-build', 'a', {pending: true}), run('post-build', 'b', {pending: true})]}));
    // The first patch is refused, as a unit whose grant has not synced yet would be.
    writeFileSync(join(bin, 'kubectl'), '#!/usr/bin/env bash\nif [ "$1" = get ]; then cat "$RUNS"; exit 0; fi\n'
      + 'echo "$*" >> "$LOG"\n[ "$(wc -l < "$LOG")" -gt 1 ]\n');
    chmodSync(join(bin, 'kubectl'), 0o755);
    const result = spawnSync('bash', ['clusters/inventories/image-builder/files/release-queue.sh'], {encoding: 'utf8',
      env: {...process.env, PATH: bin + ':' + process.env.PATH, RUNS: runs, LOG: log, QUEUE_DIR: 'clusters/inventories/image-builder/files'}});
    assert.equal(result.status, 1);
    assert.match(result.stderr, /could not patch shop-build\//);
    assert.equal(readFileSync(log, 'utf8').trim().split('\n').length, 2);
    assert.match(result.stdout, /post-build\/.* waits for release shop-build\/a/);
  } finally {
    rmSync(bin, {recursive: true, force: true});
  }
});

test('the tick deletes the run the decision names, in its namespace, without waiting for its pods', () => {
  const bin = mkdtempSync(join(tmpdir(), 'release-queue-'));
  try {
    const runs = join(bin, 'runs.json'), log = join(bin, 'log'), old = finished('shop-build', 21);
    writeFileSync(runs, JSON.stringify({items: old}));
    writeFileSync(join(bin, 'kubectl'), '#!/usr/bin/env bash\nif [ "$1" = get ]; then cat "$RUNS"; exit 0; fi\necho "$*" >> "$LOG"\n');
    chmodSync(join(bin, 'kubectl'), 0o755);
    const result = spawnSync('bash', ['clusters/inventories/image-builder/files/release-queue.sh'], {encoding: 'utf8',
      env: {...process.env, PATH: bin + ':' + process.env.PATH, RUNS: runs, LOG: log, QUEUE_DIR: 'clusters/inventories/image-builder/files'}});
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(log, 'utf8').trim(), `delete pipelinerun -n shop-build ${old[0].metadata.name} --ignore-not-found --wait=false`);
    assert.match(result.stdout, new RegExp(`deleted shop-build/${old[0].metadata.name}`));
  } finally {
    rmSync(bin, {recursive: true, force: true});
  }
});

// The admission policy's clause for the queue, evaluated on planted requests by scripts/vap-eval,
// which runs the CEL library the build plane's API server runs.
const guard = () => renderChart('image-builder').find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');
const evaluate = (policy, requests) => execFileSync('go', ['run', '.'], {cwd: 'scripts/vap-eval', encoding: 'utf8',
  input: JSON.stringify({policy, requests})}).split('\n').filter(Boolean).map((line) => JSON.parse(line).denied);

const QUEUE_SA = 'system:serviceaccount:image-builder:release-queue';
const waitingRun = () => ({
  metadata: {name: 'shop-release-x', namespace: 'shop-build', labels: {'image-builder.io/consumer': 'shop'},
    annotations: {'chains.tekton.dev/signed': 'false'}, finalizers: ['chains.tekton.dev/pipelinerun']},
  spec: {status: 'PipelineRunPending', pipelineRef: {name: 'shop-release'},
    params: [{name: 'release-tag', value: '1.0.0-stable-1'}, {name: 'stage', value: 'prod'}],
    taskRunTemplate: {serviceAccountName: 'pipeline-sa', podTemplate: {priorityClassName: 'image-builder-release'}}, timeouts: {pipeline: '1h0m0s'},
    workspaces: [{name: 'source', volumeClaimTemplate: {spec: {accessModes: ['ReadWriteOnce']}}}]},
});
const changed = (edit) => { const run = waitingRun(); edit(run); return run; };
const asks = (operation, username, object, oldObject) => ({object, oldObject, request: {operation, namespace: 'shop-build', userInfo: {username}}});
const startedRun = changed((r) => delete r.spec.status);
const asCi = (r) => { r.spec.pipelineRef.name = 'shop-ci'; r.spec.taskRunTemplate.podTemplate.priorityClassName = 'image-builder-ci'; };
const waitingCiRun = changed(asCi);
const startedCiRun = changed((r) => { asCi(r); delete r.spec.status; });
const ADMITTED = {
  'the EventListener creates a waiting run': asks('CREATE', 'system:serviceaccount:image-builder:eventlistener-sa', waitingRun(), null),
  'the queue starts a waiting run': asks('UPDATE', QUEUE_SA, startedRun, waitingRun()),
  'the queue notes what a run waits for, beside other annotations': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.annotations['image-builder.io/queued-behind'] = 'post-build/b'; }), waitingRun()),
  'the queue starts a run and drops its note': asks('UPDATE', QUEUE_SA, startedRun, changed((r) => { r.metadata.annotations['image-builder.io/queued-behind'] = 'post-build/b'; })),
  'the Tekton controller updates a started run': asks('UPDATE', 'system:serviceaccount:tekton:tekton-controller', changed((r) => { delete r.spec.status; r.metadata.labels['tekton.dev/pipeline'] = 'shop-release'; }), startedRun),
};
const DENIED = {
  'the queue changes a param': asks('UPDATE', QUEUE_SA, changed((r) => { delete r.spec.status; r.spec.params[0].value = 'other'; }), waitingRun()),
  'the queue drops the timeouts while starting': asks('UPDATE', QUEUE_SA, changed((r) => { delete r.spec.status; delete r.spec.timeouts; }), waitingRun()),
  'the queue cancels a waiting run': asks('UPDATE', QUEUE_SA, changed((r) => { r.spec.status = 'Cancelled'; }), waitingRun()),
  'the queue puts a started run back to waiting': asks('UPDATE', QUEUE_SA, waitingRun(), startedRun),
  'the queue creates a run': asks('CREATE', QUEUE_SA, waitingRun(), null),
  'the queue starts a waiting ci run': asks('UPDATE', QUEUE_SA, startedCiRun, waitingCiRun),
  'the queue notes what a ci run waits for': asks('UPDATE', QUEUE_SA, changed((r) => { asCi(r); r.metadata.annotations['image-builder.io/queued-behind'] = 'post-build/b'; }), waitingCiRun),
  'the queue changes a label': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.labels['image-builder.io/consumer'] = 'post'; }), waitingRun()),
  'the queue adds another annotation': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.annotations['chains.tekton.dev/x'] = 'y'; }), waitingRun()),
  'the queue changes another annotation': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.annotations['chains.tekton.dev/signed'] = 'true'; }), waitingRun()),
  'the queue removes another annotation': asks('UPDATE', QUEUE_SA, changed((r) => { delete r.metadata.annotations; }), waitingRun()),
  'the queue changes the finalizers': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.finalizers = []; }), waitingRun()),
};
const QUEUE_MESSAGE = 'the release queue may only start a waiting release run or note what it waits for.';

test('the admission policy lets the queue start a waiting run or note what it waits for, and nothing else', () => {
  const policy = guard();
  const verdicts = evaluate(policy, [...Object.values(ADMITTED), ...Object.values(DENIED)]);
  Object.keys(ADMITTED).forEach((name, i) => assert.deepEqual(verdicts[i], [], name));
  Object.keys(DENIED).forEach((name, i) => assert.deepEqual(verdicts[Object.keys(ADMITTED).length + i], [QUEUE_MESSAGE], name));
});

test('planted defect: without the queue clause, every change the queue must not make is admitted', () => {
  const policy = guard();
  policy.spec.validations = policy.spec.validations.filter((v) => v.message !== QUEUE_MESSAGE);
  assert.ok(evaluate(policy, Object.values(DENIED)).every((denied) => denied.length === 0));
});
