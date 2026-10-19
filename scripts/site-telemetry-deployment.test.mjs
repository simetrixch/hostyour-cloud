import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readdirSync, readFileSync} from 'node:fs';
import test from 'node:test';

// THE SERVICE WHERE global.servicesLocal.observability IS ON: clusters/inventories/observability rendered
// for dev against the stand-in cluster map, which states the query address
// (global.endpoints.observability.query). The objects are held to each other, because a pod that
// renders but is not selected, not admitted or not bound to its role passes every check of a single
// object and answers nobody.
const script = readFileSync('clusters/inventories/observability/files/site_telemetry.py', 'utf8');
const render = (...set) => spawnSync('helm', ['template', 'observability', 'clusters/inventories/observability', '--namespace', 'observability',
  '--api-versions', 'monitoring.coreos.com/v1', '--api-versions', 'monitoring.coreos.com/v1alpha1',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-dev.yaml',
  '-f', 'clusters/inventories/observability/values-common.yaml', '-f', 'clusters/inventories/observability/values-dev.yaml',
  '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/registration.yaml', ...set],
{encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
const documents = rendered => execFileSync('yq', ['-o=json', '-I=0', 'select(. != null)', '-'], {input: rendered, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024})
  .split('\n').filter(Boolean).map(line => JSON.parse(line));

const served = render();
assert.equal(served.status, 0, served.stderr);
const DOCUMENTS = documents(served.stdout);
const named = (documents, kind, name) => documents.find(candidate => candidate.kind === kind && candidate.metadata.name === name);
const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);

// Every way the objects can fail to meet, named. Empty means they meet.
function findings(documents) {
  const faults = [];
  const deployment = named(documents, 'Deployment', 'site-telemetry');
  const service = named(documents, 'Service', 'site-telemetry');
  const policy = named(documents, 'NetworkPolicy', 'site-telemetry-allow');
  const role = named(documents, 'Role', 'site-telemetry-registrations');
  const binding = named(documents, 'RoleBinding', 'site-telemetry-registrations');
  const scriptMap = named(documents, 'ConfigMap', 'site-telemetry-script');
  const ingress = documents.find(candidate => candidate.kind === 'Ingress' && candidate.metadata.name === 'observability-ingress-site-telemetry');
  if (![deployment, service, policy, role, binding, scriptMap, ingress].every(Boolean)) return ['an object of the service is not rendered'];
  const pod = deployment.spec.template;
  const [container] = pod.spec.containers;
  const port = container.ports.find(({name}) => name === 'http');
  const environment = Object.fromEntries(container.env.map(({name, value}) => [name, value]));
  const labelsOf = selector => Object.entries(selector).every(([key, value]) => pod.metadata.labels[key] === value);
  if (!labelsOf(deployment.spec.selector.matchLabels)) faults.push('the Deployment does not select its own pods');
  if (!labelsOf(service.spec.selector)) faults.push('the Service selects no pod of the Deployment');
  if (!labelsOf(policy.spec.podSelector.matchLabels)) faults.push('the NetworkPolicy selects no pod of the Deployment');
  if (service.spec.ports[0].targetPort !== 'http' || !port) faults.push('the Service targets a port the container does not open');
  if (String(port?.containerPort) !== environment.LISTEN_PORT) faults.push('the container opens another port than the service listens on');
  if (!policy.spec.ingress.every(({ports}) => ports.every(({port: admitted}) => admitted === port?.containerPort))) faults.push('the NetworkPolicy admits another port than the container opens');
  if (!same(policy.spec.policyTypes, ['Ingress'])) faults.push('the NetworkPolicy denies more than what comes in');
  if (!same(policy.spec.ingress.flatMap(({from}) => from.map(({namespaceSelector}) => namespaceSelector?.matchLabels)), [{'kubernetes.io/metadata.name': 'ingress'}])) faults.push('the NetworkPolicy admits another source than the ingress controller');
  if (!same(binding.subjects, [{kind: 'ServiceAccount', name: pod.spec.serviceAccountName, namespace: 'observability'}])) faults.push('the RoleBinding binds another account than the pod runs as');
  if (binding.roleRef.name !== role.metadata.name) faults.push('the RoleBinding binds another Role');
  if (!documents.some(candidate => candidate.kind === 'ServiceAccount' && candidate.metadata.name === pod.spec.serviceAccountName)) faults.push('the pod runs as an account that is not rendered');
  if (!same(role.rules, [{apiGroups: [''], resources: ['configmaps'], verbs: ['list']}])) faults.push('the Role grants more than listing ConfigMaps');
  if (scriptMap.data['site_telemetry.py'] !== script) faults.push('the pod runs another script than files/site_telemetry.py');
  const lokiUrl = new URL(environment.LOKI_URL);
  const loki = named(documents, 'Service', lokiUrl.hostname.split('.')[0]);
  if (!loki || !loki.spec.ports.some(({port: served}) => String(served) === lokiUrl.port) || lokiUrl.hostname.split('.')[1] !== 'observability') faults.push('LOKI_URL names a Service Loki does not serve');
  if (pod.spec.volumes.every(({configMap}) => configMap?.name !== scriptMap.metadata.name) || container.command.at(-1) !== `${container.volumeMounts[0].mountPath}/site_telemetry.py`) faults.push('the container does not run the mounted script');
  const [backend] = ingress.spec.rules.flatMap(({http}) => http.paths.map(({backend: {service: target}}) => target));
  if (backend.name !== service.metadata.name || backend.port.number !== service.spec.ports[0].port) faults.push('the Ingress routes to another Service or port');
  if (ingress.spec.rules[0].host !== 'observability-query.check.example.invalid') faults.push('the Ingress is not at the address the cluster map states');
  if (!(container.securityContext.readOnlyRootFilesystem && pod.spec.securityContext.runAsNonRoot && !container.securityContext.allowPrivilegeEscalation)) faults.push('the container is not locked down');
  if (!/^python:\d+\.\d+-slim$/.test(container.image)) faults.push('the image is not a pinned python');
  return faults;
}

test('the objects of the service meet: selected, admitted, bound, routed and running the tested script', () => {
  assert.deepEqual(findings(DOCUMENTS), []);
});

test('PLANTED DEFECT: every way the objects can miss each other is caught, by name', () => {
  const planted = (change) => { const copy = structuredClone(DOCUMENTS); change(copy); return findings(copy); };
  const of = (copy, kind, name) => named(copy, kind, name);
  const cases = [
    ['a Service that selects nothing', copy => { of(copy, 'Service', 'site-telemetry').spec.selector['app.kubernetes.io/name'] = 'other'; }, /Service selects no pod/],
    ['a policy that selects nothing', copy => { of(copy, 'NetworkPolicy', 'site-telemetry-allow').spec.podSelector.matchLabels['app.kubernetes.io/name'] = 'other'; }, /NetworkPolicy selects no pod/],
    ['a policy that admits another port', copy => { of(copy, 'NetworkPolicy', 'site-telemetry-allow').spec.ingress[0].ports[0].port = 9090; }, /admits another port/],
    ['a policy that admits every source', copy => { of(copy, 'NetworkPolicy', 'site-telemetry-allow').spec.ingress[0].from.push({podSelector: {}}); }, /another source/],
    ['a role bound to another account', copy => { of(copy, 'RoleBinding', 'site-telemetry-registrations').subjects[0].name = 'default'; }, /another account/],
    ['a role that reads Secrets too', copy => { of(copy, 'Role', 'site-telemetry-registrations').rules[0].resources.push('secrets'); }, /more than listing ConfigMaps/],
    ['a script that is not the tested one', copy => { of(copy, 'ConfigMap', 'site-telemetry-script').data['site_telemetry.py'] += '\n'; }, /another script/],
    ['a Loki that is not served', copy => { of(copy, 'Deployment', 'site-telemetry').spec.template.spec.containers[0].env.find(({name}) => name === 'LOKI_URL').value = 'http://loki-gateway.observability.svc.cluster.local:3100'; }, /Loki does not serve/],
    ['an Ingress that routes to another port', copy => { copy.find(({kind, metadata}) => kind === 'Ingress' && metadata.name === 'observability-ingress-site-telemetry').spec.rules[0].http.paths[0].backend.service.port.number = 8080; }, /another Service or port/],
    ['a container that may write its filesystem', copy => { of(copy, 'Deployment', 'site-telemetry').spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem = false; }, /not locked down/],
  ];
  for (const [name, change, expected] of cases) {
    const faults = planted(change);
    assert.ok(faults.some(fault => expected.test(fault)), `${name}: ${JSON.stringify(faults)}`);
  }
});

test('a cluster without global.servicesLocal.observability renders none of the service, and one without the address is refused', () => {
  const elsewhere = render('--set', 'global.servicesLocal.observability=false');
  assert.equal(elsewhere.status, 0, elsewhere.stderr);
  assert.deepEqual(documents(elsewhere.stdout).filter(({metadata}) => /site-telemetry/.test(metadata?.name ?? '')).map(({kind}) => kind), []);
  const unaddressed = render('--set-string', 'global.endpoints.observability.query=');
  assert.notEqual(unaddressed.status, 0);
  assert.match(unaddressed.stderr, /global\.endpoints\.observability\.query is required/);
});

// The owner's limit on the site statistics: no code and no text names the master, because the figures
// are served at global.endpoints.observability.query, and a word that names a server is false the day
// that address moves. The files are the ones of the statistics alone, whole, this one apart, which states
// the limit; the spans are the lines of this change in files that predate it, from the first line holding
// the first anchor to the first line, from there on, holding the second.
const SERVER = /master/i;
const whole = path => [path, readFileSync(path, 'utf8')];
const listed = (directory, accepted) => readdirSync(directory).filter(name => accepted.test(name)).map(name => whole(`${directory}/${name}`));
function span(path, from, to) {
  const lines = readFileSync(path, 'utf8').split('\n');
  const first = lines.findIndex(line => line.includes(from));
  const last = lines.findIndex((line, at) => at >= first && line.includes(to));
  assert.ok(first >= 0 && last >= first, `${path} holds no span from "${from}" to "${to}"`);
  return [`${path}: ${from}`, lines.slice(first, last + 1).join('\n')];
}
const ALLOY_STAGE = ["Traefik's access log carries the whole request target", 'replace    = ""'];
const OWNED = [
  ...listed('clusters/inventories/observability/templates', /^_?site-telemetry/),
  whole('clusters/inventories/observability/files/site_telemetry.py'),
  span('clusters/inventories/observability/values-common.yaml', 'The site statistics service (templates/site-telemetry', 'memory: 1Gi'),
  span('clusters/inventories/observability/values-common.yaml', '# global.endpoints.observability.query → the site statistics service', "secretName: 'observability-site-telemetry-"),
  whole('clusters/argocd/files/site-telemetry-registrations-appset.yaml'),
  ...['Chart.yaml', 'values.yaml', 'templates/configmap.yaml'].map(name => whole(`clusters/units/site-telemetry-registration/${name}`)),
  span('clusters/charts/monitoring/templates/alloy-agent-config.yaml', ...ALLOY_STAGE),
  span('clusters/charts/monitoring/templates/alloy-config.yaml', ...ALLOY_STAGE),
  ...listed('scripts', /^(?:site-telemetry.*\.test\.mjs|alloy-access-log-strip\.test\.mjs)$/).filter(([name]) => name !== 'scripts/site-telemetry-deployment.test.mjs'),
  whole('scripts/alloy-replace/main.go'),
];
const namingTheServer = files => files.filter(([, text]) => SERVER.test(text)).map(([name]) => name);

test('no file of the site statistics names the master', () => {
  assert.ok(OWNED.some(([name]) => name.endsWith('site-telemetry-deployment.yaml')), 'the Deployment is among the files');
  assert.deepEqual(namingTheServer(OWNED), []);
});

test('PLANTED DEFECT: the master named in a file of the statistics, or in any line of a span, is found; a text without it is not', () => {
  for (const [name, text] of OWNED) {
    assert.deepEqual(namingTheServer([[name, `${text}\n# observability-query.<master-fqdn>`]]), [name], name);
    assert.deepEqual(namingTheServer([[name, text.replaceAll(/\bobservability\b/g, 'the observability application')]]), [], name);
  }
});
