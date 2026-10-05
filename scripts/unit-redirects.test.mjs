import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// The standin cluster map answers global.unitApex check.example.invalid; the old apex below is
// what a cluster map carries in global.previousUnitApex after the installation moved its units.
const previous = 'old.example.invalid';
const stageApex = {dev: 'dev.check.example.invalid', test: 'test.check.example.invalid', prod: 'check.example.invalid'};
const previousStageApex = {dev: `dev.${previous}`, test: `test.${previous}`, prod: previous};

const docs = input => JSON.parse(execFileSync('yq', ['ea', '-o=json', '[.]', '-'], {input, encoding: 'utf8'})).filter(Boolean);
const helm = args => execFileSync('helm', ['template', ...args], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
const argocd = (...extra) => helm(['argocd-apps', 'clusters/argocd', '--namespace', 'argocd',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'scripts/standin/installation-values.yaml',
  '-f', 'scripts/standin/cluster-map.yaml', ...extra]);
const withPrevious = apex => argocd('--set', `global.previousUnitApex=${apex}`);
// helm prints every document under its own `---` and `# Source:` line, kinds in its install order.
const split = output => output.split(/^(?=---\n)/m);
const isRedirect = doc => /^kind: (AppProject|ApplicationSet)\nmetadata:\n  name: (unit|consumer|tenant)-redirects$/m.test(doc);

test('an absent previousUnitApex renders byte for byte what a set one renders, less its three documents', () => {
  const without = argocd();
  const withKey = split(withPrevious(previous));
  assert.equal(split(without).filter(isRedirect).length, 0);
  assert.equal(withKey.filter(isRedirect).length, 3);
  assert.equal(withKey.filter(doc => !isRedirect(doc)).join(''), without);
});

test('the redirect documents have every marker replaced', () => {
  for (const doc of split(withPrevious(previous)).filter(isRedirect)) assert.doesNotMatch(doc, /__[A-Z_]+__/);
});

// An old apex that is the new one, or a zone above or below it, would make an old host one a unit
// answers at today, and its redirect would take that unit's traffic.
test('an old apex equal to the unit apex, under it or above it fails the render', () => {
  for (const apex of ['check.example.invalid', 'old.check.example.invalid', 'example.invalid']) {
    assert.throws(() => withPrevious(apex), /previousUnitApex/, apex);
  }
});

const rendered = docs(withPrevious(previous));
const named = (kind, name) => rendered.find(doc => doc.kind === kind && doc.metadata.name === name);
const consumers = named('ApplicationSet', 'consumer-redirects');
const tenants = named('ApplicationSet', 'tenant-redirects');
const project = named('AppProject', 'unit-redirects');

test('the redirects select exactly the registrations the units select', () => {
  assert.deepEqual(consumers.spec.generators, named('ApplicationSet', 'consumer-apps').spec.generators);
  const [units] = named('ApplicationSet', 'tenants').spec.generators;
  assert.deepEqual(tenants.spec.generators, [{git: units.matrix.generators[0].git, selector: units.selector}]);
});

// The template and its patch rendered once per parameter set, as the ApplicationSet controller
// renders them (scripts/appset-render). Each answer is {output} or {error}.
const render = (appset, paramSets) => {
  const run = template => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
    input: JSON.stringify({template, options: appset.spec.goTemplateOptions, params: paramSets}), encoding: 'utf8'}));
  const template = execFileSync('yq', ['-o=yaml', '.'], {input: JSON.stringify(appset.spec.template), encoding: 'utf8'});
  return run(template).map((whole, at) => {
    const patch = run(appset.spec.templatePatch)[at];
    assert.equal(whole.error, undefined, whole.error);
    assert.equal(patch.error, undefined, patch.error);
    const application = docs(whole.output)[0];
    return {name: application.metadata.name, application, patch: docs(patch.output)[0]};
  });
};
const redirectsOf = patch => patch.spec.sources.find(source => source.path === 'clusters/units/redirect').helm.valuesObject.redirects;
const fileParams = (dir, stage, body, values) => ({
  ...body,
  path: {path: `registrations/${dir}`, basename: dir, filename: `${stage}.yaml`, segments: ['registrations', dir]},
  values: {stage, ...values},
});

test('a consumer redirects its old unit host, named by its host label or else its name', () => {
  const sets = [
    fileParams('shop', 'prod', {name: 'shop', host: 'store', cluster: 'check'}),
    fileParams('shop', 'test', {name: 'shop', host: 'store', cluster: 'check'}),
    fileParams('post', 'dev', {name: 'post', cluster: 'check'}),
  ];
  const results = render(consumers, sets);
  assert.deepEqual(results.map(result => result.name), ['shop-redirect-prod', 'shop-redirect-test', 'post-redirect-dev']);
  assert.deepEqual(results.map(result => redirectsOf(result.patch)), [
    [{from: `store.${previousStageApex.prod}`, to: `store.${stageApex.prod}`}],
    [{from: `store.${previousStageApex.test}`, to: `store.${stageApex.test}`}],
    [{from: `post.${previousStageApex.dev}`, to: `post.${stageApex.dev}`}],
  ]);
  for (const {application} of results) {
    assert.equal(application.spec.project, 'unit-redirects');
    assert.equal(application.spec.destination.namespace, 'unit-redirects');
  }
});

// The deploy charts serve every member of a tenant routed by host at <member>.<zone>, and take an
// empty routing for host (digita-lib.routing); the zone itself is served either way.
test('a tenant redirects its old zone, and the old host of every member when routed by host', () => {
  const tenant = (routing, members) => ({cluster: 'check', subdomain: 'acme', routing, ownDomain: '',
    members: members.map(name => ({name, namespaceLabels: {}, sources: []}))});
  const sets = [
    fileParams('aaaaaaaaaaaa', 'prod', tenant('path', ['web', 'auth']), {guid: 'aaaaaaaaaaaa'}),
    fileParams('bbbbbbbbbbbb', 'test', tenant('host', ['web', 'auth']), {guid: 'bbbbbbbbbbbb'}),
    fileParams('cccccccccccc', 'dev', tenant('', ['web']), {guid: 'cccccccccccc'}),
  ];
  const results = render(tenants, sets);
  assert.deepEqual(results.map(result => result.name),
    ['aaaaaaaaaaaa-redirect-prod', 'bbbbbbbbbbbb-redirect-test', 'cccccccccccc-redirect-dev']);
  const pair = (host, stage) => ({from: `${host}.${previousStageApex[stage]}`, to: `${host}.${stageApex[stage]}`});
  assert.deepEqual(results.map(result => redirectsOf(result.patch)), [
    [pair('acme', 'prod')],
    [pair('acme', 'test'), pair('web.acme', 'test'), pair('auth.acme', 'test')],
    [pair('acme', 'dev'), pair('web.acme', 'dev')],
  ]);
});

const pairs = [{from: 'shop.old.example.invalid', to: 'shop.check.example.invalid'},
  {from: 'web.acme.test.old.example.invalid', to: 'web.acme.test.check.example.invalid'}];
const chart = docs(helm(['redirect', 'clusters/units/redirect', '--namespace', 'unit-redirects',
  '-f', 'clusters/platform/values-common.yaml', '--set-json', `redirects=${JSON.stringify(pairs)}`]));

test('the chart answers each old host over https with a permanent redirect to its twin', () => {
  assert.equal(chart.length, 3 * pairs.length);
  for (const {from, to} of pairs) {
    const of = kind => chart.find(doc => doc.kind === kind && doc.metadata.name === from);
    assert.deepEqual(of('Certificate').spec, {secretName: `${from}-tls`, dnsNames: [from],
      issuerRef: {kind: 'ClusterIssuer', name: 'platform-acme'}});
    const {redirectRegex} = of('Middleware').spec;
    assert.equal(redirectRegex.permanent, true);
    // Path and query survive: Traefik matches the regex against the whole request URL.
    assert.equal(`https://${from}/a/b?c=1`.replace(new RegExp(redirectRegex.regex), redirectRegex.replacement.replace('${1}', '$1')),
      `https://${to}/a/b?c=1`);
    assert.deepEqual(of('IngressRoute').spec, {entryPoints: ['websecure'],
      routes: [{kind: 'Rule', match: `Host(\`${from}\`)`, middlewares: [{name: from}],
        services: [{name: 'noop@internal', kind: 'TraefikService'}]}],
      tls: {secretName: `${from}-tls`}});
  }
});

test('the project admits every kind the chart renders, into its one namespace', () => {
  const admitted = project.spec.namespaceResourceWhitelist.map(({group, kind}) => `${group}/${kind}`);
  for (const doc of chart) assert.ok(admitted.includes(`${doc.apiVersion.split('/')[0]}/${doc.kind}`), doc.kind);
  assert.deepEqual(project.spec.destinations.map(({namespace}) => namespace), ['unit-redirects']);
});
