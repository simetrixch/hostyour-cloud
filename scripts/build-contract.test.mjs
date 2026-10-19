import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, copyFileSync, existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {immutableChanges, probeImmutableChanges} from './check-immutable.mjs';
import {renderChart} from './render-chart.mjs';

test('no Tekton test resources are rendered and production readers remain', () => {
  const builder = renderChart('image-builder');
  assert.ok(!builder.some(d => d.kind === 'PipelineRun' || (d.kind === 'CronJob' && d.metadata.name !== 'release-queue') ||
    d.metadata.name.includes('test-reporter') || d.metadata.name.includes('test-pruner') ||
    (d.kind === 'Task' && d.metadata.name.startsWith('test-')) || d.metadata.name.endsWith('-test-push')));
  assert.deepEqual(builder.find(d => d.kind === 'EventListener').spec.triggers,
    [{triggerRef: 'github-deploy-request'}, {triggerRef: 'github-ci-push'}, {triggerRef: 'github-release-publish'},
      {triggerRef: 'forgejo-tag-push'}, {triggerRef: 'forgejo-pull-request'}]);
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
      assert.deepEqual(docs.find(d => d.kind === 'ServiceAccount' && d.metadata.name === 'pipeline-sa').imagePullSecrets,
        builds.length === 0 ? undefined : [{name: 'build-registry-pull'}], record.name + ' lists the kubelet pull secret of its release images only where it builds');
      const readers = docs.filter(d => d.kind === 'ExternalSecret');
      if (builds.length === 0) assert.deepEqual(readers.map(d => d.metadata.name).sort(), ['build-git-https', 'build-issues-read', 'build-npmrc', 'image-builder-registry-push'],
        record.name + ' holds the credentials of its ci check and of its publish push, and no pull or bump credential');
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
  assert.equal(webhook.metadata.labels['pipeline.tekton.dev/release'], 'v1.17.0');
  assert.ok(webhook.webhooks.every(h => h.failurePolicy === 'Fail'));
});

// The ci pipeline runs a repository's own check on every push of its default branch or of a `ci/`
// branch. What keeps it from being a release, from holding a credential it must not, and from
// running anywhere else is asserted here on the rendered charts; the admission policy and the
// trigger filters are evaluated by scripts/vap-eval, which runs the CEL library the build plane runs.
const evaluate = (policy, requests) => execFileSync('go', ['run', '.'], {cwd: 'scripts/vap-eval', encoding: 'utf8',
  input: JSON.stringify({policy, requests})}).split('\n').filter(Boolean).map((line) => JSON.parse(line));
// The overlays and the filter of a Trigger's cel interceptor, and whether the filter takes each push body, evaluated
// with the library the build plane runs. `edit` rewrites the filter, to plant a defect in it.
const triggerOf = (docs, name) => {
  const cel = docs.find((d) => d.kind === 'Trigger' && d.metadata.name === name).spec.interceptors.find((i) => i.ref.name === 'cel').params;
  return {overlays: cel.find((p) => p.name === 'overlays').value, filter: cel.find((p) => p.name === 'filter').value};
};
const triggerMatches = (docs, name, bodies, edit = (filter) => filter) => {
  const {overlays, filter} = triggerOf(docs, name);
  const policy = {spec: {variables: overlays.map((o) => ({name: o.key, expression: o.expression})),
    validations: [{expression: edit(filter), message: 'ignored'}]}};
  return evaluate(policy, bodies.map((body) => ({body}))).map((v) => ({matched: v.denied.length === 0, overlays: v.variables}));
};
const renderUnit = (name, builds = ['app']) => renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name,
  repoURL: `https://github.com/check/${name}.git`, buildsJson: JSON.stringify(builds)})]);
// The ci Pipeline runs in one pod: its one task `ci` holds the steps, which run one after the other.
const CI_STEPS = ['gate', 'earlier-green', 'commit-status-pending', 'clone', 'describe', 'list-sources', 'list-tools', 'sources', 'hand-over', 'check'];
const ciTaskSpec = (pipeline) => pipeline.spec.tasks.find((t) => t.name === 'ci').taskSpec;
const ciStep = (pipeline, name) => pipeline.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === name);
const imageBuilder = () => renderChart('image-builder');
// What a TriggerTemplate creates, with the trigger's parameters filled in.
const createdRun = (docs, template) => JSON.parse(JSON.stringify(docs.find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === template).spec.resourcetemplates[0])
  .replaceAll('$(tt.params.unit)', 'shop').replace(/\$\(tt\.params\.[a-z-]+\)/g, 'x'));
const createdCiRun = (docs) => createdRun(docs, 'ci-push');
const guardOf = (docs) => docs.find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');

const OWNERSHIP = 'a build namespace runs only its own release, ci, image and publish Pipelines.';
const WORKSPACE = 'a ci run is created with no workspace and an update leaves its workspaces as they were, its one pod keeps the checkout on a volume of its own task; every other managed run uses only a new source PVC, with no secret, projected, CSI or shared-claim workspace.';
const EVENT_LISTENER = 'system:serviceaccount:image-builder:eventlistener-sa';
const RELEASE_CLASS = 'image-builder-release', CI_CLASS = 'image-builder-ci', REPORT_CLASS = 'image-builder-ci-report';
const classOf = (pipeline) => (pipeline.endsWith('-ci') ? CI_CLASS : RELEASE_CLASS);
// podTemplate null leaves the template out. A ci run carries no workspace (its one pod keeps the checkout on a volume of its own
// task); every other managed run carries the one `source` claim. `workspaces` replaces that default, and null leaves them out.
const SOURCE_CLAIM = [{name: 'source', volumeClaimTemplate: {spec: {accessModes: ['ReadWriteOnce']}}}];
const createsRun = (namespace, pipeline, podTemplate = {priorityClassName: classOf(pipeline)}, workspaces = pipeline.endsWith('-ci') ? null : SOURCE_CLAIM) => ({object: {metadata: {namespace, labels: {'image-builder.io/ci': 'shop'}},
  spec: {pipelineRef: {name: pipeline}, taskRunTemplate: {serviceAccountName: 'pipeline-sa', ...(podTemplate ? {podTemplate} : {})},
    ...(workspaces ? {workspaces} : {})}},
  oldObject: null, request: {operation: 'CREATE', namespace, userInfo: {username: EVENT_LISTENER}}});

test('the admission policy admits the release, the ci, the image and the publish pipeline of a unit in its own build namespace, and nothing else', () => {
  const policy = guardOf(imageBuilder());
  const ADMITTED = ['shop-release', 'shop-ci', 'shop-image', 'shop-publish'];
  const DENIED = ['post-ci', 'post-release', 'post-image', 'post-publish', 'shop-image-extra', 'shop-ci-extra', 'shop-publish-extra', 'shop-tests', 'shop', 'ci', 'release', 'image', 'publish'];
  const verdicts = evaluate(policy, [...ADMITTED, ...DENIED].map((name) => createsRun('shop-build', name))).map((v) => v.denied);
  ADMITTED.forEach((name, i) => assert.deepEqual(verdicts[i], [], `PLANTED INNOCENT: ${name} in shop-build`));
  DENIED.forEach((name, i) => assert.deepEqual(verdicts[ADMITTED.length + i], [OWNERSHIP], `PLANTED DEFECT: ${name} in shop-build`));
  // The refusal is the ownership clause's: without it the foreign ci pipeline is admitted.
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => v.message !== OWNERSHIP);
  assert.deepEqual(evaluate(without, [createsRun('shop-build', 'post-ci')])[0].denied, []);
  // A ci run carries no workspace: its checkout is on a volume of its own task, and a claim would be a volume on the node that
  // outlives nothing and costs a second of binding. Every other managed run keeps its one `source` claim.
  const workspaceVerdict = (pipeline, workspaces) => evaluate(policy, [createsRun('shop-build', pipeline, undefined, workspaces)])[0].denied;
  assert.deepEqual(workspaceVerdict('shop-ci', SOURCE_CLAIM), [WORKSPACE], 'PLANTED DEFECT: a ci run with the source claim');
  assert.deepEqual(workspaceVerdict('shop-ci', [{name: 'source', emptyDir: {}}]), [WORKSPACE], 'PLANTED DEFECT: a ci run with an emptyDir workspace');
  assert.deepEqual(workspaceVerdict('shop-ci', null), [], 'PLANTED INNOCENT: a ci run without a workspace');
  for (const pipeline of ['shop-release', 'shop-image', 'shop-publish']) {
    assert.deepEqual(workspaceVerdict(pipeline, SOURCE_CLAIM), [], `PLANTED INNOCENT: ${pipeline} with the one source claim`);
    assert.deepEqual(workspaceVerdict(pipeline, null), [WORKSPACE], `PLANTED DEFECT: ${pipeline} without its source claim`);
    assert.deepEqual(workspaceVerdict(pipeline, [{name: 'source', emptyDir: {}}]), [WORKSPACE], `PLANTED DEFECT: ${pipeline} with an emptyDir workspace`);
  }
  // The Tekton controller keeps updating a ci run it started.
  const run = createsRun('shop-build', 'shop-ci');
  const update = {...run, oldObject: run.object, request: {operation: 'UPDATE', namespace: 'shop-build',
    userInfo: {username: 'system:serviceaccount:tekton:tekton-controller'}}};
  assert.deepEqual(evaluate(policy, [update])[0].denied, []);
});

test('the run the ci trigger creates is admitted, is no release, and the trigger takes a push of the default branch or a ci/ branch only', () => {
  // The ci list names the repositories of the table below, so the clauses around it decide each push.
  const builder = renderChart('image-builder', ['--set-json', 'ciPush.repositories=["digitaplatform/shop","simetrixch/ansiwise-core"]']);
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

  const trigger = (name) => triggerOf(builder, name);
  const matches = (name, bodies, edit) => triggerMatches(builder, name, bodies, edit);
  // GitHub sends the repository's default branch with every push (repository.default_branch); `main` here, so a
  // filter that names `master` instead of reading it is seen.
  // Every repository is public unless a push says otherwise, so the repository clause is what refuses the customer's and the outsider's.
  const repository = {name: 'Shop', clone_url: 'https://github.com/digitaplatform/shop.git', owner: {login: 'digitaplatform'}, default_branch: 'main', visibility: 'public'};
  const customer = {name: 'swissbookai', clone_url: 'https://github.com/ahkutun/swissbookai.git', owner: {login: 'ahkutun'}, default_branch: 'main', visibility: 'public'};
  const outsider = {name: 'tool', clone_url: 'https://github.com/someone-else/tool.git', owner: {login: 'someone-else'}, default_branch: 'main', visibility: 'public'};
  const platform = {name: 'ansiwise-core', clone_url: 'https://github.com/simetrixch/ansiwise-core.git', owner: {login: 'simetrixch'}, default_branch: 'master', visibility: 'public'};
  const {visibility: _public, ...undeclared} = repository;
  const privateRepository = {...repository, visibility: 'private'};
  const SHA = 'a'.repeat(40);
  const tag = '0.8.446-stable-20261009014252';
  const pushes = {
    'a push of an issue branch': {ref: 'refs/heads/issue-1-fix', after: SHA, deleted: false, repository},
    'a push of the default branch without the deleted field': {ref: 'refs/heads/main', after: SHA, repository},
    'a deploy tag push': {ref: `refs/tags/deploy/prod/${tag}`, after: SHA, deleted: false, repository},
    'a push of a delivery branch': {ref: 'refs/heads/deploy/prod', after: SHA, deleted: false, repository},
    'a branch named like a deploy tag': {ref: `refs/heads/deploy/prod/${tag}`, after: SHA, deleted: false, repository},
    // A repository whose default branch is the books branch, or a sibling of it.
    'a push of the books branch': {ref: 'refs/heads/check.example.invalid', after: SHA, deleted: false,
      repository: {...repository, default_branch: 'check.example.invalid'}},
    'a branch whose name begins with the books branch': {ref: 'refs/heads/check.example.invalid-fix', after: SHA, deleted: false,
      repository: {...repository, default_branch: 'check.example.invalid-fix'}},
    'another tag push': {ref: 'refs/tags/v1.0.0', after: SHA, deleted: false, repository},
    'a branch deletion': {ref: 'refs/heads/ci/issue-1-planted-1', after: '0'.repeat(40), deleted: true, repository},
    'a branch deletion without the deleted field': {ref: 'refs/heads/ci/issue-1-planted-1', after: '0'.repeat(40), repository},
    'a deploy tag deletion': {ref: `refs/tags/deploy/prod/${tag}`, after: '0'.repeat(40), deleted: true, repository},
    'a branch push of a customer repository': {ref: 'refs/heads/main', after: SHA, deleted: false, repository: customer},
    'a branch push of an owner that is not listed': {ref: 'refs/heads/main', after: SHA, deleted: false, repository: outsider},
    'a deploy tag push of a customer repository': {ref: `refs/tags/deploy/prod/${tag}`, after: SHA, deleted: false, repository: customer},
    'a deploy tag push of an owner that is not listed': {ref: `refs/tags/deploy/prod/${tag}`, after: SHA, deleted: false, repository: outsider},
    'a release tag push': {ref: `refs/tags/${tag}`, after: SHA, deleted: false, repository},
    'a release tag push of a customer repository': {ref: `refs/tags/${tag}`, after: SHA, deleted: false, repository: customer},
    'a release tag deletion': {ref: `refs/tags/${tag}`, after: '0'.repeat(40), deleted: true, repository},
    'a release tag with a suffix': {ref: `refs/tags/${tag}-x`, after: SHA, deleted: false, repository},
    'a branch named like a release tag': {ref: `refs/heads/${tag}`, after: SHA, deleted: false, repository},
    'a branch push of the owner of this platform': {ref: 'refs/heads/master', after: SHA, deleted: false, repository: platform},
    'a deploy tag push of the owner of this platform': {ref: `refs/tags/deploy/prod/${tag}`, after: SHA, deleted: false, repository: platform},
    'a push of master where the default branch is main': {ref: 'refs/heads/master', after: SHA, deleted: false, repository},
    'a push of a ci/ branch': {ref: 'refs/heads/ci/issue-1-planted-1', after: SHA, deleted: false, repository},
    'a branch with ci/ inside its name': {ref: 'refs/heads/feature/ci/x', after: SHA, deleted: false, repository},
    // A repository that is not public runs no check here: its push gate is the only check of a private repository.
    'a push of the default branch of a private repository': {ref: 'refs/heads/main', after: SHA, deleted: false, repository: privateRepository},
    'a push of a ci/ branch of a private repository': {ref: 'refs/heads/ci/issue-1-planted-1', after: SHA, deleted: false, repository: privateRepository},
    'a push of the default branch of an internal repository': {ref: 'refs/heads/main', after: SHA, deleted: false, repository: {...repository, visibility: 'internal'}},
    'a push of the default branch of a repository whose payload names no visibility': {ref: 'refs/heads/main', after: SHA, deleted: false, repository: undeclared},
    // The release of a private repository is not touched: its deploy tag and its release tag still run.
    'a deploy tag push of a private repository': {ref: `refs/tags/deploy/prod/${tag}`, after: SHA, deleted: false, repository: privateRepository},
    'a release tag push of a private repository': {ref: `refs/tags/${tag}`, after: SHA, deleted: false, repository: privateRepository},
  };
  // GitHub sends `before` with every push; a deletion carries the deleted commit there.
  const BEFORE = 'b'.repeat(40);
  for (const push of Object.values(pushes)) push.before = BEFORE;
  const bodies = Object.values(pushes);
  const ci = matches('github-ci-push', bodies), deploy = matches('github-deploy-request', bodies), publish = matches('github-release-publish', bodies);
  const verdicts = {ci: [false, true, false, false, false, false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, true, false, false, false, false, false, false, false],
    deploy: [false, false, true, false, false, false, false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, true, false, false, false, false, false, false, false, true, false],
    publish: [false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, false, false, false, false, false, false, false, true]};
  Object.keys(pushes).forEach((name, i) => {
    assert.equal(ci[i].matched, verdicts.ci[i], `${name} on the ci trigger`);
    assert.equal(deploy[i].matched, verdicts.deploy[i], `${name} on the deploy trigger`);
    assert.equal(publish[i].matched, verdicts.publish[i], `${name} on the publish trigger`);
  });
  assert.deepEqual(publish[15].overlays, {unit: 'shop', 'release-tag': tag, 'git-url': repository.clone_url});
  // PLANTED DEFECT: a publish filter without the deletion guard, and one without its end anchor.
  assert.ok(matches('github-release-publish', [pushes['a release tag deletion']], (filter) => filter.replace(/ &&\s+!\(has\(body\.deleted\).*$/s, ''))[0].matched);
  assert.ok(matches('github-release-publish', [pushes['a release tag with a suffix']], (filter) => filter.replace("$')", "')"))[0].matched);
  // The publish run waits in the release queue under a key of its own, and carries no consumer label: the
  // Manager's release watch selects release runs by it.
  const publishRun = byKind('TriggerTemplate', 'release-publish').spec.resourcetemplates[0];
  assert.equal(publishRun.metadata.generateName, '$(tt.params.unit)-publish-');
  assert.equal(publishRun.metadata.namespace, '$(tt.params.unit)-build');
  assert.equal(publishRun.spec.pipelineRef.name, '$(tt.params.unit)-publish');
  assert.equal(publishRun.spec.status, 'PipelineRunPending', 'a publish run waits for the release queue');
  assert.deepEqual(publishRun.metadata.labels, {'image-builder.io/publish': '$(tt.params.unit)'});
  assert.equal(publishRun.spec.taskRunTemplate.podTemplate.priorityClassName, RELEASE_CLASS);
  assert.equal(publishRun.spec.taskRunSpecs, undefined, 'a publish run carries no per-task override');
  assert.deepEqual(byKind('TriggerBinding', 'github-release-publish-binding').spec.params.map((p) => p.name), ['unit', 'release-tag', 'git-url']);
  assert.deepEqual(evaluate(guardOf(builder), [{object: createdRun(builder, 'release-publish'), oldObject: null,
    request: {operation: 'CREATE', namespace: 'shop-build', userInfo: {username: EVENT_LISTENER}}}])[0].denied, [], 'PLANTED INNOCENT: the publish run is admitted');
  assert.deepEqual(ci[23].overlays, {unit: 'shop', branch: 'ci/issue-1-planted-1', commit: SHA, before: BEFORE, 'git-url': repository.clone_url});
  // The commit before the push travels from the webhook to the run's parameter, and the check reads that parameter.
  assert.equal(byKind('TriggerBinding', 'github-ci-push-binding').spec.params.find((p) => p.name === 'before')?.value, '$(extensions.before)');
  assert.ok(byKind('TriggerTemplate', 'ci-push').spec.params.some((p) => p.name === 'before'));
  assert.equal(template.spec.params.find((p) => p.name === 'before')?.value, '$(tt.params.before)');
  // PLANTED DEFECT: a filter without the deletion guards, and one that takes every ref, each match a push they must not.
  const unguarded = (filter) => filter.replace(/ &&\s+!\(has\(body\.deleted\).*$/s, '');
  assert.ok(matches('github-ci-push', [pushes['a branch deletion']], unguarded)[0].matched);
  const anyRepository = (filter) => filter.replace(/ && \(body\.repository\.owner\.login \+ '\/' \+ body\.repository\.name\)\.lowerAscii\(\) in \[[^\]]*\]$/, '');
  assert.notEqual(anyRepository(trigger('github-ci-push').filter), trigger('github-ci-push').filter);
  assert.ok(matches('github-ci-push', [pushes['a branch push of a customer repository']], anyRepository)[0].matched);
  assert.ok(matches('github-ci-push', [pushes['a branch push of an owner that is not listed']], anyRepository)[0].matched);
  // Only a listed repository runs: one of a listed owner that the list does not name has no suites its push gate leaves out.
  const unlisted = {ref: 'refs/heads/main', before: BEFORE, after: SHA, deleted: false, repository: {...repository, name: 'other', clone_url: 'https://github.com/digitaplatform/other.git'}};
  assert.equal(matches('github-ci-push', [unlisted])[0].matched, false, 'PLANTED INNOCENT: a public repository of a listed owner that the list does not name runs nothing');
  assert.ok(matches('github-ci-push', [unlisted], anyRepository)[0].matched, 'PLANTED DEFECT: a filter without the repository clause runs it');
  // GitHub compares names in any case: the push names Shop, the list digitaplatform/shop.
  const caseSensitive = (filter) => filter.replace(".lowerAscii() in [", " in [");
  assert.notEqual(caseSensitive(trigger('github-ci-push').filter), trigger('github-ci-push').filter);
  assert.equal(matches('github-ci-push', [pushes['a push of the default branch without the deleted field']], caseSensitive)[0].matched, false,
    'PLANTED DEFECT: a comparison in the case of the push misses the listed Shop');
  // The trigger takes the GitHub event `push` and no other, so a pull request from a fork starts nothing.
  const withoutPlatform = (filter) => filter.replace("in ['digitaplatform/shop', 'simetrixch/ansiwise-core']", "in ['digitaplatform/shop']");
  assert.notEqual(withoutPlatform(trigger('github-ci-push').filter), trigger('github-ci-push').filter);
  assert.equal(matches('github-ci-push', [pushes['a branch push of the owner of this platform']], withoutPlatform)[0].matched, false,
    'PLANTED DEFECT: a list without the repository runs no check of it');
  const github = byKind('Trigger', 'github-ci-push').spec.interceptors.find((i) => i.ref.name === 'github').params;
  assert.deepEqual(github.find((p) => p.name === 'eventTypes').value, ['push'], 'the ci trigger takes push events only');
  const withBooksBranch = (filter) => filter.replace(/ &&\s+body\.ref != 'refs\/heads\/[^']*'/, '');
  assert.ok(matches('github-ci-push', [pushes['a push of the books branch']], withBooksBranch)[0].matched,
    'PLANTED DEFECT: a filter without the books branch exclusion runs the check on every commit of the Manager');
  // PLANTED DEFECTS of the refs the ci runs for: the filter as it stood before (every branch), a default branch named
  // instead of read from the push, and a ci/ that is not anchored at the start of the branch name. Each edit must
  // change the filter, and each edited filter matches a push the trigger refuses.
  const takenRefs = "(body.ref == 'refs/heads/' + body.repository.default_branch || body.ref.startsWith('refs/heads/ci/'))";
  const planted = {
    'the old filter runs the ci for every issue branch': [(filter) => filter.replace(takenRefs, "body.ref.startsWith('refs/heads/')"), 'a push of an issue branch'],
    'a filter that names master runs the ci for a branch that is not the default': [(filter) => filter.replace("'refs/heads/' + body.repository.default_branch", "'refs/heads/master'"), 'a push of master where the default branch is main'],
    'a ci/ that is not anchored runs the ci for a branch that only contains it': [(filter) => filter.replace("body.ref.startsWith('refs/heads/ci/')", "body.ref.contains('/ci/')"), 'a branch with ci/ inside its name'],
  };
  for (const [defect, [edit, push]] of Object.entries(planted)) {
    assert.notEqual(edit(trigger('github-ci-push').filter), trigger('github-ci-push').filter, `PLANTED DEFECT: ${defect}: the edit finds its clause`);
    assert.ok(matches('github-ci-push', [pushes[push]], edit)[0].matched, `PLANTED DEFECT: ${defect}`);
  }
  // PLANTED DEFECTS of the visibility clause: a filter without it runs the check of a private repository, and a filter that only
  // refuses `private` runs it for the values GitHub may add (`internal`) and for a payload that names none. Each edit must change
  // the filter, and each edited filter matches a push the trigger refuses.
  const publicOnly = "has(body.repository.visibility) && body.repository.visibility == 'public'";
  assert.ok(trigger('github-ci-push').filter.includes(`${publicOnly} && `), 'the filter reads the visibility of the repository, fail closed');
  const refusesPrivateOnly = (filter) => filter.replace(publicOnly, "!(has(body.repository.visibility) && body.repository.visibility == 'private')");
  const visibility = {
    'a filter without the visibility clause runs the check of a private repository': [(filter) => filter.replace(`${publicOnly} && `, ''), ['a push of the default branch of a private repository', 'a push of a ci/ branch of a private repository']],
    'a filter that refuses only private repositories runs the check of an internal one': [refusesPrivateOnly, ['a push of the default branch of an internal repository']],
    'a filter that refuses only private repositories runs the check where the payload names no visibility': [refusesPrivateOnly, ['a push of the default branch of a repository whose payload names no visibility']],
  };
  for (const [defect, [edit, names]] of Object.entries(visibility)) {
    assert.notEqual(edit(trigger('github-ci-push').filter), trigger('github-ci-push').filter, `PLANTED DEFECT: ${defect}: the edit finds its clause`);
    for (const name of names) {
      assert.equal(matches('github-ci-push', [pushes[name]])[0].matched, false, `PLANTED INNOCENT: ${name} runs no check`);
      assert.ok(matches('github-ci-push', [pushes[name]], edit)[0].matched, `PLANTED DEFECT: ${defect}`);
    }
  }
  // The release of a private repository goes through the deploy and the publish trigger as before: neither reads the visibility.
  assert.ok(!trigger('github-deploy-request').filter.includes('visibility'), 'the deploy trigger does not read the visibility');
  assert.ok(!trigger('github-release-publish').filter.includes('visibility'), 'the publish trigger does not read the visibility');
});

// A release moves a pin by committing the new tag into clusters/inventories/<app>/values-<stage>.yaml of the default
// branch, after the release itself ran the check on the commit it pins, and it commits as the identity its bump sets
// (ciPush.pinIdentity, held equal to the bump below). That push is not run again: the filter reads who authored and
// committed each commit and the files it changes, which the webhook lists as paths, and never its subject. It skips the
// push only when every commit of it comes from that identity and modifies pin files and nothing else, so a person's commit
// to a pin file, or one other file in any commit, starts the run. Whatever the webhook does not state well enough to tell
// is run: a commit with no listed path or no author, a push without a commits list, a push whose list may be cut short,
// and a forced push, whose listed commits are only the new ones while it drops the commits it rewound.
test('the identity the ci trigger takes for a release pin is the one the release bump commits with', () => {
  const identity = JSON.parse(execFileSync('yq', ['-o=json', '.ciPush.pinIdentity', 'clusters/inventories/image-builder/values-common.yaml'], {encoding: 'utf8'}));
  const release = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release');
  const bump = release.spec.tasks.flatMap((t) => t.taskSpec?.steps ?? []).map((step) => step.script ?? '').join('\n');
  const sets = (script) => [/git config --global user\.name\s+"([^"]+)"/.exec(script)?.[1], /git config --global user\.email\s+"([^"]+)"/.exec(script)?.[1]];
  assert.deepEqual(sets(bump), [identity.name, identity.email], 'the bump commits as the identity the trigger names');
  assert.notDeepEqual(sets(bump.replace('"image-builder@platform"', '"someone@example.com"')), [identity.name, identity.email], 'PLANTED DEFECT: a bump that commits as another identity is caught');
});

test('a push of the default branch that only moves release pins starts no ci run, and any other change in the push does', () => {
  const builder = imageBuilder();
  const SHA = 'a'.repeat(40), BEFORE = 'b'.repeat(40);
  const repository = {name: 'hostyour-cloud', clone_url: 'https://github.com/simetrixch/hostyour-cloud.git', owner: {login: 'simetrixch'}, default_branch: 'master', visibility: 'public'};
  const bump = JSON.parse(execFileSync('yq', ['-o=json', '.ciPush.pinIdentity', 'clusters/inventories/image-builder/values-common.yaml'], {encoding: 'utf8'}));
  const person = {name: 'Mehmet', email: 'mehmet@example.com'};
  const commit = (modified, {added = [], removed = [], message = 'release: manager 0.8.497-stable-20261015010114 — pin 0.8.497-stable-20261015010114-72bca23 (prod)', author = bump, committer = bump} = {}) =>
    ({id: SHA, message, added, removed, modified, author, committer});
  const push = (commits, ref = 'refs/heads/master', forced = false) => ({ref, before: BEFORE, after: SHA, deleted: false, forced, repository, ...(commits ? {commits} : {})});
  const MANAGER = 'clusters/inventories/manager/values-prod.yaml', GATE_RUNNER = 'clusters/inventories/gate-runner/values-test.yaml';
  const pins = commit([MANAGER, GATE_RUNNER]);
  const filter = triggerOf(builder, 'github-ci-push').filter;
  const lookalikes = ['clusters/inventories/manager/values-prod.yaml.bak', 'clusters/inventories/manager/values-common.yaml', 'clusters/inventories/manager/values-staging.yaml',
    'clusters/inventories/manager/templates/values-prod.yaml', 'clusters/inventories/values-prod.yaml', 'tools/clusters/inventories/manager/values-prod.yaml',
    'clusters/inventories/manager/Chart.yaml', 'clusters/platform/values-prod.yaml'];
  // Each push of the table and whether it starts a run.
  const pushes = {
    'PLANTED INNOCENT: one pin commit': [push([pins]), false],
    'PLANTED INNOCENT: two pin commits': [push([pins, commit([MANAGER])]), false],
    'PLANTED INNOCENT: 19 pin commits': [push(Array.from({length: 19}, () => pins)), false],
    'a pin file under a subject that does not say pin': [push([commit([MANAGER], {message: 'Fix the manager pin by hand'})]), false],
    "a person's commit to a pin file, under a pin subject": [push([commit([MANAGER], {author: person, committer: person})]), true],
    "a person's commit to a pin file, as the bump's name with another address": [push([commit([MANAGER], {author: {...bump, email: person.email}, committer: {...bump, email: person.email}})]), true],
    "a person's commit to a pin file, as the bump's address with another name": [push([commit([MANAGER], {author: {...bump, name: person.name}, committer: {...bump, name: person.name}})]), true],
    "a commit that the bump authored and a person committed": [push([commit([MANAGER], {committer: person})]), true],
    "a commit that a person authored and the bump committed": [push([commit([MANAGER], {author: person})]), true],
    "a person's commit among pin commits of the bump": [push([pins, commit([MANAGER], {author: person, committer: person})]), true],
    'a commit without its author': [push([{id: SHA, message: 'x', added: [], removed: [], modified: [MANAGER], committer: bump}]), true],
    'a pin file and one other file in one commit': [push([commit([MANAGER, 'clusters/platform/versions.yaml'])]), true],
    'a pin commit and a commit of another file': [push([pins, commit(['README.md'])]), true],
    'a commit of another file': [push([commit(['scripts/check.sh'])]), true],
    'a pin subject on another file': [push([commit(['scripts/check.sh'], {message: 'release: manager 0.8.497 — pin 0.8.497-stable (prod)'})]), true],
    'a pin file that is added': [push([commit([MANAGER], {added: ['clusters/inventories/manager/values-dev.yaml']})]), true],
    'a pin file that is removed': [push([commit([MANAGER], {removed: ['clusters/inventories/manager/values-dev.yaml']})]), true],
    ...Object.fromEntries(lookalikes.map((path) => [`${path}, which is no pin file`, [push([commit([path])]), true]])),
    'a commit with no listed path, which an extremely large commit has': [push([commit([])]), true],
    'a commit with no listed path among pin commits': [push([pins, commit([])]), true],
    'a push with no commit': [push([]), true],
    'a push without a commits list': [push(undefined), true],
    'a list of 20 commits, which may be cut short': [push(Array.from({length: 20}, () => pins)), true],
    'a commit without its added and removed lists': [push([{id: SHA, message: 'x', modified: [MANAGER]}]), true],
    'a pin commit on a ci/ branch, the deliberate run of any commit': [push([pins], 'refs/heads/ci/issue-387-pins'), true],
    'a pin commit on an issue branch, which no run takes': [push([pins], 'refs/heads/issue-387-fix'), false],
    'a forced push of pin commits, which drops the commits it rewound': [push([pins], 'refs/heads/master', true), true],
    'a forced push of a branch no run takes': [push([pins], 'refs/heads/issue-387-fix', true), false],
    'a push of pin commits whose forced field is absent': [(({forced, ...body}) => body)(push([pins])), false],
  };
  const verdicts = triggerMatches(builder, 'github-ci-push', Object.values(pushes).map(([body]) => body));
  Object.entries(pushes).forEach(([name, [, runs]], i) => assert.equal(verdicts[i].matched, runs, `${name} ${runs ? 'starts' : 'starts no'} run`));
  const runs = (body, edit) => triggerMatches(builder, 'github-ci-push', [body], edit)[0].matched;
  // PLANTED DEFECTS: each edit finds its clause and takes a push the filter must run for no run, or the reverse.
  const planted = {
    'the filter as it stood, without the pin clause': [(f) => f.replace("!(body.ref == 'refs/heads/' + body.repository.default_branch && !(has(body.forced) && body.forced) && has(body.commits)", '!(false && has(body.commits)'), push([pins]), false],
    'a pin clause for every branch, a ci/ branch among them': [(f) => f.replace("!(body.ref == 'refs/heads/' + body.repository.default_branch && !(has(body.forced) && body.forced) && has(body.commits)", '!(has(body.commits)'), push([pins], 'refs/heads/ci/issue-387-pins'), true],
    'a pin clause that takes an added file': [(f) => f.replace('size(c.added) == 0 && size(c.removed) == 0 && ', ''), push([commit([MANAGER], {added: ['clusters/inventories/manager/values-dev.yaml']})]), true],
    'a pin clause that is not anchored at the start': [(f) => f.replace("path.matches(r'^clusters/", "path.matches(r'clusters/"), push([commit(['tools/clusters/inventories/manager/values-prod.yaml'])]), true],
    'a pin clause that is not anchored at the end': [(f) => f.replace('[.]yaml$', '[.]yaml'), push([commit(['clusters/inventories/manager/values-prod.yaml.bak'])]), true],
    "a pin clause that does not read the author's name": [(f) => f.replace(' && c.author.name == ' + `'${bump.name}'`, ''), push([commit([MANAGER], {author: {...bump, name: person.name}})]), true],
    "a pin clause that does not read the author's address": [(f) => f.replace(' && c.author.email == ' + `'${bump.email}'`, ''), push([commit([MANAGER], {author: {...bump, email: person.email}})]), true],
    "a pin clause that does not read the committer's name": [(f) => f.replace(' && c.committer.name == ' + `'${bump.name}'`, ''), push([commit([MANAGER], {committer: {...bump, name: person.name}})]), true],
    "a pin clause that does not read the committer's address": [(f) => f.replace(' && c.committer.email == ' + `'${bump.email}'`, ''), push([commit([MANAGER], {committer: {...bump, email: person.email}})]), true],
    'a pin clause that takes a commit with no path': [(f) => f.replace(' && size(c.modified) > 0', ''), push([commit([])]), true],
    'a pin clause that needs one pin commit and not every commit': [(f) => f.replace('body.commits.all(c,', 'body.commits.exists(c,'), push([pins, commit(['README.md'])]), true],
    'a pin clause that does not read a forced push': [(f) => f.replace('!(has(body.forced) && body.forced) && ', ''), push([pins], 'refs/heads/master', true), true],
    'a pin clause with no limit on the commits': [(f) => f.replace(' && size(body.commits) < 20', ''), push(Array.from({length: 20}, () => pins)), true],
  };
  for (const [defect, [edit, body, expected]] of Object.entries(planted)) {
    assert.notEqual(edit(filter), filter, `PLANTED DEFECT: ${defect}: the edit finds its clause`);
    assert.equal(runs(body), expected, `PLANTED INNOCENT: ${defect}: the filter as it stands answers ${expected}`);
    assert.notEqual(runs(body, edit), expected, `PLANTED DEFECT: ${defect}`);
  }
});

test('the ci trigger needs a list of repositories, and an empty or missing list fails the render naming the key', () => {
  assert.throws(() => renderChart('image-builder', ['--set-json', 'ciPush={"repositories":[]}']), /ciPush\.repositories is required/);
  assert.throws(() => renderChart('image-builder', ['--set', 'ciPush=null']), /ciPush\.repositories is required/);
  const filter = renderChart('image-builder', ['--set-json', 'ciPush={"repositories":["One/A","two/b"],"pinIdentity":{"name":"pin","email":"pin@example.com"},"timeouts":{"pipeline":"2m0s","tasks":"1m0s","finally":"1m0s"}}'])
    .find((d) => d.kind === 'Trigger' && d.metadata.name === 'github-ci-push').spec.interceptors
    .find((i) => i.ref.name === 'cel').params.find((p) => p.name === 'filter').value;
  assert.ok(filter.endsWith("in ['one/a', 'two/b']"), 'every listed repository reaches the filter, in lower case');
  assert.throws(() => renderChart('image-builder', ['--set', 'global.booksCluster=']), /global\.booksCluster is required/);
});

test('the ci pipeline of a unit holds no GitOps credential, mounts only build-npmrc, and is no release', () => {
  const docs = renderUnit('shop');
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  assert.deepEqual(pipeline.spec.tasks.map((t) => t.name), ['ci']);
  assert.deepEqual(ciTaskSpec(pipeline).steps.map((s) => s.name), CI_STEPS);
  assert.deepEqual(pipeline.spec.finally.map((t) => t.name), ['report-failure', 'commit-status']);
  const referencesBump = (doc) => JSON.stringify(doc).includes('bump');
  assert.ok(!referencesBump(pipeline), 'the ci pipeline names no bump task, volume or secret');
  const planted = structuredClone(pipeline);
  planted.spec.tasks.find((t) => t.name === 'ci').taskSpec.volumes.push({name: 'bump', secret: {secretName: 'bump-git-https'}});
  assert.ok(referencesBump(planted), 'PLANTED DEFECT: a render that adds the bump volume is caught');
  const secrets = (doc) => [...JSON.stringify(doc).matchAll(/"(?:secretName|name)":"((?:build|bump)-[a-z-]+)"/g)].map((m) => m[1]).sort();
  assert.deepEqual([...new Set(secrets(pipeline))], ['build-git-https', 'build-issues-read', 'build-npmrc']);
  const check = ciStep(pipeline, 'check');
  assert.equal(check.envFrom, undefined, 'the check step holds no secret as environment');
  assert.equal(check.env.find((e) => e.name === 'CI')?.value, 'true', 'a check sees the variable GitHub Actions also sets');
  assert.equal(check.env.find((e) => e.name === 'CI_BEFORE_COMMIT')?.value, '$(params.before)', 'a check sees the commit the branch stood at before the push');
  assert.deepEqual(pipeline.spec.tasks[0].params.map((p) => p.name), ['commit', 'before', 'branch', 'git-url']);
  assert.ok(pipeline.spec.params.some((p) => p.name === 'before'));
  assert.deepEqual(ciTaskSpec(pipeline).volumes.filter((v) => v.secret).map((v) => v.secret.secretName), ['build-npmrc']);
  assert.deepEqual(check.volumeMounts.filter((m) => m.name === 'npmrc').map((m) => m.readOnly), [true]);
  // One pod holds the credential and the repository's code, so what keeps them apart is the mounts of the steps: the check
  // step mounts no clone credential and runs last, after every step that holds one.
  const holdersOf = (doc) => ciTaskSpec(doc).steps.filter((step) => JSON.stringify(step).includes('build-git-https')).map((step) => step.name);
  assert.deepEqual(holdersOf(pipeline), ['earlier-green', 'commit-status-pending', 'clone', 'sources']);
  assert.equal(ciTaskSpec(pipeline).steps.at(-1).name, 'check', 'the check runs after every step that holds a credential');
  const credentialInCheck = structuredClone(pipeline);
  ciStep(credentialInCheck, 'check').envFrom = [{secretRef: {name: 'build-git-https'}}];
  assert.ok(holdersOf(credentialInCheck).includes('check'), 'PLANTED DEFECT: a check step that mounts build-git-https is caught');
  const secretsOfCheck = (doc) => JSON.stringify(ciStep(doc, 'check'));
  assert.ok(secretsOfCheck(pipeline).includes('build-issues-read') && ciStep(pipeline, 'check').volumeMounts.some((m) => m.name === 'npmrc'),
    'PLANTED INNOCENT: the check step mounts build-npmrc and build-issues-read and holds no clone credential');
  assert.ok(!holdersOf(pipeline).includes('check'));
  assert.deepEqual(pipeline.spec.finally.filter((t) => JSON.stringify(t).includes('build-git-https')).map((t) => t.name), ['commit-status']);
  // Tekton copies a Pipeline's labels onto its runs: a consumer label here would make every ci run a release.
  assert.equal(pipeline.metadata.labels['image-builder.io/ci'], 'shop');
  assert.equal(pipeline.metadata.labels['image-builder.io/consumer'], undefined);
  assert.ok(docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release').metadata.labels['image-builder.io/consumer']);
  const grant = docs.find((d) => d.kind === 'Role' && d.metadata.name === 'eventlistener-create-pipelineruns');
  assert.ok(grant.rules.some((r) => r.resources.includes('pipelineruns') && r.verbs.includes('create')), 'the event listener may create the ci run');
});

// The check runs the repository's own code, so the one GitHub token in its reach reads the issues of the unit's
// own repository and nothing else: the property `issues` the Manager mints for that alone, never `pat` or `push`.
const checkTokenReadsIssuesOnly = (docs, unit) => {
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === `${unit}-ci`);
  const token = pipeline.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').env.find((e) => e.name === 'GITHUB_TOKEN');
  const reader = docs.find((d) => d.kind === 'ExternalSecret' && d.spec.target.name === 'build-issues-read');
  return JSON.stringify(token?.valueFrom) === JSON.stringify({secretKeyRef: {name: 'build-issues-read', key: 'token', optional: true}})
    && JSON.stringify(reader?.spec.target.template.data) === JSON.stringify({token: '{{ .issues }}'})
    && JSON.stringify(reader.spec.data.map((d) => [d.secretKey, d.remoteRef.key, d.remoteRef.property])) === JSON.stringify([['issues', `build/${unit}/repo-pat`, 'issues']]);
};

test('the ci check holds a GITHUB_TOKEN that reads the issues of its own repository and nothing else', () => {
  for (const builds of [['app'], []]) assert.ok(checkTokenReadsIssuesOnly(renderUnit('shop', builds), 'shop'), `the check of a unit with builds ${JSON.stringify(builds)} reads issues`);
  const docs = renderUnit('shop');
  const plant = (change) => { const planted = structuredClone(docs); change(planted); return checkTokenReadsIssuesOnly(planted, 'shop'); };
  const checkEnv = (planted) => planted.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci').spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').env;
  const reader = (planted) => planted.find((d) => d.kind === 'ExternalSecret' && d.metadata.name === 'build-issues-read');
  assert.ok(!plant((p) => checkEnv(p).splice(checkEnv(p).findIndex((e) => e.name === 'GITHUB_TOKEN'), 1)), 'PLANTED DEFECT: a check without GITHUB_TOKEN is caught');
  assert.ok(!plant((p) => { checkEnv(p).find((e) => e.name === 'GITHUB_TOKEN').valueFrom.secretKeyRef.name = 'build-git-https'; }), 'PLANTED DEFECT: the repository token on the check is caught');
  assert.ok(!plant((p) => { reader(p).spec.data[0].remoteRef.property = 'push'; }), 'PLANTED DEFECT: the issues reader filled from the push token is caught');
  assert.ok(!plant((p) => { reader(p).spec.target.template.data.token = '{{ .pat }}'; }), 'PLANTED DEFECT: the issues reader templated from another property is caught');
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const holdsIssuesToken = (steps) => steps.filter((t) => JSON.stringify(t).includes('build-issues-read')).map((t) => t.name);
  assert.deepEqual([holdsIssuesToken(ciTaskSpec(pipeline).steps), holdsIssuesToken(pipeline.spec.finally)], [['check'], []]);
  assert.equal(reader(docs).spec.refreshPolicy, 'OnChange', 'the Manager rewrites the token in Vault and asks for the Secret again, as for build-git-https');
});

// The publish pipeline packs the npm packages of a release tag and pushes them to the registry. It runs the repository's
// own code (install, build, pack), so the push credential is in the one task that runs none, and that task never
// sees the repository: it reads the packed tarballs alone.
test('the publish pipeline of every unit holds the push credential in its push task only, and is no release', () => {
  for (const builds of [[], ['app']]) {
    const docs = renderUnit('shop', builds);
    const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish');
    assert.ok(pipeline, `a unit with ${builds.length} builds renders its publish pipeline`);
    const task = (name) => pipeline.spec.tasks.find((t) => t.name === name);
    assert.deepEqual(pipeline.spec.tasks.map((t) => t.name), ['gate', 'clone', 'scan', 'reviewed', 'pack', 'build-binaries', 'push']);
    // Tekton copies a Pipeline's labels onto its runs: a consumer label would make the Manager watch it as a release.
    assert.deepEqual(pipeline.metadata.labels['image-builder.io/publish'], 'shop');
    assert.equal(pipeline.metadata.labels['image-builder.io/consumer'], undefined);
    assert.equal(pipeline.metadata.labels['image-builder.io/ci'], undefined);
    const holding = (p, needle) => p.spec.tasks.filter((t) => JSON.stringify(t).includes(needle)).map((t) => t.name);
    assert.deepEqual(holding(pipeline, 'image-builder-registry-push'), ['push']);
    assert.deepEqual(holding(pipeline, 'build-git-https'), ['clone', 'reviewed']);
    assert.deepEqual(holding(pipeline, 'build-npmrc'), ['pack']);
    assert.ok(!JSON.stringify(pipeline).includes('bump') && !JSON.stringify(pipeline).includes('registry-pull'), 'no bump and no pull credential');
    assert.deepEqual(task('reviewed').taskSpec.steps.filter((s) => JSON.stringify(s.envFrom ?? []).includes('build-git-https')).map((s) => s.name),
      ['fetch-default'], 'only the step that fetches the default branch holds the clone credential, and it runs only git');
    assert.ok(task('pack').taskSpec.steps.every((s) => s.envFrom === undefined), 'the steps that run the repository\'s code hold no secret as environment');
    assert.deepEqual(task('pack').taskSpec.volumes.filter((v) => v.secret).map((v) => v.secret.secretName), ['build-npmrc']);
    assert.ok(task('build-binaries').taskSpec.steps.every((s) => s.envFrom === undefined) && task('build-binaries').taskSpec.volumes === undefined,
      'release/build.sh runs the repository\'s code and holds no secret at all');
    assert.deepEqual(task('push').taskSpec.steps.map((s) => s.envFrom), [[{secretRef: {name: 'image-builder-registry-push'}}]]);
    assert.deepEqual(task('push').workspaces, [{name: 'packed', workspace: 'source', subPath: 'packed'}], 'the push reads the packed tarballs and never the repository');
    assert.equal(task('push').taskSpec.workspaces[0].readOnly, true);
    for (const [name, modes] of [['reviewed', ['source', 'binaries']], ['pack', ['source']], ['build-binaries', ['binaries']], ['push', ['source', 'binaries']]]) {
      assert.deepEqual(task(name).when, [{input: '$(tasks.scan.results.mode)', operator: 'in', values: modes}], `${name} runs only where the scan found what it publishes`);
    }
    assert.equal(task('clone').params.find((p) => p.name === 'revision').value, 'refs/tags/$(params.release-tag)', 'the clone is the pushed release tag');
    const env = (name, key) => task(name).taskSpec.steps.flatMap((s) => s.env ?? []).find((e) => e.name === key)?.value;
    assert.equal(env('scan', 'NPM_REGISTRY'), `https://${env('push', 'REGISTRY')}/v2/npm/`, 'a package names this registry\'s npm prefix');
    assert.equal(env('push', 'OWNER'), 'check', 'the scope a unit publishes is the owner of its repository');
    assert.equal(env('push', 'REPO_URL'), 'https://github.com/check/shop.git');
    assert.equal(env('gate', 'REPO_URL'), 'https://github.com/check/shop.git');
    const cloneTask = imageBuilder().find((d) => d.kind === 'Task' && d.metadata.name === 'git-clone');
    for (const t of pipeline.spec.tasks) {
      for (const step of (t.taskSpec ?? cloneTask.spec).steps) {
        for (const side of ['requests', 'limits']) assert.ok(step.computeResources?.[side]?.cpu && step.computeResources?.[side]?.memory, `${t.name}/${step.name} has ${side}`);
      }
    }
    // PLANTED DEFECT: the push credential beside the repository's code.
    const planted = structuredClone(pipeline);
    planted.spec.tasks.find((t) => t.name === 'pack').taskSpec.steps[0].envFrom = [{secretRef: {name: 'image-builder-registry-push'}}];
    assert.notDeepEqual(holding(planted, 'image-builder-registry-push'), ['push']);
  }
  const push = renderUnit('shop', []).find((d) => d.kind === 'ExternalSecret' && d.metadata.name === 'image-builder-registry-push');
  assert.deepEqual(push.spec.data.map((d) => d.remoteRef.property), ['push-user', 'push-password']);
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

// The check step of the release's builds task, run on a tagged manifest. Its stand-ins run in lockstep:
// grep -qx closes its input at the first line it matches, and printf writes its next line only after
// grep has decided the one before. A check that pipes printf into grep -q under pipefail then meets
// SIGPIPE on every run instead of at random.
const REAL_GREP = execFileSync('sh', ['-c', 'command -v grep'], {encoding: 'utf8'}).trim();
const LOCKSTEP_GREP = `#!/usr/bin/env bash
[ "$1" = -qx ] || exec "$REAL_GREP" "$@"
n=0
while IFS= read -r line; do
  n=$((n + 1))
  if "$REAL_GREP" -qx -e "$2" <<< "$line"; then exec 0<&-; : > "$LOCKSTEP/$n"; exit 0; fi
  : > "$LOCKSTEP/$n"
done
exit 1
`;
const LOCKSTEP_PRINTF = `() { if [ "$1" != '%s\\n' ] || [ $# -lt 3 ]; then builtin printf "$@"; return; fi
  local format="$1" n=0; shift; rm -f "$LOCKSTEP"/*
  for word; do
    [ "$n" = 0 ] || until [ -e "$LOCKSTEP/$n" ]; do sleep 0.01; done
    builtin printf "$format" "$word"; n=$((n + 1))
  done
}`;
const RELEASE_BUILDS = ['shop-engine', 'shop-app', 'shop-web'];
let releaseBuildsStep;
const runReleaseBuilds = (declared, edit = (script) => script) => {
  releaseBuildsStep ??= renderUnit('shop', RELEASE_BUILDS).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release')
    .spec.tasks.find((t) => t.name === 'builds').taskSpec.steps.find((s) => s.name === 'check');
  const root = mkdtempSync(join(tmpdir(), 'release-builds-')), source = join(root, 'source'), bin = join(root, 'bin');
  const results = join(root, 'results'), lockstep = join(root, 'lockstep');
  for (const dir of [join(source, 'deploy'), bin, results, lockstep]) mkdirSync(dir, {recursive: true});
  writeFileSync(join(source, 'deploy/platform.yaml'),
    `name: shop\nbuilds:\n${declared.map((b) => `  - {name: '${b}', containerfile: Containerfile, context: .}\n`).join('')}`);
  writeFileSync(join(bin, 'grep'), LOCKSTEP_GREP); chmodSync(join(bin, 'grep'), 0o755);
  const env = Object.fromEntries(releaseBuildsStep.env.map((e) => [e.name, e.value]));
  const result = spawnSync('bash', ['-c', edit(releaseBuildsStep.script).replaceAll('/tekton/results', results)], {cwd: source,
    encoding: 'utf8', timeout: 60000, env: {PATH: `${bin}:${process.env.PATH}`, REAL_GREP, LOCKSTEP: lockstep, 'BASH_FUNC_printf%%': LOCKSTEP_PRINTF, ...env}});
  const declaredResults = RELEASE_BUILDS.map((b) => existsSync(join(results, `${b}-declared`)) && readFileSync(join(results, `${b}-declared`), 'utf8'));
  rmSync(root, {recursive: true, force: true});
  return {...result, declaredResults};
};

test('the release builds check passes every attested build, the first one too, when grep -q stops reading at its match', () => {
  const innocent = runReleaseBuilds(RELEASE_BUILDS);
  assert.equal(releaseBuildsStep.env.find((e) => e.name === 'ATTESTED').value, RELEASE_BUILDS.join(' '));
  assert.equal(innocent.status, 0, `PLANTED INNOCENT: three attested builds — ${innocent.stderr}`);
  assert.deepEqual(innocent.declaredResults, ['true', 'true', 'true']);
  const attestedCheck = 'if ! [[ " ${ATTESTED} " == *" ${b} "* ]]; then';
  const racing = (script) => script.replace(attestedCheck, 'if ! printf \'%s\\n\' ${ATTESTED} | grep -qx "${b}"; then');
  assert.notEqual(racing(releaseBuildsStep.script), releaseBuildsStep.script, 'the step carries the attested check this test replaces');
  const raced = runReleaseBuilds(RELEASE_BUILDS, racing);
  assert.notEqual(raced.status, 0, 'PLANTED DEFECT: the attested check piped into grep -q is refused by the stand-ins on its first build');
  assert.match(raced.stderr, /build 'shop-engine' is declared/);
  const NOT_ATTESTED = {
    'a build missing from ATTESTED': [...RELEASE_BUILDS, 'shop-extra'],
    'a prefix of an attested build': ['shop-eng'],
    'an attested build with a suffix': ['shop-engines'],
    'a name that matches an attested build only as a pattern': ['shop-.pp'],
  };
  for (const [name, declared] of Object.entries(NOT_ATTESTED)) {
    const refused = runReleaseBuilds(declared);
    const missing = declared.at(-1);
    assert.notEqual(refused.status, 0, `PLANTED DEFECT: ${name}`);
    assert.equal(refused.stderr, `builds: FAIL — build '${missing}' is declared in deploy/platform.yaml but not attested in registrations/shop/build.yaml — run the onboard verb again to re-attest\n`, name);
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
  const ci = ciTaskSpec(pipeline);
  assert.deepEqual(ci.steps.slice(5).map((s) => s.name), ['list-sources', 'list-tools', 'sources', 'hand-over', 'check']);
  assert.deepEqual(ci.results.map((r) => r.name), ['subject', 'author', 'tools', 'earlier-run'], 'the tools of ci-tools.json travel to the check as a result of the task');
  const holdsCredential = (spec) => spec.steps.filter((s) => JSON.stringify(s.envFrom ?? []).includes('build-git-https')).map((s) => s.name);
  assert.deepEqual(holdsCredential(ci), ['clone', 'sources'], 'the step that reads the branch\'s ci-sources.json holds no credential');
  const planted = structuredClone(ci);
  planted.steps.find((s) => s.name === 'list-sources').envFrom = [{secretRef: {name: 'build-git-https'}}];
  assert.notDeepEqual(holdsCredential(planted), ['clone', 'sources'], 'PLANTED DEFECT: a credential on the reading step is caught');
  assert.equal(ciStep(pipeline, 'sources').env.find((e) => e.name === 'SOURCES_OWNER_URL').value, 'https://github.com/check', 'sources come from the unit\'s own owner');
  const mountOf = (name, path) => ciStep(pipeline, name).volumeMounts.find((m) => m.mountPath === path);
  for (const name of ['clone', 'describe', 'list-sources', 'list-tools', 'hand-over', 'check']) {
    assert.deepEqual([mountOf(name, '/workspace/source').name, mountOf(name, '/workspace/source').subPath], ['scratch', 'repository'], `${name} reads the clone from subPath repository`);
  }
  for (const name of ['sources', 'check']) assert.equal(mountOf(name, '/workspace/sources').subPath, 'sources');
  assert.equal(mountOf('check', '/workspace/sources').readOnly, true);
  assert.equal(ciStep(pipeline, 'check').env.find((e) => e.name === 'CI_SOURCES_DIR').value, '/workspace/sources');
  assert.throws(() => renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name: 'shop', repoURL: 'https://gitlab.com/check/shop.git', buildsJson: '[]'})]),
    /unit\.repoURL .* is not https:\/\/github\.com\/<owner>\/<repository>/);
});

test('the ci gate takes a full SHA-1 as commit and as before, all zeros for a new branch, and refuses anything else', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const script = pipeline.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'gate').script;
  const SHA = 'a'.repeat(40), REPO = 'https://github.com/check/shop.git';
  const gate = (script, before, commit = SHA) => spawnSync('sh', ['-c', script], {encoding: 'utf8',
    env: {...process.env, REPO_URL: REPO, GIT_URL: REPO, COMMIT: commit, BEFORE: before, BRANCH: 'feature/x'}}).status;
  assert.equal(gate(script, 'b'.repeat(40)), 0, 'PLANTED INNOCENT: a fast-forward push passes');
  assert.equal(gate(script, '0'.repeat(40)), 0, 'PLANTED INNOCENT: the first push of a new branch passes');
  for (const before of ['', 'master', 'b'.repeat(39), 'b'.repeat(41), 'B'.repeat(40), `${'b'.repeat(38)};x`, '$(id)']) {
    assert.notEqual(gate(script, before), 0, `PLANTED DEFECT: before '${before}' is refused`);
  }
  assert.notEqual(gate(script, 'b'.repeat(40), 'master'), 0, 'a commit that is no SHA-1 is still refused');
  const unchecked = script.replace(/\n\s*if ! is_sha1 "\$\{BEFORE\}"; then[\s\S]*?\n\s*fi\n/, '\n');
  assert.notEqual(unchecked, script);
  assert.equal(gate(unchecked, 'master'), 0, 'PLANTED DEFECT: a gate without the before check lets any text through');
});

test('list-sources passes only plain repository names with full commits, and a repository without ci-sources.json fetches nothing', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const script = pipeline.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'list-sources').script;
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
const CI_PARTS = [['Pipeline', 'shop-ci'], ['ResourceQuota', 'ci-pods'], ['ExternalSecret', 'build-git-https'], ['ExternalSecret', 'build-issues-read'], ['ExternalSecret', 'build-npmrc'],
  ['Role', 'ci-report-read'], ['Role', 'ci-run-keeper-pipelineruns'], ['Pipeline', 'shop-publish'], ['ExternalSecret', 'image-builder-registry-push']];
const RELEASE_PARTS = [['Pipeline', 'shop-release'], ['Pipeline', 'shop-image'], ['ExternalSecret', 'image-builder-registry-pull-opaque'], ['ExternalSecret', 'build-registry-pull'], ['ExternalSecret', 'bump-git-https']];
const holds = (docs, parts) => parts.map(([kind, name]) => docs.some((d) => d.kind === kind && d.metadata.name === name));
const isCiOnly = (docs) => holds(docs, CI_PARTS).every(Boolean) && !holds(docs, RELEASE_PARTS).some(Boolean);

test('a unit that builds nothing renders the ci check and the publish pipeline, and no release, registry pull or bump part', () => {
  const ciOnly = renderUnit('shop', []);
  assert.ok(isCiOnly(ciOnly), 'ci pipeline, ci quota, clone credential, build-npmrc, issues reader, the ci grants, the publish pipeline and its push credential render; release pipeline, pull secret and bump secret do not');
  const withBuilds = renderUnit('shop');
  assert.deepEqual(holds(withBuilds, [...CI_PARTS, ...RELEASE_PARTS]), Array(CI_PARTS.length + RELEASE_PARTS.length).fill(true), 'PLANTED INNOCENT: a unit with builds renders both pipelines and every credential as before');
  assert.ok(!isCiOnly(withBuilds), 'a unit with builds is not a ci-only unit');
  // The condition this change replaced (a unit renders its ci parts only when it builds) leaves out the ci parts.
  const oldCondition = ciOnly.filter((d) => !CI_PARTS.slice(0, 4).some(([kind, name]) => d.kind === kind && d.metadata.name === name));
  assert.ok(!isCiOnly(oldCondition), 'PLANTED DEFECT: a render that keeps the ci parts behind the builds condition is caught');
  const leaky = [...ciOnly, withBuilds.find((d) => d.kind === 'ExternalSecret' && d.metadata.name === 'bump-git-https')];
  assert.ok(!isCiOnly(leaky), 'PLANTED DEFECT: a ci-only render that carries the bump credential is caught');
});

// The engine's own check of a tenant bundle: a refused member stops the start of every app of its
// tenant, so the release run opens the bundle with the stage's engine before the bump writes a pin. The check's shell is
// run by scripts/pipeline-release.test.sh; what it is wired to is asserted here on the rendered Pipeline.
test('the release pipeline checks an apps bundle with the stage engine before the bump, and the check holds no credential', () => {
  const attested = ['shop-apps', 'shop-web'];
  const release = renderUnit('shop', attested).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release');
  const task = (name, pipeline = release) => pipeline.spec.tasks.find((t) => t.name === name);
  const onBundle = [{input: '$(tasks.builds.results.apps-bundle)', operator: 'in', values: attested}];
  assert.deepEqual(task('engine-pin').when, onBundle, 'engine-pin runs only where the manifest names an attested build as appsBundle');
  assert.deepEqual(task('check-definitions').when, onBundle, 'so does check-definitions');
  assert.ok(!attested.includes(''), 'a manifest without appsBundle writes an empty result, which no attested build equals');
  assert.ok(task('builds').taskSpec.results.some((r) => r.name === 'apps-bundle'), 'the builds task hands on the manifest\'s appsBundle');
  assert.deepEqual(task('engine-pin').runAfter, ['builds', 'scan', ...attested.map((b) => `build-${b}`)], 'engine-pin starts after the bundle build, as the bump does');
  assert.deepEqual(task('check-definitions').runAfter, ['engine-pin']);
  assert.ok(task('bump').runAfter.includes('check-definitions'), 'a refused bundle ends the run before the bump writes a pin');
  // The bump pins as a tenant bundle only its APPS_BUNDLE, so that is the value the `when` above reads, taken from the
  // same result and not read again off the manifest.
  const bumpBundle = (t) => [t.params.find((p) => p.name === 'apps-bundle')?.value, t.taskSpec.steps[0].env.find((e) => e.name === 'APPS_BUNDLE')?.value];
  assert.deepEqual(bumpBundle(task('bump')), [onBundle[0].input, '$(params.apps-bundle)'], 'the bump pins as a bundle the one build the check opened');
  const rewired = structuredClone(task('bump'));
  rewired.params.find((p) => p.name === 'apps-bundle').value = '$(tasks.verify.results.image-tag)';
  assert.notDeepEqual(bumpBundle(rewired), [onBundle[0].input, '$(params.apps-bundle)'], 'PLANTED DEFECT: a bump whose bundle comes from elsewhere than the check\'s is caught');
  const check = task('check-definitions');
  assert.deepEqual(check.params.map((p) => [p.name, p.value]), [
    ['bundle-image', 'zot.check.example.invalid/$(tasks.builds.results.apps-bundle):$(tasks.verify.results.image-tag)'],
    ['engine-image', '$(tasks.engine-pin.results.engine-image)']]);
  assert.deepEqual(check.taskSpec.steps.map((s) => [s.name, s.image]), [['copy-bundle', '$(params.bundle-image)'], ['members', 'alpine/k8s:1.35.6'], ['check', '$(params.engine-image)']]);
  // The step that opens the bundle holds no credential, and neither does a volume of its pod; the one platform credential
  // of the check is the pin read, in a task that runs no code of the unit.
  const holdsNoCredential = (t) => t.taskSpec.steps.every((s) => s.envFrom === undefined && s.env === undefined) && t.taskSpec.volumes.every((v) => v.emptyDir) && !JSON.stringify(t).includes('bump-git-https');
  assert.ok(holdsNoCredential(check), 'check-definitions holds no environment, secret or credential');
  const planted = structuredClone(check);
  planted.taskSpec.steps[2].envFrom = [{secretRef: {name: 'bump-git-https'}}];
  assert.ok(!holdsNoCredential(planted), 'PLANTED DEFECT: a check step that takes the bump credential is caught');
  assert.deepEqual(release.spec.tasks.filter((t) => JSON.stringify(t).includes('bump-git-https')).map((t) => t.name), ['engine-pin', 'bump']);
  assert.ok(task('engine-pin').taskSpec.steps.every((s) => s.image === 'alpine/k8s:1.35.6'), 'the task that holds the credential runs no image the unit or the pin names');
  for (const t of [task('engine-pin'), check]) {
    for (const step of t.taskSpec.steps) assert.ok(step.computeResources?.requests?.cpu && step.computeResources?.limits?.memory, `${t.name}/${step.name} bounds its resources`);
  }
  assert.ok(!release.spec.tasks.some((t) => t.name.startsWith('build-') && t.name !== 'build-shop-apps' && t.name !== 'build-shop-web'), 'the check is no build: the memory budget of the release counts build- tasks');
});

test('the kubelet pull secret of the release images exists for a unit that builds, composed by the shared registry pull helper', () => {
  const docs = renderUnit('shop');
  const secret = docs.find((d) => d.kind === 'ExternalSecret' && d.metadata.name === 'build-registry-pull');
  // The chart renders into argocd and its resources name their namespace, so a helper that drops the
  // namespace key places the secret where no build pod reads it.
  assert.equal(secret.metadata.namespace, 'shop-build', 'the helper places it in the namespace the caller names');
  for (const [chart, name] of [['gate-runner', 'gate-runner-registry-pull'], ['e2e-runner', 'e2e-runner-registry-pull'], ['service-provisioner', 'registry-pull-source']]) {
    assert.equal(renderChart(chart).find((d) => d.kind === 'ExternalSecret' && d.metadata.name === name).metadata.namespace, 'argocd', `PLANTED INNOCENT: ${chart}, which names no namespace, keeps ${name} in its release namespace`);
  }
  assert.equal(secret.spec.target.template.type, 'kubernetes.io/dockerconfigjson');
  assert.deepEqual(secret.spec.data.map((d) => [d.remoteRef.key.endsWith('/app/registry'), d.remoteRef.property]), [[true, 'pull-user'], [true, 'pull-password']], 'the read-only pull identity, never the push one');
  assert.ok(secret.spec.target.template.data['.dockerconfigjson'].includes('"zot.check.example.invalid"'), 'for the host the images are pulled from');
  assert.ok(!renderUnit('shop', []).some((d) => d.metadata?.name === 'build-registry-pull'), 'PLANTED INNOCENT: a unit that builds nothing renders no pull secret');
});

// The two platform bump credentials stand on build-platform/, a tier of their own, and never at
// build/<unit>/repo-pat: that leaf is a unit's own entry, and a unit named hostyour-cloud or deploy owns
// it whole. The unit's own record is its `push` token, which writes that one repository and no other,
// never its `pat`. What the bump of a unit reads, by key of its credential
// set, as `<vault key>#<property>`, and every way that departs from it.
const bumpReads = (docs) => Object.fromEntries(docs.find((d) => d.kind === 'ExternalSecret' && d.metadata.name === 'bump-git-https')
  .spec.data.map(({secretKey, remoteRef}) => [secretKey, `${remoteRef.key}#${remoteRef.property}`]));
const bumpReadFindings = (reads, unit) => {
  const expected = {'unit-pat': `build/${unit}/repo-pat#push`, 'deploy-pat': 'build-platform/deploy/repo-pat#pat', 'cloud-pat': 'build-platform/hostyour-cloud/repo-pat#pat'};
  const found = Object.entries(expected).filter(([key, read]) => reads[key] !== read).map(([key]) => `${unit}: ${key} reads ${reads[key]}`);
  if (new Set(Object.values(reads)).size !== Object.keys(reads).length) found.push(`${unit}: two keys read one entry`);
  return found;
};

test('the bump reads the platform credentials from build-platform/, and units named hostyour-cloud and deploy read their own entries apart from them', () => {
  for (const unit of ['shop', 'hostyour-cloud', 'deploy']) assert.deepEqual(bumpReadFindings(bumpReads(renderUnit(unit)), unit), [], `PLANTED INNOCENT: the render of ${unit}`);
  const deploy = bumpReads(renderUnit('deploy'));
  assert.notDeepEqual(bumpReadFindings({...deploy, 'deploy-pat': 'build/deploy/repo-pat#pat'}, 'deploy'), [], 'PLANTED DEFECT: the old deploy leaf, the entry a unit named deploy owns, is caught');
  const cloud = bumpReads(renderUnit('hostyour-cloud'));
  assert.notDeepEqual(bumpReadFindings({...cloud, 'cloud-pat': 'build/hostyour-cloud/repo-pat#pat'}, 'hostyour-cloud'), [], 'PLANTED DEFECT: the old hostyour-cloud leaf, the entry a unit named hostyour-cloud owns, is caught');
  const shop = bumpReads(renderUnit('shop'));
  assert.notDeepEqual(bumpReadFindings({...shop, 'unit-pat': 'build/shop/repo-pat#pat'}, 'shop'), [], 'PLANTED DEFECT: the unit\'s record back on its pat, the token that reaches more than its own repository, is caught');
});

// The lines of the check step from the install on, run in a repository directory with pnpm replaced by a stub
// that records each call: true when the repository's suites ran, and whether pnpm was called.
const runInstallAndCheck = (installAndCheck, files) => {
  const root = mkdtempSync(join(tmpdir(), 'ci-check-')), repo = join(root, 'repo'), bin = join(root, 'bin');
  mkdirSync(join(repo, 'scripts'), {recursive: true}); mkdirSync(bin);
  for (const file of files) writeFileSync(join(repo, file), '');
  writeFileSync(join(repo, 'scripts/test.sh'), 'touch checked\n');
  writeFileSync(join(bin, 'pnpm'), `#!/usr/bin/env bash\ntouch "${join(root, 'pnpm-called')}"\n[ -f pnpm-lock.yaml ]\n`);
  chmodSync(join(bin, 'pnpm'), 0o755);
  try {
    execFileSync('bash', ['-euo', 'pipefail', '-c', installAndCheck], {cwd: repo, env: {...process.env, CI_TOOLS: '', PATH: `${bin}:${process.env.PATH}`}});
  } catch { /* a failed install is read from the missing marker below */ }
  return {checked: existsSync(join(repo, 'checked')), pnpm: existsSync(join(root, 'pnpm-called'))};
};

test('the ci check installs with pnpm only a repository that carries pnpm-lock.yaml, and runs the suites of every repository', () => {
  const script = renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci')
    .spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').script;
  const lines = script.split('\n');
  const installAndCheck = lines.slice(lines.findIndex((line) => line.includes('pnpm install'))).join('\n');
  assert.ok(installAndCheck.includes('bash scripts/test.sh'), 'the install is followed by the repository suites');
  assert.deepEqual(runInstallAndCheck(installAndCheck, ['package.json', 'pnpm-lock.yaml']), {checked: true, pnpm: true}, 'PLANTED INNOCENT: a pnpm repository is installed, then its suites run');
  assert.deepEqual(runInstallAndCheck(installAndCheck, []), {checked: true, pnpm: false}, 'a repository without package.json runs its suites without an install');
  assert.deepEqual(runInstallAndCheck(installAndCheck, ['package.json', 'package-lock.json']), {checked: true, pnpm: false}, 'a repository with an npm lockfile runs its suites without a pnpm install');
  const unconditional = 'pnpm install --frozen-lockfile\nbash scripts/test.sh\n';
  assert.deepEqual(runInstallAndCheck(unconditional, []), {checked: false, pnpm: true}, 'PLANTED DEFECT: an install that runs in every repository fails the repository without package.json before its suites');
});

// ci-tools.json at a repository's root names the tools its check runs with, {"<tool>": "<x.y.z>"}: the fetch task
// validates it with jq and hands the lines to the check as a result; the check installs each from the table of
// files/ci-tools.table, with its sha256, and puts it before the image's own tools on PATH.
const CI_FILES = 'clusters/inventories/consumer-build/files';
const ciPipeline = (builds = []) => renderUnit('shop', builds).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
const ciTask = (builds) => ciPipeline(builds).spec.tasks.find((t) => t.name === 'ci').taskSpec;

test('list-tools passes only a known tool at a plain version, and a repository without ci-tools.json lists none', () => {
  const step = ciTask().steps.find((s) => s.name === 'list-tools');
  assert.equal(step.envFrom, undefined, 'the step that reads the repository\'s file holds no credential');
  assert.equal(step.env.find((e) => e.name === 'TOOLS_RESULT').value, '$(results.tools.path)');
  const list = (contents) => {
    const dir = mkdtempSync(join(tmpdir(), 'list-tools-'));
    try {
      if (contents !== undefined) writeFileSync(join(dir, 'ci-tools.json'), typeof contents === 'string' ? contents : JSON.stringify(contents));
      const result = spawnSync('bash', ['-c', step.script], {cwd: dir, encoding: 'utf8', env: {...process.env, TOOLS_RESULT: join(dir, 'tools')}});
      return {status: result.status, lines: result.status === 0 ? readFileSync(join(dir, 'tools'), 'utf8').split('\n').filter(Boolean) : null};
    } finally {
      rmSync(dir, {recursive: true, force: true});
    }
  };
  const all = {node: '26.11.1', npm: '12.2.0', go: '1.24.13', dart: '3.13.4', gitleaks: '8.30.1', kubectl: '1.35.6', emcc: '5.0.1', traefik: '3.6.2'};
  assert.deepEqual(list(all), {status: 0, lines: Object.entries(all).map(([tool, version]) => `${tool} ${version}`)}, 'PLANTED INNOCENT: every tool of the contract at a plain version passes');
  assert.deepEqual(list({dart: '3.13.4'}), {status: 0, lines: ['dart 3.13.4']});
  assert.deepEqual(list({}), {status: 0, lines: []}, 'a file that names no tool lists none');
  assert.deepEqual(list(undefined), {status: 0, lines: []}, 'a repository without ci-tools.json lists none and keeps the tools of its image');
  for (const [tool, version] of [['ruby', '3.4.0'], ['NODE', '26.11.1'], ['node', 'latest'], ['node', '26'], ['node', '26.11'], ['node', 'v26.11.1'], ['node', '26.11.1-rc.1'], ['traefik', 'v3.6.2'], ['node', '26.11.1; id'], ['node', '$(id)'], ['node', 26.11], ['node', null]]) {
    assert.notEqual(list({[tool]: version}).status, 0, `PLANTED DEFECT: ${tool} at ${JSON.stringify(version)} is refused`);
  }
  assert.notEqual(list({node: '26.11.1', ruby: '3.4.0'}).status, 0, 'one unknown tool among known ones refuses the file');
  for (const contents of [[['node', '26.11.1']], '"node"', '{"node": "26.11.1"', '']) {
    assert.notEqual(list(contents).status, 0, `PLANTED DEFECT: ${JSON.stringify(contents)} is no object of tools and versions`);
  }
});

const TOOLS_TABLE = readFileSync(`${CI_FILES}/ci-tools.table`, 'utf8');
const TABLE_HOSTS = ['nodejs.org', 'registry.npmjs.org', 'go.dev', 'storage.googleapis.com', 'zot.master.digitacloud.app', 'dl.k8s.io'];
// An emcc url names the emscripten-releases build of its version, as emsdk 14c18b56's emscripten-releases-tags.json maps it.
const EMSCRIPTEN_RELEASES = {'5.0.1': 'bf32ae8b61ac8efeb7eca01b54c8307f992724f7'};
const tableErrors = (table, tools) => {
  const errors = [], seen = new Set();
  for (const line of table.split('\n').filter(Boolean)) {
    const [tool, version, sha256, url, ...rest] = line.split(' ');
    if (rest.length || !url) errors.push(`${line}: not four fields`);
    if (!tools.includes(tool)) errors.push(`${tool}: not a tool of the contract`);
    if (!/^\d+\.\d+\.\d+$/.test(version ?? '')) errors.push(`${tool}: version ${version} is not x.y.z`);
    if (!/^[0-9a-f]{64}$/.test(sha256 ?? '')) errors.push(`${tool} ${version}: sha256 is not 64 hex digits`);
    if (!TABLE_HOSTS.some((host) => url?.startsWith(`https://${host}/`))) errors.push(`${tool} ${version}: ${url} is not https on a known host`);
    if (/[0-9a-f]{64}/.test(url ?? '') || (url?.startsWith('https://zot.master.digitacloud.app/') && !url.endsWith('/blobs/sha256:<sha256>'))) errors.push(`${tool} ${version}: ${url} writes the sha256 again, where the owned address ends in the slot <sha256>`);
    if (!url?.includes((tool === 'emcc' ? EMSCRIPTEN_RELEASES[version] : version) ?? '\0')) errors.push(`${tool} ${version}: ${url} does not name the version`);
    if (seen.has(`${tool} ${version}`)) errors.push(`${tool} ${version}: twice`);
    seen.add(`${tool} ${version}`);
  }
  return errors;
};

test('the tools table carries one sha256 and one https url per tool and version, for exactly the tools list-tools accepts', () => {
  const listTools = ciTask().steps.find((s) => s.name === 'list-tools').script;
  const tools = listTools.match(/IN\(([^)]*)\)/)[1].match(/[a-z]+/g);
  assert.deepEqual(tableErrors(TOOLS_TABLE, tools), [], 'PLANTED INNOCENT: the table as it stands');
  assert.deepEqual([...new Set(TOOLS_TABLE.split('\n').filter(Boolean).map((line) => line.split(' ')[0]))].sort(), [...tools].sort(), 'every accepted tool has a row and no row names another');
  const first = TOOLS_TABLE.split('\n')[0], [tool, version, sha256, url] = first.split(' ');
  const owned = Object.fromEntries(['tool', 'version', 'sha256', 'url'].map((key, at) => [key, TOOLS_TABLE.split('\n').find((line) => line.startsWith('traefik ')).split(' ')[at]]));
  for (const [defect, row] of [
    ['a short sha256', [tool, version, sha256.slice(1), url]],
    ['an upper-case sha256', [tool, version, sha256.toUpperCase(), url]],
    ['plain http', [tool, version, sha256, url.replace('https:', 'http:')]],
    ['a host that is not known', [tool, version, sha256, url.replace('https://nodejs.org', 'https://example.org')]],
    ['a url that does not name the version', [tool, version, sha256, url.replaceAll(version, '1.0.0')]],
    ['a tool of no contract', ['ruby', version, sha256, url]],
    ['a version that is no x.y.z', [tool, 'latest', sha256, url.replaceAll(version, 'latest')]],
    ['a fifth field', [tool, version, sha256, url, 'extra']],
    ['an owned address that writes the hex instead of the slot', [owned.tool, owned.version, owned.sha256, owned.url.replace('<sha256>', owned.sha256)]],
    ['an owned address without the blob of its file', [owned.tool, owned.version, owned.sha256, owned.url.replace('/blobs/sha256:<sha256>', '')]],
    ['a row back on a GitHub Release asset', [owned.tool, owned.version, owned.sha256, owned.url.replace(/^https:\/\/zot\.master\.digitacloud\.app\/v2\/simetrixch\//, 'https://').replace('/blobs/sha256:<sha256>', '')]],
  ]) {
    assert.notDeepEqual(tableErrors(`${row.join(' ')}\n`, tools), [], `PLANTED DEFECT: ${defect} is caught`);
  }
  assert.notDeepEqual(tableErrors(`${first}\n${first}\n`, tools), [], 'PLANTED DEFECT: a tool and version twice is caught');
  const envTable = ciTask().steps.find((s) => s.name === 'check').env.find((e) => e.name === 'CI_TOOLS_TABLE');
  assert.equal(envTable.value, TOOLS_TABLE, 'the check step is handed the table file, whole');
});

test('this repository\'s ci-tools.json names only rows of the tools table', () => {
  const named = Object.entries(JSON.parse(readFileSync('ci-tools.json', 'utf8'))).map(([tool, version]) => `${tool} ${version}`);
  assert.ok(named.length > 0);
  const rows = TOOLS_TABLE.split('\n').filter(Boolean).map((line) => line.split(' ').slice(0, 2).join(' '));
  assert.deepEqual(named.filter((pair) => !rows.includes(pair)), [], 'PLANTED INNOCENT: every pair of the file is a row');
  assert.notDeepEqual(['go 1.0.0'].filter((pair) => !rows.includes(pair)), [], 'PLANTED DEFECT: a version the table lacks is seen');
});

// The tools step against stand-in archives. Each stand-in program prints its own name, so what PATH resolves to is
// what ran. node's archive also carries the npm that node ships with, which the npm of ci-tools.json has to beat.
const buildToolFixtures = (root) => {
  const src = join(root, 'src'), out = join(root, 'archives');
  mkdirSync(out, {recursive: true});
  const program = (path, name) => { mkdirSync(dirname(path), {recursive: true}); writeFileSync(path, `#!/bin/sh\necho ${name}\n`); chmodSync(path, 0o755); };
  program(join(src, 'node/node-v/bin/node'), 'node-fixture');
  program(join(src, 'node/node-v/bin/npm'), 'npm-bundled-with-node');
  program(join(src, 'npm/package/bin/npm-cli.js'), 'npm-fixture');
  program(join(src, 'npm/package/bin/npx-cli.js'), 'npx-fixture');
  program(join(src, 'go/go/bin/go'), 'go-fixture');
  program(join(src, 'dart/dart-sdk/bin/dart'), 'dart-fixture');
  program(join(src, 'gitleaks/gitleaks'), 'gitleaks-fixture');
  program(join(out, 'kubectl'), 'kubectl-fixture');
  program(join(src, 'traefik/traefik'), 'traefik-fixture');
  // The SDK release of emscripten: LLVM in install/bin, Binaryen's programs beside it, emcc in install/emscripten. Its
  // emcc prints the version of the emscripten-version.txt beside it, which the archive ships as <x.y.z>-git.
  program(join(src, 'emcc/install/emscripten/emcc'), 'emcc-fixture "$(tr -d \'"\' < "$(dirname "$0")/emscripten-version.txt") (fixture)"');
  writeFileSync(join(src, 'emcc/install/emscripten/emscripten-version.txt'), '5.0.1-git\n');
  program(join(src, 'emcc/install/bin/clang'), 'clang-fixture');
  program(join(src, 'emcc/install/bin/wasm-opt'), 'wasm-opt-fixture');
  const tgz = (name, dir, entry) => execFileSync('tar', ['-czf', join(out, name), '-C', join(src, dir), entry]);
  tgz('node.tgz', 'node', 'node-v'); tgz('npm.tgz', 'npm', 'package'); tgz('go.tgz', 'go', 'go');
  tgz('gitleaks.tgz', 'gitleaks', 'gitleaks');
  tgz('traefik.tgz', 'traefik', 'traefik');
  execFileSync('tar', ['-cJf', join(out, 'emcc.tar.xz'), '-C', join(src, 'emcc'), 'install']);
  execFileSync('python3', ['-I', '-m', 'zipfile', '-c', join(out, 'dart.zip'), 'dart-sdk'], {cwd: join(src, 'dart')});
  // The owner's mirror serves a file as the blob of its sha256: the fixture serves traefik that way, and its row names the blob by the slot.
  const sha256Of = (archive) => createHash('sha256').update(readFileSync(join(out, archive))).digest('hex');
  mkdirSync(join(out, 'owned/blobs'), {recursive: true});
  copyFileSync(join(out, 'traefik.tgz'), join(out, 'owned/blobs', `sha256:${sha256Of('traefik.tgz')}`));
  const row = (tool, version, archive) => `${tool} ${version} ${sha256Of(archive)} ${tool === 'traefik' ? `file://${join(out, 'owned/blobs/sha256:<sha256>')}` : `file://${join(out, archive)}`}`;
  return Object.fromEntries([['node', '26.11.1', 'node.tgz'], ['npm', '12.2.0', 'npm.tgz'], ['go', '1.24.13', 'go.tgz'], ['dart', '3.13.4', 'dart.zip'],
    ['gitleaks', '8.30.1', 'gitleaks.tgz'], ['kubectl', '1.35.6', 'kubectl'], ['emcc', '5.0.1', 'emcc.tar.xz'],
    ['traefik', '3.6.2', 'traefik.tgz']].map(([tool, version, archive]) => [tool, row(tool, version, archive)]));
};

const runInstallTools = (wanted, rows, plant = (script) => script, extraEnv = {}) => {
  const root = mkdtempSync(join(tmpdir(), 'ci-tools-')), dir = join(root, 'installed');
  try {
    const table = rows(buildToolFixtures(root));
    const script = plant(readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8')).replaceAll('/tmp/ci-tools', dir);
    const probe = 'for t in node npm npx go dart gitleaks kubectl emcc traefik; do printf "%s|%s|%s\\n" "$t" "$(command -v "$t" || true)" "$("$t" --version </dev/null 2>&1 | head -n 1 || true)"; done';
    const result = spawnSync('bash', ['-euo', 'pipefail', '-c', `${script}\n${probe}`], {encoding: 'utf8', env: {...process.env, CI_TOOLS: wanted, CI_TOOLS_TABLE: table, ...extraEnv}});
    const resolved = Object.fromEntries((result.stdout.match(/^(node|npm|npx|go|dart|gitleaks|kubectl|emcc|traefik)\|.*$/gm) ?? []).map((line) => { const [tool, path, output] = line.split('|'); return [tool, {inside: path.startsWith(dir), output}]; }));
    // emcc reads the .emscripten beside it as Python; python3 reads the two roots out of it the same way.
    const emccConfig = join(dir, 'emcc/emscripten/.emscripten');
    const emccRoots = existsSync(emccConfig) ? execFileSync('python3', ['-I', '-c', 'import sys; exec(open(sys.argv[1]).read()); print(LLVM_ROOT); print(BINARYEN_ROOT)', emccConfig], {encoding: 'utf8'})
      .trim().replaceAll(dir, '<installed>').split('\n') : null;
    return {status: result.status, stdout: result.stdout, stderr: result.stderr, resolved, emccRoots,
      unpacked: [...['node', 'npm', 'go', 'dart', 'emcc'].filter((tool) => existsSync(join(dir, tool))), ...['gitleaks', 'kubectl', 'traefik'].filter((tool) => existsSync(join(dir, 'bin', tool)))], downloaded: existsSync(join(dir, 'node.download'))};
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
};
const allRows = (rows) => Object.values(rows).join('\n');
const WANTED_ALL = 'node 26.11.1\nnpm 12.2.0\ngo 1.24.13\ndart 3.13.4\ngitleaks 8.30.1\nkubectl 1.35.6\nemcc 5.0.1\ntraefik 3.6.2\n';

test('the tools step keeps each archive under its sha256 in the cache, uses a kept one only while its sha256 matches, and downloads again otherwise', () => {
  const cache = mkdtempSync(join(tmpdir(), 'ci-cache-'));
  try {
    let sha256 = '';
    const first = runInstallTools('gitleaks 8.30.1\n', (rows) => { sha256 = rows.gitleaks.split(' ')[2]; return allRows(rows); }, undefined, {CI_CACHE_DIR: cache});
    assert.equal(first.status, 0, first.stderr);
    assert.deepEqual(readdirSync(join(cache, 'archives')), [sha256], 'PLANTED INNOCENT: the first run keeps the archive under its sha256');
    const sha256Of = (file) => createHash('sha256').update(readFileSync(file)).digest('hex');
    assert.equal(sha256Of(join(cache, 'archives', sha256)), sha256);
    // The address is gone, so the run can only succeed from the kept archive.
    const kept = runInstallTools('gitleaks 8.30.1\n', () => `gitleaks 8.30.1 ${sha256} file:///nowhere`, undefined, {CI_CACHE_DIR: cache});
    assert.equal(kept.status, 0, kept.stderr);
    assert.deepEqual([kept.resolved.gitleaks.inside, kept.unpacked], [true, ['gitleaks']], 'PLANTED INNOCENT: a kept archive with its sha256 is used and nothing is downloaded');
    assert.deepEqual(readdirSync(join(cache, 'archives')), [sha256]);
    // A kept file that is not what its name says is replaced by a new download, which the row's sha256 vouches for.
    let current = '';
    const corrupt = (rows) => {
      current = rows.gitleaks.split(' ')[2];
      mkdirSync(join(cache, 'archives'), {recursive: true});
      writeFileSync(join(cache, 'archives', current), 'other bytes');
      return allRows(rows);
    };
    const replaced = runInstallTools('gitleaks 8.30.1\n', corrupt, undefined, {CI_CACHE_DIR: cache});
    assert.equal(replaced.status, 0, replaced.stderr);
    assert.match(replaced.stderr, new RegExp(`the kept archive ${current} no longer matches its sha256`), 'PLANTED DEFECT: a kept archive of other bytes is said so and removed');
    assert.equal(sha256Of(join(cache, 'archives', current)), current, 'and the download that replaced it is what the cache holds now');
    assert.deepEqual([replaced.resolved.gitleaks.inside, replaced.unpacked], [true, ['gitleaks']]);
    // Without the check of the kept archive the other bytes would be unpacked.
    const unchecked = runInstallTools('gitleaks 8.30.1\n', corrupt, (script) => script.replace('if echo "${sha256}  ${kept}" | sha256sum -c --status -; then', 'if true; then'), {CI_CACHE_DIR: cache});
    assert.notEqual(unchecked.status, 0, 'PLANTED DEFECT: a cache whose archives are used unchecked ends in a tool that is not what the table vouches for');
    // A run without a cache downloads and keeps nothing.
    const bare = runInstallTools('gitleaks 8.30.1\n', allRows);
    assert.equal(bare.status, 0, bare.stderr);
    assert.ok(!existsSync(join(cache, 'nothing')), 'a run without CI_CACHE_DIR keeps nothing');
  } finally {
    rmSync(cache, {recursive: true, force: true});
  }
});

test('the tools step installs each tool of ci-tools.json from the table before the image\'s own, and refuses what the table cannot vouch for', () => {
  const all = runInstallTools(WANTED_ALL, allRows);
  assert.equal(all.status, 0, all.stderr);
  assert.deepEqual(Object.entries(all.resolved).map(([tool, r]) => [tool, r.inside, r.output]), [['node', true, 'node-fixture'], ['npm', true, 'npm-fixture'], ['npx', true, 'npx-fixture'],
    ['go', true, 'go-fixture'], ['dart', true, 'dart-fixture'], ['gitleaks', true, 'gitleaks-fixture'], ['kubectl', true, 'kubectl-fixture'],
    ['emcc', true, 'emcc-fixture 5.0.1 (fixture)'], ['traefik', true, 'traefik-fixture']], 'PLANTED INNOCENT: all eight are installed, and the npm named beats the npm that ships with node');
  assert.deepEqual(all.emccRoots, ['<installed>/emcc/bin', '<installed>/emcc'], 'emcc reads LLVM from the bin of the SDK release and Binaryen from its root, as emsdk activate writes them');
  assert.match(all.stdout, /^check: emcc-fixture 5\.0\.1 \(fixture\), downloaded in \d+ s and unpacked in \d+ s$/m, 'the log names what emcc --version printed and the seconds its download and unpack took');
  const unversioned = runInstallTools('emcc 5.0.1\n', allRows, (script) => script.replace(/^.*emscripten-version\.txt.*$/gm, ''));
  assert.equal(unversioned.resolved.emcc.output, 'emcc-fixture 5.0.1-git (fixture)', 'PLANTED DEFECT: an emcc that reports 5.0.1-git, which packages/quickjs/build.sh of digita-platform refuses, is seen');
  const unconfigured = runInstallTools('emcc 5.0.1\n', allRows, (script) => script.replace(/^.*\.emscripten.*$/gm, ''));
  assert.equal(unconfigured.emccRoots, null, 'PLANTED DEFECT: an emcc without its config file is seen');
  const reversed = runInstallTools('gitleaks 8.30.1\nnpm 12.2.0\nnode 26.11.1\n', allRows);
  assert.equal(reversed.resolved.npm.output, 'npm-fixture', 'the order of ci-tools.json does not decide which npm runs');
  const nodeLast = runInstallTools(WANTED_ALL, (rows) => [rows.npm, rows.node, rows.go, rows.dart, rows.gitleaks, rows.kubectl, rows.emcc, rows.traefik].join('\n'));
  assert.equal(nodeLast.resolved.npm.output, 'npm-bundled-with-node', 'PLANTED DEFECT: a table that lists node after npm puts the npm of node first, and the probe sees it');
  const only = runInstallTools('gitleaks 8.30.1\n', allRows);
  assert.equal(only.status, 0, only.stderr);
  assert.deepEqual([only.resolved.gitleaks.inside, only.resolved.node.inside, only.resolved.dart.inside, only.unpacked], [true, false, false, ['gitleaks']], 'only the tool named is installed');
  const none = runInstallTools('', (rows) => Object.values(rows).map((row) => row.replace(/file:\/\/\S+/, 'file:///nowhere')).join('\n'));
  assert.deepEqual([none.status, none.downloaded, none.unpacked], [0, false, []], 'a repository without ci-tools.json downloads nothing');
  const absent = runInstallTools('node 26.11.2\n', allRows);
  assert.notEqual(absent.status, 0, 'PLANTED DEFECT: a version the table lacks ends the run');
  assert.match(absent.stderr, /names node 26\.11\.2, which the tools table of this pipeline does not carry/);
  assert.deepEqual([absent.downloaded, absent.unpacked], [false, []], 'and ends it before anything is downloaded');
  const half = runInstallTools('gitleaks 8.30.1\nnode 26.11.2\n', allRows);
  assert.notEqual(half.status, 0, 'one missing version among present ones ends the run');
  assert.deepEqual([half.downloaded, half.unpacked], [false, []], 'and installs none of them');
  assert.notEqual(runInstallTools('ruby 3.4.0\n', allRows).status, 0, 'PLANTED DEFECT: a tool the table does not carry ends the run');
  const forged = runInstallTools('node 26.11.1\n', (rows) => rows.node.replace(/ [0-9a-f]{64} /, ` ${'0'.repeat(64)} `));
  assert.notEqual(forged.status, 0, 'PLANTED DEFECT: an archive whose sha256 differs ends the run');
  assert.deepEqual([forged.downloaded, forged.unpacked], [true, []], 'after the download and before anything is unpacked');
  const forgedTraefik = runInstallTools('traefik 3.6.2\n', (rows) => allRows({...rows, traefik: rows.traefik.replace(/ [0-9a-f]{64} /, ` ${'0'.repeat(64)} `)}));
  assert.notEqual(forgedTraefik.status, 0, 'PLANTED DEFECT: a traefik archive whose sha256 differs ends the run');
  assert.deepEqual(forgedTraefik.unpacked, [], 'before the traefik of the archive is unpacked');
  const blobOf = (row) => { const [, , hex, url] = row.split(' '); return url.replace('file://', '').replace('<sha256>', hex); };
  assert.match(all.stdout, /^check: traefik 3\.6\.2, file:\/\/\S+\/blobs\/sha256:[0-9a-f]{64}, sha256 [0-9a-f]{64}$/m, 'PLANTED INNOCENT: the slot of the traefik row is filled with its sha256, and the log names the address that was read');
  const otherBytes = runInstallTools('traefik 3.6.2\n', (rows) => { writeFileSync(blobOf(rows.traefik), 'other bytes'); return allRows(rows); });
  assert.notEqual(otherBytes.status, 0, 'PLANTED DEFECT: an owned address whose filled blob serves other bytes ends the run');
  assert.match(otherBytes.stdout + otherBytes.stderr, /FAILED/, 'at the sha256sum -c, and not at the fetch');
  assert.deepEqual(otherBytes.unpacked, [], 'before anything of the file is unpacked');
  const unknown = runInstallTools('ruby 3.4.0\n', (rows) => `ruby 3.4.0 ${rows.node.split(' ')[2]} ${rows.node.split(' ')[3]}`);
  assert.notEqual(unknown.status, 0, 'a row for a tool this step cannot install ends the run');
  assert.match(unknown.stderr, /ruby, which this step cannot install/);
});

test('the check step installs the tools after the fixed ones and before the repository\'s own install, from the file the tests run', () => {
  const check = ciTask().steps.find((s) => s.name === 'check');
  assert.equal(check.env.find((e) => e.name === 'CI_TOOLS_FILE').value, '$(results.tools.path)', 'the validated lines reach the step as a file of the task\'s results, never as text of the script');
  assert.ok(check.script.includes('CI_TOOLS="$(cat "${CI_TOOLS_FILE}")"'), 'the step reads them from that file before the installer runs');
  const installer = readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8').trimEnd();
  assert.ok(check.script.includes(installer), 'the pipeline carries the file that these tests run');
  const at = (text) => check.script.indexOf(text);
  const fixed = readFileSync(`${CI_FILES}/ci-fixed-tools.sh`, 'utf8').trimEnd();
  assert.ok(at(fixed) >= 0 && at(fixed) < at('corepack enable') && at('corepack enable') < at(installer) && at(installer) < at('pnpm install'),
    'helm, yq and jq come first, then corepack, then the tools of the repository, then its install');
});

// helm, yq and jq are the tools every repository's check may use whatever its ci-tools.json names, so they stand in
// files/ci-fixed-tools.sh, and every step that runs a repository's own scripts carries that file and the one that installs
// ci-tools.json before it runs them: the check of the ci before scripts/test.sh, and build-binaries of the publish pipeline
// before release/build.sh, whose suites read JSON with jq (test/checks/release_digests_test.dart of ansiwise-cli).
const toolsProblems = (script, runs) => {
  const fixed = readFileSync(`${CI_FILES}/ci-fixed-tools.sh`, 'utf8').trimEnd();
  const installer = readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8').trimEnd();
  const problems = [], runAt = script.indexOf(runs), fixedAt = script.indexOf(fixed), installerAt = script.indexOf(installer);
  if (runAt < 0) problems.push(`the script never runs ${runs}`);
  if (fixedAt < 0) problems.push(`${runs} runs without helm, yq and jq: the script carries no files/ci-fixed-tools.sh`);
  if (installerAt < 0) problems.push(`${runs} runs without the tools of ci-tools.json: the script carries no files/ci-install-tools.sh`);
  if (fixedAt >= 0 && installerAt >= 0 && fixedAt > installerAt) problems.push('files/ci-fixed-tools.sh stands after files/ci-install-tools.sh');
  if (runAt >= 0 && [fixedAt, installerAt].some((at) => at > runAt)) problems.push(`a tools file stands after ${runs}`);
  if (/helm-v\d|yq_linux|jq-linux/.test(script.replace(fixed, ''))) problems.push('the script installs helm, yq or jq by a copy of its own beside files/ci-fixed-tools.sh');
  return problems;
};

// yq and jq are fetched from the owner's mirror, by the blob of their sha256, and the hex stands once, in the variable the url and
// the sha256sum -c both read. helm stays on get.helm.sh.
const OWNED_TOOLS = {yq: 'mikefarah/yq/releases/download/v4.53.6/yq_linux_amd64', jq: 'jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64'};
const fixedToolsMirrorProblems = (script) => {
  const problems = [], lines = script.split('\n');
  for (const [tool, path] of Object.entries(OWNED_TOOLS)) {
    const fetched = lines.filter((line) => line.startsWith('curl ') && line.includes(`"\${ci_bin}/${tool}"`));
    const wanted = `curl -fsSL -o "\${ci_bin}/${tool}" "https://zot.master.digitacloud.app/v2/simetrixch/github.com/${path}/blobs/sha256:\${${tool}_sha256}"`;
    if (fetched.join('\n') !== wanted) problems.push(`${tool} is fetched by ${fetched.join(' and ') || 'nothing'}, not from its owned address by ${tool}_sha256`);
    if (lines.filter((line) => new RegExp(`^${tool}_sha256=[0-9a-f]{64}$`).test(line)).length !== 1) problems.push(`${tool}_sha256 is not assigned one sha256 once`);
    if (!lines.includes(`echo "\${${tool}_sha256}  \${ci_bin}/${tool}" | sha256sum -c -`)) problems.push(`${tool} is not held to ${tool}_sha256 by sha256sum -c`);
  }
  const hexLines = lines.filter((line) => /[0-9a-f]{64}/.test(line) && !/^(yq|jq)_sha256=/.test(line) && !line.includes('helm'));
  if (hexLines.length) problems.push(`a sha256 is written beside its variable: ${hexLines.join(' and ')}`);
  return problems;
};

test('ci-fixed-tools.sh fetches yq and jq from the owner\'s mirror by the one sha256 it checks them against, and helm from get.helm.sh', () => {
  const fixed = readFileSync(`${CI_FILES}/ci-fixed-tools.sh`, 'utf8');
  assert.deepEqual(fixedToolsMirrorProblems(fixed), [], 'PLANTED INNOCENT: the file as it stands');
  assert.match(fixed, /^curl -fsSL -o \/tmp\/helm\.tar\.gz https:\/\/get\.helm\.sh\//m, 'helm stays on get.helm.sh');
  const hex = (tool) => fixed.match(new RegExp(`^${tool}_sha256=([0-9a-f]{64})$`, 'm'))[1];
  const defects = {
    'yq back on its GitHub Release asset': fixed.replace(/"https:\/\/zot\.master\.digitacloud\.app\/v2\/simetrixch\/github\.com\/(mikefarah[^"]*)\/blobs[^"]*"/, 'https://github.com/$1'),
    'the hex of jq written again in the check': fixed.replace('echo "${jq_sha256}  ', `echo "${hex('jq')}  `),
    'the hex of yq written again in the url': fixed.replace('/blobs/sha256:${yq_sha256}', `/blobs/sha256:${hex('yq')}`),
    'jq back on its GitHub Release asset': fixed.replace('https://zot.master.digitacloud.app/v2/simetrixch/github.com/jqlang', 'https://github.com/jqlang'),
    'the variable of yq missing': fixed.replace(/^yq_sha256=.*\n/m, ''),
  };
  for (const [defect, planted] of Object.entries(defects)) assert.notDeepEqual(fixedToolsMirrorProblems(planted), [], `PLANTED DEFECT: ${defect}`);
});

test('build-binaries installs the fixed tools and the tools of ci-tools.json before release/build.sh, by the files the ci check uses', () => {
  const fixed = readFileSync(`${CI_FILES}/ci-fixed-tools.sh`, 'utf8').trimEnd();
  for (const tool of [/helm-v4\.3\.0-linux-amd64\.tar\.gz/, /yq_linux_amd64/, /jq-linux-amd64/]) assert.match(fixed, tool, `${tool} is installed by the fixed tools`);
  assert.equal(fixed.match(/sha256sum -c -/g)?.length, 3, 'helm, yq and jq are each held to their sha256');
  const check = ciTask().steps.find((s) => s.name === 'check').script;
  const build = renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish')
    .spec.tasks.find((t) => t.name === 'build-binaries').taskSpec.steps.find((s) => s.name === 'build').script;
  assert.deepEqual(toolsProblems(check, 'bash scripts/test.sh'), [], 'PLANTED INNOCENT: the check step as rendered');
  assert.deepEqual(toolsProblems(build, 'bash release/build.sh'), [], 'PLANTED INNOCENT: build-binaries as rendered');
  const without = (script, text) => { assert.ok(script.includes(text), 'the planted defect finds its text'); return script.replace(text, ''); };
  const installer = readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8').trimEnd();
  const jqLine = fixed.split('\n').find((line) => line.includes('jq-linux-amd64'));
  const defects = {
    'the install of the fixed tools removed': (script) => without(script, fixed),
    'the install of the tools of ci-tools.json removed': (script) => without(script, installer),
    'only jq installed, by a copy of its own': (script) => script.replace(fixed, jqLine),
    'the fixed tools installed after the repository\'s own script': (script) => `${without(script, fixed)}\n${fixed}`,
  };
  for (const [defect, plant] of Object.entries(defects)) {
    assert.notDeepEqual(toolsProblems(plant(build), 'bash release/build.sh'), [], `PLANTED DEFECT: build-binaries with ${defect}`);
    assert.notDeepEqual(toolsProblems(plant(check), 'bash scripts/test.sh'), [], `PLANTED DEFECT: the check step with ${defect}`);
  }
  assert.match(toolsProblems(without(build, fixed), 'bash release/build.sh')[0], /without helm, yq and jq/, 'the report names the tools that are missing');
});

// The platform tree on the owner's master publishes no package: its publish run copies the images its tag names on ghcr.io
// into the mirror, then the tools and charts its tag names. The lists run the tree's own scripts, `list` for the images and
// `fetch` for the tools and charts, so they hold no secret; the push credential is in `copy` and `copy-sources`, whose
// scripts run no code of the repository, each on an image pinned by its digest; the read-backs read without a credential,
// as every cluster pulls.
const platformPublish = (registry) => renderChart('consumer-build', ['--set', `global.buildRegistry=${registry}`, '--set-json', 'unit=' +
  JSON.stringify({name: 'hostyour-cloud', repoURL: 'https://github.com/simetrixch/hostyour-cloud.git', buildsJson: '[]'})])
  .find((d) => d.kind === 'Pipeline' && d.metadata.name === 'hostyour-cloud-publish');
const mirrorProblems = (pipeline) => {
  const problems = [], task = (name) => pipeline.spec.tasks.find((t) => t.name === name);
  const mirror = task('mirror');
  if (!mirror) return ['the publish pipeline of the platform tree has no mirror task'];
  const steps = mirror.taskSpec.steps, step = (name) => steps.find((s) => s.name === name);
  if (steps.map((s) => s.name).join(' ') !== 'list copy read-back fetch copy-sources read-back-sources') {
    problems.push(`the mirror runs ${steps.map((s) => s.name).join(', ')}, not list, copy, read-back, fetch, copy-sources and read-back-sources`);
  }
  const holding = pipeline.spec.tasks.filter((t) => JSON.stringify(t).includes('image-builder-registry-push')).map((t) => t.name);
  if (holding.join(' ') !== 'push mirror') problems.push(`the push credential is held by ${holding.join(', ')}, not by push and mirror`);
  const secretSteps = steps.filter((s) => JSON.stringify(s).includes('image-builder-registry-push')).map((s) => s.name);
  if (secretSteps.join(' ') !== 'copy copy-sources') problems.push(`the push credential stands in the mirror steps ${secretSteps.join(', ')}, not in copy and copy-sources alone`);
  if (!/^quay\.io\/skopeo\/stable:v[0-9.]+-immutable@sha256:[0-9a-f]{64}$/.test(step('copy')?.image ?? '')) problems.push(`copy runs ${step('copy')?.image}, not the immutable skopeo image by its digest`);
  if ((step('copy')?.script ?? '').includes('scripts/')) problems.push('copy runs a script of the repository');
  if (!/^alpine\/k8s:[0-9.]+@sha256:[0-9a-f]{64}$/.test(step('copy-sources')?.image ?? '')) problems.push(`copy-sources runs ${step('copy-sources')?.image}, not alpine/k8s by its digest`);
  if ((step('copy-sources')?.script ?? '').includes('scripts/')) problems.push('copy-sources runs a script of the repository');
  if (!(step('fetch')?.script ?? '').includes('bash scripts/list-mirror-sources.sh')) problems.push('the fetch step never runs scripts/list-mirror-sources.sh');
  const fixed = readFileSync(`${CI_FILES}/ci-fixed-tools.sh`, 'utf8').trimEnd(), list = step('list')?.script ?? '';
  const fixedAt = list.indexOf(fixed), runAt = list.indexOf('bash scripts/list-mirror-images.sh');
  if (runAt < 0) problems.push('the list step never runs scripts/list-mirror-images.sh');
  else if (fixedAt < 0 || fixedAt > runAt) problems.push('the list step runs scripts/list-mirror-images.sh without helm and yq of files/ci-fixed-tools.sh before it');
  if (JSON.stringify(mirror.runAfter) !== '["push"]') problems.push(`the mirror runs after ${mirror.runAfter}, not after push`);
  if (JSON.stringify(mirror.when) !== JSON.stringify([{input: '$(tasks.scan.results.mode)', operator: 'in', values: ['mirror']}])) problems.push('the mirror runs for another scan mode than mirror');
  if (!JSON.stringify(task('reviewed').when).includes('"mirror"')) problems.push('the tag of the platform tree is not held to the default branch before the mirror');
  for (const s of steps) for (const side of ['requests', 'limits']) if (!(s.computeResources?.[side]?.cpu && s.computeResources?.[side]?.memory)) problems.push(`mirror/${s.name} has no ${side}`);
  return problems;
};

test('the publish run of the platform tree on the owner\'s master copies its images, tools and charts into the mirror, with the push credential in copy and copy-sources alone', () => {
  const pipeline = platformPublish('zot.check.example.invalid/simetrixch');
  assert.deepEqual(mirrorProblems(pipeline), [], 'PLANTED INNOCENT: the publish pipeline of the platform tree as rendered');
  const env = (step, key) => pipeline.spec.tasks.find((t) => t.name === step[0]).taskSpec.steps.find((s) => s.name === step[1]).env.find((e) => e.name === key).value;
  assert.equal(env(['scan', 'scan'], 'MIRRORS_IMAGES'), 'true');
  assert.deepEqual([env(['mirror', 'copy'], 'REGISTRY'), env(['mirror', 'copy'], 'OWNER'), env(['mirror', 'read-back'], 'REGISTRY')],
    ['zot.check.example.invalid', 'simetrixch', 'zot.check.example.invalid'], 'the mirror is the registry of global.buildRegistry');
  for (const name of ['fetch', 'copy-sources', 'read-back-sources']) {
    assert.deepEqual([env(['mirror', name], 'REGISTRY'), env(['mirror', name], 'OWNER')], ['zot.check.example.invalid', 'simetrixch'],
      `${name} names its rows under the registry and owner of global.buildRegistry`);
  }
  assert.equal(pipeline.spec.tasks.find((t) => t.name === 'push').when[0].values.includes('mirror'), false, 'the platform tree pushes no package');
  const plant = (change) => { const planted = structuredClone(pipeline); change(planted.spec.tasks.find((t) => t.name === 'mirror').taskSpec.steps); return mirrorProblems(planted); };
  assert.notDeepEqual(plant((steps) => { steps[0].envFrom = steps[1].envFrom; }), [], 'PLANTED DEFECT: the push credential beside the list the repository\'s script prints');
  assert.notDeepEqual(plant((steps) => { steps[0].script = steps[0].script.replace(readFileSync(`${CI_FILES}/ci-fixed-tools.sh`, 'utf8').trimEnd(), ''); }), [],
    'PLANTED DEFECT: the list step without the fixed tools');
  assert.notDeepEqual(plant((steps) => { steps[1].image = 'quay.io/skopeo/stable:v1.22.3'; }), [], 'PLANTED DEFECT: skopeo by a tag that is rebuilt every night');
  assert.notDeepEqual(plant((steps) => { steps.pop(); }), [], 'PLANTED DEFECT: a mirror whose tools and charts are never read back');
  const named = (steps, name) => steps.find((s) => s.name === name);
  assert.notDeepEqual(plant((steps) => { named(steps, 'fetch').envFrom = steps[1].envFrom; }), [], 'PLANTED DEFECT: the push credential in fetch, which downloads from the upstreams');
  assert.notDeepEqual(plant((steps) => { named(steps, 'read-back-sources').envFrom = steps[1].envFrom; }), [], 'PLANTED DEFECT: the push credential in read-back-sources');
  assert.notDeepEqual(plant((steps) => { named(steps, 'copy-sources').script += '\nbash scripts/list-mirror-sources.sh\n'; }), [],
    'PLANTED DEFECT: copy-sources runs the script of the repository');
  assert.notDeepEqual(plant((steps) => { named(steps, 'copy-sources').image = 'alpine/k8s:1.35.6'; }), [], 'PLANTED DEFECT: copy-sources on alpine/k8s by a tag');
  assert.notDeepEqual(plant((steps) => { steps.splice(steps.indexOf(named(steps, 'fetch')), 1); }), [], 'PLANTED DEFECT: a mirror without fetch');
  assert.notDeepEqual(plant((steps) => { steps.splice(1, 0, ...steps.splice(steps.indexOf(named(steps, 'fetch')), 1)); }), [], 'PLANTED DEFECT: fetch before copy');
  // Only the platform tree on the owner's master mirrors: its trunk value of global.buildRegistry names another registry
  // than the stand-in cluster's, and every other unit's publish pipeline is the one the test above holds.
  const elsewhere = platformPublish('zot.elsewhere.example.invalid/simetrixch');
  assert.deepEqual(elsewhere.spec.tasks.map((t) => t.name), ['gate', 'clone', 'scan', 'reviewed', 'pack', 'build-binaries', 'push']);
  assert.equal(elsewhere.spec.tasks.find((t) => t.name === 'scan').taskSpec.steps[0].env.find((e) => e.name === 'MIRRORS_IMAGES').value, 'false');
  assert.equal(renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish').spec.tasks
    .find((t) => t.name === 'scan').taskSpec.steps[0].env.find((e) => e.name === 'MIRRORS_IMAGES').value, 'false');
});

// Two tools are pinned for the repositories that name them in ci-tools.json, and both steps that build a repository install
// them: the check of the ci, before scripts/test.sh, and pack of the publish pipeline, before its packages are built.
// digita-platform's packages/quickjs/build.sh runs only with emcc 5.0.1 first on PATH; its row pins the SDK release emsdk
// 14c18b56 installs for 5.0.1. hostyour-deploy's access-log fixture needs the Traefik release its clusters run, 3.6.2; its
// row pins the linux_amd64 archive of that release, whose sha256 the release's traefik_v3.6.2_checksums.txt names. Each row
// pins its archive by its sha256; release holds a part of its url and what that part reads for another release, the
// planted defect.
const PINNED_ROWS = [
  {row: 'emcc 5.0.1 bda6917b630fcc604cca39af433180adfd7195e378075331ceac926553684249 https://storage.googleapis.com/webassembly/emscripten-releases-builds/linux/bf32ae8b61ac8efeb7eca01b54c8307f992724f7/wasm-binaries.tar.xz',
    release: ['bf32ae8b61ac8efeb7eca01b54c8307f992724f7', '8c5f43157a3f069ade75876e23061330521eabde']},
  {row: 'traefik 3.6.2 edc04e863795d741bdba8d70fbc1fd721b16edace829f8f25b0e13a9a34cb134 https://zot.master.digitacloud.app/v2/simetrixch/github.com/traefik/traefik/releases/download/v3.6.2/traefik_v3.6.2_linux_amd64.tar.gz/blobs/sha256:<sha256>',
    release: ['/v3.6.2/traefik_v3.6.2_', '/v3.6.1/traefik_v3.6.1_']},
];
const pinnedRowProblems = (task, tools, runs, pinned) => {
  const installer = readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8').trimEnd();
  const step = task.taskSpec.steps.find((s) => s.script.includes(runs)), problems = [];
  if (!step) return [`no step runs ${runs}`];
  const env = (name) => step.env?.find((e) => e.name === name)?.value;
  const tool = pinned.split(' ')[0];
  const rows = (env('CI_TOOLS_TABLE') ?? '').split('\n').filter((line) => line.startsWith(`${tool} `));
  if (rows.join('\n') !== pinned) problems.push(`${task.name} is handed ${rows.length ? rows.join(' and ') : `no ${tool} row`}, and not ${pinned}`);
  const handed = task.name === 'ci' ? env('CI_TOOLS_FILE') === tools : task.params?.find((p) => p.name === 'tools')?.value === tools && env('CI_TOOLS') === '$(params.tools)';
  if (!handed) problems.push(`${task.name} is not handed the tools of ci-tools.json from ${tools}`);
  const installerAt = step.script.indexOf(installer);
  if (installerAt < 0 || installerAt > step.script.indexOf(runs)) problems.push(`${task.name} runs ${runs} before files/ci-install-tools.sh`);
  return problems;
};

test('the check of the ci and pack of the publish pipeline put the pinned emcc 5.0.1 and traefik 3.6.2 first on PATH before they build', () => {
  const ci = ciPipeline().spec.tasks.find((t) => t.name === 'ci');
  const pack = renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish').spec.tasks.find((t) => t.name === 'pack');
  const holds = [[ci, '$(results.tools.path)', 'bash scripts/test.sh'], [pack, '$(tasks.scan.results.tools)', 'build_packages /workspace/packed/publishable.tsv']];
  const installer = readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8').trimEnd();
  const plant = (task, edit) => { const copy = structuredClone(task); edit(copy.taskSpec.steps.find((s) => s.env?.some((e) => e.name === 'CI_TOOLS_TABLE')), copy); return copy; };
  const table = (edit) => (step) => { const e = step.env.find((x) => x.name === 'CI_TOOLS_TABLE'); e.value = edit(e.value); };
  for (const {row, release: [named, another]} of PINNED_ROWS) {
    const [tool, version] = row.split(' ');
    for (const [task, tools, runs] of holds) assert.deepEqual(pinnedRowProblems(task, tools, runs, row), [], `PLANTED INNOCENT: ${task.name} as rendered, for ${tool}`);
    assert.ok(TOOLS_TABLE.split('\n').includes(row), `the table file carries the ${tool} row`);
    const defects = {
      [`the ${tool} row missing`]: table((value) => value.replace(`${row}\n`, '')),
      'another sha256': table((value) => value.replace(row, row.replace(/ [0-9a-f]{64} /, ` ${'0'.repeat(64)} `))),
      'another release': table((value) => value.replace(row, row.replace(named, another))),
      'another version': table((value) => value.replace(`${tool} ${version} `, `${tool} ${version}9 `)),
      'the installer removed': (step) => { step.script = step.script.replace(installer, ''); },
      'the tools of ci-tools.json not handed over': (step, task) => { task.params = task.params.filter((p) => p.name !== 'tools'); step.env = step.env.filter((e) => e.name !== 'CI_TOOLS_FILE'); },
    };
    for (const [task, tools, runs] of holds) {
      for (const [defect, edit] of Object.entries(defects)) {
        assert.notDeepEqual(pinnedRowProblems(plant(task, edit), tools, runs, row), [], `PLANTED DEFECT: ${task.name} with ${defect}`);
      }
    }
    const late = plant(pack, (step) => { step.script = `${step.script.replace(installer, '')}\n${installer}`; });
    assert.notDeepEqual(pinnedRowProblems(late, '$(tasks.scan.results.tools)', 'build_packages /workspace/packed/publishable.tsv', row), [], `PLANTED DEFECT: pack installs ${tool} after it built its packages`);
  }
});

// A step that runs a repository's own code runs as the user of its image, pptruser, uid 10042, and not as root: root keeps
// CAP_DAC_OVERRIDE and reads and writes through any mode, so a test that expects a directory to refuse a write (ansiwise-core
// run_removal_test.dart, ansiwise-cli record_not_removed_test.dart) goes red. Two steps run those suites: the check of the ci,
// and build-binaries of the publish pipeline, whose release/build.sh gates every part and the repository before it builds.
// What root did for them is done otherwise: the folders pods of root made are handed to that user by a step of root before
// it, and the check script installs and writes only below places that user owns.
const CHECK_USER = 10042;
const OWNED_BY_CHECK_USER = ['/tmp', '/workspace', '/dev/shm', '/ci-cache', '/npmrc', '/home/pptruser'];
// What is wrong with the user `step` runs as, and with `handOver`, the step of root that hands it `folders` first.
const userProblems = (step, handOver, folders) => {
  const user = step.securityContext?.runAsUser;
  const problems = [];
  if (!(user > 0 && step.securityContext?.runAsNonRoot === true)) problems.push(`the ${step.name} step may run as root`);
  if (user !== CHECK_USER) problems.push(`the ${step.name} step runs as ${user}, not as the user of its image, ${CHECK_USER}`);
  if (!new RegExp(`^chown -R -h ${user} ${folders}$`, 'm').test(handOver?.script ?? '')) problems.push(`${folders} is not handed to ${user} before the ${step.name} step`);
  return problems;
};
const checkUserProblems = (pipeline) => {
  const check = ciStep(pipeline, 'check');
  const problems = userProblems(check, ciStep(pipeline, 'hand-over'), '/workspace/source');
  // The commands of the script, without comments and urls, and every absolute path they name.
  const code = check.script.split('\n').filter((line) => !/^\s*#(?!!)/.test(line)).join('\n').replace(/https?:\/\/\S+/g, '');
  for (const path of new Set(code.match(/(?<![\w.$}/:-])\/[\w.*-]+(?:\/[\w.${}*-]+)*/g))) {
    if (path !== '/usr/bin/env' && !OWNED_BY_CHECK_USER.some((place) => path === place || path.startsWith(`${place}/`))) problems.push(`the check script names ${path}, which its user does not own`);
  }
  if (/corepack enable(?! --install-directory)/.test(code)) problems.push('corepack enable puts its shims beside node, where its user cannot write');
  return problems;
};

test('the check step runs as the user of its image, takes the clone from the fetch task, and writes only where that user can', () => {
  const pipeline = ciPipeline();
  assert.deepEqual(checkUserProblems(pipeline), [], 'PLANTED INNOCENT: the pipeline as rendered');
  const planted = (change) => { const copy = structuredClone(pipeline); change(ciTaskSpec(copy), ciTaskSpec(copy)); return checkUserProblems(copy); };
  const asRoot = planted((check) => { check.steps.find((s) => s.name === 'check').securityContext = {runAsUser: 0, allowPrivilegeEscalation: false}; });
  assert.ok(asRoot.includes('the check step may run as root'), 'PLANTED DEFECT: the check step as it ran before, uid 0');
  const unset = planted((check) => { delete check.steps.find((s) => s.name === 'check').securityContext; });
  assert.ok(unset.includes('the check step may run as root'), 'PLANTED DEFECT: a check step that leaves the user to the image is not held to a user');
  assert.ok(planted((check, fetch) => { const handOver = fetch.steps.find((s) => s.name === 'hand-over'); handOver.script = handOver.script.replace(`${CHECK_USER}`, '1000'); }).some((p) => p.includes('is not handed')), 'PLANTED DEFECT: a clone handed to another user than the check runs as');
  assert.ok(planted((check, fetch) => { fetch.steps.splice(fetch.steps.findIndex((s) => s.name === 'hand-over'), 1); }).some((p) => p.includes('is not handed')), 'PLANTED DEFECT: a clone nobody hands over stays root\'s, and the check cannot write into it');
  const script = (find, replace) => planted((check) => { const step = check.steps.find((s) => s.name === 'check'); assert.ok(step.script.includes(find)); step.script = step.script.replaceAll(find, replace); });
  assert.ok(script('ci_bin=/tmp/ci-bin', 'ci_bin=/usr/local/bin').some((p) => p.includes('/usr/local/bin')), 'PLANTED DEFECT: tools installed into a directory of root');
  assert.ok(script('corepack enable --install-directory "${ci_bin}"', 'corepack enable').some((p) => p.includes('corepack enable')), 'PLANTED DEFECT: shims written beside node');
});

test('build-binaries runs release/build.sh as the user the ci check runs as, after a step of root hands it the clone and the output', () => {
  const pipeline = renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish');
  const problems = (p) => {
    const steps = p.spec.tasks.find((t) => t.name === 'build-binaries').taskSpec.steps;
    return userProblems(steps.find((s) => s.name === 'build'), steps[0], '/workspace/source /workspace/packed');
  };
  assert.deepEqual(problems(pipeline), [], 'PLANTED INNOCENT: the pipeline as rendered');
  const steps = (p) => p.spec.tasks.find((t) => t.name === 'build-binaries').taskSpec.steps;
  // The ci hand-over differs by its guard for a commit that is green already and by the mounts of its volume, which the publish pod has not.
  const {volumeMounts, ...handOver} = ciTask().steps.find((s) => s.name === 'hand-over');
  assert.ok(volumeMounts.length > 0);
  assert.deepEqual([steps(pipeline)[0], steps(pipeline).find((s) => s.name === 'build').securityContext],
    [{...handOver, script: handOver.script.replace(/^if \[ -e .*\n/m, '').replace('/workspace/source', '/workspace/source /workspace/packed')}, ciTask().steps.find((s) => s.name === 'check').securityContext],
    'one shape: the hand-over and the user of the build are the ci\'s, apart from the folder the binaries are left in');
  const planted = (change) => { const copy = structuredClone(pipeline); change(steps(copy), steps(copy).find((s) => s.name === 'build')); return problems(copy); };
  assert.ok(planted((all, build) => { build.securityContext = {runAsUser: 0, allowPrivilegeEscalation: false}; }).includes('the build step may run as root'),
    'PLANTED DEFECT: build-binaries as it ran before, uid 0, where record_not_removed_test.dart is red');
  assert.ok(planted((all, build) => { delete build.securityContext; }).includes('the build step may run as root'), 'PLANTED DEFECT: a build that leaves the user to the image');
  assert.ok(planted((all) => { all[0].script = all[0].script.replace(' /workspace/packed', ''); }).some((p) => p.includes('is not handed')),
    'PLANTED DEFECT: an output folder left to root, where release/build.sh cannot write the binaries');
  assert.ok(planted((all) => { all.reverse(); }).some((p) => p.includes('is not handed')), 'PLANTED DEFECT: the hand-over after the build');
  assert.ok(planted((all) => { all.shift(); }).some((p) => p.includes('is not handed')), 'PLANTED DEFECT: a clone nobody hands over');
});

// The lines of the check step from the install on, with stand-ins that record in which order the install, the push gate
// and the fixture suites ran: the events, and whether the step ended green.
const runInstallSteps = (script, {files = [], tools = '', testExit = 0}) => {
  const root = mkdtempSync(join(tmpdir(), 'ci-steps-')), repo = join(root, 'repo'), bin = join(root, 'bin'), log = join(root, 'events');
  mkdirSync(join(repo, 'scripts'), {recursive: true}); mkdirSync(bin);
  const stub = (path, body) => { writeFileSync(path, `#!/usr/bin/env bash\n${body}\n`); chmodSync(path, 0o755); };
  for (const file of files) writeFileSync(join(repo, file), '');
  stub(join(bin, 'pnpm'), `echo pnpm >> "${log}"`);
  stub(join(bin, 'npm'), `echo "npm $*" >> "${log}"`);
  stub(join(repo, 'scripts/check.sh'), `echo check >> "${log}"`);
  if (files.includes('scripts/test.sh')) stub(join(repo, 'scripts/test.sh'), `echo test >> "${log}"\nexit ${testExit}`);
  try {
    const result = spawnSync('bash', ['-euo', 'pipefail', '-c', script], {cwd: repo, encoding: 'utf8', env: {...process.env, CI_TOOLS: tools, PATH: `${bin}:${process.env.PATH}`}});
    return {green: result.status === 0, events: existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n') : []};
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
};

test('the ci check runs the install the repository declares, then scripts/test.sh, and never scripts/check.sh a second time', () => {
  const lines = ciTask().steps.find((s) => s.name === 'check').script.split('\n');
  const steps = lines.slice(lines.findIndex((line) => line.includes('pnpm install'))).join('\n');
  const NPM = 'npm 12.2.0\n', LOCKS = ['package.json', 'package-lock.json'];
  assert.deepEqual(runInstallSteps(steps, {files: [...LOCKS, 'ci-tools.json', 'scripts/test.sh'], tools: NPM}), {green: true, events: ['npm ci', 'test']},
    'PLANTED INNOCENT: a repository that names npm is installed with npm ci, then its suites run');
  assert.deepEqual(runInstallSteps(steps, {files: [...LOCKS, 'pnpm-lock.yaml', 'ci-tools.json', 'scripts/test.sh'], tools: NPM}), {green: true, events: ['pnpm', 'npm ci', 'test']}, 'pnpm first where it has a lockfile');
  assert.deepEqual(runInstallSteps(steps, {files: [...LOCKS, 'scripts/test.sh']}), {green: true, events: ['test']}, 'PLANTED INNOCENT: an npm lockfile of a repository that names no npm is left alone, as before');
  assert.deepEqual(runInstallSteps(steps, {files: ['ci-tools.json']}), {green: false, events: []}, 'a repository without scripts/test.sh fails the run: it has nothing to run that its push gate did not');
  assert.deepEqual(runInstallSteps(steps, {files: ['scripts/test.sh'], testExit: 1}), {green: false, events: ['test']}, 'red suites end the step red');
  const withoutCondition = (pattern, replacement) => { const changed = steps.split('\n').map((line) => (pattern.test(line) ? replacement : line)).join('\n'); assert.notEqual(changed, steps); return changed; };
  assert.deepEqual(runInstallSteps(withoutCondition(/npm ci/, '            npm ci'), {files: [...LOCKS, 'scripts/test.sh']}).events, ['npm ci', 'test'], 'PLANTED DEFECT: an npm ci that runs for every repository is seen');
  const gateAgain = steps.replace('bash scripts/test.sh', 'bash scripts/check.sh\nbash scripts/test.sh');
  assert.notEqual(gateAgain, steps);
  assert.deepEqual(runInstallSteps(gateAgain, {files: ['scripts/test.sh']}).events, ['check', 'test'], 'PLANTED DEFECT: the push gate run a second time in the ci is seen');
  const lenient = steps.replace(/if \[ ! -f scripts\/test\.sh \]; then\n[^\n]*\n[^\n]*exit 1\n[ \t]*fi\n[ \t]*bash scripts\/test\.sh/, 'if [ -f scripts/test.sh ]; then bash scripts/test.sh; fi');
  assert.notEqual(lenient, steps);
  assert.deepEqual(runInstallSteps(lenient, {files: ['ci-tools.json']}), {green: true, events: []}, 'PLANTED DEFECT: a repository without suites that passes green is seen');
});

const seconds = (duration) => ['h', 'm', 's'].reduce((sum, unit, i) => sum + Number(new RegExp(`(\\d+)${unit}`).exec(duration)?.[1] ?? 0) * [3600, 60, 1][i], 0);

test('every step of the ci pipeline has requests and limits, and a run that waits for the quota outlives its tasks', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const stepsOf = (task) => task.taskSpec.steps;
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
  assert.deepEqual(bounds, {ci: 2640}, 'the one task is bounded by the sum of the caps of the six tasks it replaced');
  assert.deepEqual([seconds(ciStep(pipeline, 'clone').timeout), seconds(ciStep(pipeline, 'check').timeout)], [600, 1200]);
  const report = pipeline.spec.finally.find((t) => t.name === 'report-failure');
  for (const step of report.taskSpec.steps) {
    for (const side of ['requests', 'limits']) assert.ok(step.computeResources?.[side]?.cpu && step.computeResources?.[side]?.memory, `report-failure/${step.name} has ${side}`);
  }
  assert.equal(seconds(report.timeout), 300);
  assert.equal(seconds(pipeline.spec.finally.find((t) => t.name === 'commit-status').timeout), 120);
  // Tekton sets no start time on a waiting run, so the clocks start when the keeper starts it and hold no wait for a ci slot.
  // They do hold the wait of a pod for the quota of its unit: Tekton restarts the clock of a task, never that of the run.
  // The finally tasks run on a clock of their own, so a run that used up its tasks budget still mails.
  const timeouts = imageBuilder().find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === 'ci-push').spec.resourcetemplates[0].spec.timeouts;
  const mailsAfterTimeout = (t) => Boolean(t.tasks && t.finally) && seconds(t.pipeline) >= seconds(t.tasks) + seconds(t.finally) &&
    seconds(t.tasks) >= Object.values(bounds).reduce((a, b) => a + b, 0) && seconds(t.finally) >= seconds(report.timeout);
  assert.ok(mailsAfterTimeout(timeouts), 'PLANTED INNOCENT: the run outlives one round of its own tasks and leaves the finally task its own time');
  assert.ok(!mailsAfterTimeout({pipeline: timeouts.pipeline}), 'PLANTED DEFECT: the pipeline timeout alone cancels the finally task with the rest');
  assert.ok(!mailsAfterTimeout({...timeouts, pipeline: '50m0s'}), 'PLANTED DEFECT: a pipeline timeout shorter than tasks plus finally');
  assert.ok(!mailsAfterTimeout({...timeouts, tasks: '30m0s'}), 'PLANTED DEFECT: a tasks budget that is not one round of the tasks');
  assert.ok(!mailsAfterTimeout({...timeouts, finally: '2m0s'}), 'PLANTED DEFECT: a finally budget shorter than the report task');
  // The owner's bound (2026-10-19): the longest finished run of 1540 was 20.1 minutes, and the tasks budget is one minute above one
  // round of the task caps, so a run whose tasks stay inside their caps never meets it.
  assert.deepEqual(timeouts, {pipeline: '55m0s', tasks: '45m0s', finally: '10m0s'});
});

test('the bound of a ci run is set in ciPush.timeouts, each of its three clocks is required, and the TriggerTemplate carries them', () => {
  const ciPush = (timeouts) => ['--set-json', `ciPush=${JSON.stringify({repositories: ['one/a'], pinIdentity: {name: 'pin', email: 'pin@example.com'}, ...(timeouts ? {timeouts} : {})})}`];
  const rendered = (timeouts) => renderChart('image-builder', ciPush(timeouts)).find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === 'ci-push')
    .spec.resourcetemplates[0].spec.timeouts;
  const given = {pipeline: '11m0s', tasks: '7m0s', finally: '3m0s'};
  assert.deepEqual(rendered(given), given, 'PLANTED INNOCENT: the three values of the chart reach the run, none is a literal of the template');
  for (const clock of Object.keys(given)) {
    const without = {...given};
    delete without[clock];
    assert.throws(() => rendered(without), new RegExp(`ciPush\\.timeouts\\.${clock} is required`), `PLANTED DEFECT: a run without its ${clock} clock`);
  }
  assert.throws(() => rendered(undefined), /ciPush\.timeouts\.pipeline is required/, 'PLANTED DEFECT: a run without any bound');
});

// The scheduler admits a pod by its requests, and the kernel kills by QoS class when the node runs out of
// memory, so what bounds the damage to the platform pods is a sum of limits that stays within a budget
// (ciCapacity.limitsMemoryBudget). The budget is not the free memory of the node: the owner accepted that the
// worst case, every pod at its limit, exceeds it.
// The sum is the limits of the ci pods of the runs that run at once (one at a time per run, because the tasks form a
// chain, and the finally task commit-status runs after them in the same class), the report pod of each of those runs
// (its class is the one the quota does not count, so it comes on top), plus the pods that the queue's runs have alive at
// once. The queue runs one release or publish run per unit and releaseSlots runs in all (queueStartsOf below proves that
// on the queue's own decision), so the slots hold the releaseSlots largest distinct units, each the larger of its release
// run and its publish run, as the ci term holds the largest distinct ci units. What a run has alive at once is the
// heaviest set of its tasks that none waits for another, read from the rendered runAfter, result and when references and
// the finally tasks (peakConcurrent), not every task of every stage. A unit builds the number of images that
// ciCapacity.releaseUnitImages declares for it. The ci run keeper holds the number of running runs at maxRunning.
// The same sum of CPU requests, with the requests of the pods that stand on the node on top, is held to the cores of
// the node by the test of the check step's cores below.
const BYTES = {Gi: 1024 ** 3, Mi: 1024 ** 2};
const quantity = (text) => Number(text.slice(0, -2)) * BYTES[text.slice(-2)];
// The Task a pipeline task runs: its own spec, or the shared Task of image-builder that its cluster resolver names.
const sharedTaskName = (task) => task.taskRef.params?.find((param) => param.name === 'name')?.value ?? task.taskRef.name;
const podSteps = (task, shared) => {
  if (task.taskSpec) return task.taskSpec.steps;
  assert.ok(shared.has(sharedTaskName(task)), `${task.name} runs the shared Task ${sharedTaskName(task)}, which image-builder does not render`);
  return shared.get(sharedTaskName(task)).spec.steps;
};
// What a pod holds at once. The steps of a pod run one after the other, so the one pod of a ci run, ten steps of which only the
// check is large, holds its largest step; the pods of the release and the publish pipelines are counted by the sum of their steps,
// as the budget has always counted them.
const holdsAtOnce = (task, amounts) => (task.name === 'ci' ? Math.max(...amounts) : amounts.reduce((sum, amount) => sum + amount, 0));
const podLimit = (task, shared) => holdsAtOnce(task, podSteps(task, shared).map((step) => quantity(step.computeResources.limits.memory)));
// A CPU limit reserves nothing: the kernel only slows a pod that asks for more than its share, so the limits may add up
// to more than the node has, and one limit may not exceed it. What the scheduler holds to the cores is the requests.
const milliCores = (text) => (text.endsWith('m') ? Number(text.slice(0, -1)) : Number(text) * 1000);
const podRequest = (task, shared) => holdsAtOnce(task, podSteps(task, shared).map((step) => milliCores(step.computeResources.requests.cpu)));
const withSharedTask = (shared, name, edit) => {
  const task = structuredClone(shared.get(name));
  edit(task);
  return new Map(shared).set(name, task);
};
// The most that a pipeline run has alive at once, by the weight of its pods: the heaviest set of tasks none of which
// waits for another, directly or through others. A task waits for what its runAfter and the results, statuses and
// when expressions of its params name; a finally task waits for every task; two finally tasks run together.
const peakConcurrent = (pipeline, weigh) => {
  const tasks = pipeline.spec.tasks, finals = pipeline.spec.finally ?? [], nodes = [...tasks, ...finals];
  const named = (task) => [...JSON.stringify(task).matchAll(/\$\(tasks\.([a-z0-9-]+)\./g)].map((match) => match[1]);
  const direct = new Map(nodes.map((task) => [task.name, finals.includes(task) ? tasks.map((t) => t.name) : [...new Set([...(task.runAfter ?? []), ...named(task)])]]));
  const waitsFor = new Map();
  const ancestors = (name) => {
    assert.ok(direct.has(name), `${pipeline.metadata.name} waits for ${name}, which is no task of it`);
    if (!waitsFor.has(name)) waitsFor.set(name, new Set(direct.get(name).flatMap((before) => [before, ...ancestors(before)])));
    return waitsFor.get(name);
  };
  // The weight of the heaviest set of tasks none of which waits for another is the sum of all weights less a maximum flow
  // (Dilworth): each task offers its weight on the left, takes it on the right, and passes it to every task that waits for it.
  const count = nodes.length, source = 2 * count, sink = source + 1;
  const capacity = Array.from({length: sink + 1}, () => new Array(sink + 1).fill(0));
  const weights = nodes.map(weigh);
  nodes.forEach((task, i) => {
    capacity[source][i] = weights[i];
    capacity[count + i][sink] = weights[i];
    nodes.forEach((later, j) => { if (ancestors(later.name).has(task.name)) capacity[i][count + j] = Infinity; });
  });
  let flow = 0;
  for (;;) {
    const from = new Array(sink + 1).fill(-1);
    from[source] = source;
    for (let queue = [source]; queue.length && from[sink] < 0; queue = queue.slice(1)) {
      for (let next = 0; next <= sink; next += 1) {
        if (from[next] < 0 && capacity[queue[0]][next] > 0) { from[next] = queue[0]; queue.push(next); }
      }
    }
    if (from[sink] < 0) break;
    let push = Infinity;
    for (let at = sink; at !== source; at = from[at]) push = Math.min(push, capacity[from[at]][at]);
    for (let at = sink; at !== source; at = from[at]) { capacity[from[at]][at] -= push; capacity[at][from[at]] += push; }
    flow += push;
  }
  return weights.reduce((sum, weight) => sum + weight, 0) - flow;
};
const MEMORY = {pod: podLimit, standing: () => 0, budget: (capacity) => quantity(capacity.limitsMemoryBudget)};
const CORES = {pod: podRequest, standing: (capacity) => milliCores(capacity.standingCpuRequests), budget: (capacity) => milliCores(capacity.nodeCpu)};
// What the releaseSlots slots of the queue hold at most: the largest distinct units, each the larger of its release run and its publish run.
const largestQueued = (capacity, units, weigh) => units.map(({release, publish}) => Math.max(peakConcurrent(release, weigh), peakConcurrent(publish, weigh)))
  .sort((a, b) => b - a).slice(0, capacity.releaseSlots).reduce((sum, weight) => sum + weight, 0);
const fitsBudget = (capacity, pipeline, shared, units, size = MEMORY) => {
  const weigh = (task) => size.pod(task, shared);
  const largest = (tasks) => Math.max(0, ...tasks.map(weigh));
  const isReport = (task) => task.name === 'report-failure';
  const pipelines = Array.isArray(pipeline) ? pipeline : Array(capacity.maxRunning).fill(pipeline);
  assert.ok(pipelines.length >= capacity.maxRunning, 'the budget needs at least one distinct eligible unit per ci slot');
  const ciPods = pipelines.map((unit) => largest([...unit.spec.tasks, ...unit.spec.finally.filter((t) => !isReport(t))]) +
    largest(unit.spec.finally.filter(isReport))).sort((a, b) => b - a).slice(0, capacity.maxRunning).reduce((sum, limit) => sum + limit, 0);
  return ciPods + largestQueued(capacity, units, weigh) + size.standing(capacity) <= size.budget(capacity);
};
const readCiCapacity = () => ({...JSON.parse(execFileSync('yq', ['-o=json', '.ciCapacity', 'clusters/inventories/consumer-build/values-common.yaml'], {encoding: 'utf8'})),
  maxRunning: Number(execFileSync('yq', ['.ciRunKeeper.maxRunning', 'clusters/inventories/image-builder/values-common.yaml'], {encoding: 'utf8'})),
  releaseSlots: Number(execFileSync('yq', ['.releaseQueue.maxRunning', 'clusters/inventories/image-builder/values-common.yaml'], {encoding: 'utf8'}))});
const imageNames = (count) => Array.from({length: count}, (_, i) => `image-${i + 1}`);
const pipelineOf = (docs, name) => docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === name);
// The release and the publish pipeline of each unit the queue can hold in a slot, the release drawn with the number of images the unit builds at once.
const releaseUnitsOf = (images) => Object.entries(images).map(([name, count]) => {
  const docs = renderUnit(name, imageNames(count));
  return {name, images: count, release: pipelineOf(docs, `${name}-release`), publish: pipelineOf(docs, `${name}-publish`)};
});
const withUnits = (units, edit) => units.map((unit) => edit(structuredClone(unit)));
const declaresEveryCount = (images) => Object.values(images).every((count) => Number.isInteger(count) && count >= 1);
const largestUnit = (units) => units.reduce((largest, unit) => (unit.images > largest.images ? unit : largest));
// The charts the budgets are drawn for: the ci pipeline of an ordinary unit and the releases of the declared units.
const ciPlane = (capacity) => {
  const docs = renderUnit('shop');
  return {docs,
    pipeline: pipelineOf(docs, 'shop-ci'),
    units: releaseUnitsOf(capacity.releaseUnitImages),
    shared: new Map(imageBuilder().filter((d) => d.kind === 'Task').map((d) => [d.metadata.name, d]))};
};
// The queue's own decision on planted waiting runs: which units its tick starts at once. `edit` rewrites the program, to plant a defect.
const RELEASE_QUEUE_JQ = 'clusters/inventories/image-builder/files/release-queue.jq';
const queueStartsOf = (units, stages, slots, edit = (program) => program) => {
  const dir = mkdtempSync(join(tmpdir(), 'release-queue-'));
  try {
    writeFileSync(join(dir, 'release-queue.jq'), edit(readFileSync(RELEASE_QUEUE_JQ, 'utf8')));
    const items = units.flatMap((unit, u) => Array.from({length: stages}, (_, stage) => ({
      metadata: {namespace: `${unit}-build`, name: `${unit}-release-${stage}`, creationTimestamp: `2026-10-18T05:${String(u).padStart(2, '0')}:${String(stage).padStart(2, '0')}Z`},
      spec: {status: 'PipelineRunPending', pipelineRef: {name: `${unit}-release`}, params: [{name: 'release-tag', value: '1.0.0-stable-1'}]}, status: {}})));
    return execFileSync('jq', ['-c', '--argjson', 'max', String(slots), '-f', join(dir, 'release-queue.jq')], {input: JSON.stringify({items}), encoding: 'utf8'})
      .split('\n').filter(Boolean).map((line) => JSON.parse(line)).filter((change) => change.type === 'json').map((change) => change.namespace);
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
};
const channelStageCount = () => Math.max(...Object.values(JSON.parse(execFileSync('yq', ['-o=json', '.global.channelStages', 'clusters/platform/values-common.yaml'], {encoding: 'utf8'}))).map((reached) => reached.length));
const ciMemoryPipelines = () => {
  const overrides = JSON.parse(execFileSync('yq', ['-o=json', '.ciCheckMemory.units', 'clusters/inventories/consumer-build/values-common.yaml'], {encoding: 'utf8'}));
  const names = [...Object.keys(overrides), ...Array.from({length: 14}, (_, i) => `default-unit-${i + 1}`)];
  const pipelines = names.map((name) => renderUnit(name).find((d) => d.kind === 'Pipeline' && d.metadata.name === `${name}-ci`));
  assert.equal(new Set(pipelines.map((unit) => unit.metadata.namespace)).size, pipelines.length, 'each ci limit belongs to a distinct eligible unit');
  return pipelines;
};

test('the seven largest distinct ci units and nine releases fit the 54.75Gi memory budget, which stays within the memory of the node', () => {
  const capacity = readCiCapacity();
  assert.ok(declaresEveryCount(capacity.releaseUnitImages), 'every declared unit names how many images it builds');
  assert.equal(capacity.releaseUnitImages['digita-realtime'], 1, 'digita-realtime builds its one image after the scan');
  assert.ok(declaresEveryCount({...capacity.releaseUnitImages, 'digita-realtime': 1}), 'PLANTED INNOCENT: the row of digita-realtime with its count');
  assert.ok(!declaresEveryCount({...capacity.releaseUnitImages, 'digita-realtime': null}), 'PLANTED DEFECT: a row without its count is caught');
  const {docs, pipeline, shared, units} = ciPlane(capacity);
  const pipelines = ciMemoryPipelines();
  const fits = (ciUnits = pipelines, limit = capacity, releaseUnits = units) => fitsBudget(limit, ciUnits, shared, releaseUnits);
  const [{publish}] = units;
  assert.ok(units.every((unit) => unit.publish.spec.tasks.every((t, i) => i === 0 || t.runAfter?.length === 1 && t.runAfter[0] === unit.publish.spec.tasks[i - 1].name)), 'the budget counts one publish pod, so its tasks run one after the other');
  assert.equal(String(capacity.podsPerUnit), docs.find((d) => d.kind === 'ResourceQuota').spec.hard.pods, 'the quota renders the declared pods per unit');
  // The pods that meet at the boundary of a run: its one task `ci` and the finally task commit-status, which runs after it.
  const podsAtBoundary = (p) => p.spec.tasks.length + p.spec.finally.filter((t) => t.name === 'commit-status').length;
  assert.equal(podsAtBoundary(pipeline), capacity.podsPerUnit, 'the budget counts one ci pod per running run, and the quota admits the pod of commit-status beside it');
  const thirdPod = structuredClone(pipeline);
  thirdPod.spec.tasks.push({...thirdPod.spec.tasks[0], name: 'second', runAfter: ['ci']});
  assert.notEqual(podsAtBoundary(thirdPod), capacity.podsPerUnit, 'PLANTED DEFECT: a second task of the ci pipeline is a third pod at the boundary, which the quota refuses');
  // The Buildah pods a release has alive at once: the builds, by the same reading of runAfter, results and when references as the budget.
  const buildsAlive = (release) => peakConcurrent(release, (task) => (task.name.startsWith('build-') ? 1 : 0));
  for (const unit of units) {
    assert.equal(buildsAlive(unit.release), Math.min(unit.images, capacity.releaseBuildsAtOnce), `${unit.name} builds at most releaseBuildsAtOnce of its ${unit.images} images at once`);
  }
  const swissbookai = units.find((unit) => unit.name === 'swissbookai').release;
  const secondInParallel = structuredClone(swissbookai);
  secondInParallel.spec.tasks.find((t) => t.name === 'build-image-2').runAfter = ['scan'];
  assert.equal(buildsAlive(swissbookai), 1, 'PLANTED INNOCENT: the swissbookai release as rendered builds its four images one after the other');
  assert.equal(buildsAlive(secondInParallel), 2, 'PLANTED DEFECT: a second build that waits for the scan alone runs beside the first, two Buildah pods at once, and is caught');
  const admitsNextTask = (pods) => pods === 2;
  assert.ok(admitsNextTask(capacity.podsPerUnit), 'the quota admits the pod of the next task while the finished pod before it still counts, and no more');
  assert.ok(!admitsNextTask(1), 'PLANTED DEFECT: one pod per unit refuses the next task until the finished pod is gone, and Tekton tries it again a minute later');
  assert.ok(!admitsNextTask(3), 'PLANTED DEFECT: a third pod has no task of a chain to run, and the memory budget counts one live ci pod per run');
  assert.equal(capacity.releaseBuildsAtOnce, 1, 'the owner decided on 2026-10-19 that a release builds one image at a time');
  assert.equal(capacity.releaseSlots, 9, 'the owner decided on 2026-10-19 that nine releases run at once');
  assert.ok(Object.keys(capacity.releaseUnitImages).length >= capacity.releaseSlots, 'the declared units fill every slot of the queue');
  assert.equal(quantity(capacity.limitsMemoryBudget) / BYTES.Gi, 54.75, 'the budget holds one 3.5Gi ci unit, six 3Gi ci units, seven report pods of 256Mi and nine release slots at 3.5Gi');
  const withinNode = (limit) => quantity(limit.limitsMemoryBudget) <= quantity(limit.nodeMemory);
  assert.ok(withinNode(capacity), 'PLANTED INNOCENT: the budget stands within the allocatable memory of the node');
  assert.ok(!withinNode({...capacity, limitsMemoryBudget: `${quantity(capacity.nodeMemory) / BYTES.Mi + 1}Mi`}), 'PLANTED DEFECT: a budget one Mi above the allocatable memory of the node is caught');
  assert.ok(fits(), 'PLANTED INNOCENT: the seven largest distinct ci units and the nine largest releases exactly fit');
  assert.ok(!fits(pipelines, {...capacity, limitsMemoryBudget: '56063Mi'}), 'PLANTED DEFECT: one Mi below the exact 54.75Gi sum is caught');
  assert.ok(fits(pipelines, {...capacity, releaseSlots: 2}), 'PLANTED INNOCENT: two releases at a time fit too');
  assert.ok(!fits(pipelines, {...capacity, releaseSlots: capacity.releaseSlots + 1}), 'PLANTED DEFECT: a tenth release at once is caught');
  assert.ok(!fits(pipelines, {...capacity, limitsMemoryBudget: '48896Mi'}), 'PLANTED DEFECT: nine releases on the budget of seven, 47.75Gi, are caught');
  const planted = structuredClone(pipelines);
  checkResources(planted.find((unit) => unit.metadata.name === 'digita-platform-ci')).limits.memory = '4Gi';
  assert.ok(!fits(planted), 'PLANTED DEFECT: a 4Gi override makes the sum 55.25Gi (56576Mi)');
  assert.ok(!fits(pipelines, {...capacity, maxRunning: capacity.maxRunning + 1}), 'PLANTED DEFECT: an eighth ci run at once, 58Gi (59392Mi) against the 54.75Gi budget, is caught');
  assert.ok(!fits(pipelines, {...capacity, maxRunning: 14}), 'PLANTED DEFECT: 14 distinct ci units at once are caught');
  const largestName = largestUnit(units).name;
  const largestInParallel = withUnits(units, (unit) => {
    if (unit.name === largestName) unit.release.spec.tasks.find((t) => t.name === 'build-image-2').runAfter = ['scan'];
    return unit;
  });
  assert.ok(!fits(pipelines, capacity, largestInParallel), `PLANTED DEFECT: the second build of ${largestName} waiting for the scan alone, two builds of 3072Mi in a slot of 3584Mi, is caught by the exact budget`);
  const heavyStep = structuredClone(pipelines);
  ciStep(heavyStep[0], 'sources').computeResources.limits.memory = '4Gi';
  assert.ok(!fits(heavyStep), 'PLANTED DEFECT: a step before the check that outgrows it makes the pod larger than the 3Gi counted');
  const lightSteps = structuredClone(pipelines);
  ciStep(lightSteps[0], 'sources').computeResources.limits.memory = '512Mi';
  assert.ok(fits(lightSteps), 'PLANTED INNOCENT: the steps before the check stay below it, so the pod is counted by the check');
  const heavyReport = structuredClone(pipelines);
  heavyReport[0].spec.finally[0].taskSpec.steps[0].computeResources.limits.memory = '2Gi';
  assert.ok(!fits(heavyReport), 'PLANTED DEFECT: a larger report pod outside the quota is caught');
  const heavy = withSharedTask(shared, 'buildah-build-push', (task) => { task.spec.steps.find((step) => step.name === 'build').computeResources.limits.memory = '8Gi'; });
  assert.ok(!fitsBudget(capacity, pipelines, heavy, units), 'PLANTED DEFECT: a raised buildah limit is caught');
  const formerLimits = withSharedTask(shared, 'buildah-build-push', (task) => { task.spec.steps.find((step) => step.name === 'build').computeResources.limits.memory = '4Gi'; });
  assert.ok(!fitsBudget(capacity, pipelines, formerLimits, units), 'PLANTED DEFECT: the former 4Gi build and 2Gi push limits, 6Gi a pod, at nine releases are caught');
  const heavyPublish = structuredClone(publish);
  heavyPublish.spec.tasks.find((t) => t.name === 'pack').taskSpec.steps[0].computeResources.limits.memory = '19Gi';
  assert.ok(!fits(pipelines, capacity, withUnits(units, (unit) => ({...unit, publish: heavyPublish}))), 'PLANTED DEFECT: a publish pod above a release slot is caught');
  const bigScan = withSharedTask(shared, 'credential-scan', (task) => { task.spec.steps[0].computeResources.limits.memory = '10Gi'; });
  assert.ok(!fitsBudget(capacity, pipelines, bigScan, units), 'PLANTED DEFECT: a scan pod that runs beside the probes, and is none of the Buildah pods, is counted');
});

// The limits of the Buildah pod are set from the largest working set a step reached on the master, with a margin, because
// the sum of the pods of the nine release slots is what the budget above holds. Measured 2026-10-18 13:28 UTC on the
// master's Prometheus over 15 days, the whole retention (query: max by (namespace, pod, container)
// (max_over_time(container_memory_working_set_bytes{namespace=~".*-build", container=~"step-(build|push)"}[15d])) / 1024^2):
// `step-build` reached 2320.7Mi (swissbookai-build, pod swissbookai-release-5pqbj-build-swissbookai-web-pod) and
// `step-push` 247.6Mi (digita-report-build, pod digita-report-release-7j22g-build-digita-report-backend-pod). The peaks
// are rounded up to the Mi. The two limits are 2752Mi and 320Mi, 3Gi in all: 1.186 and 1.292 times the peaks, which is as
// much margin as the 3Gi of the owner's decision leaves, so each margin is the one the limit gives and no round figure.
const BUILDAH_PEAK = {build: {peak: 2321 * BYTES.Mi, margin: 1.18}, push: {peak: 248 * BYTES.Mi, margin: 1.29}};

test('each step of the Buildah pod limits its memory above the measured peak with a margin, requests no more than its limit, and the pod is 3Gi', () => {
  const {shared} = ciPlane(readCiCapacity());
  const stepsOfBuildah = (task) => Object.fromEntries(task.spec.steps.map((step) => [step.name, step.computeResources]));
  const covers = (task) => Object.entries(BUILDAH_PEAK).every(([name, {peak, margin}]) => {
    const {requests, limits} = stepsOfBuildah(task)[name];
    return quantity(limits.memory) >= peak * margin && quantity(requests.memory) <= quantity(limits.memory);
  }) && podLimit({taskSpec: task.spec}, shared) <= 3 * BYTES.Gi;
  const buildah = shared.get('buildah-build-push');
  assert.ok(covers(buildah), 'PLANTED INNOCENT: the limits as they stand cover the measured peaks with their margins and make 3Gi');
  const lowered = (step, memory) => withSharedTask(shared, 'buildah-build-push', (task) => { task.spec.steps.find((s) => s.name === step).computeResources.limits.memory = memory; }).get('buildah-build-push');
  assert.ok(!covers(lowered('build', '2560Mi')), 'PLANTED DEFECT: a build limit of 2560Mi, 1.10 times the 2321Mi peak, is caught');
  assert.ok(!covers(lowered('build', '2Gi')), 'PLANTED DEFECT: a build limit of 2Gi, below the peak, is caught');
  assert.ok(!covers(lowered('push', '256Mi')), 'PLANTED DEFECT: a push limit of 256Mi, 1.03 times the 248Mi peak, is caught');
  assert.ok(!covers(lowered('push', '1Gi')), 'PLANTED DEFECT: a push limit that takes the pod above 3Gi is caught');
  const dearRequest = withSharedTask(shared, 'buildah-build-push', (task) => { task.spec.steps.find((s) => s.name === 'push').computeResources.requests.memory = '1Gi'; }).get('buildah-build-push');
  assert.ok(!covers(dearRequest), 'PLANTED DEFECT: a request above its limit, which the API server refuses, is caught');
});

test('the queue runs one run of a unit and releaseSlots runs in all, which the capacity sums count', () => {
  const capacity = readCiCapacity(), stages = channelStageCount();
  const units = Array.from({length: capacity.releaseSlots + 2}, (_, i) => `unit${i}`);
  assert.ok(stages > 1, 'the channel table reaches several stages, and a stage run is a run of its own');
  const startsOf = (edit) => queueStartsOf(units, stages, capacity.releaseSlots, edit);
  assert.deepEqual(startsOf(), units.slice(0, capacity.releaseSlots).map((unit) => `${unit}-build`), 'PLANTED INNOCENT: of every unit the first stage run starts and no more than releaseSlots runs in all');
  assert.notDeepEqual(startsOf((program) => program.replace('(.holder | has($unit)) or', 'false or')), startsOf(), 'PLANTED DEFECT: a queue that admits the stages of one unit together starts the same unit twice');
  assert.ok(new Set(startsOf((program) => program.replace('(.holder | has($unit)) or', 'false or'))).size < capacity.releaseSlots, 'PLANTED DEFECT: and fewer units than releaseSlots then run');
});

// The check step takes 12 cores at most, and requests the largest whole number of cores for which the CPU requests of
// the ci pods of the runs that run at once, of the releases or publish runs the queue runs at once and of the pods that
// stand on the node still fit its cores (the sum of fitsBudget, in CPU requests). One more core fails the test as well as
// a core less: the request is as far as the budget allows.
const checkResources = (pipeline) => pipeline.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').computeResources;
const workerCap = (pipeline) => pipeline.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').env.find((entry) => entry.name === 'VITEST_MAX_WORKERS')?.value;

test('digita-platform has four Vitest workers and enough check memory while other units retain their resources', () => {
  const digita = renderUnit('digita-platform').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'digita-platform-ci');
  const ordinary = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const upperWorkerMi = Math.ceil(2048 / 3 * 1.30);
  const rawWorkerMi = 2048 / 3;
  const admitsWorkers = (pipeline) => workerCap(pipeline) === '4' &&
    quantity(checkResources(pipeline).requests.memory) >= Math.ceil(4 * rawWorkerMi) * BYTES.Mi &&
    quantity(checkResources(pipeline).limits.memory) >= 4 * upperWorkerMi * BYTES.Mi;
  assert.equal(upperWorkerMi, 888, 'the supplied three-worker 2Gi peak plus 30 percent determines the estimate');
  assert.ok(admitsWorkers(digita), 'PLANTED INNOCENT: cap four, 3Gi request and 3584Mi limit cover the estimate');
  assert.equal(checkResources(digita).requests.memory, '3Gi');
  assert.equal(checkResources(digita).limits.memory, '3584Mi');
  assert.equal(workerCap(ordinary), undefined, 'the cap is only for digita-platform');
  assert.equal(checkResources(ordinary).requests.memory, '2Gi');
  assert.equal(checkResources(ordinary).limits.memory, '3Gi');
  const missingCap = structuredClone(digita);
  missingCap.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').env = missingCap.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').env.filter((entry) => entry.name !== 'VITEST_MAX_WORKERS');
  assert.ok(!admitsWorkers(missingCap), 'PLANTED DEFECT: a missing cap is caught');
  const ignoredCap = structuredClone(digita);
  ignoredCap.spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').env.find((entry) => entry.name === 'VITEST_MAX_WORKERS').name = 'VITEST_WORKERS';
  assert.ok(!admitsWorkers(ignoredCap), 'PLANTED DEFECT: an env name the Vitest reader ignores is caught');
  const lowLimit = structuredClone(digita);
  checkResources(lowLimit).limits.memory = '3Gi';
  assert.ok(!admitsWorkers(lowLimit), 'PLANTED DEFECT: 3Gi cannot hold four estimated workers with margin');
  const lowRequest = structuredClone(digita);
  checkResources(lowRequest).requests.memory = '2Gi';
  assert.ok(!admitsWorkers(lowRequest), 'PLANTED DEFECT: the request is below four workers without margin');
});
const withCheck = (pipeline, side, cpu) => {
  const planted = structuredClone(pipeline);
  checkResources(planted)[side].cpu = cpu;
  return planted;
};

test('the check step takes 12 cores at most and requests the largest whole number of cores that the build node admits', () => {
  const capacity = readCiCapacity();
  const {pipeline, shared, units} = ciPlane(capacity);
  const [{publish}] = units;
  const fits = (pipelineUnderTest, capacityUnderTest = capacity) => fitsBudget(capacityUnderTest, pipelineUnderTest, shared, units, CORES);
  const requestIsLargest = (pipelineUnderTest) => fits(pipelineUnderTest)
    && !fits(withCheck(pipelineUnderTest, 'requests', String(milliCores(checkResources(pipelineUnderTest).requests.cpu) / 1000 + 1)));
  const limitIsSound = (pipelineUnderTest) => milliCores(checkResources(pipelineUnderTest).limits.cpu) <= milliCores(capacity.nodeCpu)
    && milliCores(checkResources(pipelineUnderTest).requests.cpu) <= milliCores(checkResources(pipelineUnderTest).limits.cpu);
  assert.equal(checkResources(pipeline).limits.cpu, '12', 'the check step may take 12 cores');
  assert.ok(limitIsSound(pipeline), 'PLANTED INNOCENT: the limit is within the cores of the node and the request within the limit');
  assert.ok(!limitIsSound(withCheck(pipeline, 'limits', String(milliCores(capacity.nodeCpu) / 1000 + 1))), 'PLANTED DEFECT: a limit above the cores of the node is caught');
  assert.ok(!limitIsSound(withCheck(pipeline, 'requests', '13')), 'PLANTED DEFECT: a request above the limit, which the API server refuses, is caught');
  assert.ok(requestIsLargest(pipeline), 'PLANTED INNOCENT: the request as it stands fits, and one more core does not');
  assert.ok(!requestIsLargest(withCheck(pipeline, 'requests', '1')), 'PLANTED DEFECT: a request below what the node admits, one more core would fit, is caught');
  assert.ok(!requestIsLargest(withCheck(pipeline, 'requests', '3')), 'PLANTED DEFECT: the former request of 3 cores, which the node does not admit with seven runs and nine releases at once, is caught');
  assert.ok(fits(pipeline, {...capacity, releaseSlots: 2}), 'PLANTED INNOCENT: two releases at a time fit too');
  assert.ok(!fits(pipeline, {...capacity, maxRunning: 14}), 'PLANTED DEFECT: 14 runs at once, one per unit of 14 units and so no cap, is caught');
  assert.ok(!fits(pipeline, {...capacity, releaseSlots: Object.keys(capacity.releaseUnitImages).length}), 'PLANTED DEFECT: every declared unit released at once is caught');
  assert.ok(!fits(pipeline, {...capacity, standingCpuRequests: capacity.nodeCpu}), 'PLANTED DEFECT: standing requests that fill the node are caught');
  assert.ok(!fits(pipeline, {...capacity, nodeCpu: '24'}), 'PLANTED DEFECT: a build node of 24 cores is caught');
  const heavy = withSharedTask(shared, 'buildah-build-push', (task) => { task.spec.steps.find((step) => step.name === 'build').computeResources.requests.cpu = '4'; });
  assert.ok(!fitsBudget(capacity, pipeline, heavy, units, CORES), 'PLANTED DEFECT: a raised request of the buildah build step is caught');
  const wide = withSharedTask(shared, 'buildah-build-push', (task) => {
    task.spec.steps.find((step) => step.name === 'build').computeResources.requests.cpu = '1000m';
    task.spec.steps.find((step) => step.name === 'push').computeResources.requests.cpu = '250m';
  });
  assert.ok(!fitsBudget(capacity, pipeline, wide, units, CORES), 'PLANTED DEFECT: a Buildah pod that requests 1.25 cores, 1000m and 250m, does not fit nine releases beside seven ci runs');
  const heavyPublish = structuredClone(publish);
  heavyPublish.spec.tasks.find((t) => t.name === 'pack').taskSpec.steps[0].computeResources.requests.cpu = '8';
  assert.ok(!fitsBudget(capacity, pipeline, shared, withUnits(units, (unit) => ({...unit, publish: heavyPublish})), CORES), 'PLANTED DEFECT: a publish pod that requests 8 cores, above the build pods of a release, is caught');
});

// The pods the master cannot work without carry a CPU request, which scripts/check.sh holds for every render. What the
// budget of the cores counts of them is ciCapacity.standingCpuRequests: the 4530m the node held on 2026-10-15, before
// they had requests (declared by the budget of the check step), their own requests, which this test reads from the
// values that carry them, and the 400m of traefik that hostyour-deploy sets on the addon's DaemonSet. The 8 slave
// instances are the app clusters apps1 to apps8, one Argo CD each on the master.
const BASELINE_CPU = 4530, SLAVE_INSTANCES = 8, TRAEFIK_CPU = 400;
const requestAt = (file, path) => {
  const value = execFileSync('yq', [`${path}.resources.requests.cpu`, file], {encoding: 'utf8'}).trim();
  assert.notEqual(value, 'null', `${file} sets no CPU request at ${path}`);
  return milliCores(value);
};
const requestsOf = (file, paths) => paths.reduce((total, path) => total + requestAt(file, path), 0);

test('the standing CPU requests of the budget count the requests of the pods the master cannot work without', () => {
  const capacity = readCiCapacity();
  const argoComponents = ['.controller', '.server', '.repoServer', '.redis', '.applicationSet'];
  const master = requestsOf('clusters/bootstrap/argocd/values.tpl', [...argoComponents, '.dex', '.notifications']);
  const slave = requestsOf('clusters/slaves/slave/values-common.yaml', argoComponents.map((component) => `.["argo-cd"]${component}`));
  const certManager = requestsOf('clusters/inventories/cert-manager/values-common.yaml', ['.["cert-manager"]', '.["cert-manager"].cainjector', '.["cert-manager"].webhook']);
  const identity = requestAt('clusters/bootstrap/idp/values.yaml', '.postgresql.primary');
  const requests = master + SLAVE_INSTANCES * slave + certManager + identity;
  const counted = (standing, extra = 0) => milliCores(standing) >= BASELINE_CPU + requests + extra + TRAEFIK_CPU;
  assert.ok(counted(capacity.standingCpuRequests), 'PLANTED INNOCENT: the budget counts the requests as they stand');
  assert.ok(!counted(capacity.standingCpuRequests, 1000), 'PLANTED DEFECT: a request raised by a core that the budget does not count is caught');
  assert.ok(!counted(capacity.standingCpuRequests, SLAVE_INSTANCES * 10), 'PLANTED DEFECT: 10m more on each of the slave instances is caught');
  assert.ok(!counted(`${BASELINE_CPU + requests}m`), 'PLANTED DEFECT: a budget that leaves out traefik, once its request is set, is caught');
});

// The pods of the build node. The kubelet admits at most nodePods active pods (a finished pod does not count), and
// a Tekton task is one pod, so what counts is the pods a run has alive at once (peakConcurrent), not every task of
// every stage. The queue runs one run per unit and releaseSlots runs in all, so the slots hold the largest distinct
// units, each the larger of its release run and its publish run, beside the ci runs (each at most podsPerUnit ci pods
// and one report pod) and the pods that stand there whatever the build plane does.
const podsOnNode = (capacity, units) => largestQueued(capacity, units, () => 1) + capacity.maxRunning * (capacity.podsPerUnit + 1) + capacity.standingPods;

test('the pods of all ci runs and the nine largest releases or publish runs, with the pods that stand on the build node, stay below its pod limit', () => {
  const capacity = readCiCapacity();
  const {units} = ciPlane(capacity);
  const below = (counted) => counted < capacity.nodePods;
  for (const unit of units) {
    assert.equal(peakConcurrent(unit.release, () => 1), Math.max(unit.images + 1, 3), `${unit.name} has the scan and a probe per image alive at once, or verify, builds and scan, or its builds: the largest of them`);
  }
  const largest = largestUnit(units);
  assert.ok(below(podsOnNode(capacity, units)), 'PLANTED INNOCENT: nine slots as they stand, the units of 5 + 4 + 4 + 3 + 3 + 4 x 3 = 31 pods, 31 + 7 x 3 + 125 = 177 pods, stay below the limit');
  assert.ok(below(podsOnNode({...capacity, releaseSlots: 2}, units)), 'PLANTED INNOCENT: two releases at a time stay below it too');
  assert.ok(!below(podsOnNode({...capacity, releaseSlots: 40}, Array(40).fill(largest))), 'PLANTED DEFECT: forty slots of the largest unit, a total above 250, are caught');
  assert.ok(!below(podsOnNode({...capacity, standingPods: capacity.nodePods}, units)), 'PLANTED DEFECT: standing pods that fill the node are caught');
  const everyTask = capacity.releaseSlots * 3 * largest.release.spec.tasks.length + capacity.maxRunning * (capacity.podsPerUnit + 1) + capacity.standingPods;
  assert.ok(!below(everyTask), 'PLANTED DEFECT: counting every task of every stage of nine releases is above 250, which is the count that this test replaces');
  const wide = renderUnit('shop', imageNames(60)).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-release');
  assert.ok(!below(podsOnNode(capacity, Array(capacity.releaseSlots).fill({...largest, release: wide}))), 'PLANTED DEFECT: nine units of sixty images, sixty probes and the scan alive at once in each, are caught');
  const chain = (names) => ({metadata: {name: 'chain'}, spec: {tasks: names.map((name, i) => ({name, ...(i ? {runAfter: [names[i - 1]]} : {})}))}});
  assert.equal(peakConcurrent(chain(['a', 'b', 'c', 'd', 'e']), () => 1), 1, 'PLANTED INNOCENT: five tasks that run one after the other have one pod alive at a time');
  const referenced = chain(['a', 'b']);
  referenced.spec.tasks.push({name: 'c', params: [{name: 'x', value: '$(tasks.b.results.y)'}]}, {name: 'd', when: [{input: '$(tasks.c.results.z)', operator: 'in', values: ['true']}]});
  assert.equal(peakConcurrent(referenced, () => 1), 1, 'PLANTED INNOCENT: tasks that wait through a result and through a when expression have one pod alive at a time');
  const withFinally = chain(['a', 'b']);
  withFinally.spec.finally = [{name: 'report'}, {name: 'status'}];
  assert.equal(peakConcurrent(withFinally, () => 1), 2, 'PLANTED INNOCENT: two finally tasks run together after the tasks, never beside them');
  assert.equal(peakConcurrent({metadata: {name: 'fan'}, spec: {tasks: [{name: 'a'}, {name: 'b', runAfter: ['a']}, {name: 'c', runAfter: ['a']}, {name: 'd', runAfter: ['b', 'c']}]}}, () => 1), 2,
    'PLANTED DEFECT: a fan of two tasks between one before and one after is two pods, not four');
});

// The engine suite of a repository keeps its MongoDB files in /dev/shm where that exists, and mongod refuses to run with
// less than 500 MiB free, so the check step needs 1 GiB in the workspace, in /tmp and in /dev/shm. A path the pod spec
// gives no volume is the container's own: /tmp is its writable layer on the node's disk, and /dev/shm is the 64 MiB tmpfs
// the runtime mounts. A volume sized by its sizeLimit has that size; one without a sizeLimit is the node's disk.
const MIN_FREE = BYTES.Gi, RUNTIME_SHM = 64 * BYTES.Mi;
const storageShort = (pipeline) => {
  const spec = ciTaskSpec(pipeline), check = spec.steps.find((s) => s.name === 'check');
  const sizeAt = (path, fallback) => {
    const mount = check.volumeMounts?.find((m) => m.mountPath === path);
    const volume = mount && spec.volumes.find((v) => v.name === mount.name);
    return !volume ? fallback : volume.emptyDir?.sizeLimit ? quantity(volume.emptyDir.sizeLimit) : Infinity;
  };
  return Object.entries({'/workspace/source': sizeAt('/workspace/source', 0), '/tmp': sizeAt('/tmp', Infinity), '/dev/shm': sizeAt('/dev/shm', RUNTIME_SHM)})
    .filter(([, bytes]) => bytes < MIN_FREE).map(([path]) => path);
};

test('the ci check has 1 GiB in its workspace, in /tmp and in /dev/shm, and its scratch volume is bounded', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  assert.deepEqual(storageShort(pipeline), [], 'PLANTED INNOCENT: the check step as it stands');
  const withVolume = (path, emptyDir) => {
    const planted = structuredClone(pipeline), spec = ciTaskSpec(planted), check = spec.steps.find((s) => s.name === 'check'), name = `planted-${path.replaceAll('/', '')}`;
    spec.volumes = [...spec.volumes.filter((v) => v.name !== name), {name, emptyDir}];
    check.volumeMounts = [...check.volumeMounts.filter((m) => m.mountPath !== path), {name, mountPath: path}];
    return planted;
  };
  const withoutMount = (path) => {
    const planted = structuredClone(pipeline), check = ciStep(planted, 'check');
    check.volumeMounts = check.volumeMounts.filter((m) => m.mountPath !== path);
    return planted;
  };
  assert.deepEqual(storageShort(withoutMount('/dev/shm')), ['/dev/shm'], 'PLANTED DEFECT: no volume at /dev/shm leaves the 64 MiB tmpfs of the runtime');
  assert.deepEqual(storageShort(withoutMount('/workspace/source')), ['/workspace/source'], 'PLANTED DEFECT: a check with no volume under its clone');
  assert.deepEqual(storageShort(withVolume('/workspace/source', {sizeLimit: '512Mi'})), ['/workspace/source'], 'PLANTED DEFECT: a workspace of 512Mi');
  assert.deepEqual(storageShort(withVolume('/tmp', {sizeLimit: '256Mi'})), ['/tmp'], 'PLANTED DEFECT: /tmp on a volume of 256Mi');
  assert.deepEqual(storageShort(withVolume('/dev/shm', {sizeLimit: '45Mi'})), ['/dev/shm'], 'PLANTED DEFECT: /dev/shm on a volume of 45Mi');
  assert.deepEqual(storageShort(withVolume('/dev/shm', {})), [], 'PLANTED INNOCENT: /dev/shm on an unsized volume of the node disk');
  // The scratch volume holds the clone and the pinned sources of one run, and a check that fills it ends its own pod: the size limit is
  // what bounds it, and it is the value of ciScratch.size.
  const scratchOf = (p) => ciTaskSpec(p).volumes.find((v) => v.name === 'scratch');
  const size = execFileSync('yq', ['.ciScratch.size', 'clusters/inventories/consumer-build/values-common.yaml'], {encoding: 'utf8'}).trim();
  assert.equal(scratchOf(pipeline).emptyDir.sizeLimit, size, 'PLANTED INNOCENT: the scratch volume carries the size of ciScratch.size');
  const unbounded = structuredClone(pipeline);
  delete scratchOf(unbounded).emptyDir.sizeLimit;
  assert.notEqual(scratchOf(unbounded).emptyDir.sizeLimit, size, 'PLANTED DEFECT: a scratch volume without a size limit fills the node disk');
  assert.equal(scratchOf(pipeline).persistentVolumeClaim, undefined, 'the checkout of a ci run is on no claim');
  assert.ok(quantity(size) >= MIN_FREE, 'the scratch volume holds the 1 GiB the check needs');
});

// The lines of the check step before the tools are installed, run with a df that reports a short path as 45 MB free.
const runStorageGuard = (guard, shortPath) => {
  const root = mkdtempSync(join(tmpdir(), 'ci-storage-')), bin = join(root, 'bin');
  mkdirSync(bin);
  writeFileSync(join(bin, 'df'), '#!/usr/bin/env bash\n' +
    'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"\n' +
    `if [ "$2" = "${shortPath}" ]; then free=43908; else free=789012345; fi\n` +
    'echo "stub 800000000 1 $free 1% $2"\n');
  chmodSync(join(bin, 'df'), 0o755);
  const result = spawnSync('bash', ['-euo', 'pipefail', '-c', guard], {env: {...process.env, PATH: `${bin}:${process.env.PATH}`}, encoding: 'utf8'});
  rmSync(root, {recursive: true, force: true});
  return result;
};

test('the ci check prints the free space of its workspace, /tmp and /dev/shm, and stops before the tools when one is under 1 GiB', () => {
  const script = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci').spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check').script;
  const lines = script.split('\n');
  const guard = lines.slice(0, lines.findIndex((line) => line.includes('trap '))).join('\n');
  const roomy = runStorageGuard(guard, 'none');
  assert.equal(roomy.status, 0, 'PLANTED INNOCENT: 1 GiB or more free everywhere passes');
  for (const path of ['/workspace/source', '/tmp', '/dev/shm']) {
    assert.ok(roomy.stdout.includes(path), `the log shows the free space of ${path}`);
    const short = runStorageGuard(guard, path);
    assert.notEqual(short.status, 0, `PLANTED DEFECT: 45 MB free in ${path} stops the step`);
    assert.ok(short.stderr.includes(path), `the message names ${path}`);
  }
});

test('the egress policy of a build namespace selects every pod of it', () => {
  const policy = (docs) => docs.find((d) => d.kind === 'NetworkPolicy' && d.metadata.name === 'build-egress');
  const exempts = (doc) => !doc || !Object.hasOwn(doc.spec, 'podSelector') || Object.keys(doc.spec.podSelector).length > 0;
  for (const docs of [renderUnit('shop'), renderChart('forgejo-build', ['--namespace', 'forgejo-build'])]) {
    assert.ok(!exempts(policy(docs)), 'build-egress selects the whole namespace');
  }
  const planted = structuredClone(policy(renderUnit('shop')));
  planted.spec.podSelector = {matchExpressions: [{key: 'tekton.dev/pipelineTask', operator: 'NotIn', values: ['tests']}]};
  assert.ok(exempts(planted), 'PLANTED DEFECT: a selector that exempts a task is caught');
  delete planted.spec.podSelector;
  assert.ok(exempts(planted), 'PLANTED DEFECT: a missing selector is caught');
});

test('the ci run keeper runs one tick after the other, reads runs cluster-wide, and may patch and delete only inside a build namespace', () => {
  const docs = imageBuilder();
  const keeper = docs.find((d) => d.kind === 'Deployment' && d.metadata.name === 'ci-run-keeper');
  // Two keepers at once would each start runs up to the cap, so there is one, and the old pod ends before the new one starts.
  assert.equal(keeper.spec.replicas, 1);
  assert.equal(keeper.spec.strategy.type, 'Recreate');
  const pod = keeper.spec.template.spec;
  assert.equal(pod.serviceAccountName, 'ci-run-keeper');
  assert.equal(pod.containers[0].image, docs.find((d) => d.kind === 'CronJob' && d.metadata.name === 'release-queue')
    .spec.jobTemplate.spec.template.spec.containers[0].image);
  const map = docs.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'ci-run-keeper');
  assert.ok(map.data['ci-run-keeper.jq'].includes('image-builder.io/ci-branch') && map.data['ci-run-keeper.sh'].includes('kubectl delete'));
  assert.ok(map.data['ci-run-keeper.jq'].includes('image-builder.io/branch-deleted'));
  // Every remote is asked at once, so asking takes at most the time one ask gets, and it leaves the tick at least half of its
  // length to list the runs and write the changes.
  const setting = (name) => Number(pod.containers[0].env.find((e) => e.name === name).value);
  const [tick, every] = [setting('CI_KEEPER_TICK_SECONDS'), setting('CI_KEEPER_DECISION_SECONDS')];
  const askSeconds = Number(/^git_timeout=(\d+)$/m.exec(map.data['ci-run-keeper.sh'])[1]);
  const leavesTime = (ask) => ask * 2 <= tick;
  assert.ok(leavesTime(askSeconds), `PLANTED INNOCENT: an ask of ${askSeconds} seconds leaves the tick its half of ${tick}`);
  assert.ok(!leavesTime(tick), 'PLANTED DEFECT: an ask that may take the whole tick');
  assert.equal(Math.floor((tick - every) / every) + 1, 5, 'five decisions a tick, ten seconds apart');
  assert.ok(askSeconds <= every, 'the remotes are read in the first decision, which may then take the whole interval and no more');
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

// The loop of the keeper and its liveness probe run here as the pod runs them, with a stand-in tick that succeeds, fails, leaves
// a child behind or hangs, the marker in a temporary directory, and a tick and a decision interval of one second each.
test('the loop of the ci run keeper marks only a tick that succeeded, pauses after one that failed, ends a hung tick and every process a tick left, and its probe restarts a stalled one', () => {
  const container = imageBuilder().find((d) => d.kind === 'Deployment' && d.metadata.name === 'ci-run-keeper').spec.template.spec.containers[0];
  const dir = mkdtempSync(join(tmpdir(), 'keeper-loop-'));
  const marker = join(dir, 'keeper-succeeded');
  const at = (text, folder = dir) => text.replaceAll('/keeper/ci-run-keeper.sh', join(folder, 'tick.sh')).replaceAll('/tmp/keeper-succeeded', join(folder, 'keeper-succeeded'));
  const loop = container.command[2];
  assert.notEqual(at(loop), loop, 'the loop names the tick and the marker the test replaces');
  const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
  const lines = (file) => (existsSync(file) ? readFileSync(file, 'utf8').split('\n').filter(Boolean) : []);
  // Each run has a folder of its own, because a tick of the run before may still write after the test ended that loop.
  const run = (script, mode, seconds) => {
    const folder = mkdtempSync(join(dir, 'run-'));
    const log = join(folder, 'ticks'), children = join(folder, 'children');
    writeFileSync(join(folder, 'tick.sh'), `echo tick >>'${log}'
case "$TICK_MODE" in
  fail) exit 1 ;;
  leftover) sleep 30 & echo "$!" >>'${children}'; exit 0 ;;
  hang) sleep 30 & echo "$!" >>'${children}'; sleep 30 ;;
esac
`);
    spawnSync('bash', ['-c', at(script, folder)], {env: {...process.env, TICK_MODE: mode, CI_KEEPER_TICK_SECONDS: '1', CI_KEEPER_DECISION_SECONDS: '1'}, timeout: seconds * 1000});
    const pids = lines(children).map(Number);
    // The child of the last tick may still run when the test ends the loop in the middle of that tick.
    const result = {marked: existsSync(join(folder, 'keeper-succeeded')), ticks: lines(log).length, leftOver: pids.slice(0, -1).filter(alive).length, children: pids.length};
    for (const pid of pids) { try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ } }
    return result;
  };
  const mutate = (from, to) => { const script = loop.replace(from, to); assert.notEqual(script, loop, `PLANTED DEFECT: the edit finds its clause: ${from}`); return script; };
  assert.ok(run(loop, 'ok', 1).marked, 'PLANTED INNOCENT: a tick that succeeded is marked');
  const failing = run(loop, 'fail', 2.5);
  assert.ok(!failing.marked, 'a tick that failed is not marked');
  assert.ok(failing.ticks <= 3, `a failed tick is followed by a pause of one decision interval: ${failing.ticks} ticks in 2.5 seconds`);
  assert.ok(run(mutate('if wait "${tick}"; then ok=1; else ok=0; fi', 'wait "${tick}"; ok=1'), 'fail', 1).marked, 'PLANTED DEFECT: a loop that marks a failed tick');
  assert.ok(run(mutate('sleep "${CI_KEEPER_DECISION_SECONDS}"', ':'), 'fail', 2.5).ticks > 10, 'PLANTED DEFECT: a loop that does not pause after a failed tick');
  const leftover = run(loop, 'leftover', 1.5);
  assert.ok(leftover.children > 2 && leftover.leftOver === 0, `every process a tick left ends with the tick: ${leftover.leftOver} of ${leftover.children} still ran`);
  assert.ok(run(mutate('kill -KILL -- "-${tick}" "-${watchdog}" 2>/dev/null', ':'), 'leftover', 1.5).leftOver > 0, 'PLANTED DEFECT: a loop that leaves the processes of a tick running');
  const hung = run(loop, 'hang', 3.5);
  assert.ok(hung.ticks >= 2 && hung.leftOver === 0, `a hung tick is ended at its length, with its child: ${hung.ticks} ticks, ${hung.leftOver} children left`);
  assert.equal(run(mutate('{ sleep "${CI_KEEPER_TICK_SECONDS}"; kill -TERM -- "-${tick}"; } 2>/dev/null &', ':'), 'hang', 3.5).ticks, 1, 'PLANTED DEFECT: a loop without its watchdog waits for a hung tick');
  // The probe passes while the last success is younger than ten minutes; the first ten minutes of the pod are not probed.
  const probe = container.livenessProbe;
  assert.deepEqual([probe.initialDelaySeconds, probe.periodSeconds, probe.timeoutSeconds, probe.failureThreshold], [600, 60, 10, 1]);
  const probes = (command) => spawnSync(command[0], command.slice(1).map((part) => at(part))).status === 0;
  const aged = (minutes) => { writeFileSync(marker, ''); const then = Date.now() / 1000 - minutes * 60; utimesSync(marker, then, then); };
  rmSync(marker, {force: true});
  assert.ok(!probes(probe.exec.command), 'a pod whose tick never succeeded fails the probe');
  aged(9); assert.ok(probes(probe.exec.command), 'PLANTED INNOCENT: a success nine minutes ago passes');
  aged(11); assert.ok(!probes(probe.exec.command), 'a success eleven minutes ago fails the probe');
  assert.ok(probes(probe.exec.command.map((part) => part.replace('-mmin -10', '-mmin -100'))), 'PLANTED DEFECT: a probe of a hundred minutes passes a keeper stalled for eleven');
  rmSync(dir, {recursive: true, force: true});
});

const KEEPER = 'system:serviceaccount:image-builder:ci-run-keeper';
const KEEPER_MESSAGE = 'the ci run keeper may only cancel a ci run and name the push that replaced it or the branch that was deleted, start a waiting one, or note what it waits for.';
const PRIORITY_MESSAGE = "a managed run's podTemplate sets priorityClassName to the class of its pipeline and nothing else.";
const OVERRIDE_MESSAGE = 'per-task pod, step, sidecar, metadata and account overrides are not allowed, except the report class on the task report-failure of a ci run.';
const CI_CLASS_MESSAGE = 'a ci run carries the ci priority class: the capacity quota of its build namespace counts the pods of that class only.';

test('the admission policy lets the ci run keeper cancel, name the replacing push or the deleted branch, start and note a ci run and change nothing else', () => {
  const policy = guardOf(imageBuilder());
  const running = (pipeline = 'shop-ci') => ({...createsRun('shop-build', pipeline).object,
    metadata: {namespace: 'shop-build', name: `${pipeline}-x`, labels: {'image-builder.io/ci': 'shop'}, annotations: {'image-builder.io/ci-branch': 'main'}, finalizers: ['chains.tekton.dev/pipelinerun']}});
  const withParams = (run) => ({...run, spec: {...run.spec, params: [{name: 'branch', value: 'main'}], timeouts: {pipeline: '2h0m0s'}}});
  const base = withParams(running());
  const changed = (edit, from = base) => { const run = structuredClone(from); edit(run); return run; };
  const cancelled = changed((r) => { r.spec.status = 'Cancelled'; });
  const waiting = changed((r) => { r.spec.status = 'PipelineRunPending'; });
  const noted = changed((r) => { r.metadata.annotations['image-builder.io/queued-behind'] = 'all 7 ci slots are in use'; }, waiting);
  const named = (r) => { r.metadata.annotations['image-builder.io/cancelled-by'] = `${'a'.repeat(40)} (shop-ci-y)`; };
  const deleted = (r) => { r.metadata.annotations['image-builder.io/branch-deleted'] = 'ci/issue-1-planted-1'; };
  const update = (username, object, oldObject) => ({object, oldObject, request: {operation: 'UPDATE', namespace: 'shop-build', userInfo: {username}}});
  const ADMITTED = {
    'the keeper cancels a running ci run': update(KEEPER, cancelled, base),
    'the keeper cancels a running ci run gracefully, so its finally tasks run': update(KEEPER, changed((r) => { r.spec.status = 'CancelledRunFinally'; }), base),
    'the keeper cancels a running ci run and names the push that replaced it': update(KEEPER, changed((r) => { r.spec.status = 'CancelledRunFinally'; named(r); }), base),
    'the keeper cancels a waiting ci run and names the push that replaced it': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; named(r); }), waiting),
    'the keeper cancels a waiting ci run and names the branch that was deleted': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; deleted(r); }), waiting),
    'the keeper cancels a running ci run gracefully and names the branch that was deleted': update(KEEPER, changed((r) => { r.spec.status = 'CancelledRunFinally'; deleted(r); }), base),
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
    'the keeper changes a param while it cancels gracefully': update(KEEPER, changed((r) => { r.spec.status = 'CancelledRunFinally'; r.spec.params[0].value = 'other'; }), base),
    'the keeper sets a status Tekton does not know': update(KEEPER, changed((r) => { r.spec.status = 'StoppedRunFinally'; }), base),
    'the keeper changes a param and nothing else': update(KEEPER, changed((r) => { r.spec.params[0].value = 'other'; }), base),
    'the keeper hands the run to another controller while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.spec.managedBy = 'example.com/other'; }), base),
    'the keeper changes the timeouts while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.spec.timeouts.pipeline = '24h0m0s'; }), base),
    'the keeper sets another status': update(KEEPER, changed((r) => { r.spec.status = 'PipelineRunPending'; }), base),
    'the keeper takes the cancellation back': update(KEEPER, base, cancelled),
    'the keeper changes a label while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.metadata.labels['image-builder.io/consumer'] = 'shop'; }), base),
    'the keeper changes an annotation while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.metadata.annotations['image-builder.io/ci-branch'] = 'other'; }), base),
    'the keeper names a push while it cancels and changes the branch of the run beside it': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; named(r); r.metadata.annotations['image-builder.io/ci-branch'] = 'other'; }), base),
    'the keeper names a push while it cancels and drops the branch of the run': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.metadata.annotations = {'image-builder.io/cancelled-by': 'x'}; }), base),
    'the keeper names a push on a run it does not cancel': update(KEEPER, changed(named), base),
    'the keeper names a deleted branch on a run it does not cancel': update(KEEPER, changed(deleted), base),
    'the keeper names a deleted branch while it starts a run': update(KEEPER, changed(deleted), waiting),
    'the keeper names a deleted branch while it notes a run': update(KEEPER, changed(deleted, noted), waiting),
    'the keeper names a deleted branch while it cancels a release run': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; deleted(r); }, releaseRun), releaseRun),
    'the keeper names a deleted branch while it cancels and changes the branch of the run beside it': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; deleted(r); r.metadata.annotations['image-builder.io/ci-branch'] = 'other'; }), base),
    'the keeper names a deleted branch while it cancels and drops the branch of the run': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.metadata.annotations = {'image-builder.io/branch-deleted': 'x'}; }), base),
    'the keeper writes an annotation of another name while it cancels': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; r.metadata.annotations['image-builder.io/branch-removed'] = 'x'; }), base),
    'the keeper names a push while it starts a run': update(KEEPER, changed(named), waiting),
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

// A ci run created by the Trigger of the earlier release carries the `source` claim. Tekton lets nothing but spec.status change on a
// run, so every update of such a run keeps its workspaces, and the keeper that starts or cancels it is not refused for them.
test('the admission policy lets the keeper start and cancel a waiting ci run that still carries the source claim, and gives no ci run a workspace by an update', () => {
  const policy = guardOf(imageBuilder());
  const waiting = {metadata: {namespace: 'shop-build', name: 'shop-ci-x', labels: {'image-builder.io/ci': 'shop'}, annotations: {'image-builder.io/ci-branch': 'main'}},
    spec: {...createsRun('shop-build', 'shop-ci').object.spec, status: 'PipelineRunPending', workspaces: SOURCE_CLAIM}};
  const changed = (edit, from = waiting) => { const run = structuredClone(from); edit(run); return run; };
  const update = (username, object, oldObject) => ({object, oldObject, request: {operation: 'UPDATE', namespace: 'shop-build', userInfo: {username}}});
  const bare = changed((r) => { delete r.spec.workspaces; });
  const ADMITTED = {
    'the keeper starts a waiting ci run that carries the source claim': update(KEEPER, changed((r) => { delete r.spec.status; }), waiting),
    'the keeper cancels a waiting ci run that carries the source claim': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; }), waiting),
    'the keeper notes a waiting ci run that carries the source claim': update(KEEPER, changed((r) => { r.metadata.annotations['image-builder.io/queued-behind'] = 'all 7 ci slots are in use'; }), waiting),
    'the Tekton controller updates a started ci run that carries the source claim': update('system:serviceaccount:tekton:tekton-controller',
      changed((r) => { delete r.spec.status; r.metadata.labels['tekton.dev/pipeline'] = 'shop-ci'; }), changed((r) => { delete r.spec.status; })),
    'the keeper starts a waiting ci run without a workspace': update(KEEPER, changed((r) => { delete r.spec.status; }, bare), bare),
    'the keeper cancels a waiting ci run without a workspace': update(KEEPER, changed((r) => { r.spec.status = 'Cancelled'; }, bare), bare),
  };
  const DENIED = {
    'an update gives a waiting ci run a workspace': update('owner@example.com', waiting, bare),
    'an update changes the claim of a waiting ci run': update('owner@example.com',
      changed((r) => { r.spec.workspaces[0].volumeClaimTemplate.spec.accessModes = ['ReadWriteMany']; }), waiting),
  };
  const verdicts = evaluate(policy, [...Object.values(ADMITTED), ...Object.values(DENIED)]).map((v) => v.denied);
  Object.keys(ADMITTED).forEach((name, i) => assert.deepEqual(verdicts[i], [], `PLANTED INNOCENT: ${name}`));
  Object.keys(DENIED).forEach((name, i) => assert.deepEqual(verdicts[Object.keys(ADMITTED).length + i], [WORKSPACE], `PLANTED DEFECT: ${name}`));
  // The clause as it was, which judged an update like a create: the three actions on a run with the claim are refused, which stalls the unit.
  const before = structuredClone(policy);
  const clause = before.spec.validations.find((v) => v.message === WORKSPACE);
  const sameWorkspaces = '(!has(object.spec.workspaces) || variables.sameWorkspaces)';
  assert.ok(clause.expression.includes(sameWorkspaces));
  clause.expression = clause.expression.replace(sameWorkspaces, '!has(object.spec.workspaces)');
  const stalled = evaluate(before, Object.values(ADMITTED).slice(0, 4)).map((v) => v.denied);
  assert.deepEqual(stalled, [[WORKSPACE], [WORKSPACE], [WORKSPACE], [WORKSPACE]], 'PLANTED DEFECT: a clause that judges an update like a create');
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
  // A publish run waits in the release queue, outside the ci quota, so it takes the release class.
  assert.deepEqual(verdict('shop-publish', {priorityClassName: RELEASE_CLASS}), [], 'PLANTED INNOCENT: a publish run with the release class');
  assert.deepEqual(verdict('shop-publish', {priorityClassName: CI_CLASS}), [PRIORITY_MESSAGE], 'PLANTED DEFECT: a publish run takes the ci class');
  // Every other field Tekton's CRD knows for a pod template is refused beside a right class. The CRD
  // is the one the repository renders, so a Tekton upgrade that adds a field turns this red until the
  // policy lists it.
  const crd = renderChart('tekton').find((d) => d.kind === 'CustomResourceDefinition' && d.metadata.name === 'pipelineruns.tekton.dev');
  const fields = Object.keys(crd.spec.versions.find((v) => v.name === 'v1').schema.openAPIV3Schema.properties.spec.properties
    .taskRunTemplate.properties.podTemplate.properties).filter((field) => field !== 'priorityClassName');
  assert.ok(fields.includes('volumes') && fields.includes('automountServiceAccountToken') && fields.length > 10);
  for (const pipeline of ['shop-release', 'shop-ci', 'shop-image', 'shop-publish']) {
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

test('the report pod of a red run is admitted by the ci quota while the check of another branch holds its slots', () => {
  const builder = imageBuilder();
  const quota = renderUnit('shop').find((d) => d.kind === 'ResourceQuota');
  const run = createdCiRun(builder);
  // Every slot is taken: the check of the other branch and the finished pod before it, which still counts.
  const held = Array.from({length: Number(quota.spec.hard.pods)}, () => podClassOf(run, 'check'));
  assert.equal(quotaAdmits(quota, held, podClassOf(run, 'check')), false, 'a second ci pod waits');
  assert.equal(quotaAdmits(quota, held, podClassOf(run, 'report-failure')), true, 'PLANTED INNOCENT: the report pod of a red run does not wait for the slot');
  const noOverride = structuredClone(run);
  delete noOverride.spec.taskRunSpecs;
  assert.equal(quotaAdmits(quota, held, podClassOf(noOverride, 'report-failure')), false, 'PLANTED DEFECT: a run without the override puts the report pod behind the check');
  const counting = structuredClone(quota);
  counting.spec.scopeSelector.matchExpressions[0].values.push(REPORT_CLASS);
  assert.equal(quotaAdmits(counting, held, podClassOf(run, 'report-failure')), false, 'PLANTED DEFECT: a quota that counts the report class holds the report pod back');
});

// What build-git-https gives its two readers, and every way that departs from it: the clone's
// GITCREDENTIALS from property `pat`, and the commit status tasks' key `token` from property `statuses`,
// a token that posts commit statuses on the unit's own repository and writes nothing else.
const gitHttpsFindings = (secret, unit) => {
  const reads = Object.fromEntries(secret.spec.data.map(({secretKey, remoteRef}) => [secretKey, `${remoteRef.key}#${remoteRef.property}`]));
  const {GITCREDENTIALS, token} = secret.spec.target.template.data;
  const found = [];
  if (GITCREDENTIALS !== 'https://x-access-token:{{ .pat }}@github.com') found.push(`GITCREDENTIALS is ${GITCREDENTIALS}`);
  if (token !== '{{ .statuses }}') found.push(`token is ${token}`);
  if (reads.pat !== `build/${unit}/repo-pat#pat`) found.push(`pat reads ${reads.pat}`);
  if (reads.statuses !== `build/${unit}/repo-pat#statuses`) found.push(`statuses reads ${reads.statuses}`);
  return found;
};

test('tekton/ci is set to pending after the gate and to the outcome in a finally task, with the statuses token and the run link', () => {
  const docs = renderUnit('shop');
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const pending = ciStep(pipeline, 'commit-status-pending');
  const outcome = pipeline.spec.finally.find((t) => t.name === 'commit-status');
  const outcomeStep = outcome.taskSpec.steps[0];
  const status = readFileSync('clusters/inventories/consumer-build/files/ci-commit-status.sh', 'utf8');
  const green = readFileSync('clusters/inventories/consumer-build/files/ci-green-status.sh', 'utf8');
  const envOf = (step) => Object.fromEntries(step.env.map((e) => [e.name, e.value ?? e.valueFrom]));
  assert.ok(pending.script.includes(status), 'the pipeline carries the script that scripts/ci-commit-status.test.mjs runs');
  assert.ok(outcomeStep.script.includes(status) && outcomeStep.script.includes(green), 'and the outcome task carries it with the reader of the green status that it calls');
  for (const step of [pending, outcomeStep]) {
    const env = envOf(step);
    assert.deepEqual(env.GITHUB_TOKEN, {secretKeyRef: {name: 'build-git-https', key: 'token'}});
    assert.equal(env.REPOSITORY_PATH, 'check/shop');
    assert.equal(env.COMMIT, '$(params.commit)');
    assert.match(env.RUN_URL, /^https:\/\/tekton\.[^/]+\/#\/namespaces\/shop-build\/pipelineruns\/\$\(context\.pipelineRun\.name\)$/);
  }
  assert.deepEqual(pipeline.spec.tasks.map((t) => t.name), ['ci'], 'one task, so one pod runs the check');
  assert.deepEqual(pipeline.spec.tasks.filter((t) => t.when), [],
    'ci-commit-status.sh reads Completed as a stopped run, which holds only while no task is skipped by a when');
  const order = ciTaskSpec(pipeline).steps.map((s) => s.name);
  assert.ok(order.indexOf('gate') < order.indexOf('commit-status-pending') && order.indexOf('commit-status-pending') < order.indexOf('clone'),
    'the pending status is set after the gate proved the commit and before the clone');
  assert.equal(envOf(pending).RUN_STATE, 'running');
  // The outcome runs for every run of the registered repository, whatever happened to the task, and reads nothing the task may not
  // have left: a finally task that names a missing result is skipped, and a run that timed out before it would stay pending for ever.
  const readsResult = (task) => /\$\(tasks\.[a-z-]+\.results\./.test(JSON.stringify(task));
  assert.ok(!readsResult(outcome), 'PLANTED INNOCENT: the outcome names the status and reason of the task and params only');
  const readingResult = structuredClone(outcome);
  readingResult.params.push({name: 'earlier-run', value: '$(tasks.ci.results.earlier-run)'});
  assert.ok(readsResult(readingResult), 'PLANTED DEFECT: a result of the task named by the outcome is caught');
  const repoURL = 'https://github.com/check/shop.git';
  assert.deepEqual(outcome.when, [{input: '$(params.git-url)', operator: 'in', values: [repoURL]}],
    'a run for a repository the registration does not name set no pending, so it sets no outcome');
  const postsFor = (task, gitUrl) => (task.when ?? []).every((w) => w.operator === 'in' && w.values.includes(w.input.replace('$(params.git-url)', gitUrl)));
  assert.ok(postsFor(outcome, repoURL), 'PLANTED INNOCENT: the registered repository gets its outcome');
  assert.ok(!postsFor(outcome, 'https://github.com/someone/else.git'), 'PLANTED DEFECT: a refused run for a repository the registration does not name posts nothing');
  const withoutWhen = structuredClone(outcome);
  delete withoutWhen.when;
  assert.ok(postsFor(withoutWhen, 'https://github.com/someone/else.git'), 'PLANTED DEFECT: an outcome without the when posts for the refused run');
  const params = Object.fromEntries(outcome.params.map((p) => [p.name, p.value]));
  assert.equal(params['run-state'], '$(tasks.status)');
  assert.equal(params['task-reasons'], '$(tasks.ci.reason)', 'the outcome reads the reason of the task, so a cancelled one is told from a failed one');
  const secret = docs.find((d) => d.kind === 'ExternalSecret' && d.metadata.name === 'build-git-https');
  assert.deepEqual(gitHttpsFindings(secret, 'shop'), [], 'PLANTED INNOCENT: the render of shop');
  const tokenOnPat = structuredClone(secret);
  tokenOnPat.spec.target.template.data.token = '{{ .pat }}';
  assert.notDeepEqual(gitHttpsFindings(tokenOnPat, 'shop'), [], 'PLANTED DEFECT: the status token back on the clone\'s pat is caught');
  const statusesOnPat = structuredClone(secret);
  statusesOnPat.spec.data.find((d) => d.secretKey === 'statuses').remoteRef.property = 'pat';
  assert.notDeepEqual(gitHttpsFindings(statusesOnPat, 'shop'), [], 'PLANTED DEFECT: the statuses data item reading property pat is caught');
  assert.throws(() => renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name: 'shop',
    repoURL: 'https://gitlab.com/check/shop.git', buildsJson: '["app"]'})]), /not https:\/\/github\.com\/<owner>\/<repository>/);
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
  const check = structuredClone(pipeline.spec.tasks.find((t) => t.name === 'ci'));
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
  const CI_TASKS = ['ci'];
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

test('the Forgejo build fence preserves the build baseline and limits each internal API to its own tasks and deployed pods', async t => {
  const yaml = (args, input) => JSON.parse(execFileSync('yq', ['-o=json', '-I=0', ...args], {input, encoding: 'utf8'}));
  const releaseTemplate = yaml(['.spec.template.spec.sources[1].helm.releaseName', 'clusters/argocd/files/platform-apps-appset.yaml']);
  assert.equal(releaseTemplate, '{{ dig "releaseName" (printf "%s-__STAGE__" .name) . }}');
  const deployed = (name, stage, extra = []) => {
    const app = yaml(['.', `clusters/inventories/${name}/app.yaml`]);
    const release = app.releaseName ?? `${app.name}-${stage}`;
    const rendered = execFileSync('helm', ['template', release, `clusters/inventories/${name}`, '--namespace', app.namespace,
      '-f', 'clusters/platform/values-common.yaml', '-f', `clusters/platform/values-${stage}.yaml`,
      '-f', `clusters/inventories/${name}/values-common.yaml`,
      ...(existsSync(`clusters/inventories/${name}/values-${stage}.yaml`) ? ['-f', `clusters/inventories/${name}/values-${stage}.yaml`] : []),
      '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/registration.yaml', '--set-string', `stage=${stage}`, ...extra],
    {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
    return {app, release, rendered, docs: yaml(['eval-all', '[.]', '-'], rendered).filter(Boolean)};
  };
  const builder = imageBuilder();
  const destination = (name, task, variable, stage) => {
    const rendered = deployed(name, stage);
    assert.equal(rendered.release, name === 'forgejo' ? `forgejo-${stage}` : 'plane');
    assert.equal(rendered.app.namespace, name);
    const api = new URL(builder.find(d => d.kind === 'Task' && d.metadata.name === task).spec.steps[0].env.find(e => e.name === variable).value);
    assert.equal(api.pathname, '/api/v1');
    const [serviceName, namespace] = api.hostname.split('.');
    assert.equal(namespace, rendered.app.namespace);
    const service = rendered.docs.find(d => d.kind === 'Service' && d.metadata.name === serviceName);
    assert.equal(service.metadata.namespace, namespace);
    const servicePort = service.spec.ports.find(p => p.port === Number(api.port));
    const workloads = rendered.docs.filter(d => ['Deployment', 'StatefulSet'].includes(d.kind) && d.metadata.namespace === namespace &&
      Object.entries(service.spec.selector).every(([key, value]) => d.spec.template.metadata.labels[key] === value));
    assert.equal(workloads.length, 1, `${serviceName} selects exactly its API workload`);
    const podLabels = workloads[0].spec.selector.matchLabels;
    assert.deepEqual(podLabels, service.spec.selector);
    const ports = workloads[0].spec.template.spec.containers.flatMap(c => c.ports ?? []);
    const port = typeof servicePort.targetPort === 'number' ? servicePort.targetPort : ports.find(p => p.name === servicePort.targetPort).containerPort;
    return {to: [{namespaceSelector: {matchLabels: {'kubernetes.io/metadata.name': namespace}}, podSelector: {matchLabels: podLabels}}],
      ports: [{protocol: 'TCP', port}]};
  };
  const baseline = renderUnit('shop').find(d => d.kind === 'NetworkPolicy' && d.metadata.name === 'build-egress').spec;
  const forgejoTasks = ['clone', 'status-pending', 'release', 'status'];
  const expectedByStage = Object.fromEntries(['prod', 'test', 'dev'].map(stage => [stage, {
    'build-egress': baseline,
    'forgejo-http-egress': {podSelector: {matchExpressions: [{key: 'tekton.dev/pipelineTask', operator: 'In', values: forgejoTasks}]},
      policyTypes: ['Egress'], egress: [destination('forgejo', 'forgejo-set-status', 'FORGEJO_API', stage)]},
    'plane-api-egress': {podSelector: {matchLabels: {'tekton.dev/pipelineTask': 'plane'}},
      policyTypes: ['Egress'], egress: [destination('plane', 'plane-update-status', 'PLANE_API', stage)]}
  }]));
  const forgejo = expectedByStage.prod['forgejo-http-egress'].egress[0];
  const plane = expectedByStage.prod['plane-api-egress'].egress[0];
  const fixtureForgejo = renderChart('forgejo').find(d => d.kind === 'Service' && d.metadata.name === 'forgejo-http').spec.selector;
  const fixturePlane = renderChart('plane').find(d => d.kind === 'Service' && d.metadata.name === 'plane-api').spec.selector;
  assert.notDeepEqual(fixtureForgejo, forgejo.to[0].podSelector.matchLabels);
  assert.notDeepEqual(fixturePlane, plane.to[0].podSelector.matchLabels);
  const docs = deployed('forgejo-build', 'prod').docs;
  const policies = docs => docs.filter(d => d.kind === 'NetworkPolicy');
  const assertFence = (docs, stage = 'prod') => {
    const expected = expectedByStage[stage];
    assert.deepEqual(policies(docs).map(p => p.metadata.name).sort(), Object.keys(expected).sort());
    for (const policy of policies(docs)) {
      assert.equal(policy.metadata.namespace, 'forgejo-build');
      assert.deepEqual(policy.spec, expected[policy.metadata.name], policy.metadata.name);
    }
  };
  assertFence(docs);
  const selects = (policy, task) => Object.entries(policy.spec.podSelector.matchLabels ?? {}).every(([key, value]) =>
    key === 'tekton.dev/pipelineTask' && value === task) && (policy.spec.podSelector.matchExpressions ?? []).every(expression =>
    expression.key === 'tekton.dev/pipelineTask' && expression.operator === 'In' && expression.values.includes(task));
  const pipeline = docs.find(d => d.kind === 'Pipeline' && d.metadata.name === 'forgejo-release');
  const tasks = [...pipeline.spec.tasks, ...pipeline.spec.finally].map(task => task.name);
  assert.deepEqual(tasks, ['status-pending', 'clone', 'check', 'build', 'release', 'plane', 'status']);
  for (const task of [...tasks, 'unrelated']) {
    const rules = policies(docs).filter(policy => selects(policy, task)).flatMap(policy => policy.spec.egress);
    const internal = rules.filter(rule => rule.to.some(peer => ['forgejo', 'plane'].includes(peer.namespaceSelector?.matchLabels?.['kubernetes.io/metadata.name'])));
    assert.deepEqual(internal, forgejoTasks.includes(task) ? [forgejo] : task === 'plane' ? [plane] : [], `${task}'s complete internal allowance`);
  }
  const policy = (copy, name) => policies(copy).find(p => p.metadata.name === name);
  const cases = [
    ['missing fence', copy => copy.splice(copy.indexOf(policy(copy, 'build-egress')), 1)],
    ['missing baseline selector', copy => { delete policy(copy, 'build-egress').spec.podSelector; }],
    ['narrowed baseline selector', copy => { policy(copy, 'build-egress').spec.podSelector = {matchLabels: {'tekton.dev/pipelineTask': 'build'}}; }],
    ['missing public exclusions', copy => { delete policy(copy, 'build-egress').spec.egress[1].to[0].ipBlock.except; }],
    ['additional broad policy', copy => copy.push({kind: 'NetworkPolicy', metadata: {name: 'allow-all', namespace: 'forgejo-build'}, spec: {podSelector: {}, policyTypes: ['Egress'], egress: [{}]}})],
    ['API server copied into baseline', copy => policy(copy, 'build-egress').spec.egress.push(structuredClone(
      renderUnit('shop').find(d => d.kind === 'NetworkPolicy' && d.metadata.name === 'bump-apiserver').spec.egress[0]))]
  ];
  for (const name of ['forgejo-http-egress', 'plane-api-egress']) {
    cases.push(...[
      ['missing task selector', p => { delete p.spec.podSelector; }],
      ['empty task selector', p => { p.spec.podSelector = {}; }],
      ['build task selected', p => { p.spec.podSelector = {matchLabels: {'tekton.dev/pipelineTask': 'build'}}; }],
      ['check task selected', p => { p.spec.podSelector = {matchLabels: {'tekton.dev/pipelineTask': 'check'}}; }],
      ['missing namespace selector', p => { delete p.spec.egress[0].to[0].namespaceSelector; }],
      ['empty namespace selector', p => { p.spec.egress[0].to[0].namespaceSelector = {}; }],
      ['unrelated namespace', p => { p.spec.egress[0].to[0].namespaceSelector.matchLabels['kubernetes.io/metadata.name'] = 'unrelated'; }],
      ['missing destination pod selector', p => { delete p.spec.egress[0].to[0].podSelector; }],
      ['empty destination pod selector', p => { p.spec.egress[0].to[0].podSelector = {}; }],
      ['wrong port', p => { p.spec.egress[0].ports[0].port = 22; }],
      ['additional port', p => { p.spec.egress[0].ports.push({protocol: 'TCP', port: 22}); }],
      ['missing ports', p => { delete p.spec.egress[0].ports; }],
      ['empty ports', p => { p.spec.egress[0].ports = []; }],
      ['UDP instead of TCP', p => { p.spec.egress[0].ports[0].protocol = 'UDP'; }],
      ['namespace and pod selectors split into alternative peers', p => { const peer = p.spec.egress[0].to[0]; p.spec.egress[0].to =
        [{namespaceSelector: peer.namespaceSelector}, {podSelector: peer.podSelector}]; }]
    ].map(([defect, edit]) => [`${name}: ${defect}`, copy => edit(policy(copy, name))]));
    cases.push([`${name}: exception copied into baseline`, copy => policy(copy, 'build-egress').spec.egress.push(structuredClone(policy(copy, name).spec.egress[0]))]);
  }
  cases.push(
    ['Plane opened to Forgejo API tasks', copy => { policy(copy, 'plane-api-egress').spec.podSelector = structuredClone(policy(copy, 'forgejo-http-egress').spec.podSelector); }],
    ['Forgejo instance matches only the default fixture release', copy => { policy(copy, 'forgejo-http-egress').spec.egress[0].to[0].podSelector.matchLabels = fixtureForgejo; }],
    ['Plane API matches only the default fixture namespace', copy => { policy(copy, 'plane-api-egress').spec.egress[0].to[0].podSelector.matchLabels = fixturePlane; }]
  );
  for (const [name, edit] of cases) await t.test(`PLANTED DEFECT: ${name}`, () => {
    const copy = structuredClone(docs);
    edit(copy);
    assert.throws(() => assertFence(copy), assert.AssertionError);
  });
  await t.test('PLANTED INNOCENT: deployed selectors and harmless metadata', () => {
    const copy = structuredClone(docs);
    for (const p of policies(copy)) p.metadata.annotations = {description: 'build egress'};
    assertFence(copy);
  });
  await t.test('configured Forgejo label keys and values survive Kubernetes YAML decoding', async t => {
    const root = mkdtempSync(join(tmpdir(), 'forgejo-labels-'));
    t.after(() => rmSync(root, {recursive: true, force: true}));
    const source = join(root, 'decode.go'), decoder = join(root, 'decode');
    writeFileSync(source, `package main
import (
  "encoding/json"
  "os"
  "sigs.k8s.io/yaml"
)
func main() {
  var documents []string
  if err := json.NewDecoder(os.Stdin).Decode(&documents); err != nil { panic(err) }
  decoded := make([]json.RawMessage, len(documents))
  for i, document := range documents {
    data, err := yaml.YAMLToJSON([]byte(document))
    if err != nil { panic(err) }
    decoded[i] = data
  }
  if err := json.NewEncoder(os.Stdout).Encode(decoded); err != nil { panic(err) }
}
`);
    execFileSync('go', ['build', '-o', decoder, source], {cwd: 'scripts/appset-render'});
    const decode = rendered => JSON.parse(execFileSync(decoder, [], {
      input: JSON.stringify(rendered.split(/^---[ \t]*$/m).filter(document => document.trim())), encoding: 'utf8'}));
    const labels = {on: 'release', yes: 'true', '0123': '0123', 'example.com/role': 'builder'};
    const rendered = deployed('forgejo-build', 'prod', ['--set-json', `egress.forgejo.podLabels=${JSON.stringify(labels)}`]).rendered;
    const forgejo = decode(deployed('forgejo', 'prod', ['--set-json', `forgejo.deployment.labels=${JSON.stringify(labels)}`]).rendered);
    const service = forgejo.find(d => d.kind === 'Service' && d.metadata.name === 'forgejo-http');
    const workloads = forgejo.filter(d => ['Deployment', 'StatefulSet'].includes(d.kind) &&
      Object.entries(service.spec.selector).every(([key, value]) => d.spec.template.metadata.labels[key] === value));
    assert.equal(workloads.length, 1);
    const podLabels = workloads[0].spec.template.metadata.labels;
    for (const [key, value] of Object.entries(labels)) assert.equal(podLabels[key], value, `Forgejo preserves ${key}`);
    const assertLabels = docs => {
      const selector = policy(docs, 'forgejo-http-egress').spec.egress[0].to[0].podSelector.matchLabels;
      for (const [key, value] of Object.entries(labels)) assert.equal(selector[key], value, `policy preserves ${key}`);
      for (const [key, value] of Object.entries(selector)) assert.equal(podLabels[key], value, `selector matches Forgejo's ${key}`);
    };
    await t.test('PLANTED INNOCENT: configured keys and string values match Forgejo pods', () => assertLabels(decode(rendered)));
    for (const key of ['on', 'yes', '0123']) await t.test(`PLANTED DEFECT: configured key ${key} emitted unquoted`, () => {
      const planted = rendered.replace(new RegExp(`^(\\s*)"${key}":`, 'm'), `$1${key}:`);
      assert.notEqual(planted, rendered);
      assert.throws(() => assertLabels(decode(planted)), assert.AssertionError);
    });
  });
  for (const stage of ['prod', 'test', 'dev']) {
    const docs = deployed('forgejo-build', stage).docs;
    await t.test(`PLANTED INNOCENT: ${stage} fence matches its deployed Forgejo and Plane workloads`, () => {
      assertFence(docs, stage);
    });
    if (stage !== 'prod') await t.test(`PLANTED DEFECT: ${stage} Forgejo instance fixed to forgejo-prod`, () => {
      const copy = structuredClone(docs);
      policy(copy, 'forgejo-http-egress').spec.egress[0].to[0].podSelector.matchLabels['app.kubernetes.io/instance'] = 'forgejo-prod';
      assert.throws(() => assertFence(copy, stage), assert.AssertionError);
    });
  }
  await t.test('PLANTED DEFECT: missing stage for the Forgejo instance', () => {
    assert.throws(() => renderChart('forgejo-build', ['--set-json', 'stage=null']),
      error => error.message.includes('forgejo-build: stage is required'));
  });
  for (const destination of ['forgejo', 'plane']) for (const field of ['namespace', 'podLabels', 'port']) {
    const key = `egress.${destination}.${field}`;
    await t.test(`PLANTED DEFECT: missing configuration ${key}`, () => {
      assert.throws(() => renderChart('forgejo-build', ['--set-json', `${key}=null`]),
        error => error.message.includes(`${key} is required`));
    });
  }
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

test('no install of the gate worker sets nodedir as an npm config, which npm 12 reports as an unknown config on every install', () => {
  // npm_config_nodedir and --nodedir are read by npm itself, and npm 12 warns "unknown nodedir" twice per
  // install; node-gyp takes the same headers from npm_package_config_node_gyp_nodedir, which npm does not read.
  const setsNodedir = (docs) => /npm_config_nodedir|--nodedir/i.test(JSON.stringify(docs).replaceAll('\\n', '\n'));
  const docs = renderUnit('shop');
  assert.ok(docs.some((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci'), 'the pipelines under check are rendered');
  assert.ok(!setsNodedir(docs), 'PLANTED INNOCENT: the pipelines as rendered select no headers through an npm config');
  const planted = (change) => { const copy = structuredClone(docs); change(copy.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci').spec.tasks.find((t) => t.name === 'ci').taskSpec.steps.find((s) => s.name === 'check')); return copy; };
  assert.ok(!setsNodedir(planted((step) => { step.env.push({name: 'npm_package_config_node_gyp_nodedir', value: '/usr/local'}); })),
    'PLANTED INNOCENT: node-gyp\'s own key selects the same headers and npm does not report it');
  assert.ok(setsNodedir(planted((step) => { step.env.push({name: 'npm_config_nodedir', value: '/usr/local'}); })), 'PLANTED DEFECT: npm_config_nodedir set as an env of the check step');
  assert.ok(setsNodedir(planted((step) => { step.env.push({name: 'NPM_CONFIG_NODEDIR', value: '/usr/local'}); })), 'PLANTED DEFECT: the upper-case spelling npm reads as well');
  assert.ok(setsNodedir(planted((step) => { step.script += '\nexport npm_config_nodedir=/usr/local\n'; })), 'PLANTED DEFECT: npm_config_nodedir exported by the script');
  assert.ok(setsNodedir(planted((step) => { step.script += '\nnpm ci --nodedir=/usr/local\n'; })), 'PLANTED DEFECT: the nodedir flag of the install command');
});

// The cache of the ci runs of a unit is a claim of its own, kept under its bound by the check step, which alone mounts it.
test('the ci cache is one claim per unit on the hostpath class that Argo CD does not wait for, and only the check step mounts it', () => {
  const docs = renderUnit('shop');
  const claim = docs.find((d) => d.kind === 'PersistentVolumeClaim' && d.metadata.name === 'ci-cache');
  assert.equal(claim.metadata.namespace, 'shop-build', 'the claim of the unit, and no claim shared between units');
  const bound = execFileSync('yq', ['.ciCache.size', 'clusters/inventories/consumer-build/values-common.yaml'], {encoding: 'utf8'}).trim();
  assert.deepEqual([claim.spec.storageClassName, claim.spec.accessModes, claim.spec.resources.requests.storage], ['microk8s-hostpath', ['ReadWriteOnce'], bound]);
  assert.equal(bound, '5Gi');
  assert.equal(claim.metadata.annotations['argocd.argoproj.io/ignore-healthcheck'], 'true',
    'the class binds on the first consumer, and a unit with no ci run would show Progressing for ever');
  const pipeline = docs.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const mounts = (name) => (ciStep(pipeline, name).volumeMounts ?? []).filter((m) => m.name === 'ci-cache');
  assert.deepEqual(ciTaskSpec(pipeline).steps.filter((s) => mounts(s.name).length > 0).map((s) => s.name), ['check'], 'PLANTED INNOCENT: the check step alone');
  assert.equal(ciTaskSpec(pipeline).volumes.find((v) => v.name === 'ci-cache').persistentVolumeClaim.claimName, 'ci-cache');
  const planted = structuredClone(pipeline);
  ciStep(planted, 'clone').volumeMounts.push({name: 'ci-cache', mountPath: '/ci-cache'});
  assert.deepEqual(ciTaskSpec(planted).steps.filter((s) => (s.volumeMounts ?? []).some((m) => m.name === 'ci-cache')).map((s) => s.name), ['clone', 'check'],
    'PLANTED DEFECT: a step that holds the clone credential and mounts the cache would let the credential step write what the check reads');
  const limit = ciStep(pipeline, 'check').env.find((e) => e.name === 'CI_CACHE_LIMIT_KIB').value;
  assert.equal(Number(limit) * 1024, quantity(bound), 'the trim holds the cache to the size of the claim: the one bound is stated in ciCache.size');
  assert.ok(ciStep(pipeline, 'check').script.includes('trap \'ci_cache_trim'), 'the check step trims the cache when it ends, whatever the outcome');
});

// A package install that a run repeats is a download per run unless its manager keeps the packages on the claim: go, pnpm, npm,
// dart and helm each read one variable for it, and the check step sets every one of them under the claim.
test('the check step points the package cache of every manager it runs at the claim, one directory per version of the manager', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const script = ciStep(pipeline, 'check').script;
  const PACKAGE_CACHES = ['COREPACK_HOME', 'HELM_CACHE_HOME', 'GOMODCACHE', 'GOCACHE', 'pnpm_config_store_dir', 'PUB_CACHE', 'npm_config_cache'];
  const unpointed = (text) => PACKAGE_CACHES.filter((name) => !new RegExp(`${name}="\\$\\{(CI_CACHE_DIR|go_cache)\\}`).test(text));
  assert.deepEqual(unpointed(script), [], 'PLANTED INNOCENT: the seven caches stand under the claim');
  for (const name of ['PUB_CACHE', 'npm_config_cache']) {
    assert.deepEqual(unpointed(script.replace(`export ${name}=`, `export ${name}_ELSEWHERE=`)), [name], `PLANTED DEFECT: a check step that leaves ${name} where the manager puts it keeps nothing between runs`);
  }
  // The block that sets the two caches of dart and npm, run with stand-in managers that print the version they have.
  const block = script.slice(script.indexOf('# The package caches of dart'), script.indexOf('if [ -f pnpm-lock.yaml ]'));
  const root = mkdtempSync(join(tmpdir(), 'ci-package-caches-')), bin = join(root, 'bin');
  try {
    mkdirSync(bin);
    const stand = (name, output, status = 0) => { writeFileSync(join(bin, name), `#!/usr/bin/env bash\necho '${output}'\nexit ${status}\n`); chmodSync(join(bin, name), 0o755); };
    const run = () => spawnSync('bash', ['-euo', 'pipefail', '-c', `${block}\necho "pub=\${PUB_CACHE-} npm=\${npm_config_cache-}"`],
      {encoding: 'utf8', env: {PATH: `${bin}:/usr/bin:/bin`, CI_CACHE_DIR: '/ci-cache'}});
    stand('dart', 'Dart SDK version: 3.13.4 (stable) (Tue Sep 15 01:01:15 2026 -0700) on "linux_x64"');
    stand('npm', '12.2.0');
    const both = run();
    assert.equal(both.status, 0, both.stderr);
    assert.equal(both.stdout.trim(), 'pub=/ci-cache/pub/3.13.4 npm=/ci-cache/npm/12.2.0', 'PLANTED INNOCENT: one directory per version of dart and of npm');
    rmSync(join(bin, 'dart'));
    rmSync(join(bin, 'npm'));
    const neither = run();
    assert.equal(neither.status, 0, neither.stderr);
    assert.equal(neither.stdout.trim(), 'pub= npm=', 'PLANTED INNOCENT: a run without dart or npm sets neither');
    stand('dart', 'a text that names no version');
    const unreadable = run();
    assert.notEqual(unreadable.status, 0, 'PLANTED DEFECT: a dart whose version cannot be read must not put its packages in a directory without a version');
    assert.match(unreadable.stderr, /the version of dart cannot be read from: a text that names no version/);
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});

// The trim runs in the check step of every run: the entries with the oldest last access go first, until the cache is within the
// bound. `limitKiB` is a number, or a function of the planted cache. `then` runs on the cache after the trim.
const CACHE_TRIM = readFileSync(`${CI_FILES}/ci-cache-trim.sh`, 'utf8');
// The trim of the first build: file by file, wherever the file lies. Planted as the defect that the whole-directory entries answer.
const FILE_BY_FILE_TRIM = `ci_cache_trim() {
  chmod -R u+w "\${CI_CACHE_DIR}"
  local total; total="$(du -sk "\${CI_CACHE_DIR}" | cut -f1)"
  while IFS=$'\\t' read -r _ size path; do
    [ "\${total}" -gt "\${CI_CACHE_LIMIT_KIB}" ] || break
    rm -f -- "\${path}"
    total=$((total - (size + 1023) / 1024))
  done < <(find "\${CI_CACHE_DIR}" -type f -printf '%A@\\t%s\\t%p\\n' | sort -n)
  find "\${CI_CACHE_DIR}" -mindepth 1 -type d -empty -delete
}`;
const runCacheTrim = (limitKiB, plant, {script = CACHE_TRIM, then = () => undefined} = {}) => {
  const root = mkdtempSync(join(tmpdir(), 'ci-trim-')), cache = join(root, 'cache');
  try {
    mkdirSync(cache);
    const file = (name, kib, accessedAt) => {
      mkdirSync(dirname(join(cache, name)), {recursive: true});
      writeFileSync(join(cache, name), Buffer.alloc(kib * 1024, 1));
      utimesSync(join(cache, name), accessedAt, accessedAt);
    };
    plant(file, cache, root);
    const limit = typeof limitKiB === 'function' ? limitKiB(cache) : limitKiB;
    const result = spawnSync('bash', ['-euo', 'pipefail', '-c', `${script}\nci_cache_trim`], {encoding: 'utf8', env: {...process.env, CI_CACHE_DIR: cache, CI_CACHE_LIMIT_KIB: String(limit)}});
    const left = [];
    const walk = (dir) => readdirSync(dir, {withFileTypes: true}).forEach((entry) => (entry.isDirectory() ? walk(join(dir, entry.name)) : left.push(join(dir, entry.name).slice(cache.length + 1))));
    walk(cache);
    return {status: result.status, stdout: result.stdout, stderr: result.stderr, left: left.sort(), after: then(cache, root)};
  } finally {
    // A cache of Go modules is read-only, and so is the planted one.
    spawnSync('chmod', ['-R', 'u+w', root]);
    rmSync(root, {recursive: true, force: true});
  }
};
const usedKiB = (cache) => Number(spawnSync('du', ['-sk', cache], {encoding: 'utf8'}).stdout.split('\t')[0]);

test('the ci cache trim evicts the entries with the oldest last access first until the cache is within its bound, and says what it evicted', () => {
  const plant = (file) => {
    file('go/go1/build/old', 64, 1_000_000_000);
    file('pnpm/11.7.0/middle', 64, 1_500_000_000);
    file('helm/v4/new', 64, 2_000_000_000);
  };
  const over = runCacheTrim(160, plant);
  assert.equal(over.status, 0, over.stderr);
  assert.deepEqual(over.left, ['helm/v4/new', 'pnpm/11.7.0/middle'], 'PLANTED DEFECT: a cache over its bound loses the entry nobody read for longest, and only that one');
  assert.match(over.stdout, /^ci-cache: \d+ KiB of 160 KiB, evicted 1 entries \(64 KiB\), the oldest last access first$/m);
  assert.ok(Number(/^ci-cache: (\d+) KiB/m.exec(over.stdout)[1]) <= 160, 'the size it prints is the size it measured after the eviction');
  const within = runCacheTrim(4096, plant);
  assert.deepEqual(within.left, ['go/go1/build/old', 'helm/v4/new', 'pnpm/11.7.0/middle'], 'PLANTED INNOCENT: a cache within its bound loses nothing');
  assert.match(within.stdout, /evicted 0 entries \(0 KiB\)/);
  const emptied = runCacheTrim(160, (file) => { file('go/go1/build/only', 64, 1_000_000_000); file('go/go1/build/also', 64, 1_000_000_001); file('go/go1/build/third', 64, 1_000_000_002); file('go/go1/build/last', 64, 1_000_000_003); });
  assert.deepEqual(emptied.left, ['go/go1/build/last', 'go/go1/build/third'], 'the newest stay when several must go');
  const noCache = spawnSync('bash', ['-euo', 'pipefail', '-c', `${CACHE_TRIM}\nci_cache_trim`], {encoding: 'utf8', env: {...process.env, CI_CACHE_DIR: '/nonexistent-ci-cache', CI_CACHE_LIMIT_KIB: '1'}});
  assert.equal(noCache.status, 0, 'a run whose claim is not mounted has nothing to trim');
});

// What each tool brings back by itself when one file of it is missing, probed on 2026-10-19 with go 1.27.1, pnpm 11.7.0, npm 12.2.0,
// dart 3.13.4, corepack 0.36.0 and helm 4.3.0: the file stands alone, and only that file goes.
const SINGLE_FILES = ['archives/0a1b2c', 'corepack/lastKnownGood.json', 'go/go1.24.13/build/ab/ab12-a', 'go/go1.24.13/mod/cache/download/example.com/m/@v/v1.0.0.zip',
  'go/go1.24.13/mod/cache/download/example.com/m/@v/v1.0.0.ziphash', 'go/go1.24.13/mod/cache/download/example.com/m/@v/v1.0.0.mod', 'pnpm/11.7.0/v11/files/ab/cdef', 'pnpm/11.7.0/v11/index.db',
  'npm/12.2.0/_cacache/content-v2/sha512/ab/cd/ef', 'pub/3.13.4/hosted-hashes/pub.dev/args-2.7.0.sha256', 'pub/3.13.4/hosted/pub.dev/.cache/args-versions.json', 'helm/v4.3.0/repository/chart-1.0.0.tgz'];
// What a tool takes as complete as soon as its directory exists: the files of the entry, and the entry itself.
const DIRECTORY_ENTRIES = {
  'a module that go extracted': ['go/go1.24.13/mod/example.com/m@v1.0.0', ['go.mod', 'a/a.go', 'b/b.go']],
  'a module of a nested path that go extracted': ['go/go1.24.13/mod/golang.org/x/text@v0.3.0', ['go.mod', 'unicode/norm/norm.go', 'transform/transform.go']],
  'a repository that go cloned': ['go/go1.24.13/mod/cache/vcs/0123abcd', ['HEAD', 'objects/pack/pack-1.pack', 'refs/heads/main']],
  'a package manager that corepack unpacked': ['corepack/v1/pnpm/11.7.0', ['.corepack', 'bin/pnpm.cjs', 'dist/pnpm.mjs']],
  'a package folder of pub': ['pub/3.13.4/hosted/pub.dev/args-2.7.0', ['pubspec.yaml', 'lib/args.dart', 'lib/src/parser.dart']],
  'a repository that pub cloned': ['pub/3.13.4/git/cache/shop-0123', ['HEAD', 'objects/pack/pack-1.pack']],
  'a checkout that pub made': ['pub/3.13.4/git/shop-0123', ['pubspec.yaml', 'lib/shop.dart']],
};

test('the ci cache trim evicts a directory that a tool takes as complete whole, and a file that stands alone by itself', () => {
  const oneKiBLess = (cache) => usedKiB(cache) - 1;
  for (const [what, [entry, files]] of Object.entries(DIRECTORY_ENTRIES)) {
    // The second file has the oldest last access of the whole cache; a newer file of the entry and a newer entry stand beside it.
    const plant = (file, cache) => {
      files.forEach((name, i) => file(`${entry}/${name}`, 4, i === 1 ? 1_000_000_000 : 1_200_000_000 + i));
      file('go/go1.24.13/build/newer', 64, 2_000_000_000);
      spawnSync('chmod', ['-R', 'a-w', join(cache, entry)]);
    };
    const present = (left) => files.filter((name) => left.includes(`${entry}/${name}`));
    const whole = runCacheTrim(oneKiBLess, plant);
    assert.equal(whole.status, 0, `${what}: ${whole.stderr}`);
    assert.deepEqual(whole.left, ['go/go1.24.13/build/newer'], `PLANTED INNOCENT: ${what} goes whole, the read-only one too`);
    assert.match(whole.stdout, /evicted 1 entries/, what);
    const stays = runCacheTrim(4096, plant);
    assert.deepEqual(present(stays.left), files, `PLANTED INNOCENT: ${what} stays whole within the bound`);
    // The bound is one KiB below what the cache holds: a trim file by file has enough with the oldest file, the whole entry must go.
    const partial = runCacheTrim(oneKiBLess, plant, {script: FILE_BY_FILE_TRIM});
    assert.ok(present(partial.left).length > 0 && present(partial.left).length < files.length,
      `PLANTED DEFECT: a trim file by file leaves ${what} with ${present(partial.left).length} of ${files.length} files, which its tool never fetches again`);
  }
  for (const single of SINGLE_FILES) {
    const siblings = [`${dirname(single)}/sibling-1`, `${dirname(single)}/sibling-2`];
    const plant = (file) => { file(single, 64, 1_000_000_000); siblings.forEach((name) => file(name, 64, 2_000_000_000)); };
    const result = runCacheTrim(oneKiBLess, plant);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.left, siblings.sort(), `PLANTED INNOCENT: ${single} stands alone, so its siblings stay`);
  }
});

// The first build of the trim left half a Go module: go takes the directory as complete, so every later run of the unit failed to compile.
test('a go build still compiles after the trim has evicted the module with the oldest access, and fails after a trim file by file', () => {
  const zipper = 'package main\n\nimport (\n\t"archive/zip"\n\t"io/fs"\n\t"os"\n\t"path/filepath"\n)\n\nfunc main() {\n\tout, _ := os.Create(os.Args[1])\n\tw := zip.NewWriter(out)\n' +
    '\troot, prefix := os.Args[2], os.Args[3]\n\tfilepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {\n\t\tif err != nil || d.IsDir() {\n\t\t\treturn err\n\t\t}\n' +
    '\t\trel, _ := filepath.Rel(root, path)\n\t\tf, _ := w.Create(prefix + filepath.ToSlash(rel))\n\t\tdata, _ := os.ReadFile(path)\n\t\tf.Write(data)\n\t\treturn nil\n\t})\n\tw.Close()\n\tout.Close()\n}\n';
  // The build cache of go stands outside the planted cache and serves both runs, so the standard library is compiled once.
  const gocache = mkdtempSync(join(tmpdir(), 'ci-trim-gocache-'));
  const goEnv = (root, cache) => ({...process.env, GOPROXY: `file://${root}/proxy`, GOSUMDB: 'off', GOFLAGS: '-mod=mod', GOTOOLCHAIN: 'local', GOWORK: 'off',
    GOPATH: join(root, 'gopath'), GOMODCACHE: join(cache, 'go/go1.24.13/mod'), GOCACHE: gocache, HOME: root});
  const build = (root, cache) => spawnSync('go', ['build', '-o', '/dev/null', '.'], {cwd: join(root, 'app'), encoding: 'utf8', env: goEnv(root, cache)});
  const plant = (file, cache, root) => {
    const files = {'go.mod': 'module example.com/m\n\ngo 1.21\n', 'a/a.go': 'package a\n\nfunc A() string { return "a" }\n', 'b/b.go': 'package b\n\nfunc B() string { return "b" }\n'};
    mkdirSync(join(root, 'module'), {recursive: true});
    for (const [name, text] of Object.entries(files)) { mkdirSync(dirname(join(root, 'module', name)), {recursive: true}); writeFileSync(join(root, 'module', name), text); }
    mkdirSync(join(root, 'proxy/example.com/m/@v'), {recursive: true});
    writeFileSync(join(root, 'proxy/example.com/m/@v/v1.0.0.info'), '{"Version":"v1.0.0","Time":"2020-01-01T00:00:00Z"}');
    writeFileSync(join(root, 'proxy/example.com/m/@v/v1.0.0.mod'), files['go.mod']);
    writeFileSync(join(root, 'zipper.go'), zipper);
    execFileSync('go', ['run', join(root, 'zipper.go'), join(root, 'proxy/example.com/m/@v/v1.0.0.zip'), join(root, 'module'), 'example.com/m@v1.0.0/'], {env: goEnv(root, cache)});
    mkdirSync(join(root, 'app'), {recursive: true});
    writeFileSync(join(root, 'app/go.mod'), 'module shop\n\ngo 1.21\n\nrequire example.com/m v1.0.0\n');
    writeFileSync(join(root, 'app/main.go'), 'package main\n\nimport "example.com/m/b"\n\nfunc main() { println(b.B()) }\n');
    const first = build(root, cache);
    assert.equal(first.status, 0, first.stderr);
    // The module, extracted, has the oldest access, b/b.go the oldest of it; every file that go downloaded is newer.
    const module = join(cache, 'go/go1.24.13/mod/example.com/m@v1.0.0');
    for (const name of Object.keys(files)) utimesSync(join(module, name), name === 'b/b.go' ? 1_000_000_000 : 1_100_000_000, name === 'b/b.go' ? 1_000_000_000 : 1_100_000_000);
    const stamp = (dir) => readdirSync(dir, {withFileTypes: true}).forEach((entry) => (entry.isDirectory() ? stamp(join(dir, entry.name)) : utimesSync(join(dir, entry.name), 1_900_000_000, 1_900_000_000)));
    stamp(join(cache, 'go/go1.24.13/mod/cache'));
  };
  const after = (cache, root) => ({module: ['a/a.go', 'b/b.go'].map((name) => existsSync(join(cache, 'go/go1.24.13/mod/example.com/m@v1.0.0', name))), build: build(root, cache)});
  // One KiB below what the cache holds: b/b.go alone would be enough for a trim file by file, and the module is the entry to evict.
  const bound = (cache) => usedKiB(cache) - 1;
  try {
    const trimmed = runCacheTrim(bound, plant, {then: after});
    assert.equal(trimmed.status, 0, trimmed.stderr);
    assert.equal(trimmed.after.module[0], trimmed.after.module[1], 'PLANTED INNOCENT: the module is whole or gone, never half');
    assert.equal(trimmed.after.build.status, 0, `PLANTED INNOCENT: the next run compiles, from the proxy if the module went: ${trimmed.after.build.stderr}`);
    const halved = runCacheTrim(bound, plant, {script: FILE_BY_FILE_TRIM, then: after});
    assert.deepEqual(halved.after.module, [true, false], 'a trim file by file takes b/b.go, the oldest file, and leaves the module standing');
    assert.notEqual(halved.after.build.status, 0, 'PLANTED DEFECT: a trim file by file ends in a unit whose every run fails to compile');
    assert.match(halved.after.build.stderr, /b\b.*(no such file|does not contain package|no Go files)|(no such file|does not contain package|no Go files).*b\b/s);
  } finally {
    // The build cache of go makes nothing read-only, but its module cache does, and so would a cache pointed at it.
    spawnSync('chmod', ['-R', 'u+w', gocache]);
    rmSync(gocache, {recursive: true, force: true});
  }
});

// Every step after earlier-green ends at once when the commit is green already, and neither earlier-green nor the gate before it does.
test('every step of the ci task after earlier-green ends at once on a commit that is green already', () => {
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-ci');
  const guard = 'if [ -e /workspace/earlier-green ]; then echo "skipped: the commit is green already"; exit 0; fi';
  const unguarded = (p) => {
    const steps = ciTaskSpec(p).steps, after = steps.findIndex((s) => s.name === 'earlier-green') + 1;
    return steps.slice(after).filter((s) => !s.script.split('\n').slice(0, 3).includes(guard)).map((s) => s.name);
  };
  assert.deepEqual(unguarded(pipeline), [], 'PLANTED INNOCENT: all eight steps after earlier-green carry the guard in their first lines');
  assert.equal(ciTaskSpec(pipeline).steps.length - ciTaskSpec(pipeline).steps.findIndex((s) => s.name === 'earlier-green') - 1, 8);
  for (const name of CI_STEPS.slice(CI_STEPS.indexOf('earlier-green') + 1)) {
    const planted = structuredClone(pipeline);
    const step = ciStep(planted, name);
    step.script = step.script.replace(guard, '');
    assert.deepEqual(unguarded(planted), [name], `PLANTED DEFECT: ${name} without the guard would clone, or check, a commit that is green already`);
  }
  for (const name of ['gate', 'earlier-green']) assert.ok(!ciStep(pipeline, name).script.includes(guard), `${name} runs for every commit`);
  const scriptOf = (name) => ciStep(pipeline, name).script;
  assert.ok(scriptOf('earlier-green').includes('touch /workspace/earlier-green') && scriptOf('earlier-green').includes('$(results.earlier-run.path)'),
    'the marker and the result that names the run are written by the step that found the green status');
  const check = ciStep(pipeline, 'check');
  assert.ok(!(check.volumeMounts ?? []).some((m) => m.mountPath === '/workspace'), 'the marker lives in the implicit /workspace of the pod, which no step mounts over');
});
