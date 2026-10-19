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

// The labels the tenants ApplicationSet stamps on a tenant namespace, and one the registration declares.
const TENANT = 'platform/tenant-managed';
const TENANT_LABELS = {'platform/tenant': 'aaaaaaaaaaaa', [TENANT]: 'true', 'platform/tenant-stage': 'prod', 'platform/db-consumer': 'true', 'platform/redis-consumer': 'true'};

const ADMITTED = {
  'the controller marks a platform namespace through managedNamespaceMetadata, which stamps no tracking id': asks('CREATE', workload('external-secrets')),
  'the same on a slave namespace of the master, beside an annotation of another kind': asks('CREATE', namespace('apps1', {labels: {[LABEL]: 'true'}, annotations: {note: 'x'}})),
  'a namespace with no label and no annotation': asks('CREATE', namespace('scratch')),
  'a namespace of an outside unit without the label': asks('CREATE', namespace('acme-build', {annotations: {[TRACKING_ID]: 'acme-build:/Namespace:acme-build/acme-build'}})),
  'a namespace of an outside unit with another platform label': asks('CREATE', namespace('acme-build', {labels: {'hostyour.cloud/build': 'true'}, annotations: {[TRACKING_ID]: 'acme-build:/Namespace:acme-build/acme-build'}})),
  'an update that takes the label off a namespace an outside Application tracks': asks('UPDATE', namespace('acme-build', {labels: {}, annotations: {[TRACKING_ID]: 'acme-build:/Namespace:acme-build/acme-build'}}),
    workload('acme-build', 'acme-build:/Namespace:acme-build/acme-build')),
  'a tenant namespace without the label: the four labels the tenants ApplicationSet stamps and one of the registration': asks('CREATE', namespace('aaaaaaaaaaaa-prod', {labels: TENANT_LABELS})),
  'an update that takes the label off a tenant namespace': asks('UPDATE', namespace('aaaaaaaaaaaa-prod', {labels: TENANT_LABELS}), namespace('aaaaaaaaaaaa-prod', {labels: {...TENANT_LABELS, [LABEL]: 'true'}})),
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
  'the tenants ApplicationSet writes the label beside its tenant marker, which stamps no tracking id': asks('CREATE', namespace('aaaaaaaaaaaa-prod', {labels: {...TENANT_LABELS, [LABEL]: 'true'}})),
  'the same with another value of the marker': asks('CREATE', namespace('aaaaaaaaaaaa-prod', {labels: {...TENANT_LABELS, [TENANT]: 'false', [LABEL]: 'true'}})),
  'an update that adds the label to a tenant namespace': asks('UPDATE', namespace('aaaaaaaaaaaa-prod', {labels: {...TENANT_LABELS, [LABEL]: 'true'}}), namespace('aaaaaaaaaaaa-prod', {labels: TENANT_LABELS})),
  'a platform owner\'s tracking id does not excuse the tenant marker': asks('CREATE', namespace('forgejo-build', {labels: {...TENANT_LABELS, [LABEL]: 'true'}, annotations: {[TRACKING_ID]: liveId('forgejo-build')}})),
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
// write carries no tracking id, so the tracking-id rule admits it. Two lines hold the label back: the template writes every key
// it copies so that it parses back to the string it compared, and the policy refuses the label on a namespace that carries the
// tenant marker the same write stamps.
const renderPatch = (namespaceLabels, template = patch) => {
  const [answer] = render(template, [paramSet('aaaaaaaaaaaa', 'prod', registration(['charts/app'], {namespaceLabels}))]);
  assert.equal(answer.error, undefined, answer.error);
  return yaml('.', answer.output);
};
const labelsOf = (application) => application.spec.syncPolicy.managedNamespaceMetadata.labels;

// Keys that are not the label as a string and parse back to it once a YAML parser has read them bare (review r21012).
const VARIANTS = {
  'a trailing blank': `${LABEL} `,
  'double quotes': `"${LABEL}"`,
  'single quotes': `'${LABEL}'`,
  'a newline that starts a further line of the patch': `injected: line\n        ${LABEL}`,
};
const bareKey = patch.replace('{{ $k | quote }}:', '{{ $k }}:');
const withoutTenantMarker = (policy) => {
  const variable = policy.spec.variables.find((v) => v.name === 'tenantManaged');
  assert.ok(variable, 'the policy reads the tenant marker in a variable of its own');
  variable.expression = 'false';
  return policy;
};

test('the tenants ApplicationSet leaves the label off the namespace of a tenant whose registration declares it', () => {
  const labels = labelsOf(renderPatch({[LABEL]: 'true', 'platform/redis-consumer': 'true'}));
  assert.equal(labels[LABEL], undefined);
  assert.deepEqual(labels, TENANT_LABELS,
    'a label of the registration that binds no Vault role stays, and so do the four the ApplicationSet stamps');
});

for (const [variant, key] of Object.entries(VARIANTS)) {
  test(`the tenants ApplicationSet writes a declared key as ${variant} exactly as declared: no label ${LABEL}, no further line in the patch`, () => {
    const baseline = renderPatch({'platform/redis-consumer': 'true'});
    const application = renderPatch({'platform/redis-consumer': 'true', [key]: 'true'});
    const labels = labelsOf(application);
    assert.equal(labels[LABEL], undefined);
    assert.equal(labels[key], 'true', 'the key parses back to the string that was compared, so Kubernetes refuses it as a label');
    delete labels[key];
    assert.deepEqual(application, baseline, 'nothing else of the Application differs: the key adds no line to the patch');
  });

  test(`the policy refuses the namespace that carries the label and the tenant marker, as the bare template wrote it for ${variant}`, () => {
    const leaked = labelsOf(renderPatch({[key]: 'true'}, bareKey));
    assert.equal(leaked[LABEL], 'true', 'precondition: the template with the key bare lets this variant through');
    const {policy} = guard();
    const [{message}] = policy.spec.validations;
    assert.deepEqual(evaluate(policy, [asks('CREATE', namespace('aaaaaaaaaaaa-prod', {labels: leaked}))]), [[message]]);
  });
}

test('planted defect: with the key written bare, every variant reaches the namespace as the label', () => {
  assert.notEqual(bareKey, patch);
  for (const [variant, key] of Object.entries(VARIANTS)) assert.equal(labelsOf(renderPatch({[key]: 'true'}, bareKey))[LABEL], 'true', variant);
});

test('planted defect: with the label let through, the namespace the tenants ApplicationSet writes claims it and the tracking-id rule admits that write', () => {
  const letThrough = patch.replace('and (ne $k "platform/tenant-stage") (ne $k "hostyour.cloud/workload")', 'ne $k "platform/tenant-stage"');
  assert.notEqual(letThrough, patch);
  const labels = labelsOf(renderPatch({[LABEL]: 'true'}, letThrough));
  assert.equal(labels[LABEL], 'true');
  const {policy} = guard();
  assert.deepEqual(evaluate(withoutTenantMarker(policy), [asks('CREATE', namespace('aaaaaaaaaaaa-prod', {labels}))]), [[]], 'no tracking id: without the tenant marker the policy cannot tell the write from a platform namespace');
});

test('planted defect: without the tenant marker, the policy admits the label on the namespace of every variant', () => {
  const {policy} = guard();
  const leaked = Object.values(VARIANTS).map((key) => labelsOf(renderPatch({[key]: 'true'}, bareKey)));
  const verdicts = evaluate(withoutTenantMarker(policy), leaked.map((labels) => asks('CREATE', namespace('aaaaaaaaaaaa-prod', {labels}))));
  assert.deepEqual(verdicts, leaked.map(() => []));
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
