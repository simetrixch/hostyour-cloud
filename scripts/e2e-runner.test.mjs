import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
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

// THE SIGN-IN RUN: the Task that proves Plane signs a person in through Forgejo and the identity provider, as the two test
// accounts of clusters/bootstrap/idp/blueprints/20-plane-test-accounts.yaml. It targets the installation's own Plane, so it
// names no tenant, and the two passwords reach it from the Secret plane-test-account, which the namespace's default
// SecretStore reads: the store of the E2E passwords reaches tenants' entries and nothing else, and its role stays as it is.
// Argo CD, Headlamp and the Vault UI are the owner's own consoles and get no test account and no proof run, so no Task and
// no ExternalSecret of the chart may carry their names or read an entry of a test account for them.
const clusterDomain = yaml('.global.domain', readFileSync('scripts/standin/cluster-map.yaml', 'utf8'));
// yq prints nothing for a document that matches nothing, and a missing object is a finding, not a crash.
const pick = (expression, rendered) => JSON.parse(execFileSync('yq', ['ea', '-o=json', `[${expression}] | .[0] // null`, '-'], {input: rendered, encoding: 'utf8'}));
const SIGN_IN_SECRETS = {
  'plane-test-account': ['password=prod/app/plane-test-account:password', 'uninvited-password=prod/app/plane-test-account:uninvited-password'],
};
const SIGN_IN_TASKS = {
  'run-plane-sign-in': {host: 'plane', config: 'playwright.plane.config.ts', passwords: [
    {variable: 'E2E_PLANE_ACCOUNT_PASSWORD', secret: 'plane-test-account', key: 'password'},
    {variable: 'E2E_PLANE_UNINVITED_PASSWORD', secret: 'plane-test-account', key: 'uninvited-password'},
  ]},
};
// A name or a Vault key that belongs to a console of the owner: Argo CD, Headlamp or the platform test account that proved them.
const CONSOLE_PATTERN = /argocd|headlamp|platform/;
const signInObjects = (rendered = runner.stdout) => ({
  tasks: Object.fromEntries(Object.keys(SIGN_IN_TASKS).map(name => [name, pick(`select(.kind == "Task" and .metadata.name == "${name}")`, rendered)])),
  secrets: Object.fromEntries(Object.keys(SIGN_IN_SECRETS).map(name => [name, pick(`select(.kind == "ExternalSecret" and .metadata.name == "${name}")`, rendered)])),
  stores: JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(.kind == "SecretStore") | .metadata.name]', '-'], {input: rendered, encoding: 'utf8'})),
  taskNames: JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(.kind == "Task") | .metadata.name]', '-'], {input: rendered, encoding: 'utf8'})),
  secretReads: JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(.kind == "ExternalSecret") | {"name": .metadata.name, "keys": [.spec.data[]?.remoteRef.key]}]', '-'], {input: rendered, encoding: 'utf8'})),
});

/** Every way a Task or its Secret lets a password out, or reads it through the wrong store, named. */
function signInFindings({tasks, secrets, stores, taskNames, secretReads}) {
  const found = [];
  for (const name of taskNames.filter(each => CONSOLE_PATTERN.test(each))) found.push(`the Task ${name} proves a sign-in to a console of the owner, which gets no proof run`);
  for (const {name, keys} of secretReads) {
    if (CONSOLE_PATTERN.test(name) || keys.some(key => CONSOLE_PATTERN.test(key))) found.push(`the ExternalSecret ${name} reads ${keys} for a console of the owner, which gets no test account`);
  }
  for (const [name, expected] of Object.entries(SIGN_IN_SECRETS)) {
    const secret = secrets[name];
    if (!secret) { found.push(`no ExternalSecret ${name}`); continue; }
    const store = secret.spec.secretStoreRef.name;
    if (store !== 'vault-backend') found.push(`${name} is read through ${store}, not through the namespace's default store vault-backend`);
    if (store === 'e2e-passwords') found.push(`${name} is read through the store of the E2E passwords, whose role reaches tenants' entries and must not be widened`);
    if (!stores.includes(store)) found.push(`the store ${store} does not exist in the namespace`);
    const reads = secret.spec.data.map(({secretKey, remoteRef: {key, property}}) => `${secretKey}=${key}:${property}`);
    if (JSON.stringify(reads) !== JSON.stringify(expected)) found.push(`${name} reads ${reads}`);
    if (secret.spec.refreshInterval !== '0' || secret.spec.refreshPolicy !== 'OnChange') found.push(`${name} is read from Vault on a timer`);
  }
  for (const [name, {host, config, passwords}] of Object.entries(SIGN_IN_TASKS)) {
    const task = tasks[name];
    if (!task) { found.push(`no Task ${name}`); continue; }
    const [step] = task.spec.steps;
    if (task.spec.steps.length !== 1) found.push(`${name} has ${task.spec.steps.length} steps, not 1`);
    if ((task.spec.params ?? []).length > 0) found.push(`${name} takes params ${task.spec.params.map(({name: param}) => param)}, which a TaskRun's spec would print`);
    const env = Object.fromEntries(step.env.map(({name: variable, ...source}) => [variable, source]));
    for (const {variable, secret, key} of passwords) {
      if (JSON.stringify(env[variable]) !== JSON.stringify({valueFrom: {secretKeyRef: {name: secret, key}}})) found.push(`${name}: ${variable} is not the key ${key} of the Secret ${secret} through secretKeyRef`);
    }
    for (const [variable, source] of Object.entries(env)) {
      if (/PASSWORD|SECRET|TOKEN|KEY/.test(variable) && !passwords.some(password => password.variable === variable)) found.push(`${name}: the step carries ${variable}, which is no password of the accounts of this proof`);
      if (/PASSWORD|SECRET|TOKEN|KEY/.test(variable) && source.value !== undefined) found.push(`${name}: ${variable} is a value of the Task, not a secretKeyRef`);
    }
    if (env.PLAYWRIGHT_BASE_URL?.value !== `https://${host}.${clusterDomain}`) found.push(`${name}: the case starts at ${env.PLAYWRIGHT_BASE_URL?.value}, not at the installation's own ${host}`);
    if (env.PLAYWRIGHT_LIST_PRINT_STEPS !== undefined) found.push(`${name}: the list reporter prints the steps, which quote what a fill typed`);
    if (/PASSWORD|printenv|\benv\b|set -[a-z]*x|--reporter|\$\(params\./.test(step.script)) found.push(`${name}: the script names a password, prints the environment, switches tracing on or adds a reporter`);
    if (!new RegExp(`^exec node_modules/\\.bin/playwright test --config ${config.replaceAll('.', '\\.')}$`, 'm').test(step.script)) found.push(`${name}: the script does not run ${config} alone`);
    if (task.spec.workspaces !== undefined || task.spec.results !== undefined) found.push(`${name} hands something to another pod`);
    const volumes = Object.fromEntries(task.spec.volumes.map(({name: volume, ...source}) => [volume, source]));
    const mounted = Object.fromEntries(step.volumeMounts.map(({name: volume, mountPath}) => [mountPath, volumes[volume]]));
    if (JSON.stringify(mounted['/e2e/packages/e2e/.auth']) !== JSON.stringify({emptyDir: {medium: 'Memory'}}) || JSON.stringify(mounted['/e2e/packages/e2e/test-results']) !== JSON.stringify({emptyDir: {}})) found.push(`${name}: what the run writes outlives its pod`);
    if (step.securityContext.readOnlyRootFilesystem !== true || step.securityContext.runAsNonRoot !== true) found.push(`${name}: the step runs with a writable root filesystem or as root`);
    if (!/\/digita-testkit-e2e:0\.1\.0$/.test(step.image)) found.push(`${name}: the image is ${step.image}, not the pinned E2E image`);
  }
  return found;
}

test('the sign-in Task gets its passwords from plane-test-account through secretKeyRef, the Secret is read by the default store, and no Task or ExternalSecret serves a console of the owner', () => {
  assert.equal(runner.status, 0, runner.stderr);
  assert.deepEqual(signInFindings(signInObjects()), []);
});

test('PLANTED DEFECT: a password as a value, a param, a printed password, E2E_PASSWORD, a reporter, another account, the store of the E2E passwords or a Task or Secret of a console is each found', () => {
  assert.equal(runner.status, 0, runner.stderr);
  const taskPlants = {
    'a password as a literal value': (task, {passwords}) => { const env = task.spec.steps[0].env.find(e => e.name === passwords[0].variable); env.valueFrom = undefined; env.value = 'hunter2-hunter2'; },
    'a password in a param': task => { task.spec.params = [{name: 'password', type: 'string'}]; },
    'a print of the password in the script': (task, {passwords}) => { task.spec.steps[0].script += `\necho "signing in with \${${passwords[0].variable}}"\n`; },
    'the E2E password of a tenant': task => { task.spec.steps[0].env.push({name: 'E2E_PASSWORD', valueFrom: {secretKeyRef: {name: 'e2e-$(params.target)', key: 'password'}}}); },
    'a reporter that prints the steps': task => { task.spec.steps[0].env.push({name: 'PLAYWRIGHT_LIST_PRINT_STEPS', value: '1'}); },
    'a trace of the script': task => { task.spec.steps[0].script = task.spec.steps[0].script.replace('set -eu', 'set -eux'); },
    'the Secret of a tenant for the account of the wrong group': (task, {passwords}) => { task.spec.steps[0].env.find(e => e.name === passwords[1].variable).valueFrom.secretKeyRef.name = 'e2e-aaaaaaaaaaaa-prod'; },
    'the password of an account this proof does not use': task => { task.spec.steps[0].env.push({name: 'E2E_OTHER_ACCOUNT_PASSWORD', valueFrom: {secretKeyRef: {name: 'plane-test-account', key: 'password'}}}); },
    'the case at another host': task => { task.spec.steps[0].env.find(e => e.name === 'PLAYWRIGHT_BASE_URL').value = `https://other.${clusterDomain}`; },
    'the script runs another config': (task, {config}) => { task.spec.steps[0].script = task.spec.steps[0].script.replace(config, 'playwright.config.ts'); },
    'a session that outlives its pod': task => { task.spec.workspaces = [{name: 'session'}]; },
    'a Task that is missing': (task, {}, tasks, name) => { tasks[name] = null; },
  };
  for (const [taskName, expected] of Object.entries(SIGN_IN_TASKS)) {
    for (const [plantName, plant] of Object.entries(taskPlants)) {
      const objects = structuredClone(signInObjects());
      plant(objects.tasks[taskName], expected, objects.tasks, taskName);
      assert.notDeepEqual(signInFindings(objects), [], `${taskName}: ${plantName}`);
    }
  }
  const secretPlants = {
    'a read of Vault on a timer': secret => { secret.spec.refreshInterval = '1h'; },
    'the wrong entry': secret => { secret.spec.data[0].remoteRef.key = 'prod/app/manager'; },
    'an ExternalSecret that is missing': (secret, secrets, name) => { secrets[name] = null; },
  };
  for (const secretName of Object.keys(SIGN_IN_SECRETS)) {
    for (const [plantName, plant] of Object.entries(secretPlants)) {
      const objects = structuredClone(signInObjects());
      plant(objects.secrets[secretName], objects.secrets, secretName);
      assert.notDeepEqual(signInFindings(objects), [], `${secretName}: ${plantName}`);
    }
  }
  const consolePlants = {
    'a rendered Task run-argocd-sign-in': objects => { objects.taskNames.push('run-argocd-sign-in'); },
    'a rendered Task run-headlamp-sign-in': objects => { objects.taskNames.push('run-headlamp-sign-in'); },
    'a rendered ExternalSecret platform-test-account': objects => { objects.secretReads.push({name: 'platform-test-account', keys: ['prod/app/platform-test-account']}); },
    'an ExternalSecret under another name that reads prod/app/platform-test-account': objects => { objects.secretReads.push({name: 'console-password', keys: ['prod/app/platform-test-account']}); },
  };
  for (const [plantName, plant] of Object.entries(consolePlants)) {
    const objects = structuredClone(signInObjects());
    plant(objects);
    assert.notDeepEqual(signInFindings(objects), [], plantName);
  }
  const throughE2ePasswords = helm(...runnerArgs, '--set-string', 'global.secretStoreName=e2e-passwords');
  assert.equal(throughE2ePasswords.status, 0, throughE2ePasswords.stderr);
  const found = signInFindings(signInObjects(throughE2ePasswords.stdout));
  for (const secretName of Object.keys(SIGN_IN_SECRETS)) {
    assert.ok(found.some(finding => finding.startsWith(`${secretName} is read through the store of the E2E passwords`)), `${secretName} read through e2e-passwords`);
  }
});

test('PLANTED INNOCENT: another image pin, another variable that is no secret and another description change nothing the rules hold', () => {
  const repinned = helm(...runnerArgs.slice(0, -1), 'builds[0].name=digita-testkit-e2e,builds[0].image=digita-testkit-e2e,builds[0].tag=0.1.0');
  assert.deepEqual(signInFindings(signInObjects(repinned.stdout)), []);
  const objects = structuredClone(signInObjects());
  for (const task of Object.values(objects.tasks)) {
    task.spec.steps[0].env.push({name: 'E2E_PLANE_WORKSPACE', value: 'simplidigita'});
    task.spec.description = 'planted';
  }
  assert.deepEqual(signInFindings(objects), []);
});

test('the e2e-runner policy and the store of the E2E passwords stay as they are: the sign-in Secrets need neither', () => {
  const {stores} = signInObjects();
  assert.equal(stores.filter(name => name === 'e2e-passwords').length, 1);
  const store = yaml('select(.kind == "SecretStore" and .metadata.name == "e2e-passwords") | .spec.provider.vault.auth.kubernetes', runner.stdout);
  assert.equal(store.role, 'e2e-runner');
  assert.equal(store.serviceAccountRef.name, 'e2e-runner-eso');
});
