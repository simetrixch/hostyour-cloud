import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

// Where the service-provisioner serves a redis claim from: a consumer's own server in the claim's own
// namespace where its credential stands there, else the cluster's shared one. The function is taken
// out of the rendered ConfigMap and run by itself, with the Secret reads stubbed.
const program = JSON.parse(execFileSync('yq', ['-o=json', '[select(.kind == "ConfigMap")][0].data | to_entries | map(select(.key | test("\\\\.py$")))[0].value', '-'], {
  encoding: 'utf8', input: execFileSync('helm', ['template', 'sp', 'clusters/inventories/service-provisioner', '--namespace', 'service-provisioner',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml', '-f', 'clusters/inventories/service-provisioner/values-common.yaml',
    '-f', 'clusters/inventories/service-provisioner/values-test.yaml', '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml'],
  {encoding: 'utf8'})}));

const harness = `
import ast, json, sys
source = sys.stdin.read()
tree = ast.parse(source)
fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_redis_admin")
secrets = json.loads(sys.argv[1])
env = {"REDIS_HOST": "redis-prod.redis.svc.cluster.local", "REDIS_PORT": "6379", "REDIS_CRED_NS": "redis",
       "REDIS_CRED_SECRET": "redis-credentials", "REDIS_CRED_KEY": "redis-password",
       "read_secret_key": lambda core, ns, name, key: secrets.get("%s/%s/%s" % (ns, name, key))}
exec(compile(ast.Module(body=[fn], type_ignores=[]), "_redis_admin", "exec"), env)
print(json.dumps(env["_redis_admin"](None, sys.argv[2])))
`;
const admin = (secrets, ns) => JSON.parse(execFileSync('python3', ['-c', harness, JSON.stringify(secrets), ns], {input: program, encoding: 'utf8'}));
const shared = {'redis/redis-credentials/redis-password': 'shared-pw'};

test('a claim in a namespace with its own Redis credential is served by that namespace\'s server', () => {
  assert.deepEqual(admin({...shared, 'acme-test/redis-credentials/redis-password': 'own-pw'}, 'acme-test'),
    ['redis.acme-test.svc.cluster.local', 6379, 'own-pw']);
});

test('a claim without one, and the shared server\'s own namespace, are served by the shared server', () => {
  assert.deepEqual(admin(shared, 'beta-test'), ['redis-prod.redis.svc.cluster.local', 6379, 'shared-pw']);
  assert.deepEqual(admin(shared, 'redis'), ['redis-prod.redis.svc.cluster.local', 6379, 'shared-pw']);
});
