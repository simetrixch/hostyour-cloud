// apply-cloudflare-zone-security.mjs — the Cloudflare Free controls of an installation's two zones,
// previewed, applied and read back. Started by apply-cloudflare-zone-security.sh, which guards the config.
//
// PER ZONE, platformDomain and unitApex of the books branch's map:
//   SSL mode Full (strict); the minimum TLS version raised to 1.2 where it stands lower (a higher one stays);
//   the zone-level origin pull certificate of the config uploaded and origin pull on;
//   the Cloudflare Managed Free Ruleset deployed; the custom rule `hostyour-next-action`, which blocks
//   (403 on Free) every request carrying a Next-Action header, WebSocket handshakes included; the one
//   rate rule `hostyour-login-rate` on the login path. Every other rule and setting is left as it stands.
//
// THE TOKEN AND THE PRIVATE KEY STAND IN NO ARGUMENT LIST. curl gets both through a config on its
// standard input, so `ps` shows neither, and nothing here prints them.

import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const API = 'https://api.cloudflare.com/client/v4';
const CUSTOM = 'http_request_firewall_custom';
const RATE = 'http_ratelimit';
const MANAGED = 'http_request_firewall_managed';
// The ruleset Free carries, as the zone's ruleset listing spells it: kind managed, phase MANAGED. The same
// words in another order match nothing.
const FREE_MANAGED = 'Cloudflare Managed Free Ruleset';
// The minimum TLS versions a zone can state, lowest first. The edge ends the browser's TLS, so this zone
// setting, not the origin's own policy, decides whether a browser on TLS 1.0 or 1.1 connects.
const TLS_VERSIONS = ['1.0', '1.1', '1.2', '1.3'];
const MINIMUM_TLS = '1.2';
// Free admits five custom rules and one rate rule per zone.
const CUSTOM_SLOTS = 5;
const NEXT_ACTION = {
  ref: 'hostyour-next-action', description: 'hostyour: no server action reaches a proxied host',
  expression: 'len(http.request.headers["next-action"]) > 0', action: 'block', enabled: true,
};
// The login of digita-auth, mounted under /auth. Free counts by IP and colo in 10-second windows on the
// path alone. ponytail: 20 a window is a guess until #398's measurements calibrate it.
const LOGIN_RATE = {
  ref: 'hostyour-login-rate', description: 'hostyour: sign-in attempts per address',
  expression: 'http.request.uri.path eq "/auth/api/v1/auth/login"', action: 'block', enabled: true,
  ratelimit: {characteristics: ['cf.colo.id', 'ip.src'], period: 10, requests_per_period: 20, mitigation_timeout: 10},
};
// What a token lacking it is told to carry, by the API path it was refused on.
const PERMISSIONS = [
  [/\/settings\//, 'Zone Settings Read and Write'],
  [/\/origin_tls_client_auth/, 'SSL and Certificates Read and Write'],
  [/\/rulesets/, 'Zone WAF Read and Write'],
  [/^\/zones\?/, 'Zone Read'],
];

const fail = (message, code = 65) => { throw Object.assign(new Error(message), {code}); };

/** The value of one KEY='value' line of the config, read and never executed; `\n` becomes a line break. */
function configValue(text, key) {
  const line = text.split('\n').map(l => l.replace(/\r$/, '')).find(l => l.startsWith(`${key}='`));
  return line?.slice(key.length + 2, line.lastIndexOf("'")).replaceAll('\\n', '\n') ?? '';
}

/** The zones platformDomain and unitApex of the map on the books branch FQDN of origin. */
function zonesOfBooks(repository, fqdn) {
  const git = args => spawnSync('git', ['-C', repository, ...args], {encoding: 'utf8'});
  if (git(['fetch', '--quiet', 'origin', `refs/heads/${fqdn}`]).status !== 0)
    fail(`the branch ${fqdn} could not be fetched from origin, so the zones it records cannot be read`, 69);
  const map = git(['show', `FETCH_HEAD:clusters/active/${fqdn}.yaml`]);
  if (map.status !== 0) fail(`branch ${fqdn} carries no clusters/active/${fqdn}.yaml, and the zones are read there`, 66);
  const zones = ['platformDomain', 'unitApex'].map(key => {
    const value = map.stdout.match(new RegExp(`^  ${key}:\\s*["']?([^"'\\s#]+)`, 'm'))?.[1];
    return value ?? fail(`clusters/active/${fqdn}.yaml on branch ${fqdn} states no ${key}`);
  });
  return [...new Set(zones)];
}

/** One call to the API: the answer's result, or null on 404 where [absent] allows it. */
function call(token, method, path, body, absent = false) {
  const quoted = text => `"${text.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
  const config = [`header = ${quoted(`Authorization: Bearer ${token}`)}`, 'header = "Content-Type: application/json"'];
  if (body !== undefined) config.push(`data-binary = ${quoted(JSON.stringify(body))}`);
  const run = spawnSync('curl', ['-sS', '-K', '-', '-X', method, '-w', '\n%{http_code}', API + path],
    {input: config.join('\n') + '\n', encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
  if (run.status !== 0) fail(`Cloudflare could not be reached for ${method} ${path} (curl exit ${run.status})`, 69);
  const status = Number(run.stdout.slice(run.stdout.lastIndexOf('\n') + 1));
  if (status === 404 && absent) return null;
  let answer;
  try { answer = JSON.parse(run.stdout.slice(0, run.stdout.lastIndexOf('\n'))); } catch { answer = {}; }
  if (status === 403 || status === 401) {
    const needs = PERMISSIONS.find(([pattern]) => pattern.test(path))?.[1] ?? 'a permission this act did not expect';
    fail(`Cloudflare refused ${method} ${path} (${status}): CLOUDFLARE_ZONE_SECURITY_API_TOKEN needs ${needs} on this zone`, 77);
  }
  if (status < 200 || status > 299 || answer.success !== true)
    fail(`Cloudflare refused ${method} ${path} (${status}): ${answer.errors?.map(e => e.message).join('; ') || 'no message'}`, 69);
  return answer.result;
}

const samePem = (a, b) => a.replace(/\s/g, '') === b.replace(/\s/g, '');
// The API answers a rule with fields of its own beside the declared ones, so only the declared ones are compared.
const covers = (actual, wanted) => wanted !== null && typeof wanted === 'object' && !Array.isArray(wanted)
  ? Object.entries(wanted).every(([key, value]) => covers(actual?.[key], value))
  : JSON.stringify(actual) === JSON.stringify(wanted);

/** Every write zone [zone] needs, as {what, method, path, body}; refused where Free has no room for it. */
function changesOf(api, zone, certificate, privateKey) {
  const at = `/zones/${zone.id}`;
  const changes = [];
  if (api('GET', `${at}/settings/ssl`).value !== 'strict')
    changes.push({what: 'SSL mode to Full (strict)', method: 'PATCH', path: `${at}/settings/ssl`, body: {value: 'strict'}});
  const tls = api('GET', `${at}/settings/min_tls_version`).value;
  if (!TLS_VERSIONS.includes(tls)) fail(`zone ${zone.name} states min_tls_version ${tls}, which this act cannot compare with ${MINIMUM_TLS}`);
  if (TLS_VERSIONS.indexOf(tls) < TLS_VERSIONS.indexOf(MINIMUM_TLS))
    changes.push({what: `Minimum TLS version to ${MINIMUM_TLS}`, method: 'PATCH', path: `${at}/settings/min_tls_version`, body: {value: MINIMUM_TLS}});
  if (!api('GET', `${at}/origin_tls_client_auth`).some(c => samePem(c.certificate ?? '', certificate)))
    changes.push({what: 'upload the origin pull certificate of the config', method: 'POST', path: `${at}/origin_tls_client_auth`,
      body: {certificate, private_key: privateKey}});
  if (api('GET', `${at}/origin_tls_client_auth/settings`).enabled !== true)
    changes.push({what: 'origin pull on', method: 'PUT', path: `${at}/origin_tls_client_auth/settings`, body: {enabled: true}});

  const free = api('GET', `${at}/rulesets`).find(r => r.kind === 'managed' && r.phase === MANAGED && r.name === FREE_MANAGED)
    ?? fail(`zone ${zone.name} lists no ${FREE_MANAGED}, so the plan it is on does not carry it`);
  const deploy = {ref: 'hostyour-free-managed', description: `hostyour: ${FREE_MANAGED}`, expression: 'true',
    action: 'execute', action_parameters: {id: free.id}, enabled: true};
  const wanted = [
    [MANAGED, deploy, rules => rules.find(r => r.action === 'execute' && r.action_parameters?.id === free.id), null],
    [CUSTOM, NEXT_ACTION, rules => rules.find(r => r.ref === NEXT_ACTION.ref),
      rules => rules.length >= CUSTOM_SLOTS && `zone ${zone.name} holds ${rules.length} custom rules, the ${CUSTOM_SLOTS} Free admits, and ${NEXT_ACTION.ref} needs one of them`],
    [RATE, LOGIN_RATE, rules => rules.find(r => r.ref === LOGIN_RATE.ref),
      rules => rules.length >= 1 && `zone ${zone.name} holds the rate rule ${rules[0].description || rules[0].id}, the one Free admits, and ${LOGIN_RATE.ref} needs it`],
  ];
  for (const [phase, rule, standing, full] of wanted) {
    const entrypoint = api('GET', `${at}/rulesets/phases/${phase}/entrypoint`, undefined, true);
    const found = entrypoint && standing(entrypoint.rules ?? []);
    if (!entrypoint) changes.push({what: `${rule.ref} in a new ${phase} ruleset`, method: 'PUT', path: `${at}/rulesets/phases/${phase}/entrypoint`, body: {rules: [rule]}});
    else if (!found) {
      const refusal = full?.(entrypoint.rules ?? []);
      if (refusal) fail(`${refusal}. Free one in the dashboard; nothing of this zone has been changed by this run`);
      changes.push({what: `add ${rule.ref}`, method: 'POST', path: `${at}/rulesets/${entrypoint.id}/rules`, body: rule});
    } else if (phase === MANAGED ? found.enabled !== true : !covers(found, rule)) {
      // A deployment that stands is switched on as it stands, its scope kept.
      const {action, action_parameters, expression, description, ref} = found;
      changes.push({what: `${phase === MANAGED ? 'enable' : 'set'} ${found.ref || found.id} as declared`, method: 'PATCH',
        path: `${at}/rulesets/${entrypoint.id}/rules/${found.id}`,
        body: phase === MANAGED ? {action, action_parameters, expression, description, ref, enabled: true} : rule});
    }
  }
  return changes;
}

export function applyZoneSecurity(args, repository) {
  const [configPath, mode, ...more] = args;
  if (!configPath || !['preview', 'apply'].includes(mode) || more.length)
    fail('usage: lifecycle/apply-cloudflare-zone-security.sh <config> preview|apply', 64);
  const text = readFileSync(configPath, 'utf8');
  const [fqdn, token, certificate, privateKey] = ['FQDN', 'CLOUDFLARE_ZONE_SECURITY_API_TOKEN',
    'CLOUDFLARE_ORIGIN_PULL_CERTIFICATE', 'CLOUDFLARE_ORIGIN_PULL_PRIVATE_KEY'].map(key =>
    configValue(text, key) || fail(`${configPath} states no ${key}${key.startsWith('CLOUDFLARE_ORIGIN') ? '; create-origin-pull-certificate.sh writes it' : ''}`));
  const api = (method, path, body, absent) => call(token, method, path, body, absent);
  let pending = 0;
  for (const name of zonesOfBooks(repository, fqdn)) {
    const zone = api('GET', `/zones?name=${encodeURIComponent(name)}`)[0]
      ?? fail(`the token reaches no zone ${name}: CLOUDFLARE_ZONE_SECURITY_API_TOKEN needs Zone Read on it`, 77);
    const changes = changesOf(api, zone, certificate, privateKey);
    for (const change of changes) {
      console.log(`zone ${name}: ${mode === 'apply' ? 'applying' : 'would'} ${change.what}`);
      if (mode === 'apply') api(change.method, change.path, change.body);
    }
    if (!changes.length) console.log(`zone ${name}: nothing to change`);
    if (mode === 'preview') continue;
    const left = changesOf(api, zone, certificate, privateKey);
    if (left.length) fail(`zone ${name} reads back without ${left.map(c => c.what).join(', ')}`);
    const uploaded = api('GET', `/zones/${zone.id}/origin_tls_client_auth`).find(c => samePem(c.certificate ?? '', certificate));
    console.log(`zone ${name}: read back as declared; the origin pull certificate is ${uploaded.status}, valid to ${uploaded.expires_on}`);
    if (uploaded.status !== 'active') pending += 1;
  }
  // A route may require the certificate only once Cloudflare presents it, which is its status active.
  if (pending) fail('the origin pull certificate is not active on every zone yet. Run preview again in a few minutes; no route may require it before', 75);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { applyZoneSecurity(process.argv.slice(2), resolve(dirname(fileURLToPath(import.meta.url)), '..')); }
  catch (error) {
    process.stderr.write(`apply-cloudflare-zone-security: ${error.message}\n`);
    process.exitCode = Number.isInteger(error.code) ? error.code : 70;
  }
}
