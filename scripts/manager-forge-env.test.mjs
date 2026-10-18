import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

// What the Manager chart tells the Manager about the forges: the platform and deploy repositories whole, the
// installation's Forgejo host with the webhook key its hooks are signed with, and the npm scope of each Forgejo
// organisation. The control host's gates (master.sshUser, onboarding.gatemanagerAddr) are set here because the
// stand-in installation is no control host.
const render = (...set) => execFileSync('helm', ['template', 'manager', 'clusters/inventories/manager', '--namespace', 'manager',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
  '-f', 'clusters/inventories/manager/values-common.yaml', '-f', 'clusters/inventories/manager/values-prod.yaml',
  '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml',
  '--set', 'master.sshUser=ops', '--set', 'master.lanHost=10.0.0.1', '--set', 'onboarding.gatemanagerAddr=10.0.0.1',
  ...set.flatMap(value => ['--set', value])], {encoding: 'utf8'});
const select = (rendered, expression) => JSON.parse(execFileSync('yq', ['-o=json', '-I=0', expression, '-'], {input: rendered, encoding: 'utf8'}));
const environment = rendered => {
  const text = execFileSync('yq', ['-o=json', '-I=0', 'select(.kind == "Deployment" and .metadata.name == "manager") | .spec.template.spec.containers[0].env[]', '-'], {input: rendered, encoding: 'utf8'});
  return Object.fromEntries(text.trim().split('\n').filter(Boolean).map(line => JSON.parse(line)).map(entry => [entry.name, entry]));
};

// The contract the Manager reads, as a function so a chart that drops an env can be shown to go red.
const FORGE_ENV = ['PLATFORM_REPO_URL', 'GITHUB_REPO', 'DEPLOY_REPO_URL', 'FORGEJO_HOST', 'FORGEJO_PACKAGE_SCOPES', 'FORGEJO_WEBHOOK_SECRET'];
function assertForgeEnv(env, expected) {
  for (const name of FORGE_ENV) assert.ok(env[name], `the Manager chart passes no ${name}`);
  assert.equal(env.PLATFORM_REPO_URL.value, expected.platformUrl);
  assert.equal(env.GITHUB_REPO.value, expected.platformRepo);
  assert.equal(env.DEPLOY_REPO_URL.value, expected.deployUrl);
  assert.equal(env.FORGEJO_HOST.value, expected.forgejoHost);
  assert.equal(env.FORGEJO_PACKAGE_SCOPES.value, 'ansiwise=simetrixch,hostyour=simetrixch,simplidigita=digitaplatform');
  assert.deepEqual(env.FORGEJO_WEBHOOK_SECRET.valueFrom.secretKeyRef, {name: 'manager-forgejo-webhook', key: 'forgejo-webhook-secret', optional: true});
}

const rendered = render();
const today = {platformUrl: 'https://github.com/simetrixch/hostyour-cloud.git', platformRepo: 'simetrixch/hostyour-cloud',
  deployUrl: 'https://github.com/check/check.git', forgejoHost: 'forgejo.check.example.invalid'};

test('the chart hands the Manager the platform and deploy repositories whole, the Forgejo host, its webhook key and the scope table', () => {
  assertForgeEnv(environment(rendered), today);
  assert.equal(environment(rendered).DEPLOY_REPO, undefined, 'DEPLOY_REPO is DEPLOY_REPO_URL now, the deploy repository whole');
  assert.equal(environment(rendered).GITHUB_WEBHOOK_SECRET.valueFrom.secretKeyRef.name, 'manager-webhook');
});

test('a platform and a deploy repository on the Forgejo host are passed whole, and GITHUB_REPO follows the platform URL', () => {
  const moved = render('global.platformUrl=https://forgejo.check.example.invalid/org-a/hostyour-cloud.git', 'global.deployUrl=https://forgejo.check.example.invalid/org-a/hostyour-deploy.git');
  assertForgeEnv(environment(moved), {platformUrl: 'https://forgejo.check.example.invalid/org-a/hostyour-cloud.git', platformRepo: 'org-a/hostyour-cloud',
    deployUrl: 'https://forgejo.check.example.invalid/org-a/hostyour-deploy.git', forgejoHost: 'forgejo.check.example.invalid'});
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
