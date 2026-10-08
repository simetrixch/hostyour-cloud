import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';

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

test('each build namespace grants the queue patch on its PipelineRuns and nothing else', () => {
  const docs = renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name: 'shop', repoURL: 'https://github.com/check/shop.git', buildsJson: '[]'})]);
  const role = docs.find((d) => d.kind === 'Role' && d.metadata.name === 'release-queue-start-pipelineruns');
  assert.equal(role.metadata.namespace, 'shop-build');
  assert.deepEqual(role.rules, [{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['patch']}]);
  const binding = docs.find((d) => d.kind === 'RoleBinding' && d.metadata.name === 'release-queue-start-pipelineruns');
  assert.deepEqual(binding.subjects, [{kind: 'ServiceAccount', name: 'release-queue', namespace: 'image-builder'}]);
});
