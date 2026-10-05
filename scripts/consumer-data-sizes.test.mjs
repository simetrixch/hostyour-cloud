import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readdirSync} from 'node:fs';
import test from 'node:test';

const yaml = (expression, input) => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input, encoding: 'utf8'}));
const file = (expression, path) => JSON.parse(execFileSync('yq', ['-o=json', expression, path], {encoding: 'utf8'}));
const appset = file('.spec', 'clusters/argocd/files/consumers-appset.yaml');
const patch = appset.templatePatch;

// The template patch rendered once per parameter set, as the ApplicationSet controller renders it
// (scripts/appset-render). Each answer is {output} or {error}.
const render = (template, paramSets) => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
  input: JSON.stringify({template, options: appset.goTemplateOptions, params: paramSets}), encoding: 'utf8'}));

// A consumer registration with the fields a standing one carries (registrations/<name>/<stage>.yaml on
// the books branch), as the git files generator hands it to the template.
const consumer = (name, extra) => ({
  name, repoURL: `https://example.test/${name}.git`, owner: 'acme', onboardedAt: '2026-10-05T00:00:00Z',
  suspended: false, quiesced: false, removing: false, chartPath: 'chart', cluster: 'apps1',
  databases: [], keyPatterns: [], channelPatterns: [], services: ['postgresql'], size: 'small', mongodb: 'standalone',
  quota: {requestsCpu: '1', requestsMemory: '2Gi', limitsCpu: '4', limitsMemory: '8Gi', pods: '16', persistentVolumeClaims: '4'},
  host: `${name}.example.test`,
  path: {path: `registrations/${name}`, basename: name, filename: 'test.yaml', segments: ['registrations', name]},
  values: {stage: 'test'},
  ...extra,
});

// Where each data service keeps its volume size, and the figure every registration without a pin was
// onboarded at: the presets' figures before they gave the volume up.
const parts = {
  postgresql: {chart: 'clusters/units/postgresql', volume: ['postgres-data', 'pvc', 'storageSize'],
    onboarded: {small: '5Gi', medium: '20Gi', large: '50Gi'}},
  mongodb: {chart: 'clusters/units/mongodb', volume: ['mongodb', 'storageSize'],
    onboarded: {small: '10Gi', medium: '40Gi', large: '100Gi'}},
};
const at = (object, keys) => keys.reduce((value, key) => value?.[key], object);

// What one part's source asks Helm for: its preset, and its volume as Helm merges it — the
// valuesObject over the preset over the chart's own values.yaml.
const asked = (output, part) => {
  const {chart, volume} = parts[part];
  const [source] = yaml(`[.spec.sources[] | select(.path == "${chart}")]`, output);
  if (!source) return undefined;
  const preset = source.helm.valueFiles.find(name => name.startsWith('values-size-'));
  const fromObject = at(source.helm.valuesObject, volume);
  const fromPreset = at(file('.', `${chart}/${preset}`), volume);
  return {preset, volume: fromObject ?? fromPreset ?? at(file('.', `${chart}/values.yaml`), volume)};
};

const renderOne = registration => {
  const [result] = render(patch, [registration]);
  assert.equal(result.error, undefined, `${registration.name}: ${result.error}`);
  return result.output;
};

test('a registration of today renders the preset and the volume it was onboarded with', () => {
  for (const size of ['small', 'medium', 'large']) {
    const output = renderOne(consumer(`today-${size}`, {size}));
    for (const part of Object.keys(parts)) {
      assert.deepEqual(asked(output, part), {preset: `values-size-${size}.yaml`, volume: parts[part].onboarded[size]}, `${part} at ${size}`);
    }
  }
});

test('each part renders its own size, and its pinned volume over any preset', () => {
  const output = renderOne(consumer('per-part', {size: 'small', sizes: {postgresql: 'large', mongodb: 'medium'},
    volumes: {postgresql: '5Gi', mongodb: '10Gi'}}));
  assert.deepEqual(asked(output, 'postgresql'), {preset: 'values-size-large.yaml', volume: '5Gi'});
  assert.deepEqual(asked(output, 'mongodb'), {preset: 'values-size-medium.yaml', volume: '10Gi'});
});

test('a part whose size is written but not yet pinned renders the volume its size was onboarded with', () => {
  // The Manager pins the volume in the same commit as any change of a part's size, so a part without
  // a pin still has the size it was onboarded at.
  const output = renderOne(consumer('unpinned', {size: 'medium', sizes: {postgresql: 'medium'}}));
  assert.deepEqual(asked(output, 'postgresql'), {preset: 'values-size-medium.yaml', volume: '20Gi'});
});

test('a word no registration without a pin can carry renders no volume, and fails no other consumer', () => {
  const results = render(patch, [consumer('pinless-new-word', {sizes: {postgresql: 'xxlarge'}}), consumer('neighbour', {})]);
  results.forEach(result => assert.equal(result.error, undefined, result.error));
  assert.equal(asked(results[0].output, 'postgresql').volume, '');
  assert.deepEqual(asked(results[1].output, 'postgresql'), {preset: 'values-size-small.yaml', volume: '5Gi'});
});

// One failed parameter set is enough for the controller to create, update and delete no Application
// of the whole set, which is why every read above admits a registration without the key.
test('a bare read of sizes or volumes fails every registration without them', () => {
  for (const [from, to] of [['dig "sizes" "postgresql" .size .', '.sizes.postgresql'], [/dig "volumes" "postgresql" \(.*?\) \./, '.volumes.postgresql']]) {
    const bare = patch.replace(from, to);
    assert.notEqual(bare, patch, `the template no longer reads ${from}`);
    const [result] = render(bare, [consumer('today', {})]);
    assert.match(result.error ?? '', /map has no entry for key "(sizes|volumes)"/, `${to} did not fail`);
  }
});

// A preset sizes the pods and nothing else: a volume cannot change once created, so a preset that
// named one would turn every change of size into a refused resize.
test('no preset carries a volume size', () => {
  for (const {chart, volume} of Object.values(parts)) {
    for (const preset of readdirSync(chart).filter(name => name.startsWith('values-size-'))) {
      assert.equal(at(file('.', `${chart}/${preset}`), volume), undefined, `${chart}/${preset} sizes a volume`);
    }
  }
});

// THE SIZE TABLE'S ROWS, the counterpart of the Manager's seed (hostyour-manager plugins/unit/shared/unit-size.ts,
// UNIT_SIZE_SEED and MONGODB_EXPORTER), in millicores and Mi: small to large copied from it, xsmall,
// xlarge and xxlarge the figures decided with this file's presets for the seed to carry.
// `postgresql` is one instance with its exporter, rounded up; `mongodb` one member; the MongoDB
// exporter is one pod per instance, priced on its own. No surge: PostgreSQL and both exporters run
// Recreate, MongoDB is a StatefulSet, so the pods fit once.
const rows = {
  postgresql: {
    xsmall: {requests: [25, 256], limits: [400, 512]},
    small: {requests: [50, 512], limits: [600, 1024]},
    medium: {requests: [150, 1536], limits: [1200, 2560]},
    large: {requests: [300, 2560], limits: [2200, 4608]},
    xlarge: {requests: [450, 3584], limits: [3200, 6656]},
    xxlarge: {requests: [600, 4608], limits: [4200, 8704]},
  },
  mongodb: {
    xsmall: {requests: [50, 256], limits: [500, 1024]},
    small: {requests: [100, 512], limits: [1000, 2048]},
    medium: {requests: [250, 1024], limits: [2000, 4096]},
    large: {requests: [500, 2048], limits: [4000, 8192]},
    xlarge: {requests: [750, 3072], limits: [6000, 12288]},
    xxlarge: {requests: [1000, 4096], limits: [8000, 16384]},
  },
};
const mongodbExporter = {requests: [15, 48], limits: [100, 128]};

const cpu = quantity => String(quantity).endsWith('m') ? Number.parseFloat(quantity) : Number.parseFloat(quantity) * 1000;
const memory = quantity => {
  const [, number, unit] = String(quantity).match(/^([\d.]+)(Ki|Mi|Gi)?$/);
  return Number(number) * {Ki: 1 / 1024, Mi: 1, Gi: 1024, undefined: 1 / 1024 / 1024}[unit];
};
const sum = containers => ['requests', 'limits'].reduce((total, kind) => ({...total, [kind]: [
  containers.reduce((n, {resources}) => n + cpu(resources[kind].cpu), 0),
  containers.reduce((n, {resources}) => n + memory(resources[kind].memory), 0),
]}), {});
const fits = (used, row) => ['requests', 'limits'].every(kind => used[kind].every((value, index) => value <= row[kind][index]));

const pods = (part, preset, extra = []) => JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(.kind == "Deployment" or .kind == "StatefulSet")]', '-'], {
  encoding: 'utf8', input: execFileSync('helm', ['template', 'acme-test', parts[part].chart, '--namespace', 'acme-test',
    '--api-versions', 'monitoring.coreos.com/v1', '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml',
    '-f', `${parts[part].chart}/${preset}`, '-f', 'scripts/standin/cluster-map.yaml',
    '--set', 'externalsecret-postgres.externalSecret.vaultPath=test/consumer/acme/postgres',
    '--set', 'externalsecret-mongodb.externalSecret.vaultPath=test/consumer/acme/mongodb', ...extra], {encoding: 'utf8'})}));
const containersOf = workload => [...(workload.spec.template.spec.initContainers ?? []), ...workload.spec.template.spec.containers];
const used = (part, preset, extra) => {
  const workloads = pods(part, preset, extra);
  if (part === 'postgresql') return {instance: sum(workloads.flatMap(containersOf))};
  const exporter = workloads.find(({kind}) => kind === 'Deployment');
  return {instance: sum(containersOf(workloads.find(({kind}) => kind === 'StatefulSet'))), exporter: sum(containersOf(exporter))};
};

test('every preset of every data service fits its size-table row', () => {
  for (const part of Object.keys(parts)) {
    for (const preset of readdirSync(parts[part].chart).filter(name => name.startsWith('values-size-'))) {
      const size = preset.slice('values-size-'.length, -'.yaml'.length);
      const row = rows[part][size];
      assert.ok(row, `${part} has a ${preset} but the size table has no ${part} row for ${size}`);
      const {instance, exporter} = used(part, preset);
      assert.ok(fits(instance, row), `${part} at ${size} uses ${JSON.stringify(instance)}, its row is ${JSON.stringify(row)}`);
      if (exporter) assert.ok(fits(exporter, mongodbExporter), `the MongoDB exporter uses ${JSON.stringify(exporter)}`);
    }
  }
});

test('a preset above its row is refused', () => {
  const planted = used('postgresql', 'values-size-small.yaml', ['--set', 'postgres.resources.limits.memory=1100Mi']);
  assert.equal(fits(planted.instance, rows.postgresql.small), false);
});

// A consumer's OWN Redis (clusters/units/redis): a source only for `redis: standalone`, at its own
// size, on its pinned volume, with the policy the registration names.
const redisSource = output => yaml('[.spec.sources[] | select(.path == "clusters/units/redis")]', output)[0];

test('an own Redis renders its preset, its pinned volume, its policy and its credential path', () => {
  const source = redisSource(renderOne(consumer('cache', {services: ['redis'], redis: 'standalone', redisMaxmemoryPolicy: 'allkeys-lru',
    size: 'small', sizes: {redis: 'large'}, volumes: {redis: '8Gi'}})));
  assert.ok(source, 'no clusters/units/redis source');
  assert.ok(source.helm.valueFiles.includes('values-size-large.yaml'), source.helm.valueFiles.join(', '));
  assert.deepEqual([source.helm.valuesObject['redis-data'].pvc.storageSize, source.helm.valuesObject.redis.maxmemoryPolicy,
    source.helm.valuesObject['externalsecret-redis'].externalSecret.vaultPath], ['8Gi', 'allkeys-lru', 'test/consumer/cache/redis']);
});

test('a registration on the shared Redis, or written before the key, renders no own Redis', () => {
  assert.equal(redisSource(renderOne(consumer('shared-cache', {services: ['redis'], redis: 'shared'}))), undefined);
  assert.equal(redisSource(renderOne(consumer('older', {}))), undefined);
});

// The Manager's `redis` rows (UNIT_SIZE_SEED.redis): the server and its exporter, together.
const redisRows = {
  xsmall: {requests: [25, 128], limits: [250, 512]},
  small: {requests: [50, 256], limits: [500, 1024]},
  medium: {requests: [100, 512], limits: [1000, 2048]},
  large: {requests: [200, 1024], limits: [2000, 4096]},
  xlarge: {requests: [300, 2048], limits: [2000, 8192]},
  xxlarge: {requests: [400, 3072], limits: [2000, 12288]},
};
const redisPods = preset => JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(.kind == "Deployment")]', '-'], {
  encoding: 'utf8', input: execFileSync('helm', ['template', 'acme-test', 'clusters/units/redis', '--namespace', 'acme-test',
    '--api-versions', 'monitoring.coreos.com/v1', '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml',
    '-f', `clusters/units/redis/${preset}`, '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml',
    '--set', 'externalsecret-redis.externalSecret.vaultPath=test/consumer/acme/redis'], {encoding: 'utf8'})}));

test('every preset of an own Redis, its exporter included, is exactly its size-table row', () => {
  for (const [size, row] of Object.entries(redisRows)) {
    const total = sum(redisPods(`values-size-${size}.yaml`).flatMap(containersOf));
    assert.deepEqual(total, row, `redis at ${size}`);
  }
  assert.deepEqual(readdirSync('clusters/units/redis').filter(name => name.startsWith('values-size-')).sort(),
    Object.keys(redisRows).map(size => `values-size-${size}.yaml`).sort());
});
