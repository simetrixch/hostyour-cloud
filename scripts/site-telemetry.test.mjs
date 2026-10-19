import assert from 'node:assert/strict';
import {generateKeyPairSync, sign} from 'node:crypto';
import {spawn} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {createServer} from 'node:http';
import {createServer as createSocketServer} from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {fileURLToPath} from 'node:url';

// The read API of the site statistics is a permission gate in front of the visitors of every tenant.
// It runs here as a process, against a stand-in Kubernetes API (the registrations), a stand-in Loki
// (the ingress log and the sign-in failures) and a stand-in identity provider (the key sets), so the
// gate under test is the one the pod runs. Each way the gate can be opened is planted into a copy of
// the source and must open it.
const SOURCE = fileURLToPath(new URL('../clusters/inventories/observability/files/site_telemetry.py', import.meta.url));
const NOW = Date.now();
const minutesAgo = minutes => NOW - minutes * 60000;
const keys = {shop: generateKeyPairSync('rsa', {modulusLength: 2048}), other: generateKeyPairSync('rsa', {modulusLength: 2048})};
const encode = value => Buffer.from(typeof value === 'string' ? value : JSON.stringify(value)).toString('base64url');

function token({tenantKey = keys.shop, host = 'shop.example.test', roles, typ = 'access', expires = NOW / 1000 + 600, alg = 'RS256', kid = 'k1'}) {
  const input = `${encode({alg, kid, typ: 'JWT'})}.${encode({iss: `https://${host}/auth`, typ, roles, exp: expires, sub: 'someone'})}`;
  return `${input}.${sign('RSA-SHA256', Buffer.from(input), tenantKey.privateKey).toString('base64url')}`;
}

const REGISTRATIONS = [
  {tenant: 'aaaa-prod', hosts: ['shop.example.test', 'www.shop.example.test'], issuers: ['shop.example.test'], proxiedHosts: [],
    sites: [{name: 'main', sitePath: '/', main: true}, {name: 'secondary', sitePath: '/web/secondary', main: false}]},
  {tenant: 'bbbb-prod', hosts: ['other.example.test'], issuers: ['other.example.test'], proxiedHosts: [],
    sites: [{name: 'main', sitePath: '/', main: true}]},
  {tenant: 'cccc-prod', hosts: ['edge.example.test'], issuers: ['edge.example.test'], proxiedHosts: ['edge.example.test'],
    sites: [{name: 'main', sitePath: '/', main: true}]},
];

const CHROME = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';
const PHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
function access({minutes, host = 'shop.example.test', tenant = 'aaaa-prod', router = 'digita-web', path = '/', status = 200, address = '203.0.113.7:51000', agent = CHROME, referer, country = 'CH'}) {
  const line = {ClientAddr: address, RouterName: `${tenant}-${router}-${host}@kubernetes`, ServiceName: `${tenant}-${router}-3001@kubernetes`,
    DownstreamStatus: status, Duration: 1, DownstreamContentSize: 10, RequestHost: host, RequestPath: path,
    'request_User-Agent': agent, 'request_Accept-Language': 'de-CH'};
  if (referer) line['request_Referer'] = referer;
  if (country) line['request_Cf-Ipcountry'] = country;
  return [minutesAgo(minutes), JSON.stringify(line)];
}
function failure({minutes, site = 'main', category = 'login_failed', service = 'digita-auth', namespace = 'aaaa-prod'}) {
  return [namespace, minutesAgo(minutes), JSON.stringify({level: 'info', service, type: 'site_attack', site, category, action: 'blocked', statusCode: 401, path: '/auth/api/v1/auth/login', ipHash: 'a1b2c3d4e5f6', country: 'CH'})];
}

const TRAFFIC = [
  access({minutes: 180, path: '/?token=SECRETTOKEN', referer: 'https://news.example.org/story'}),
  access({minutes: 175, path: '/angebote'}),
  access({minutes: 100, path: '/angebote'}),
  access({minutes: 90, path: '/', address: '198.51.100.9:40000', agent: PHONE, country: 'DE'}),
  access({minutes: 80, path: '/web/secondary/blog'}),
  access({minutes: 70, path: '/_next/static/chunk.js'}),
  access({minutes: 70, path: '/api/health'}),
  access({minutes: 70, path: '/', agent: 'kube-probe/1.31'}),
  access({minutes: 60, path: '/missing', status: 404}),
  access({minutes: 50, path: '/.env', status: 404, address: '192.0.2.50:1000'}),
  access({minutes: 40, path: '/', status: 429, address: '192.0.2.51:1000'}),
  access({minutes: 30, path: '/api/contact', status: 403, address: '192.0.2.52:1000'}),
  access({minutes: 30, path: '/', router: 'digita-auth'}),
  access({minutes: 20, host: 'other.example.test', tenant: 'bbbb-prod', path: '/foreign'}),
  access({minutes: 20, host: 'evil.example.test', path: '/spoofed-host'}),
  access({minutes: 20, host: 'edge.example.test', tenant: 'cccc-prod', path: '/behind-the-edge'}),
];
const FAILURES = [failure({minutes: 45}), failure({minutes: 44, site: 'secondary'}), failure({minutes: 43, service: 'imposter'}), failure({minutes: 42, namespace: 'bbbb-prod'})];

const listen = handler => new Promise(resolve => { const server = createServer(handler).listen(0, '127.0.0.1', () => resolve(server)); });
const freePort = () => new Promise(resolve => { const server = createSocketServer().listen(0, '127.0.0.1', () => { const {port} = server.address(); server.close(() => resolve(port)); }); });
const json = (response, body) => { response.setHeader('content-type', 'application/json'); response.end(JSON.stringify(body)); };

let folder;
const servers = [];
let urls;
before(async () => {
  folder = mkdtempSync(join(tmpdir(), 'site-telemetry-'));
  writeFileSync(join(folder, 'token'), 'service-account-token');
  const kubernetes = await listen((request, response) => {
    assert.equal(request.headers.authorization, 'Bearer service-account-token');
    assert.match(request.url, /^\/api\/v1\/namespaces\/observability\/configmaps\?labelSelector=platform%2Fsite-telemetry-registration%3Dtrue$/);
    json(response, {items: REGISTRATIONS.map(facts => ({data: {'registration.json': JSON.stringify(facts)}})).concat([{data: {'registration.json': 'not json'}}])});
  });
  const loki = await listen((request, response) => {
    const query = new URL(request.url, 'http://x').searchParams.get('query');
    const values = query.includes('container="traefik"')
      ? TRAFFIC.map(([stamp, line]) => [String(BigInt(stamp) * 1000000n), line])
      : FAILURES.filter(([namespace]) => query.includes(`namespace="${namespace}"`)).map(([, stamp, line]) => [String(BigInt(stamp) * 1000000n), line]);
    json(response, {status: 'success', data: {result: [{stream: {}, values}]}});
  });
  const jwk = key => ({kty: 'RSA', kid: 'k1', alg: 'RS256', ...key.publicKey.export({format: 'jwk'})});
  const identity = await listen((request, response) => {
    const host = request.url.split('/')[1];
    json(response, {keys: [jwk(host === 'shop.example.test' ? keys.shop : keys.other)]});
  });
  servers.push(kubernetes, loki, identity);
  urls = {kubernetes: `http://127.0.0.1:${kubernetes.address().port}`, loki: `http://127.0.0.1:${loki.address().port}`, identity: `http://127.0.0.1:${identity.address().port}`};
});
after(() => { servers.forEach(server => server.close()); rmSync(folder, {recursive: true, force: true}); });

/** Starts the service from [source] and runs [use] against it. */
async function serving(source, use) {
  const port = await freePort();
  const child = spawn('python3', ['-I', source], {stdio: ['ignore', 'ignore', 'pipe'], env: {
    POD_NAMESPACE: 'observability', LISTEN_PORT: String(port), KUBERNETES_API_URL: urls.kubernetes, KUBERNETES_TOKEN_FILE: join(folder, 'token'),
    LOKI_URL: urls.loki, JWKS_URL_TEMPLATE: `${urls.identity}/{host}/jwks.json`, CACHE_SECONDS: '0', PATH: process.env.PATH}});
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  try {
    for (let tries = 0; ; tries++) {
      const ready = await fetch(`http://127.0.0.1:${port}/healthz`).then(answer => answer.ok, () => false);
      if (ready) break;
      assert.ok(tries < 100, `the service never answered:\n${stderr}`);
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    return await use(async (kind, query, bearer, extra = {}) => {
      const parameters = new URLSearchParams({tenant: 'aaaa-prod', site: 'main', range: '24h', ...query});
      const answer = await fetch(`http://127.0.0.1:${port}/api/v1/site-telemetry/${kind}?${parameters}`, {headers: {...(bearer ? {authorization: `Bearer ${bearer}`} : {}), ...extra}});
      return {status: answer.status, text: await answer.text(), headers: answer.headers};
    });
  } finally {
    child.kill();
    await new Promise(resolve => child.once('exit', resolve));
  }
}
const read = (kind, query, bearer, extra) => serving(SOURCE, ask => ask(kind, query, bearer, extra));
const mutated = (from, to) => {
  const source = readFileSync(SOURCE, 'utf8');
  assert.equal(source.split(from).length, 2, `${from} stands once in the service`);
  const copy = join(folder, `mutated-${Math.random().toString(36).slice(2)}.py`);
  writeFileSync(copy, source.replace(from, to));
  return copy;
};
const admin = {roles: ['Administrator']};

test('a caller without a valid tenant token is refused with 403 Forbidden', async () => {
  const refused = [
    ['no token', undefined],
    ['a token of another key', token({...admin, tenantKey: keys.other})],
    ['an expired token', token({...admin, expires: NOW / 1000 - 3600})],
    ['a refresh token', token({...admin, typ: 'refresh'})],
    ['an unsigned token', token({...admin, alg: 'none'})],
    ['an issuer the registration does not name', token({...admin, host: 'evil.example.test'})],
    ['a role of no administrator', token({roles: ['System User']})],
    ['roles that are no list', token({roles: 'Administrator'})],
  ];
  await serving(SOURCE, async ask => {
    for (const [name, bearer] of refused) {
      const answer = await ask('visitors', {}, bearer);
      assert.deepEqual([name, answer.status, JSON.parse(answer.text)], [name, 403, {error: 'forbidden'}]);
    }
    assert.equal((await ask('visitors', {tenant: 'zzzz-prod'}, token(admin))).status, 403, 'a tenant no registration names');
    assert.equal((await ask('visitors', {tenant: 'aaaa-prod; drop'}, token(admin))).status, 403, 'a tenant that is no name');
  });
});

test('a token of one tenant reaches nothing of another tenant', async () => {
  await serving(SOURCE, async ask => {
    assert.equal((await ask('visitors', {tenant: 'bbbb-prod'}, token(admin))).status, 403, 'the token of aaaa-prod asks for bbbb-prod');
    assert.equal((await ask('security', {tenant: 'bbbb-prod'}, token(admin))).status, 403);
    assert.equal((await ask('visitors', {tenant: 'bbbb-prod'}, token({...admin, tenantKey: keys.other, host: 'other.example.test'}))).status, 200, 'its own token');
  });
});

test('an administrator of one website reads that website and not another; a tenant administrator reads both', async () => {
  await serving(SOURCE, async ask => {
    const secondary = token({roles: ['secondary:Administrator']});
    for (const kind of ['visitors', 'security']) {
      assert.equal((await ask(kind, {site: 'main'}, secondary)).status, 403, `${kind} of main for secondary:Administrator`);
      assert.equal((await ask(kind, {site: 'secondary'}, secondary)).status, 200, `${kind} of secondary for secondary:Administrator`);
      for (const site of ['main', 'secondary']) assert.equal((await ask(kind, {site}, token(admin))).status, 200, `${kind} of ${site} for Administrator`);
    }
    assert.equal((await ask('visitors', {site: 'nothing'}, token(admin))).status, 404);
    assert.equal((await ask('visitors', {site: 'nothing'}, token({roles: ['main:Administrator']}))).status, 403, 'an unknown website is no way to learn what exists');
  });
});

test('PLANTED DEFECT: each way to open the gate is found', async () => {
  const secondary = token({roles: ['secondary:Administrator']});
  const planted = {
    'the role check is gone': [mutated('if "Administrator" not in roles and f"{site}:Administrator" not in roles:', 'if False:'), 'visitors', {site: 'main'}, secondary],
    'any administrator role suffices': [mutated('f"{site}:Administrator" not in roles', 'not any(r.endswith(":Administrator") for r in roles)'), 'visitors', {site: 'main'}, secondary],
    'the signature is not checked': [mutated('or not verify_rs256(', 'or False and not verify_rs256('), 'visitors', {}, token({...admin, tenantKey: keys.other})],
    'the issuer is not bound to the tenant': [mutated(' or host not in facts["issuers"]', ''), 'visitors', {tenant: 'bbbb-prod'}, token(admin)],
    'a refresh token is accepted': [mutated('or claims["typ"] != "access"', ''), 'visitors', {}, token({...admin, typ: 'refresh'})],
    'an expired token is accepted': [mutated('claims["exp"] < time.time() - 30', 'False'), 'visitors', {}, token({...admin, expires: NOW / 1000 - 3600})],
  };
  for (const [name, [source, kind, query, bearer]] of Object.entries(planted)) {
    const answer = await serving(source, ask => ask(kind, query, bearer));
    assert.equal(answer.status, 200, `${name}: the planted copy answers`);
    assert.equal((await serving(SOURCE, ask => ask(kind, query, bearer))).status, 403, `${name}: the real service refuses`);
  }
});

test('visitors: pages, visits and sources of the site, and nothing a caller can use against the visitor', async () => {
  const answer = await read('visitors', {}, token(admin));
  const body = JSON.parse(answer.text);
  assert.equal(answer.status, 200);
  assert.deepEqual(body.kpis, {uniqueVisitors: 2, visits: 3, pageviews: 4, bounceRate: 2 / 3});
  assert.deepEqual(body.topPages, [{key: '/', count: 2}, {key: '/angebote', count: 2}]);
  assert.deepEqual(body.referrers, [{key: 'news.example.org', count: 1}]);
  assert.deepEqual(body.countries, [{key: 'CH', count: 3}, {key: 'DE', count: 1}]);
  assert.deepEqual(body.devices, [{key: 'desktop', count: 3}, {key: 'mobile', count: 1}]);
  assert.deepEqual(body.browsers, [{key: 'Chrome', count: 3}, {key: 'Safari', count: 1}]);
  assert.deepEqual(body.operatingSystems, [{key: 'Windows', count: 3}, {key: 'iOS', count: 1}]);
  assert.equal(body.requests.total, 4);
  assert.ok(body.requests.items.every(item => /^[0-9a-f]{12}$/.test(item.ipHash)));
  assert.doesNotMatch(answer.text, /SECRETTOKEN|\?token|203\.0\.113|198\.51\.100/, 'no query string and no raw address leaves the service');
  assert.doesNotMatch(answer.text, /foreign|spoofed-host|behind-the-edge|\/web\/secondary/, 'no other tenant, host or website');
});

test('visitors: a filter narrows every figure, and another website counts its own pages', async () => {
  const filtered = JSON.parse((await read('visitors', {country: 'DE', device: 'mobile'}, token(admin))).text);
  assert.equal(filtered.kpis.pageviews, 1);
  assert.deepEqual(filtered.topPages, [{key: '/', count: 1}]);
  const secondary = JSON.parse((await read('visitors', {site: 'secondary'}, token(admin))).text);
  assert.deepEqual(secondary.topPages, [{key: '/web/secondary/blog', count: 1}]);
  const page = JSON.parse((await read('visitors', {pageSize: '2', page: '2'}, token(admin))).text);
  assert.deepEqual([page.requests.items.length, page.requests.total], [2, 4]);
});

test('visitors: behind the edge no visitor can be told from another, so no figure of visitors is claimed', async () => {
  const body = JSON.parse((await read('visitors', {tenant: 'cccc-prod'}, token({...admin, tenantKey: keys.other, host: 'edge.example.test'}))).text);
  assert.equal(body.kpis.pageviews, 1);
  assert.deepEqual([body.kpis.uniqueVisitors, body.kpis.visits, body.kpis.bounceRate], [null, null, null]);
});

test('security: scanner probes, blocked requests and sign-in failures of the site', async () => {
  const answer = await read('security', {}, token(admin));
  const body = JSON.parse(answer.text);
  assert.equal(answer.status, 200);
  assert.deepEqual(body.kpis, {blockedAttacks: 4, scannerProbes: 1, botFormBlocks: 2, signInFailures: 1});
  assert.deepEqual(body.categories.map(row => row.key).sort(), ['form_rejected', 'login_failed', 'rate_limit_429', 'scanner_probe']);
  assert.doesNotMatch(answer.text, /192\.0\.2\.|imposter|spoofed-host/, 'no raw address, no line of another service');
  const probes = JSON.parse((await read('security', {category: 'scanner_probe'}, token(admin))).text);
  assert.deepEqual(probes.requests.items.map(item => item.path), ['/.env']);
  const byAddress = JSON.parse((await read('security', {ipHash: 'a1b2c3d4e5f6'}, token(admin))).text);
  assert.equal(byAddress.requests.total, 1);
  const secondary = JSON.parse((await read('security', {site: 'secondary'}, token(admin))).text);
  assert.deepEqual(secondary.kpis, {blockedAttacks: 1, scannerProbes: 0, botFormBlocks: 0, signInFailures: 1});
});

test('a range outside 24 hours, 7 days and 30 days is refused', async () => {
  for (const range of ['1h', '14d', '90d', '']) assert.equal((await read('visitors', {range}, token(admin))).status, 400, range);
  for (const range of ['24h', '7d', '30d']) assert.equal((await read('security', {range}, token(admin))).status, 200, range);
});

test('a browser of the tenant may read the answer, and no other origin', async () => {
  const own = await read('visitors', {}, token(admin), {origin: 'https://shop.example.test'});
  assert.equal(own.headers.get('access-control-allow-origin'), 'https://shop.example.test');
  const foreign = await read('visitors', {}, token(admin), {origin: 'https://evil.example.test'});
  assert.equal(foreign.headers.get('access-control-allow-origin'), null);
});

test('PLANTED DEFECT: counting another tenant\'s hosts, a query string or a raw address is found', async () => {
  const bearer = token(admin);
  const reads = async source => JSON.parse((await serving(source, ask => ask('visitors', {}, bearer))).text);
  assert.equal((await reads(SOURCE)).kpis.pageviews, 4);
  assert.notEqual((await reads(mutated('if host not in hosts or not', 'if False or not'))).kpis.pageviews, 4, 'a spoofed host is counted');
  assert.notEqual((await reads(mutated('.split("?", 1)[0]', ''))).topPages.length, 2, 'the query stays in the path');
  assert.match((await serving(mutated('hashlib.sha256(salt + host.encode()).hexdigest()[:12]', 'host'), ask => ask('visitors', {}, bearer))).text, /203\.0\.113\.7/, 'the raw address leaves');
});
