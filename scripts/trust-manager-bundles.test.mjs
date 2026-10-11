import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// The Bundle platform-trust stands in its own chart, after trust-manager: a release holding the
// Bundle CRD and a Bundle cannot install on a new cluster, so the installer and Argo CD both put
// trust-manager first and the Bundle second.

const yq = (args, input) => JSON.parse(execFileSync('yq', args, {input, encoding: 'utf8'}));
const app = yq(['-o=json', '.', 'clusters/inventories/trust-manager-bundles/app.yaml']);
const trustManager = yq(['-o=json', '.', 'clusters/inventories/trust-manager/app.yaml']);
const render = (chart, extra = []) => execFileSync('helm', ['template', chart, `clusters/inventories/${chart}`, '--namespace', 'cert-manager',
  '-f', 'clusters/platform/values-common.yaml', ...extra], {encoding: 'utf8'});
const objects = text => yq(['ea', '-o=json', '-I=0', '[.] | map(select(. != null and .kind != null))', '-'], text);
const bundle = issuer => objects(render('trust-manager-bundles', ['--set', `global.clusterIssuer=${issuer}`]))
  .find(d => d.kind === 'Bundle' && d.metadata.name === 'platform-trust');

test('the Bundle for platform-acme has two sources and for platform-local three, the third the platform-ca secret', () => {
  const acme = bundle('platform-acme');
  assert.ok(acme, 'Bundle platform-trust exists for platform-acme');
  assert.equal(acme.spec.sources.length, 2);

  const local = bundle('platform-local');
  assert.ok(local, 'Bundle platform-trust exists for platform-local');
  assert.equal(local.spec.sources.length, 3);
  assert.deepEqual(local.spec.sources[2], {secret: {name: 'platform-ca', key: 'ca.crt'}});
});

test('PLANTED DEFECT: --set global.clusterIssuer=letsencrypt-prod makes helm template fail with a message containing global.clusterIssuer', () => {
  assert.throws(() => render('trust-manager-bundles', ['--set', 'global.clusterIssuer=letsencrypt-prod']), /global\.clusterIssuer/);
});

test('PLANTED DEFECT: the trust-manager chart renders no Bundle', () => {
  assert.deepEqual(objects(render('trust-manager')).filter(d => d.kind === 'Bundle').map(d => d.metadata.name), []);
});

test('PLANTED DEFECT: app.prune is "false", and the Application syncs after trust-manager, beside it', () => {
  assert.equal(app.prune, 'false');
  assert.ok(Number(app.syncWave) > Number(trustManager.syncWave), `syncWave ${app.syncWave} after trust-manager's ${trustManager.syncWave}`);
  for (const key of ['project', 'namespace', 'runsOn']) {
    assert.equal(app[key], trustManager[key], key);
  }
});

test('the Bundle carries no wave of its own: the Application\'s wave orders it', () => {
  assert.equal(bundle('platform-acme').metadata.annotations?.['argocd.argoproj.io/sync-wave'], undefined);
});
