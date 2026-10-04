import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {immutableChanges, probeImmutableChanges} from './check-immutable.mjs';

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

test('withdrawn Tekton test resources cannot activate and production readers remain', () => {
  const builder = renderChart('image-builder', ['--set', 'digitaTests.events.enabled=true',
    '--set', 'digitaTests.retention.enabled=true']);
  assert.ok(!builder.some(d => ['PipelineRun', 'CronJob'].includes(d.kind) ||
    d.metadata.name.includes('test-reporter') || d.metadata.name.includes('test-pruner') ||
    (d.kind === 'Task' && d.metadata.name.startsWith('test-')) || d.metadata.name.endsWith('-test-push')));
  assert.deepEqual(builder.find(d => d.kind === 'EventListener').spec.triggers,
    [{triggerRef: 'github-deploy-request'}]);
  const guard = builder.find(d => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');
  assert.ok(guard.spec.variables.find(v => v.name === 'retiredCleanup').expression.includes('object.spec == oldObject.spec'));
  assert.ok(!JSON.stringify(guard).includes('op3-input'));
  const fanout = renderChart('consumer-build').find(d => d.kind === 'ApplicationSet');
  assert.equal(fanout.spec.generators.length, 1);
  assert.deepEqual(fanout.spec.generators[0].git.files, [{path: 'registrations/*/build.yaml'}]);
  assert.equal(fanout.spec.generators[0].selector.matchLabels.suspended, 'false');
  const records = [{name: 'private-app', repositoryURL: 'https://github.com/check/private-app.git'},
    {name: 'public-lib', repositoryURL: 'https://github.com/check/public-lib.git'}];
  for (const record of records) {
    for (const builds of [[], ['check']]) {
      const docs = renderChart('consumer-build', ['--set', 'digitaTests.releaseGate.enabled=true',
        '--set', 'digitaTests.retention.enabled=true', '--set', 'digitaTests.proof.enabled=true',
        '--set-json', 'unit=' + JSON.stringify({name: record.name, repoURL: record.repositoryURL,
          buildsJson: JSON.stringify(builds)})]);
      assert.ok(!docs.some(d => d.kind === 'PipelineRun' || (d.kind === 'Pipeline' && d.metadata.name.endsWith('-tests'))));
      assert.ok(!docs.find(d => d.kind === 'ServiceAccount' && d.metadata.name === 'pipeline-sa').imagePullSecrets);
      const readers = docs.filter(d => d.kind === 'ExternalSecret');
      if (builds.length === 0) assert.equal(readers.length, 0, record.name + ' rendered a test-only reader');
      else {
        const pull = readers.find(d => d.metadata.name === 'image-builder-registry-pull-opaque');
        assert.equal(pull.spec.target.name, pull.metadata.name);
        assert.equal(pull.spec.target.template.type, 'Opaque');
        assert.equal(pull.spec.data.length, 2);
        assert.ok(pull.spec.data.every(value => value.remoteRef.property.startsWith('pull-')));
        assert.ok(readers.some(d => d.metadata.name === 'build-git-https'));
        assert.ok(readers.some(d => d.metadata.name === 'build-npmrc'));
        const pipeline = docs.find(d => d.kind === 'Pipeline' && d.metadata.name.endsWith('-release'));
        assert.ok(!pipeline.spec.tasks.some(t => t.name === 'test-report'));
        assert.ok(JSON.stringify(pipeline).includes('image-builder-registry-pull-opaque'));
      }
    }
  }
  const build = builder.find(d => d.kind === 'Task' && d.metadata.name === 'buildah-build-push');
  assert.equal(build.spec.steps.find(step => step.name === 'build').envFrom[0].secretRef.name,
    'image-builder-registry-pull-opaque');
});

test('immutable render guard catches the planted registry transition inside a green run', () => {
  probeImmutableChanges();
  const before = {apiVersion: 'external-secrets.io/v1', kind: 'ExternalSecret', metadata: {name: 'image-builder-registry-pull'},
    spec: {target: {name: 'image-builder-registry-pull', creationPolicy: 'Owner'}}};
  const planted = structuredClone(before);
  planted.spec.target.template = {type: 'kubernetes.io/dockerconfigjson'};
  assert.deepEqual(immutableChanges([before], [planted]), ['/Secret/default/image-builder-registry-pull: type changed']);
  const repaired = structuredClone(planted);
  repaired.metadata.name = repaired.spec.target.name = 'image-builder-registry-pull-opaque';
  repaired.spec.target.template.type = 'Opaque';
  assert.deepEqual(immutableChanges([planted], [repaired]), []);
  for (const kind of ['Deployment', 'DaemonSet', 'StatefulSet']) {
    const object = {apiVersion: 'apps/v1', kind, metadata: {name: 'app'}, spec: {selector: {matchLabels: {app: 'old'}}}};
    assert.equal(immutableChanges([object], [{...object, spec: {selector: {matchLabels: {app: 'new'}}}}]).length, 1);
  }
});

test('admission guard selects typed Tekton fields and keeps native inline refusal', () => {
  const tekton = renderChart('tekton');
  const crd = tekton.find(d => d.kind === 'CustomResourceDefinition' && d.metadata.name === 'pipelineruns.tekton.dev');
  const properties = crd.spec.versions.find(v => v.name === 'v1').schema.openAPIV3Schema.properties.spec.properties;
  // Use the shipped schema, not a hand-maintained list of CEL-visible fields.
  const guard = renderChart('image-builder').find(d => d.kind === 'ValidatingAdmissionPolicy' &&
    d.metadata.name === 'image-builder-pipelinerun-guard');
  const untypedFields = policy => [...new Set([...JSON.stringify(policy.spec).matchAll(/object\.spec\.([A-Za-z0-9_]+)/g)]
    .map(match => match[1]))].filter(field => !properties[field]?.type).sort();
  assert.deepEqual(untypedFields(guard), []);
  const planted = structuredClone(guard);
  planted.spec.validations.push({expression: '!has(object.spec.pipelineSpec)'});
  assert.deepEqual(untypedFields(planted), ['pipelineSpec']);
  // Inline-only is denied by the typed reference requirement; an inline spec
  // with a reference is rejected by Tekton's native exactly-one validation.
  assert.equal(guard.spec.failurePolicy, 'Fail');
  assert.ok(guard.spec.validations.some(v => v.expression ===
    'has(object.spec.pipelineRef) && has(object.spec.pipelineRef.name) && size(object.spec.pipelineRef.name) > 0'));
  const webhook = tekton.find(d => d.kind === 'ValidatingWebhookConfiguration' &&
    d.metadata.name === 'validation.webhook.pipeline.tekton.dev');
  assert.equal(webhook.metadata.labels['pipeline.tekton.dev/release'], 'v1.12.0');
  assert.ok(webhook.webhooks.every(h => h.failurePolicy === 'Fail'));
});
