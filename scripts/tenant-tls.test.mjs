import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {appset, paramSet, render, yaml} from './tenant-appset-fixture.mjs';

const file = 'clusters/argocd/files/tenant-tls-appset.yaml';
const chart = 'clusters/units/tenant-tls';
const guid = 'aaaaaaaaaaaa';
const names = ['workshop-tls', 'auth-tls'];
const subject = [{kind: 'ServiceAccount', name: 'manager', namespace: 'manager'}];
const documents = input => JSON.parse(execFileSync('yq', ['eval-all', '-o=json', '[.]', '-'], {input, encoding: 'utf8'})).filter(Boolean);
const preparation = stage => ({...paramSet(guid, stage, {cluster: 'apps1', secretNames: names,
  namespaceLabels: {'platform/redis-consumer': 'true'}}),
  path: {path: `registrations/${guid}`, basename: guid, filename: `tls-${stage}.yaml`, segments: ['registrations', guid]}});
const tlsSet = () => yaml('.spec', readFileSync(file, 'utf8'));
const application = (params, set = tlsSet()) => {
  const [typed, patched] = [set.template, set.templatePatch].map(value => {
    const text = (typeof value === 'string' ? value : JSON.stringify(value)).replaceAll('__CLUSTER_NAME__', 'apps1');
    const [got] = render(text, [params]);
    assert.equal(got.error, undefined, got.error);
    return yaml('.', got.output);
  });
  return {...typed, spec: {...typed.spec, ...patched.spec,
    syncPolicy: {...typed.spec.syncPolicy, ...patched.spec.syncPolicy}}};
};
const manifests = (secretNames, extra = {}, stage = 'prod') => documents(execFileSync('helm',
  ['template', 'tenant-tls', chart, '--namespace', `${guid}-${stage}`, '--set-json',
    `secretNames=${JSON.stringify(secretNames)}`, ...Object.entries(extra).flatMap(([key, value]) =>
      ['--set-json', `${key}=${JSON.stringify(value)}`])], {encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe']}));
const checkGrant = (docs, expected, stage = 'prod') => {
  assert.deepEqual(docs.map(doc => doc.kind).sort(), ['Role', 'RoleBinding']);
  const role = docs.find(doc => doc.kind === 'Role');
  const binding = docs.find(doc => doc.kind === 'RoleBinding');
  for (const doc of docs) assert.equal(doc.metadata.namespace, `${guid}-${stage}`);
  assert.equal(role.metadata.name, 'tenant-tls');
  assert.deepEqual(role.rules, expected.length ? [{apiGroups: [''], resources: ['secrets'],
    verbs: ['get'], resourceNames: expected}] : []);
  assert.deepEqual(binding.roleRef, {apiGroup: 'rbac.authorization.k8s.io', kind: 'Role', name: 'tenant-tls'});
  assert.deepEqual(binding.subjects, subject);
};
const checkApplication = (got, stage) => {
  assert.equal(got.metadata.name, `tenant-tls-${guid}-${stage}`);
  assert.equal(got.spec.project, got.metadata.name);
  assert.deepEqual(got.spec.destination, {name: 'apps1', namespace: `${guid}-${stage}`});
  assert.deepEqual(got.spec.sources, [{repoURL: 'https://github.com/simetrixch/hostyour-cloud.git',
    targetRevision: '__BRANCH__', path: chart, helm: {valuesObject: {secretNames: names}}}]);
  assert.deepEqual(got.spec.syncPolicy.managedNamespaceMetadata.labels, {'platform/tenant': guid,
    'platform/tenant-managed': 'true', 'platform/tenant-stage': stage, 'platform/db-consumer': 'true',
    'platform/redis-consumer': 'true'});
  assert.ok(got.spec.syncPolicy.syncOptions.includes('CreateNamespace=true'));
};

test('TLS preparation uses the books selector, exact filenames and path identity at every stage', () => {
  const set = tlsSet();
  const [generator] = set.generators;
  assert.equal(generator.git.repoURL, appset.generators[0].git.repoURL);
  assert.equal(generator.git.revision, appset.generators[0].git.revision);
  assert.deepEqual(generator.selector, appset.generators[0].selector);
  assert.deepEqual(generator.git.files, ['dev', 'test', 'prod'].map(stage => ({path: `registrations/*/tls-${stage}.yaml`})));
  for (const stage of ['dev', 'test', 'prod']) {
    const params = preparation(stage);
    for (const [key, value] of Object.entries(generator.git.values)) {
      const [got] = render(value, [params]);
      assert.equal(got.error, undefined); assert.equal(got.output, params.values[key]);
    }
    checkApplication(application(params), stage);
  }
  const emitted = execFileSync('helm', ['template', 'argocd-apps', 'clusters/argocd',
    '-f', 'scripts/standin/cluster-map.yaml', '--set', 'revision=approved-commit'], {encoding: 'utf8'});
  const shipped = yaml('select(.kind == "ApplicationSet" and .metadata.name == "tenant-tls")', emitted);
  assert.equal(shipped.spec.generators[0].git.revision, yaml('.global.booksCluster', readFileSync('scripts/standin/cluster-map.yaml', 'utf8')));
  assert.equal(shipped.spec.templatePatch.includes('targetRevision: approved-commit'), true);
});

test('named GET and an empty-name preparation render only local Role/RoleBinding, never a Namespace', () => {
  for (const stage of ['dev', 'test', 'prod']) {
    checkGrant(manifests(names, {}, stage), names, stage);
    checkGrant(manifests([], {}, stage), [], stage);
  }
  assert.deepEqual(application({...preparation('prod'), secretNames: []}).spec.sources[0].helm.valuesObject, {secretNames: []});
});

test('planted excessive verbs, general reads, foreign subjects and escaping grants make the check red', () => {
  const docs = manifests(names);
  const changes = [rule => {rule.verbs.push('list');}, rule => {rule.verbs.push('watch');},
    rule => {rule.resourceNames = ['*'];}, rule => {rule.resourceNames = [];},
    rule => {delete rule.resourceNames;}, rule => {rule.resources.push('certificates');}];
  for (const change of changes) {
    const planted = structuredClone(docs); change(planted.find(doc => doc.kind === 'Role').rules[0]);
    assert.throws(() => checkGrant(planted, names));
  }
  for (const change of [doc => {doc.subjects[0].namespace = 'foreign';},
    doc => {doc.subjects.push({kind: 'Group', name: 'system:authenticated'});},
    doc => {doc.roleRef.kind = 'ClusterRole';}, doc => {doc.metadata.namespace = 'foreign';}]) {
    const planted = structuredClone(docs); change(planted.find(doc => doc.kind === 'RoleBinding'));
    assert.throws(() => checkGrant(planted, names));
  }
});

test('the chart refuses wildcard, empty and malformed names and caller-supplied grant controls', () => {
  checkGrant(manifests(names), names);
  for (const bad of [['*'], [''], ['Bad_Name'], ['valid', '*'], ['a'.repeat(254)], [3], 'all', null]) assert.throws(() => manifests(bad));
  for (const key of ['subjects', 'rules', 'sources']) assert.throws(() => manifests(names, {[key]: []}));
});

test('preparation refuses wrong path identity, reserved labels and product/grant inputs', () => {
  const params = preparation('prod');
  for (const patch of [{values: {guid: '../foreign', stage: 'prod'}}, {values: {guid: 'bbbbbbbbbbbb', stage: 'prod'}},
    {values: {guid, stage: 'foreign'}}, {values: {guid, stage: 'test'}},
    {cluster: 'apps2'}, {sources: [{chart: 'charts/app'}]}, {subjects: subject}, {rules: []}, {guid: 'foreign'}, {stage: 'test'}]) {
    assert.throws(() => application({...params, ...patch}));
  }
  for (const key of ['platform/tenant', 'platform/tenant-managed', 'platform/tenant-stage', 'platform/db-consumer']) {
    assert.throws(() => application({...params, namespaceLabels: {[key]: 'foreign'}}));
  }
  for (const [key, value] of Object.entries({'hostyour.cloud/workload': 'true', 'hostyour.cloud/build': 'true',
    'hostyour.cloud/consumer': 'true', 'pod-security.kubernetes.io/enforce': 'privileged',
    'pod-security.kubernetes.io/audit': 'privileged', 'pod-security.kubernetes.io/warn': 'privileged',
    'platform/unapproved': 'true', 'platform/redis-consumer': 'false'})) {
    assert.throws(() => application({...params, namespaceLabels: {...params.namespaceLabels, [key]: value}}), undefined, key);
  }
  for (const prefix of ['hostyour.cloud/', 'platform/', 'pod-security.kubernetes.io/']) {
    assert.throws(() => application({...params, namespaceLabels: {[`${prefix}unapproved`]: ''}}), undefined, prefix);
  }
  const labels = application(params).spec.syncPolicy.managedNamespaceMetadata.labels;
  assert.deepEqual(application({...params, namespaceLabels: labels}).spec.syncPolicy.managedNamespaceMetadata.labels, labels);
  assert.deepEqual(application({...params, namespaceLabels: {...params.namespaceLabels, 'product.example/team': 'shop'}})
    .spec.syncPolicy.managedNamespaceMetadata.labels, {...labels, 'product.example/team': 'shop'});
  assert.equal(application({...params, namespaceLabels: {}}).spec.syncPolicy.managedNamespaceMetadata.labels['platform/redis-consumer'], undefined);
  const innocent = application(params);
  for (const mutate of [got => {got.spec.sources[0].repoURL = 'https://github.com/product/product.git';},
    got => {got.spec.destination.name = 'foreign';}, got => {got.spec.destination.namespace = '*';},
    got => {got.spec.syncPolicy.managedNamespaceMetadata.labels['platform/tenant'] = 'foreign';}]) {
    const planted = structuredClone(innocent); mutate(planted);
    assert.throws(() => checkApplication(planted, 'prod'));
  }
  checkApplication(innocent, 'prod');
});

test('Certificate discovery grants only public-object GET/LIST and no Secret rule', () => {
  const rendered = execFileSync('helm', ['template', 'manager', 'clusters/inventories/manager', '--namespace', 'manager',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
    '-f', 'clusters/inventories/manager/values-common.yaml', '-f', 'clusters/inventories/manager/values-prod.yaml',
    '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml'], {encoding: 'utf8'});
  const docs = documents(rendered);
  const role = docs.find(doc => doc?.kind === 'ClusterRole' && doc.metadata.name === 'manager-tenant-certificates-reader');
  assert.ok(role);
  const check = rules => assert.deepEqual(rules, [{apiGroups: ['cert-manager.io'], resources: ['certificates'], verbs: ['get', 'list']}]);
  check(role.rules);
  const binding = docs.find(doc => doc?.kind === 'ClusterRoleBinding' && doc.metadata.name === role.metadata.name);
  assert.deepEqual(binding.subjects, subject);
  assert.deepEqual(binding.roleRef, {apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name: role.metadata.name});
  for (const resources of [['certificates', 'secrets'], ['*']]) assert.throws(() => check([{...role.rules[0], resources}]));
});
