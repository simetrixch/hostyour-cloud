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
function identities(documents, namespace) {
  const result = new Map();
  for (const object of documents.filter(Boolean)) {
    const objects = [object];
    if (object.kind === 'ExternalSecret') objects.push({apiVersion: 'v1', kind: 'Secret',
      metadata: {namespace: object.metadata.namespace, name: object.spec.target?.name ?? object.metadata.name},
      type: object.spec.target?.template?.type ?? 'Opaque'});
    for (const item of objects) {
      const group = item.apiVersion.includes('/') ? item.apiVersion.split('/')[0] : '';
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
export function immutableChanges(before, after, namespace = 'default') {
  const old = identities(before, namespace), findings = [];
  for (const [identity, candidate] of identities(after, namespace)) {
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

}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[2] === '--probe') {
    probeImmutableChanges();
    console.log('check: immutable-field planted defects caught; forward renames and mutable changes accepted');
  } else {
    const changes = immutableChanges(JSON.parse(readFileSync(process.argv[2])), JSON.parse(readFileSync(process.argv[3])), process.argv[4]);
    if (changes.length) {console.error(changes.join('\n')); process.exitCode = 1;}
  }
}
