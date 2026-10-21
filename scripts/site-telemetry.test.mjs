import assert from 'node:assert/strict';
import {generateKeyPairSync, sign} from 'node:crypto';
import {spawn} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {createServer} from 'node:http';
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
// The traffic stands on one UTC day: it ends at NOW, or, in the first hours of a day, just before that day began.
// A visitor's hash changes with the day, so traffic across midnight would count one visitor twice.
const OLDEST_MINUTES = 180;
const today = new Date(NOW);
const startOfToday = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
const TRAFFIC_END = NOW - OLDEST_MINUTES * 60000 >= startOfToday ? NOW : startOfToday - 60000;
const minutesAgo = minutes => TRAFFIC_END - minutes * 60000;
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
  {tenant: 'dddd-prod', hosts: ['big.example.test'], issuers: ['big.example.test'], proxiedHosts: [],
    sites: [{name: 'main', sitePath: '/', main: true}]},
  {tenant: 'eeee-prod', hosts: ['days.example.test'], issuers: ['days.example.test'], proxiedHosts: [],
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
  access({minutes: OLDEST_MINUTES, path: '/?token=SECRETTOKEN', referer: 'https://news.example.org/story'}),
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
const FAILURES = [failure({minutes: 45}), failure({minutes: 44, site: 'secondary'}), failure({minutes: 43, service: 'imposter'}), failure({minutes: 42, namespace: 'bbbb-prod'}),
  failure({minutes: 41, category: 'password_reset'})];

// More lines than one page of Loki's answer holds (5000), a second apart, so a reader that stops at the
// first page, or reads a line twice at the page border, counts something else than BULK_LINES.
const BULK_LINES = 5200;
const BULK = Array.from({length: BULK_LINES}, (_, index) => [NOW - 2 * 3600000 + index * 1000, access({minutes: 0, host: 'big.example.test', tenant: 'dddd-prod'})[1]]);
// The same visitor on two days: two requests at noon of the day before yesterday and one at noon of yesterday (UTC).
const noon = daysAgo => { const day = new Date(NOW); return Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate() - daysAgo, 12); };
const ROTATION = [noon(2), noon(2) + 300000, noon(1)]
  .map(stamp => [stamp, access({minutes: 0, host: 'days.example.test', tenant: 'eeee-prod', address: '203.0.113.77:1234'})[1]]);
// What the selector's host filter would pick out of the ingress log.
const TRAFFIC_BY_HOST = [['big\\.example\\.test', BULK], ['days\\.example\\.test', ROTATION]];

const listen = handler => new Promise(resolve => { const server = createServer(handler).listen(0, '127.0.0.1', () => resolve(server)); });
const json = (response, body) => { response.setHeader('content-type', 'application/json'); response.end(JSON.stringify(body)); };

let folder;
const servers = [];
let urls;
let lokiRequests = 0;
before(async () => {
  folder = mkdtempSync(join(tmpdir(), 'site-telemetry-'));
  writeFileSync(join(folder, 'token'), 'service-account-token');
  const kubernetes = await listen((request, response) => {
    assert.equal(request.headers.authorization, 'Bearer service-account-token');
    assert.match(request.url, /^\/api\/v1\/namespaces\/observability\/configmaps\?labelSelector=platform%2Fsite-telemetry-registration%3Dtrue$/);
    json(response, {items: REGISTRATIONS.map(facts => ({data: {'registration.json': JSON.stringify(facts)}})).concat([{data: {'registration.json': 'not json'}}])});
  });
  // Loki as the service meets it: a bound is Unix nanoseconds (the real Loki 3.7.4 answered 400 to a date
  // written any other way), `start` is included and `end` is not, at most `limit` lines come back, 100
  // when the request names none, and the newest first unless `direction` says forward.
  const loki = await listen((request, response) => {
    lokiRequests += 1;
    const parameters = new URL(request.url, 'http://x').searchParams;
    const [start, end] = ['start', 'end'].map(name => (/^\d{19}$/.test(parameters.get(name) ?? '') ? BigInt(parameters.get(name)) : null));
    if (start === null || end === null) {
      response.statusCode = 400;
      return response.end(`could not parse 'start' or 'end' parameter: ${parameters.get('start')} ${parameters.get('end')}`);
    }
    const query = parameters.get('query');
    const lines = query.includes('container="traefik"')
      ? TRAFFIC_BY_HOST.find(([host]) => query.includes(host))?.[1] ?? TRAFFIC
      : FAILURES.filter(([namespace]) => query.includes(`namespace="${namespace}"`)).map(([, stamp, line]) => [stamp, line]);
    const values = lines.map(([stamp, line]) => [BigInt(stamp) * 1000000n, line]).filter(([stamp]) => stamp >= start && stamp < end)
      .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
    if ((parameters.get('direction') ?? 'backward') === 'backward') values.reverse();
    json(response, {status: 'success', data: {result: [{stream: {}, values: values.slice(0, Number(parameters.get('limit') ?? 100)).map(([stamp, line]) => [String(stamp), line])}]}});
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

// The service binds the port the system gives it and the launcher says which one, on the first line of its stdout once it
// listens, so no port is chosen first and taken by another process before the service binds it. The service itself runs
// unchanged, as the pod runs it.
const LAUNCHER = [
  'import runpy, socketserver, sys',
  'listen = socketserver.TCPServer.server_activate',
  'def report(server):',
  '    listen(server)',
  '    print(server.server_address[1], flush=True)',
  'socketserver.TCPServer.server_activate = report',
  'runpy.run_path(sys.argv[1], run_name="__main__")'].join('\n');
const START_MILLISECONDS = 10000;

/** The port a started service listens on: the first line it said. A service that ends or stays silent fails the wait with what it wrote to stderr. */
async function portOf(child, exited, stderr, startMilliseconds) {
  let stdout = '';
  const said = new Promise(resolve => child.stdout.on('data', chunk => { stdout += chunk; if (stdout.includes('\n')) resolve(Number(stdout.split('\n')[0])); }));
  let timer;
  const silent = new Promise((resolve, reject) => { timer = setTimeout(() => reject(new Error(`the service said no port within ${startMilliseconds / 1000} s:\n${stderr()}`)), startMilliseconds); });
  const ended = exited.then(({code, signal, error}) => { throw new Error(`the service ended (${error?.message ?? signal ?? `exit ${code}`}) before it listened:\n${stderr()}`); });
  try {
    return await Promise.race([said, silent, ended]);
  } finally {
    clearTimeout(timer);
  }
}

/** Starts the service from [source] with the settings [environment] changes and runs [use] against it. */
async function serving(source, use, environment = {}, startMilliseconds = START_MILLISECONDS) {
  const child = spawn('python3', ['-I', '-c', LAUNCHER, source], {stdio: ['ignore', 'pipe', 'pipe'], env: {
    POD_NAMESPACE: 'observability', LISTEN_PORT: '0', KUBERNETES_API_URL: urls.kubernetes, KUBERNETES_TOKEN_FILE: join(folder, 'token'),
    LOKI_URL: urls.loki, JWKS_URL_TEMPLATE: `${urls.identity}/{host}/jwks.json`, CACHE_SECONDS: '0', PATH: process.env.PATH, ...environment}});
  // Listened to from the start: a child that ends before the cleanup below is told of at once, and never waited for.
  const exited = new Promise(resolve => { child.once('close', (code, signal) => resolve({code, signal})); child.once('error', error => resolve({error})); });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  try {
    const port = await portOf(child, exited, () => stderr, startMilliseconds);
    return await use(async (kind, query, bearer, extra = {}, method = 'GET') => {
      const parameters = new URLSearchParams({tenant: 'aaaa-prod', site: 'main', range: '24h', ...query});
      const answer = await fetch(`http://127.0.0.1:${port}/api/v1/site-telemetry/${kind}?${parameters}`, {method, headers: {...(bearer ? {authorization: `Bearer ${bearer}`} : {}), ...extra}});
      return {status: answer.status, text: await answer.text(), headers: answer.headers};
    });
  } finally {
    child.kill();
    await exited;
  }
}
const read = (kind, query, bearer, extra) => serving(SOURCE, ask => ask(kind, query, bearer, extra));
// The category words a security report may speak: the keys of the plan that Traefik and digita-auth can tell apart.
const CATEGORIES = ['login_failed', 'login_locked', '2fa_failed', 'rate_limit_429', 'scanner_probe'];
const unplannedWords = body => [...body.categories.map(row => row.key), ...body.requests.items.map(item => item.category)].filter(word => !CATEGORIES.includes(word));
const mutated = (from, to) => {
  const source = readFileSync(SOURCE, 'utf8');
  assert.equal(source.split(from).length, 2, `${from} stands once in the service`);
  const copy = join(folder, `mutated-${Math.random().toString(36).slice(2)}.py`);
  writeFileSync(copy, source.replace(from, to));
  return copy;
};
const admin = {roles: ['Administrator']};
const PREFLIGHTS_REFUSED = ['https://evil.example.test', 'https://other.example.test', 'http://shop.example.test', 'shop.example.test'];

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
  assert.deepEqual(body.categories.map(row => row.key).sort(), ['login_failed', 'rate_limit_429', 'scanner_probe'], 'a sign-in line of another category is no sign-in failure');
  assert.deepEqual(unplannedWords(body), []);
  assert.equal(body.requests.total, 3, 'the refused form stands in no row');
  assert.doesNotMatch(answer.text, /form_rejected|forged_form_signature|honeypot_bot/, 'Traefik cannot tell a forged signature from a honeypot catch');
  assert.doesNotMatch(answer.text, /192\.0\.2\.|imposter|spoofed-host/, 'no raw address, no line of another service');
  const limited = JSON.parse((await read('security', {category: 'rate_limit_429'}, token(admin))).text);
  assert.deepEqual([limited.kpis.blockedAttacks, limited.kpis.botFormBlocks], [1, 1], 'a category filter leaves out the refused form, which has no category');
  const probes = JSON.parse((await read('security', {category: 'scanner_probe'}, token(admin))).text);
  assert.deepEqual(probes.requests.items.map(item => item.path), ['/.env']);
  const byAddress = JSON.parse((await read('security', {ipHash: 'a1b2c3d4e5f6'}, token(admin))).text);
  assert.equal(byAddress.requests.total, 1);
  const secondary = JSON.parse((await read('security', {site: 'secondary'}, token(admin))).text);
  assert.deepEqual(secondary.kpis, {blockedAttacks: 1, scannerProbes: 0, botFormBlocks: 0, signInFailures: 1});
});

test('PLANTED DEFECT: a word for the refused forms, the old or a new one, or a refusal counted nowhere, is found', async () => {
  const refusal = 'refusals.append({**event, "category": None,';
  const security = async source => JSON.parse((await serving(source, ask => ask('security', {}, token(admin)))).text);
  for (const word of ['form_rejected', 'forged_form_signature', 'honeypot_bot', 'form_block']) {
    const body = await security(mutated(refusal, `events.append({**event, "category": "${word}",`));
    assert.deepEqual(unplannedWords(body), [word, word], `the word ${word} stands in a row and a category`);
  }
  assert.equal((await security(mutated('form_blocks = sum(1 for event in refusals if wanted(event))', 'form_blocks = 0'))).kpis.botFormBlocks, 1, 'the refused form is counted nowhere');
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

test('a preflight is answered for the tenant\'s own hosts and for no other origin', async () => {
  await serving(SOURCE, async ask => {
    const own = await ask('visitors', {}, undefined, {origin: 'https://shop.example.test'}, 'OPTIONS');
    assert.deepEqual([own.status, own.headers.get('access-control-allow-origin')], [204, 'https://shop.example.test']);
    for (const origin of PREFLIGHTS_REFUSED) {
      const refused = await ask('visitors', {}, undefined, {origin}, 'OPTIONS');
      assert.deepEqual([origin, refused.status, refused.headers.get('access-control-allow-origin')], [origin, 403, null]);
    }
  });
});

test('PLANTED DEFECT: a preflight that answers a foreign origin is found', async () => {
  const planted = {
    'every origin is allowed': mutated('if facts is None or origin.removeprefix("https://") not in facts["hosts"] or not origin.startswith("https://"):', 'if facts is None:'),
    'the scheme is not checked': mutated(' or not origin.startswith("https://")', ''),
  };
  for (const [name, source] of Object.entries(planted)) {
    const answered = await serving(source, async ask => {
      for (const origin of PREFLIGHTS_REFUSED) {
        if ((await ask('visitors', {}, undefined, {origin}, 'OPTIONS')).status === 204) return origin;
      }
      return null;
    });
    assert.notEqual(answered, null, `${name}: the planted copy answers a refused origin`);
  }
});

test('the sign-in failures of the site are the three failures of digita-auth and no other line of its', async () => {
  const body = JSON.parse((await read('security', {category: 'password_reset'}, token(admin))).text);
  assert.deepEqual([body.kpis.blockedAttacks, body.requests.total, body.categories], [0, 0, []]);
  const planted = JSON.parse((await serving(mutated(' or entry["category"] not in AUTH_FAILURES', ''), ask => ask('security', {category: 'password_reset'}, token(admin)))).text);
  assert.equal(planted.requests.total, 1, 'PLANTED DEFECT: without the category filter the line of another category is a security event');
});

test('the cache answers each website its own figures, and a repeated question without a second read of Loki', async () => {
  const asked = source => serving(source, async ask => {
    const bearer = token(admin);
    const main = JSON.parse((await ask('visitors', {site: 'main'}, bearer)).text);
    const before = lokiRequests;
    await ask('visitors', {site: 'main'}, bearer);
    const repeated = lokiRequests - before;
    const secondary = JSON.parse((await ask('visitors', {site: 'secondary'}, bearer)).text);
    return {repeated, main: main.topPages, secondary: secondary.topPages};
  }, {CACHE_SECONDS: '60'});
  const real = await asked(SOURCE);
  assert.equal(real.repeated, 0, 'the cache is on in this run');
  assert.deepEqual(real.secondary, [{key: '/web/secondary/blog', count: 1}]);
  assert.notDeepEqual(real.main, real.secondary);
  const planted = await asked(mutated('tuple(sorted(query.items()))', 'tuple(sorted((name, value) for name, value in query.items() if name != "site"))'));
  assert.deepEqual(planted.secondary, planted.main, 'PLANTED DEFECT: a cache key without the website serves one website\'s figures to another');
});

test('every line Loki holds is counted: the reader pages on until a page is not full', async () => {
  const bearer = token({...admin, tenantKey: keys.other, host: 'big.example.test'});
  const counted = async source => JSON.parse((await serving(source, ask => ask('visitors', {tenant: 'dddd-prod'}, bearer))).text);
  const real = await counted(SOURCE);
  assert.deepEqual([real.kpis.pageviews, real.requests.total, real.truncated], [BULK_LINES, BULK_LINES, false]);
  const planted = {
    'only the first page is read': mutated('if len(entries) < PAGE:', 'if True:'),
    'the next page starts at the last line again': mutated('start = entries[-1][0] + 1', 'start = entries[-1][0]'),
    'the page size is left to Loki, which answers 100 lines': mutated('"limit": PAGE, ', ''),
    'the newest lines come first, so the next start skips the rest': mutated('"direction": "forward"', '"direction": "backward"'),
  };
  for (const [name, source] of Object.entries(planted)) assert.notEqual((await counted(source)).kpis.pageviews, BULK_LINES, `PLANTED DEFECT: ${name}`);
});

test('the address of a visitor is hashed with the day, so the same visitor is no one on another day', async () => {
  const bearer = token({...admin, tenantKey: keys.other, host: 'days.example.test'});
  const hashes = async source => {
    const body = JSON.parse((await serving(source, ask => ask('visitors', {tenant: 'eeee-prod', range: '7d'}, bearer))).text);
    return {unique: body.kpis.uniqueVisitors, byTime: body.requests.items.slice().sort((left, right) => left.time.localeCompare(right.time)).map(item => item.ipHash)};
  };
  const real = await hashes(SOURCE);
  assert.equal(real.unique, 2, 'one visitor on two days');
  assert.deepEqual([real.byTime[0] === real.byTime[1], real.byTime[1] === real.byTime[2]], [true, false], 'the same day the same hash, the next day another');
  const planted = await hashes(mutated('salt = hmac.new(PROCESS_SECRET, day, hashlib.sha256).digest()', 'salt = hmac.new(PROCESS_SECRET, b"fixed", hashlib.sha256).digest()'));
  assert.equal(planted.unique, 1, 'PLANTED DEFECT: a salt that does not change with the day makes the hash a durable identifier');
});

test('PLANTED DEFECT: counting another tenant\'s hosts, a query string or a raw address is found', async () => {
  const bearer = token(admin);
  const reads = async source => JSON.parse((await serving(source, ask => ask('visitors', {}, bearer))).text);
  assert.equal((await reads(SOURCE)).kpis.pageviews, 4);
  assert.notEqual((await reads(mutated('if host not in hosts or not', 'if False or not'))).kpis.pageviews, 4, 'a spoofed host is counted');
  assert.notEqual((await reads(mutated('.split("?", 1)[0]', ''))).topPages.length, 2, 'the query stays in the path');
  assert.match((await serving(mutated('hashlib.sha256(salt + host.encode()).hexdigest()[:12]', 'host'), ask => ask('visitors', {}, bearer))).text, /203\.0\.113\.7/, 'the raw address leaves');
});

test('a service that ends before it listens fails the test at once with what it wrote, and one that says no port is not waited for for ever', {timeout: 30000}, async () => {
  const dies = join(folder, 'dies.py');
  writeFileSync(dies, 'import sys\nsys.stderr.write("planted startup failure\\n")\nsys.exit(3)\n');
  const started = Date.now();
  await assert.rejects(serving(dies, ask => ask('visitors', {}, token(admin))), /the service ended \(exit 3\) before it listened:\nplanted startup failure/, 'PLANTED DEFECT: a service that dies before it answers');
  assert.ok(Date.now() - started < 10000, 'the failure came within seconds');
  const silent = join(folder, 'silent.py');
  writeFileSync(silent, 'import time\ntime.sleep(60)\n');
  await assert.rejects(serving(silent, ask => ask('visitors', {}, token(admin)), {}, 1500), /the service said no port within 1\.5 s/, 'PLANTED DEFECT: a service that lives and says no port');
  assert.equal((await serving(SOURCE, ask => ask('visitors', {}, token(admin)))).status, 200, 'PLANTED INNOCENT: the real service is served as before');
});
