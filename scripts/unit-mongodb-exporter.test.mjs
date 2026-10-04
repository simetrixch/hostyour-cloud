import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';

const chart = 'clusters/units/mongodb';
// The unit's own MongoDB as clusters/argocd/files/consumers-appset.yaml renders it: the platform
// globals, the size preset, the mode's own file and the mode word.
const render = (mode, {modeFile = true} = {}) => JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(. != null)]', '-'], {
  encoding: 'utf8', input: execFileSync('helm', ['template', 'acme-test', chart,
    '--namespace', 'acme-test', '--api-versions', 'monitoring.coreos.com/v1',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml',
    '-f', `${chart}/values-size-small.yaml`, ...(modeFile ? ['-f', `${chart}/values-mode-${mode}.yaml`] : []),
    '-f', 'scripts/standin/cluster-map.yaml', '--set', `mongodb.mode=${mode}`,
    '--set', 'externalsecret-mongodb.externalSecret.vaultPath=test/consumer/acme/mongodb'], {encoding: 'utf8'})}));
const envOf = container => Object.fromEntries(container.env.map(({name, value, valueFrom}) => [name, value ?? valueFrom]));

// The exporter reaches every member on its own, as the instance's root, and leaves no credential in a URI.
const checkExporter = docs => {
  const members = docs.find(({kind}) => kind === 'StatefulSet').spec;
  const root = envOf(members.template.spec.containers.find(({name}) => name === 'mongodb'));
  const expected = Array.from({length: members.replicas},
    (_, at) => `mongodb://mongodb-${at}.${members.serviceName}:27017`);

  const exporters = docs.filter(({kind}) => kind === 'Deployment').flatMap(({spec}) => spec.template.spec.containers)
    .filter(({name}) => name === 'mongodb-exporter');
  assert.equal(exporters.length, 1, 'the unit renders no MongoDB exporter, or more than one');
  const env = envOf(exporters[0]);
  assert.equal(env.MONGODB_USER, root.MONGO_INITDB_ROOT_USERNAME);
  assert.deepEqual(env.MONGODB_PASSWORD, root.MONGO_INITDB_ROOT_PASSWORD);
  assert.deepEqual(env.MONGODB_URI.split(','), expected, `the exporter does not reach each of the ${members.replicas} members on its own`);

  const monitors = docs.filter(({kind}) => kind === 'ServiceMonitor');
  assert.equal(monitors.length, 1, 'the exporter has no ServiceMonitor, or more than one');
  assert.equal(monitors[0].metadata.labels.release, 'observability');
  const targets = monitors[0].spec.endpoints.map(({params}) => params.target[0]);
  assert.deepEqual(targets, expected, `the ServiceMonitor does not scrape each of the ${members.replicas} members on its own`);
  for (const uri of [...env.MONGODB_URI.split(','), ...targets]) assert.ok(!uri.includes('@'), `${uri} carries a credential`);

  // The consumer's AppProject refuses these kinds, and one refused resource fails the whole sync.
  assert.deepEqual(docs.filter(({kind}) => ['Role', 'RoleBinding', 'Secret'].includes(kind)).map(({kind}) => kind), []);
};

test('the unit MongoDB of each mode exports every member as its root, to the observability stack', () => {
  for (const mode of ['standalone', 'replicaset']) checkExporter(render(mode));
});

test('a render without the mode file, or without the exporter, is refused', () => {
  assert.throws(() => checkExporter(render('replicaset', {modeFile: false})), /each of the 3 members/);
  const bare = render('standalone').filter(({metadata}) => !metadata.name.includes('prometheus-mongodb-exporter'));
  assert.throws(() => checkExporter(bare), /no MongoDB exporter/);
});

test('the renderer names the mode file beside the mode word', () => {
  const appset = readFileSync('clusters/argocd/files/consumers-appset.yaml', 'utf8');
  const source = appset.slice(appset.indexOf('path: clusters/units/mongodb'));
  assert.match(source.slice(0, source.indexOf('valuesObject:')), /- values-mode-\{\{ \.mongodb \}\}\.yaml/);
});
