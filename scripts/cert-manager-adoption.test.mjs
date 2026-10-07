import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// cert-manager under ArgoCD adopts the microk8s addon's Helm release in place: the same chart, the same
// release name, the same objects, plus the one flag that makes a Certificate own its Secret.

const app = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/inventories/cert-manager/app.yaml'], {encoding: 'utf8'}));
const render = (extra = []) => execFileSync('helm', ['template', app.releaseName, 'clusters/inventories/cert-manager', '--namespace', app.namespace,
  '-f', 'clusters/inventories/cert-manager/values-common.yaml', ...extra], {encoding: 'utf8'});
const objects = text => JSON.parse(execFileSync('yq', ['ea', '-o=json', '-I=0', '[.] | map(select(. != null and .kind != null))', '-'], {input: text, encoding: 'utf8'}));
const controllerArgs = docs => docs.find(d => d.kind === 'Deployment' && d.metadata.name === 'cert-manager').spec.template.spec.containers[0].args;

test('renders under the addon release name: its Deployments, with the selectors the running ones hold', () => {
  assert.equal(app.releaseName, 'cert-manager');
  const selectors = Object.fromEntries(objects(render()).filter(d => d.kind === 'Deployment').map(d => [d.metadata.name, d.spec.selector.matchLabels]));
  assert.deepEqual(selectors, {
    'cert-manager': {'app.kubernetes.io/name': 'cert-manager', 'app.kubernetes.io/instance': 'cert-manager', 'app.kubernetes.io/component': 'controller'},
    'cert-manager-cainjector': {'app.kubernetes.io/name': 'cainjector', 'app.kubernetes.io/instance': 'cert-manager', 'app.kubernetes.io/component': 'cainjector'},
    'cert-manager-webhook': {'app.kubernetes.io/name': 'webhook', 'app.kubernetes.io/instance': 'cert-manager', 'app.kubernetes.io/component': 'webhook'},
  });
});

test('PLANTED DEFECT: the controller runs with the owner-ref flag, and without the value it does not', () => {
  assert.ok(controllerArgs(objects(render())).includes('--enable-certificate-owner-ref=true'));
  assert.ok(!controllerArgs(objects(render(['--set', 'cert-manager.enableCertificateOwnerRef=false']))).includes('--enable-certificate-owner-ref=true'));
});

test('ships its CRDs, syncs them server-side, and renders no post-install hook beside the release', () => {
  const docs = objects(render());
  assert.ok(docs.filter(d => d.kind === 'CustomResourceDefinition').length >= 6);
  assert.equal(app.serverSideApply, 'true');
  assert.deepEqual(docs.filter(d => d.metadata.annotations?.['helm.sh/hook']).map(d => `${d.kind}/${d.metadata.name}`), []);
});

// The CRDs hold every Certificate, and with the owner-ref flag every TLS Secret hangs off one: no sync
// prunes the app, and ArgoCD keeps a CRD carrying the keep policy when the Application is deleted.
const crdsWithoutKeep = docs => docs.filter(d => d.kind === 'CustomResourceDefinition' && d.metadata.annotations?.['helm.sh/resource-policy'] !== 'keep').map(d => d.metadata.name);

test('PLANTED DEFECT: nothing removes the CRDs, neither a prune nor the Application\'s deletion', () => {
  assert.equal(app.prune, 'false');
  assert.deepEqual(crdsWithoutKeep(objects(render())), []);
  assert.ok(crdsWithoutKeep(objects(render(['--set', 'cert-manager.crds.keep=false']))).length >= 6);
});

// The patch the platform ApplicationSet lays over each Application, as it renders for this app.yaml.
const appset = JSON.parse(execFileSync('yq', ['-o=json', '.spec', 'clusters/argocd/files/platform-apps-appset.yaml'], {encoding: 'utf8'}));
const [{output, error}] = JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
  input: JSON.stringify({template: appset.templatePatch, options: appset.goTemplateOptions, params: [app]}), encoding: 'utf8'}));
const application = JSON.parse(execFileSync('yq', ['-o=json', '.'], {input: output ?? '', encoding: 'utf8'}));

test('every webhook configuration whose caBundle the cainjector writes is compared without it', () => {
  assert.equal(error, undefined);
  const injected = objects(render()).filter(d => d.metadata.annotations?.['cert-manager.io/inject-ca-from-secret']).map(d => d.kind);
  assert.deepEqual([...new Set(injected)].sort(), ['MutatingWebhookConfiguration', 'ValidatingWebhookConfiguration']);
  for (const kind of injected) {
    const rule = application.spec.ignoreDifferences.find(r => r.kind === kind);
    assert.equal(rule?.group, 'admissionregistration.k8s.io', kind);
    assert.deepEqual(rule.jqPathExpressions, ['.webhooks[]?.clientConfig.caBundle'], kind);
  }
});
