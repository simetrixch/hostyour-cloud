import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import net from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {renderLokiRules} from './render-loki-rules.mjs';

// A cluster whose ingress stops writing its access log is seen by IngressAccessLogMissing, a rule of the master's Loki
// ruler. What its expression answers is LogQL's, so this test asks Loki itself, the release the master runs, over planted
// streams, and reads the ConfigMap's rules as that ruler parses them. The streams carry the labels Alloy gives a Traefik
// pod's log; a slave's Alloy adds `cluster`, the master's adds none.
const SHIPPED_VERSION = '3.7.4';
const RULE = 'IngressAccessLogMissing';
const SECOND = 1000000000n;
const NOW = BigInt(Date.now()) * 1000000n;
// A line as Traefik 3.6.2 writes it with the access-log arguments of hostyour-deploy's deploy-cluster, and a line of its own log.
const ACCESS = '{"ClientAddr":"10.0.0.9:41090","DownstreamContentSize":11,"DownstreamStatus":200,"Duration":226709,"RouterName":"shop@kubernetescrd","ServiceName":"shop@kubernetescrd","level":"info","msg":"","time":"2026-10-15T23:08:34Z"}';
const OWN = '2026-10-15T23:08:34Z ERR error="the service is gone"';
const ingress = (cluster, level = 'info') => ({...(cluster ? {cluster} : {}), namespace: 'ingress', container: 'traefik', level});
// Each stream with its lines as [hours ago, line]. "fake" is the tenant the ruler reads; a second tenant holds a master
// whose ingress stopped, because the master's streams and the master's alert carry no cluster label to tell them apart.
const PLANTED = {
  fake: [
    [ingress('present.invalid'), [[20, ACCESS], [0.25, ACCESS]]],
    [ingress('stopped.invalid'), [[5, ACCESS]]],
    [ingress('stopped.invalid', '<no value>'), [[0.1, OWN]]],
    [ingress('elsewhere.invalid'), [[5, ACCESS]]],
    [{cluster: 'elsewhere.invalid', namespace: 'shop', container: 'web', level: 'info'}, [[0.1, ACCESS]]],
    [ingress(null), [[0.5, ACCESS]]],
  ],
  'master-stopped': [[ingress(null), [[5, ACCESS]]]],
};
const EXPECTED = {fake: ['elsewhere.invalid', 'stopped.invalid'], 'master-stopped': ['the master']};

const freePort = () => new Promise(done => { const s = net.createServer().listen(0, '127.0.0.1', () => { const {port} = s.address(); s.close(() => done(port)); }); });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const files = renderLokiRules().find(d => d.kind === 'ConfigMap' && d.metadata.name === 'loki-rules').data;
const rules = Object.values(files).flatMap(file => JSON.parse(execFileSync('yq', ['-o=json', '.groups'], {encoding: 'utf8', input: file})).flatMap(g => g.rules));
const folder = mkdtempSync(join(tmpdir(), 'ingress-access-log-alert-'));
let loki, output = '', base;

const ask = (path, tenant) => fetch(`${base}${path}`, {headers: {'X-Scope-OrgID': tenant}});
/** The clusters [expression] alerts on in [tenant] at the planted now, the master for a result without a cluster. */
async function alerted(expression, tenant) {
  const answer = await ask(`/loki/api/v1/query?${new URLSearchParams({query: expression, time: String(NOW)})}`, tenant);
  const body = await answer.json();
  assert.equal(body.status, 'success', JSON.stringify(body));
  return body.data.result.map(series => series.metric.cluster ?? 'the master').sort();
}

before(async () => {
  const rulesFolder = join(folder, 'rules', 'fake');
  mkdirSync(rulesFolder, {recursive: true});
  for (const [name, content] of Object.entries(files)) writeFileSync(join(rulesFolder, name), content);
  const [httpPort, grpcPort] = [await freePort(), await freePort()];
  base = `http://127.0.0.1:${httpPort}`;
  // One process with the ruler, as the master's single binary runs; every line stays in the ingester, which every query reads.
  writeFileSync(join(folder, 'loki.yaml'), JSON.stringify({
    auth_enabled: true,
    analytics: {reporting_enabled: false},
    server: {http_listen_address: '127.0.0.1', http_listen_port: httpPort, grpc_listen_address: '127.0.0.1', grpc_listen_port: grpcPort, log_level: 'warn'},
    common: {path_prefix: join(folder, 'data'), instance_addr: '127.0.0.1', replication_factor: 1, ring: {kvstore: {store: 'inmemory'}},
      storage: {filesystem: {chunks_directory: join(folder, 'data/chunks'), rules_directory: join(folder, 'data/rules')}}},
    schema_config: {configs: [{from: '2024-01-01', store: 'tsdb', object_store: 'filesystem', schema: 'v13', index: {prefix: 'index_', period: '24h'}}]},
    ingester: {max_chunk_age: '48h', chunk_idle_period: '48h', lifecycler: {min_ready_duration: '0s', final_sleep: '0s'}},
    querier: {query_ingesters_within: 0},
    ruler: {enable_api: true, rule_path: join(folder, 'data/rules-temp'), storage: {type: 'local', local: {directory: join(folder, 'rules')}}},
  }));
  loki = spawn('loki', [`-config.file=${join(folder, 'loki.yaml')}`], {stdio: ['ignore', 'pipe', 'pipe']});
  loki.stdout.on('data', chunk => { output += chunk; });
  loki.stderr.on('data', chunk => { output += chunk; });
  let ready = false;
  for (let tries = 0; tries < 120 && !ready && loki.exitCode === null; tries++) {
    ready = (await fetch(`${base}/ready`).catch(() => null))?.status === 200;
    if (!ready) await pause(500);
  }
  assert.ok(ready, `Loki never became ready:\n${output}`);
  for (const [tenant, streams] of Object.entries(PLANTED)) {
    const answer = await fetch(`${base}/loki/api/v1/push`, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Scope-OrgID': tenant},
      body: JSON.stringify({streams: streams.map(([stream, lines]) => ({stream,
        values: [...lines].sort(([a], [b]) => b - a).map(([hours, line]) => [String(NOW - BigInt(Math.round(hours * 3600)) * SECOND), line])}))})});
    assert.equal(answer.status, 204, await answer.text());
  }
});

after(async () => {
  if (loki && loki.exitCode === null) {
    loki.kill();
    await new Promise(resolve => loki.once('exit', resolve));
  }
  rmSync(folder, {recursive: true, force: true});
});

test(`the binary under test is Loki ${SHIPPED_VERSION}`, () => {
  assert.match(execFileSync('loki', ['--version'], {encoding: 'utf8'}), new RegExp(`^loki, version ${SHIPPED_VERSION.replaceAll('.', '\\.')} `));
});

test('the ruler parses every rule of the ConfigMap, and refuses a file it cannot parse', async () => {
  const answer = await ask('/loki/api/v1/rules', 'fake');
  const listed = await answer.text();
  assert.equal(answer.status, 200, listed);
  for (const rule of rules) assert.match(listed, new RegExp(`alert: ${rule.alert}\\n`), `the ruler does not list ${rule.alert}`);
  const broken = join(folder, 'rules', 'fake', 'broken.yaml');
  writeFileSync(broken, `groups:\n  - name: broken\n    rules:\n      - alert: Broken\n        expr: 'sum (count_over_time({namespace="ingress"} |= [1h]))'\n`);
  try {
    assert.equal((await ask('/loki/api/v1/rules', 'fake')).status, 400, 'PLANTED DEFECT: a rule Loki cannot parse is refused');
  } finally {
    rmSync(broken);
  }
});

test(`${RULE} names each ingress that wrote access lines in the last day and none in the last hour, the master's too`, async () => {
  const rule = rules.find(r => r.alert === RULE);
  assert.ok(rule, `no ${RULE} rule`);
  assert.equal(rule.labels?.severity, 'warning', 'platform-default routes every alert but severity=info');
  for (const tenant of Object.keys(PLANTED)) assert.deepEqual(await alerted(rule.expr, tenant), EXPECTED[tenant], `PLANTED INNOCENT and DEFECT: ${tenant}`);
});

test(`PLANTED DEFECT: an ${RULE} that misses a stopped stream, or names a running one, is caught`, async () => {
  const {expr} = rules.find(r => r.alert === RULE);
  const planted = {
    'no hour of silence asked for': expr.replace(/ unless .*$/, ''),
    'Traefik\'s own log counted as access lines': expr.replaceAll(' |= "\\"DownstreamStatus\\":"', ''),
    'every namespace read': expr.replaceAll('{namespace="ingress", container="traefik"}', '{namespace=~".+"}'),
    'not per cluster': expr.replaceAll('sum by (cluster)', 'sum'),
    'six hours of silence asked for': expr.replace('[1h]', '[6h]'),
  };
  for (const [name, wrong] of Object.entries(planted)) {
    assert.notEqual(wrong, expr, `the plant "${name}" changes nothing`);
    const answers = {};
    for (const tenant of Object.keys(PLANTED)) answers[tenant] = await alerted(wrong, tenant);
    assert.notDeepEqual(answers, EXPECTED, `PLANTED DEFECT: ${name}`);
  }
});
