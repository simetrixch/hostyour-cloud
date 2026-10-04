import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const render = stage => execFileSync('helm', ['template', 'redis', 'clusters/inventories/redis', '--namespace', 'redis',
  '--api-versions', 'monitoring.coreos.com/v1', '--api-versions', 'monitoring.coreos.com/v1alpha1',
  '-f', 'clusters/platform/values-common.yaml', '-f', `clusters/platform/values-${stage}.yaml`,
  '-f', 'clusters/inventories/redis/values-common.yaml', '-f', `clusters/inventories/redis/values-${stage}.yaml`,
  '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml',
  '-f', 'scripts/standin/registration.yaml'], {encoding: 'utf8'});
const server = stage => JSON.parse(execFileSync('yq', ['-o=json',
  'select(.kind == "Deployment" and .metadata.name == "redis") | .spec.template.spec.containers[] | select(.name == "redis")', '-'],
  {input: render(stage), encoding: 'utf8'}));

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
  assert.ok(redisBytes(ceiling) < kubernetesBytes(resources.limits.memory),
    `--maxmemory ${ceiling} is not below the container's memory limit ${resources.limits.memory}`);
  assert.equal(option(args, '--maxmemory-policy'), 'noeviction');
};
const prod = server('prod');

test('the shared Redis of every stage runs under a ceiling below its memory limit, with noeviction', () => {
  for (const stage of ['dev', 'test', 'prod']) checkCeiling(server(stage));
});

test('a missing, unlimited or too high ceiling and an evicting or unstated policy are refused', () => {
  const withArgs = change => ({...prod, args: change([...prod.args])});
  const setOption = (name, value) => args => { args[args.indexOf(name) + 1] = value; return args; };
  const dropOption = name => args => { args.splice(args.indexOf(name), 2); return args; };
  for (const planted of [dropOption('--maxmemory'), setOption('--maxmemory', '0'), setOption('--maxmemory', '6gb'),
    setOption('--maxmemory', '7g'), setOption('--maxmemory-policy', 'allkeys-lru'),
    setOption('--maxmemory-policy', 'volatile-lru'), dropOption('--maxmemory-policy')]) {
    assert.throws(() => checkCeiling(withArgs(planted)));
  }
  checkCeiling(withArgs(setOption('--maxmemory', '1024mb')));
});
