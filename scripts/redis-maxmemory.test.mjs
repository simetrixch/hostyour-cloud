import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const render = stage => execFileSync('helm', ['template', 'redis', 'clusters/inventories/redis', '--namespace', 'redis',
  '--api-versions', 'monitoring.coreos.com/v1', '--api-versions', 'monitoring.coreos.com/v1alpha1',
  '-f', 'clusters/platform/values-common.yaml', '-f', `clusters/platform/values-${stage}.yaml`,
  '-f', 'clusters/inventories/redis/values-common.yaml', '-f', `clusters/inventories/redis/values-${stage}.yaml`,
  '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml',
  '-f', 'scripts/standin/registration.yaml'], {encoding: 'utf8'});
const read = (expression, rendered) => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input: rendered, encoding: 'utf8'}));
const server = rendered => read(
  'select(.kind == "Deployment" and .metadata.name == "redis") | .spec.template.spec.containers[] | select(.name == "redis")', rendered);
const nearCeiling = rendered => read(
  'select(.kind == "PrometheusRule") | .spec.groups[].rules[] | select(.alert == "RedisMemoryNearCeiling") | .expr', rendered);

// redis.conf units: k, m and g count in thousands, kb, mb and gb in 1024s. A bare 0 means no ceiling at all.
const redisBytes = value => {
  const [, number, unit = ''] = /^(\d+)([kmg]b?)?$/i.exec(value);
  return Number(number) * {'': 1, k: 1e3, kb: 2 ** 10, m: 1e6, mb: 2 ** 20, g: 1e9, gb: 2 ** 30}[unit.toLowerCase()];
};
const kubernetesBytes = value => {
  const [, number, unit = ''] = /^(\d+)(Ki|Mi|Gi|Ti|k|M|G|T)?$/.exec(value);
  return Number(number) * {'': 1, Ki: 2 ** 10, Mi: 2 ** 20, Gi: 2 ** 30, Ti: 2 ** 40, k: 1e3, M: 1e6, G: 1e9, T: 1e12}[unit];
};
const option = (args, name) => {
  const at = args.indexOf(name);
  return at < 0 ? undefined : args[at + 1];
};
const checkCeiling = ({args, resources}) => {
  const ceiling = option(args, '--maxmemory');
  assert.ok(ceiling, 'redis-server carries no --maxmemory');
  assert.ok(redisBytes(ceiling) > 0, `--maxmemory ${ceiling} sets no ceiling`);
  // maxmemory bounds the used memory, not the resident size: an AOF rewrite's fork can copy the whole
  // dataset again, so the ceiling is at most half the container's memory limit.
  assert.ok(2 * redisBytes(ceiling) <= kubernetesBytes(resources.limits.memory),
    `--maxmemory ${ceiling} is more than half the container's memory limit ${resources.limits.memory}`);
  assert.equal(option(args, '--maxmemory-policy'), 'noeviction');
};
// A server reporting max 0 makes used/max +Inf, so the alert holds only where a ceiling is set.
const checkRule = expr => assert.match(expr, /\band\s+redis_memory_max_bytes\s*>\s*0\b/, `RedisMemoryNearCeiling has no ceiling guard: ${expr}`);
const prodRender = render('prod');
const prod = server(prodRender);

test('the shared Redis of every stage runs under a ceiling of half its memory limit, with noeviction, and warns before it', () => {
  for (const stage of ['dev', 'test', 'prod']) {
    const rendered = stage === 'prod' ? prodRender : render(stage);
    checkCeiling(server(rendered));
    checkRule(nearCeiling(rendered));
  }
});

test('a missing, unlimited or too high ceiling, an evicting or unstated policy and an unguarded alert are refused', () => {
  const withArgs = change => ({...prod, args: change([...prod.args])});
  const setOption = (name, value) => args => { args[args.indexOf(name) + 1] = value; return args; };
  const dropOption = name => args => { args.splice(args.indexOf(name), 2); return args; };
  for (const planted of [dropOption('--maxmemory'), setOption('--maxmemory', '0'), setOption('--maxmemory', '4gb'),
    setOption('--maxmemory', '6gb'), setOption('--maxmemory', '7g'), setOption('--maxmemory-policy', 'allkeys-lru'),
    setOption('--maxmemory-policy', 'volatile-lru'), dropOption('--maxmemory-policy')]) {
    assert.throws(() => checkCeiling(withArgs(planted)));
  }
  checkCeiling(withArgs(setOption('--maxmemory', '3gb')));
  checkCeiling(withArgs(setOption('--maxmemory', '1024mb')));
  assert.throws(() => checkRule('redis_memory_used_bytes / redis_memory_max_bytes > 0.85'));
  checkRule(nearCeiling(prodRender));
});

// A consumer's own Redis (clusters/units/redis): every size preset holds the same ceiling rule against
// its own container, and its policy is the one the registration names, noeviction by default.
const unitRender = (preset, policy) => execFileSync('helm', ['template', 'acme-test', 'clusters/units/redis', '--namespace', 'acme-test',
  '--api-versions', 'monitoring.coreos.com/v1', '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml',
  '-f', `clusters/units/redis/${preset}`, '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml',
  '--set', 'externalsecret-redis.externalSecret.vaultPath=test/consumer/acme/redis', ...(policy ? ['--set', `redis.maxmemoryPolicy=${policy}`] : [])],
  {encoding: 'utf8'});
const unitServer = rendered => {
  const container = server(rendered);
  const env = Object.fromEntries((container.env ?? []).filter(e => 'value' in e).map(e => [e.name, e.value]));
  return {...container, args: container.args.map(a => a.replace(/^\$\((\w+)\)$/, (whole, name) => env[name] ?? whole))};
};

test('every size of a consumer\'s own Redis runs under a ceiling of half its container limit', () => {
  for (const preset of ['xsmall', 'small', 'medium', 'large', 'xlarge', 'xxlarge'].map(size => `values-size-${size}.yaml`)) {
    checkCeiling(unitServer(unitRender(preset)));
  }
});

test('a consumer\'s own Redis takes the maxmemory policy its registration names', () => {
  const evicting = unitServer(unitRender('values-size-small.yaml', 'allkeys-lru'));
  assert.equal(option(evicting.args, '--maxmemory-policy'), 'allkeys-lru');
  assert.throws(() => checkCeiling(evicting));
});
