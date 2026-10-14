import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';
import {cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {paramSet, patch, registration, render, yaml} from './tenant-appset-fixture.mjs';

// The typed half of the ApplicationSet, which the other tenant tests do not render: the name, the
// project and the destination of the one Application, as the controller renders them.
const template = execFileSync('yq', ['-o=yaml', '.spec.template', 'clusters/argocd/files/tenants-appset.yaml'], {encoding: 'utf8'});

// The Application the controller builds for each parameter set: the typed template, with the
// templatePatch's sources and namespace labels over it.
const applications = (paramSets, typed = template) => paramSets.flatMap(params => {
  const [named] = render(typed, [params]);
  const [patched] = render(patch, [params]);
  assert.equal(named.error, undefined, named.error);
  assert.equal(patched.error, undefined, patched.error);
  const {metadata, spec} = yaml('.', named.output);
  const {spec: patchSpec} = yaml('.', patched.output);
  return [{name: metadata.name, labels: metadata.labels, project: spec.project, namespace: spec.destination.namespace,
    namespaceLabels: patchSpec.syncPolicy.managedNamespaceMetadata.labels, sources: patchSpec.sources}];
});

const guid = 'aaaaaaaaaaaa';
const stage = 'prod';
const charts = ['charts/engine', 'charts/app', 'charts/auth', 'charts/jobs', 'charts/report', 'charts/web'];
const body = registration(charts, {
  apps: [
    {name: 'workshop', seedReference: true, seedDemo: false, selections: {}, needs: ['report'], path: '/app/workshop'},
    {name: 'events', seedReference: true, seedDemo: false, selections: {}, needs: [], path: '/app/events'},
    {name: 'starter', folder: 'web', site: 'starter', main: true, seedReference: true, seedDemo: true, selections: {},
      needs: [], path: '/admin/starter', sitePath: '/'},
  ],
  members: [{name: 'auth', path: '/auth'}, {name: 'jobs', path: '/jobs'}, {name: 'report', path: '/reports'}, {name: 'web', path: '/'}],
  namespaceLabels: {'platform/redis-consumer': 'true'},
  removedApps: {archive: 'keep'},
  approvedTags: {engine: '0.6.009-stable-20261011000000-abcdef0'},
});
// One chart carries the registration's own value files and values, which ride after the product's.
body.sources[1] = {chart: 'charts/app', valueFiles: ['values-shop.yaml'], values: {app: {replicas: 2}}};
const params = paramSet(guid, stage, body);

// The facts the charts are written against, which are the keys below and no others: `member` and
// `appName` are not among them, `demo` stands only where the registration is a demo.
const tenantKeys = ['apps', 'appsImage', 'appsImageTag', 'approvedTags', 'displayName', 'guid', 'members', 'ownDomain',
  'ownDomainAliases', 'ownDomainRedirects', 'quiesced', 'removedApps', 'seedUsers', 'senderDomain', 'size', 'stage',
  'subdomain', 'suspended', 'zone'];

// Whether the rendered Applications of one registration are the ONE Application of its tenant stage.
const assertOneApplication = (rendered, set) => {
  const {guid: tenant, stage: at} = set.values;
  assert.equal(rendered.length, 1, `one Application per tenant stage, and these are ${rendered.map(application => application.name)}`);
  const [application] = rendered;
  assert.equal(application.name, `${tenant}-${at}`);
  assert.equal(application.project, `${tenant}-${at}`);
  assert.equal(application.namespace, `${tenant}-${at}`);
  assert.deepEqual(application.labels, {'platform/tenant': tenant});
  // The two refs, then the registration's charts in order, then the policy and the quota of this repository.
  const paths = application.sources.map(source => source.ref ?? source.path);
  assert.deepEqual(paths, ['values', 'pins', ...set.sources.map(source => source.chart), 'clusters/units/networkpolicy', 'clusters/units/quota']);
  const chartSources = application.sources.slice(2, 2 + set.sources.length);
  chartSources.forEach(source => {
    const tenantFacts = source.helm.valuesObject.tenant;
    assert.deepEqual(Object.keys(tenantFacts).sort(), (set.demo ? [...tenantKeys, 'demo'] : tenantKeys).sort());
    assert.deepEqual(tenantFacts.apps, set.apps);
    assert.deepEqual(tenantFacts.members, set.members);
    assert.deepEqual(tenantFacts.removedApps, set.removedApps);
    assert.deepEqual(tenantFacts.approvedTags, set.approvedTags);
    assert.equal(tenantFacts.guid, tenant);
    assert.equal(tenantFacts.stage, at);
  });
};

test('a tenant with three apps renders one Application, one namespace and one project, with the whole member set in every chart', () => {
  const rendered = applications([params]);
  assertOneApplication(rendered, params);
  const [application] = rendered;
  assert.deepEqual(application.namespaceLabels, {'platform/tenant': guid, 'platform/tenant-managed': 'true',
    'platform/tenant-stage': stage, 'platform/db-consumer': 'true', 'platform/redis-consumer': 'true'});
  const [, , engine, app] = application.sources;
  assert.deepEqual(app.helm.valueFiles, ['$values/clusters/platform/values-common.yaml', `$values/clusters/platform/values-${stage}.yaml`,
    'values.yaml', `values-${stage}.yaml`, 'values-shop.yaml', `$pins/charts/app/pins-${stage}.yaml`, '$values/clusters/active/__FQDN__.yaml']);
  assert.deepEqual(app.helm.valuesObject.app, {replicas: 2});
  assert.equal(engine.helm.valuesObject.app, undefined);
});

test('two tenants, one of them a demo without an app, render one Application each', () => {
  const bare = paramSet('bbbbbbbbbbbb', 'dev', registration(['charts/engine', 'charts/web'], {apps: [], demo: true}));
  [params, bare].forEach(set => assertOneApplication(applications([set]), set));
});

test('all existing registration generators exclude TLS preparations beside ordinary and build pointers', () => {
  const files = readdirSync('clusters/argocd/files').filter(file => file.endsWith('.yaml') && file !== 'tenant-tls-appset.yaml');
  const texts = [...files.map(file => readFileSync(`clusters/argocd/files/${file}`, 'utf8')),
    readFileSync('clusters/inventories/consumer-build/files/applicationset.yaml', 'utf8')];
  const patterns = texts.flatMap(text => [...text.matchAll(/path: ["']?(registrations\/[^"'\s]+)/g)].map(match => match[1]));
  assert.ok(patterns.length >= 20);
  const accepts = (pattern, path) => new RegExp(`^${pattern.replaceAll('.', '\\.').replaceAll('*', '[^/]*')}$`).test(path);
  const check = patterns => {
    for (const stage of ['dev', 'test', 'prod']) assert.ok(patterns.every(pattern => !accepts(pattern, `registrations/${guid}/tls-${stage}.yaml`)));
  };
  check(patterns);
  assert.throws(() => check([...patterns, 'registrations/*/*.yaml']));
  for (const stage of ['dev', 'test', 'prod']) {
    assert.ok(patterns.some(pattern => accepts(pattern, `registrations/${guid}/${stage}.yaml`)));
    assertOneApplication(applications([paramSet(guid, stage, body)]), paramSet(guid, stage, body));
  }
  assert.ok(patterns.some(pattern => accepts(pattern, `registrations/${guid}/build.yaml`)));
  for (const [file, expression, matches, defect] of [
    ['lifecycle/abandon-installation.sh', /case "\$file" in ([^;]+)\) ;; \*\) continue ;; esac/g,
      (pattern, path) => pattern.split('|').some(glob => accepts(glob, path)), 'registrations/*/*.yaml'],
    ['clusters/inventories/consumer-build/templates/pipeline-release.yaml', /for reg in [^;\n]*?\/(registrations\/[^;\n]+); do/g,
      (pattern, path, stage) => accepts(pattern.replaceAll('"', '').replaceAll('${STAGE}', stage), path), 'registrations/*/*.yaml'],
  ]) {
    const text = readFileSync(file, 'utf8');
    const checkReader = source => {
      const readers = [...source.matchAll(expression)];
      assert.equal(readers.length, 2, file);
      for (const [, pattern] of readers) for (const stage of ['dev', 'test', 'prod']) {
        assert.ok(matches(pattern, `registrations/${guid}/${stage}.yaml`, stage), `${file}: ${stage} innocent`);
        assert.ok(!matches(pattern, `registrations/${guid}/tls-${stage}.yaml`, stage), `${file}: TLS preparation`);
        assert.ok(!matches(pattern, `registrations/${guid}/build.yaml`, stage), `${file}: build pointer`);
      }
    };
    checkReader(text);
    for (const match of text.matchAll(expression)) {
      const planted = text.slice(0, match.index) + match[0].replace(match[1], defect) + text.slice(match.index + match[0].length);
      assert.throws(() => checkReader(planted), /TLS preparation/);
    }
  }
});

test('ordinary chart bump excludes TLS preparation from actual release selection and rendering', t => {
  const work = mkdtempSync(join(tmpdir(), 'tenant-release-'));
  t.after(() => rmSync(work, {recursive: true, force: true}));
  const pipeline = readFileSync('clusters/inventories/consumer-build/templates/pipeline-release.yaml', 'utf8');
  const section = pipeline.match(/if \[ -n "\$\{BUMPED_CHARTS\}" \]; then\n[\s\S]+?(?=\n\s+# ── class \(c\):)/)?.[0];
  assert.ok(section, 'actual tenant chart-hit block');
  const [script] = render(section, [{}]);
  assert.equal(script.error, undefined, script.error);
  const directory = join(work, 'hostyour-cloud/clusters/argocd/files');
  cpSync('clusters/argocd/files', directory, {recursive: true});
  cpSync('clusters/inventories/consumer-build/files/applicationset.yaml', join(directory, 'consumer-build.yaml'));
  const tlsFile = join(directory, 'tenant-tls-appset.yaml');
  const tlsText = readFileSync(tlsFile, 'utf8').replaceAll('__CLUSTER_NAME__', 'apps1');
  writeFileSync(tlsFile, tlsText);
  const tls = yaml('.', tlsText);
  const tlsBody = {cluster: 'apps1', namespaceLabels: {'platform/redis-consumer': 'true'}, secretNames: ['workshop-tls']};
  const prepared = paramSet(guid, stage, tlsBody);
  prepared.path.filename = `tls-${stage}.yaml`;
  const [named] = render(JSON.stringify(tls.spec.template), [prepared]);
  const [patched] = render(tls.spec.templatePatch, [prepared]);
  assert.equal(named.error, undefined, named.error);
  assert.equal(patched.error, undefined, patched.error);
  assert.equal(yaml('.metadata.name', named.output), `tenant-tls-${guid}-${stage}`);
  assert.equal(yaml('.spec.syncPolicy.managedNamespaceMetadata.labels."platform/tenant"', patched.output), guid);
  assert.deepEqual(yaml('.spec.sources[0].helm.valuesObject.secretNames', patched.output), tlsBody.secretNames);
  const registrations = join(work, 'deploy-books/registrations');
  mkdirSync(join(registrations, guid), {recursive: true});
  writeFileSync(join(registrations, guid, 'prod.yaml'), JSON.stringify(body));
  writeFileSync(join(registrations, guid, 'tls-prod.yaml'), JSON.stringify(tlsBody));
  writeFileSync(join(registrations, guid, 'test.yaml'), JSON.stringify(body));
  writeFileSync(join(registrations, guid, 'build.yaml'), JSON.stringify({name: 'fixture', suspended: false,
    repoURL: 'https://github.com/check/check.git', builds: []}));
  mkdirSync(join(registrations, 'bbbbbbbbbbbb'));
  writeFileSync(join(registrations, 'bbbbbbbbbbbb', 'prod.yaml'), JSON.stringify(registration(['charts/web'])));
  const hits = join(work, 'hits');
  const run = () => {
    writeFileSync(hits, '');
    execFileSync('bash', ['-euo', 'pipefail', '-c', script.output], {encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'],
      env: {...process.env, WORK: work, BUMPED_CHARTS: ' app', STAGE: stage, TENANT_REGS: registrations, HITS_FILE: hits}});
    assert.equal(readFileSync(hits, 'utf8'), `tenant ${guid}-${stage} apps1\n`);
  };
  run();
  tls.spec.template.metadata.labels = {'platform/tenant': '{{ .values.guid }}'};
  writeFileSync(tlsFile, JSON.stringify(tls));
  assert.throws(run, /tenant-tls: preparation identity does not match its path and target cluster/);
});

// What the retired matrix did: a parameter set per standing member, the member's fields over the
// registration's, and a name that carries the member. The check must go red on it and green above.
test('PLANTED DEFECT: an Application per member is refused, and the planted innocent above is not', () => {
  const perMember = params.members.map(member => ({...params, name: member.name}));
  const perMemberTemplate = template.replaceAll('{{ .values.guid }}-{{ .values.stage }}', '{{ .values.guid }}-{{ .name }}-{{ .values.stage }}');
  assert.notEqual(perMemberTemplate, template);
  const planted = applications(perMember, perMemberTemplate);
  assert.deepEqual(planted.map(application => application.name),
    ['auth', 'jobs', 'report', 'web'].map(member => `${guid}-${member}-${stage}`));
  assert.throws(() => assertOneApplication(planted, params), /one Application per tenant stage/);
});
