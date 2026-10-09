import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {immutableChanges, probeImmutableChanges} from './check-immutable.mjs';
import {renderChart} from './render-chart.mjs';

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
      if (builds.length === 0) assert.deepEqual(readers.map(d => d.metadata.name).sort(), ['build-git-https', 'build-npmrc'], record.name + ' holds the credentials of its ci check and no push or bump credential');
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
  const schema = crd.spec.versions.find(v => v.name === 'v1').schema.openAPIV3Schema;
  const properties = schema.properties.spec.properties;
  // Use the shipped schema, not a hand-maintained list of CEL-visible fields. oldObject counts: a delete reads it.
  const guard = renderChart('image-builder').find(d => d.kind === 'ValidatingAdmissionPolicy' &&
    d.metadata.name === 'image-builder-pipelinerun-guard');
  const untypedFields = policy => [...new Set([...JSON.stringify(policy.spec).matchAll(/[oO]bject\.spec\.([A-Za-z0-9_]+)/g)]
    .map(match => match[1]))].filter(field => !properties[field]?.type).sort();
  assert.deepEqual(untypedFields(guard), []);
  const planted = structuredClone(guard);
  planted.spec.validations.push({expression: '!has(object.spec.pipelineSpec)'});
  assert.deepEqual(untypedFields(planted), ['pipelineSpec']);
  planted.spec.validations.push({expression: '!has(oldObject.spec.notInTheCrd)'});
  assert.deepEqual(untypedFields(planted), ['notInTheCrd', 'pipelineSpec']);
  // The delete clauses read whether a run has finished from status.conditions.
  const untypedConditionFields = root => ['type', 'status'].filter(field => !root.properties.status.properties.conditions?.items?.properties?.[field]?.type);
  assert.deepEqual(untypedConditionFields(schema), []);
  const untypedStatus = structuredClone(schema);
  delete untypedStatus.properties.status.properties.conditions;
  assert.deepEqual(untypedConditionFields(untypedStatus), ['type', 'status']);
  // Inline-only is denied by the typed reference requirement; an inline spec
  // with a reference is rejected by Tekton's native exactly-one validation.
  assert.equal(guard.spec.failurePolicy, 'Fail');
  assert.ok(guard.spec.validations.some(v => v.expression ===
    "request.operation == 'DELETE' || (has(object.spec.pipelineRef) && has(object.spec.pipelineRef.name) && size(object.spec.pipelineRef.name) > 0)"));
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
// What the ci-push TriggerTemplate creates, with the trigger's parameters filled in.
const createdCiRun = (docs) => JSON.parse(JSON.stringify(docs.find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === 'ci-push').spec.resourcetemplates[0])
  .replaceAll('$(tt.params.unit)', 'shop').replace(/\$\(tt\.params\.[a-z-]+\)/g, 'x'));
const guardOf = (docs) => docs.find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');

const OWNERSHIP = 'a build namespace runs only its own release, ci and image Pipelines.';
const EVENT_LISTENER = 'system:serviceaccount:image-builder:eventlistener-sa';
const RELEASE_CLASS = 'image-builder-release', CI_CLASS = 'image-builder-ci', REPORT_CLASS = 'image-builder-ci-report';
const classOf = (pipeline) => (pipeline.endsWith('-ci') ? CI_CLASS : RELEASE_CLASS);
// podTemplate null leaves the template out.
const createsRun = (namespace, pipeline, podTemplate = {priorityClassName: classOf(pipeline)}) => ({object: {metadata: {namespace, labels: {'image-builder.io/ci': 'shop'}},
  spec: {pipelineRef: {name: pipeline}, taskRunTemplate: {serviceAccountName: 'pipeline-sa', ...(podTemplate ? {podTemplate} : {})},
    workspaces: [{name: 'source', volumeClaimTemplate: {spec: {accessModes: ['ReadWriteOnce']}}}]}},
  oldObject: null, request: {operation: 'CREATE', namespace, userInfo: {username: EVENT_LISTENER}}});

test('the admission policy admits the release, the ci and the image pipeline of a unit in its own build namespace, and nothing else', () => {
  const policy = guardOf(imageBuilder());
  const ADMITTED = ['shop-release', 'shop-ci', 'shop-image'];
  const DENIED = ['post-ci', 'post-release', 'post-image', 'shop-image-extra', 'shop-ci-extra', 'shop-tests', 'shop', 'ci', 'release', 'image'];
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
  assert.equal(template.spec.status, 'PipelineRunPending', 'a ci run is created waiting, and the ci run keeper starts it when a slot is free');
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].spec.status, 'PipelineRunPending', 'a release run waits for the release queue');
  assert.deepEqual(Object.keys(template.metadata.labels), ['image-builder.io/ci']);
  assert.equal(template.metadata.annotations['image-builder.io/ci-branch'], '$(tt.params.branch)', 'the keeper groups ci runs by branch');
  assert.equal(template.spec.taskRunTemplate.podTemplate.priorityClassName, CI_CLASS);
  assert.deepEqual(template.spec.taskRunSpecs, [{pipelineTaskName: 'report-failure', podTemplate: {priorityClassName: REPORT_CLASS}}],
    'the report pod, and no other, carries the class the quota does not count');
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].spec.taskRunTemplate.podTemplate.priorityClassName, RELEASE_CLASS);
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].spec.taskRunSpecs, undefined, 'a release run carries no per-task override');
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].metadata.labels['image-builder.io/consumer'], '$(tt.params.unit)');
  // What the template creates, as the guard sees it once the trigger's parameters are in.
  const created = createdCiRun(builder);
  const verdict = evaluate(guardOf(builder), [{object: created, oldObject: null,
    request: {operation: 'CREATE', namespace: 'shop-build', userInfo: {username: EVENT_LISTENER}}}])[0];
  assert.deepEqual(verdict.denied, [], 'PLANTED INNOCENT: the run with the report override and the three timeouts is admitted');

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
    'a push of the books branch': {ref: 'refs/heads/check.example.invalid', after: SHA, deleted: false, repository},
    'a branch whose name begins with the books branch': {ref: 'refs/heads/check.example.invalid-fix', after: SHA, deleted: false, repository},
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
  const verdicts = {ci: [true, true, false, false, false, false, true, false, false, false, false, false, false, false, false],
    deploy: [false, false, true, false, false, false, false, false, false, false, false, false, false, true, true]};
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
  const withBooksBranch = (filter) => filter.replace(/ &&\s+body\.ref != 'refs\/heads\/[^']*'/, '');
  assert.ok(matches('github-ci-push', [pushes['a push of the books branch']], withBooksBranch)[0].matched,
    'PLANTED DEFECT: a filter without the books branch exclusion runs the check on every commit of the Manager');
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
  assert.throws(() => renderChart('image-builder', ['--set', 'global.booksCluster=']), /global\.booksCluster is required/);
});

test('the ci pipeline of a unit holds no GitOps credential, mounts only the packages reader, and is no release', () => {
  const docs = renderUnit('shop');
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  assert.deepEqual(pipeline.spec.tasks.map((t) => t.name), ['gate', 'clone', 'describe-commit', 'fetch', 'check']);
  assert.deepEqual(pipeline.spec.finally.map((t) => t.name), ['report-failure']);
  const referencesBump = (doc) => JSON.stringify(doc).includes('bump');
  assert.ok(!referencesBump(pipeline), 'the ci pipeline names no bump task, volume or secret');
  const planted = structuredClone(pipeline);
  planted.spec.tasks.find((t) => t.name === 'check').taskSpec.volumes.push({name: 'bump', secret: {secretName: 'bump-git-https'}});
  assert.ok(referencesBump(planted), 'PLANTED DEFECT: a render that adds the bump volume is caught');
  const secrets = (doc) => [...JSON.stringify(doc).matchAll(/"(?:secretName|name)":"((?:build|bump)-[a-z-]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual([...new Set(secrets(pipeline))], ['build-git-https', 'build-npmrc']);
  const check = pipeline.spec.tasks.find((t) => t.name === 'check').taskSpec;
  assert.equal(check.steps[0].envFrom, undefined, 'the check step holds no secret as environment');
  assert.equal(check.steps[0].env.find((e) => e.name === 'CI')?.value, 'true', 'a check sees the variable GitHub Actions also sets');
  assert.deepEqual(check.volumes.filter((v) => v.secret).map((v) => v.secret.secretName), ['build-npmrc']);
  assert.deepEqual(check.steps[0].volumeMounts.filter((m) => m.name === 'npmrc').map((m) => m.readOnly), [true]);
  assert.deepEqual(pipeline.spec.tasks.filter((t) => JSON.stringify(t).includes('build-git-https')).map((t) => t.name), ['clone', 'fetch']);
  // Tekton copies a Pipeline's labels onto its runs: a consumer label here would make every ci run a release.
  assert.equal(pipeline.metadata.labels['image-builder.io/ci'], 'shop');
  assert.equal(pipeline.metadata.labels['image-builder.io/consumer'], undefined);
  assert.ok(docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release').metadata.labels['image-builder.io/consumer']);
  const grant = docs.find((d) => d.kind === 'Role' && d.metadata.name === 'eventlistener-create-pipelineruns');
  assert.ok(grant.rules.some((r) => r.resources.includes('pipelineruns') && r.verbs.includes('create')), 'the event listener may create the ci run');
});

// The by-hand image pipeline builds what an operator names in the run. What keeps that from overwriting
// a release, from reaching another unit's images, and from reaching the release queue is asserted here.
test('the image pipeline of a unit is no release and holds the clone credential in its clone only', () => {
  const docs = renderUnit('shop');
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-image');
  assert.deepEqual(pipeline.spec.tasks.map((t) => t.name), ['clone', 'check', 'scan', 'build']);
  assert.deepEqual(pipeline.spec.tasks.find((t) => t.name === 'build').runAfter, ['check', 'scan']);
  // Tekton copies a Pipeline's labels onto its runs: a consumer label makes the release queue start it.
  assert.equal(pipeline.metadata.labels['image-builder.io/consumer'], undefined);
  assert.equal(pipeline.metadata.labels['image-builder.io/ci'], undefined);
  assert.deepEqual(pipeline.spec.tasks.filter((t) => JSON.stringify(t).includes('build-git-https')).map((t) => t.name), ['clone']);
  assert.ok(!JSON.stringify(pipeline).includes('bump'), 'the image pipeline names no bump task, volume or secret');
  const clone = pipeline.spec.tasks.find((t) => t.name === 'clone').params;
  assert.equal(clone.find((p) => p.name === 'revision').value, 'HEAD', 'only the default branch is built');
  const script = pipeline.spec.tasks.find((t) => t.name === 'check').taskSpec.steps[0].script;
  assert.ok(!script.includes('$(params.'), 'the run inputs reach the check as environment, never as script source');
  assert.ok(!renderUnit('shop', []).some((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-image'), 'a unit that builds nothing has no registry to push to');
});

// The check step, run with the registry answer replaced by a stub: whether the build may go on.
let imageCheckStep;
const runImageCheck = (inputs, registryAnswer = '404') => {
  imageCheckStep ??= renderUnit('shop', ['shop-web']).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-image')
    .spec.tasks.find((t) => t.name === 'check').taskSpec.steps[0];
  const step = imageCheckStep;
  const root = mkdtempSync(join(tmpdir(), 'image-check-')), source = join(root, 'source'), bin = join(root, 'bin');
  mkdirSync(join(source, 'docker'), {recursive: true}); mkdirSync(bin);
  writeFileSync(join(source, 'docker/base.Dockerfile'), 'FROM scratch\n');
  writeFileSync(join(bin, 'curl'), `#!/usr/bin/env bash\nprintf '%s' '${registryAnswer}'\n`);
  chmodSync(join(bin, 'curl'), 0o755);
  const script = step.script.replaceAll('/workspace/source', source).replace('$(results.build-timestamp.path)', join(root, 'timestamp'));
  const env = Object.fromEntries(step.env.filter((e) => e.value !== undefined && !e.value.startsWith('$(params.')).map((e) => [e.name, e.value]));
  const result = spawnSync('bash', ['-c', script], {cwd: source, encoding: 'utf8', env: {PATH: `${bin}:${process.env.PATH}`,
    REGISTRY_USERNAME: 'u', REGISTRY_PASSWORD: 'p', ...env, IMAGE: 'shop-base', VERSION: '1.0.0', CONTAINERFILE: 'docker/base.Dockerfile', CONTEXT: '.', ...inputs}});
  rmSync(root, {recursive: true, force: true});
  return result.status;
};

test('the image check builds only a new tag of an image named after the unit, from a file of the checkout', () => {
  assert.equal(runImageCheck({}), 0, 'PLANTED INNOCENT: shop-base:1.0.0 from docker/base.Dockerfile, absent from the registry');
  assert.equal(runImageCheck({CONTEXT: 'docker', CONTAINERFILE: 'base.Dockerfile'}), 0, 'PLANTED INNOCENT: a context below the root');
  const DENIED = {
    'an image of another unit': [{IMAGE: 'post-base'}],
    'an image named the unit alone': [{IMAGE: 'shop'}],
    'a release build of the unit': [{IMAGE: 'shop-web'}],
    'an image name with upper case': [{IMAGE: 'shop-Base'}],
    'an image name with a path': [{IMAGE: 'shop-base/x'}],
    'an image name with a shell character': [{IMAGE: 'shop-base;id'}],
    'a version with a slash': [{VERSION: '1.0/0'}],
    'a version that starts with a dot': [{VERSION: '.1'}],
    'a version with a shell character': [{VERSION: '1$(id)'}],
    'a containerfile that leaves the checkout': [{CONTAINERFILE: '../base.Dockerfile'}],
    'an absolute containerfile': [{CONTAINERFILE: '/etc/passwd'}],
    'a containerfile that does not exist': [{CONTAINERFILE: 'docker/missing.Dockerfile'}],
    'a context that leaves the checkout': [{CONTEXT: 'docker/..'}],
    'a tag that exists': [{}, '200'],
    'a registry that cannot answer': [{}, '503'],
  };
  for (const [name, [inputs, answer]] of Object.entries(DENIED)) {
    assert.notEqual(runImageCheck(inputs, answer), 0, `PLANTED DEFECT: ${name}`);
  }
});

test('the build offers REGISTRY only to a Containerfile that declares it', () => {
  const script = imageBuilder().find((d) => d.kind === 'Task' && d.metadata.name === 'buildah-build-push')
    .spec.steps.find((step) => step.name === 'build').script;
  const pattern = script.match(/if grep -Eq '([^']+)' "\$\{CONTAINERFILE\}"; then\n\s+REGISTRY_FLAGS\+=\(--build-arg "REGISTRY=\$\(params\.registry\)"\)/)?.[1];
  assert.ok(pattern, 'the build step adds the REGISTRY build argument behind a grep of the Containerfile');
  assert.match(script, /"\$\{REGISTRY_FLAGS\[@\]\}" \\\n/, 'buildah bud receives the flags');
  // Run through grep itself, because the pattern is POSIX ERE and the shell's grep is what reads it.
  const declares = (containerfile) => spawnSync('grep', ['-Eq', pattern], {input: containerfile}).status === 0;
  assert.ok(declares('ARG REGISTRY\nFROM ${REGISTRY}/shop-base:1\n'), 'PLANTED INNOCENT: ARG REGISTRY');
  assert.ok(declares('  ARG REGISTRY=zot.example\n'), 'PLANTED INNOCENT: ARG REGISTRY with a default');
  assert.ok(!declares('ARG REGISTRY_MIRROR\nFROM node:24\n'), 'PLANTED DEFECT: another argument that starts with REGISTRY');
  assert.ok(!declares('FROM node:24\n# ARG REGISTRY\n'), 'PLANTED DEFECT: a comment that names it');
});

// The pinned sources of other repositories: fetched with the clone credential before the check, read by the
// check from a read-only volume beside the clone, never inside it.
test('the fetch task fetches the pinned sources with the credential, and the check reads them read-only without it', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const task = (name) => pipeline.spec.tasks.find((t) => t.name === name);
  const fetch = task('fetch').taskSpec;
  assert.deepEqual(fetch.steps.map((s) => s.name), ['branches', 'list-sources', 'sources']);
  const holdsCredential = (spec) => spec.steps.filter((s) => JSON.stringify(s.envFrom ?? []).includes('build-git-https')).map((s) => s.name);
  assert.deepEqual(holdsCredential(fetch), ['branches', 'sources'], 'the step that reads the branch\'s ci-sources.json holds no credential');
  const planted = structuredClone(fetch);
  planted.steps[1].envFrom = [{secretRef: {name: 'build-git-https'}}];
  assert.notDeepEqual(holdsCredential(planted), ['branches', 'sources'], 'PLANTED DEFECT: a credential on the reading step is caught');
  assert.equal(fetch.steps[2].env.find((e) => e.name === 'SOURCES_OWNER_URL').value, 'https://github.com/check', 'sources come from the unit\'s own owner');
  for (const name of ['clone', 'describe-commit', 'fetch', 'check']) {
    assert.equal(task(name).workspaces.find((w) => w.name === 'source').subPath, 'repository', `${name} reads the clone from subPath repository`);
  }
  for (const name of ['fetch', 'check']) assert.equal(task(name).workspaces.find((w) => w.name === 'sources').subPath, 'sources');
  const check = task('check').taskSpec;
  assert.equal(check.workspaces.find((w) => w.name === 'sources').readOnly, true);
  assert.equal(check.steps[0].env.find((e) => e.name === 'CI_SOURCES_DIR').value, '/workspace/sources');
  assert.throws(() => renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name: 'shop', repoURL: 'https://gitlab.com/check/shop.git', buildsJson: '[]'})]),
    /unit\.repoURL .* is not https:\/\/github\.com\/<owner>\/<repository>/);
});

test('list-sources passes only plain repository names with full commits, and a repository without ci-sources.json fetches nothing', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const script = pipeline.spec.tasks.find((t) => t.name === 'fetch').taskSpec.steps.find((s) => s.name === 'list-sources').script;
  const SHA = 'a'.repeat(40);
  const list = (sources) => {
    const dir = mkdtempSync(join(tmpdir(), 'list-sources-'));
    try {
      if (sources !== undefined) writeFileSync(join(dir, 'ci-sources.json'), JSON.stringify(sources));
      const result = spawnSync('bash', ['-c', script], {cwd: dir, encoding: 'utf8', env: {...process.env, SOURCE_LIST: join(dir, 'list')}});
      return {status: result.status, lines: existsSync(join(dir, 'list')) && result.status === 0 ? readFileSync(join(dir, 'list'), 'utf8').split('\n').filter(Boolean) : null};
    } finally {
      rmSync(dir, {recursive: true, force: true});
    }
  };
  assert.deepEqual(list({git: {'digita-auth': SHA, 'digita-post.v2': 'b'.repeat(40)}, npm: {mongodb: '7.5.0'}}),
    {status: 0, lines: [`digita-auth ${SHA}`, `digita-post.v2 ${'b'.repeat(40)}`]}, 'PLANTED INNOCENT: plain names and full commits pass, and npm is not read');
  assert.deepEqual(list(undefined), {status: 0, lines: []});
  assert.deepEqual(list({npm: {mongodb: '7.5.0'}}), {status: 0, lines: []});
  for (const [name, commit] of [['../digita-auth', SHA], ['owner/digita-auth', SHA], ['..', SHA], ['digita auth', SHA], ['digita-auth', 'a'.repeat(39)], ['digita-auth', 'A'.repeat(40)], ['digita-auth', 'master']]) {
    assert.notEqual(list({git: {[name]: commit}}).status, 0, `PLANTED DEFECT: ${name} at ${commit} is refused`);
  }
  assert.notEqual(list({git: {'digita-auth': SHA, x: 1}}).status, 0, 'a commit that is not a string is refused');
});

// A unit that builds nothing ("CI only", `builds: []` in its registration) still gets a ci check on every
// push, and gets no release pipeline and no credential that writes: the namespace runs repository code.
const CI_PARTS = [['Pipeline', 'shop-ci'], ['ResourceQuota', 'ci-pods'], ['ExternalSecret', 'build-git-https'], ['ExternalSecret', 'build-npmrc'],
  ['Role', 'ci-report-read'], ['Role', 'ci-run-keeper-pipelineruns']];
const RELEASE_PARTS = [['Pipeline', 'shop-release'], ['Pipeline', 'shop-image'], ['ExternalSecret', 'image-builder-registry-pull-opaque'], ['ExternalSecret', 'bump-git-https']];
const holds = (docs, parts) => parts.map(([kind, name]) => docs.some((d) => d.kind === kind && d.metadata.name === name));
const isCiOnly = (docs) => holds(docs, CI_PARTS).every(Boolean) && !holds(docs, RELEASE_PARTS).some(Boolean);

test('a unit that builds nothing renders the ci check and no release, registry or bump part', () => {
  const ciOnly = renderUnit('shop', []);
  assert.ok(isCiOnly(ciOnly), 'ci pipeline, ci quota, clone credential, packages reader and the ci grants render; release pipeline, registry secret and bump secret do not');
  const withBuilds = renderUnit('shop');
  assert.deepEqual(holds(withBuilds, [...CI_PARTS, ...RELEASE_PARTS]), Array(CI_PARTS.length + RELEASE_PARTS.length).fill(true), 'PLANTED INNOCENT: a unit with builds renders both pipelines and every credential as before');
  assert.ok(!isCiOnly(withBuilds), 'a unit with builds is not a ci-only unit');
  // The condition this change replaced (a unit renders its ci parts only when it builds) leaves out the ci parts.
  const oldCondition = ciOnly.filter((d) => !CI_PARTS.slice(0, 4).some(([kind, name]) => d.kind === kind && d.metadata.name === name));
  assert.ok(!isCiOnly(oldCondition), 'PLANTED DEFECT: a render that keeps the ci parts behind the builds condition is caught');
  const leaky = [...ciOnly, withBuilds.find((d) => d.kind === 'ExternalSecret' && d.metadata.name === 'bump-git-https')];
  assert.ok(!isCiOnly(leaky), 'PLANTED DEFECT: a ci-only render that carries the bump credential is caught');
});

// The lines of the check step from the install on, run in a repository directory with pnpm replaced by a stub
// that records each call: true when the repository's check ran, and whether pnpm was called.
const runInstallAndCheck = (installAndCheck, files) => {
  const root = mkdtempSync(join(tmpdir(), 'ci-check-')), repo = join(root, 'repo'), bin = join(root, 'bin');
  mkdirSync(join(repo, 'scripts'), {recursive: true}); mkdirSync(bin);
  for (const file of files) writeFileSync(join(repo, file), '');
  writeFileSync(join(repo, 'scripts/check.sh'), 'touch checked\n');
  writeFileSync(join(bin, 'pnpm'), `#!/usr/bin/env bash\ntouch "${join(root, 'pnpm-called')}"\n[ -f pnpm-lock.yaml ]\n`);
  chmodSync(join(bin, 'pnpm'), 0o755);
  try {
    execFileSync('bash', ['-euo', 'pipefail', '-c', installAndCheck], {cwd: repo, env: {...process.env, PATH: `${bin}:${process.env.PATH}`}});
  } catch { /* a failed install is read from the missing marker below */ }
  return {checked: existsSync(join(repo, 'checked')), pnpm: existsSync(join(root, 'pnpm-called'))};
};

test('the ci check installs with pnpm only a repository that carries pnpm-lock.yaml, and checks every repository', () => {
  const script = renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci')
    .spec.tasks.find((t) => t.name === 'check').taskSpec.steps[0].script;
  const lines = script.split('\n');
  const installAndCheck = lines.slice(lines.findIndex((line) => line.includes('pnpm install'))).join('\n');
  assert.ok(installAndCheck.includes('bash scripts/check.sh'), 'the install is followed by the repository check');
  assert.deepEqual(runInstallAndCheck(installAndCheck, ['package.json', 'pnpm-lock.yaml']), {checked: true, pnpm: true}, 'PLANTED INNOCENT: a pnpm repository is installed, then checked');
  assert.deepEqual(runInstallAndCheck(installAndCheck, []), {checked: true, pnpm: false}, 'a repository without package.json is checked without an install');
  assert.deepEqual(runInstallAndCheck(installAndCheck, ['package.json', 'package-lock.json']), {checked: true, pnpm: false}, 'a repository with an npm lockfile is checked without a pnpm install');
  const unconditional = 'pnpm install --frozen-lockfile\nbash scripts/check.sh\n';
  assert.deepEqual(runInstallAndCheck(unconditional, []), {checked: false, pnpm: true}, 'PLANTED DEFECT: an install that runs in every repository fails the repository without package.json before its check');
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
  assert.deepEqual(bounds, {gate: 300, clone: 600, 'describe-commit': 120, 'fetch': 300, check: 1200});
  const report = pipeline.spec.finally.find((t) => t.name === 'report-failure');
  for (const step of report.taskSpec.steps) {
    for (const side of ['requests', 'limits']) assert.ok(step.computeResources?.[side]?.cpu && step.computeResources?.[side]?.memory, `report-failure/${step.name} has ${side}`);
  }
  assert.equal(seconds(report.timeout), 300);
  // Tekton sets no start time on a waiting run, so the clocks start when the keeper starts it and hold no wait for a ci slot.
  // They do hold the wait of a pod for the quota of its unit.
  // The finally tasks run on a clock of their own, so a run that used up its tasks budget still mails.
  const timeouts = imageBuilder().find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === 'ci-push').spec.resourcetemplates[0].spec.timeouts;
  const mailsAfterTimeout = (t) => Boolean(t.tasks && t.finally) && seconds(t.pipeline) >= seconds(t.tasks) + seconds(t.finally) &&
    seconds(t.tasks) >= 2 * Object.values(bounds).reduce((a, b) => a + b, 0) && seconds(t.finally) >= seconds(report.timeout);
  assert.ok(mailsAfterTimeout(timeouts), 'PLANTED INNOCENT: the run outlives two rounds of its own tasks and leaves the finally task its own time');
  assert.ok(!mailsAfterTimeout({pipeline: timeouts.pipeline}), 'PLANTED DEFECT: the pipeline timeout alone cancels the finally task with the rest');
  assert.ok(!mailsAfterTimeout({...timeouts, pipeline: '1h50m0s'}), 'PLANTED DEFECT: a pipeline timeout shorter than tasks plus finally');
  assert.ok(!mailsAfterTimeout({...timeouts, tasks: '30m0s'}), 'PLANTED DEFECT: a tasks budget that is not two rounds of the tasks');
  assert.ok(!mailsAfterTimeout({...timeouts, finally: '2m0s'}), 'PLANTED DEFECT: a finally budget shorter than the report task');
});

// The scheduler admits a pod by its requests, and the kernel kills by QoS class when the node runs out of
// memory, so what keeps the platform pods alive is a sum of limits that fits the free memory of the node.
const BYTES = {Gi: 1024 ** 3, Mi: 1024 ** 2};
const quantity = (text) => Number(text.slice(0, -2)) * BYTES[text.slice(-2)];
const podLimit = (task, cloneTask) => (task.taskSpec ?? cloneTask.spec).steps
  .reduce((sum, step) => sum + quantity(step.computeResources.limits.memory), 0);
// The limits of the ci pods of the runs that run at once (one at a time per run, because the tasks form a chain),
// the report pod of each of those runs (its class is the one the quota does not count, so it comes on top), plus
// the build pods of the one release that runs. The ci run keeper holds the number of running runs at maxRunning.
const fitsFreeMemory = (capacity, pipeline, cloneTask, release, buildahTask) => {
  const largest = (tasks) => Math.max(0, ...tasks.map((task) => podLimit(task, cloneTask)));
  const ciPods = capacity.maxRunning * largest(pipeline.spec.tasks);
  const reportPods = capacity.maxRunning * largest(pipeline.spec.finally);
  const buildPods = release.spec.tasks.filter((task) => task.name.startsWith('build-') && task.runAfter?.includes('scan')).length;
  return ciPods + reportPods + buildPods * podLimit({taskSpec: buildahTask.spec}, cloneTask) <= quantity(capacity.limitsMemoryBudget);
};

test('the memory limits of all ci pods and one release together fit the free memory of the build node', () => {
  const capacity = {...JSON.parse(execFileSync('yq', ['-o=json', '.ciCapacity', 'clusters/inventories/consumer-build/values-common.yaml'], {encoding: 'utf8'})),
    maxRunning: Number(execFileSync('yq', ['.ciRunKeeper.maxRunning', 'clusters/inventories/image-builder/values-common.yaml'], {encoding: 'utf8'}))};
  const images = (count) => Array.from({length: count}, (_, i) => `image-${i + 1}`);
  const docs = renderUnit('shop', images(capacity.releaseBuildPods));
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const release = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release');
  const cloneTask = imageBuilder().find((d) => d.kind === 'Task' && d.metadata.name === 'git-clone');
  const buildah = imageBuilder().find((d) => d.kind === 'Task' && d.metadata.name === 'buildah-build-push');
  assert.equal(String(capacity.podsPerUnit), docs.find((d) => d.kind === 'ResourceQuota').spec.hard.pods, 'the quota renders the declared pods per unit');
  assert.ok(pipeline.spec.tasks.every((t, i) => i === 0 || t.runAfter?.length === 1 && t.runAfter[0] === pipeline.spec.tasks[i - 1].name), 'the budget counts one ci pod per running run, so the tasks run one after the other');
  assert.equal(release.spec.tasks.filter((t) => t.name.startsWith('build-') && t.runAfter?.includes('scan')).length, capacity.releaseBuildPods, 'every image of the release builds in parallel after the scan');
  assert.ok(fitsFreeMemory(capacity, pipeline, cloneTask, release, buildah), 'PLANTED INNOCENT: the limits as they stand fit');
  const planted = structuredClone(pipeline);
  planted.spec.tasks.find((t) => t.name === 'check').taskSpec.steps[0].computeResources.limits.memory = '4Gi';
  assert.ok(!fitsFreeMemory(capacity, planted, cloneTask, release, buildah), 'PLANTED DEFECT: a 4Gi limit on the check step is caught');
  assert.ok(!fitsFreeMemory({...capacity, maxRunning: 14}, pipeline, cloneTask, release, buildah), 'PLANTED DEFECT: 14 runs at once, one per unit of 14 units and so no cap, is caught');
  const fourImages = renderUnit('shop', images(capacity.releaseBuildPods + 1)).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release');
  assert.ok(!fitsFreeMemory(capacity, pipeline, cloneTask, fourImages, buildah), 'PLANTED DEFECT: a fourth image built in parallel is caught');
  const heavyReport = structuredClone(pipeline);
  heavyReport.spec.finally[0].taskSpec.steps[0].computeResources.limits.memory = '2Gi';
  assert.ok(!fitsFreeMemory(capacity, heavyReport, cloneTask, release, buildah), 'PLANTED DEFECT: a 2Gi limit on the report step, one report pod per running run outside the quota, is caught');
  const heavy = structuredClone(buildah);
  heavy.spec.steps.find((step) => step.name === 'build').computeResources.limits.memory = '8Gi';
  assert.ok(!fitsFreeMemory(capacity, pipeline, cloneTask, release, heavy), 'PLANTED DEFECT: a raised limit of the buildah build step is caught');
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
const KEEPER_MESSAGE = 'the ci run keeper may only cancel a ci run, start a waiting one, or note what it waits for.';
const PRIORITY_MESSAGE = "a managed run's podTemplate sets priorityClassName to the class of its pipeline and nothing else.";
const OVERRIDE_MESSAGE = 'per-task pod, step, sidecar, metadata and account overrides are not allowed, except the report class on the task report-failure of a ci run.';
const CI_CLASS_MESSAGE = 'a ci run carries the ci priority class: the capacity quota of its build namespace counts the pods of that class only.';

test('the admission policy lets the ci run keeper cancel, start and note a ci run and change nothing else', () => {
  const policy = guardOf(imageBuilder());
  const running = (pipeline = 'shop-ci') => ({...createsRun('shop-build', pipeline).object,
    metadata: {namespace: 'shop-build', name: `${pipeline}-x`, labels: {'image-builder.io/ci': 'shop'}, annotations: {'image-builder.io/ci-branch': 'main'}, finalizers: ['chains.tekton.dev/pipelinerun']}});
  const withParams = (run) => ({...run, spec: {...run.spec, params: [{name: 'branch', value: 'main'}], timeouts: {pipeline: '2h0m0s'}}});
  const base = withParams(running());
  const changed = (edit, from = base) => { const run = structuredClone(from); edit(run); return run; };
  const cancelled = changed((r) => { r.spec.status = 'Cancelled'; });
  const waiting = changed((r) => { r.spec.status = 'PipelineRunPending'; });
  const noted = changed((r) => { r.metadata.annotations['image-builder.io/queued-behind'] = 'all 6 ci slots are in use'; }, waiting);
  const update = (username, object, oldObject) => ({object, oldObject, request: {operation: 'UPDATE', namespace: 'shop-build', userInfo: {username}}});
  const ADMITTED = {
    'the keeper cancels a running ci run': update(KEEPER, cancelled, base),
    'the keeper cancels a ci run again': update(KEEPER, cancelled, cancelled),
    'the keeper cancels a waiting ci run': update(KEEPER, cancelled, waiting),
    'the keeper starts a waiting ci run': update(KEEPER, base, waiting),
    'the keeper starts a waiting ci run and drops its note': update(KEEPER, base, noted),
    'the keeper notes a waiting ci run': update(KEEPER, noted, waiting),
    'the keeper keeps a waiting ci run waiting': update(KEEPER, noted, noted),
    'the Tekton controller updates the cancelled ci run': update('system:serviceaccount:tekton:tekton-controller', changed((r) => { r.metadata.labels['tekton.dev/pipeline'] = 'shop-ci'; }, cancelled), cancelled),
  };
  const releaseRun = withParams(running('shop-release'));
  const releaseWaiting = changed((r) => { r.spec.status = 'PipelineRunPending'; }, releaseRun);
  const DENIED = {
    'the keeper starts a waiting release run': update(KEEPER, changed((r) => { delete r.spec.status; }, releaseWaiting), releaseWaiting),
    'the keeper changes a param while it starts': update(KEEPER, changed((r) => { r.spec.params[0].value = 'other'; }), waiting),
    'the keeper changes another annotation while it notes': update(KEEPER, changed((r) => { r.metadata.annotations['image-builder.io/ci-branch'] = 'other'; }, noted), waiting),
    'the keeper changes a label while it starts': update(KEEPER, changed((r) => { r.metadata.labels['image-builder.io/consumer'] = 'shop'; }), waiting),
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

test('the admission policy lets the ci run keeper delete a finished ci run of its own namespace, and no other run', () => {
  const policy = guardOf(imageBuilder());
  // On a delete object is null; oldObject is the run, and it has finished when its Succeeded condition is True or False.
  const run = (pipeline, status) => ({metadata: {namespace: 'shop-build', name: `${pipeline}-x`}, spec: {pipelineRef: {name: pipeline}}, ...(status ? {status} : {})});
  const succeeded = (value) => ({conditions: [{type: 'Succeeded', status: value}]});
  const deletes = (username, oldObject) => ({object: null, oldObject, request: {operation: 'DELETE', namespace: 'shop-build', userInfo: {username}}});
  const QUEUE = 'system:serviceaccount:image-builder:release-queue';
  const DASHBOARD = 'system:serviceaccount:tekton-pipelines:tekton-dashboard';
  const KEEPER_DELETE_MESSAGE = 'the ci run keeper may only delete a finished ci run of its own namespace.';
  const ADMITTED = {
    'the keeper deletes a ci run that succeeded': deletes(KEEPER, run('shop-ci', succeeded('True'))),
    'the keeper deletes a ci run that failed': deletes(KEEPER, run('shop-ci', succeeded('False'))),
    'the Tekton Dashboard deletes a running ci run': deletes(DASHBOARD, run('shop-ci', succeeded('Unknown'))),
    'a user deletes a waiting ci run': deletes('owner@example.com', {...run('shop-ci'), spec: {pipelineRef: {name: 'shop-ci'}, status: 'PipelineRunPending'}}),
    'the release queue deletes a finished release run': deletes(QUEUE, run('shop-release', succeeded('True'))),
  };
  const DENIED = {
    'the keeper deletes a running ci run': deletes(KEEPER, run('shop-ci', succeeded('Unknown'))),
    'the keeper deletes a waiting ci run': deletes(KEEPER, {...run('shop-ci'), spec: {pipelineRef: {name: 'shop-ci'}, status: 'PipelineRunPending'}}),
    'the keeper deletes a ci run with an empty status': deletes(KEEPER, run('shop-ci', {})),
    'the keeper deletes a ci run with another condition only': deletes(KEEPER, run('shop-ci', {conditions: [{type: 'Ready', status: 'True'}]})),
    'the keeper deletes a finished release run': deletes(KEEPER, run('shop-release', succeeded('True'))),
    'the keeper deletes a finished run of another unit\'s ci pipeline': deletes(KEEPER, run('post-ci', succeeded('True'))),
    'the keeper deletes a finished run without a pipeline': deletes(KEEPER, {metadata: {namespace: 'shop-build', name: 'x'}, spec: {}, status: succeeded('True')}),
  };
  const verdicts = evaluate(policy, [...Object.values(ADMITTED), ...Object.values(DENIED)]).map((v) => v.denied);
  Object.keys(ADMITTED).forEach((name, i) => assert.deepEqual(verdicts[i], [], `PLANTED INNOCENT: ${name}`));
  Object.keys(DENIED).forEach((name, i) => assert.deepEqual(verdicts[Object.keys(ADMITTED).length + i], [KEEPER_DELETE_MESSAGE], `PLANTED DEFECT: ${name}`));
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => v.message !== KEEPER_DELETE_MESSAGE);
  assert.ok(evaluate(without, Object.values(DENIED)).every((v) => v.denied.length === 0), 'without the keeper delete clause every one of them is admitted');
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
  // An image run is started by hand, outside the ci quota, so it takes the release class.
  assert.deepEqual(verdict('shop-image', {priorityClassName: RELEASE_CLASS}), [], 'PLANTED INNOCENT: an image run with the release class');
  assert.deepEqual(verdict('shop-image', {priorityClassName: CI_CLASS}), [PRIORITY_MESSAGE], 'PLANTED DEFECT: an image run takes the ci class');
  // Every other field Tekton's CRD knows for a pod template is refused beside a right class. The CRD
  // is the one the repository renders, so a Tekton upgrade that adds a field turns this red until the
  // policy lists it.
  const crd = renderChart('tekton').find((d) => d.kind === 'CustomResourceDefinition' && d.metadata.name === 'pipelineruns.tekton.dev');
  const fields = Object.keys(crd.spec.versions.find((v) => v.name === 'v1').schema.openAPIV3Schema.properties.spec.properties
    .taskRunTemplate.properties.podTemplate.properties).filter((field) => field !== 'priorityClassName');
  assert.ok(fields.includes('volumes') && fields.includes('automountServiceAccountToken') && fields.length > 10);
  for (const pipeline of ['shop-release', 'shop-ci', 'shop-image']) {
    for (const field of fields) {
      const value = {volumes: [], automountServiceAccountToken: true}[field] ?? 'x';
      assert.deepEqual(verdict(pipeline, {priorityClassName: classOf(pipeline), [field]: value}), [PRIORITY_MESSAGE],
        `PLANTED DEFECT: ${pipeline} sets ${field}`);
    }
  }
  // A per-task pod template cannot bring the token back either: no run carries per-task overrides.
  const perTask = createsRun('shop-build', 'shop-ci');
  perTask.object.spec.taskRunSpecs = [{pipelineTaskName: 'check', podTemplate: {automountServiceAccountToken: true}}];
  assert.deepEqual(evaluate(policy, [perTask])[0].denied, [OVERRIDE_MESSAGE],
    'PLANTED DEFECT: a task asks for the token through taskRunSpecs');
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => ![PRIORITY_MESSAGE, CI_CLASS_MESSAGE].includes(v.message));
  assert.deepEqual(evaluate(without, [createsRun('shop-build', 'shop-ci', null), createsRun('shop-build', 'shop-ci', {priorityClassName: 'system-node-critical'}),
    createsRun('shop-build', 'shop-release', {priorityClassName: CI_CLASS, volumes: []})]).map((v) => v.denied), [[], [], []], 'without the clauses all three are admitted');
});

test('releases rank above ci, neither preempts, and the quota counts the class the ci runs carry', () => {
  const classes = Object.fromEntries(imageBuilder().filter((d) => d.kind === 'PriorityClass').map((d) => [d.metadata.name, d]));
  assert.deepEqual(Object.keys(classes).sort(), [CI_CLASS, REPORT_CLASS, RELEASE_CLASS].sort());
  for (const klass of Object.values(classes)) {
    assert.equal(klass.preemptionPolicy, 'Never', `${klass.metadata.name} must not evict a platform pod`);
    assert.equal(klass.globalDefault, false);
    assert.equal(klass.metadata.annotations['argocd.argoproj.io/sync-wave'], '-1', 'the class exists before a run names it');
  }
  assert.ok(classes[RELEASE_CLASS].value > 0, 'a release outranks a pod without a class');
  assert.ok(classes[CI_CLASS].value <= 0 && classes[CI_CLASS].value < classes[RELEASE_CLASS].value);
  assert.equal(classes[REPORT_CLASS].value, classes[CI_CLASS].value, 'the report pod ranks like a ci pod');
  const quotas = renderUnit('shop').filter((d) => d.kind === 'ResourceQuota');
  assert.equal(quotas.length, 1);
  assert.equal(quotas[0].metadata.namespace, 'shop-build');
  assert.deepEqual(quotas[0].spec.scopeSelector.matchExpressions, [{scopeName: 'PriorityClass', operator: 'In', values: [CI_CLASS]}]);
  assert.ok(!JSON.stringify(quotas[0]).includes(REPORT_CLASS), 'the report pod is not counted by the ci quota');
  assert.deepEqual(Object.keys(quotas[0].spec.hard), ['pods'], 'a compute quota would refuse Tekton init containers, which carry no requests');
  assert.ok(Number(quotas[0].spec.hard.pods) >= 1);
});

// The failure report. A ci run that fails mails the error through Alertmanager, and what keeps that from
// weakening the ci pipeline is asserted here on the rendered charts: the report task runs after a failure
// only, holds the one token, reads with `get` and nothing else, and is the one pod that reaches the API
// server and Alertmanager.
const REPORT_OVERRIDE = (extra = {}) => ({pipelineTaskName: 'report-failure', podTemplate: {priorityClassName: REPORT_CLASS}, ...extra});
const runWith = (pipeline, taskRunSpecs) => {
  const run = createsRun('shop-build', pipeline);
  if (taskRunSpecs) run.object.spec.taskRunSpecs = taskRunSpecs;
  return run;
};

test('the admission policy admits the report class on report-failure of a ci run and no other per-task override', () => {
  const policy = guardOf(imageBuilder());
  const crd = renderChart('tekton').find((d) => d.kind === 'CustomResourceDefinition' && d.metadata.name === 'pipelineruns.tekton.dev');
  const entry = crd.spec.versions.find((v) => v.name === 'v1').schema.openAPIV3Schema.properties.spec.properties.taskRunSpecs.items.properties;
  const podTemplateFields = Object.keys(entry.podTemplate.properties).filter((field) => field !== 'priorityClassName');
  // The keys of an entry come from the CRD this repository renders, so a Tekton upgrade that adds one turns this red.
  const otherKeys = Object.keys(entry).filter((key) => !['pipelineTaskName', 'podTemplate'].includes(key));
  assert.deepEqual(otherKeys.sort(), ['computeResources', 'metadata', 'serviceAccountName', 'sidecarSpecs', 'stepSpecs', 'timeout']);
  const ADMITTED = {
    'a ci run with the report class on report-failure': runWith('shop-ci', [REPORT_OVERRIDE()]),
    'a ci run with an empty list of per-task overrides': runWith('shop-ci', []),
    'a ci run without per-task overrides': runWith('shop-ci'),
    'a release run without per-task overrides': runWith('shop-release'),
    'the run the ci-push TriggerTemplate creates': {...runWith('shop-ci'), object: createdCiRun(imageBuilder())},
  };
  ADMITTED['the run the ci-push TriggerTemplate creates'].object.metadata.namespace = 'shop-build';
  const DENIED = {
    'a second entry': runWith('shop-ci', [REPORT_OVERRIDE(), REPORT_OVERRIDE({pipelineTaskName: 'check'})]),
    'the same entry twice': runWith('shop-ci', [REPORT_OVERRIDE(), REPORT_OVERRIDE()]),
    'another task with the report class': runWith('shop-ci', [REPORT_OVERRIDE({pipelineTaskName: 'check'})]),
    'a task of the release pipeline with the report class': runWith('shop-ci', [REPORT_OVERRIDE({pipelineTaskName: 'bump'})]),
    'the report class on a release run': runWith('shop-release', [REPORT_OVERRIDE()]),
    'the ci class on report-failure': runWith('shop-ci', [REPORT_OVERRIDE({podTemplate: {priorityClassName: CI_CLASS}})]),
    'a system class on report-failure': runWith('shop-ci', [REPORT_OVERRIDE({podTemplate: {priorityClassName: 'system-node-critical'}})]),
    'an entry without a pod template': runWith('shop-ci', [{pipelineTaskName: 'report-failure'}]),
    'a pod template without the class': runWith('shop-ci', [REPORT_OVERRIDE({podTemplate: {}})]),
    'an entry without a task name': runWith('shop-ci', [{podTemplate: {priorityClassName: REPORT_CLASS}}]),
    ...Object.fromEntries(otherKeys.map((key) => [`${key} in the entry`,
      runWith('shop-ci', [REPORT_OVERRIDE({[key]: key === 'serviceAccountName' ? 'pipeline-sa' : 'x'})])])),
    ...Object.fromEntries(podTemplateFields.map((field) => [`${field} in the pod template of the entry`,
      runWith('shop-ci', [REPORT_OVERRIDE({podTemplate: {priorityClassName: REPORT_CLASS, [field]: {volumes: [], automountServiceAccountToken: true}[field] ?? 'x'}})])])),
  };
  assert.ok(podTemplateFields.includes('automountServiceAccountToken') && podTemplateFields.includes('volumes'));
  const verdicts = evaluate(policy, [...Object.values(ADMITTED), ...Object.values(DENIED)]).map((v) => v.denied);
  Object.keys(ADMITTED).forEach((name, i) => assert.deepEqual(verdicts[i], [], `PLANTED INNOCENT: ${name}`));
  Object.keys(DENIED).forEach((name, i) => assert.deepEqual(verdicts[Object.keys(ADMITTED).length + i], [OVERRIDE_MESSAGE], `PLANTED DEFECT: ${name}`));
  // The refusal is this clause's: without it every one of them is admitted.
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => v.message !== OVERRIDE_MESSAGE);
  assert.ok(evaluate(without, Object.values(DENIED).filter((run) => !run.object.spec.taskRunSpecs.some((e) => e.serviceAccountName)))
    .every((v) => v.denied.length === 0), 'without the clause every one of them is admitted');
  // A different service account in an entry is refused by the older clause too, so both name it.
  assert.deepEqual(evaluate(policy, [runWith('shop-ci', [REPORT_OVERRIDE({serviceAccountName: 'other'})])])[0].denied.sort(),
    ['taskRunSpecs may not run a task under another ServiceAccount — every task pod runs as pipeline-sa.', OVERRIDE_MESSAGE].sort());
});

// A model of the two rules that decide whether the report pod waits, each read from the source it models.
// Tekton merges the entry of taskRunSpecs over taskRunTemplate for that one task (pipelinerun_types.go
// GetTaskRunSpec calls MergePodTemplateWithDefault, whose priorityClassName stays the task's own when set,
// pkg/apis/pipeline/pod/template.go). The quota counts the pods of its scope classes that are not finished.
const podClassOf = (run, task) => run.spec.taskRunSpecs?.find((entry) => entry.pipelineTaskName === task)?.podTemplate?.priorityClassName ??
  run.spec.taskRunTemplate.podTemplate?.priorityClassName;
const quotaAdmits = (quota, runningClasses, newClass) => {
  const counted = quota.spec.scopeSelector.matchExpressions.flatMap((e) => e.values);
  return !counted.includes(newClass) || runningClasses.filter((c) => counted.includes(c)).length + 1 <= Number(quota.spec.hard.pods);
};

test('the report pod of a red run is admitted by the ci quota while the check of another branch holds its slot', () => {
  const builder = imageBuilder();
  const quota = renderUnit('shop').find((d) => d.kind === 'ResourceQuota');
  const run = createdCiRun(builder);
  const held = [podClassOf(run, 'check')];
  assert.equal(quota.spec.hard.pods, '1', 'the slot is held by the one check');
  assert.equal(quotaAdmits(quota, held, podClassOf(run, 'check')), false, 'a second ci pod waits');
  assert.equal(quotaAdmits(quota, held, podClassOf(run, 'report-failure')), true, 'PLANTED INNOCENT: the report pod of a red run does not wait for the slot');
  const noOverride = structuredClone(run);
  delete noOverride.spec.taskRunSpecs;
  assert.equal(quotaAdmits(quota, held, podClassOf(noOverride, 'report-failure')), false, 'PLANTED DEFECT: a run without the override puts the report pod behind the check');
  const counting = structuredClone(quota);
  counting.spec.scopeSelector.matchExpressions[0].values.push(REPORT_CLASS);
  assert.equal(quotaAdmits(counting, held, podClassOf(run, 'report-failure')), false, 'PLANTED DEFECT: a quota that counts the report class holds the report pod back');
});

test('report-failure runs after a failure only, holds the one token, and reads with get on the run, its TaskRuns and pod logs', () => {
  const docs = renderUnit('shop');
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const all = [...pipeline.spec.tasks, ...pipeline.spec.finally];
  const report = pipeline.spec.finally.find((t) => t.name === 'report-failure');
  const runsOnFailureOnly = (task) => JSON.stringify(task.when) === JSON.stringify([{input: '$(tasks.status)', operator: 'in', values: ['Failed']}]);
  const holdsSecret = (task) => /"(?:secretName|secretRef|secretKeyRef|envFrom)"/.test(JSON.stringify(task));
  const mountsToken = (task) => /serviceAccountToken|"automountServiceAccountToken":true/.test(JSON.stringify(task));
  assert.equal(report.taskSpec.steps[0].script, readFileSync('clusters/inventories/consumer-build/files/ci-report-failure.sh', 'utf8'),
    'the pipeline carries the script that scripts/ci-report-failure.test.mjs runs');
  assert.ok(runsOnFailureOnly(report), 'PLANTED INNOCENT: the report runs when a task failed');
  for (const when of [undefined, [{input: '$(tasks.status)', operator: 'in', values: ['Failed', 'Succeeded']}],
    [{input: '$(tasks.status)', operator: 'notin', values: ['Succeeded']}], [{input: '$(tasks.status)', operator: 'in', values: ['Completed']}]]) {
    assert.ok(!runsOnFailureOnly({...report, when}), `PLANTED DEFECT: ${JSON.stringify(when)} is not a failure`);
  }
  assert.ok(!holdsSecret(report), 'the report holds no npmrc, no git credential and no other secret');
  const withNpmrc = structuredClone(report);
  withNpmrc.taskSpec.volumes.push({name: 'npmrc', secret: {secretName: 'build-npmrc'}});
  assert.ok(holdsSecret(withNpmrc), 'PLANTED DEFECT: the report task mounting build-npmrc is caught');
  const asEnvironment = structuredClone(report);
  asEnvironment.taskSpec.steps[0].envFrom = [{secretRef: {name: 'build-git-https'}}];
  assert.ok(holdsSecret(asEnvironment), 'PLANTED DEFECT: the report task reading a secret as environment is caught');
  assert.deepEqual(all.filter(mountsToken).map((t) => t.name), ['report-failure'], 'only the report task mounts a token');
  const check = structuredClone(pipeline.spec.tasks.find((t) => t.name === 'check'));
  check.taskSpec.volumes.push({name: 'api', projected: {sources: [{serviceAccountToken: {path: 'token', expirationSeconds: 600}}]}});
  assert.ok(mountsToken(check), 'PLANTED DEFECT: a check that mounts a token is caught');
  assert.ok(mountsToken({taskSpec: {steps: [], automountServiceAccountToken: true}}) && mountsToken({podTemplate: {automountServiceAccountToken: true}}),
    'PLANTED DEFECT: a task that switches the automount on is caught');
  assert.equal(docs.find((d) => d.kind === 'ServiceAccount' && d.metadata.name === 'pipeline-sa').automountServiceAccountToken, false);
  const projected = report.taskSpec.volumes.find((v) => v.name === 'api-token').projected.sources.find((source) => source.serviceAccountToken).serviceAccountToken;
  assert.ok(projected.expirationSeconds >= 600, 'the API server refuses a shorter life');
  assert.equal(projected.audience, undefined, 'the token is for the API server and no other audience');

  const grants = (role) => role.rules.flatMap((rule) => rule.apiGroups.flatMap((group) => rule.resources.flatMap((resource) => rule.verbs.map((verb) => `${group}/${resource}:${verb}`)))).sort();
  const role = docs.find((d) => d.kind === 'Role' && d.metadata.name === 'ci-report-read');
  const EXPECTED = ['/pods/log:get', 'tekton.dev/pipelineruns:get', 'tekton.dev/taskruns:get'];
  assert.deepEqual(grants(role), EXPECTED, 'PLANTED INNOCENT: get on the run, its TaskRuns and pod logs');
  for (const [name, edit] of Object.entries({
    'list on the TaskRuns': (r) => { r.rules[0].verbs.push('list'); },
    'watch on the run': (r) => { r.rules[0].verbs.push('watch'); },
    'create on the run': (r) => { r.rules[0].verbs.push('create'); },
    'the pods themselves': (r) => { r.rules[1].resources.push('pods'); },
    'exec into a pod': (r) => { r.rules[1].resources.push('pods/exec'); },
    'secrets': (r) => { r.rules.push({apiGroups: [''], resources: ['secrets'], verbs: ['get']}); },
    'a wildcard resource': (r) => { r.rules[0].resources = ['*']; },
  })) {
    const planted = structuredClone(role);
    edit(planted);
    assert.notDeepEqual(grants(planted), EXPECTED, `PLANTED DEFECT: ${name} is caught`);
  }
  const binding = docs.find((d) => d.kind === 'RoleBinding' && d.metadata.name === 'ci-report-read');
  assert.deepEqual(binding.subjects, [{kind: 'ServiceAccount', name: 'pipeline-sa', namespace: 'shop-build'}]);
  assert.deepEqual([binding.roleRef.kind, binding.roleRef.name, role.metadata.namespace], ['Role', 'ci-report-read', 'shop-build']);
});

test('only the report pod of a ci run reaches the API server and Alertmanager, and only Alertmanager on port 9093', () => {
  const nodeCidr = JSON.parse(execFileSync('yq', ['-o=json', '.global.nodeCidrs[0]', 'scripts/standin/cluster-map.yaml'], {encoding: 'utf8'}));
  const policies = (docs) => docs.filter((d) => d.kind === 'NetworkPolicy');
  const selects = (policy, labels) => Object.entries(policy.spec.podSelector.matchLabels ?? {}).every(([key, value]) => labels[key] === value);
  const rulesFor = (docs, task) => policies(docs).filter((policy) => selects(policy, {'tekton.dev/pipelineTask': task})).flatMap((policy) => policy.spec.egress ?? []);
  const reachesApiServer = (docs, task) => rulesFor(docs, task).some((rule) => (rule.to ?? []).some((to) => to.ipBlock?.cidr === nodeCidr && !to.ipBlock.except) &&
    (!rule.ports || rule.ports.some((port) => [443, 6443, 16443].includes(port.port))));
  const mentionsAlertmanager = (rule) => (rule.to ?? []).some((to) => to.namespaceSelector?.matchLabels?.['kubernetes.io/metadata.name'] === 'observability');
  const reachesAlertmanager = (docs, task) => rulesFor(docs, task).some(mentionsAlertmanager);
  // Alertmanager's pods and its one port: a namespace alone, or any other port, is wider.
  const alertmanagerRulesAreNarrow = (docs, task) => rulesFor(docs, task).filter(mentionsAlertmanager).every((rule) =>
    rule.to.every((to) => Object.keys(to.podSelector?.matchLabels ?? {}).length > 0) && JSON.stringify(rule.ports) === JSON.stringify([{protocol: 'TCP', port: 9093}]));
  const CI_TASKS = ['gate', 'clone', 'describe-commit', 'fetch', 'check'];
  const holds = (docs) => reachesApiServer(docs, 'report-failure') && reachesAlertmanager(docs, 'report-failure') && alertmanagerRulesAreNarrow(docs, 'report-failure') &&
    CI_TASKS.every((task) => !reachesApiServer(docs, task) && !reachesAlertmanager(docs, task));
  const docs = renderUnit('shop');
  assert.ok(holds(docs), 'PLANTED INNOCENT: the pinhole of the report pod, and no other, as rendered');
  const planted = (edit) => { const copy = structuredClone(docs); edit(policies(copy).find((p) => p.metadata.name === 'ci-report-egress'), copy); return copy; };
  const buildEgress = (copy) => policies(copy).find((p) => p.metadata.name === 'build-egress');
  const rulesOfReport = (policy) => policy.spec.egress;
  assert.ok(!holds(planted((policy) => { policy.spec.podSelector.matchLabels['tekton.dev/pipelineTask'] = 'check'; })), 'PLANTED DEFECT: the pinhole selects the check pod');
  assert.ok(!holds(planted((policy) => { policy.spec.podSelector = {}; })), 'PLANTED DEFECT: the pinhole selects every pod of the namespace');
  assert.ok(!holds(planted((policy) => { delete rulesOfReport(policy)[1].to[0].podSelector; })), 'PLANTED DEFECT: Alertmanager is opened to the whole namespace of observability');
  assert.ok(!holds(planted((policy) => { rulesOfReport(policy)[1].ports[0].port = 9094; })), 'PLANTED DEFECT: another port of Alertmanager');
  assert.ok(!holds(planted((policy) => { rulesOfReport(policy)[1].ports.push({protocol: 'TCP', port: 9090}); })), 'PLANTED DEFECT: a second port of observability');
  assert.ok(!holds(planted((policy) => { delete rulesOfReport(policy)[1].ports; })), 'PLANTED DEFECT: every port of Alertmanager');
  assert.ok(!holds(planted((policy, copy) => { buildEgress(copy).spec.egress.push(structuredClone(rulesOfReport(policy)[1])); })), 'PLANTED DEFECT: 9093 placed in build-egress reaches every pod');
  assert.ok(!holds(planted((policy, copy) => { buildEgress(copy).spec.egress.push(structuredClone(rulesOfReport(policy)[0])); })), 'PLANTED DEFECT: the API server placed in build-egress reaches every pod');
  assert.ok(!holds(planted((policy) => { rulesOfReport(policy)[0].ports = [{protocol: 'TCP', port: 22}]; })), 'PLANTED DEFECT: the API server rule on the wrong port reaches nothing');
});

test('no step of the ci pipeline or of the clone traces its commands', () => {
  const traces = (doc) => /\bset\s+-[A-Za-z]*x|xtrace|GIT_TRACE|GIT_CURL_VERBOSE/.test(JSON.stringify(doc).replaceAll('\\n', '\n'));
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const clone = imageBuilder().find((d) => d.kind === 'Task' && d.metadata.name === 'git-clone');
  assert.ok(!traces(pipeline) && !traces(clone), 'PLANTED INNOCENT: the pipeline and the clone as rendered');
  for (const trace of ['set -eux', 'set -x', 'set -o xtrace', 'export GIT_TRACE=1', 'GIT_TRACE_CURL=1']) {
    const plantedPipeline = structuredClone(pipeline), plantedClone = structuredClone(clone);
    plantedPipeline.spec.tasks[0].taskSpec.steps[0].script += `\n${trace}\n`;
    plantedClone.spec.steps[0].script += `\n${trace}\n`;
    assert.ok(traces(plantedPipeline) && traces(plantedClone), `PLANTED DEFECT: ${trace} would print the clone credential into a log the failure mail quotes`);
  }
});
