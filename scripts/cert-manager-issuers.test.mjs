import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// cert-manager-issuers renders the platform's ClusterIssuer: either platform-acme, bound to the
// installation's one ACME account, or the local authority chain when public certificates are withheld.

const app = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/inventories/cert-manager-issuers/app.yaml'], {encoding: 'utf8'}));
const render = (extra = []) => execFileSync('helm', ['template', app.name, 'clusters/inventories/cert-manager-issuers', '--namespace', app.namespace, ...extra], {encoding: 'utf8'});
const objects = text => JSON.parse(execFileSync('yq', ['ea', '-o=json', '-I=0', '[.] | map(select(. != null and .kind != null))', '-'], {input: text, encoding: 'utf8'}));

const email = 'check@check.example.invalid';

// THE ONE ACME ACCOUNT (Google Trust Services). platform-acme binds the account whose key and External
// Account Binding cert-manager-account delivers into Secret platform-acme-account, named by the key id
// the cluster's map carries as global.acmeEabKeyId. There is no other form: a map without the key id is
// refused by its name, never answered with an issuer that generates a key of its own.
const gts = 'https://dv.acme-v02.api.pki.goog/directory';
const keyID = 'synthetic-eab-key-id';
const acme = (extra = []) => render(['--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptEmail=${email}`, '--set', `global.letsencryptServer=${gts}`, ...extra]);
const SOLVERS = [{http01: {ingress: {ingressClassName: 'public', serviceType: 'ClusterIP'}}}];

test('platform-acme binds the one account: no key of its own, the delivered key and the binding', () => {
  const docs = objects(acme(['--set', `global.acmeEabKeyId=${keyID}`]));
  assert.equal(docs.length, 1);
  assert.equal(docs[0].kind, 'ClusterIssuer');
  assert.equal(docs[0].metadata.name, 'platform-acme');
  assert.deepEqual(docs[0].spec, {
    acme: {
      email,
      server: gts,
      disableAccountKeyGeneration: true,
      privateKeySecretRef: {name: 'platform-acme-account'},
      externalAccountBinding: {keyID, keySecretRef: {name: 'platform-acme-account', key: 'eab-mac-key'}},
      solvers: SOLVERS,
    },
  });
});

test('PLANTED DEFECT: a map without global.acmeEabKeyId, or with an empty one, is refused naming global.acmeEabKeyId', () => {
  assert.throws(() => execFileSync('helm', ['template', app.name, 'clusters/inventories/cert-manager-issuers', '--namespace', app.namespace,
    '--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptEmail=${email}`, '--set', `global.letsencryptServer=${gts}`],
    {encoding: 'utf8', stdio: 'pipe'}), /global\.acmeEabKeyId/);
  assert.throws(() => execFileSync('helm', ['template', app.name, 'clusters/inventories/cert-manager-issuers', '--namespace', app.namespace,
    '--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptEmail=${email}`, '--set', `global.letsencryptServer=${gts}`, '--set', 'global.acmeEabKeyId='],
    {encoding: 'utf8', stdio: 'pipe'}), /global\.acmeEabKeyId/);
});

test('PLANTED DEFECT: without global.letsencryptEmail the render fails naming global.letsencryptEmail', () => {
  assert.throws(
    () => render(['--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptServer=${gts}`, '--set', `global.acmeEabKeyId=${keyID}`]),
    /global\.letsencryptEmail/
  );
});

test('platform-local renders platform-self-signed, platform-ca and platform-local, and no platform-acme', () => {
  const docs = objects(render(['--set', 'global.clusterIssuer=platform-local']));
  assert.equal(docs.find(d => d.kind === 'ClusterIssuer' && d.metadata.name === 'platform-acme'), undefined);

  const selfSigned = docs.find(d => d.kind === 'ClusterIssuer' && d.metadata.name === 'platform-self-signed');
  assert.ok(selfSigned);
  assert.deepEqual(selfSigned.spec, {selfSigned: {}});

  const ca = docs.find(d => d.kind === 'Certificate' && d.metadata.name === 'platform-ca');
  assert.ok(ca);
  assert.equal(ca.metadata.namespace, 'cert-manager');
  assert.equal(ca.spec.isCA, true);
  assert.equal(ca.spec.secretName, 'platform-ca');
  assert.equal(ca.spec.issuerRef.name, 'platform-self-signed');

  const local = docs.find(d => d.kind === 'ClusterIssuer' && d.metadata.name === 'platform-local');
  assert.ok(local);
  assert.equal(local.spec.ca.secretName, 'platform-ca');
  assert.equal(ca.metadata.annotations['argocd.argoproj.io/sync-options'], 'Prune=false', 'the authority key survives a flip');
});

test('PLANTED DEFECT: letsencrypt-prod fails naming global.clusterIssuer', () => {
  assert.throws(
    () => render(['--set', 'global.clusterIssuer=letsencrypt-prod']),
    /global\.clusterIssuer/
  );
});

test('app.prune is "true" and the issuers stand where cert-manager and trust-manager stand', () => {
  assert.equal(app.prune, 'true');
  for (const family of ['cert-manager', 'trust-manager']) {
    const sibling = JSON.parse(execFileSync('yq', ['-o=json', '.', `clusters/inventories/${family}/app.yaml`], {encoding: 'utf8'}));
    assert.equal(app.runsOn, sibling.runsOn, `the issuers and ${family} select the same clusters`);
  }
});

test('PLANTED INNOCENT: platform-local ignores global.acmeEabKeyId', () => {
  const text = render(['--set', 'global.clusterIssuer=platform-local', '--set', `global.acmeEabKeyId=${keyID}`]);
  assert.equal(text, render(['--set', 'global.clusterIssuer=platform-local']));
  assert.doesNotMatch(text, /externalAccountBinding|platform-acme-account/);
});

const account = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/inventories/cert-manager-account/app.yaml'], {encoding: 'utf8'}));
const ACCOUNT_CHART = 'clusters/inventories/cert-manager-account';
// The values chain the platform appset hands every application (clusters/argocd/files/platform-apps-appset.yaml),
// with the cluster map's own keys set last.
const renderAccount = (stage, extra = []) => execFileSync('helm', ['template', `${account.name}-${stage}`, ACCOUNT_CHART, '--namespace', account.namespace,
  '-f', 'clusters/platform/values-common.yaml', '-f', `${ACCOUNT_CHART}/values-${stage}.yaml`,
  '--set', 'global.endpoints.vault.url=https://vault.check.example.invalid', '--set', 'global.vaultKubernetesAuthPath=kubernetes-check', ...extra], {encoding: 'utf8'});

test('cert-manager-account is a core app of wave 1 in cert-manager on every cluster, which creates no namespace', () => {
  assert.deepEqual(account, {name: 'cert-manager-account', project: 'core', syncWave: '1', namespace: 'cert-manager', prune: 'true', createNamespace: 'false', runsOn: 'every-cluster'});
});

test('cert-manager-account renders nothing under platform-local', () => {
  for (const stage of ['dev', 'test', 'prod']) {
    assert.deepEqual(objects(renderAccount(stage, ['--set', 'global.clusterIssuer=platform-local', '--set', `global.acmeEabKeyId=${keyID}`])), [], stage);
  }
});

test('under platform-acme, with or without the key id, one store and one ExternalSecret read exactly the account key and the MAC key of the stage', () => {
  for (const [stage, extra] of ['dev', 'test', 'prod'].flatMap(stage => [[stage, ['--set', `global.acmeEabKeyId=${keyID}`]], [stage, []]])) {
    const docs = objects(renderAccount(stage, ['--set', 'global.clusterIssuer=platform-acme', ...extra]));
    assert.deepEqual(docs.map(d => `${d.kind}/${d.metadata.name}/${d.metadata.namespace}`).sort(),
      ['ExternalSecret/platform-acme-account/cert-manager', 'SecretStore/vault-backend/cert-manager', 'ServiceAccount/external-secrets-sa/cert-manager'], stage);
    const store = docs.find(d => d.kind === 'SecretStore');
    assert.deepEqual(store.spec.provider.vault, {
      server: 'https://vault.check.example.invalid', path: 'secret', version: 'v2', namespace: 'vault',
      auth: {kubernetes: {mountPath: 'kubernetes-check', role: 'external-secrets', serviceAccountRef: {name: 'external-secrets-sa'}}},
    }, stage);
    const secret = docs.find(d => d.kind === 'ExternalSecret');
    assert.equal(secret.spec.refreshPolicy, 'OnChange');
    assert.equal(secret.spec.refreshInterval, '0');
    assert.deepEqual(secret.spec.secretStoreRef, {name: 'vault-backend', kind: 'SecretStore'});
    assert.deepEqual(secret.spec.target, {name: 'platform-acme-account', creationPolicy: 'Owner'});
    const ref = (key, property) => ({conversionStrategy: 'Default', decodingStrategy: 'None', metadataPolicy: 'None', nullBytePolicy: 'Ignore', key, property});
    assert.deepEqual(secret.spec.data, [
      {secretKey: 'tls.key', remoteRef: ref(`${stage}/app/acme-account`, 'private-key')},
      {secretKey: 'eab-mac-key', remoteRef: ref(`${stage}/app/acme-eab`, 'mac-key')},
    ], stage);
  }
});

test('PLANTED DEFECT: a cluster map without the Vault address fails the account render by name', () => {
  assert.throws(
    () => execFileSync('helm', ['template', 'x', ACCOUNT_CHART, '--namespace', 'cert-manager', '-f', 'clusters/platform/values-common.yaml', '-f', `${ACCOUNT_CHART}/values-prod.yaml`,
      '--set', 'global.vaultKubernetesAuthPath=kubernetes-check', '--set', 'global.clusterIssuer=platform-acme'], {encoding: 'utf8', stdio: 'pipe'}),
    /global\.endpoints\.vault\.url/
  );
});
