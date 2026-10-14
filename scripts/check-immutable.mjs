// Compare immutable fields by Kubernetes identity, including ESO's generated Secret.
import {readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]));
  return value;
}
function fields(object) {
  const spec = object.spec ?? {};
  switch (object.kind) {
    case 'Secret': return {type: object.type ?? 'Opaque'};
    case 'PersistentVolumeClaim': return {storageClassName: spec.storageClassName ?? null,
      accessModes: [...(spec.accessModes ?? [])].sort(), volumeMode: spec.volumeMode ?? 'Filesystem', selector: spec.selector ?? null};
    case 'RoleBinding': case 'ClusterRoleBinding': return {roleRef: object.roleRef};
    case 'Deployment': case 'DaemonSet': return {selector: spec.selector};
    case 'StatefulSet': return {selector: spec.selector, serviceName: spec.serviceName,
      volumeClaimTemplates: spec.volumeClaimTemplates ?? []};
    case 'Job': return {template: spec.template};
    default: return {};
  }
}
const groupOf = apiVersion => apiVersion.includes('/') ? apiVersion.split('/')[0] : '';
// Argo CD keeps a field its Application ignores at the live value only under RespectIgnoreDifferences;
// without it a sync applies the rendered field and the API server refuses the change, so only then is
// the field left out of the comparison. A rule may take out one annotation or one label and nothing
// else, so no rule can take out a field the check compares; a rule the check cannot read the way Argo
// CD does is refused, never skipped.
const IGNORABLE = [['spec', 'template', 'metadata', 'annotations'], ['spec', 'template', 'metadata', 'labels'],
  ['metadata', 'annotations'], ['metadata', 'labels']];
const pointerSteps = pointer => pointer.startsWith('/') ? pointer.split('/').slice(1).map(step => step.replaceAll('~1', '/').replaceAll('~0', '~')) : null;
const jqSteps = expression => /^(\.[A-Za-z_]\w*)+$/.test(expression) ? expression.slice(1).split('.') : null;
export function ignoredFields(app = {}) {
  if (app.respectIgnoreDifferences !== 'true' || app.ignoreDifferences === undefined) return [];
  const where = `the app.yaml named ${app.name}`;
  if (!Array.isArray(app.ignoreDifferences)) throw new Error(`${where}: ignoreDifferences is not a list`);
  return app.ignoreDifferences.map(rule => {
    const refuse = why => { throw new Error(`${where}: ignoreDifferences rule ${JSON.stringify(rule)} ${why}`); };
    if (rule?.managedFieldsManagers !== undefined) refuse('names managedFieldsManagers, which no render shows');
    if (!rule?.kind) refuse('names no kind');
    if (/[*?[]/.test(`${rule.group ?? ''}${rule.kind}`)) refuse('matches its group or kind by a glob');
    if (![rule.jsonPointers ?? [], rule.jqPathExpressions ?? []].every(Array.isArray)) refuse('lists its paths not as a list');
    const paths = [...(rule.jsonPointers ?? []).map(path => [path, pointerSteps(path)]),
      ...(rule.jqPathExpressions ?? []).map(path => [path, jqSteps(path)])];
    for (const [path, steps] of paths) {
      if (!steps) refuse(`has ${path}, which the check cannot read (a jsonPointer from /, a jq path of .key steps)`);
      if (steps.at(-1) === '-') refuse(`has ${path}, which ends in an array position`);
      if (!IGNORABLE.some(prefix => steps.length > prefix.length && prefix.every((step, i) => steps[i] === step))) {
        refuse(`has ${path}, which is not one annotation or label, the only fields the immutable check lets a rule take out`);
      }
    }
    return {...rule, paths: paths.map(([, steps]) => steps)};
  });
}
function withoutIgnored(object, namespace, ignored) {
  const rules = ignored.filter(rule => (rule.group ?? '') === groupOf(object.apiVersion) && rule.kind === object.kind &&
    (!rule.name || rule.name === object.metadata.name) && (!rule.namespace || rule.namespace === (object.metadata.namespace ?? namespace)));
  if (!rules.length) return object;
  const copy = structuredClone(object);
  for (const steps of rules.flatMap(rule => rule.paths)) {
    const parent = steps.slice(0, -1).reduce((node, step) => node?.[step], copy);
    if (parent && typeof parent === 'object') delete parent[steps.at(-1)];
  }
  return copy;
}
function identities(documents, namespace, ignored) {
  const result = new Map();
  for (const rendered of documents.filter(Boolean)) {
    const object = withoutIgnored(rendered, namespace, ignored);
    const objects = [object];
    if (object.kind === 'ExternalSecret') objects.push({apiVersion: 'v1', kind: 'Secret',
      metadata: {namespace: object.metadata.namespace, name: object.spec.target?.name ?? object.metadata.name},
      type: object.spec.target?.template?.type ?? 'Opaque'});
    for (const item of objects) {
      const group = groupOf(item.apiVersion);
      const scope = ['ClusterRoleBinding'].includes(item.kind) ? '' : (item.metadata.namespace ?? namespace);
      const key = [group, item.kind, scope, item.metadata.name].join('/');
      const value = fields(item);
      const annotations = item.metadata.annotations ?? {};
      const recreated = item.kind === 'Job' && Boolean(annotations['argocd.argoproj.io/hook']) &&
        (annotations['argocd.argoproj.io/hook-delete-policy'] ?? '').split(',').map(p => p.trim()).includes('BeforeHookCreation');
      if (Object.keys(value).length) result.set(key, {fields: value, recreated});
    }
  }
  return result;
}
export function immutableChanges(before, after, namespace = 'default', ignored = []) {
  const old = identities(before, namespace, ignored), findings = [];
  for (const [identity, candidate] of identities(after, namespace, ignored)) {
    if (!old.has(identity)) continue;
    const previous = old.get(identity);
    if (previous.recreated && candidate.recreated) continue;
    for (const [field, value] of Object.entries(candidate.fields)) {
      if (JSON.stringify(canonical(previous.fields[field])) !== JSON.stringify(canonical(value))) findings.push(`${identity}: ${field} changed`);
    }
  }
  return findings;
}
export function probeImmutableChanges() {
  const secret = {apiVersion: 'v1', kind: 'Secret', metadata: {name: 'pull'}, type: 'Opaque'};
  const changed = {...secret, type: 'kubernetes.io/dockerconfigjson'};
  assert.equal(immutableChanges([secret], [changed]).length, 1);
  assert.deepEqual(immutableChanges([secret], [{...changed, metadata: {name: 'pull-dockerconfigjson'}}]), []);
  assert.deepEqual(immutableChanges([secret], [{...secret, data: {fake: 'innocent'}}]), []);
  const eso = {apiVersion: 'external-secrets.io/v1', kind: 'ExternalSecret', metadata: {name: 'reader'}, spec: {target: {name: 'pull'}}};
  assert.equal(immutableChanges([eso], [{...eso, spec: {target: {name: 'pull', template: {type: changed.type}}}}]).length, 1);
  assert.deepEqual(immutableChanges([eso], [{...eso, spec: {target: {name: 'new-pull', template: {type: changed.type}}}}]), []);
  const binding = {apiVersion: 'rbac.authorization.k8s.io/v1', kind: 'RoleBinding', metadata: {name: 'reader'}, roleRef: {kind: 'Role', name: 'before'}};
  assert.equal(immutableChanges([binding], [{...binding, roleRef: {...binding.roleRef, name: 'after'}}]).length, 1);
  const pvc = {apiVersion: 'v1', kind: 'PersistentVolumeClaim', metadata: {name: 'data'}, spec: {accessModes: ['ReadWriteOnce']}};
  assert.equal(immutableChanges([pvc], [{...pvc, spec: {accessModes: ['ReadWriteMany']}}]).length, 1);
  assert.deepEqual(immutableChanges([pvc], [{...pvc, spec: {...pvc.spec, volumeMode: 'Filesystem', resources: {requests: {storage: '2Gi'}}}}]), []);
  const job = {apiVersion: 'batch/v1', kind: 'Job', metadata: {name: 'init'}, spec: {template: {spec: {containers: [{name: 'init', image: 'before'}]}}}};
  const changedJob = structuredClone(job); changedJob.spec.template.spec.containers[0].image = 'after';
  assert.equal(immutableChanges([job], [changedJob]).length, 1);
  const annotations = {'argocd.argoproj.io/hook': 'Sync', 'argocd.argoproj.io/hook-delete-policy': 'BeforeHookCreation,HookSucceeded'};
  const hook = {...job, metadata: {...job.metadata, annotations}};
  const changedHook = {...changedJob, metadata: {...changedJob.metadata, annotations}};
  assert.deepEqual(immutableChanges([hook], [changedHook]), []);
  assert.equal(immutableChanges([hook], [changedJob]).length, 1);
  // plane-ce stamps a new timestamp into its migration Job's pod template on every render, and plane's
  // app.yaml has Argo CD keep the live one.
  const plane = {name: 'plane', respectIgnoreDifferences: 'true', ignoreDifferences: [
    {group: 'apps', kind: 'Deployment', jsonPointers: ['/spec/template/metadata/annotations/timestamp']},
    {group: 'batch', kind: 'Job', jsonPointers: ['/spec/template/metadata/annotations/timestamp']}]};
  const stamped = structuredClone(job); stamped.spec.template.metadata = {annotations: {timestamp: 'before'}};
  const restamped = structuredClone(stamped); restamped.spec.template.metadata.annotations.timestamp = 'after';
  const restampedImage = structuredClone(restamped); restampedImage.spec.template.spec.containers[0].image = 'after';
  assert.deepEqual(immutableChanges([stamped], [restamped], 'default', ignoredFields(plane)), []);
  assert.equal(immutableChanges([stamped], [restampedImage], 'default', ignoredFields(plane)).length, 1);
  assert.equal(immutableChanges([stamped], [restamped]).length, 1);
  assert.equal(immutableChanges([stamped], [restamped], 'default', ignoredFields({...plane, respectIgnoreDifferences: undefined})).length, 1);
  const otherJob = {...plane, ignoreDifferences: plane.ignoreDifferences.map(rule => ({...rule, name: 'other'}))};
  assert.equal(immutableChanges([stamped], [restamped], 'default', ignoredFields(otherJob)).length, 1);
  const refused = (rule, why) => assert.throws(() => ignoredFields({...plane, ignoreDifferences: [rule]}), why);
  const jobs = {group: 'batch', kind: 'Job'}, timestamp = ['/spec/template/metadata/annotations/timestamp'];
  const outside = /not one annotation or label/;
  for (const jsonPointers of [['/spec/template'], ['/spec'], ['/kind'], ['/apiVersion'], ['/metadata'], ['/spec/template/metadata'],
    ['/spec/template/metadata/annotations'], ['/spec/template/spec/containers/image'], ['/spec/template/spec/containers/0/image']]) refused({...jobs, jsonPointers}, outside);
  refused({group: 'apps', kind: 'Deployment', jsonPointers: ['/spec/selector']}, outside);
  refused({...jobs, jqPathExpressions: ['.spec.template']}, outside);
  refused({...jobs, jqPathExpressions: ['.spec.template.spec.containers[]?.image']}, /cannot read/);
  refused({...jobs, jqPathExpressions: ['.spec.template | .metadata.annotations.timestamp']}, /cannot read/);
  refused({...jobs, jsonPointers: ['spec/template/metadata/annotations/timestamp']}, /cannot read/);
  refused({...jobs, jsonPointers: ['/metadata/annotations/-']}, /array position/);
  refused({...jobs, managedFieldsManagers: ['kube-controller-manager']}, /managedFieldsManagers/);
  refused({group: 'batch', jsonPointers: timestamp}, /no kind/);
  refused({group: 'batch', kind: '*', jsonPointers: timestamp}, /glob/);
  refused({group: '*', kind: 'Job', jsonPointers: timestamp}, /glob/);
  refused({...jobs, jsonPointers: timestamp[0]}, /not as a list/);
  assert.throws(() => ignoredFields({...plane, ignoreDifferences: plane.ignoreDifferences[1]}), /ignoreDifferences is not a list/);
  const byJq = {...plane, ignoreDifferences: [{...jobs, jqPathExpressions: ['.spec.template.metadata.annotations.timestamp']}]};
  assert.deepEqual(immutableChanges([stamped], [restamped], 'default', ignoredFields(byJq)), []);
  assert.equal(immutableChanges([stamped], [restampedImage], 'default', ignoredFields(byJq)).length, 1);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[2] === '--probe') {
    probeImmutableChanges();
    console.log('check: immutable-field planted defects caught; forward renames, mutable changes and fields Argo CD keeps live accepted');
  } else {
    try {
      const changes = immutableChanges(JSON.parse(readFileSync(process.argv[2])), JSON.parse(readFileSync(process.argv[3])), process.argv[4],
        ignoredFields(JSON.parse(readFileSync(process.argv[5]))));
      if (changes.length) {console.error(changes.join('\n')); process.exitCode = 1;}
    } catch (error) {console.error(error.message); process.exitCode = 1;}
  }
}
