import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {cpSync, existsSync, mkdtempSync, readdirSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

// THE WAIT: a release pins the images an inventory's values-<stage>.yaml carries under `builds` on
// the books branch, then its pipeline reads the inventory's Application `<inventory>-<stage>` in
// ns argocd until it is live (consumer-build pipeline-release.yaml, its platform hits) and fails a
// Forbidden. So every such inventory grants the releasing unit's pipeline-sa get on its Application
// at every stage of the channel table, and nothing else (common.argoSyncGrant). A patch would
// refresh nothing there, so the grant carries none.

const yq = (args, input) => JSON.parse(execFileSync('yq', ['-o=json', ...args], {encoding: 'utf8', ...(input ? {input} : {})}));
const stages = ['dev', 'test', 'prod'];
const channelStages = [...new Set(Object.values(yq(['.global.channelStages', 'clusters/platform/values-common.yaml'])).flat())].sort();

/** Every value file of an inventory that carries builds, which a release pins and then waits for. */
const pinned = readdirSync('clusters/inventories').flatMap(inventory => stages
  .filter(stage => existsSync(`clusters/inventories/${inventory}/values-${stage}.yaml`))
  .filter(stage => yq(['.builds // [] | length', `clusters/inventories/${inventory}/values-${stage}.yaml`]) > 0)
  .map(stage => ({inventory, stage})));

// A stage file pins the placeholder tag until its first release, and a chart refuses to render it, so
// each pin stands at a released tag here, as the chart renders once the release wrote it.
const standins = mkdtempSync(join(tmpdir(), 'argo-sync-pins-'));
process.on('exit', () => rmSync(standins, {recursive: true, force: true}));
const releasedPins = (inventory, stage) => {
  const file = join(standins, `${inventory}-${stage}.json`);
  writeFileSync(file, JSON.stringify({builds: yq(['.builds | map(.tag = "0.1.0")', `clusters/inventories/${inventory}/values-${stage}.yaml`])}));
  return file;
};

const render = (chart, inventory, stage, ...extra) => spawnSync('helm', ['template', `${inventory}-${stage}`, chart,
  '--namespace', yq(['.namespace', `clusters/inventories/${inventory}/app.yaml`]),
  '-f', 'clusters/platform/values-common.yaml', '-f', `clusters/platform/values-${stage}.yaml`,
  '-f', `clusters/inventories/${inventory}/values-common.yaml`, '-f', `clusters/inventories/${inventory}/values-${stage}.yaml`,
  '-f', releasedPins(inventory, stage),
  '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml', ...extra], {encoding: 'utf8'});

/** Every way the rendered chart misses the grant its release needs, named. */
function grantFindings(chart, inventory, stage) {
  const rendered = render(chart, inventory, stage);
  if (rendered.status !== 0) return [`${inventory} ${stage}: does not render: ${rendered.stderr.trim()}`];
  const inArgocd = kind => JSON.parse(execFileSync('yq', ['ea', '-o=json', '-I=0',
    `[.] | map(select(.kind == "${kind}" and .metadata.namespace == "argocd" and .metadata.name == "platform-${inventory}-argo-sync"))`, '-'],
  {input: rendered.stdout, encoding: 'utf8'}));
  const [role] = inArgocd('Role');
  const [binding] = inArgocd('RoleBinding');
  if (!role || !binding) return [`${inventory} ${stage}: no Role and RoleBinding platform-${inventory}-argo-sync in ns argocd`];
  const releasedBy = yq(['.releasedBy', `clusters/inventories/${inventory}/values-common.yaml`]);
  const found = [];
  const rules = [{apiGroups: ['argoproj.io'], resources: ['applications'], resourceNames: channelStages.map(s => `${inventory}-${s}`), verbs: ['get']}];
  try { assert.deepEqual(role.rules, rules); } catch { found.push(`${inventory} ${stage}: the Role grants ${JSON.stringify(role.rules)}`); }
  try {
    assert.deepEqual(binding.roleRef, {apiGroup: 'rbac.authorization.k8s.io', kind: 'Role', name: role.metadata.name});
    assert.deepEqual(binding.subjects, [{kind: 'ServiceAccount', name: 'pipeline-sa', namespace: `${releasedBy}-build`}]);
  } catch { found.push(`${inventory} ${stage}: the RoleBinding binds ${JSON.stringify(binding.subjects)} to ${JSON.stringify(binding.roleRef)}`); }
  return found;
}

test('the inventories a release pins are read: e2e-runner, gate-runner and manager, and not one without builds', () => {
  const inventories = new Set(pinned.map(({inventory}) => inventory));
  for (const inventory of ['e2e-runner', 'gate-runner', 'manager']) assert.ok(inventories.has(inventory), inventory);
  assert.ok(!inventories.has('coredns'), 'the planted innocent: an inventory whose value files carry no builds');
});

test('every inventory a release pins lets its releasing unit\'s pipeline get its Applications in ns argocd, and nothing else', () => {
  assert.deepEqual(pinned.flatMap(({inventory, stage}) => grantFindings(`clusters/inventories/${inventory}`, inventory, stage)), []);
});

test('the grant binds the unit named for each inventory', () => {
  const unitOf = inventory => yq(['.releasedBy', `clusters/inventories/${inventory}/values-common.yaml`]);
  assert.deepEqual(['e2e-runner', 'gate-runner', 'manager'].map(unitOf), ['digita-testkit', 'hostyour-manager', 'hostyour-manager']);
});

test('PLANTED DEFECT: an inventory with builds that renders no grant is found', () => {
  const dir = mkdtempSync(join(tmpdir(), 'argo-sync-'));
  try {
    const chart = join(dir, 'gate-runner');
    cpSync('clusters/inventories/gate-runner', chart, {recursive: true});
    rmSync(join(chart, 'templates/rbac-argo-sync.yaml'));
    assert.deepEqual(grantFindings(chart, 'gate-runner', 'prod'), ['gate-runner prod: no Role and RoleBinding platform-gate-runner-argo-sync in ns argocd']);
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
});

test('PLANTED DEFECT: an inventory that names no releasing unit is refused, not bound to nobody', () => {
  const rendered = render('clusters/inventories/manager', 'manager', 'prod', '--set', 'releasedBy=null');
  assert.notEqual(rendered.status, 0);
  assert.match(rendered.stderr, /manager: releasedBy is required/);
});
