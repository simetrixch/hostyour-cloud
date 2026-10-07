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
