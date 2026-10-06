import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

// How the service-provisioner serves a mariadb claim: from the consumer's own server in the claim's
// namespace (clusters/units/mariadb), with a user that owns that server and the databases the claim
// names. The functions are taken out of the rendered ConfigMap and run by themselves; nothing here
// opens a connection.
const rendered = execFileSync('helm', ['template', 'sp', 'clusters/inventories/service-provisioner', '--namespace', 'service-provisioner',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml', '-f', 'clusters/inventories/service-provisioner/values-common.yaml',
  '-f', 'clusters/inventories/service-provisioner/values-test.yaml', '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml'],
{encoding: 'utf8'});
const program = JSON.parse(execFileSync('yq', ['-o=json', '[select(.kind == "ConfigMap")][0].data | to_entries | map(select(.key | test("\\\\.py$")))[0].value', '-'],
  {encoding: 'utf8', input: rendered}));

const harness = `
import ast, json, sys
tree = ast.parse(sys.stdin.read())
names = ("_mariadb_ident", "_mariadb_statements", "_databases", "handle_mariadb")
fns = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name in names]
call, args = sys.argv[1], json.loads(sys.argv[2])
env = {"MARIADB_CRED_SECRET": "mariadb-credentials", "MARIADB_CRED_KEY": "root-password", "MARIADB_PORT": 3306,
       "read_secret_key": lambda core, ns, name, key: "root-pw"}
exec(compile(ast.Module(body=fns, type_ignores=[]), "provisioner", "exec"), env)
try:
    print(json.dumps(env[call](*args)))
except RuntimeError as e:
    print(json.dumps({"error": str(e)}))
`;
const run = (call, args) => JSON.parse(execFileSync('python3', ['-c', harness, call, JSON.stringify(args)], {input: program, encoding: 'utf8'}));

test('a mariadb claim\'s user owns the server and every database the claim names, re-stated on every pass', () => {
  assert.deepEqual(run('_mariadb_statements', ['acme_shop', 'pw', ['shop', 'shop_log']]), [
    ["CREATE USER IF NOT EXISTS %s@'%%' IDENTIFIED BY %s", ['acme_shop', 'pw']],
    ["ALTER USER %s@'%%' IDENTIFIED BY %s", ['acme_shop', 'pw']],
    ["GRANT ALL PRIVILEGES ON *.* TO %s@'%%' WITH GRANT OPTION", ['acme_shop']],
    ['CREATE DATABASE IF NOT EXISTS `shop`', []],
    ['CREATE DATABASE IF NOT EXISTS `shop_log`', []],
  ]);
});

test('PLANTED DEFECT: a database name cannot leave its backticks', () => {
  assert.equal(run('_mariadb_ident', ['we`ird']), '`we``ird`');
});

test('a mariadb claim naming no database is refused before any connection', () => {
  assert.match(run('handle_mariadb', [null, {}, 'acme-test', 'shop', 'acme_shop', 'pw', '']).error, /at least one database/);
});

test('the claim kind, its handler and its deprovisioner are known, and the client library is pinned', () => {
  const crd = JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(.kind == "CustomResourceDefinition")] | .[0].spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.service.enum'],
    {encoding: 'utf8', input: rendered}));
  assert.ok(crd.includes('mariadb'), crd.join(', '));
  assert.match(program, /"mariadb": handle_mariadb,/);
  assert.match(program, /"mariadb": deprovision_mariadb,/);
  assert.match(rendered, /PyMySQL==\d+\.\d+\.\d+/);
});
