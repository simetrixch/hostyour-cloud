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
  assert.ok(!builder.some(d => d.kind === 'PipelineRun' || (d.kind === 'CronJob' && d.metadata.name !== 'release-queue') ||
    d.metadata.name.includes('test-reporter') || d.metadata.name.includes('test-pruner') ||
    (d.kind === 'Task' && d.metadata.name.startsWith('test-')) || d.metadata.name.endsWith('-test-push')));
  assert.deepEqual(builder.find(d => d.kind === 'EventListener').spec.triggers,
    [{triggerRef: 'github-deploy-request'}, {triggerRef: 'github-ci-push'}]);
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

// The ci pipeline runs a repository's own check on every branch push. What keeps it from being a
// release, from holding a credential it must not, and from running anywhere else is asserted here
// on the rendered charts; the admission policy and the trigger filters are evaluated by
// scripts/vap-eval, which runs the CEL library the build plane runs.
const evaluate = (policy, requests) => execFileSync('go', ['run', '.'], {cwd: 'scripts/vap-eval', encoding: 'utf8',
  input: JSON.stringify({policy, requests})}).split('\n').filter(Boolean).map((line) => JSON.parse(line));
const renderUnit = (name, builds = ['app']) => renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name,
  repoURL: `https://github.com/check/${name}.git`, buildsJson: JSON.stringify(builds)})]);
const imageBuilder = () => renderChart('image-builder');
const guardOf = (docs) => docs.find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');

const OWNERSHIP = 'a build namespace runs only its own release and ci Pipelines; deleting retired tests permit unchanged controller cleanup.';
const EVENT_LISTENER = 'system:serviceaccount:image-builder:eventlistener-sa';
const createsRun = (namespace, pipeline) => ({object: {metadata: {namespace, labels: {'image-builder.io/ci': 'shop'}},
  spec: {pipelineRef: {name: pipeline}, taskRunTemplate: {serviceAccountName: 'pipeline-sa'},
    workspaces: [{name: 'source', volumeClaimTemplate: {spec: {accessModes: ['ReadWriteOnce']}}}]}},
  oldObject: null, request: {operation: 'CREATE', namespace, userInfo: {username: EVENT_LISTENER}}});

test('the admission policy admits the release and the ci pipeline of a unit in its own build namespace, and nothing else', () => {
  const policy = guardOf(imageBuilder());
  const ADMITTED = ['shop-release', 'shop-ci'];
  const DENIED = ['post-ci', 'post-release', 'shop-ci-extra', 'shop-tests', 'shop', 'ci', 'release'];
  const verdicts = evaluate(policy, [...ADMITTED, ...DENIED].map((name) => createsRun('shop-build', name))).map((v) => v.denied);
  ADMITTED.forEach((name, i) => assert.deepEqual(verdicts[i], [], `PLANTED INNOCENT: ${name} in shop-build`));
  DENIED.forEach((name, i) => assert.deepEqual(verdicts[ADMITTED.length + i], [OWNERSHIP], `PLANTED DEFECT: ${name} in shop-build`));
  // The refusal is the ownership clause's: without it the foreign ci pipeline is admitted.
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => v.message !== OWNERSHIP);
  assert.deepEqual(evaluate(without, [createsRun('shop-build', 'post-ci')])[0].denied, []);
  // The Tekton controller keeps updating a ci run it started.
  const run = createsRun('shop-build', 'shop-ci');
  const update = {...run, oldObject: run.object, request: {operation: 'UPDATE', namespace: 'shop-build',
    userInfo: {username: 'system:serviceaccount:tekton:tekton-controller'}}};
  assert.deepEqual(evaluate(policy, [update])[0].denied, []);
});

test('the run the ci trigger creates is admitted, is no release, and the trigger takes a branch push only', () => {
  const builder = imageBuilder();
  const byKind = (kind, name) => builder.find((d) => d.kind === kind && d.metadata.name === name);
  const template = byKind('TriggerTemplate', 'ci-push').spec.resourcetemplates[0];
  assert.equal(template.metadata.generateName, '$(tt.params.unit)-ci-');
  assert.equal(template.spec.pipelineRef.name, '$(tt.params.unit)-ci');
  assert.equal(template.spec.status, undefined, 'a ci run is created running, not waiting for the release queue');
  assert.deepEqual(Object.keys(template.metadata.labels), ['image-builder.io/ci']);
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].metadata.labels['image-builder.io/consumer'], '$(tt.params.unit)');
  // What the template creates, as the guard sees it once the trigger's parameters are in.
  const created = JSON.parse(JSON.stringify(template).replaceAll('$(tt.params.unit)', 'shop').replace(/\$\(tt\.params\.[a-z-]+\)/g, 'x'));
  const verdict = evaluate(guardOf(builder), [{object: created, oldObject: null,
    request: {operation: 'CREATE', namespace: 'shop-build', userInfo: {username: EVENT_LISTENER}}}])[0];
  assert.deepEqual(verdict.denied, []);

  const trigger = (name) => {
    const cel = byKind('Trigger', name).spec.interceptors.find((i) => i.ref.name === 'cel').params;
    return {overlays: cel.find((p) => p.name === 'overlays').value, filter: cel.find((p) => p.name === 'filter').value};
  };
  const matches = (name, bodies, edit = (filter) => filter) => {
    const {overlays, filter} = trigger(name);
    const policy = {spec: {variables: overlays.map((o) => ({name: o.key, expression: o.expression})),
      validations: [{expression: edit(filter), message: 'ignored'}]}};
    return evaluate(policy, bodies.map((body) => ({body}))).map((v) => ({matched: v.denied.length === 0, overlays: v.variables}));
  };
  const repository = {name: 'Digita-Platform', clone_url: 'https://github.com/digitaplatform/digita-platform.git'};
  const SHA = 'a'.repeat(40);
  const tag = '0.8.446-stable-20261009014252';
  const pushes = {
    'a branch push': {ref: 'refs/heads/feature/x', after: SHA, deleted: false, repository},
    'a branch push without the deleted field': {ref: 'refs/heads/main', after: SHA, repository},
    'a deploy tag push': {ref: `refs/tags/deploy/prod/${tag}`, after: SHA, deleted: false, repository},
    'a push of a delivery branch': {ref: 'refs/heads/deploy/prod', after: SHA, deleted: false, repository},
    'a branch named like a deploy tag': {ref: `refs/heads/deploy/prod/${tag}`, after: SHA, deleted: false, repository},
    'another tag push': {ref: 'refs/tags/v1.0.0', after: SHA, deleted: false, repository},
    'a branch deletion': {ref: 'refs/heads/feature/x', after: '0'.repeat(40), deleted: true, repository},
    'a branch deletion without the deleted field': {ref: 'refs/heads/feature/x', after: '0'.repeat(40), repository},
    'a deploy tag deletion': {ref: `refs/tags/deploy/prod/${tag}`, after: '0'.repeat(40), deleted: true, repository},
  };
  const bodies = Object.values(pushes);
  const ci = matches('github-ci-push', bodies), deploy = matches('github-deploy-request', bodies);
  const verdicts = {ci: [true, true, false, false, false, false, false, false, false],
    deploy: [false, false, true, false, false, false, false, false, false]};
  Object.keys(pushes).forEach((name, i) => {
    assert.equal(ci[i].matched, verdicts.ci[i], `${name} on the ci trigger`);
    assert.equal(deploy[i].matched, verdicts.deploy[i], `${name} on the deploy trigger`);
  });
  assert.deepEqual(ci[0].overlays, {unit: 'digita-platform', branch: 'feature/x', commit: SHA, 'git-url': repository.clone_url});
  // PLANTED DEFECT: a filter without the deletion guards, and one that takes every ref, each match a push they must not.
  const unguarded = (filter) => filter.replace(/ &&\s+!\(has\(body\.deleted\).*$/s, '');
  assert.ok(matches('github-ci-push', [pushes['a branch deletion']], unguarded)[0].matched);
  const everyRef = (filter) => filter.replace("body.ref.startsWith('refs/heads/')", "body.ref.startsWith('refs/')");
  assert.ok(matches('github-ci-push', [pushes['another tag push']], everyRef)[0].matched);
});

test('the ci pipeline of a unit holds no GitOps credential, mounts only the packages reader, and is no release', () => {
  const docs = renderUnit('shop');
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  assert.deepEqual(pipeline.spec.tasks.map((t) => t.name), ['gate', 'clone', 'fetch-branches', 'check']);
  assert.equal(pipeline.spec.finally, undefined);
  const referencesBump = (doc) => JSON.stringify(doc).includes('bump');
  assert.ok(!referencesBump(pipeline), 'the ci pipeline names no bump task, volume or secret');
  const planted = structuredClone(pipeline);
  planted.spec.tasks[3].taskSpec.volumes.push({name: 'bump', secret: {secretName: 'bump-git-https'}});
  assert.ok(referencesBump(planted), 'PLANTED DEFECT: a render that adds the bump volume is caught');
  const secrets = (doc) => [...JSON.stringify(doc).matchAll(/"(?:secretName|name)":"((?:build|bump)-[a-z-]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual([...new Set(secrets(pipeline))], ['build-git-https', 'build-npmrc']);
  const check = pipeline.spec.tasks.find((t) => t.name === 'check').taskSpec;
  assert.equal(check.steps[0].envFrom, undefined, 'the check step holds no secret as environment');
  assert.deepEqual(check.volumes.filter((v) => v.secret).map((v) => v.secret.secretName), ['build-npmrc']);
  assert.deepEqual(check.steps[0].volumeMounts.filter((m) => m.name === 'npmrc').map((m) => m.readOnly), [true]);
  assert.deepEqual(pipeline.spec.tasks.filter((t) => JSON.stringify(t).includes('build-git-https')).map((t) => t.name), ['clone', 'fetch-branches']);
  // Tekton copies a Pipeline's labels onto its runs: a consumer label here would make every ci run a release.
  assert.equal(pipeline.metadata.labels['image-builder.io/ci'], 'shop');
  assert.equal(pipeline.metadata.labels['image-builder.io/consumer'], undefined);
  assert.ok(docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release').metadata.labels['image-builder.io/consumer']);
  assert.ok(!renderUnit('shop', []).some((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci'), 'a unit without builds has no clone credential and no ci pipeline');
  const grant = docs.find((d) => d.kind === 'Role' && d.metadata.name === 'eventlistener-create-pipelineruns');
  assert.ok(grant.rules.some((r) => r.resources.includes('pipelineruns') && r.verbs.includes('create')), 'the event listener may create the ci run');
});

test('the egress policy of a build namespace selects every pod of it', () => {
  const policy = (docs) => docs.find((d) => d.kind === 'NetworkPolicy' && d.metadata.name === 'build-egress');
  const exempts = (doc) => Object.keys(doc.spec.podSelector ?? {}).length > 0;
  assert.ok(!exempts(policy(renderUnit('shop'))), 'build-egress selects the whole namespace');
  const planted = structuredClone(policy(renderUnit('shop')));
  planted.spec.podSelector = {matchExpressions: [{key: 'tekton.dev/pipelineTask', operator: 'NotIn', values: ['tests']}]};
  assert.ok(exempts(planted), 'PLANTED DEFECT: a selector that exempts a task is caught');
});
