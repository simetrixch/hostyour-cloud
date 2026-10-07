import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// trust-manager under ArgoCD adopts the installer's Helm release in place: the same chart, the same
// release name, the same objects, and its Bundle in the form of the cluster issuer.

const app = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/inventories/trust-manager/app.yaml'], {encoding: 'utf8'}));
const render = (extra = []) => execFileSync('helm', ['template', app.releaseName, 'clusters/inventories/trust-manager', '--namespace', app.namespace,
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/inventories/trust-manager/values-common.yaml', ...extra], {encoding: 'utf8'});
const objects = text => JSON.parse(execFileSync('yq', ['ea', '-o=json', '-I=0', '[.] | map(select(. != null and .kind != null))', '-'], {input: text, encoding: 'utf8'}));

test('renders under release name trust-manager, and the Deployment trust-manager has selector {app: trust-manager}', () => {
  assert.equal(app.releaseName, 'trust-manager');
  const docs = objects(render());
  const deployment = docs.find(d => d.kind === 'Deployment' && d.metadata.name === 'trust-manager');
  assert.ok(deployment, 'Deployment trust-manager exists');
  assert.deepEqual(deployment.spec.selector.matchLabels, {app: 'trust-manager'});
});

const crdsWithoutKeep = docs => docs.filter(d => d.kind === 'CustomResourceDefinition' && d.metadata.annotations?.['helm.sh/resource-policy'] !== 'keep').map(d => d.metadata.name);

test('PLANTED DEFECT: every CRD carries helm.sh/resource-policy: keep, and with crds.keep=false at least one does not; app.prune is "false"', () => {
  assert.equal(app.prune, 'false');
  const docs = objects(render());
  const crds = docs.filter(d => d.kind === 'CustomResourceDefinition');
  assert.ok(crds.length >= 1, 'CRDs exist');
  assert.deepEqual(crdsWithoutKeep(docs), []);
  assert.ok(crdsWithoutKeep(objects(render(['--set', 'trust-manager.crds.keep=false']))).length >= 1);
});

test('the Bundle for platform-acme has two sources and for platform-local three, the third the platform-ca secret', () => {
  const acmeDocs = objects(render(['--set', 'global.clusterIssuer=platform-acme']));
  const acmeBundle = acmeDocs.find(d => d.kind === 'Bundle' && d.metadata.name === 'platform-trust');
  assert.ok(acmeBundle, 'Bundle platform-trust exists for platform-acme');
  assert.equal(acmeBundle.spec.sources.length, 2);

  const localDocs = objects(render(['--set', 'global.clusterIssuer=platform-local']));
  const localBundle = localDocs.find(d => d.kind === 'Bundle' && d.metadata.name === 'platform-trust');
  assert.ok(localBundle, 'Bundle platform-trust exists for platform-local');
  assert.equal(localBundle.spec.sources.length, 3);
  assert.deepEqual(localBundle.spec.sources[2], {secret: {name: 'platform-ca', key: 'ca.crt'}});
});

test('PLANTED DEFECT: --set global.clusterIssuer=letsencrypt-prod makes helm template fail with a message containing global.clusterIssuer', () => {
  assert.throws(() => render(['--set', 'global.clusterIssuer=letsencrypt-prod']), /global\.clusterIssuer/);
});

const appset = JSON.parse(execFileSync('yq', ['-o=json', '.spec', 'clusters/argocd/files/platform-apps-appset.yaml'], {encoding: 'utf8'}));
const [{output, error}] = JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
  input: JSON.stringify({template: appset.templatePatch, options: appset.goTemplateOptions, params: [app]}), encoding: 'utf8'}));
const application = JSON.parse(execFileSync('yq', ['-o=json', '.'], {input: output ?? '', encoding: 'utf8'}));

test('every webhook configuration kind the chart renders with an inject-ca annotation is covered by ignoreDifferences with caBundle', () => {
  assert.equal(error, undefined);
  const injected = objects(render()).filter(d =>
    d.metadata.annotations?.['cert-manager.io/inject-ca-from'] ||
    d.metadata.annotations?.['cert-manager.io/inject-ca-from-secret']
  ).map(d => d.kind);
  assert.ok(injected.length >= 1);
  for (const kind of [...new Set(injected)]) {
    const rule = application.spec.ignoreDifferences.find(r => r.kind === kind);
    assert.equal(rule?.group, 'admissionregistration.k8s.io', kind);
    assert.deepEqual(rule.jqPathExpressions, ['.webhooks[]?.clientConfig.caBundle'], kind);
  }
});

test('the render holds no Helm hook', () => {
  const docs = objects(render());
  assert.deepEqual(docs.filter(d => d.metadata.annotations?.['helm.sh/hook']).map(d => `${d.kind}/${d.metadata.name}`), []);
});
