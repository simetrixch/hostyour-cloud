import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

// Where the service-provisioner serves a redis claim from, and what it grants there: a consumer's own
// server in the claim's own namespace where its credential stands there, with every key and channel,
// else the cluster's shared one, with exactly the patterns the claim names. The functions are taken
// out of the rendered ConfigMap and run by themselves, with the Secret reads stubbed.
const program = JSON.parse(execFileSync('yq', ['-o=json', '[select(.kind == "ConfigMap")][0].data | to_entries | map(select(.key | test("\\\\.py$")))[0].value', '-'], {
  encoding: 'utf8', input: execFileSync('helm', ['template', 'sp', 'clusters/inventories/service-provisioner', '--namespace', 'service-provisioner',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml', '-f', 'clusters/inventories/service-provisioner/values-common.yaml',
    '-f', 'clusters/inventories/service-provisioner/values-test.yaml', '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml'],
  {encoding: 'utf8'})}));

const harness = `
import ast, json, sys
source = sys.stdin.read()
tree = ast.parse(source)
fns = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name in ("_redis_admin", "_redis_grant", "_key_patterns", "_channel_patterns")]
call, args = sys.argv[1], json.loads(sys.argv[2])
env = {"REDIS_HOST": "redis-prod.redis.svc.cluster.local", "REDIS_PORT": "6379", "REDIS_CRED_NS": "redis",
       "REDIS_CRED_SECRET": "redis-credentials", "REDIS_CRED_KEY": "redis-password",
       "read_secret_key": lambda core, ns, name, key: args[0].get("%s/%s/%s" % (ns, name, key))}
exec(compile(ast.Module(body=fns, type_ignores=[]), "provisioner", "exec"), env)
try:
    print(json.dumps(env[call](*([None] + args[1:] if call == "_redis_admin" else args))))
except RuntimeError as e:
    print(json.dumps({"error": str(e)}))
`;
const run = (call, args) => JSON.parse(execFileSync('python3', ['-c', harness, call, JSON.stringify(args)], {input: program, encoding: 'utf8'}));
const admin = (secrets, ns) => run('_redis_admin', [secrets, ns]);
const grant = (spec, own) => run('_redis_grant', [spec, own]);
const shared = {'redis/redis-credentials/redis-password': 'shared-pw'};

test('a claim in a namespace with its own Redis credential is served by that namespace\'s server', () => {
  assert.deepEqual(admin({...shared, 'acme-test/redis-credentials/redis-password': 'own-pw'}, 'acme-test'),
    ['redis.acme-test.svc.cluster.local', 6379, 'own-pw', true]);
});

test('a claim without one, and the shared server\'s own namespace, are served by the shared server', () => {
  assert.deepEqual(admin(shared, 'beta-test'), ['redis-prod.redis.svc.cluster.local', 6379, 'shared-pw', false]);
  assert.deepEqual(admin(shared, 'redis'), ['redis-prod.redis.svc.cluster.local', 6379, 'shared-pw', false]);
});

test('a claim on its own Redis gets every key and channel, and names none', () => {
  assert.deepEqual(grant({}, true), [['*'], ['*']]);
});

test('a claim on the shared server gets exactly its patterns, and one naming no key pattern is refused', () => {
  assert.deepEqual(grant({keyPatterns: ['acme:*'], channelPatterns: ['acme:notify:*']}, false), [['acme:*'], ['acme:notify:*']]);
  assert.match(grant({}, false).error, /at least one key pattern/);
});
