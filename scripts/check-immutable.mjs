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
// the field left out of the comparison.
export function ignoredFields(app = {}) {
  return app.respectIgnoreDifferences === 'true' ? app.ignoreDifferences ?? [] : [];
}
const each = Symbol('each');
const pointerPath = pointer => pointer.split('/').slice(1).map(step => step.replaceAll('~1', '/').replaceAll('~0', '~'));
// Argo evaluates these with gojq; only .key and []/[]? steps ending in a key are walked here, and any
// other expression is refused rather than ignoring too little or too much.
function jqPath(expression) {
  if (!/^(\.[A-Za-z_]\w*|\[\]\??)*\.[A-Za-z_]\w*$/.test(expression)) throw new Error(`unsupported jqPathExpression ${expression}`);
  return expression.match(/\.[A-Za-z_]\w*|\[\]/g).map(step => step === '[]' ? each : step.slice(1));
}
function unset(node, [step, ...rest]) {
  if (node === null || typeof node !== 'object') return;
  if (step === each) return Array.isArray(node) && node.forEach(item => unset(item, rest));
  if (rest.length) return unset(node[step], rest);
  if (Array.isArray(node)) node.splice(Number(step), 1); else delete node[step];
}
function withoutIgnored(object, namespace, ignored) {
  const rules = ignored.filter(rule => (rule.group ?? '') === groupOf(object.apiVersion) && rule.kind === object.kind &&
    (!rule.name || rule.name === object.metadata.name) && (!rule.namespace || rule.namespace === (object.metadata.namespace ?? namespace)));
  if (!rules.length) return object;
  const copy = structuredClone(object);
  for (const rule of rules) {
    for (const path of [...(rule.jsonPointers ?? []).map(pointerPath), ...(rule.jqPathExpressions ?? []).map(jqPath)]) unset(copy, path);
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
  const plane = {respectIgnoreDifferences: 'true', ignoreDifferences: [
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
  const images = {respectIgnoreDifferences: 'true', ignoreDifferences: [{group: 'batch', kind: 'Job', jqPathExpressions: ['.spec.template.spec.containers[]?.image']}]};
  assert.deepEqual(immutableChanges([job], [changedJob], 'default', ignoredFields(images)), []);
  const piped = {...images, ignoreDifferences: [{...images.ignoreDifferences[0], jqPathExpressions: ['.spec.template | .spec']}]};
  assert.throws(() => immutableChanges([job], [changedJob], 'default', ignoredFields(piped)), /unsupported jqPathExpression/);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[2] === '--probe') {
    probeImmutableChanges();
    console.log('check: immutable-field planted defects caught; forward renames, mutable changes and fields Argo CD keeps live accepted');
  } else {
    const changes = immutableChanges(JSON.parse(readFileSync(process.argv[2])), JSON.parse(readFileSync(process.argv[3])), process.argv[4],
      ignoredFields(JSON.parse(readFileSync(process.argv[5]))));
    if (changes.length) {console.error(changes.join('\n')); process.exitCode = 1;}
  }
}
