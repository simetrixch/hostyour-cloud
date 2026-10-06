import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';

// The platform's own unit charts are sources of a consumer's Application, so every resource they render is
// judged by the consumer's AppProject, which refuses the kinds a unit could widen its own fence with
// (clusters/units/reconciler/templates/appproject.yaml), and every pod they render by the consumer namespace's
// Pod Security level, which the ApplicationSet stamps. One refused resource fails the whole sync, and a refused
// pod never starts. Each unit chart the consumers ApplicationSet names is rendered as it renders it, and checked
// against the project's own list and the restricted level.

const appset = readFileSync('clusters/argocd/files/consumers-appset.yaml', 'utf8');
const project = readFileSync('clusters/units/reconciler/templates/appproject.yaml', 'utf8');

/** The kinds the per-unit AppProject refuses, read from its namespaceResourceBlacklist. */
export function refusedKinds(text) {
  const block = text.slice(text.indexOf('namespaceResourceBlacklist:')).split('\n').slice(1);
  const kinds = [];
  for (const line of block) {
    if (!/^\s+(- group:|kind:)/.test(line)) break;
    const kind = /kind:\s*(\S+)/.exec(line);
    if (kind) kinds.push(kind[1]);
  }
  return kinds;
}

/** The unit charts the consumers ApplicationSet adds to a consumer's Application. */
const unitsOf = text => [...new Set([...text.matchAll(/path: clusters\/units\/([a-z-]+)/g)].map(m => m[1]))].sort();

const common = ['-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml', '-f', 'scripts/standin/cluster-map.yaml'];
const sized = unit => ['-f', `clusters/units/${unit}/values-size-small.yaml`];
const secret = (alias, store) => ['--set', `${alias}.externalSecret.vaultPath=test/consumer/acme/${store}`];

/** How the ApplicationSet renders each unit chart: its value files and the values it sets. */
const RENDER = {
  postgresql: [...common, ...sized('postgresql'), '--set', 'postgres-data.pvc.storageSize=5Gi', ...secret('externalsecret-postgres', 'postgres')],
  mongodb: [...common, ...sized('mongodb'), '-f', 'clusters/units/mongodb/values-mode-standalone.yaml', '--set', 'mongodb.mode=standalone',
    '--set', 'mongodb.storageSize=10Gi', ...secret('externalsecret-mongodb', 'mongodb')],
  redis: [...common, ...sized('redis'), '--set', 'redis-data.pvc.storageSize=1Gi', ...secret('externalsecret-redis', 'redis')],
  mariadb: [...common, ...sized('mariadb'), '--set', 'mariadb-data.pvc.storageSize=1Gi', ...secret('externalsecret-mariadb', 'mariadb')],
  networkpolicy: ['-f', 'scripts/standin/cluster-map.yaml', '--set', 'smtpEntry.port=2525'],
  quota: ['--set', 'quota.requestsCpu=400m', '--set', 'quota.requestsMemory=1Gi', '--set', 'quota.limitsCpu=1500m',
    '--set', 'quota.limitsMemory=2Gi', '--set', 'quota.pods=8', '--set', 'quota.persistentVolumeClaims=1'],
};

const render = unit => JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(. != null)]', '-'], {
  encoding: 'utf8',
  input: execFileSync('helm', ['template', 'acme-test', `clusters/units/${unit}`, '--namespace', 'acme-test',
    '--api-versions', 'monitoring.coreos.com/v1', ...RENDER[unit]], {encoding: 'utf8'}),
}));

/** The Pod Security level the ApplicationSet stamps on every consumer namespace. */
const enforced = /pod-security\.kubernetes\.io\/enforce: (\S+)/.exec(appset)?.[1];

/** What the restricted level asks of a pod, as `<unit>: <workload>/<container>: <rule>` for each one it breaks. */
export function restrictedBreaches(unit, docs) {
  const breaches = [];
  for (const {kind, metadata, spec} of docs) {
    // Argo CD applies no Helm test hook ("Not supported. No equivalent in Argo CD", its Helm guide), so such a pod
    // never reaches the namespace.
    if (/^test/.test(metadata?.annotations?.['helm.sh/hook'] ?? '')) continue;
    const pod = ['Deployment', 'StatefulSet', 'DaemonSet', 'Job'].includes(kind) ? spec.template.spec : kind === 'Pod' ? spec : null;
    if (!pod) continue;
    const podContext = pod.securityContext ?? {};
    for (const container of [...(pod.initContainers ?? []), ...(pod.containers ?? [])]) {
      const context = container.securityContext ?? {};
      const at = `${unit}: ${kind}/${metadata.name}/${container.name}`;
      if (context.allowPrivilegeEscalation !== false) breaches.push(`${at}: allowPrivilegeEscalation`);
      if (!(context.capabilities?.drop ?? []).includes('ALL')) breaches.push(`${at}: capabilities`);
      if ((context.runAsNonRoot ?? podContext.runAsNonRoot) !== true) breaches.push(`${at}: runAsNonRoot`);
      const seccomp = (context.seccompProfile ?? podContext.seccompProfile)?.type;
      if (seccomp !== 'RuntimeDefault' && seccomp !== 'Localhost') breaches.push(`${at}: seccompProfile`);
    }
  }
  return breaches;
}

/** The rendered resources the project refuses, as `<unit>: <kind>/<name>`. */
export function refusedIn(unit, docs, refused) {
  return docs.filter(({kind}) => refused.includes(kind)).map(({kind, metadata}) => `${unit}: ${kind}/${metadata?.name ?? '?'}`);
}

test('the per-unit project refuses the kinds that would widen a unit\'s fence', () => {
  assert.deepEqual(refusedKinds(project), ['Application', 'ApplicationSet', 'AppProject', 'Role', 'RoleBinding', 'Secret']);
});

test('every unit chart of a consumer\'s Application is rendered here', () => {
  assert.deepEqual(unitsOf(appset), Object.keys(RENDER).sort());
});

test('no unit chart of a consumer\'s Application renders a kind its project refuses', () => {
  const refused = refusedKinds(project);
  assert.deepEqual(Object.keys(RENDER).flatMap(unit => refusedIn(unit, render(unit), refused)), []);
});

test('every pod of a consumer\'s unit charts meets the restricted Pod Security level its namespace enforces', () => {
  assert.equal(enforced, 'restricted');
  assert.deepEqual(Object.keys(RENDER).flatMap(unit => restrictedBreaches(unit, render(unit))), []);
});

test('PLANTED: a container without its restricted settings is named for each one; a restricted one passes', () => {
  const restricted = {allowPrivilegeEscalation: false, capabilities: {drop: ['ALL']}};
  const pod = containers => ({kind: 'Deployment', metadata: {name: 'exporter'},
    spec: {template: {spec: {securityContext: {runAsNonRoot: true, seccompProfile: {type: 'RuntimeDefault'}}, containers}}}});
  assert.deepEqual(restrictedBreaches('planted', [pod([{name: 'bare'}])]), ['planted: Deployment/exporter/bare: allowPrivilegeEscalation', 'planted: Deployment/exporter/bare: capabilities']);
  assert.deepEqual(restrictedBreaches('planted', [pod([{name: 'kept', securityContext: restricted}])]), []);
  const loose = {kind: 'Deployment', metadata: {name: 'exporter'}, spec: {template: {spec: {containers: [{name: 'kept', securityContext: restricted}]}}}};
  assert.deepEqual(restrictedBreaches('planted', [loose]), ['planted: Deployment/exporter/kept: runAsNonRoot', 'planted: Deployment/exporter/kept: seccompProfile']);
});

test('PLANTED: a Role, a RoleBinding or a Secret is named; an ExternalSecret, a ServiceAccount and a Deployment pass', () => {
  const refused = refusedKinds(project);
  const planted = [
    {kind: 'Role', metadata: {name: 'exporter'}}, {kind: 'RoleBinding', metadata: {name: 'exporter'}},
    {kind: 'Secret', metadata: {name: 'exporter-config'}}, {kind: 'ExternalSecret', metadata: {name: 'credentials'}},
    {kind: 'ServiceAccount', metadata: {name: 'exporter'}}, {kind: 'Deployment', metadata: {name: 'exporter'}},
  ];
  assert.deepEqual(refusedIn('planted', planted, refused), ['planted: Role/exporter', 'planted: RoleBinding/exporter', 'planted: Secret/exporter-config']);
  assert.deepEqual(refusedKinds('namespaceResourceBlacklist:\n    - group: ""\n      kind: Secret\n  roles: []'), ['Secret']);
});

test('the MariaDB exporter reads its my.cnf from the credentials ESO materialises, holding the root password from Vault', () => {
  const docs = render('mariadb');
  const external = docs.find(({kind}) => kind === 'ExternalSecret');
  assert.equal(external.spec.target.name, 'mariadb-credentials');
  assert.equal(external.spec.target.template.mergePolicy, 'Merge');
  assert.match(external.spec.target.template.data['my.cnf'], /password=\{\{ index \. "root-password" \}\}/);
  assert.doesNotMatch(external.spec.target.template.data['my.cnf'], /password=[^{]/, 'my.cnf carries a literal password');
  const exporter = docs.filter(({kind}) => kind === 'Deployment').find(({metadata}) => metadata.name === 'mariadb-exporter');
  const volumes = exporter.spec.template.spec.volumes.map(({secret}) => secret?.secretName).filter(Boolean);
  assert.ok(volumes.includes('mariadb-credentials'), 'the exporter mounts no mariadb-credentials');
});
