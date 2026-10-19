import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const yaml = (expression, input) => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input, encoding: 'utf8'}));
const FILE = 'clusters/argocd/files/site-telemetry-registrations-appset.yaml';

// THE REGISTRATIONS: what the ApplicationSet hands the chart, as the controller renders the template
// patch (scripts/appset-render). Each answer is {output} or {error}.
const appset = yaml('select(.kind == "ApplicationSet") | .spec', readFileSync(FILE, 'utf8'));
const render = (template, paramSets) => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
  input: JSON.stringify({template, options: appset.goTemplateOptions, params: paramSets}), encoding: 'utf8'}));
const params = (guid, stage, registration) => ({
  cluster: 'apps1', subdomain: 'acme', ownDomain: '', members: [],
  path: {path: `registrations/${guid}`, basename: guid, filename: `${stage}.yaml`, segments: ['registrations', guid]},
  values: {guid, stage},
  ...registration,
});
const WEBSITES = [
  {name: 'workshop', path: '/app/workshop'},
  {name: 'starter', folder: 'web', site: 'starter', main: true, path: '/admin/starter', sitePath: '/'},
  {name: 'blog', folder: 'web', site: 'blog', main: false, path: '/admin/blog', sitePath: '/web/blog'},
];
const tenants = [
  // The tenant with its own domain behind Cloudflare, two websites and an app that is not one.
  {guid: 'aaaaaaaaaaaa', stage: 'prod', registration: {ownDomain: 'shop.example.test', proxiedHosts: ['shop.example.test'], apps: WEBSITES},
    expected: {guid: 'aaaaaaaaaaaa', stage: 'prod', host: 'shop.example.test', proxiedHosts: ['shop.example.test'],
      sites: [{name: 'starter', sitePath: '/', main: true}, {name: 'blog', sitePath: '/web/blog', main: false}]}},
  // The planted innocent: reached at its zone, a registration without `proxiedHosts` and without a website.
  {guid: 'bbbbbbbbbbbb', stage: 'dev', registration: {apps: [WEBSITES[0]]},
    expected: {guid: 'bbbbbbbbbbbb', stage: 'dev', host: 'acme.__STAGE_APEX_DEV__', proxiedHosts: [], sites: []}},
  // A registration written before `apps` existed.
  {guid: 'cccccccccccc', stage: 'test', registration: {},
    expected: {guid: 'cccccccccccc', stage: 'test', host: 'acme.__STAGE_APEX_TEST__', proxiedHosts: [], sites: []}},
];
const paramSets = tenants.map(({guid, stage, registration}) => params(guid, stage, registration));
const handedTo = patch => render(patch, paramSets).map((result, at) => {
  assert.equal(result.error, undefined, `${tenants[at].guid}: ${result.error}`);
  return yaml('.spec.sources[] | select(.path == "clusters/units/site-telemetry-registration") | .helm.valuesObject.tenant', result.output);
});

test('every tenant is handed its host, its proxied hosts and its websites alone', () => {
  assert.deepEqual(handedTo(appset.templatePatch), tenants.map(({expected}) => expected));
});

test('PLANTED DEFECT: a patch that hands the zone alone fails the tenant with an own domain, and only that one', () => {
  const zoneAlone = appset.templatePatch.replace('.ownDomain | default $zone', '$zone');
  assert.notEqual(zoneAlone, appset.templatePatch);
  const hosts = handedTo(zoneAlone).map(({host}) => host);
  assert.notEqual(hosts[0], tenants[0].expected.host);
  assert.deepEqual(hosts.slice(1), tenants.slice(1).map(({expected}) => expected.host));
});

test('PLANTED DEFECT: a patch that takes every app for a website is refused at the app that is not one', () => {
  const everyApp = appset.templatePatch.replace('{{- if hasKey . "site" }}', '{{- if true }}');
  assert.notEqual(everyApp, appset.templatePatch);
  const [first] = render(everyApp, paramSets);
  assert.match(first.error ?? '', /site/);
});

test('the project admits ConfigMaps in the namespace observability and nothing else', () => {
  const project = yaml('select(.kind == "AppProject") | .spec', readFileSync(FILE, 'utf8'));
  assert.deepEqual(project.destinations.map(({namespace}) => namespace), ['observability']);
  assert.deepEqual(project.namespaceResourceWhitelist, [{group: '', kind: 'ConfigMap'}]);
  assert.equal(appset.template.spec.destination.namespace, 'observability');
});

const helm = (...args) => spawnSync('helm', ['template', ...args], {encoding: 'utf8'});
const registrationChart = (...set) => helm('site-telemetry-registration', 'clusters/units/site-telemetry-registration',
  '--namespace', 'observability', '--set-string', 'tenant.guid=aaaaaaaaaaaa,tenant.stage=prod,tenant.host=shop.example.test', ...set);

test('the ConfigMap holds what the service reads, under the label it lists by', () => {
  const rendered = registrationChart('--set', 'tenant.sites[0].name=starter,tenant.sites[0].sitePath=/,tenant.sites[0].main=true');
  assert.equal(rendered.status, 0, rendered.stderr);
  const configMap = yaml('select(.kind == "ConfigMap")', rendered.stdout);
  assert.equal(configMap.metadata.name, 'site-telemetry-registration-aaaaaaaaaaaa-prod');
  assert.equal(configMap.metadata.namespace, 'observability');
  assert.equal(configMap.metadata.labels['platform/site-telemetry-registration'], 'true');
  const facts = JSON.parse(configMap.data['registration.json']);
  assert.deepEqual(facts, {tenant: 'aaaaaaaaaaaa-prod', hosts: ['shop.example.test'], issuers: ['shop.example.test'], proxiedHosts: [],
    sites: [{name: 'starter', sitePath: '/', main: true}]});
  // The service drops a registration whose tenant does not match its own pattern, and lists by this label.
  const service = readFileSync('clusters/inventories/observability/files/site_telemetry.py', 'utf8');
  assert.ok(service.includes('platform/site-telemetry-registration=true'));
  const [, pattern] = service.match(/^TENANT = re\.compile\(r"(.*)"\)$/m);
  assert.match(facts.tenant, new RegExp(pattern));
});

test('a registration without a host is refused', () => {
  const rendered = registrationChart('--set-string', 'tenant.host=');
  assert.notEqual(rendered.status, 0);
  assert.match(rendered.stderr, /tenant\.host is empty/);
});

// THE EMISSION: the reconciler's chart renders the file where the books are kept and nowhere else.
const apps = (...set) => helm('argocd-apps', 'clusters/argocd', '-f', 'scripts/standin/cluster-map.yaml',
  '--set', 'revision=0123456789abcdef0123456789abcdef01234567', ...set);
const emitted = rendered => [...rendered.stdout.matchAll(/^# file: (.*)$/gm)].map(([, name]) => name);

test('the registrations are emitted on the cluster that keeps the books, and on no other', () => {
  const books = apps();
  assert.equal(books.status, 0, books.stderr);
  assert.ok(emitted(books).includes('site-telemetry-registrations-appset.yaml'));
  const slave = apps('--set', 'global.servicesLocal.vault=false');
  assert.equal(slave.status, 0, slave.stderr);
  assert.ok(!emitted(slave).includes('site-telemetry-registrations-appset.yaml'));
  assert.ok(emitted(slave).includes('tenants-appset.yaml'), 'the planted innocent: a slave still carries the tenants');
});
