import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync, readdirSync} from 'node:fs';
import test from 'node:test';

// Every host behind the identity provider's forward auth is answered by the embedded outpost with one
// provider, and the group plane-users must pass that gate at plane.<fqdn> alone. The outpost picks the
// provider of a request (authentik internal/outpost/proxyv2/handlers.go lookupApp, proxyv2 2026.5.6): the
// provider whose external host is the host; and only where none has it, any one of the forward_domain
// providers whose cookie domain ends the host, at random per request. So for each gated host this test
// collects those candidates and demands that the application of every one of them admits `admins` alone,
// and at plane.<fqdn> `admins` and `plane-users`. It is stricter than the outpost, which takes the longest
// cookie domain among the matches: a longer cookie domain added later changes no verdict here.

const blueprintDirectory = 'clusters/bootstrap/idp/blueprints';
const blueprintTexts = Object.fromEntries(readdirSync(blueprintDirectory).filter(name => name.endsWith('.yaml')).sort()
  .map(name => [name, readFileSync(`${blueprintDirectory}/${name}`, 'utf8')]));

const yq = (text, path = '.') => JSON.parse(execFileSync('yq', ['-o=json', path, '-'], {input: text, encoding: 'utf8'}));
const hostOf = text => text.replace('{{ .Values.global.domain }}', '<fqdn>');
const PLANE = 'plane.<fqdn>';
const ADMITTED = host => (host === PLANE ? ['admins', 'plane-users'] : ['admins']);

// The files of the repository that put a route behind the forward auth, and the hosts each one gates. A chart
// that leaves its ingress off gates nothing. Plane's address is written by deploy-branch into
// installation/values/plane.yaml, outside this repository; its provider's external host is plane.<fqdn> (scripts/plane.test.mjs).
const valuesHosts = text => { const ingress = yq(text).ingress?.ingress; return ingress?.enabled ? [hostOf(ingress.host)] : []; };
const SOURCES = {
  'clusters/bootstrap/headlamp/ingressroute.tpl': text => [...text.matchAll(/Host\(`([^`]+)`\)/g)].map(match => match[1]),
  'clusters/inventories/tekton/values-common.yaml': valuesHosts,
  'clusters/inventories/dbgate/values-common.yaml': valuesHosts,
  'clusters/inventories/plane/values-common.yaml': () => [PLANE],
};
const usesForwardAuth = text => text.split('\n').some(line => !/^\s*#/.test(line) && /idp-forwardauth@kubernetescrd|^\s*-\s*name: forwardauth\s*$/.test(line));

const repositoryFiles = (directory = 'clusters') => readdirSync(directory, {withFileTypes: true}).flatMap(entry => {
  const path = `${directory}/${entry.name}`;
  if (entry.isDirectory()) return repositoryFiles(path);
  return /(^values[^/]*\.yaml|\.tpl)$/.test(entry.name) ? [path] : [];
});
const repositoryTexts = Object.fromEntries(repositoryFiles().map(path => [path, readFileSync(path, 'utf8')]));

const hostPattern = value => { const [text, domain] = value; assert.equal(domain, 'IDP_DOMAIN'); return text.replace('https://', '').replace('%s', '<fqdn>'); };
const nameOf = reference => reference[1][1];

/** Every way a host behind the forward auth reaches an application that admits more than it should, named. */
function gateFindings(blueprints, files) {
  const found = [];
  const providers = [], applications = [], bindings = [], outpost = [];
  for (const text of Object.values(blueprints)) {
    for (const entry of yq(text).entries ?? []) {
      const {model, attrs = {}, identifiers = {}} = entry;
      if (model === 'authentik_providers_proxy.proxyprovider') providers.push({name: attrs.name, host: hostPattern(attrs.external_host), mode: attrs.mode, cookie: hostPattern(attrs.cookie_domain).replace(/^\./, '')});
      if (model === 'authentik_core.application') applications.push({slug: attrs.slug, provider: attrs.provider && nameOf(attrs.provider)});
      if (model === 'authentik_policies.policybinding') bindings.push({slug: nameOf(identifiers.target), group: nameOf(identifiers.group)});
      if (model === 'authentik_outposts.outpost') outpost.push(...attrs.providers.map(nameOf));
    }
  }
  for (const [file, text] of Object.entries(files)) {
    if (usesForwardAuth(text) && !(file in SOURCES)) found.push(`${file} puts a route behind the forward auth, and this test does not know the hosts it gates`);
  }
  for (const [file, hosts] of Object.entries(SOURCES)) {
    if (!usesForwardAuth(files[file] ?? '')) { found.push(`${file} no longer names the forward auth, so it is no source of a gated host`); continue; }
    for (const host of hosts(files[file])) {
      const bound = providers.filter(provider => outpost.includes(provider.name));
      const claimed = bound.filter(provider => provider.host === host);
      const candidates = claimed.length > 0 ? claimed : bound.filter(provider => provider.mode === 'forward_domain' && host.endsWith(provider.cookie));
      if (candidates.length === 0) found.push(`${host} is answered by no provider of the outpost`);
      for (const candidate of candidates) {
        const application = applications.find(each => each.provider === candidate.name);
        const admitted = bindings.filter(binding => binding.slug === application?.slug).map(binding => binding.group).sort();
        if (JSON.stringify(admitted) !== JSON.stringify(ADMITTED(host))) found.push(`${host} is answered by ${candidate.name}, whose application ${application?.slug} admits ${JSON.stringify(admitted)}, not ${JSON.stringify(ADMITTED(host))} alone`);
      }
    }
  }
  return found;
}

const without = (texts, name) => Object.fromEntries(Object.entries(texts).filter(([file]) => file !== name));
const OUTPOST = '99-z-outpost-bindings.yaml';
const outpostWithout = text => text.replaceAll('  - !Find [authentik_providers_proxy.proxyprovider, [name, Headlamp Forward Auth]]\n', '')
  .replaceAll('        - !Find [authentik_providers_proxy.proxyprovider, [name, Headlamp Forward Auth]]\n', '');
// The blueprints as they stood before kube.<fqdn> had a provider of its own.
const withoutHeadlampGate = () => ({...without(blueprintTexts, '99-proxy-headlamp.yaml'), [OUTPOST]: outpostWithout(blueprintTexts[OUTPOST])});
const ingress = `${'  routes:\n'}    - match: Host(\`new.<fqdn>\`)\n      middlewares:\n        - name: forwardauth\n          namespace: idp\n`;
const planeUsersBinding = slug => `  - model: authentik_policies.policybinding
    identifiers:
      target: !Find [authentik_core.application, [slug, ${slug}]]
      group: !Find [authentik_core.group, [name, plane-users]]
`;
const provider = (host, mode = 'forward_domain') => `version: 1
metadata:
  name: Planted ${host}
entries:
  - model: authentik_providers_proxy.proxyprovider
    attrs:
      name: Planted ${host}
      external_host: !Format ["https://${host}.%s", !Env IDP_DOMAIN]
      mode: ${mode}
      cookie_domain: !Format [".%s", !Env IDP_DOMAIN]
  - model: authentik_core.application
    attrs:
      slug: planted-${host}
      provider: !Find [authentik_providers_proxy.proxyprovider, [name, Planted ${host}]]
  - model: authentik_policies.policybinding
    identifiers:
      target: !Find [authentik_core.application, [slug, planted-${host}]]
      group: !Find [authentik_core.group, [name, admins]]
`;

test('every host behind the forward auth is answered by providers whose applications admit admins, and plane-users at plane alone', () => {
  assert.deepEqual(gateFindings(blueprintTexts, repositoryTexts), []);
  assert.deepEqual(Object.keys(SOURCES).filter(file => !(file in repositoryTexts)), [], 'every source exists');
});

test('PLANTED DEFECT: kube.<fqdn> without a provider of its own is answered by Plane\'s and found', () => {
  assert.deepEqual(gateFindings(withoutHeadlampGate(), repositoryTexts), [
    'kube.<fqdn> is answered by Plane, whose application plane admits ["admins","plane-users"], not ["admins"] alone',
  ]);
});

test('PLANTED DEFECT: a second group on the gate, a gate off the outpost, a new gated host nobody claims, an unknown gated file, and plane-users on Tekton or none at Plane are found', () => {
  const planted = {
    'plane-users admitted by the gate of kube': [{...blueprintTexts, '99-proxy-headlamp.yaml': blueprintTexts['99-proxy-headlamp.yaml'] + planeUsersBinding('headlamp-forward-auth')}, repositoryTexts],
    'the gate of kube not bound to the outpost': [{...blueprintTexts, [OUTPOST]: outpostWithout(blueprintTexts[OUTPOST])}, repositoryTexts],
    'plane-users admitted to Tekton': [{...blueprintTexts, '99-proxy-tekton.yaml': blueprintTexts['99-proxy-tekton.yaml'].replace('name, admins]]\n      order', 'name, plane-users]]\n      order')}, repositoryTexts],
    'plane without plane-users': [{...blueprintTexts, '99-proxy-plane.yaml': blueprintTexts['99-proxy-plane.yaml'].replace(/  - id: plane-plane-users-binding[\s\S]*$/, '')}, repositoryTexts],
    'a new gated host with a route of its own and no provider': [blueprintTexts, {...repositoryTexts, 'clusters/bootstrap/headlamp/ingressroute.tpl': repositoryTexts['clusters/bootstrap/headlamp/ingressroute.tpl'] + ingress}],
    'a gated file the test does not know': [blueprintTexts, {...repositoryTexts, 'clusters/bootstrap/planted/ingressroute.tpl': ingress}],
  };
  for (const [name, [blueprints, files]] of Object.entries(planted)) {
    assert.notDeepEqual(gateFindings(blueprints, files), [], name);
  }
  assert.notEqual(planted['plane without plane-users'][0]['99-proxy-plane.yaml'], blueprintTexts['99-proxy-plane.yaml'], 'the plant matched');
  assert.notEqual(planted['plane-users admitted to Tekton'][0]['99-proxy-tekton.yaml'], blueprintTexts['99-proxy-tekton.yaml'], 'the plant matched');
});

test('PLANTED INNOCENT: Plane in forward_single mode beside no gate for kube, a new host with its own provider, and a comment naming the forward auth change nothing', () => {
  // Plane's provider stays a candidate for plane.<fqdn> by its external host in either mode and leaves the fallback for kube.<fqdn> to Tekton's.
  const single = {...withoutHeadlampGate(), '99-proxy-plane.yaml': blueprintTexts['99-proxy-plane.yaml'].replace('\n      mode: forward_domain', '\n      mode: forward_single')};
  assert.notEqual(single['99-proxy-plane.yaml'], blueprintTexts['99-proxy-plane.yaml']);
  assert.deepEqual(gateFindings(single, repositoryTexts), []);
  const route = {...repositoryTexts, 'clusters/bootstrap/headlamp/ingressroute.tpl': repositoryTexts['clusters/bootstrap/headlamp/ingressroute.tpl'] + ingress};
  const claimed = {...blueprintTexts, '99-proxy-new.yaml': provider('new'),
    [OUTPOST]: blueprintTexts[OUTPOST].replace(/^(\s+)- !Find \[authentik_providers_proxy\.proxyprovider, \[name, Headlamp Forward Auth\]\]$/gm,
      (line, indent) => `${line}\n${indent}- !Find [authentik_providers_proxy.proxyprovider, [name, Planted new]]`)};
  assert.equal(claimed[OUTPOST].match(/Planted new/g).length, 2, 'the plant matched');
  assert.deepEqual(gateFindings(claimed, route), []);
  assert.deepEqual(gateFindings(blueprintTexts, {...repositoryTexts, 'clusters/inventories/planted/values-common.yaml': '# the annotation idp-forwardauth@kubernetescrd would put a route behind the gate\n'}), []);
});
