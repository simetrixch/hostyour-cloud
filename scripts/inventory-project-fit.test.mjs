import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {existsSync, readdirSync} from 'node:fs';
import test from 'node:test';

// An Application whose namespace its project does not admit is refused by Argo CD with an
// InvalidSpecError and never syncs: nothing reaches the cluster, and nothing goes red here either,
// because the render of the inventory itself is fine. So every inventory's namespace is held against
// the destinations of the project it names, as Argo CD will hold it.

const yq = (args, input) => JSON.parse(execFileSync('yq', args, {encoding: 'utf8', ...(input ? {input} : {})}));
const projects = yq(['ea', '-o=json', '-I=0', '[.] | map(select(.kind == "AppProject"))', 'clusters/argocd/files/projects.yaml']);
const inventories = readdirSync('clusters/inventories')
  .filter(dir => existsSync(`clusters/inventories/${dir}/app.yaml`))
  .map(dir => ({dir, app: yq(['-o=json', '.', `clusters/inventories/${dir}/app.yaml`])}));

// A project names the reconciler's own namespace as a placeholder the fan-out fills; an inventory
// names it as the reconciler's namespace on the master, `argocd`.
const namespaceOf = name => (name === '__ARGOCD_NAMESPACE__' ? 'argocd' : name);

/** Every way the inventories break their projects, named. */
function findings(projectList, inventoryList) {
  const found = [];
  for (const {dir, app} of inventoryList) {
    if (!app.project || !app.namespace) continue;
    const project = projectList.find(p => p.metadata.name === app.project);
    if (!project) { found.push(`${dir}: project ${app.project} is not in projects.yaml`); continue; }
    const admits = (project.spec.destinations ?? []).some(d => d.namespace === '*' || namespaceOf(d.namespace) === app.namespace);
    if (!admits) found.push(`${dir}: project ${app.project} admits no namespace ${app.namespace}`);
  }
  return found;
}

test('every inventory\'s namespace is a destination of its project', () => {
  assert.ok(inventories.some(({dir}) => dir === 'cert-manager'), 'the cert-manager inventory is among those read');
  assert.deepEqual(findings(projects, inventories), []);
});

test('PLANTED DEFECT: a project without the namespace of an inventory that names it is found', () => {
  const planted = structuredClone(projects);
  const core = planted.find(p => p.metadata.name === 'core');
  core.spec.destinations = core.spec.destinations.filter(d => d.namespace !== 'cert-manager');
  assert.deepEqual(findings(planted, inventories).filter(f => f.includes('namespace cert-manager')), [
    'cert-manager: project core admits no namespace cert-manager',
    'cert-manager-issuers: project core admits no namespace cert-manager',
    'trust-manager: project core admits no namespace cert-manager',
  ]);
});

// The cluster-scoped kinds the cert-manager family renders, read off the running addon on the first
// cluster it was adopted on; a kind the project does not whitelist is refused at sync the same way.
const CERT_MANAGER_CLUSTER_KINDS = [
  ['admissionregistration.k8s.io', 'ValidatingWebhookConfiguration'],
  ['admissionregistration.k8s.io', 'MutatingWebhookConfiguration'],
  ['cert-manager.io', 'ClusterIssuer'],
  ['trust.cert-manager.io', 'Bundle'],
  ['apiextensions.k8s.io', 'CustomResourceDefinition'],
  ['rbac.authorization.k8s.io', 'ClusterRole'],
  ['rbac.authorization.k8s.io', 'ClusterRoleBinding'],
];

test('the project of the cert-manager family whitelists every cluster-scoped kind it renders', () => {
  const names = new Set(['cert-manager', 'trust-manager', 'cert-manager-issuers'].map(dir => inventories.find(i => i.dir === dir).app.project));
  assert.deepEqual([...names], ['core']);
  const whitelist = projects.find(p => p.metadata.name === 'core').spec.clusterResourceWhitelist;
  const missing = CERT_MANAGER_CLUSTER_KINDS.filter(([group, kind]) => !whitelist.some(w => (w.group === group || w.group === '*') && (w.kind === kind || w.kind === '*')));
  assert.deepEqual(missing, []);
});

// The image builder renders cluster-scoped kinds of its own (its read-only roles, the admission policy,
// the two priority classes of the build node). A kind its project does not whitelist is refused at
// sync, and the whole application stands OutOfSync. The kinds below are the cluster-scoped ones a
// manifest can name; a rendered document of any of them is held against the project.
const CLUSTER_SCOPED = new Set(['ClusterRole', 'ClusterRoleBinding', 'ValidatingAdmissionPolicy', 'ValidatingAdmissionPolicyBinding',
  'PriorityClass', 'Namespace', 'CustomResourceDefinition', 'ValidatingWebhookConfiguration', 'MutatingWebhookConfiguration']);

test('the project of the image builder whitelists every cluster-scoped kind it renders', () => {
  const {app} = inventories.find(i => i.dir === 'image-builder');
  const rendered = execFileSync('helm', ['template', 'image-builder', 'clusters/inventories/image-builder', '--namespace', app.namespace,
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
    '-f', 'clusters/inventories/image-builder/values-common.yaml', '-f', 'clusters/inventories/image-builder/values-prod.yaml',
    '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/registration.yaml'], {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
  const docs = yq(['ea', '-o=json', '-I=0', '[.]', '-'], rendered).filter(Boolean);
  const kinds = [...new Set(docs.filter(d => CLUSTER_SCOPED.has(d.kind)).map(d => `${d.apiVersion.split('/')[0]} ${d.kind}`))].sort();
  assert.ok(kinds.includes('scheduling.k8s.io PriorityClass') && kinds.includes('rbac.authorization.k8s.io ClusterRole'));
  const whitelist = projects.find(p => p.metadata.name === app.project).spec.clusterResourceWhitelist;
  const missing = kinds.filter(k => !whitelist.some(w => (w.group === k.split(' ')[0] || w.group === '*') && (w.kind === k.split(' ')[1] || w.kind === '*')));
  assert.deepEqual(missing, []);
});
