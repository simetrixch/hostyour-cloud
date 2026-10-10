import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

const yaml = (expression, input) => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input, encoding: 'utf8'}));

// THE TARGETS: the host each demo tenant's stage is handed, as the ApplicationSet controller renders
// the template patch (scripts/appset-render). Each answer is {output} or {error}.
const appset = JSON.parse(execFileSync('yq', ['-o=json', 'select(.kind == "ApplicationSet") | .spec',
  'clusters/argocd/files/e2e-targets-appset.yaml'], {encoding: 'utf8'}));
const render = (template, paramSets) => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
  input: JSON.stringify({template, options: appset.goTemplateOptions, params: paramSets}), encoding: 'utf8'}));
const params = (guid, ownDomain) => ({
  cluster: 'apps1', subdomain: 'acme', ownDomain, apps: [], demo: true, members: [],
  path: {path: `registrations/${guid}`, basename: guid, filename: 'prod.yaml', segments: ['registrations', guid]},
  values: {guid, stage: 'prod'},
});
// The Manager writes ownDomain into every registration, empty where the tenant is reached at its zone.
const targets = [
  {guid: 'aaaaaaaaaaaa', ownDomain: 'shop.example.test', host: 'shop.example.test'},
  {guid: 'bbbbbbbbbbbb', ownDomain: '', host: 'acme.__STAGE_APEX_PROD__'},
];
const paramSets = targets.map(({guid, ownDomain}) => params(guid, ownDomain));
const hostsOf = patch => render(patch, paramSets).map((result, at) => {
  assert.equal(result.error, undefined, `${targets[at].guid}: ${result.error}`);
  return yaml('.spec.sources[] | select(.path == "clusters/units/e2e-target") | .helm.valuesObject.target', result.output);
});

test('every demo target is handed its own domain, else its zone', () => {
  assert.deepEqual(hostsOf(appset.templatePatch), targets.map(({guid, host}) => ({guid, stage: 'prod', host})));
});

test('PLANTED DEFECT: a patch that hands the zone alone fails the tenant with an own domain, and only that one', () => {
  const zoneAlone = appset.templatePatch.replace('.ownDomain | default $zone', '$zone');
  assert.notEqual(zoneAlone, appset.templatePatch);
  const hosts = hostsOf(zoneAlone).map(({host}) => host);
  assert.notEqual(hosts[0], targets[0].host);
  assert.equal(hosts[1], targets[1].host, 'the planted innocent: the tenant reached at its zone');
});

const helm = (...args) => spawnSync('helm', ['template', ...args], {encoding: 'utf8'});
const targetChart = (host) => helm('e2e-target', 'clusters/units/e2e-target', '--namespace', 'e2e-runner',
  '-f', 'clusters/inventories/e2e-runner/values-common.yaml',
  '--set-string', `target.guid=aaaaaaaaaaaa,target.stage=prod,target.host=${host}`);

test('the target Secret pairs the password of its tenant and stage with its host', () => {
  const rendered = targetChart('shop.example.test');
  assert.equal(rendered.status, 0, rendered.stderr);
  const secret = yaml('select(.kind == "ExternalSecret")', rendered.stdout);
  assert.equal(secret.spec.target.name, 'e2e-aaaaaaaaaaaa-prod');
  assert.equal(secret.spec.secretStoreRef.name, 'e2e-passwords');
  assert.equal(secret.spec.target.template.data.host, 'shop.example.test');
  assert.deepEqual(secret.spec.data.map(({remoteRef: {key, property}}) => ({key, property})),
    [{key: 'prod/tenants/aaaaaaaaaaaa/e2e', property: 'password'}]);
});

test('a target without a host is refused', () => {
  const rendered = targetChart('');
  assert.notEqual(rendered.status, 0);
  assert.match(rendered.stderr, /target\.host is empty/);
});

// THE RUN: the Task as master renders it, with a pin standing in for the release's.
const runner = helm('e2e-runner', 'clusters/inventories/e2e-runner', '--namespace', 'e2e-runner',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
  '-f', 'clusters/inventories/e2e-runner/values-common.yaml', '-f', 'clusters/inventories/e2e-runner/values-prod.yaml',
  '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml',
  '--set-string', 'builds[0].name=digita-testkit-e2e,builds[0].image=digita-testkit-e2e,builds[0].tag=0.1.0');
const task = () => {
  assert.equal(runner.status, 0, runner.stderr);
  return yaml('select(.kind == "Task" and .metadata.name == "run-case")', runner.stdout);
};

test('the password reaches the step only from the target Secret, and nothing a run writes outlives its pod', () => {
  const {spec} = task();
  const [step] = spec.steps;
  assert.deepEqual(spec.params.map(({name}) => name), ['target', 'path', 'case']);
  const env = Object.fromEntries(step.env.map(({name, ...source}) => [name, source]));
  assert.deepEqual(env.E2E_PASSWORD, {valueFrom: {secretKeyRef: {name: 'e2e-$(params.target)', key: 'password'}}});
  assert.deepEqual(env.E2E_TARGET_HOST, {valueFrom: {secretKeyRef: {name: 'e2e-$(params.target)', key: 'host'}}});
  // A step title of the list reporter quotes what a fill typed, and every other reporter writes more.
  assert.equal(env.PLAYWRIGHT_LIST_PRINT_STEPS, undefined);
  assert.doesNotMatch(step.script, /--reporter|\$\(params\./);
  assert.equal(spec.workspaces, undefined);
  assert.equal(spec.results, undefined);
  const volumes = Object.fromEntries(spec.volumes.map(({name, ...source}) => [name, source]));
  const mounted = Object.fromEntries(step.volumeMounts.map(({name, mountPath}) => [mountPath, volumes[name]]));
  assert.deepEqual(mounted['/e2e/packages/e2e/.auth'], {emptyDir: {medium: 'Memory'}});
  assert.deepEqual(mounted['/e2e/packages/e2e/test-results'], {emptyDir: {}});
  assert.match(step.image, /\/digita-testkit-e2e:0\.1\.0$/);
});

// The step's script run under sh, with a stand-in Playwright that prints what it was handed.
const runScript = (path, testCase) => {
  const dir = mkdtempSync(join(tmpdir(), 'e2e-runner-'));
  try {
    mkdirSync(join(dir, 'node_modules/.bin'), {recursive: true});
    writeFileSync(join(dir, 'node_modules/.bin/playwright'), '#!/bin/sh\necho "playwright $PLAYWRIGHT_BASE_URL $*"\n');
    chmodSync(join(dir, 'node_modules/.bin/playwright'), 0o755);
    writeFileSync(join(dir, 'run-case.sh'), task().spec.steps[0].script);
    return spawnSync('sh', ['run-case.sh'], {cwd: dir, encoding: 'utf8',
      env: {PATH: process.env.PATH, E2E_TARGET_HOST: 'shop.example.test', E2E_APP_PATH: path, E2E_CASE: testCase}});
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
};

test('a run starts Playwright at the target host and the path, with the case alone', () => {
  const run = runScript('/app/shop/', 'cases/settings.spec.ts');
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /^playwright https:\/\/shop\.example\.test\/app\/shop\/ test cases\/settings\.spec\.ts$/m);
});

test('a path that could name another host, or a case that is not a file under cases/, is refused before Playwright starts', () => {
  for (const [path, testCase] of [
    ['@evil.example.test/', 'cases/settings.spec.ts'],
    ['.evil.example.test/', 'cases/settings.spec.ts'],
    [':8443@evil.example.test/', 'cases/settings.spec.ts'],
    ['/app/@evil.example.test', 'cases/settings.spec.ts'],
    ['/app?next=https://evil.example.test', 'cases/settings.spec.ts'],
    ['/app/shop/', '--reporter=line'],
    ['/app/shop/', '--headed'],
    ['/app/shop/', 'cases/../../x.spec.ts'],
    ['/app/shop/', 'cases/settings.spec.ts --reporter=line'],
  ]) {
    const run = runScript(path, testCase);
    assert.equal(run.status, 2, `${path} ${testCase}: ${run.stdout}${run.stderr}`);
    assert.doesNotMatch(run.stdout, /playwright/);
  }
});
