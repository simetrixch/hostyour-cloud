import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, copyFileSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
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
    [{triggerRef: 'github-deploy-request'}, {triggerRef: 'github-release-publish'},
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
      if (builds.length === 0) assert.deepEqual(readers.map(d => d.metadata.name).sort(), ['build-git-https', 'build-npmrc', 'image-builder-registry-push'],
        record.name + ' holds the credentials of its publish run, and no pull or bump credential');
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

// What keeps a run in a build namespace from holding a credential it must not, and from running anywhere else, is
// asserted here on the rendered charts; the admission policy and the trigger filters are evaluated by scripts/vap-eval,
// which runs the CEL library the build plane runs.
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
const imageBuilder = () => renderChart('image-builder');
// What a TriggerTemplate creates, with the trigger's parameters filled in.
const createdRun = (docs, template) => JSON.parse(JSON.stringify(docs.find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === template).spec.resourcetemplates[0])
  .replaceAll('$(tt.params.unit)', 'shop').replace(/\$\(tt\.params\.[a-z-]+\)/g, 'x'));
const guardOf = (docs) => docs.find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');

const OWNERSHIP = 'a build namespace runs only its own release, image and publish Pipelines.';
const WORKSPACE = 'a managed run uses only a new source PVC, with no secret, projected, CSI or shared-claim workspace.';
const EVENT_LISTENER = 'system:serviceaccount:image-builder:eventlistener-sa';
const RELEASE_CLASS = 'image-builder-release';
// podTemplate null leaves the template out. A managed run carries the one `source` claim; `workspaces` replaces that
// default, and null leaves them out.
const SOURCE_CLAIM = [{name: 'source', volumeClaimTemplate: {spec: {accessModes: ['ReadWriteOnce']}}}];
const createsRun = (namespace, pipeline, podTemplate = {priorityClassName: RELEASE_CLASS}, workspaces = SOURCE_CLAIM) => ({object: {metadata: {namespace, labels: {'image-builder.io/consumer': 'shop'}},
  spec: {pipelineRef: {name: pipeline}, taskRunTemplate: {serviceAccountName: 'pipeline-sa', ...(podTemplate ? {podTemplate} : {})},
    ...(workspaces ? {workspaces} : {})}},
  oldObject: null, request: {operation: 'CREATE', namespace, userInfo: {username: EVENT_LISTENER}}});

test('the admission policy admits the release, the image and the publish pipeline of a unit in its own build namespace, and nothing else', () => {
  const policy = guardOf(imageBuilder());
  const ADMITTED = ['shop-release', 'shop-image', 'shop-publish'];
  const DENIED = ['shop-ci', 'post-release', 'post-image', 'post-publish', 'shop-image-extra', 'shop-release-extra', 'shop-publish-extra', 'shop-tests', 'shop', 'release', 'image', 'publish'];
  const verdicts = evaluate(policy, [...ADMITTED, ...DENIED].map((name) => createsRun('shop-build', name))).map((v) => v.denied);
  ADMITTED.forEach((name, i) => assert.deepEqual(verdicts[i], [], `PLANTED INNOCENT: ${name} in shop-build`));
  DENIED.forEach((name, i) => assert.deepEqual(verdicts[ADMITTED.length + i], [OWNERSHIP], `PLANTED DEFECT: ${name} in shop-build`));
  // The refusal is the ownership clause's: without it the foreign release pipeline is admitted.
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => v.message !== OWNERSHIP);
  assert.deepEqual(evaluate(without, [createsRun('shop-build', 'post-release')])[0].denied, []);
  // Every managed run keeps its one `source` claim.
  const workspaceVerdict = (pipeline, workspaces) => evaluate(policy, [createsRun('shop-build', pipeline, undefined, workspaces)])[0].denied;
  for (const pipeline of ['shop-release', 'shop-image', 'shop-publish']) {
    assert.deepEqual(workspaceVerdict(pipeline, SOURCE_CLAIM), [], `PLANTED INNOCENT: ${pipeline} with the one source claim`);
    assert.deepEqual(workspaceVerdict(pipeline, null), [WORKSPACE], `PLANTED DEFECT: ${pipeline} without its source claim`);
    assert.deepEqual(workspaceVerdict(pipeline, [{name: 'source', emptyDir: {}}]), [WORKSPACE], `PLANTED DEFECT: ${pipeline} with an emptyDir workspace`);
  }
  // The Tekton controller keeps updating a release run it started.
  const run = createsRun('shop-build', 'shop-release');
  const update = {...run, oldObject: run.object, request: {operation: 'UPDATE', namespace: 'shop-build',
    userInfo: {username: 'system:serviceaccount:tekton:tekton-controller'}}};
  assert.deepEqual(evaluate(policy, [update])[0].denied, []);
});

test('the deploy trigger takes a deploy tag push and the publish trigger a release tag push, and the runs they create wait for the queue', () => {
  const builder = imageBuilder();
  const byKind = (kind, name) => builder.find((d) => d.kind === kind && d.metadata.name === name);
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].spec.status, 'PipelineRunPending', 'a release run waits for the release queue');
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].spec.taskRunTemplate.podTemplate.priorityClassName, RELEASE_CLASS);
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].spec.taskRunSpecs, undefined, 'a release run carries no per-task override');
  assert.equal(byKind('TriggerTemplate', 'deploy-request').spec.resourcetemplates[0].metadata.labels['image-builder.io/consumer'], '$(tt.params.unit)');
  const trigger = (name) => triggerOf(builder, name);
  const matches = (name, bodies, edit) => triggerMatches(builder, name, bodies, edit);
  // GitHub sends the repository's default branch with every push (repository.default_branch); `main` here, so a
  // filter that names `master` instead of reading it is seen.
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
  const deploy = matches('github-deploy-request', bodies), publish = matches('github-release-publish', bodies);
  const verdicts = {deploy: [false, false, true, false, false, false, false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, true, false, false, false, false, false, false, false, true, false],
    publish: [false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, false, false, false, false, false, false, false, true]};
  Object.keys(pushes).forEach((name, i) => {
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
  // The release of a private repository goes through the deploy and the publish trigger: neither reads the visibility.
  assert.ok(!trigger('github-deploy-request').filter.includes('visibility'), 'the deploy trigger does not read the visibility');
  assert.ok(!trigger('github-release-publish').filter.includes('visibility'), 'the publish trigger does not read the visibility');
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

// A unit that builds nothing (`builds: []` in its registration) still gets its publish pipeline, and gets no release
// pipeline and no credential that writes: the namespace runs repository code.
const PUBLISH_PARTS = [['Pipeline', 'shop-publish'], ['ExternalSecret', 'build-git-https'], ['ExternalSecret', 'build-npmrc'], ['ExternalSecret', 'image-builder-registry-push']];
const RELEASE_PARTS = [['Pipeline', 'shop-release'], ['Pipeline', 'shop-image'], ['ExternalSecret', 'image-builder-registry-pull-opaque'], ['ExternalSecret', 'build-registry-pull'], ['ExternalSecret', 'bump-git-https']];
const holds = (docs, parts) => parts.map(([kind, name]) => docs.some((d) => d.kind === kind && d.metadata.name === name));
const isPublishOnly = (docs) => holds(docs, PUBLISH_PARTS).every(Boolean) && !holds(docs, RELEASE_PARTS).some(Boolean);

test('a unit that builds nothing renders the publish pipeline, and no release, registry pull or bump part', () => {
  const publishOnly = renderUnit('shop', []);
  assert.ok(isPublishOnly(publishOnly), 'the publish pipeline, the clone credential, build-npmrc and the push credential render; release pipeline, pull secret and bump secret do not');
  const withBuilds = renderUnit('shop');
  assert.deepEqual(holds(withBuilds, [...PUBLISH_PARTS, ...RELEASE_PARTS]), Array(PUBLISH_PARTS.length + RELEASE_PARTS.length).fill(true), 'PLANTED INNOCENT: a unit with builds renders both pipelines and every credential');
  assert.ok(!isPublishOnly(withBuilds), 'a unit with builds is not a publish-only unit');
  const leaky = [...publishOnly, withBuilds.find((d) => d.kind === 'ExternalSecret' && d.metadata.name === 'bump-git-https')];
  assert.ok(!isPublishOnly(leaky), 'PLANTED DEFECT: a publish-only render that carries the bump credential is caught');
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

// ci-tools.json at a repository's root names the tools its release build runs with, {"<tool>": "<x.y.z>"}: the scan of
// the publish pipeline hands the lines to pack and build-binaries as a result; each installs them from the table of
// files/ci-tools.table, with its sha256, and puts them before the image's own tools on PATH.
const CI_FILES = 'clusters/inventories/consumer-build/files';
// The tools files/ci-install-tools.sh can install: the patterns of its case.
const INSTALLER = readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8');
const installedTools = () => INSTALLER.slice(INSTALLER.indexOf('case "${tool}" in')).match(/^ {4}[a-z][a-z |]*\)$/gm).flatMap((pattern) => pattern.trim().slice(0, -1).split(' | '));

const TOOLS_TABLE = readFileSync(`${CI_FILES}/ci-tools.table`, 'utf8');
const TABLE_HOSTS = ['nodejs.org', 'registry.npmjs.org', 'go.dev', 'storage.googleapis.com', 'zot.master.digitacloud.app'];
// A row on the owner's mirror, which serves a file as the blob of its sha256 and names it by the slot <sha256>.
const OWNED_ROW = 'node 26.11.1 15fc043a51a5783f2f4b634561091658f5a7f0e3db03f997dca3a8033a33e45b https://zot.master.digitacloud.app/v2/simetrixch/github.com/nodejs/node/releases/download/v26.11.1/node-v26.11.1-linux-x64.tar.gz/blobs/sha256:<sha256>';
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

test('the tools table carries one sha256 and one https url per tool and version, for exactly the tools the installer installs', () => {
  const tools = installedTools();
  assert.deepEqual(tableErrors(TOOLS_TABLE, tools), [], 'PLANTED INNOCENT: the table as it stands');
  assert.deepEqual([...new Set(TOOLS_TABLE.split('\n').filter(Boolean).map((line) => line.split(' ')[0]))].sort(), [...tools].sort(), 'every installed tool has a row and no row names another');
  const first = TOOLS_TABLE.split('\n')[0], [tool, version, sha256, url] = first.split(' ');
  assert.deepEqual(tableErrors(`${OWNED_ROW}\n`, tools), [], 'PLANTED INNOCENT: a row on the owner\'s mirror, by the slot');
  const owned = Object.fromEntries(['tool', 'version', 'sha256', 'url'].map((key, at) => [key, OWNED_ROW.split(' ')[at]]));
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
  // The SDK release of emscripten: LLVM in install/bin, Binaryen's programs beside it, emcc in install/emscripten. Its
  // emcc prints the version of the emscripten-version.txt beside it, which the archive ships as <x.y.z>-git.
  program(join(src, 'emcc/install/emscripten/emcc'), 'emcc-fixture "$(tr -d \'"\' < "$(dirname "$0")/emscripten-version.txt") (fixture)"');
  writeFileSync(join(src, 'emcc/install/emscripten/emscripten-version.txt'), '5.0.1-git\n');
  program(join(src, 'emcc/install/bin/clang'), 'clang-fixture');
  program(join(src, 'emcc/install/bin/wasm-opt'), 'wasm-opt-fixture');
  const tgz = (name, dir, entry) => execFileSync('tar', ['-czf', join(out, name), '-C', join(src, dir), entry]);
  tgz('node.tgz', 'node', 'node-v'); tgz('npm.tgz', 'npm', 'package'); tgz('go.tgz', 'go', 'go');
  execFileSync('tar', ['-cJf', join(out, 'emcc.tar.xz'), '-C', join(src, 'emcc'), 'install']);
  execFileSync('python3', ['-I', '-m', 'zipfile', '-c', join(out, 'dart.zip'), 'dart-sdk'], {cwd: join(src, 'dart')});
  // The owner's mirror serves a file as the blob of its sha256: the fixture serves go that way, and its row names the blob by the slot.
  const sha256Of = (archive) => createHash('sha256').update(readFileSync(join(out, archive))).digest('hex');
  mkdirSync(join(out, 'owned/blobs'), {recursive: true});
  copyFileSync(join(out, 'go.tgz'), join(out, 'owned/blobs', `sha256:${sha256Of('go.tgz')}`));
  const row = (tool, version, archive) => `${tool} ${version} ${sha256Of(archive)} ${tool === 'go' ? `file://${join(out, 'owned/blobs/sha256:<sha256>')}` : `file://${join(out, archive)}`}`;
  return Object.fromEntries([['node', '26.11.1', 'node.tgz'], ['npm', '12.2.0', 'npm.tgz'], ['go', '1.24.13', 'go.tgz'], ['dart', '3.13.4', 'dart.zip'],
    ['emcc', '5.0.1', 'emcc.tar.xz']].map(([tool, version, archive]) => [tool, row(tool, version, archive)]));
};

const runInstallTools = (wanted, rows, plant = (script) => script, extraEnv = {}) => {
  const root = mkdtempSync(join(tmpdir(), 'ci-tools-')), dir = join(root, 'installed');
  try {
    const table = rows(buildToolFixtures(root));
    const script = plant(readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8')).replaceAll('/tmp/ci-tools', dir);
    const probe = 'for t in node npm npx go dart emcc; do printf "%s|%s|%s\\n" "$t" "$(command -v "$t" || true)" "$("$t" --version </dev/null 2>&1 | head -n 1 || true)"; done';
    const result = spawnSync('bash', ['-euo', 'pipefail', '-c', `${script}\n${probe}`], {encoding: 'utf8', env: {...process.env, CI_TOOLS: wanted, CI_TOOLS_TABLE: table, ...extraEnv}});
    const resolved = Object.fromEntries((result.stdout.match(/^(node|npm|npx|go|dart|emcc)\|.*$/gm) ?? []).map((line) => { const [tool, path, output] = line.split('|'); return [tool, {inside: path.startsWith(dir), output}]; }));
    // emcc reads the .emscripten beside it as Python; python3 reads the two roots out of it the same way.
    const emccConfig = join(dir, 'emcc/emscripten/.emscripten');
    const emccRoots = existsSync(emccConfig) ? execFileSync('python3', ['-I', '-c', 'import sys; exec(open(sys.argv[1]).read()); print(LLVM_ROOT); print(BINARYEN_ROOT)', emccConfig], {encoding: 'utf8'})
      .trim().replaceAll(dir, '<installed>').split('\n') : null;
    return {status: result.status, stdout: result.stdout, stderr: result.stderr, resolved, emccRoots,
      unpacked: ['node', 'npm', 'go', 'dart', 'emcc'].filter((tool) => existsSync(join(dir, tool))), downloaded: existsSync(join(dir, 'node.download'))};
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
};
const allRows = (rows) => Object.values(rows).join('\n');
const WANTED_ALL = 'node 26.11.1\nnpm 12.2.0\ngo 1.24.13\ndart 3.13.4\nemcc 5.0.1\n';

test('the tools step installs each tool of ci-tools.json from the table before the image\'s own, and refuses what the table cannot vouch for', () => {
  const all = runInstallTools(WANTED_ALL, allRows);
  assert.equal(all.status, 0, all.stderr);
  assert.deepEqual(Object.entries(all.resolved).map(([tool, r]) => [tool, r.inside, r.output]), [['node', true, 'node-fixture'], ['npm', true, 'npm-fixture'], ['npx', true, 'npx-fixture'],
    ['go', true, 'go-fixture'], ['dart', true, 'dart-fixture'], ['emcc', true, 'emcc-fixture 5.0.1 (fixture)']],
    'PLANTED INNOCENT: all five are installed, and the npm named beats the npm that ships with node');
  assert.deepEqual(all.emccRoots, ['<installed>/emcc/bin', '<installed>/emcc'], 'emcc reads LLVM from the bin of the SDK release and Binaryen from its root, as emsdk activate writes them');
  assert.match(all.stdout, /^check: emcc-fixture 5\.0\.1 \(fixture\), downloaded in \d+ s and unpacked in \d+ s$/m, 'the log names what emcc --version printed and the seconds its download and unpack took');
  const unversioned = runInstallTools('emcc 5.0.1\n', allRows, (script) => script.replace(/^.*emscripten-version\.txt.*$/gm, ''));
  assert.equal(unversioned.resolved.emcc.output, 'emcc-fixture 5.0.1-git (fixture)', 'PLANTED DEFECT: an emcc that reports 5.0.1-git, which packages/quickjs/build.sh of digita-platform refuses, is seen');
  const unconfigured = runInstallTools('emcc 5.0.1\n', allRows, (script) => script.replace(/^.*\.emscripten.*$/gm, ''));
  assert.equal(unconfigured.emccRoots, null, 'PLANTED DEFECT: an emcc without its config file is seen');
  const reversed = runInstallTools('go 1.24.13\nnpm 12.2.0\nnode 26.11.1\n', allRows);
  assert.equal(reversed.resolved.npm.output, 'npm-fixture', 'the order of ci-tools.json does not decide which npm runs');
  const nodeLast = runInstallTools(WANTED_ALL, (rows) => [rows.npm, rows.node, rows.go, rows.dart, rows.emcc].join('\n'));
  assert.equal(nodeLast.resolved.npm.output, 'npm-bundled-with-node', 'PLANTED DEFECT: a table that lists node after npm puts the npm of node first, and the probe sees it');
  const only = runInstallTools('dart 3.13.4\n', allRows);
  assert.equal(only.status, 0, only.stderr);
  assert.deepEqual([only.resolved.dart.inside, only.resolved.node.inside, only.resolved.go.inside, only.unpacked], [true, false, false, ['dart']], 'only the tool named is installed');
  const none = runInstallTools('', (rows) => Object.values(rows).map((row) => row.replace(/file:\/\/\S+/, 'file:///nowhere')).join('\n'));
  assert.deepEqual([none.status, none.downloaded, none.unpacked], [0, false, []], 'a repository without ci-tools.json downloads nothing');
  const absent = runInstallTools('node 26.11.2\n', allRows);
  assert.notEqual(absent.status, 0, 'PLANTED DEFECT: a version the table lacks ends the run');
  assert.match(absent.stderr, /names node 26\.11\.2, which the tools table of this pipeline does not carry/);
  assert.deepEqual([absent.downloaded, absent.unpacked], [false, []], 'and ends it before anything is downloaded');
  const half = runInstallTools('dart 3.13.4\nnode 26.11.2\n', allRows);
  assert.notEqual(half.status, 0, 'one missing version among present ones ends the run');
  assert.deepEqual([half.downloaded, half.unpacked], [false, []], 'and installs none of them');
  assert.notEqual(runInstallTools('ruby 3.4.0\n', allRows).status, 0, 'PLANTED DEFECT: a tool the table does not carry ends the run');
  const forged = runInstallTools('node 26.11.1\n', (rows) => rows.node.replace(/ [0-9a-f]{64} /, ` ${'0'.repeat(64)} `));
  assert.notEqual(forged.status, 0, 'PLANTED DEFECT: an archive whose sha256 differs ends the run');
  assert.deepEqual([forged.downloaded, forged.unpacked], [true, []], 'after the download and before anything is unpacked');
  const forgedOwned = runInstallTools('go 1.24.13\n', (rows) => allRows({...rows, go: rows.go.replace(/ [0-9a-f]{64} /, ` ${'0'.repeat(64)} `)}));
  assert.notEqual(forgedOwned.status, 0, 'PLANTED DEFECT: an archive of the owner\'s mirror whose sha256 differs ends the run');
  assert.deepEqual(forgedOwned.unpacked, [], 'before the go of the archive is unpacked');
  const blobOf = (row) => { const [, , hex, url] = row.split(' '); return url.replace('file://', '').replace('<sha256>', hex); };
  assert.match(all.stdout, /^check: go 1\.24\.13, file:\/\/\S+\/blobs\/sha256:[0-9a-f]{64}, sha256 [0-9a-f]{64}$/m, 'PLANTED INNOCENT: the slot of the go row is filled with its sha256, and the log names the address that was read');
  const otherBytes = runInstallTools('go 1.24.13\n', (rows) => { writeFileSync(blobOf(rows.go), 'other bytes'); return allRows(rows); });
  assert.notEqual(otherBytes.status, 0, 'PLANTED DEFECT: an owned address whose filled blob serves other bytes ends the run');
  assert.match(otherBytes.stdout + otherBytes.stderr, /FAILED/, 'at the sha256sum -c, and not at the fetch');
  assert.deepEqual(otherBytes.unpacked, [], 'before anything of the file is unpacked');
  const unknown = runInstallTools('ruby 3.4.0\n', (rows) => `ruby 3.4.0 ${rows.node.split(' ')[2]} ${rows.node.split(' ')[3]}`);
  assert.notEqual(unknown.status, 0, 'a row for a tool this step cannot install ends the run');
  assert.match(unknown.stderr, /ruby, which this step cannot install/);
});

// helm, yq and jq are the tools every repository's check may use whatever its ci-tools.json names, so they stand in
// files/ci-fixed-tools.sh, and the step that runs a repository's own scripts carries that file and the one that installs
// ci-tools.json before it runs them: build-binaries of the publish pipeline before release/build.sh, whose suites read JSON
// with jq (test/checks/release_digests_test.dart of ansiwise-cli).
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

test('build-binaries installs the fixed tools and the tools of ci-tools.json before release/build.sh, by their files', () => {
  const fixed = readFileSync(`${CI_FILES}/ci-fixed-tools.sh`, 'utf8').trimEnd();
  for (const tool of [/helm-v4\.3\.0-linux-amd64\.tar\.gz/, /yq_linux_amd64/, /jq-linux-amd64/]) assert.match(fixed, tool, `${tool} is installed by the fixed tools`);
  assert.equal(fixed.match(/sha256sum -c -/g)?.length, 3, 'helm, yq and jq are each held to their sha256');
  const build = renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish')
    .spec.tasks.find((t) => t.name === 'build-binaries').taskSpec.steps.find((s) => s.name === 'build').script;
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

// A tool is pinned for the repositories that name it in ci-tools.json, and pack of the publish pipeline installs it
// before its packages are built.
// digita-platform's packages/quickjs/build.sh runs only with emcc 5.0.1 first on PATH; its row pins the SDK release emsdk
// 14c18b56 installs for 5.0.1. The row pins its archive by its sha256; release holds a part of its url and what that part
// reads for another release, the planted defect.
const PINNED_ROWS = [
  {row: 'emcc 5.0.1 bda6917b630fcc604cca39af433180adfd7195e378075331ceac926553684249 https://storage.googleapis.com/webassembly/emscripten-releases-builds/linux/bf32ae8b61ac8efeb7eca01b54c8307f992724f7/wasm-binaries.tar.xz',
    release: ['bf32ae8b61ac8efeb7eca01b54c8307f992724f7', '8c5f43157a3f069ade75876e23061330521eabde']},
];
const pinnedRowProblems = (task, tools, runs, pinned) => {
  const installer = readFileSync(`${CI_FILES}/ci-install-tools.sh`, 'utf8').trimEnd();
  const step = task.taskSpec.steps.find((s) => s.script.includes(runs)), problems = [];
  if (!step) return [`no step runs ${runs}`];
  const env = (name) => step.env?.find((e) => e.name === name)?.value;
  const tool = pinned.split(' ')[0];
  const rows = (env('CI_TOOLS_TABLE') ?? '').split('\n').filter((line) => line.startsWith(`${tool} `));
  if (rows.join('\n') !== pinned) problems.push(`${task.name} is handed ${rows.length ? rows.join(' and ') : `no ${tool} row`}, and not ${pinned}`);
  const handed = task.params?.find((p) => p.name === 'tools')?.value === tools && env('CI_TOOLS') === '$(params.tools)';
  if (!handed) problems.push(`${task.name} is not handed the tools of ci-tools.json from ${tools}`);
  const installerAt = step.script.indexOf(installer);
  if (installerAt < 0 || installerAt > step.script.indexOf(runs)) problems.push(`${task.name} runs ${runs} before files/ci-install-tools.sh`);
  return problems;
};

test('pack of the publish pipeline puts the pinned emcc 5.0.1 first on PATH before it builds', () => {
  const pack = renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish').spec.tasks.find((t) => t.name === 'pack');
  const holds = [[pack, '$(tasks.scan.results.tools)', 'build_packages /workspace/packed/publishable.tsv']];
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
      'the tools of ci-tools.json not handed over': (step, task) => { task.params = task.params.filter((p) => p.name !== 'tools'); },
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
// run_removal_test.dart, ansiwise-cli record_not_removed_test.dart) goes red. build-binaries of the publish pipeline runs
// those suites, through release/build.sh, which gates every part and the repository before it builds. What root did for
// them is done otherwise: the folders pods of root made are handed to that user by a step of root before it.
const CHECK_USER = 10042;
// What is wrong with the user `step` runs as, and with `handOver`, the step of root that hands it `folders` first.
const userProblems = (step, handOver, folders) => {
  const user = step.securityContext?.runAsUser;
  const problems = [];
  if (!(user > 0 && step.securityContext?.runAsNonRoot === true)) problems.push(`the ${step.name} step may run as root`);
  if (user !== CHECK_USER) problems.push(`the ${step.name} step runs as ${user}, not as the user of its image, ${CHECK_USER}`);
  if (!new RegExp(`^chown -R -h ${user} ${folders}$`, 'm').test(handOver?.script ?? '')) problems.push(`${folders} is not handed to ${user} before the ${step.name} step`);
  return problems;
};
test('build-binaries runs release/build.sh as the user of its image, after a step of root hands it the clone and the output', () => {
  const pipeline = renderUnit('shop', []).find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish');
  const problems = (p) => {
    const steps = p.spec.tasks.find((t) => t.name === 'build-binaries').taskSpec.steps;
    return userProblems(steps.find((s) => s.name === 'build'), steps[0], '/workspace/source /workspace/packed');
  };
  assert.deepEqual(problems(pipeline), [], 'PLANTED INNOCENT: the pipeline as rendered');
  const steps = (p) => p.spec.tasks.find((t) => t.name === 'build-binaries').taskSpec.steps;
  const planted = (change) => { const copy = structuredClone(pipeline); change(steps(copy), steps(copy).find((s) => s.name === 'build')); return problems(copy); };
  assert.ok(planted((all, build) => { build.securityContext = {runAsUser: 0, allowPrivilegeEscalation: false}; }).includes('the build step may run as root'),
    'PLANTED DEFECT: build-binaries as it ran before, uid 0, where record_not_removed_test.dart is red');
  assert.ok(planted((all, build) => { delete build.securityContext; }).includes('the build step may run as root'), 'PLANTED DEFECT: a build that leaves the user to the image');
  assert.ok(planted((all) => { all[0].script = all[0].script.replace(' /workspace/packed', ''); }).some((p) => p.includes('is not handed')),
    'PLANTED DEFECT: an output folder left to root, where release/build.sh cannot write the binaries');
  assert.ok(planted((all) => { all.reverse(); }).some((p) => p.includes('is not handed')), 'PLANTED DEFECT: the hand-over after the build');
  assert.ok(planted((all) => { all.shift(); }).some((p) => p.includes('is not handed')), 'PLANTED DEFECT: a clone nobody hands over');
});

// The scheduler admits a pod by its requests, and the kernel kills by QoS class when the node runs out of
// memory, so what bounds the damage to the platform pods is a sum of limits that stays within a budget
// (ciCapacity.limitsMemoryBudget).
// The sum is the pods that the queue's runs have alive at once. The queue runs one release or publish run per unit and
// releaseSlots runs in all (queueStartsOf below proves that on the queue's own decision), so the slots hold the
// releaseSlots largest distinct units, each the larger of its release run and its publish run. What a run has alive at
// once is the heaviest set of its tasks that none waits for another, read from the rendered runAfter, result and when
// references and the finally tasks (peakConcurrent), not every task of every stage. A unit builds the number of images
// that ciCapacity.releaseUnitImages declares for it.
// The same sum of CPU requests, with the requests of the pods that stand on the node on top, is held to the cores of
// the node by the test of the cores below.
const BYTES = {Gi: 1024 ** 3, Mi: 1024 ** 2};
const quantity = (text) => Number(text.slice(0, -2)) * BYTES[text.slice(-2)];
// The Task a pipeline task runs: its own spec, or the shared Task of image-builder that its cluster resolver names.
const sharedTaskName = (task) => task.taskRef.params?.find((param) => param.name === 'name')?.value ?? task.taskRef.name;
const podSteps = (task, shared) => {
  if (task.taskSpec) return task.taskSpec.steps;
  assert.ok(shared.has(sharedTaskName(task)), `${task.name} runs the shared Task ${sharedTaskName(task)}, which image-builder does not render`);
  return shared.get(sharedTaskName(task)).spec.steps;
};
// What a pod holds at once: the sum of its steps, as the budget has always counted them.
const podLimit = (task, shared) => podSteps(task, shared).reduce((sum, step) => sum + quantity(step.computeResources.limits.memory), 0);
// A CPU limit reserves nothing: the kernel only slows a pod that asks for more than its share, so the limits may add up
// to more than the node has, and one limit may not exceed it. What the scheduler holds to the cores is the requests.
const milliCores = (text) => (text.endsWith('m') ? Number(text.slice(0, -1)) : Number(text) * 1000);
const podRequest = (task, shared) => podSteps(task, shared).reduce((sum, step) => sum + milliCores(step.computeResources.requests.cpu), 0);
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
const fitsBudget = (capacity, shared, units, size = MEMORY) => largestQueued(capacity, units, (task) => size.pod(task, shared)) + size.standing(capacity) <= size.budget(capacity);
const readCiCapacity = () => ({...JSON.parse(execFileSync('yq', ['-o=json', '.ciCapacity', 'clusters/inventories/consumer-build/values-common.yaml'], {encoding: 'utf8'})),
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
// The releases of the declared units, and the shared Tasks of image-builder they run.
const releasePlane = (capacity) => ({units: releaseUnitsOf(capacity.releaseUnitImages),
  shared: new Map(imageBuilder().filter((d) => d.kind === 'Task').map((d) => [d.metadata.name, d]))});
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

test('the nine largest releases or publish runs fit the 31.5Gi memory budget, which stays within the memory of the node', () => {
  const capacity = readCiCapacity();
  assert.ok(declaresEveryCount(capacity.releaseUnitImages), 'every declared unit names how many images it builds');
  assert.equal(capacity.releaseUnitImages['digita-realtime'], 1, 'digita-realtime builds its one image after the scan');
  assert.ok(declaresEveryCount({...capacity.releaseUnitImages, 'digita-realtime': 1}), 'PLANTED INNOCENT: the row of digita-realtime with its count');
  assert.ok(!declaresEveryCount({...capacity.releaseUnitImages, 'digita-realtime': null}), 'PLANTED DEFECT: a row without its count is caught');
  const {shared, units} = releasePlane(capacity);
  const fits = (limit = capacity, releaseUnits = units) => fitsBudget(limit, shared, releaseUnits);
  const [{publish}] = units;
  assert.ok(units.every((unit) => unit.publish.spec.tasks.every((t, i) => i === 0 || t.runAfter?.length === 1 && t.runAfter[0] === unit.publish.spec.tasks[i - 1].name)), 'the budget counts one publish pod, so its tasks run one after the other');
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
  assert.equal(capacity.releaseBuildsAtOnce, 1, 'the owner decided on 2026-10-19 that a release builds one image at a time');
  assert.equal(capacity.releaseSlots, 9, 'the owner decided on 2026-10-19 that nine releases run at once');
  assert.ok(Object.keys(capacity.releaseUnitImages).length >= capacity.releaseSlots, 'the declared units fill every slot of the queue');
  assert.equal(quantity(capacity.limitsMemoryBudget) / BYTES.Gi, 31.5, 'the budget holds nine release slots at 3.5Gi');
  const withinNode = (limit) => quantity(limit.limitsMemoryBudget) <= quantity(limit.nodeMemory);
  assert.ok(withinNode(capacity), 'PLANTED INNOCENT: the budget stands within the allocatable memory of the node');
  assert.ok(!withinNode({...capacity, limitsMemoryBudget: `${quantity(capacity.nodeMemory) / BYTES.Mi + 1}Mi`}), 'PLANTED DEFECT: a budget one Mi above the allocatable memory of the node is caught');
  assert.ok(fits(), 'PLANTED INNOCENT: the nine largest releases exactly fit');
  assert.ok(!fits({...capacity, limitsMemoryBudget: '32255Mi'}), 'PLANTED DEFECT: one Mi below the exact 31.5Gi sum is caught');
  assert.ok(fits({...capacity, releaseSlots: 2}), 'PLANTED INNOCENT: two releases at a time fit too');
  assert.ok(!fits({...capacity, releaseSlots: capacity.releaseSlots + 1}), 'PLANTED DEFECT: a tenth release at once is caught');
  const largestName = largestUnit(units).name;
  const largestInParallel = withUnits(units, (unit) => {
    if (unit.name === largestName) unit.release.spec.tasks.find((t) => t.name === 'build-image-2').runAfter = ['scan'];
    return unit;
  });
  assert.ok(!fits(capacity, largestInParallel), `PLANTED DEFECT: the second build of ${largestName} waiting for the scan alone, two builds of 3072Mi in a slot of 3584Mi, is caught by the exact budget`);
  const heavy = withSharedTask(shared, 'buildah-build-push', (task) => { task.spec.steps.find((step) => step.name === 'build').computeResources.limits.memory = '8Gi'; });
  assert.ok(!fitsBudget(capacity, heavy, units), 'PLANTED DEFECT: a raised buildah limit is caught');
  const formerLimits = withSharedTask(shared, 'buildah-build-push', (task) => { task.spec.steps.find((step) => step.name === 'build').computeResources.limits.memory = '4Gi'; });
  assert.ok(!fitsBudget(capacity, formerLimits, units), 'PLANTED DEFECT: the former 4Gi build limit at nine releases is caught');
  const heavyPublish = structuredClone(publish);
  heavyPublish.spec.tasks.find((t) => t.name === 'pack').taskSpec.steps[0].computeResources.limits.memory = '19Gi';
  assert.ok(!fits(capacity, withUnits(units, (unit) => ({...unit, publish: heavyPublish}))), 'PLANTED DEFECT: a publish pod above a release slot is caught');
  const bigScan = withSharedTask(shared, 'credential-scan', (task) => { task.spec.steps[0].computeResources.limits.memory = '10Gi'; });
  assert.ok(!fitsBudget(capacity, bigScan, units), 'PLANTED DEFECT: a scan pod that runs beside the probes, and is none of the Buildah pods, is counted');
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
  const {shared} = releasePlane(readCiCapacity());
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

test('the nine largest releases or publish runs and the pods that stand on the build node fit its cores', () => {
  const capacity = readCiCapacity();
  const {shared, units} = releasePlane(capacity);
  const [{publish}] = units;
  const fits = (limit = capacity, tasks = shared, releaseUnits = units) => fitsBudget(limit, tasks, releaseUnits, CORES);
  assert.ok(fits(), 'PLANTED INNOCENT: nine releases beside the standing pods');
  assert.ok(fits({...capacity, releaseSlots: 2}), 'PLANTED INNOCENT: two releases at a time fit too');
  assert.ok(!fits({...capacity, standingCpuRequests: capacity.nodeCpu}), 'PLANTED DEFECT: standing requests that fill the node are caught');
  assert.ok(!fits({...capacity, nodeCpu: '8'}), 'PLANTED DEFECT: a build node of 8 cores is caught');
  const heavy = withSharedTask(shared, 'buildah-build-push', (task) => { task.spec.steps.find((step) => step.name === 'build').computeResources.requests.cpu = '4'; });
  assert.ok(!fits(capacity, heavy), 'PLANTED DEFECT: a buildah build step that requests 4 cores, nine at once, is caught');
  const heavyPublish = structuredClone(publish);
  heavyPublish.spec.tasks.find((t) => t.name === 'pack').taskSpec.steps[0].computeResources.requests.cpu = '8';
  assert.ok(!fits(capacity, shared, withUnits(units, (unit) => ({...unit, publish: heavyPublish}))), 'PLANTED DEFECT: a publish pod that requests 8 cores is caught');
});

// The pods the master cannot work without carry a CPU request, which scripts/check.sh holds for every render. What the
// budget of the cores counts of them is ciCapacity.standingCpuRequests: the 4530m the node held on 2026-10-15, before
// they had requests, their own requests, which this test reads from the
// values that carry them, Forgejo's among them, and the 400m of traefik that hostyour-deploy sets on the addon's DaemonSet. The 8 slave
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
  const forgejo = requestAt('clusters/inventories/forgejo/values-common.yaml', '.forgejo');
  const requests = master + SLAVE_INSTANCES * slave + certManager + identity + forgejo;
  const counted = (standing, extra = 0) => milliCores(standing) >= BASELINE_CPU + requests + extra + TRAEFIK_CPU;
  assert.ok(counted(capacity.standingCpuRequests), 'PLANTED INNOCENT: the budget counts the requests as they stand');
  assert.ok(!counted(capacity.standingCpuRequests, 1000), 'PLANTED DEFECT: a request raised by a core that the budget does not count is caught');
  assert.ok(!counted(capacity.standingCpuRequests, SLAVE_INSTANCES * 10), 'PLANTED DEFECT: 10m more on each of the slave instances is caught');
  assert.ok(!counted(`${BASELINE_CPU + requests}m`), 'PLANTED DEFECT: a budget that leaves out traefik, once its request is set, is caught');
  assert.ok(!counted(`${BASELINE_CPU + requests - forgejo + TRAEFIK_CPU}m`), 'PLANTED DEFECT: a budget that leaves out the Forgejo request is caught');
});

// The pods of the build node. The kubelet admits at most nodePods active pods (a finished pod does not count), and
// a Tekton task is one pod, so what counts is the pods a run has alive at once (peakConcurrent), not every task of
// every stage. The queue runs one run per unit and releaseSlots runs in all, so the slots hold the largest distinct
// units, each the larger of its release run and its publish run, beside the pods that stand there whatever the build
// plane does.
const podsOnNode = (capacity, units) => largestQueued(capacity, units, () => 1) + capacity.standingPods;

test('the pods of the nine largest releases or publish runs, with the pods that stand on the build node, stay below its pod limit', () => {
  const capacity = readCiCapacity();
  const {units} = releasePlane(capacity);
  const below = (counted) => counted < capacity.nodePods;
  for (const unit of units) {
    assert.equal(peakConcurrent(unit.release, () => 1), Math.max(unit.images + 1, 3), `${unit.name} has the scan and a probe per image alive at once, or verify, builds and scan, or its builds: the largest of them`);
  }
  const largest = largestUnit(units);
  assert.ok(below(podsOnNode(capacity, units)), 'PLANTED INNOCENT: nine slots as they stand, the units of 5 + 4 + 4 + 3 + 3 + 4 x 3 = 31 pods, 31 + 125 = 156 pods, stay below the limit');
  assert.ok(below(podsOnNode({...capacity, releaseSlots: 2}, units)), 'PLANTED INNOCENT: two releases at a time stay below it too');
  assert.ok(!below(podsOnNode({...capacity, releaseSlots: 40}, Array(40).fill(largest))), 'PLANTED DEFECT: forty slots of the largest unit, a total above 250, are caught');
  assert.ok(!below(podsOnNode({...capacity, standingPods: capacity.nodePods}, units)), 'PLANTED DEFECT: standing pods that fill the node are caught');
  const everyTask = capacity.releaseSlots * 3 * largest.release.spec.tasks.length + capacity.standingPods;
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

const PRIORITY_MESSAGE = "a managed run's podTemplate sets priorityClassName to the class of its pipeline and nothing else.";
const OVERRIDE_MESSAGE = 'per-task pod, step, sidecar, metadata and account overrides are not allowed.';

test('a run carries the release class and no other pod template field', () => {
  const policy = guardOf(imageBuilder());
  const verdict = (pipeline, podTemplate) => evaluate(policy, [createsRun('shop-build', pipeline, podTemplate)])[0].denied.sort();
  assert.deepEqual(verdict('shop-release', null), [], 'a release run without a pod template is admitted');
  for (const pipeline of ['shop-release', 'shop-image', 'shop-publish']) {
    assert.deepEqual(verdict(pipeline, {priorityClassName: RELEASE_CLASS}), [], `PLANTED INNOCENT: ${pipeline} with the release class`);
    assert.deepEqual(verdict(pipeline, {}), [PRIORITY_MESSAGE], `PLANTED DEFECT: ${pipeline} with an empty pod template`);
    assert.deepEqual(verdict(pipeline, {priorityClassName: 'system-cluster-critical'}), [PRIORITY_MESSAGE], `PLANTED DEFECT: ${pipeline} takes a system class`);
  }
  // Every other field Tekton's CRD knows for a pod template is refused beside the right class. The CRD
  // is the one the repository renders, so a Tekton upgrade that adds a field turns this red until the
  // policy lists it.
  const crd = renderChart('tekton').find((d) => d.kind === 'CustomResourceDefinition' && d.metadata.name === 'pipelineruns.tekton.dev');
  const fields = Object.keys(crd.spec.versions.find((v) => v.name === 'v1').schema.openAPIV3Schema.properties.spec.properties
    .taskRunTemplate.properties.podTemplate.properties).filter((field) => field !== 'priorityClassName');
  assert.ok(fields.includes('volumes') && fields.includes('automountServiceAccountToken') && fields.length > 10);
  for (const pipeline of ['shop-release', 'shop-image', 'shop-publish']) {
    for (const field of fields) {
      const value = {volumes: [], automountServiceAccountToken: true}[field] ?? 'x';
      assert.deepEqual(verdict(pipeline, {priorityClassName: RELEASE_CLASS, [field]: value}), [PRIORITY_MESSAGE],
        `PLANTED DEFECT: ${pipeline} sets ${field}`);
    }
  }
  // A per-task pod template cannot bring the token back either: no run carries per-task overrides.
  const perTask = (taskRunSpecs) => { const run = createsRun('shop-build', 'shop-release'); run.object.spec.taskRunSpecs = taskRunSpecs; return evaluate(policy, [run])[0].denied; };
  assert.deepEqual(perTask([]), [], 'PLANTED INNOCENT: an empty list of per-task overrides');
  assert.deepEqual(perTask([{pipelineTaskName: 'build', podTemplate: {automountServiceAccountToken: true}}]), [OVERRIDE_MESSAGE],
    'PLANTED DEFECT: a task asks for the token through taskRunSpecs');
  assert.deepEqual(perTask([{pipelineTaskName: 'report-failure', podTemplate: {priorityClassName: RELEASE_CLASS}}]), [OVERRIDE_MESSAGE],
    'PLANTED DEFECT: the one per-task class override the policy admitted before');
  const without = structuredClone(policy);
  without.spec.validations = without.spec.validations.filter((v) => v.message !== PRIORITY_MESSAGE);
  assert.deepEqual(evaluate(without, [createsRun('shop-build', 'shop-release', {priorityClassName: 'system-node-critical'}),
    createsRun('shop-build', 'shop-release', {priorityClassName: RELEASE_CLASS, volumes: []})]).map((v) => v.denied), [[], []], 'without the clause both are admitted');
});
test('the release class ranks above a pod without a class and preempts nothing, and a build namespace holds no quota', () => {
  const classes = imageBuilder().filter((d) => d.kind === 'PriorityClass');
  assert.deepEqual(classes.map((d) => d.metadata.name), [RELEASE_CLASS]);
  const [release] = classes;
  assert.equal(release.preemptionPolicy, 'Never', 'a release build must not evict a platform pod');
  assert.equal(release.globalDefault, false);
  assert.equal(release.metadata.annotations['argocd.argoproj.io/sync-wave'], '-1', 'the class exists before a run names it');
  assert.ok(release.value > 0, 'a release outranks a pod without a class');
  assert.deepEqual(renderUnit('shop').filter((d) => d.kind === 'ResourceQuota'), []);
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

test('no step of the publish pipeline or of the clone traces its commands', () => {
  const traces = (doc) => /\bset\s+-[A-Za-z]*x|xtrace|GIT_TRACE|GIT_CURL_VERBOSE/.test(JSON.stringify(doc).replaceAll('\\n', '\n'));
  const pipeline = renderUnit('shop').find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish');
  const clone = imageBuilder().find((d) => d.kind === 'Task' && d.metadata.name === 'git-clone');
  assert.ok(!traces(pipeline) && !traces(clone), 'PLANTED INNOCENT: the pipeline and the clone as rendered');
  for (const trace of ['set -eux', 'set -x', 'set -o xtrace', 'export GIT_TRACE=1', 'GIT_TRACE_CURL=1']) {
    const plantedPipeline = structuredClone(pipeline), plantedClone = structuredClone(clone);
    plantedPipeline.spec.tasks.find((t) => t.taskSpec).taskSpec.steps[0].script += `\n${trace}\n`;
    plantedClone.spec.steps[0].script += `\n${trace}\n`;
    assert.ok(traces(plantedPipeline) && traces(plantedClone), `PLANTED DEFECT: ${trace} would print the clone credential into the log of the run`);
  }
});

test('no install of the publish pipeline sets nodedir as an npm config, which npm 12 reports as an unknown config on every install', () => {
  // npm_config_nodedir and --nodedir are read by npm itself, and npm 12 warns "unknown nodedir" twice per
  // install; node-gyp takes the same headers from npm_package_config_node_gyp_nodedir, which npm does not read.
  const setsNodedir = (docs) => /npm_config_nodedir|--nodedir/i.test(JSON.stringify(docs).replaceAll('\\n', '\n'));
  const docs = renderUnit('shop');
  assert.ok(docs.some((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish'), 'the pipelines under check are rendered');
  assert.ok(!setsNodedir(docs), 'PLANTED INNOCENT: the pipelines as rendered select no headers through an npm config');
  const planted = (change) => { const copy = structuredClone(docs); change(copy.find((d) => d.kind === 'Pipeline' && d.metadata.name === 'shop-publish').spec.tasks.find((t) => t.name === 'pack').taskSpec.steps.find((s) => s.env?.some((e) => e.name === 'CI_TOOLS'))); return copy; };
  assert.ok(!setsNodedir(planted((step) => { step.env.push({name: 'npm_package_config_node_gyp_nodedir', value: '/usr/local'}); })),
    'PLANTED INNOCENT: node-gyp\'s own key selects the same headers and npm does not report it');
  assert.ok(setsNodedir(planted((step) => { step.env.push({name: 'npm_config_nodedir', value: '/usr/local'}); })), 'PLANTED DEFECT: npm_config_nodedir set as an env of pack');
  assert.ok(setsNodedir(planted((step) => { step.env.push({name: 'NPM_CONFIG_NODEDIR', value: '/usr/local'}); })), 'PLANTED DEFECT: the upper-case spelling npm reads as well');
  assert.ok(setsNodedir(planted((step) => { step.script += '\nexport npm_config_nodedir=/usr/local\n'; })), 'PLANTED DEFECT: npm_config_nodedir exported by the script');
  assert.ok(setsNodedir(planted((step) => { step.script += '\nnpm ci --nodedir=/usr/local\n'; })), 'PLANTED DEFECT: the nodedir flag of the install command');
});
