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
    {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe']});
  return JSON.parse(execFileSync('yq', ['eval-all', '-o=json', '-I=0', '[.]', '-'],
    {input: rendered, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024})).filter(Boolean);
}

test('no Tekton test resources are rendered and production readers remain', () => {
  const builder = renderChart('image-builder');
  assert.ok(!builder.some(d => d.kind === 'PipelineRun' || (d.kind === 'CronJob' && !['release-queue', 'ci-run-keeper'].includes(d.metadata.name)) ||
    d.metadata.name.includes('test-reporter') || d.metadata.name.includes('test-pruner') ||
    (d.kind === 'Task' && d.metadata.name.startsWith('test-')) || d.metadata.name.endsWith('-test-push')));
  assert.deepEqual(builder.find(d => d.kind === 'EventListener').spec.triggers,
    [{triggerRef: 'github-deploy-request'}, {triggerRef: 'github-ci-push'}]);
  const guard = builder.find(d => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');
  assert.ok(!JSON.stringify(guard).includes('op3-input'));
  const fanout = renderChart('consumer-build').find(d => d.kind === 'ApplicationSet');
  assert.equal(fanout.spec.generators.length, 1);
  assert.deepEqual(fanout.spec.generators[0].git.files, [{path: 'registrations/*/build.yaml'}]);
  assert.equal(fanout.spec.generators[0].selector.matchLabels.suspended, 'false');
  const records = [{name: 'private-app', repositoryURL: 'https://github.com/check/private-app.git'},
    {name: 'public-lib', repositoryURL: 'https://github.com/check/public-lib.git'}];
  for (const record of records) {
    for (const builds of [[], ['check']]) {
      const docs = renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name: record.name,
        repoURL: record.repositoryURL, buildsJson: JSON.stringify(builds)})]);
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

const OWNERSHIP = 'a build namespace runs only its own release and ci Pipelines.';
const EVENT_LISTENER = 'system:serviceaccount:image-builder:eventlistener-sa';
const RELEASE_CLASS = 'image-builder-release', CI_CLASS = 'image-builder-ci';
const classOf = (pipeline) => (pipeline.endsWith('-release') ? RELEASE_CLASS : CI_CLASS);
// podTemplate null leaves the template out.
const createsRun = (namespace, pipeline, podTemplate = {priorityClassName: classOf(pipeline)}) => ({object: {metadata: {namespace, labels: {'image-builder.io/ci': 'shop'}},
  spec: {pipelineRef: {name: pipeline}, taskRunTemplate: {serviceAccountName: 'pipeline-sa', ...(podTemplate ? {podTemplate} : {})},
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
  assert.equal(template.metadata.annotations['image-builder.io/ci-branch'], '$(tt.params.branch)', 'the keeper groups ci runs by branch');
  assert.equal(template.spec.taskRunTemplate.podTemplate.priorityClassName, CI_CLASS);
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].spec.taskRunTemplate.podTemplate.priorityClassName, RELEASE_CLASS);
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
  const repository = {name: 'Shop', clone_url: 'https://github.com/digitaplatform/shop.git', owner: {login: 'digitaplatform'}};
  const customer = {name: 'swissbookai', clone_url: 'https://github.com/ahkutun/swissbookai.git', owner: {login: 'ahkutun'}};
  const demo = {name: 'hostyour-demo-consumer', clone_url: 'https://github.com/simetrixch/hostyour-demo-consumer.git', owner: {login: 'simetrixch'}};
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
    'a branch push of a customer repository': {ref: 'refs/heads/main', after: SHA, deleted: false, repository: customer},
    'a branch push of an owner that is not listed': {ref: 'refs/heads/main', after: SHA, deleted: false, repository: demo},
    'a deploy tag push of a customer repository': {ref: `refs/tags/deploy/prod/${tag}`, after: SHA, deleted: false, repository: customer},
    'a deploy tag push of an owner that is not listed': {ref: `refs/tags/deploy/prod/${tag}`, after: SHA, deleted: false, repository: demo},
  };
  const bodies = Object.values(pushes);
  const ci = matches('github-ci-push', bodies), deploy = matches('github-deploy-request', bodies);
  const verdicts = {ci: [true, true, false, false, false, false, false, false, false, false, false, false, false],
    deploy: [false, false, true, false, false, false, false, false, false, false, false, true, true]};
  Object.keys(pushes).forEach((name, i) => {
    assert.equal(ci[i].matched, verdicts.ci[i], `${name} on the ci trigger`);
    assert.equal(deploy[i].matched, verdicts.deploy[i], `${name} on the deploy trigger`);
  });
  assert.deepEqual(ci[0].overlays, {unit: 'shop', branch: 'feature/x', commit: SHA, 'git-url': repository.clone_url});
  // PLANTED DEFECT: a filter without the deletion guards, and one that takes every ref, each match a push they must not.
  const unguarded = (filter) => filter.replace(/ &&\s+!\(has\(body\.deleted\).*$/s, '');
  assert.ok(matches('github-ci-push', [pushes['a branch deletion']], unguarded)[0].matched);
  const anyOwner = (filter) => filter.replace(/ && body\.repository\.owner\.login in \[[^\]]*\]$/, '');
  assert.ok(matches('github-ci-push', [pushes['a branch push of a customer repository']], anyOwner)[0].matched);
  assert.ok(matches('github-ci-push', [pushes['a branch push of an owner that is not listed']], anyOwner)[0].matched);
  const everyRef = (filter) => filter.replace("body.ref.startsWith('refs/heads/')", "body.ref.startsWith('refs/')");
  assert.ok(matches('github-ci-push', [pushes['another tag push']], everyRef)[0].matched);
});

test('the ci trigger needs a list of owners, and an empty or missing list fails the render naming the key', () => {
  assert.throws(() => renderChart('image-builder', ['--set-json', 'ciPush={"owners":[]}']), /ciPush\.owners is required/);
  assert.throws(() => renderChart('image-builder', ['--set', 'ciPush=null']), /ciPush\.owners is required/);
  const filter = renderChart('image-builder', ['--set-json', 'ciPush={"owners":["one","two"]}'])
    .find((d) => d.kind === 'Trigger' && d.metadata.name === 'github-ci-push').spec.interceptors
    .find((i) => i.ref.name === 'cel').params.find((p) => p.name === 'filter').value;
  assert.ok(filter.endsWith("body.repository.owner.login in ['one', 'two']"), 'every listed owner reaches the filter');
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
  assert.equal(check.steps[0].env.find((e) => e.name === 'CI')?.value, 'true', 'a check sees the variable GitHub Actions also sets');
  const LOG = '.git/ci-check.log';
  assert.match(check.steps[0].script, /\| tee \.git\/ci-check\.log$/m, 'the log sits where no check lints, formats or lists it');
  assert.ok(pipeline.spec.description.includes(LOG) && pipeline.spec.workspaces[0].description.includes(LOG));
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

const seconds = (duration) => ['h', 'm', 's'].reduce((sum, unit, i) => sum + Number(new RegExp(`(\\d+)${unit}`).exec(duration)?.[1] ?? 0) * [3600, 60, 1][i], 0);

test('every step of the ci pipeline has requests and limits, and a run that waits for the quota outlives its tasks', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const cloneTask = imageBuilder().find((d) => d.kind === 'Task' && d.metadata.name === 'git-clone');
  const stepsOf = (task) => (task.taskSpec ?? cloneTask.spec).steps;
  for (const task of pipeline.spec.tasks) {
    for (const step of stepsOf(task)) {
      const resources = step.computeResources;
      for (const side of ['requests', 'limits']) {
        assert.ok(resources?.[side]?.cpu && resources?.[side]?.memory, `${task.name}/${step.name} has ${side} for cpu and memory`);
      }
    }
    assert.ok(task.timeout, `${task.name} bounds its own run: the timeout of a task restarts while its pod waits for the quota`);
  }
  const bounds = Object.fromEntries(pipeline.spec.tasks.map((t) => [t.name, seconds(t.timeout)]));
  assert.deepEqual(bounds, {gate: 300, clone: 600, 'fetch-branches': 300, check: 1200});
  // The clock of the whole run starts at its creation, so it holds the wait for a free slot as well.
  const whole = seconds(imageBuilder().find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === 'ci-push').spec.resourcetemplates[0].spec.timeouts.pipeline);
  assert.ok(whole >= 3 * Object.values(bounds).reduce((a, b) => a + b, 0), 'the run outlives three rounds of its own tasks');
});

test('the egress policy of a build namespace selects every pod of it', () => {
  const policy = (docs) => docs.find((d) => d.kind === 'NetworkPolicy' && d.metadata.name === 'build-egress');
  const exempts = (doc) => Object.keys(doc.spec.podSelector ?? {}).length > 0;
  assert.ok(!exempts(policy(renderUnit('shop'))), 'build-egress selects the whole namespace');
  const planted = structuredClone(policy(renderUnit('shop')));
  planted.spec.podSelector = {matchExpressions: [{key: 'tekton.dev/pipelineTask', operator: 'NotIn', values: ['tests']}]};
  assert.ok(exempts(planted), 'PLANTED DEFECT: a selector that exempts a task is caught');
});

test('the ci run keeper runs every minute, reads runs cluster-wide, and may patch and delete only inside a build namespace', () => {
  const docs = imageBuilder();
  const cron = docs.find((d) => d.kind === 'CronJob' && d.metadata.name === 'ci-run-keeper');
  assert.equal(cron.spec.schedule, '* * * * *');
  assert.equal(cron.spec.concurrencyPolicy, 'Forbid');
  const pod = cron.spec.jobTemplate.spec.template.spec;
  assert.equal(pod.serviceAccountName, 'ci-run-keeper');
  assert.equal(pod.containers[0].image, docs.find((d) => d.kind === 'CronJob' && d.metadata.name === 'release-queue')
    .spec.jobTemplate.spec.template.spec.containers[0].image);
  const map = docs.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'ci-run-keeper');
  assert.ok(map.data['ci-run-keeper.jq'].includes('image-builder.io/ci-branch') && map.data['ci-run-keeper.sh'].includes('kubectl delete'));
  // A patch or delete verb on a ClusterRole would reach every namespace, release runs of other units among them.
  const bound = docs.filter((d) => d.kind === 'ClusterRoleBinding' && d.subjects?.some((s) => s.name === 'ci-run-keeper'))
    .map((d) => docs.find((r) => r.kind === 'ClusterRole' && r.metadata.name === d.roleRef.name));
  assert.deepEqual(bound.map((r) => r.rules), [[{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['get', 'list']}]]);
  const unit = renderUnit('shop');
  const role = unit.find((d) => d.kind === 'Role' && d.metadata.name === 'ci-run-keeper-pipelineruns');
  assert.equal(role.metadata.namespace, 'shop-build');
  assert.deepEqual(role.rules, [{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['patch', 'delete']}]);
  const binding = unit.find((d) => d.kind === 'RoleBinding' && d.metadata.name === 'ci-run-keeper-pipelineruns');
  assert.deepEqual(binding.subjects, [{kind: 'ServiceAccount', name: 'ci-run-keeper', namespace: 'image-builder'}]);
});

const KEEPER = 'system:serviceaccount:image-builder:ci-run-keeper';
const KEEPER_MESSAGE = 'the ci run keeper may only cancel a ci run.';
const PRIORITY_MESSAGE = "a managed run's podTemplate sets priorityClassName to the class of its pipeline and nothing else.";
const CI_CLASS_MESSAGE = 'a ci run carries the ci priority class: the capacity quota of its build namespace counts the pods of that class only.';

test('the admission policy lets the ci run keeper cancel a ci run and change nothing else', () => {
  const policy = guardOf(imageBuilder());
  const running = (pipeline = 'shop-ci') => ({...createsRun('shop-build', pipeline).object,
    metadata: {namespace: 'shop-build', name: `${pipeline}-x`, labels: {'image-builder.io/ci': 'shop'}, annotations: {'image-builder.io/ci-branch': 'main'}, finalizers: ['chains.tekton.dev/pipelinerun']}});
  const withParams = (run) => ({...run, spec: {...run.spec, params: [{name: 'branch', value: 'main'}], timeouts: {pipeline: '2h0m0s'}}});
  const base = withParams(running());
  const changed = (edit, from = base) => { const run = structuredClone(from); edit(run); return run; };
  const cancelled = changed((r) => { r.spec.status = 'Cancelled'; });
  const update = (username, object, oldObject) => ({object, oldObject, request: {operation: 'UPDATE', namespace: 'shop-build', userInfo: {username}}});
  const ADMITTED = {
    'the keeper cancels a running ci run': update(KEEPER, cancelled, base),
    'the keeper cancels a ci run again': update(KEEPER, cancelled, cancelled),
    'the Tekton controller updates the cancelled ci run': update('system:serviceaccount:tekton:tekton-controller', changed((r) => { r.metadata.labels['tekton.dev/pipeline'] = 'shop-ci'; }, cancelled), cancelled),
  };
  const releaseRun = withParams(running('shop-release'));
  const DENIED = {
    'the keeper cancels a release run': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; }, releaseRun), releaseRun),
    'the keeper changes a param while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.spec.params[0].value = 'other'; }), base),
    'the keeper changes a param and nothing else': update(KEEPER, changed((r) => { r.spec.params[0].value = 'other'; }), base),
    'the keeper hands the run to another controller while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.spec.managedBy = 'example.com/other'; }), base),
    'the keeper changes the timeouts while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.spec.timeouts.pipeline = '24h0m0s'; }), base),
    'the keeper sets another status': update(KEEPER, changed((r) => { r.spec.status = 'PipelineRunPending'; }), base),
    'the keeper takes the cancellation back': update(KEEPER, base, cancelled),
    'the keeper changes a label while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.metadata.labels['image-builder.io/consumer'] = 'shop'; }), base),
    'the keeper changes an annotation while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.metadata.annotations['image-builder.io/ci-branch'] = 'other'; }), base),
    'the keeper changes the finalizers while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.metadata.finalizers = []; }), base),
    'the keeper creates a run': {...createsRun('shop-build', 'shop-ci'), request: {operation: 'CREATE', namespace: 'shop-build', userInfo: {username: KEEPER}}},
    'the keeper creates a run that is cancelled already': {object: changed((r) => { r.spec.status = 'Cancelled'; }, createsRun('shop-build', 'shop-ci').object), oldObject: null,
      request: {operation: 'CREATE', namespace: 'shop-build', userInfo: {username: KEEPER}}},
  };
  const verdicts = evaluate(policy, [...Object.values(ADMITTED), ...Object.values(DENIED)]).map((v) => v.denied);
  Object.keys(ADMITTED).forEach((name, i) => assert.deepEqual(verdicts[i], [], `PLANTED INNOCENT: ${name}`));
  Object.keys(DENIED).forEach((name, i) => assert.deepEqual(verdicts[Object.keys(ADMITTED).length + i], [KEEPER_MESSAGE], `PLANTED DEFECT: ${name}`));
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => v.message !== KEEPER_MESSAGE);
  assert.ok(evaluate(without, Object.values(DENIED)).every((v) => v.denied.length === 0), 'without the keeper clause every one of them is admitted');
});

test('a run carries the priority class of its pipeline and no other pod template field', () => {
  const builder = imageBuilder();
  const policy = guardOf(builder);
  const verdict = (pipeline, podTemplate) => evaluate(policy, [createsRun('shop-build', pipeline, podTemplate)])[0].denied.sort();
  assert.deepEqual(verdict('shop-release', {priorityClassName: RELEASE_CLASS}), [], 'PLANTED INNOCENT: a release run with the release class');
  assert.deepEqual(verdict('shop-ci', {priorityClassName: CI_CLASS}), [], 'PLANTED INNOCENT: a ci run with the ci class');
  assert.deepEqual(verdict('shop-release', null), [], 'a release run without a pod template is counted by no quota');
  const refused = [PRIORITY_MESSAGE, CI_CLASS_MESSAGE].sort();
  assert.deepEqual(verdict('shop-ci', null), [CI_CLASS_MESSAGE], 'PLANTED DEFECT: a ci run without a class runs outside the quota');
  assert.deepEqual(verdict('shop-ci', {}), refused, 'PLANTED DEFECT: a ci run with an empty pod template');
  assert.deepEqual(verdict('shop-ci', {priorityClassName: RELEASE_CLASS}), refused, 'PLANTED DEFECT: a ci run takes the release class');
  assert.deepEqual(verdict('shop-ci', {priorityClassName: 'system-node-critical'}), refused, 'PLANTED DEFECT: a ci run takes a system class');
  assert.deepEqual(verdict('shop-release', {priorityClassName: CI_CLASS}), [PRIORITY_MESSAGE], 'PLANTED DEFECT: a release run takes the ci class');
  assert.deepEqual(verdict('shop-release', {priorityClassName: 'system-cluster-critical'}), [PRIORITY_MESSAGE], 'PLANTED DEFECT: a release run takes a system class');
  // Every other field Tekton's CRD knows for a pod template is refused beside a right class. The CRD
  // is the one the repository renders, so a Tekton upgrade that adds a field turns this red until the
  // policy lists it.
  const crd = renderChart('tekton').find((d) => d.kind === 'CustomResourceDefinition' && d.metadata.name === 'pipelineruns.tekton.dev');
  const fields = Object.keys(crd.spec.versions.find((v) => v.name === 'v1').schema.openAPIV3Schema.properties.spec.properties
    .taskRunTemplate.properties.podTemplate.properties).filter((field) => field !== 'priorityClassName');
  assert.ok(fields.includes('volumes') && fields.includes('automountServiceAccountToken') && fields.length > 10);
  for (const pipeline of ['shop-release', 'shop-ci']) {
    for (const field of fields) {
      const value = {volumes: [], automountServiceAccountToken: true}[field] ?? 'x';
      assert.deepEqual(verdict(pipeline, {priorityClassName: classOf(pipeline), [field]: value}), [PRIORITY_MESSAGE],
        `PLANTED DEFECT: ${pipeline} sets ${field}`);
    }
  }
  // A per-task pod template cannot bring the token back either: no run carries per-task overrides.
  const perTask = createsRun('shop-build', 'shop-ci');
  perTask.object.spec.taskRunSpecs = [{pipelineTaskName: 'check', podTemplate: {automountServiceAccountToken: true}}];
  assert.deepEqual(evaluate(policy, [perTask])[0].denied, ['per-task pod, step, sidecar, metadata and account overrides are not allowed.'],
    'PLANTED DEFECT: a task asks for the token through taskRunSpecs');
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => ![PRIORITY_MESSAGE, CI_CLASS_MESSAGE].includes(v.message));
  assert.deepEqual(evaluate(without, [createsRun('shop-build', 'shop-ci', null), createsRun('shop-build', 'shop-ci', {priorityClassName: 'system-node-critical'}),
    createsRun('shop-build', 'shop-release', {priorityClassName: CI_CLASS, volumes: []})]).map((v) => v.denied), [[], [], []], 'without the clauses all three are admitted');
});

test('releases rank above ci, neither preempts, and the quota counts the class the ci runs carry', () => {
  const classes = Object.fromEntries(imageBuilder().filter((d) => d.kind === 'PriorityClass').map((d) => [d.metadata.name, d]));
  assert.deepEqual(Object.keys(classes).sort(), [CI_CLASS, RELEASE_CLASS]);
  for (const klass of Object.values(classes)) {
    assert.equal(klass.preemptionPolicy, 'Never', `${klass.metadata.name} must not evict a platform pod`);
    assert.equal(klass.globalDefault, false);
    assert.equal(klass.metadata.annotations['argocd.argoproj.io/sync-wave'], '-1', 'the class exists before a run names it');
  }
  assert.ok(classes[RELEASE_CLASS].value > 0, 'a release outranks a pod without a class');
  assert.ok(classes[CI_CLASS].value <= 0 && classes[CI_CLASS].value < classes[RELEASE_CLASS].value);
  const quotas = renderUnit('shop').filter((d) => d.kind === 'ResourceQuota');
  assert.equal(quotas.length, 1);
  assert.equal(quotas[0].metadata.namespace, 'shop-build');
  assert.deepEqual(quotas[0].spec.scopeSelector.matchExpressions, [{scopeName: 'PriorityClass', operator: 'In', values: [CI_CLASS]}]);
  assert.deepEqual(Object.keys(quotas[0].spec.hard), ['pods'], 'a compute quota would refuse Tekton init containers, which carry no requests');
  assert.ok(Number(quotas[0].spec.hard.pods) >= 1);
  assert.deepEqual(renderUnit('shop', []).filter((d) => d.kind === 'ResourceQuota'), [], 'a unit without builds has no ci run');
});
