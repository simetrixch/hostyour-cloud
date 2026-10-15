import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

// tenant-limits renders the chains a tenant's routes name. The render is read for what a route relies
// on, and then run: the same Middlewares are loaded into Traefik 3.6.2, the version the clusters run,
// through its file provider, whose fields are the CRD's, and visitors are told apart by their own
// loopback address (direct) or by the CF-Connecting-IP a proxy sets (proxied).

const CHART = 'clusters/inventories/tenant-limits';
const TRAEFIK = '3.6.2';
const USES = ['pages', 'forms', 'api', 'streams'];
const MODES = ['direct', 'proxied'];
const DROP = 'tenant-limits-direct-drop-cf-connecting-ip';
const NOT_STARTED = 'Traefik refused the render';
const yq = (args, input) => JSON.parse(execFileSync('yq', args, {encoding: 'utf8', ...(input ? {input} : {})}));
const app = yq(['-o=json', '.', `${CHART}/app.yaml`]);
// The values chain the platform appset hands every application (clusters/argocd/files/platform-apps-appset.yaml).
const render = (extra = []) => yq(['ea', '-o=json', '-I=0', '[.] | map(select(. != null and .kind != null))', '-'],
  execFileSync('helm', ['template', `${app.name}-prod`, CHART, '--namespace', app.namespace, '-f', 'clusters/platform/values-common.yaml',
    '-f', 'clusters/platform/values-prod.yaml', '-f', `${CHART}/values-common.yaml`, ...extra], {encoding: 'utf8', stdio: 'pipe'}));
const named = (docs, name) => docs.find(d => d.kind === 'Middleware' && d.metadata.name === name)?.spec;
/** The members of chain [name], each as its spec. */
const members = (docs, name) => (named(docs, name)?.chain?.middlewares ?? []).map(m => ({name: m.name, ...named(docs, m.name)}));

/** Every way the render fails a route that names a chain, without running it. */
function renderFindings(docs, application) {
  const found = [];
  if (application.namespace !== 'ingress') found.push(`the chains stand in ${application.namespace}, so ingress-tenant-…@kubernetescrd names nothing`);
  if (application.runsOn !== 'every-cluster') found.push(`the chains stand only on ${application.runsOn}`);
  for (const use of USES) for (const mode of MODES) {
    const chain = `tenant-${use}-limits-${mode}`;
    const parts = members(docs, chain);
    if (!parts.length) { found.push(`no chain ${chain}`); continue; }
    const rate = parts.find(p => p.rateLimit)?.rateLimit;
    const inFlight = parts.find(p => p.inFlightReq)?.inFlightReq;
    if (!(rate?.average > 0 && rate.burst >= rate.average)) found.push(`${chain} admits any rate`);
    if (!(inFlight?.amount > 0)) found.push(`${chain} admits any number of open requests`);
    const keys = [rate, inFlight].map(m => m?.sourceCriterion ?? {});
    if (mode === 'direct') {
      if (parts[0]?.headers?.customRequestHeaders?.['CF-Connecting-IP'] !== '') found.push(`${chain} passes on the CF-Connecting-IP a visitor sent`);
      if (keys.some(k => JSON.stringify(k) !== '{"ipStrategy":{"ipv6Subnet":64}}'))
        found.push(`${chain} counts by what the visitor sends, not by the connection`);
    } else if (keys.some(k => k.requestHeaderName !== 'CF-Connecting-IP')) found.push(`${chain} counts every visitor of one Cloudflare edge as one`);
    if (parts.some(p => p.name !== DROP && !p.name.startsWith(`${chain}-`))) found.push(`${chain} shares a bucket with another chain`);
  }
  return found;
}

const freePort = () => new Promise(done => { const s = net.createServer().listen(0, '127.0.0.1', () => { const {port} = s.address(); s.close(() => done(port)); }); });
const request = (port, path, {from = '127.0.0.1', cf, agent}) => new Promise(done => {
  const req = http.request({host: '127.0.0.1', port, path, localAddress: from, agent, headers: cf ? {'CF-Connecting-IP': cf} : {}}, res => {
    let body = ''; res.on('data', c => { body += c; }); res.on('end', () => done({status: res.statusCode, body}));
  });
  req.on('error', error => done({status: 0, body: error.message}));
  req.end();
});

/** Traefik 3.6.2 serving [docs] in front of a backend that echoes the CF-Connecting-IP it got and holds /hold open. */
async function serve(docs) {
  const held = [];
  const backend = http.createServer((req, res) => {
    const answer = () => res.end(JSON.stringify({cf: req.headers['cf-connecting-ip'] ?? null}));
    req.url.endsWith('/hold') ? held.push(answer) : answer();
  });
  const [backendPort, port] = [await freePort(), await freePort()];
  await new Promise(done => backend.listen(backendPort, '127.0.0.1', done));
  const middlewares = Object.fromEntries(docs.filter(d => d.kind === 'Middleware').map(d =>
    [d.metadata.name, d.spec.chain ? {chain: {middlewares: d.spec.chain.middlewares.map(m => m.name)}} : d.spec]));
  const chains = docs.filter(d => d.spec?.chain).map(d => d.metadata.name);
  const routers = Object.fromEntries([['ready', {rule: 'Path(`/ready`)', service: 'backend'}],
    ...chains.map(c => [c, {rule: `PathPrefix(\`/${c}\`)`, service: 'backend', middlewares: [c]}])]);
  const dir = mkdtempSync(join(tmpdir(), 'tenant-limits-'));
  writeFileSync(join(dir, 'dynamic.yaml'), JSON.stringify({http: {routers, middlewares,
    services: {backend: {loadBalancer: {servers: [{url: `http://127.0.0.1:${backendPort}`}]}}}}}));
  const traefik = spawn('traefik', [`--entryPoints.web.address=127.0.0.1:${port}`, `--providers.file.filename=${join(dir, 'dynamic.yaml')}`, '--log.level=ERROR'], {stdio: 'ignore'});
  for (let i = 0; i < 100 && (await request(port, '/ready', {})).status !== 200; i++) await new Promise(r => setTimeout(r, 100));
  return {port, held, chains, stop: () => { traefik.kill(); backend.closeAllConnections(); backend.close(); rmSync(dir, {recursive: true, force: true}); }};
}

/** Every way a running chain fails a visitor or lets one past its limits, named. */
async function runFindings(docs) {
  const found = [];
  const server = await serve(docs);
  try {
    if ((await request(server.port, '/ready', {})).status !== 200) return [NOT_STARTED];
    for (const [index, chain] of server.chains.entries()) {
      const [, use, mode] = chain.match(/^tenant-(\w+)-limits-(\w+)$/);
      const parts = members(docs, chain);
      const rate = parts.find(p => p.rateLimit)?.rateLimit ?? {average: 50, burst: 200};
      const amount = parts.find(p => p.inFlightReq)?.inFlightReq.amount ?? 100;
      // Who visitor n is: a loopback address of its own, or one address behind a proxy that names it.
      const visitor = n => mode === 'direct' ? {from: `127.0.${index + 1}.${n}`} : {cf: `198.51.${index}.${n}`};
      // A direct visitor sends a CF-Connecting-IP of its own, another on every request.
      const burst = async (n, count) => {
        const agent = new http.Agent({keepAlive: true, maxSockets: 10});
        const answers = await Promise.all(Array.from({length: count}, (_, i) => request(server.port, `/${chain}`, {...visitor(n), agent, ...(mode === 'direct' ? {cf: `203.0.113.${i % 250}`} : {})})));
        agent.destroy();
        return answers;
      };
      // A shared office, a sign-in and a page's navigation are a burst up to the limit from one visitor.
      const office = await burst(1, rate.burst);
      if (office.some(a => a.status !== 200)) found.push(`${chain}: a burst of ${rate.burst} from one visitor got ${[...new Set(office.map(a => a.status))]}`);
      if (mode === 'direct' && office.some(a => JSON.parse(a.body || '{}').cf !== null)) found.push(`${chain}: the backend got a CF-Connecting-IP`);
      const flood = await burst(2, rate.burst + 2 * rate.average + 50);
      if (!flood.some(a => a.status === 429)) found.push(`${chain}: ${flood.length} requests from one visitor got no 429`);
      if ((await request(server.port, `/${chain}`, visitor(3))).status !== 200) found.push(`${chain}: a second visitor is refused while the first floods`);
      // Open requests are counted where the rate admits enough of them at once; streams open slower than they may stay open.
      if (amount < rate.burst) {
        const open = Array.from({length: amount}, () => request(server.port, `/${chain}/hold`, visitor(4)));
        await new Promise(r => setTimeout(r, 300));
        if ((await request(server.port, `/${chain}`, visitor(4))).status !== 429) found.push(`${chain}: request ${amount + 1} of one visitor passes while ${amount} stand open`);
        if ((await request(server.port, `/${chain}`, visitor(5))).status !== 200) found.push(`${chain}: a second visitor is refused while the first holds ${amount} open`);
        server.held.splice(0).forEach(answer => answer());
        await Promise.all(open);
      } else if (use !== 'streams') found.push(`${chain}: ${amount} open requests are never reached at a burst of ${rate.burst}`);
    }
  } finally { server.stop(); }
  return found;
}

test('the eight chains stand on every cluster in ingress, each counting its own visitors by the trust its mode has', () => {
  assert.deepEqual(renderFindings(render(), app), []);
});

test(`Traefik ${TRAEFIK} answers 429 to one flooding visitor and serves a second, an office and a held stream`, async () => {
  assert.match(execFileSync('traefik', ['version'], {encoding: 'utf8'}), new RegExp(`Version:\\s+${TRAEFIK.replaceAll('.', '\\.')}\\n`),
    `traefik ${TRAEFIK} must be on the path, as ci-tools.json names it`);
  assert.deepEqual(await runFindings(render()), []);
});

test('PLANTED DEFECT: a chain that keeps the header, counts by the wrong key, or lacks a limit is caught; a value missing is refused', async () => {
  const docs = render();
  const change = edit => { const copy = structuredClone(docs); edit(copy); return copy; };
  const spec = (copy, name) => copy.find(d => d.metadata.name === name).spec;
  const planted = {
    'the direct chain keeps the header': change(c => { spec(c, 'tenant-forms-limits-direct').chain.middlewares.shift(); }),
    'direct counts by the header': change(c => { spec(c, 'tenant-api-limits-direct-rate').rateLimit.sourceCriterion = {requestHeaderName: 'CF-Connecting-IP'}; }),
    'proxied counts by the edge': change(c => { spec(c, 'tenant-pages-limits-proxied-rate').rateLimit.sourceCriterion = {ipStrategy: {ipv6Subnet: 64}}; }),
    'direct open requests counted per host': change(c => { delete spec(c, 'tenant-api-limits-direct-in-flight').inFlightReq.sourceCriterion; }),
    'no rate': change(c => { spec(c, 'tenant-streams-limits-proxied').chain.middlewares.splice(0, 1); }),
    'no in-flight': change(c => { spec(c, 'tenant-forms-limits-proxied').chain.middlewares.pop(); }),
  };
  for (const [name, copy] of Object.entries(planted)) {
    assert.notDeepEqual(renderFindings(copy, app), [], `render: ${name}`);
    const found = await runFindings(copy);
    assert.ok(found.length && !found.includes(NOT_STARTED), `run: ${name}: ${found}`);
  }
  assert.notDeepEqual(renderFindings(docs, {...app, runsOn: 'master'}), [], 'only on the master');
  assert.throws(() => render(['--set', 'tenantLimits.forms.burst=null']), /tenantLimits\.forms\.burst is required/);
});
