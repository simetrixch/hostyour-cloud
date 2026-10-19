import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

// apply-cloudflare-zone-security runs against a stand-in for curl that answers as the Cloudflare API
// answers the calls it makes, from a state file it changes on every write, and records each call: its
// arguments, the config curl was given on its standard input, and the body that config carried.

const HERE = fileURLToPath(new URL('.', import.meta.url));
const ACT = 'apply-cloudflare-zone-security';
const FQDN = 'master.example.invalid';
const TOKEN = 'zone-security-token-4c1e';
const DNS_TOKEN = 'dns-token-sentinel-9b2d';
const CERTIFICATE = '-----BEGIN CERTIFICATE-----\nMIIBorigin\n-----END CERTIFICATE-----\n';
const PRIVATE_KEY = '-----BEGIN PRIVATE KEY-----\nMIIEsecret\n-----END PRIVATE KEY-----\n';
const FREE_ID = '77454fe2d30c4220b5701f6fdfb893ba';
const UNRELATED = {id: 'u1', ref: 'u1', description: 'office block', expression: 'ip.src eq 192.0.2.1', action: 'block', enabled: true, version: '3'};

const FAKE_CURL = `#!/usr/bin/env node
const fs = require('node:fs');
const dir = process.env.FAKE_CLOUDFLARE;
const state = JSON.parse(fs.readFileSync(dir + '/state.json', 'utf8'));
const argv = process.argv.slice(2);
const config = fs.readFileSync(0, 'utf8');
const value = name => (config.split('\\n').filter(l => l.startsWith(name + ' = "')).map(l => l.slice(name.length + 4, -1).replace(/\\\\(["\\\\])/g, '$1')));
const method = argv[argv.indexOf('-X') + 1];
const url = new URL(argv[argv.length - 1]);
const path = url.pathname.replace('/client/v4', '');
const body = value('data-binary')[0];
fs.appendFileSync(dir + '/calls.jsonl', JSON.stringify({argv, config, method, path: path + url.search, body}) + '\\n');
const answer = (status, result, errors = []) => { process.stdout.write(JSON.stringify({success: status < 300, errors, result}) + '\\n' + status); fs.writeFileSync(dir + '/state.json', JSON.stringify(state)); process.exit(0); };
if (!value('header').includes('Authorization: Bearer ' + state.token)) answer(403, null, [{code: 9109, message: 'Invalid access token'}]);
const area = /settings\\/(ssl|min_tls_version)/.test(path) ? 'settings' : /origin_tls/.test(path) ? 'certificates' : /rulesets/.test(path) ? 'waf' : 'zone';
if (state.denied.includes(area)) answer(403, null, [{code: 10000, message: 'Authentication error'}]);
if (path === '/zones') answer(200, state.zones.filter(z => z.name === url.searchParams.get('name')).map(({id, name}) => ({id, name})));
const zone = state.zones.find(z => path.startsWith('/zones/' + z.id + '/'));
const rest = path.slice(('/zones/' + zone.id).length);
const sent = body === undefined ? undefined : JSON.parse(body);
const withIds = rules => rules.map((r, i) => ({id: r.id || 'r' + Date.now().toString(36) + i, version: '1', last_updated: '2026-10-15T00:00:00Z', ...r,
  ratelimit: r.ratelimit && {requests_to_origin: false, ...r.ratelimit}}));
let m;
if (rest === '/settings/ssl') { if (method === 'PATCH') zone.ssl = sent.value; answer(200, {id: 'ssl', value: zone.ssl}); }
if (rest === '/settings/min_tls_version') { if (method === 'PATCH' && !zone.minTlsFrozen) zone.minTls = sent.value; answer(200, {id: 'min_tls_version', value: zone.minTls}); }
if (rest === '/origin_tls_client_auth') {
  if (method === 'POST') zone.certificates.push({id: 'c' + zone.certificates.length, certificate: sent.certificate, private_key_given: sent.private_key, status: state.uploadStatus, expires_on: '2028-10-15T00:00:00Z'});
  answer(200, zone.certificates.map(({private_key_given, ...c}) => c));
}
if (rest === '/origin_tls_client_auth/settings') { if (method === 'PUT') zone.originPull = sent.enabled; answer(200, {enabled: zone.originPull}); }
if (rest === '/rulesets') answer(200, [...zone.managed, ...Object.values(zone.entrypoints)].map(({rules, ...r}) => r));
if ((m = rest.match(/^\\/rulesets\\/phases\\/([a-z_]+)\\/entrypoint$/))) {
  if (method === 'PUT') zone.entrypoints[m[1]] = {id: 'e-' + m[1], kind: 'zone', phase: m[1], rules: withIds(sent.rules)};
  zone.entrypoints[m[1]] ? answer(200, zone.entrypoints[m[1]]) : answer(404, null, [{code: 10003, message: 'could not find entrypoint ruleset'}]);
}
const ruleset = Object.values(zone.entrypoints).find(e => rest.startsWith('/rulesets/' + e.id + '/rules'));
if (ruleset && method === 'POST') { ruleset.rules.push(...withIds([sent])); answer(200, ruleset); }
if (ruleset && method === 'PATCH') { const i = ruleset.rules.findIndex(r => rest.endsWith('/' + r.id)); ruleset.rules[i] = withIds([{...sent, id: ruleset.rules[i].id}])[0]; answer(200, ruleset); }
answer(404, null, [{code: 7003, message: 'no route'}]);
`;

/** A clone whose origin carries the books branch, the act in it (or a planted copy), the stand-in curl and a config. */
function fixture(mjs = readFileSync(join(HERE, `${ACT}.mjs`), 'utf8')) {
  const root = mkdtempSync(join(tmpdir(), 'zone-security-'));
  const git = (cwd, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], {cwd, stdio: 'ignore'});
  mkdirSync(join(root, 'books/clusters/active'), {recursive: true});
  writeFileSync(join(root, `books/clusters/active/${FQDN}.yaml`), `role: master\nglobal:\n  platformDomain: shop.invalid\n  unitApex: "units.invalid"\n`);
  git(join(root, 'books'), 'init', '-q', '-b', FQDN);
  git(join(root, 'books'), 'add', '.');
  git(join(root, 'books'), 'commit', '-qm', 'books');
  mkdirSync(join(root, 'work/lifecycle'), {recursive: true});
  git(join(root, 'work'), 'init', '-q');
  git(join(root, 'work'), 'remote', 'add', 'origin', join(root, 'books'));
  writeFileSync(join(root, `work/lifecycle/${ACT}.mjs`), mjs);
  for (const file of [`${ACT}.sh`, 'require-owner-only.sh']) copyFileSync(join(HERE, file), join(root, 'work/lifecycle', file));
  mkdirSync(join(root, 'bin'));
  writeFileSync(join(root, 'bin/curl'), FAKE_CURL);
  chmodSync(join(root, 'bin/curl'), 0o755);
  const line = text => text.replaceAll('\n', '\\n');
  writeFileSync(join(root, 'config.env'), [`FQDN='${FQDN}'`, `CLOUDFLARE_DNS_API_TOKEN='${DNS_TOKEN}'`, `CLOUDFLARE_ZONE_SECURITY_API_TOKEN='${TOKEN}'`,
    `CLOUDFLARE_ORIGIN_PULL_CERTIFICATE='${line(CERTIFICATE)}'`, `CLOUDFLARE_ORIGIN_PULL_PRIVATE_KEY='${line(PRIVATE_KEY)}'`, ''].join('\n'));
  chmodSync(join(root, 'config.env'), 0o600);
  return root;
}
/** Two Free zones as a new installation finds them: SSL Full, the minimum TLS version at Cloudflare's default 1.0, no origin pull, an unrelated custom rule, and the
 * Free managed ruleset as Cloudflare lists it on a Free zone. */
function cloudflare(root, change = state => state) {
  const zone = (id, name) => ({id, name, ssl: 'full', minTls: '1.0', certificates: [], originPull: false,
    managed: [{id: FREE_ID, name: 'Cloudflare Managed Free Ruleset', kind: 'managed', phase: 'http_request_firewall_managed'}],
    entrypoints: {http_request_firewall_custom: {id: `e-custom-${id}`, kind: 'zone', phase: 'http_request_firewall_custom', rules: [UNRELATED]}}});
  const state = change({token: TOKEN, denied: [], uploadStatus: 'active', zones: [zone('z1', 'shop.invalid'), zone('z2', 'units.invalid')]});
  writeFileSync(join(root, 'state.json'), JSON.stringify(state));
}
function run(root, mode) {
  writeFileSync(join(root, 'calls.jsonl'), '');
  const result = spawnSync('bash', [join(root, `work/lifecycle/${ACT}.sh`), join(root, 'config.env'), mode], {encoding: 'utf8',
    env: {...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}`, FAKE_CLOUDFLARE: root}});
  const calls = readFileSync(join(root, 'calls.jsonl'), 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l));
  return {...result, calls, writes: calls.filter(c => c.method !== 'GET'), state: JSON.parse(readFileSync(join(root, 'state.json'), 'utf8'))};
}

/** Every way the act in [root] misses the declared controls of a zone, named. */
function findings(root) {
  const found = [];
  const expect = (what, holds) => { if (!holds) found.push(what); };
  const secretsKept = (name, result) => {
    for (const secret of [TOKEN, 'MIIEsecret', DNS_TOKEN])
      expect(`${name}: a secret stands in an argument list or the output`, !(result.stdout + result.stderr + JSON.stringify(result.calls.map(c => c.argv))).includes(secret));
    expect(`${name}: the DNS token reached curl`, !result.calls.some(c => c.config.includes(DNS_TOKEN)));
  };

  cloudflare(root);
  let result = run(root, 'preview');
  expect('preview ends 0', result.status === 0);
  expect('preview writes nothing', result.writes.length === 0);
  expect('preview names the changes of both zones', /zone shop\.invalid: would SSL mode to Full \(strict\)/.test(result.stdout) && /zone units\.invalid: would add hostyour-next-action/.test(result.stdout));
  expect('preview names the minimum TLS version of both zones', /zone shop\.invalid: would Minimum TLS version to 1\.2/.test(result.stdout) && /zone units\.invalid: would Minimum TLS version to 1\.2/.test(result.stdout));
  secretsKept('preview', result);

  result = run(root, 'apply');
  expect(`apply ends 0 (${result.status}: ${result.stderr.trim()})`, result.status === 0);
  secretsKept('apply', result);
  for (const zone of result.state.zones) {
    const rules = phase => zone.entrypoints[phase]?.rules ?? [];
    expect(`${zone.name}: SSL mode is strict`, zone.ssl === 'strict');
    expect(`${zone.name}: the minimum TLS version is 1.2`, zone.minTls === '1.2');
    expect(`${zone.name}: the certificate and its key are uploaded`, zone.certificates.length === 1 && zone.certificates[0].private_key_given === PRIVATE_KEY && zone.certificates[0].certificate === CERTIFICATE);
    expect(`${zone.name}: origin pull is on`, zone.originPull === true);
    expect(`${zone.name}: the unrelated rule stands as it stood`, JSON.stringify(rules('http_request_firewall_custom')[0]) === JSON.stringify(UNRELATED));
    expect(`${zone.name}: the Next-Action rule blocks`, rules('http_request_firewall_custom').some(r => r.ref === 'hostyour-next-action' && r.action === 'block' && r.expression === 'len(http.request.headers["next-action"]) > 0'));
    expect(`${zone.name}: one rate rule counts the login per IP in 10 seconds`, rules('http_ratelimit').length === 1 && rules('http_ratelimit')[0].expression === 'http.request.uri.path eq "/auth/api/v1/auth/login"' && rules('http_ratelimit')[0].ratelimit.period === 10 && rules('http_ratelimit')[0].ratelimit.characteristics.includes('ip.src'));
    expect(`${zone.name}: the Managed Free Ruleset runs`, rules('http_request_firewall_managed').some(r => r.action === 'execute' && r.action_parameters.id === FREE_ID && r.enabled));
  }
  expect('apply reads back', (result.stdout.match(/read back as declared; the origin pull certificate is active/g) ?? []).length === 2);
  result = run(root, 'preview');
  expect('a second preview has nothing to change', result.status === 0 && result.writes.length === 0 && (result.stdout.match(/nothing to change/g) ?? []).length === 2);

  // A minimum at or above 1.2 stands as it is; only one below it is written.
  const tlsWrites = result => result.writes.filter(c => c.path.endsWith('/settings/min_tls_version'));
  cloudflare(root, state => { state.zones[0].minTls = '1.3'; state.zones[1].minTls = '1.1'; return state; });
  result = run(root, 'preview');
  expect('preview names the minimum TLS version of the zone below 1.2 and not of the zone at 1.3', !/zone shop\.invalid: would Minimum TLS version/.test(result.stdout) && /zone units\.invalid: would Minimum TLS version to 1\.2/.test(result.stdout));
  result = run(root, 'apply');
  expect(`apply raises 1.1 to 1.2 and never lowers 1.3 (${result.status}: ${result.stderr.trim()})`, result.status === 0 && result.state.zones[0].minTls === '1.3' && result.state.zones[1].minTls === '1.2' && tlsWrites(result).length === 1 && tlsWrites(result)[0].path.startsWith('/zones/z2/'));
  cloudflare(root, state => { state.zones[0].minTls = '1.2'; state.zones[1].minTls = '1.2'; return state; });
  result = run(root, 'apply');
  expect('a minimum of 1.2 is neither named nor written', result.status === 0 && !/Minimum TLS version/.test(result.stdout) && tlsWrites(result).length === 0 && result.state.zones.every(z => z.minTls === '1.2'));
  cloudflare(root, state => { state.zones[0].minTls = 'off'; return state; });
  result = run(root, 'preview');
  expect('a minimum Cloudflare does not list stops the run naming it', result.status === 65 && /zone shop\.invalid states min_tls_version off/.test(result.stderr));
  cloudflare(root, state => { state.zones[0].minTlsFrozen = true; return state; });
  result = run(root, 'apply');
  expect('a minimum Cloudflare does not keep fails the read-back naming it', result.status === 65 && /zone shop\.invalid reads back without Minimum TLS version to 1\.2/.test(result.stderr));

  // Cloudflare's own deployment of the Managed Free Ruleset counts, and is not deployed a second time.
  cloudflare(root, state => { state.zones[0].entrypoints.http_request_firewall_managed = {id: 'e-m', kind: 'zone', phase: 'http_request_firewall_managed', rules: [{id: 'd1', ref: 'd1', action: 'execute', action_parameters: {id: FREE_ID}, expression: 'true', enabled: true}]}; return state; });
  result = run(root, 'apply');
  expect('a standing Managed Free deployment is kept alone', result.status === 0 && result.state.zones[0].entrypoints.http_request_firewall_managed.rules.length === 1);

  cloudflare(root, state => { state.zones[1].entrypoints.http_request_firewall_custom.rules = [1, 2, 3, 4, 5].map(n => ({...UNRELATED, id: `u${n}`, ref: `u${n}`})); return state; });
  result = run(root, 'apply');
  expect('five custom rules stop the run naming the slot', result.status === 65 && /zone units\.invalid holds 5 custom rules, the 5 Free admits, and hostyour-next-action needs one of them/.test(result.stderr));
  expect('the full zone is not written', !result.writes.some(c => c.path.startsWith('/zones/z2')));

  cloudflare(root, state => { state.zones[0].entrypoints.http_ratelimit = {id: 'e-r', kind: 'zone', phase: 'http_ratelimit', rules: [{id: 'f1', description: 'search burst', action: 'block', expression: 'true', enabled: true}]}; return state; });
  result = run(root, 'preview');
  expect('a foreign rate rule stops the run naming it', result.status === 65 && /holds the rate rule search burst, the one Free admits/.test(result.stderr));

  cloudflare(root, state => { state.zones[0].managed = []; return state; });
  result = run(root, 'preview');
  expect('a zone without the Managed Free Ruleset stops the run naming it', result.status === 65 && /zone shop\.invalid lists no Cloudflare Managed Free Ruleset, so the plan it is on does not carry it/.test(result.stderr));

  // Only a ruleset of the managed firewall phase is one the managed phase can execute.
  cloudflare(root, state => { state.zones[0].managed = state.zones[0].managed.map(r => ({...r, phase: 'ddos_l7'})); return state; });
  result = run(root, 'preview');
  expect('a zone whose Managed Free Ruleset stands in another phase stops the run naming it', result.status === 65 && /zone shop\.invalid lists no Cloudflare Managed Free Ruleset/.test(result.stderr));

  cloudflare(root, state => { state.denied = ['waf']; return state; });
  result = run(root, 'apply');
  expect('a token without WAF rights stops the run naming them', result.status === 77 && /CLOUDFLARE_ZONE_SECURITY_API_TOKEN needs Zone WAF Read and Write/.test(result.stderr));
  secretsKept('refusal', result);

  cloudflare(root, state => { state.uploadStatus = 'pending_deployment'; return state; });
  result = run(root, 'apply');
  expect('a certificate Cloudflare does not present yet fails the read-back', result.status === 75 && /not active on every zone yet/.test(result.stderr));
  return found;
}

test('preview writes nothing, apply sets every declared control and keeps unrelated rules, read back; no secret is shown', () => {
  const root = fixture();
  try { assert.deepEqual(findings(root), []); } finally { rmSync(root, {recursive: true, force: true}); }
});

test('a config others can read is refused before Cloudflare is asked', () => {
  const root = fixture();
  try {
    cloudflare(root);
    chmodSync(join(root, 'config.env'), 0o644);
    const result = run(root, 'apply');
    assert.equal(result.status, 65);
    assert.match(result.stderr, /is mode 644, and it carries the zone security token and the origin pull private key\. Make it owner-only with: chmod 600 /);
    assert.equal(result.calls.length, 0);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('PLANTED DEFECT: an act that replaces a whole ruleset, shows the token, skips the slot check, writes on preview or misses the Managed Free Ruleset as Cloudflare lists it, leaves the minimum TLS version low or lowers a high one is caught', () => {
  const act = readFileSync(join(HERE, `${ACT}.mjs`), 'utf8');
  const planted = {
    'a whole ruleset replaced': act.replace("method: 'POST', path: `${at}/rulesets/${entrypoint.id}/rules`, body: rule", "method: 'PUT', path: `${at}/rulesets/phases/${phase}/entrypoint`, body: {rules: [rule]}"),
    'the token in an argument': act.replace("['-sS', '-K', '-',", "['-sS', '-H', `X-Token: ${token}`, '-K', '-',"),
    'no slot check': act.replace('if (refusal) fail(', 'if (false) fail('),
    'preview writes': act.replace("if (mode === 'apply') api(", 'api('),
    'no read-back': act.replace("if (pending) fail(", "if (false) fail("),
    'the name the ruleset does not carry': act.replace("'Cloudflare Managed Free Ruleset'", "'Cloudflare Free Managed Ruleset'"),
    'no phase check': act.replace(" && r.phase === MANAGED", ""),
    'no minimum TLS': act.replace('< TLS_VERSIONS.indexOf(MINIMUM_TLS)', '< 0'),
    'a higher minimum lowered': act.replace('< TLS_VERSIONS.indexOf(MINIMUM_TLS)', '!== TLS_VERSIONS.indexOf(MINIMUM_TLS)'),
    'a lower minimum than 1.2': act.replace("const MINIMUM_TLS = '1.2'", "const MINIMUM_TLS = '1.1'"),
    'a minimum nobody lists passed': act.replace('if (!TLS_VERSIONS.includes(tls)) fail(', 'if (false) fail('),
  };
  for (const [name, text] of Object.entries(planted)) {
    assert.notEqual(text, act, name);
    const root = fixture(text);
    try { assert.notDeepEqual(findings(root), [], name); } finally { rmSync(root, {recursive: true, force: true}); }
  }
});
