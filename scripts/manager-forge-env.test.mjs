import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {cpSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';

// What the Manager chart tells the Manager about the forges: the platform and deploy repositories whole, the
// installation's Forgejo host with the webhook key its hooks are signed with, and the GitHub owners whose units
// may move to it. The control host's gates (master.sshUser, onboarding.gatemanagerAddr) are set here because the
// stand-in installation is no control host.
const renderChart = (chart, ...set) => execFileSync('helm', ['template', 'manager', chart, '--namespace', 'manager',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
  '-f', 'clusters/inventories/manager/values-common.yaml', '-f', 'clusters/inventories/manager/values-prod.yaml',
  '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml',
  '--set', 'master.sshUser=ops', '--set', 'master.lanHost=10.0.0.1', '--set', 'onboarding.gatemanagerAddr=10.0.0.1',
  ...set.flatMap(value => ['--set', value])], {encoding: 'utf8'});
const render = (...set) => renderChart('clusters/inventories/manager', ...set);
const select = (rendered, expression) => JSON.parse(execFileSync('yq', ['-o=json', '-I=0', expression, '-'], {input: rendered, encoding: 'utf8'}));
const environment = rendered => {
  const text = execFileSync('yq', ['-o=json', '-I=0', 'select(.kind == "Deployment" and .metadata.name == "manager") | .spec.template.spec.containers[0].env[]', '-'], {input: rendered, encoding: 'utf8'});
  return Object.fromEntries(text.trim().split('\n').filter(Boolean).map(line => JSON.parse(line)).map(entry => [entry.name, entry]));
};

// The contract the Manager reads, as a function so a chart that drops an env can be shown to go red.
const FORGE_ENV = ['PLATFORM_REPO_URL', 'GITHUB_REPO', 'DEPLOY_REPO_URL', 'FORGEJO_HOST', 'FORGEJO_PACKAGE_SCOPES', 'FORGEJO_MOVE_GITHUB_OWNERS', 'FORGEJO_WEBHOOK_SECRET'];
function assertForgeEnv(env, expected) {
  for (const name of FORGE_ENV) assert.ok(env[name], `the Manager chart passes no ${name}`);
  assert.equal(env.PLATFORM_REPO_URL.value, expected.platformUrl);
  assert.equal(env.GITHUB_REPO.value, expected.platformRepo);
  assert.equal(env.DEPLOY_REPO_URL.value, expected.deployUrl);
  assert.equal(env.FORGEJO_HOST.value, expected.forgejoHost);
  assert.deepEqual(parsePackageScopes(env.FORGEJO_PACKAGE_SCOPES.value), expected.packageScopes ?? {});
  assert.equal(env.FORGEJO_MOVE_GITHUB_OWNERS.value, expected.moveGitHubOwners ?? '');
  assert.deepEqual(env.FORGEJO_WEBHOOK_SECRET.valueFrom.secretKeyRef, {name: 'manager-forgejo-webhook', key: 'forgejo-webhook-secret', optional: true});
}

function parsePackageScopes(value) {
  assert.equal(typeof value, 'string', 'FORGEJO_PACKAGE_SCOPES must be a string');
  return Object.fromEntries(value.split(',').filter(Boolean).map(pair => {
    assert.match(pair, /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?=[A-Za-z0-9][A-Za-z0-9._-]*$/, 'FORGEJO_PACKAGE_SCOPES must contain organisation=scope pairs separated by commas');
    const [organisation, scope] = pair.split('=');
    return [organisation.toLowerCase(), scope];
  }));
}

const rendered = render();
const today = {platformUrl: 'https://github.com/simetrixch/hostyour-cloud.git', platformRepo: 'simetrixch/hostyour-cloud',
  deployUrl: 'https://github.com/check/check.git', forgejoHost: 'forgejo.check.example.invalid'};

test('the empty package scope default renders an empty string accepted as an empty map', () => {
  assert.deepEqual(select(readFileSync('clusters/inventories/manager/values-common.yaml', 'utf8'), '.forgejo.packageScopes'), {});
  const value = environment(rendered).FORGEJO_PACKAGE_SCOPES?.value;
  assert.equal(value, '');
  assert.deepEqual(parsePackageScopes(value), {});
});

test('PLANTED INNOCENT: a configured organisation scope map renders as comma-separated organisation=scope pairs and parses back', () => {
  const env = environment(render('forgejo.packageScopes.Org-A=scope-one', 'forgejo.packageScopes.org-b=scope.two'));
  assert.equal(env.FORGEJO_PACKAGE_SCOPES?.value, 'Org-A=scope-one,org-b=scope.two');
  assertForgeEnv(env, {...today, packageScopes: {'org-a': 'scope-one', 'org-b': 'scope.two'}});
});

test('PLANTED DEFECT: a chart dropping the package scopes env or using the wrong pair format goes red', () => {
  const work = execFileSync('mktemp', ['-d'], {encoding: 'utf8'}).trim();
  try {
    const chart = join(work, 'manager');
    cpSync('clusters/inventories/manager', chart, {recursive: true});
    const template = join(chart, 'templates/deployment.yaml');
    const source = readFileSync(template, 'utf8');
    const mutations = [
      [source.replace(/\n\s*- name: FORGEJO_PACKAGE_SCOPES\n\s+value: [^\n]*/, ''), /passes no FORGEJO_PACKAGE_SCOPES/],
      [source.replace('printf "%s=%s"', 'printf "%s:%s"'), /FORGEJO_PACKAGE_SCOPES must contain/],
    ];
    for (const [mutant, message] of mutations) {
      assert.ok(mutant !== source, 'the planted defect must change the chart');
      writeFileSync(template, mutant);
      const env = environment(renderChart(chart, 'forgejo.packageScopes.org-a=scope-one'));
      assert.throws(() => assertForgeEnv(env, {...today, packageScopes: {'org-a': 'scope-one'}}), message);
    }
  } finally {
    rmSync(work, {recursive: true, force: true});
  }
});

test('the chart hands the Manager the platform and deploy repositories whole, the Forgejo host, its webhook key and no owner that moves', () => {
  assertForgeEnv(environment(rendered), today);
  assert.equal(environment(rendered).DEPLOY_REPO, undefined, 'DEPLOY_REPO is DEPLOY_REPO_URL now, the deploy repository whole');
  assert.equal(environment(rendered).GITHUB_WEBHOOK_SECRET.valueFrom.secretKeyRef.name, 'manager-webhook');
});

test('a platform and a deploy repository on the Forgejo host are passed whole, and GITHUB_REPO follows the platform URL', () => {
  const moved = render('global.platformUrl=https://forgejo.check.example.invalid/org-a/hostyour-cloud.git', 'global.deployUrl=https://forgejo.check.example.invalid/org-a/hostyour-deploy.git');
  assertForgeEnv(environment(moved), {platformUrl: 'https://forgejo.check.example.invalid/org-a/hostyour-cloud.git', platformRepo: 'org-a/hostyour-cloud',
    deployUrl: 'https://forgejo.check.example.invalid/org-a/hostyour-deploy.git', forgejoHost: 'forgejo.check.example.invalid'});
});

test('PLANTED DEFECT: the Forgejo host and the repositories render without consumer onboarding, which is a different switch', () => {
  const env = environment(render('onboarding.gatemanagerAddr='));
  assert.equal(env.ONBOARD_GATE_MANAGER_ADDR, undefined, 'the stand-in has no consumer onboarding in this render');
  for (const name of ['PLATFORM_REPO_URL', 'DEPLOY_REPO_URL', 'FORGEJO_HOST', 'FORGEJO_PACKAGE_SCOPES', 'FORGEJO_MOVE_GITHUB_OWNERS']) assert.ok(env[name], `without consumer onboarding the Manager chart passes no ${name}`);
});

test('PLANTED DEFECT: a github.repo that names another repository than global.platformUrl fails the render, naming both', () => {
  assert.throws(() => render('github.repo=org-a/cloud'), /github\.repo \(org-a\/cloud\).*global\.platformUrl \(simetrixch\/hostyour-cloud\)/s);
});

test('PLANTED INNOCENT: a github.repo that names the repository global.platformUrl names changes nothing', () => {
  assertForgeEnv(environment(render('github.repo=simetrixch/hostyour-cloud')), today);
  const moved = render('github.repo=org-a/hostyour-cloud', 'global.platformUrl=https://forgejo.check.example.invalid/org-a/hostyour-cloud.git');
  assert.equal(environment(moved).GITHUB_REPO.value, 'org-a/hostyour-cloud');
});

test('PLANTED DEFECT: the product ships no organisation of any installation, and an installation names the owners that move', () => {
  const shipped = readFileSync('clusters/inventories/manager/values-common.yaml', 'utf8');
  for (const organisation of ['ansiwise', 'hostyour', 'simplidigita']) assert.ok(!new RegExp(`^\\s+${organisation}:`, 'm').test(shipped.split('\nforgejo:')[1] ?? ''), `values-common.yaml names the organisation ${organisation}`);
  assert.equal(environment(rendered).FORGEJO_MOVE_GITHUB_OWNERS.value, '');
  assert.equal(environment(render('forgejo.moveGitHubOwners={org-a,org-b}')).FORGEJO_MOVE_GITHUB_OWNERS.value, 'org-a,org-b');
});

test('PLANTED DEFECT: the engine repository stands in the platform repository organisation until a forge move splits them', () => {
  const engine = select(readFileSync('clusters/platform/versions.yaml', 'utf8'), '.cliTools.ansiwise.upstream.image');
  const platformUrl = select(readFileSync('clusters/platform/values-common.yaml', 'utf8'), '.global.platformUrl');
  assert.equal(engine.split('/')[0], new URL(platformUrl).pathname.split('/')[1], `versions.yaml names ${engine} as the engine, whose release line the platform repository ${platformUrl} does not share`);
  assert.equal(engine, 'simetrixch/ansiwise-cli');
});

test('the Forgejo webhook key is read from the entry the Forgejo Triggers read, in an ExternalSecret that tolerates its absence', () => {
  const secret = select(rendered, 'select(.kind == "ExternalSecret" and .metadata.name == "manager-forgejo-webhook")');
  assert.equal(secret.spec.target.deletionPolicy, 'Delete');
  assert.deepEqual(secret.spec.data.map(({secretKey, remoteRef}) => [secretKey, remoteRef.key, remoteRef.property]),
    [['forgejo-webhook-secret', 'prod/app/forgejo-webhook', 'forgejo-webhook-secret']]);
  assert.equal(secret.spec.refreshPolicy, 'OnChange');
});

test('PLANTED DEFECT: a chart without one of the envs goes red, naming it', () => {
  for (const name of FORGE_ENV) {
    const env = {...environment(rendered)}; delete env[name];
    assert.throws(() => assertForgeEnv(env, today), new RegExp(`passes no ${name}`));
  }
  const wrongKey = structuredClone(environment(rendered));
  wrongKey.FORGEJO_WEBHOOK_SECRET.valueFrom.secretKeyRef.name = 'manager-webhook';
  assert.throws(() => assertForgeEnv(wrongKey, today));
});

test('PLANTED INNOCENT: an installation off the control host passes the Manager no repository env at all', () => {
  const off = execFileSync('helm', ['template', 'manager', 'clusters/inventories/manager', '--namespace', 'manager',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
    '-f', 'clusters/inventories/manager/values-common.yaml', '-f', 'clusters/inventories/manager/values-prod.yaml',
    '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml'], {encoding: 'utf8'});
  assert.deepEqual(Object.keys(environment(off)).filter(name => FORGE_ENV.includes(name)), []);
});
