import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const usage = 'usage: plan-installation-domain --books-fqdn HOST --from-domain DOMAIN --to-domain DOMAIN --dry-run [--fqdn HOST --ssh-user USER]';
const refuse = (message, code = 65) => { throw Object.assign(new Error(message), {code}); };

export function requireHostname(host) {
  if (typeof host !== 'string' || host.length > 253 || !host.includes('.') ||
      !host.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) ||
      /^[0-9.]+$/.test(host)) refuse('a lowercase DNS hostname is required');
  return host;
}

export function moveHostname(host, from, to) {
  const wildcard = host.startsWith('*.') ? '*.' : '';
  const name = requireHostname(wildcard ? host.slice(2) : host);
  const target = name === from ? to : name.endsWith('.' + from) ? name.slice(0, -from.length) + to : name;
  requireHostname(target);
  if ((wildcard + target).length > 253) refuse('a mapped hostname exceeds the DNS length limit');
  return wildcard + target;
}

function moveEndpoint(value, from, to) {
  if (!value.includes('://')) return moveHostname(value, from, to);
  let url;
  try { url = new URL(value); } catch { refuse('an endpoint URL is invalid'); }
  // Endpoint settings are addresses, not a transport for credentials or signed queries.
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.search || url.hash)
    refuse('endpoint URLs must have no credentials, query or fragment');
  const target = moveHostname(url.hostname, from, to);
  const start = value.indexOf('://') + 3;
  if (value.slice(start, start + url.hostname.length).toLowerCase() !== url.hostname)
    refuse('endpoint hosts must use DNS spelling');
  return target === url.hostname ? value : value.slice(0, start) + target + value.slice(start + url.hostname.length);
}

export function planInstallation(maps, fromDomain, toDomain, installedHosts = []) {
  requireHostname(fromDomain); requireHostname(toDomain);
  if (fromDomain === toDomain || fromDomain.endsWith('.' + toDomain) || toDomain.endsWith('.' + fromDomain))
    refuse('source and target domains must be different, disjoint zones');
  if (!Array.isArray(maps) || !maps.length) refuse('the books branch carries no cluster maps');
  const seen = new Set();
  const hosts = new Map();
  const changes = [];
  const addHost = host => {
    const target = moveHostname(host, fromDomain, toDomain);
    if (target !== host) hosts.set(host, target);
    return target;
  };
  for (const {file, map} of maps) {
    const global = map?.global;
    const domain = requireHostname(global?.domain);
    if (file !== `clusters/active/${domain}.yaml` || seen.has(domain)) refuse('cluster map identity is inconsistent or duplicated');
    seen.add(domain);
    if (!domain.endsWith('.' + fromDomain)) refuse('a cluster map is outside the source zone');
    if (!['master', 'slave'].includes(map.role) || !['dev', 'test', 'prod'].includes(map.stage) ||
        typeof global.clusterName !== 'string' || !global.clusterName) refuse('a cluster map has no valid role, stage or name');
    const fields = [];
    for (const key of ['domain', 'booksCluster', 'buildPlane', 'unitApex']) {
      const before = requireHostname(global[key]);
      const after = addHost(before);
      if (before !== after) fields.push({path: `global.${key}`, before, after});
    }
    const walk = (object, path) => {
      if (!object || typeof object !== 'object' || Array.isArray(object)) refuse('the endpoint map is invalid');
      for (const key of Object.keys(object).sort()) {
        const value = object[key];
        // Mail configuration belongs to its separate owner decision; private IPs stay unchanged.
        if (path === 'global.endpoints' && key === 'mail') continue;
        if (value && typeof value === 'object') walk(value, `${path}.${key}`);
        else if (['host', 'url', 'prometheusPush', 'lokiPush'].includes(key)) {
          if (typeof value !== 'string') refuse('an endpoint address must be text');
          const after = moveEndpoint(value, fromDomain, toDomain);
          const host = value.includes('://') ? new URL(value).hostname : value;
          addHost(host);
          if (after !== value) fields.push({path: `${path}.${key}`, before: value, after});
        }
      }
    };
    walk(global.endpoints, 'global.endpoints');
    changes.push({file, targetFile: `clusters/active/${addHost(domain)}.yaml`,
      clusterName: global.clusterName, role: map.role, stage: map.stage, fields});
  }
  const preservedHosts = [];
  for (const host of [...new Set(installedHosts)].sort()) {
    if (addHost(host) === host) preservedHosts.push(host);
  }
  return {fromDomain, toDomain, clusterCount: changes.length, changes,
    hosts: [...hosts.keys()].sort().map(before => ({before, after: hosts.get(before)})),
    preservedHosts, unchanged: ['clusterName', 'role', 'stage', 'release', 'private addresses', 'mail endpoint and platformDomain', 'data', 'keys'],
    cutoverReady: false,
    blockers: ['Manager installation-domain execution and rollback are not available here; do not use slave rename, which rejects masters and removes old DNS.',
      'New-host TLS, persisted URLs, IdP/session continuity, client overrides and final redirect activation require the coordinated cutover gates.']};
}

function command(program, args, input) {
  try { return execFileSync(program, args, {encoding: 'utf8', input, timeout: 45000, maxBuffer: 8 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe']}).trim(); }
  catch { refuse(`${program} read failed; nothing has been changed remotely`, 69); }
}

export function installedIngressHosts(items) {
  if (!Array.isArray(items)) refuse('the installed ingress inventory is invalid');
  const hosts = [];
  for (const item of items) {
    for (const rule of item.spec?.rules ?? []) if (rule.host) hosts.push(rule.host);
    for (const route of item.spec?.routes ?? []) {
      if (typeof route.match !== 'string') refuse('an ingress route has no matcher');
      // Skip quoted literals elsewhere in the expression, such as a PathPrefix argument.
      const matcher = /`[^`]*`|"(?:\\.|[^"\\])*"|\b(HostRegexp|HostSNI|Host)\s*\(/g;
      for (const match of route.match.matchAll(matcher)) {
        if (!match[1]) continue;
        if (match[1] !== 'Host') refuse('an ingress route uses an unsupported hostname matcher; inventory is incomplete');
        const end = route.match.indexOf(')', match.index + match[0].length);
        if (end < 0) refuse('an ingress hostname matcher is malformed');
        const args = route.match.slice(match.index + match[0].length, end);
        if (!/^\s*(?:`[^`]+`|"[^"\\]+")\s*(?:,\s*(?:`[^`]+`|"[^"\\]+")\s*)*$/.test(args))
          refuse('an ingress hostname matcher is malformed');
        for (const argument of args.matchAll(/([`"])([^`"]+)\1/g)) hosts.push(requireHostname(argument[2]));
      }
    }
  }
  return hosts;
}

export async function runDomainPlan(args, repo, requireMachine = false) {
  try {
    if (args.length === 1 && args[0] === '--help') { process.stdout.write(usage + '\n'); return; }
    const options = {};
    for (let i = 0; i < args.length; i++) {
      const key = args[i];
      if (!['--books-fqdn', '--from-domain', '--to-domain', '--fqdn', '--ssh-user', '--dry-run'].includes(key) || key in options)
        refuse(usage, 64);
      if (key === '--dry-run') options[key] = true;
      else {
        if (!args[i + 1] || args[i + 1].startsWith('--')) refuse(usage, 64);
        options[key] = args[++i];
      }
    }
    if (!options['--dry-run']) refuse('only --dry-run is available; cutover must use the reviewed Manager migration', 64);
    for (const key of ['--books-fqdn', '--from-domain', '--to-domain']) requireHostname(options[key]);
    const books = options['--books-fqdn'], from = options['--from-domain'], to = options['--to-domain'];
    if (!books.endsWith('.' + from)) refuse('the books FQDN is outside the source zone');
    if (Boolean(options['--fqdn']) !== Boolean(options['--ssh-user']) || (requireMachine && !options['--fqdn']))
      refuse('--fqdn and --ssh-user are required together for a machine dry run', 64);
    if (options['--fqdn']) {
      requireHostname(options['--fqdn']);
      if (!/^[a-z_][a-z0-9_-]*$/.test(options['--ssh-user'])) refuse('the SSH account is invalid');
    }
    const git = (...argv) => command('git', ['-C', repo, ...argv]);
    const remoteRef = `refs/remotes/origin/${books}`;
    git('fetch', '--quiet', '--no-tags', 'origin', `refs/heads/${books}:${remoteRef}`);
    // FETCH_HEAD is shared by sibling worktrees and another operator's fetch can replace it.
    const commit = git('rev-parse', remoteRef);
    const paths = git('ls-tree', '-r', '--name-only', commit, 'clusters/active').split('\n').filter(file => file.endsWith('.yaml'));
    const maps = paths.map(file => {
      let map;
      try { map = JSON.parse(command('yq', ['-o=json', '.'], git('show', `${commit}:${file}`))); }
      catch { refuse('a cluster map could not be parsed'); }
      return {file, map};
    });
    if (!maps.some(({map}) => map.global?.domain === books && map.role === 'master')) refuse('the books branch has no matching master map');
    planInstallation(maps, from, to);
    let machine = null;
    let installedHosts = [];
    if (options['--fqdn']) {
      const old = options['--fqdn'];
      if (!maps.some(({map}) => map.global?.domain === old)) refuse('the selected machine has no cluster map');
      const target = moveHostname(old, from, to);
      const ssh = (host, cmd) => command('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
        '-o', 'StrictHostKeyChecking=yes', '-o', `HostKeyAlias=${old}`, '--', `${options['--ssh-user']}@${host}`, cmd]);
      const oldIdentity = ssh(old, 'hostname');
      const newIdentity = ssh(target, 'hostname');
      if (!/^[a-z0-9][a-z0-9.-]{0,252}$/.test(oldIdentity)) refuse('the machine hostname is invalid');
      const key = host => {
        const parts = ssh(host, 'cat /etc/ssh/ssh_host_ed25519_key.pub').split(/\s+/);
        if (parts[0] !== 'ssh-ed25519' || !/^[A-Za-z0-9+/]+={0,2}$/.test(parts[1] ?? '')) refuse('the machine has no valid public host key');
        return parts[1];
      };
      const oldKey = key(old), newKey = key(target);
      if (oldKey !== newKey || oldIdentity !== newIdentity) refuse('the new SSH name does not reach the same machine and host key');
      let inventory;
      try { inventory = JSON.parse(ssh(old, 'microk8s.kubectl get ingresses.networking.k8s.io,ingressroutes.traefik.io -A -o json')); }
      catch { refuse('the installed ingress inventory could not be read'); }
      installedHosts = installedIngressHosts(inventory.items);
      machine = {fromFqdn: old, toFqdn: target, hostname: oldIdentity, sameMachine: true, sameHostKey: true,
        hostKeyFingerprint: 'SHA256:' + createHash('sha256').update(Buffer.from(oldKey, 'base64')).digest('base64').replace(/=+$/, ''),
        installedRouteCount: inventory.items.length};
    }
    const result = {...planInstallation(maps, from, to, installedHosts), dryRun: true, sourceCommit: commit,
      booksBranch: {before: books, after: moveHostname(books, from, to)}, machine,
      coverage: {clusterMaps: 'all maps on the books branch', installedIngress: machine ? options['--fqdn'] : 'NOT RUN',
        persistedStores: 'NOT RUN; Manager migration owns this census', clientOverrides: 'NOT RUN; each client needs its own inventory'}};
    result.planDigest = createHash('sha256').update(JSON.stringify(result)).digest('hex');
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  } catch (error) {
    process.stderr.write('domain-move: ' + error.message + '\n');
    process.exitCode = Number.isInteger(error.code) ? error.code : 65;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  await runDomainPlan(process.argv.slice(2), resolve(dirname(fileURLToPath(import.meta.url)), '..'));
