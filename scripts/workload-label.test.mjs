import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {renderChart} from './render-chart.mjs';
import {paramSet, patch, registration, render, yaml} from './tenant-appset-fixture.mjs';

// The label hostyour.cloud/workload is the whole binding of the Vault role `external-secrets`, whose policy reads the
// storage box login that opens every backup. The admission policy `namespace-workload-label` of the external-secrets
// inventory lets a Namespace carry it only when no Application stamped it or when one of the platform's own
// namespace-rendering applications did. It is evaluated by scripts/vap-eval, which runs the CEL library the API server runs.

const LABEL = 'hostyour.cloud/workload';
const TRACKING_ID = 'argocd.argoproj.io/tracking-id';
const INVENTORIES = 'clusters/inventories';
const LABEL_KEY = /^[ \t]+hostyour\.cloud\/workload:/m;

const guard = (extra = []) => {
  const objects = renderChart('external-secrets', extra);
  const policy = objects.find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'namespace-workload-label');
  const binding = objects.find((d) => d.kind === 'ValidatingAdmissionPolicyBinding' && d.metadata.name === 'namespace-workload-label');
  assert.ok(policy && binding, 'the external-secrets inventory renders the policy namespace-workload-label and its binding');
  return {policy, binding};
};
const evaluate = (policy, requests) => execFileSync('go', ['run', '.'], {cwd: 'scripts/vap-eval', encoding: 'utf8',
  input: JSON.stringify({policy, requests})}).split('\n').filter(Boolean).map((line) => JSON.parse(line).denied);

const namespace = (name, {labels, annotations} = {}) => ({apiVersion: 'v1', kind: 'Namespace',
  metadata: {name, ...(labels && {labels}), ...(annotations && {annotations})}});
const workload = (name, trackingId) => namespace(name, {labels: {[LABEL]: 'true'}, ...(trackingId && {annotations: {[TRACKING_ID]: trackingId}})});
const asks = (operation, object, oldObject = null) => ({object, oldObject,
  request: {operation, resource: {resource: 'namespaces'}, userInfo: {username: 'system:serviceaccount:argocd:argocd-application-controller'}}});

// The tracking ids of the four namespaces that carry the label under an Application of their own, as the master and
// apps1 to apps8 hold them on 2026-10-19 (service-provisioner is the one that stands on a slave).
const OWNERS = ['e2e-runner', 'forgejo-build', 'gate-runner', 'service-provisioner'];
const liveId = (app) => `${app}-prod:/Namespace:${app}/${app}`;

const ADMITTED = {
  'the controller marks a platform namespace through managedNamespaceMetadata, which stamps no tracking id': asks('CREATE', workload('external-secrets')),
  'the same on a slave namespace of the master, beside an annotation of another kind': asks('CREATE', namespace('apps1', {labels: {[LABEL]: 'true'}, annotations: {note: 'x'}})),
  'a namespace with no label and no annotation': asks('CREATE', namespace('scratch')),
  'a namespace of an outside unit without the label': asks('CREATE', namespace('acme-build', {annotations: {[TRACKING_ID]: 'acme-build:/Namespace:acme-build/acme-build'}})),
  'a namespace of an outside unit with another platform label': asks('CREATE', namespace('acme-build', {labels: {'hostyour.cloud/build': 'true'}, annotations: {[TRACKING_ID]: 'acme-build:/Namespace:acme-build/acme-build'}})),
  'an update that takes the label off a namespace an outside Application tracks': asks('UPDATE', namespace('acme-build', {labels: {}, annotations: {[TRACKING_ID]: 'acme-build:/Namespace:acme-build/acme-build'}}),
    workload('acme-build', 'acme-build:/Namespace:acme-build/acme-build')),
  ...Object.fromEntries(OWNERS.flatMap((app) => [
    [`${app} creates its own namespace under its own Application`, asks('CREATE', workload(app, liveId(app)))],
    [`${app} syncs its own namespace again`, asks('UPDATE', workload(app, liveId(app)), workload(app, liveId(app)))],
  ])),
};
const DENIED = {
  'an outside unit marks its build namespace under its build fan-out Application': asks('CREATE', workload('acme-build', 'acme-build:/Namespace:acme-build/acme-build')),
  'an outside unit marks its delivery namespace under its delivery Application': asks('CREATE', workload('acme-prod', 'acme-prod:/Namespace:acme-prod/acme-prod')),
  'a tenant marks its namespace under its tenant Application': asks('CREATE', workload('abc123def456-prod', 'abc123def456-prod:/Namespace:abc123def456-prod/abc123def456-prod')),
  'another Application takes the name of a platform namespace': asks('CREATE', workload('forgejo-build', 'acme-build:/Namespace:forgejo-build/forgejo-build')),
  'another Application adds the label to an existing platform namespace': asks('UPDATE', workload('forgejo-build', 'acme-build:/Namespace:forgejo-build/forgejo-build'), workload('forgejo-build', liveId('forgejo-build'))),
  'an Application of another stage than the installation': asks('CREATE', workload('e2e-runner', 'e2e-runner-dev:/Namespace:e2e-runner/e2e-runner')),
  'an Application whose name only begins like a platform one': asks('CREATE', workload('e2e-runner', 'e2e-runner-prod-x:/Namespace:e2e-runner/e2e-runner')),
  'a platform Application on an object it does not own': asks('CREATE', workload('acme-build', 'e2e-runner-prod:/Namespace:e2e-runner/e2e-runner-x')),
};

test('the policy namespace-workload-label stands on every namespace write and refuses in the validation, not in a match', () => {
  const {policy, binding} = guard();
  assert.equal(policy.spec.failurePolicy, 'Fail');
  assert.deepEqual(policy.spec.matchConstraints.resourceRules, [{apiGroups: [''], apiVersions: ['v1'], operations: ['CREATE', 'UPDATE'], resources: ['namespaces']}]);
  assert.equal(policy.spec.matchConstraints.namespaceSelector, undefined);
  assert.equal(policy.spec.matchConditions, undefined, 'a matchCondition is not evaluated by scripts/vap-eval, so the policy it checks would not be the policy that ships');
  assert.equal(policy.spec.validations.length, 1);
  assert.equal(binding.spec.policyName, policy.metadata.name);
  assert.deepEqual(binding.spec.validationActions, ['Deny']);
  assert.equal(binding.spec.matchResources, undefined);
  assert.equal(binding.spec.paramRef, undefined);
});

test('the policy lets the label stand on a namespace no Application stamped and on the four that own it, and on no other', () => {
  const {policy} = guard();
  const [{message}] = policy.spec.validations;
  assert.match(message, new RegExp(LABEL));
  const names = [...Object.keys(ADMITTED), ...Object.keys(DENIED)];
  const verdicts = evaluate(policy, [...Object.values(ADMITTED), ...Object.values(DENIED)]);
  assert.equal(verdicts.length, names.length);
  names.forEach((name, i) => assert.deepEqual(verdicts[i], i < Object.keys(ADMITTED).length ? [] : [message], name));
});

test('the admitted tracking ids follow the stage of the installation', () => {
  const {policy} = guard(['--set', 'global.env=test']);
  const verdicts = evaluate(policy, OWNERS.flatMap((app) => [asks('CREATE', workload(app, liveId(app))), asks('CREATE', workload(app, `${app}-test:/Namespace:${app}/${app}`))]));
  OWNERS.forEach((app, i) => {
    assert.equal(verdicts[2 * i].length, 1, `${app} of the prod stage is refused on a test installation`);
    assert.deepEqual(verdicts[2 * i + 1], [], `${app} of the test stage is admitted on a test installation`);
  });
});

// The tenants ApplicationSet is the one writer that copies namespace labels from data an outside party declares: the registration of
// a tenant stands in the product's deploy repository, and its `namespaceLabels` ride onto the namespace Argo CD creates. That
// write carries no tracking id, so the policy admits it and only the ApplicationSet can leave the label out.
const tenantNamespaceLabels = (namespaceLabels, template = patch) => {
  const [answer] = render(template, [paramSet('aaaaaaaaaaaa', 'prod', registration(['charts/app'], {namespaceLabels}))]);
  assert.equal(answer.error, undefined, answer.error);
  return yaml('.spec.syncPolicy.managedNamespaceMetadata.labels', answer.output);
};

test('the tenants ApplicationSet leaves the label off the namespace of a tenant whose registration declares it', () => {
  const labels = tenantNamespaceLabels({[LABEL]: 'true', 'platform/redis-consumer': 'true'});
  assert.equal(labels[LABEL], undefined);
  assert.equal(labels['platform/redis-consumer'], 'true', 'a label of the registration that binds no Vault role stays');
  assert.equal(labels['platform/tenant-managed'], 'true');
});

test('planted defect: with the label let through, the namespace the tenants ApplicationSet writes claims it and the policy admits that write', () => {
  const letThrough = patch.replace('and (ne $k "platform/tenant-stage") (ne $k "hostyour.cloud/workload")', 'ne $k "platform/tenant-stage"');
  assert.notEqual(letThrough, patch);
  const labels = tenantNamespaceLabels({[LABEL]: 'true'}, letThrough);
  assert.equal(labels[LABEL], 'true');
  const {policy} = guard();
  assert.deepEqual(evaluate(policy, [asks('CREATE', namespace('aaaaaaaaaaaa-prod', {labels}))]), [[]], 'no tracking id: the policy cannot tell the write from a platform namespace');
});

test('planted defect: without the validation, every namespace the platform does not own keeps the label', () => {
  const {policy} = guard();
  policy.spec.validations = [];
  assert.ok(evaluate(policy, Object.values(DENIED)).every((denied) => denied.length === 0));
});

test('planted defect: with no application on the list, the four owners are refused', () => {
  const {policy} = guard(['--set-json', 'workloadNamespaceApplications=[]']);
  assert.ok(evaluate(policy, OWNERS.map((app) => asks('CREATE', workload(app, liveId(app))))).every((denied) => denied.length === 1));
});

// The inventories whose templates render a Namespace of their own that carries the label, found as text: a document that
// begins a line with `kind: Namespace` and carries the label as a key. A comment that names the label is not one.
function workloadNamespaceInventories(root) {
  const found = new Set();
  for (const inventory of readdirSync(root)) {
    const templates = join(root, inventory, 'templates');
    let entries;
    try {
      entries = readdirSync(templates, {recursive: true, withFileTypes: true});
    } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    for (const entry of entries.filter((e) => e.isFile())) {
      const documents = readFileSync(join(entry.parentPath, entry.name), 'utf8').split(/^---\s*$/m);
      if (documents.some((d) => /^kind: Namespace\s*$/m.test(d) && LABEL_KEY.test(d))) found.add(inventory);
    }
  }
  return [...found].sort();
}

test('the applications the policy admits are the inventories that render a labelled namespace of their own', () => {
  const listed = JSON.parse(execFileSync('yq', ['-o=json', '.workloadNamespaceApplications', `${INVENTORIES}/external-secrets/values-common.yaml`], {encoding: 'utf8'}));
  assert.deepEqual([...listed].sort(), workloadNamespaceInventories(INVENTORIES));
  assert.deepEqual([...listed].sort(), [...OWNERS].sort());
});

test('the sweep finds a planted template that renders a labelled namespace and passes the planted innocents', () => {
  const root = mkdtempSync(join(tmpdir(), 'workload-label-'));
  try {
    const put = (inventory, file, text) => {
      mkdirSync(join(root, inventory, 'templates'), {recursive: true});
      writeFileSync(join(root, inventory, 'templates', file), text);
    };
    put('planted', 'namespace.yaml', `apiVersion: v1\nkind: Namespace\nmetadata:\n  name: planted\n  labels:\n    ${LABEL}: "true"\n`);
    put('planted-second-document', 'objects.yaml', `kind: ConfigMap\n---\nkind: Namespace\nmetadata:\n  labels:\n    ${LABEL}: "true"\n`);
    put('innocent-comment', 'namespace.yaml', `{{- /*\n\n${LABEL}: the label every platform namespace carries.\n*/ -}}\n# ${LABEL}: "true"\nkind: Namespace\nmetadata:\n  name: x\n`);
    put('innocent-other-kind', 'deployment.yaml', `kind: Namespace\nmetadata:\n  name: x\n---\nkind: Deployment\nmetadata:\n  labels:\n    ${LABEL}: "true"\n`);
    put('innocent-label-only', 'pod.yaml', `kind: Pod\nmetadata:\n  labels:\n    ${LABEL}: "true"\n`);
    mkdirSync(join(root, 'innocent-no-templates'));
    assert.deepEqual(workloadNamespaceInventories(root), ['planted', 'planted-second-document']);
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});
