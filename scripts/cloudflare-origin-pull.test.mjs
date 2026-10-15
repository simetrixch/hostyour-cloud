import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';

// cloudflare-origin-pull renders, on every cluster, the TLSOption every route of a host behind
// Cloudflare's proxy names, and the delivery of the CA it verifies the client certificate against.

const CHART = 'clusters/inventories/cloudflare-origin-pull';
const yq = (args, input) => JSON.parse(execFileSync('yq', args, {encoding: 'utf8', ...(input ? {input} : {})}));
const app = yq(['-o=json', '.', `${CHART}/app.yaml`]);
// The values chain the platform appset hands every application (clusters/argocd/files/platform-apps-appset.yaml).
const render = (stage, extra = []) => execFileSync('helm', ['template', `${app.name}-${stage}`, CHART, '--namespace', app.namespace,
  '-f', 'clusters/platform/values-common.yaml', '-f', `clusters/platform/values-${stage}.yaml`,
  '--set', 'global.endpoints.vault.url=https://vault.check.example.invalid', '--set', 'global.vaultKubernetesAuthPath=kubernetes-check', ...extra],
{encoding: 'utf8', stdio: 'pipe'});
const objects = text => yq(['ea', '-o=json', '-I=0', '[.] | map(select(. != null and .kind != null))', '-'], text);
const STAGES = ['dev', 'test', 'prod'];

// The unescape of a PEM kept on one line with \n, as ESO evaluates it for the GitHub App's key
// (clusters/inventories/argocd-secrets), whose one difference is the field it reads. Helm passes the
// text between the backticks through as it stands.
const appKey = readFileSync('clusters/inventories/argocd-secrets/templates/externalsecret-repo-deploy.yaml', 'utf8').match(/githubAppPrivateKey: '\{\{ `(.*)` \}\}'/)[1];
const UNESCAPE = appKey.replace('"private-key"', '"ca-certificate"');

/** Every way the rendered objects and the app fail the routes that name the TLSOption, named. */
function findings(docs, application, stage) {
  const found = [];
  const of = kind => docs.filter(d => d.kind === kind);
  const option = of('TLSOption').find(d => d.metadata.name === 'cloudflare-origin-pull');
  if (!option) found.push('no TLSOption cloudflare-origin-pull');
  if (application.namespace !== 'ingress') found.push(`the TLSOption stands in ${application.namespace}, so ingress-cloudflare-origin-pull@kubernetescrd names nothing`);
  if (application.runsOn !== 'every-cluster') found.push(`the TLSOption stands only on ${application.runsOn}`);
  if (application.createNamespace !== 'true') found.push('the namespace never gets the label the store\'s Vault role admits');
  if (option && option.spec.clientAuth?.clientAuthType !== 'RequireAndVerifyClientCert') found.push(`the TLSOption asks ${option.spec.clientAuth?.clientAuthType}, so a connection without the client certificate passes`);
  const secretNames = option?.spec.clientAuth?.secretNames ?? [];
  const secret = of('ExternalSecret').find(d => secretNames.includes(d.spec.target?.name));
  if (!secret) { found.push(`no ExternalSecret writes ${secretNames.join(', ') || 'the Secret the TLSOption names'}`); return found; }
  const {target, data, refreshPolicy, secretStoreRef} = secret.spec;
  if (target.deletionPolicy !== 'Delete') found.push('a missing entry is an error, and the application holds up its wave');
  if (refreshPolicy !== 'OnChange') found.push(`the CA is read ${refreshPolicy}`);
  if (JSON.stringify(Object.keys(target.template?.data ?? {})) !== '["tls.ca"]') found.push(`the Secret carries ${Object.keys(target.template?.data ?? {})}, not tls.ca alone`);
  if (target.template?.data?.['tls.ca'] !== UNESCAPE) found.push(`tls.ca is ${target.template?.data?.['tls.ca']}`);
  const read = data?.map(d => `${d.secretKey}=${d.remoteRef.key}:${d.remoteRef.property}`);
  if (JSON.stringify(read) !== JSON.stringify([`ca-certificate=${stage}/app/cloudflare-origin-pull:ca-certificate`])) found.push(`the CA is read from ${read}`);
  const store = of('SecretStore').find(d => d.metadata.name === secretStoreRef.name);
  if (!store) found.push(`no SecretStore ${secretStoreRef.name}`);
  else if (!of('ServiceAccount').some(d => d.metadata.name === store.spec.provider.vault.auth.kubernetes.serviceAccountRef.name)) found.push('the store logs in with a ServiceAccount nothing renders');
  return found;
}

test('cloudflare-origin-pull is a core app of wave 5 in ingress on every cluster, which labels the namespace', () => {
  assert.deepEqual(app, {name: 'cloudflare-origin-pull', project: 'core', syncWave: '5', namespace: 'ingress', prune: 'true', createNamespace: 'true', runsOn: 'every-cluster'});
});

test('every stage renders the TLSOption that requires the client certificate and the CA of the stage it verifies against', () => {
  assert.match(UNESCAPE, /^\{\{ index \. "ca-certificate" \| replace "\\\\n" "\\n" \}\}$/);
  for (const stage of STAGES) {
    const docs = objects(render(stage));
    assert.deepEqual(docs.map(d => `${d.kind}/${d.metadata.name}/${d.metadata.namespace}`).sort(),
      ['ExternalSecret/cloudflare-origin-pull-ca/ingress', 'SecretStore/vault-backend/ingress', 'ServiceAccount/external-secrets-sa/ingress', 'TLSOption/cloudflare-origin-pull/ingress'], stage);
    assert.deepEqual(docs.find(d => d.kind === 'SecretStore').spec.provider.vault, {
      server: 'https://vault.check.example.invalid', path: 'secret', version: 'v2', namespace: 'vault',
      auth: {kubernetes: {mountPath: 'kubernetes-check', role: 'external-secrets', serviceAccountRef: {name: 'external-secrets-sa'}}},
    }, stage);
    assert.deepEqual(findings(docs, app, stage), [], stage);
  }
});

test('PLANTED DEFECT: each way a route of a proxied host would admit a connection, or the CA would not arrive, is found', () => {
  const docs = objects(render('prod'));
  const planted = {
    'the client certificate is optional': d => { d.find(o => o.kind === 'TLSOption').spec.clientAuth.clientAuthType = 'VerifyClientCertIfGiven'; },
    'the TLSOption names another Secret': d => { d.find(o => o.kind === 'TLSOption').spec.clientAuth.secretNames = ['platform-acme-account']; },
    'the TLSOption is gone': d => { d.splice(d.findIndex(o => o.kind === 'TLSOption'), 1); },
    'a missing entry holds the wave': d => { delete d.find(o => o.kind === 'ExternalSecret').spec.target.deletionPolicy; },
    'the PEM keeps its escaped line breaks': d => { d.find(o => o.kind === 'ExternalSecret').spec.target.template.data['tls.ca'] = '{{ index . "ca-certificate" }}'; },
    'the CA is read from another stage': d => { d.find(o => o.kind === 'ExternalSecret').spec.data[0].remoteRef.key = 'test/app/cloudflare-origin-pull'; },
    'the store has no ServiceAccount': d => { d.splice(d.findIndex(o => o.kind === 'ServiceAccount'), 1); },
  };
  for (const [name, plant] of Object.entries(planted)) {
    const copy = structuredClone(docs);
    plant(copy);
    assert.notDeepEqual(findings(copy, app, 'prod'), [], name);
  }
  assert.notDeepEqual(findings(docs, {...app, createNamespace: 'false'}, 'prod'), [], 'the namespace is not labelled');
  assert.notDeepEqual(findings(docs, {...app, runsOn: 'master'}, 'prod'), [], 'a slave has no TLSOption');
  assert.deepEqual(findings(structuredClone(docs), app, 'prod'), [], 'the planted innocent: the render as it is');
});

test('PLANTED DEFECT: a cluster map without the Vault address fails the render by name', () => {
  assert.throws(() => execFileSync('helm', ['template', 'x', CHART, '--namespace', 'ingress', '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
    '--set', 'global.vaultKubernetesAuthPath=kubernetes-check'], {encoding: 'utf8', stdio: 'pipe'}), /global\.endpoints\.vault\.url/);
});
