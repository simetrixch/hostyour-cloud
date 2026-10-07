import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// cert-manager-issuers renders the platform's ClusterIssuer: either platform-acme as every cluster
// holds it today, or the local authority chain when public certificates are withheld.

const app = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/inventories/cert-manager-issuers/app.yaml'], {encoding: 'utf8'}));
const render = (extra = []) => execFileSync('helm', ['template', app.name, 'clusters/inventories/cert-manager-issuers', '--namespace', app.namespace, ...extra], {encoding: 'utf8'});
const objects = text => JSON.parse(execFileSync('yq', ['ea', '-o=json', '-I=0', '[.] | map(select(. != null and .kind != null))', '-'], {input: text, encoding: 'utf8'}));

const email = 'check@check.example.invalid';
const server = 'https://acme-staging-v02.api.letsencrypt.org/directory';

test('platform-acme with an email and a server renders exactly one ClusterIssuer platform-acme whose spec equals the live spec', () => {
  const docs = objects(render([
    '--set', 'global.clusterIssuer=platform-acme',
    '--set', `global.letsencryptEmail=${email}`,
    '--set', `global.letsencryptServer=${server}`,
  ]));
  assert.equal(docs.length, 1);
  const issuer = docs[0];
  assert.equal(issuer.kind, 'ClusterIssuer');
  assert.equal(issuer.metadata.name, 'platform-acme');
  assert.deepEqual(issuer.spec, {
    acme: {
      email,
      privateKeySecretRef: {
        name: 'platform-acme',
      },
      server,
      solvers: [
        {
          http01: {
            ingress: {
              ingressClassName: 'public',
              serviceType: 'ClusterIP',
            },
          },
        },
      ],
    },
  });
});

test('PLANTED DEFECT: without global.letsencryptEmail the render fails naming global.letsencryptEmail', () => {
  assert.throws(
    () => render(['--set', 'global.clusterIssuer=platform-acme', '--set', `global.letsencryptServer=${server}`]),
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

// The installer still writes the local authority from its bootstrap files on a fresh cluster, and this
// Application adopts what it wrote: a spec that drifted from them would issue the authority again.
test('PLANTED DEFECT: the local authority equals the installer\'s bootstrap documents, spec for spec', () => {
  const rendered = objects(render(['--set', 'global.clusterIssuer=platform-local']));
  const bootstrap = ['platform-authority.yaml', 'platform-authority-issuer.yaml']
    .flatMap(f => objects(execFileSync('cat', [`clusters/bootstrap/cert-manager/${f}`], {encoding: 'utf8'})));
  assert.equal(bootstrap.length, 3);
  for (const want of bootstrap) {
    const got = rendered.find(d => d.kind === want.kind && d.metadata.name === want.metadata.name);
    assert.deepEqual(got?.spec, want.spec, `${want.kind}/${want.metadata.name}`);
  }
});

test('PLANTED DEFECT: letsencrypt-prod fails naming global.clusterIssuer', () => {
  assert.throws(
    () => render(['--set', 'global.clusterIssuer=letsencrypt-prod']),
    /global\.clusterIssuer/
  );
});

test('app.prune is "true" and app.runsOn is apps8', () => {
  assert.equal(app.prune, 'true');
  assert.equal(app.runsOn, 'apps8');
});
