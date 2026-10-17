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
const runnerArgs = ['e2e-runner-prod', 'clusters/inventories/e2e-runner', '--namespace', 'e2e-runner',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
  '-f', 'clusters/inventories/e2e-runner/values-common.yaml', '-f', 'clusters/inventories/e2e-runner/values-prod.yaml',
  '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml',
  '--set-string', 'builds[0].name=digita-testkit-e2e,builds[0].image=digita-testkit-e2e,builds[0].tag=0.1.0'];
const runner = helm(...runnerArgs);
const task = () => {
  assert.equal(runner.status, 0, runner.stderr);
  return yaml('select(.kind == "Task" and .metadata.name == "run-case")', runner.stdout);
};

test('the password reaches the step only from the target Secret, and nothing a run writes outlives its pod', () => {
  const {spec} = task();
  const [step] = spec.steps;
  assert.deepEqual(spec.params.map(({name}) => name), ['target', 'path', 'case', 'dropped-member', 'dropped-account']);
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

test('the dropped member and account reach the step as params, empty by default', () => {
  const {spec} = task();
  const [step] = spec.steps;
  const param = name => spec.params.find(candidate => candidate.name === name);
  assert.equal(param('dropped-member').default, '');
  assert.equal(param('dropped-account').default, '');
  const env = Object.fromEntries(step.env.map(({name, ...source}) => [name, source]));
  assert.deepEqual(env.E2E_DROPPED_MEMBER, {value: '$(params.dropped-member)'});
  assert.deepEqual(env.E2E_DROPPED_ACCOUNT, {value: '$(params.dropped-account)'});
});

// THE TEST MAILBOX KEY: one ExternalSecret reads the three properties of e2e/test-mailbox through the
// E2E store on the tree's delivery rule, with Delete so a missing entry is no error and a refresh
// annotation of its own, and the step takes each property from it as optional environment.
const MAILBOX_KEYS = [['E2E_TEST_MAILBOX_CLIENT_ID', 'client-id'], ['E2E_TEST_MAILBOX_CLIENT_SECRET', 'client-secret'],
  ['E2E_TEST_MAILBOX_REFRESH_TOKEN', 'refresh-token']];
const REFRESH = 'hostyour.cloud/refreshRequestedOn';
const documents = () => {
  assert.equal(runner.status, 0, runner.stderr);
  return JSON.parse(execFileSync('yq', ['ea', '-o=json', '[.]', '-'], {input: runner.stdout, encoding: 'utf8'})).filter(Boolean);
};

/** Every way the rendered runner departs from the test mailbox key's delivery, named. */
function mailboxFindings(rendered) {
  const secrets = rendered.filter(doc => doc.kind === 'ExternalSecret' && doc.metadata.name === 'e2e-test-mailbox');
  if (secrets.length !== 1) return [`${secrets.length} ExternalSecrets e2e-test-mailbox, not 1`];
  const [{metadata, spec}] = secrets;
  const found = [];
  if (spec.secretStoreRef.name !== 'e2e-passwords' || spec.secretStoreRef.kind !== 'SecretStore') found.push(`the store is the ${spec.secretStoreRef.kind} ${spec.secretStoreRef.name}, not the SecretStore e2e-passwords`);
  if (spec.refreshPolicy !== 'OnChange') found.push(`refreshPolicy is ${spec.refreshPolicy}, not OnChange`);
  if (spec.refreshInterval !== '0') found.push(`refreshInterval is ${spec.refreshInterval}, not "0"`);
  if (spec.target.name !== 'e2e-test-mailbox') found.push(`the target is ${spec.target.name}, not e2e-test-mailbox`);
  if (spec.target.creationPolicy !== 'Owner') found.push(`creationPolicy is ${spec.target.creationPolicy}, not Owner`);
  if (spec.target.deletionPolicy !== 'Delete') found.push(`deletionPolicy is ${spec.target.deletionPolicy}, not Delete, so a missing entry is an error`);
  const rows = spec.data.map(({secretKey, remoteRef: {key, property}}) => ({secretKey, key, property}));
  if (JSON.stringify(rows) !== JSON.stringify(MAILBOX_KEYS.map(([, key]) => ({secretKey: key, key: 'e2e/test-mailbox', property: key})))) found.push(`the rows read ${JSON.stringify(rows)}, not the three properties of e2e/test-mailbox`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(metadata.annotations?.[REFRESH] ?? '')) found.push(`no annotation ${REFRESH} with a date`);
  if (metadata.annotations?.['hostyour.cloud/refreshRequestedAt'] !== undefined) found.push('the chart declares hostyour.cloud/refreshRequestedAt, which the Manager sets');
  const task = rendered.find(doc => doc.kind === 'Task' && doc.metadata.name === 'run-case');
  const env = Object.fromEntries(task.spec.steps[0].env.map(({name, ...source}) => [name, source]));
  for (const [name, key] of MAILBOX_KEYS) {
    if (JSON.stringify(env[name]) !== JSON.stringify({valueFrom: {secretKeyRef: {name: 'e2e-test-mailbox', key, optional: true}}})) found.push(`${name} is not the optional key ${key} of e2e-test-mailbox`);
  }
  return found;
}

test('the test mailbox key reaches the step only from e2e-test-mailbox, read on change through the E2E store, a missing entry no error', () => {
  assert.deepEqual(mailboxFindings(documents()), []);
});

test('PLANTED DEFECT: a retained or periodic read, another store or entry, a required env row or the Manager\'s annotation is found, and the chart itself is not', () => {
  const secret = rendered => rendered.find(doc => doc.kind === 'ExternalSecret' && doc.metadata.name === 'e2e-test-mailbox');
  const step = rendered => rendered.find(doc => doc.kind === 'Task' && doc.metadata.name === 'run-case').spec.steps[0];
  const planted = {
    'deletionPolicy Retain': rendered => { secret(rendered).spec.target.deletionPolicy = 'Retain'; },
    'no deletionPolicy': rendered => { delete secret(rendered).spec.target.deletionPolicy; },
    'refreshPolicy Periodic': rendered => { secret(rendered).spec.refreshPolicy = 'Periodic'; },
    'the store vault-backend': rendered => { secret(rendered).spec.secretStoreRef.name = 'vault-backend'; },
    'the key prod/e2e/test-mailbox': rendered => { secret(rendered).spec.data[0].remoteRef.key = 'prod/e2e/test-mailbox'; },
    'an env row without optional': rendered => { delete step(rendered).env.find(({name}) => name === 'E2E_TEST_MAILBOX_REFRESH_TOKEN').valueFrom.secretKeyRef.optional; },
    'the refresh annotation renamed to the Manager\'s': rendered => {
      const {annotations} = secret(rendered).metadata;
      annotations['hostyour.cloud/refreshRequestedAt'] = annotations[REFRESH];
      delete annotations[REFRESH];
    },
  };
  for (const [name, plant] of Object.entries(planted)) {
    const rendered = structuredClone(documents());
    plant(rendered);
    assert.notDeepEqual(mailboxFindings(rendered), [], name);
  }
  assert.deepEqual(mailboxFindings(structuredClone(documents())), [], 'the planted innocent: the chart as rendered');
});

// The step's script run under sh, with a stand-in Playwright that prints what it was handed. Tekton sets
// every param's variable, empty where the run gives none, so the run here does as well.
const runScript = (path, testCase, {member = '', account = '', script = task().spec.steps[0].script} = {}) => {
  const dir = mkdtempSync(join(tmpdir(), 'e2e-runner-'));
  try {
    mkdirSync(join(dir, 'node_modules/.bin'), {recursive: true});
    writeFileSync(join(dir, 'node_modules/.bin/playwright'),
      '#!/bin/sh\necho "playwright $PLAYWRIGHT_BASE_URL $*"\necho "dropped [$E2E_DROPPED_MEMBER] [$E2E_DROPPED_ACCOUNT]"\n');
    chmodSync(join(dir, 'node_modules/.bin/playwright'), 0o755);
    writeFileSync(join(dir, 'run-case.sh'), script);
    return spawnSync('sh', ['run-case.sh'], {cwd: dir, encoding: 'utf8',
      env: {PATH: process.env.PATH, E2E_TARGET_HOST: 'shop.example.test', E2E_APP_PATH: path, E2E_CASE: testCase,
        E2E_DROPPED_MEMBER: member, E2E_DROPPED_ACCOUNT: account}});
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

test('PLANTED INNOCENT: a member, an account with a subaddress, and no values at all reach Playwright', () => {
  for (const [member, account] of [['testco-workshop', 'e2e+drop@example.test'], ['', '']]) {
    const run = runScript('/app/shop/', 'cases/dropped-member-roles.spec.ts', {member, account});
    assert.equal(run.status, 0, `${member} ${account}: ${run.stderr}`);
    assert.match(run.stdout, /^playwright https:\/\/shop\.example\.test\/app\/shop\/ test cases\/dropped-member-roles\.spec\.ts$/m);
    assert.ok(run.stdout.includes(`dropped [${member}] [${account}]\n`), run.stdout);
  }
});

const unsafeDropped = [
  ['dropped-member', {member: 'testco workshop'}],
  ['dropped-member', {member: 'testco;id'}],
  ['dropped-member', {member: 'testco$HOME'}],
  ['dropped-member', {member: 'testco-workshop:admin'}],
  ['dropped-account', {account: 'e2e drop@example.test'}],
  ['dropped-account', {account: 'e2e;id@example.test'}],
  ['dropped-account', {account: 'e2e$HOME@example.test'}],
];

test('PLANTED DEFECT: a dropped member or account with a space or a shell character is refused, naming the param, before Playwright starts', () => {
  for (const [param, dropped] of unsafeDropped) {
    const run = runScript('/app/shop/', 'cases/dropped-member-roles.spec.ts', dropped);
    assert.equal(run.status, 2, `${param} ${JSON.stringify(dropped)}: ${run.stdout}${run.stderr}`);
    assert.match(run.stderr, new RegExp(`^run-case: ${param} `, 'm'));
    assert.doesNotMatch(run.stdout, /playwright/);
  }
});

test('PLANTED DEFECT: a step without the refusals hands every unsafe value to Playwright, so the test above goes red on it', () => {
  const script = task().spec.steps[0].script;
  const unrefused = script.replace(/^ *case "\$\{E2E_DROPPED_(MEMBER|ACCOUNT)\}" in\n.*\n *esac\n/gm, '');
  for (const [param, dropped] of unsafeDropped) {
    const run = runScript('/app/shop/', 'cases/dropped-member-roles.spec.ts', {...dropped, script: unrefused});
    assert.equal(run.status, 0, `${param} ${JSON.stringify(dropped)}: ${run.stderr}`);
    assert.match(run.stdout, /playwright/);
  }
});
