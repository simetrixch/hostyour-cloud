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
// The installation's two zones, as every cluster map of the books branch names them.
const platformDomain = 'simplidigita.ai';
const unitApex = 'digitacloud.app';
const ZONES = ['--set', `global.platformDomain=${platformDomain}`, '--set', `global.unitApex=${unitApex}`];
const acme = (extra = []) => render(['--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptEmail=${email}`, '--set', `global.letsencryptServer=${gts}`, ...ZONES, ...extra]);
const SOLVERS = [
  {http01: {ingress: {ingressClassName: 'public', serviceType: 'ClusterIP'}}},
  {selector: {dnsZones: [platformDomain, unitApex]}, dns01: {cloudflare: {apiTokenSecretRef: {name: 'platform-acme-cloudflare-dns', key: 'api-token'}}}},
];

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
    '--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptEmail=${email}`, '--set', `global.letsencryptServer=${gts}`, ...ZONES],
    {encoding: 'utf8', stdio: 'pipe'}), /global\.acmeEabKeyId/);
  assert.throws(() => execFileSync('helm', ['template', app.name, 'clusters/inventories/cert-manager-issuers', '--namespace', app.namespace,
    '--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptEmail=${email}`, '--set', `global.letsencryptServer=${gts}`, ...ZONES, '--set', 'global.acmeEabKeyId='],
    {encoding: 'utf8', stdio: 'pipe'}), /global\.acmeEabKeyId/);
});

// The solver cert-manager v1.19.1 picks for one name (pkg/util/solverpicker/solverpicker.go, the
// dnsZones and no-selector branches, which are the only two this issuer uses): a solver without a
// selector is taken only while nothing was taken, and a solver whose dnsZones match the name wins
// over it. A zone matches a name that is the zone or ends in a dot and the zone, label by label.
function pick(solvers, name) {
  let picked;
  let pickedZoneLabels = 0;
  for (const solver of solvers) {
    if (!solver.selector) { picked ??= solver; continue; }
    const labels = Math.max(0, ...(solver.selector.dnsZones ?? []).filter(zone => name === zone || name.endsWith(`.${zone}`)).map(zone => zone.split('.').length));
    if (labels > pickedZoneLabels) { picked = solver; pickedZoneLabels = labels; }
  }
  return picked?.dns01 ? 'dns-01' : picked?.http01 ? 'http-01' : 'none';
}
// A name under each zone, each zone itself, the deep DNS-only names of the inventory, and names outside.
const CHALLENGES = {
  'show.simplidigita.ai': 'dns-01', 'www.show.simplidigita.ai': 'dns-01', 'simplidigita.ai': 'dns-01',
  'demo.dev.digitacloud.app': 'dns-01', 'vault.master.digitacloud.app': 'dns-01', 'digitacloud.app': 'dns-01',
  'shop.customer.example': 'http-01', 'notdigitacloud.app': 'http-01', 'digitacloud.app.customer.example': 'http-01',
};
const challenges = solvers => Object.fromEntries(Object.keys(CHALLENGES).map(name => [name, pick(solvers, name)]));

test('a name under either zone of the installation is answered by DNS-01, and every other name by HTTP-01', () => {
  const issuer = objects(acme(['--set', `global.acmeEabKeyId=${keyID}`]))[0];
  assert.deepEqual(challenges(issuer.spec.acme.solvers), CHALLENGES);
});

test('PLANTED DEFECT: without the DNS-01 solver, or with a zone missing, an owned name goes back to HTTP-01', () => {
  const solvers = objects(acme(['--set', `global.acmeEabKeyId=${keyID}`]))[0].spec.acme.solvers;
  assert.notDeepEqual(challenges(solvers.filter(solver => !solver.dns01)), CHALLENGES, 'the DNS-01 solver is gone');
  assert.notDeepEqual(challenges(solvers.map(solver => (solver.dns01 ? {...solver, selector: {dnsZones: [unitApex]}} : solver))), CHALLENGES, 'platformDomain is missing');
  assert.notDeepEqual(challenges(solvers.map(solver => (solver.dns01 ? {...solver, selector: undefined} : solver))), CHALLENGES, 'the DNS-01 solver takes every name');
  assert.deepEqual(challenges(structuredClone(solvers)), CHALLENGES, 'the planted innocent: the solvers as rendered');
});

test('PLANTED DEFECT: a map without global.platformDomain or global.unitApex is refused naming the key', () => {
  const base = ['--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptEmail=${email}`, '--set', `global.letsencryptServer=${gts}`, '--set', `global.acmeEabKeyId=${keyID}`];
  const quiet = extra => execFileSync('helm', ['template', app.name, 'clusters/inventories/cert-manager-issuers', '--namespace', app.namespace, ...base, ...extra], {encoding: 'utf8', stdio: 'pipe'});
  assert.throws(() => quiet(['--set', `global.unitApex=${unitApex}`]), /global\.platformDomain/);
  assert.throws(() => quiet(['--set', `global.platformDomain=${platformDomain}`]), /global\.unitApex/);
  assert.throws(() => quiet(['--set', `global.platformDomain=${platformDomain}`, '--set', 'global.unitApex=']), /global\.unitApex/);
});

test('PLANTED INNOCENT: one zone named twice, as a single-zone installation names it, is one entry', () => {
  const issuer = objects(acme(['--set', `global.acmeEabKeyId=${keyID}`, '--set', `global.platformDomain=${unitApex}`]))[0];
  assert.deepEqual(issuer.spec.acme.solvers[1].selector, {dnsZones: [unitApex]});
});

test('PLANTED DEFECT: without global.letsencryptEmail the render fails naming global.letsencryptEmail', () => {
  assert.throws(
    () => render(['--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptServer=${gts}`, '--set', `global.acmeEabKeyId=${keyID}`, ...ZONES]),
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

test('under platform-acme, with or without the key id, one store and two ExternalSecrets read exactly the account key, the MAC key and the DNS token of the stage', () => {
  for (const [stage, extra] of ['dev', 'test', 'prod'].flatMap(stage => [[stage, ['--set', `global.acmeEabKeyId=${keyID}`]], [stage, []]])) {
    const docs = objects(renderAccount(stage, ['--set', 'global.clusterIssuer=platform-acme', ...extra]));
    assert.deepEqual(docs.map(d => `${d.kind}/${d.metadata.name}/${d.metadata.namespace}`).sort(),
      ['ExternalSecret/platform-acme-account/cert-manager', 'ExternalSecret/platform-acme-cloudflare-dns/cert-manager', 'SecretStore/vault-backend/cert-manager', 'ServiceAccount/external-secrets-sa/cert-manager'], stage);
    const store = docs.find(d => d.kind === 'SecretStore');
    assert.deepEqual(store.spec.provider.vault, {
      server: 'https://vault.check.example.invalid', path: 'secret', version: 'v2', namespace: 'vault',
      auth: {kubernetes: {mountPath: 'kubernetes-check', role: 'external-secrets', serviceAccountRef: {name: 'external-secrets-sa'}}},
    }, stage);
    const ref = (key, property) => ({conversionStrategy: 'Default', decodingStrategy: 'None', metadataPolicy: 'None', nullBytePolicy: 'Ignore', key, property});
    const expected = {
      'platform-acme-account': [
        {secretKey: 'tls.key', remoteRef: ref(`${stage}/app/acme-account`, 'private-key')},
        {secretKey: 'eab-mac-key', remoteRef: ref(`${stage}/app/acme-eab`, 'mac-key')},
      ],
      // The Secret the DNS-01 solver of platform-acme names, under the key it names.
      [SOLVERS[1].dns01.cloudflare.apiTokenSecretRef.name]: [
        {secretKey: SOLVERS[1].dns01.cloudflare.apiTokenSecretRef.key, remoteRef: ref(`${stage}/app/cloudflare-dns`, 'api-token')},
      ],
    };
    for (const secret of docs.filter(d => d.kind === 'ExternalSecret')) {
      assert.equal(secret.spec.refreshPolicy, 'OnChange');
      assert.equal(secret.spec.refreshInterval, '0');
      assert.deepEqual(secret.spec.secretStoreRef, {name: 'vault-backend', kind: 'SecretStore'});
      assert.deepEqual(secret.spec.target, {name: secret.metadata.name, creationPolicy: 'Owner'});
      assert.deepEqual(secret.spec.data, expected[secret.metadata.name], `${stage} ${secret.metadata.name}`);
    }
  }
});

test('PLANTED DEFECT: a cluster map without the Vault address fails the account render by name', () => {
  assert.throws(
    () => execFileSync('helm', ['template', 'x', ACCOUNT_CHART, '--namespace', 'cert-manager', '-f', 'clusters/platform/values-common.yaml', '-f', `${ACCOUNT_CHART}/values-prod.yaml`,
      '--set', 'global.vaultKubernetesAuthPath=kubernetes-check', '--set', 'global.clusterIssuer=platform-acme'], {encoding: 'utf8', stdio: 'pipe'}),
    /global\.endpoints\.vault\.url/
  );
});
