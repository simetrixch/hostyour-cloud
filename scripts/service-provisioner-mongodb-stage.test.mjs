import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

// Which MongoDB databases the service-provisioner serves a claim under, and which it drops. On the
// cluster's SHARED replica set, two stages of one consumer must never share a database: a PROD worker
// would deliver what its TEST stage queued, because both would read one collection. A database that
// leaves a claim's list goes only with the claim's drop mark. The functions are taken out of the
// rendered ConfigMap and run against a stand-in pymongo that records what they ask of the server and
// answers usersInfo from the grants the case configures; nothing connects.
const rendered = execFileSync('helm', ['template', 'sp', 'clusters/inventories/service-provisioner', '--namespace', 'service-provisioner',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml', '-f', 'clusters/inventories/service-provisioner/values-common.yaml',
  '-f', 'clusters/inventories/service-provisioner/values-test.yaml', '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml'],
{encoding: 'utf8'});
const program = JSON.parse(execFileSync('yq', ['-o=json', '[select(.kind == "ConfigMap")][0].data | to_entries | map(select(.key | test("\\\\.py$")))[0].value'],
  {encoding: 'utf8', input: rendered}));

const harness = `
import ast, json, sys, types
calls = []
logs = []
users = {}
class OperationFailure(Exception):
    def __init__(self, msg, code=None):
        super().__init__(msg); self.code = code
class _Db:
    def __init__(self, name): self.name = name
    def command(self, *a, **k):
        if a[0] == "usersInfo":
            # The grants the user holds on the stand-in server, next to a role the provisioner never reads.
            return {"users": [{"user": a[1], "roles": [{"role": "readWrite", "db": d} for d in users[a[1]]] + [{"role": "clusterMonitor", "db": "admin"}]}] if a[1] in users else []}
        calls.append([self.name] + [str(x) for x in a] + ([k["roles"]] if "roles" in k else []))
class MongoClient:
    def __init__(self, *a, **k): pass
    def __getitem__(self, name): return _Db(name)
    def close(self): pass
pymongo = types.ModuleType("pymongo"); pymongo.MongoClient = MongoClient
errors = types.ModuleType("pymongo.errors"); errors.OperationFailure = OperationFailure
sys.modules["pymongo"] = pymongo; sys.modules["pymongo.errors"] = errors

tree = ast.parse(sys.stdin.read())
fns = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name in (
    "_databases", "_served_databases", "_extra_roles", "_mongo_backend", "_mongo_uri", "_replica_set_of",
    "handle_mongodb", "_drop_left_databases", "deprovision_mongodb", "read_secret_key", "describe_orphans", "deprovision", "deletion_age_seconds", "sanitize")]
consts = [n for n in ast.walk(tree) if isinstance(n, ast.Assign) and any(getattr(t, "id", "") in ("CONSUMER_STAGE_LABEL", "CONSUMER_LABEL") for t in n.targets)]
call, ns, labels, own, opts = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4], json.loads(sys.argv[5])

class _Meta:
    def __init__(self, labels): self.labels = labels
class _Ns:
    def __init__(self, labels): self.metadata = _Meta(labels)
class Core:
    def read_namespace(self, name): return _Ns(labels)
env = {"MONGO_CRED_NS": "mongodb", "MONGO_CRED_SECRET": "mongodb-credentials", "MONGO_CRED_KEY": "root-password",
       "MONGO_HOST": "mongodb.mongodb.svc.cluster.local", "MONGO_REPLICA_SET": "rs0", "MONGO_ROOT_USER": "root",
       "MONGO_AUTH_SOURCE": "admin",
       "log": types.SimpleNamespace(info=lambda fmt, *a: logs.append(fmt % a), error=lambda fmt, *a: logs.append(fmt % a))}
def relocation_held(core, n):
    if opts.get("holdReadFails"): raise RuntimeError("namespace read refused")
    return bool(opts.get("relocating"))
env["read_secret_key"] = lambda core, n, s, k: ("own-pw" if own == "own" and n == ns else ("root-pw" if n == "mongodb" and own != "unreadable" else None))
env["_replica_set_of"] = lambda host, pw: None
from urllib.parse import quote_plus
import re
from datetime import datetime, timezone
env.update({"quote_plus": quote_plus, "re": re, "datetime": datetime, "timezone": timezone, "MAX_DELETION_ATTEMPTS": 3,
            "MAX_DELETION_SECONDS": 600, "FORCE_RELEASE_ANNOTATION": "force-release", "relocation_held": relocation_held,
            "delete_own_secret": lambda core, n, name: None})
exec(compile(ast.Module(body=consts + [f for f in fns if f.name not in ("read_secret_key", "_replica_set_of")], type_ignores=[]), "provisioner", "exec"), env)
spec = {"databases": opts.get("databases", ["digita_post"])}
if "drop" in opts: spec["_drop"] = opts["drop"]
users.update({"user1": opts["granted"]} if "granted" in opts else {})
recorded = {}
def failing_teardown(core, spec, ns, name, user, prefix):
    raise RuntimeError("the shared set is busy")
env["DEPROVISIONERS"] = {"mongodb": failing_teardown}
env["set_delete_status"] = lambda custom, n, name, phase, attempts, orphans, msg, gen: recorded.update(orphans=orphans)
if call == "orphans":
    claim = {"metadata": {"namespace": ns, "name": "mongodb", "generation": 1, "finalizers": ["x"]}, "spec": dict(spec, service="mongodb", secretName="s")}
    env["deprovision"](Core(), None, claim)
    print(json.dumps({"orphans": [o for o in recorded["orphans"] if o.startswith("mongo:db:")]}))
elif call == "handle":
    try:
        out, *_ = env["handle_mongodb"](Core(), spec, ns, "mongodb", "user1", "pw1", "")
    except RuntimeError as e:
        print(json.dumps({"error": str(e)})); sys.exit(0)
    print(json.dumps({"databases": out["MONGODB_DATABASES"], "uri_db": out["MONGODB_URI"].split("/")[3].split("?")[0], "roles": calls[0][-1]}))
elif call == "update":
    error = None
    try:
        env["handle_mongodb"](Core(), spec, ns, "mongodb", "user1", opts["password"], "")
    except RuntimeError as e:
        error = str(e)
    print(json.dumps({"error": error, "dropped": [c[0] for c in calls if "dropDatabase" in c], "logs": logs,
                      "updated": [c[-1] for c in calls if "updateUser" in c], "created": any("createUser" in c for c in calls)}))
else:
    env["deprovision_mongodb"](Core(), spec, ns, "mongodb", "user1", "")
    print(json.dumps({"dropped": [c[0] for c in calls if "dropDatabase" in c]}))
`;
const run = (call, ns, labels, own = 'shared', opts = {}) =>
  JSON.parse(execFileSync('python3', ['-c', harness, call, ns, JSON.stringify(labels), own, JSON.stringify(opts)], {input: program, encoding: 'utf8'}));
const consumer = (stage) => ({'hostyour.cloud/consumer': 'true', 'hostyour.cloud/consumer-name': 'digita-post', 'hostyour.cloud/consumer-stage': stage});

test('PLANTED: a TEST consumer on the shared replica set is served <name>_test, in its roles, its Secret and its URI', () => {
  assert.deepEqual(run('handle', 'digita-post-test', consumer('test')),
    {databases: 'digita_post_test', uri_db: 'digita_post_test', roles: [{role: 'readWrite', db: 'digita_post_test'}]});
});

test('teardown of a TEST consumer drops the database it was served, never the PROD one', () => {
  assert.deepEqual(run('deprovision', 'digita-post-test', consumer('test')), {dropped: ['digita_post_test']});
});

test('PROD keeps the literal name on the shared replica set', () => {
  assert.deepEqual(run('handle', 'digita-post-prod', consumer('prod')).databases, 'digita_post');
});

test('an own server, a tenant namespace and an unlabelled namespace keep the literal name', () => {
  assert.equal(run('handle', 'digita-post-test', consumer('test'), 'own').databases, 'digita_post');
  assert.equal(run('handle', 'ak64h58875qw-auth-test', {'platform/tenant': 'ak64h58875qw', 'platform/tenant-stage': 'test'}).databases, 'digita_post');
  assert.equal(run('handle', 'other', {}).databases, 'digita_post');
});

test('PLANTED: a failed TEST teardown lists the database it was served, never the PROD one', () => {
  assert.deepEqual(run('orphans', 'digita-post-test', consumer('test')), {orphans: ['mongo:db:digita_post_test']});
});

test('where the served names cannot be read, the orphan list says so instead of naming the literal database', () => {
  const {orphans} = run('orphans', 'digita-post-test', consumer('test'), 'unreadable');
  assert.equal(orphans.length, 1);
  assert.match(orphans[0], /^mongo:db:<undetermined/);
  assert.ok(!orphans.includes('mongo:db:digita_post'));
});

test('PLANTED: a consumer namespace without its stage label is served nothing', () => {
  const {error} = run('handle', 'digita-post-x', {'hostyour.cloud/consumer': 'true', 'hostyour.cloud/consumer-name': 'digita-post'});
  assert.match(error, /carries no hostyour.cloud\/consumer-stage label/);
});

test('teardown on an own server drops the literal name', () => {
  assert.deepEqual(run('deprovision', 'digita-post-test', consumer('test'), 'own'), {dropped: ['digita_post']});
});

test('a failed teardown on an own server lists the literal database it was served', () => {
  assert.deepEqual(run('orphans', 'digita-post-test', consumer('test'), 'own'), {orphans: ['mongo:db:digita_post']});
});

// A claim that stands in a tenant namespace, whose database names carry the stage already and stay literal.
const tenant = {'platform/tenant': 'acme', 'platform/tenant-stage': 'prod'};
const password = 'p+ss/w0rd=never-in-a-log';
const [tenantDb, eventsDb, workshopDb] = ['acme_tenant_prod', 'acme_events_prod', 'acme_workshop_prod'];
// One pass of the provisioner over a claim whose user holds `granted` and whose list is now `databases`.
const update = (opts, ns = 'acme-prod', labels = tenant) => run('update', ns, labels, 'shared', {password, ...opts});
const eventsLeft = {granted: [tenantDb, eventsDb], databases: [tenantDb, workshopDb]};
const rolesOf = roles => roles.map(({db}) => db).sort();

test('a database that left the list with the drop mark is dropped, and the one that joined is granted', () => {
  const result = update({...eventsLeft, drop: eventsDb});
  assert.deepEqual(result.dropped, [eventsDb]);
  assert.deepEqual(result.updated.map(rolesOf), [[tenantDb, workshopDb]]);
  assert.ok(result.updated[0].every(({role}) => role === 'readWrite'));
  assert.equal(result.created, false);
  assert.ok(result.logs.includes(`dropped database ${eventsDb} of claim acme-prod/mongodb: it left the list with the drop mark`));
});

test('PLANTED: a database that left the list without the drop mark is kept and logged as an orphan', () => {
  const result = update(eventsLeft);
  assert.deepEqual(result.dropped, []);
  assert.deepEqual(result.updated.map(rolesOf), [[tenantDb, workshopDb]]);
  assert.ok(result.logs.includes(`orphan database ${eventsDb} of claim acme-prod/mongodb: it left the list without the drop mark; kept`));
  assert.deepEqual(update({...eventsLeft, drop: workshopDb}).dropped, [], 'a mark on another name drops nothing');
});

test('a marked database that stays in the list, or that was never granted, is not dropped', () => {
  assert.deepEqual(update({granted: [tenantDb, eventsDb], databases: [tenantDb, eventsDb], drop: eventsDb}).dropped, []);
  assert.deepEqual(update({granted: [tenantDb], databases: [tenantDb], drop: 'acme_never_prod'}).dropped, []);
});

test('a mark is read like the list: a TEST consumer on the shared set drops the <name>_test it was served', () => {
  const result = update({granted: ['digita_post_test'], databases: ['digita_other'], drop: 'digita_post'}, 'digita-post-test', consumer('test'));
  assert.deepEqual(result.dropped, ['digita_post_test']);
  assert.deepEqual(update({granted: ['digita_post'], databases: ['digita_other'], drop: 'digita_post'}, 'digita-post-prod', consumer('prod')).dropped, ['digita_post']);
});

test('while the namespace is relocating nothing is dropped, the grant stays, and the next pass after the hold drops it', () => {
  const held = update({...eventsLeft, databases: [tenantDb], drop: eventsDb, relocating: true});
  assert.deepEqual(held.dropped, []);
  assert.ok(held.logs.includes(`drop of ${eventsDb} held: namespace acme-prod is relocating`));
  assert.deepEqual(held.updated.map(rolesOf), [[eventsDb, tenantDb]]);
  const next = update({granted: held.updated[0].map(({db}) => db), databases: [tenantDb], drop: eventsDb});
  assert.deepEqual(next.dropped, [eventsDb]);
  assert.deepEqual(next.updated.map(rolesOf), [[tenantDb]]);
});

test('a failed read of the relocation hold drops nothing and fails the claim', () => {
  const result = update({...eventsLeft, drop: eventsDb, holdReadFails: true});
  assert.equal(result.error, 'namespace read refused');
  assert.deepEqual(result.dropped, []);
  assert.deepEqual(result.updated, []);
});

test('a user that does not exist yet is created and nothing is dropped', () => {
  const result = update({databases: [tenantDb, workshopDb], drop: eventsDb});
  assert.deepEqual(result.dropped, []);
  assert.equal(result.created, true);
  assert.deepEqual(result.updated, []);
});

test('no log line names the password', () => {
  const lines = [update({...eventsLeft, drop: eventsDb}), update(eventsLeft), update({...eventsLeft, drop: eventsDb, relocating: true})].flatMap(({logs}) => logs);
  assert.ok(lines.some(line => line.includes('dropped database')));
  assert.ok(lines.every(line => !line.includes(password)));
});
