import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {applicationOf, driftFindings, renderChart, renderTwice} from './render-chart.mjs';

// Forgejo on the master. A person signs in through the identity provider alone, and only as a member
// of `admins` or of `plane-users`, the group of the Plane sign-in test accounts: no password form, no local administrator, an account made at the first sign-in. It
// keeps its data in SQLite in its one volume, serves no package registry, takes Git over SSH on the
// master's port 2222, and may send a webhook to the build plane's EventListener and nowhere else. The
// keys it signs and encrypts with it makes itself, in app.ini on the same volume.

const docs = input => JSON.parse(execFileSync('yq', ['ea', '-o=json', '-I=0', '[.]', '-'], {input, encoding: 'utf8'})).filter(Boolean);
const platform = JSON.parse(execFileSync('yq', ['-o=json', '.global', 'clusters/platform/values-common.yaml'], {encoding: 'utf8'}));
const clusterMap = JSON.parse(execFileSync('yq', ['-o=json', '.global', 'scripts/standin/cluster-map.yaml'], {encoding: 'utf8'}));
const blueprintFile = 'clusters/bootstrap/idp/blueprints/99-forgejo.yaml';
const blueprintText = readFileSync(blueprintFile, 'utf8');
const idpValues = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/bootstrap/idp/values.yaml'], {encoding: 'utf8'}));

/** The app.ini sections the chart writes, as {section: {KEY: value}}. */
function appIni(objects) {
  const inline = objects.find(o => o.kind === 'Secret' && o.metadata.name === 'forgejo-inline-config');
  return Object.fromEntries(Object.entries(inline?.stringData ?? {}).map(([section, body]) =>
    [section, Object.fromEntries(String(body).split('\n').map(line => line.split(/=(.*)/s).slice(0, 2)))]));
}

/** Every way the render breaks the rules above, named. */
function renderFindings(objects) {
  const found = [];
  const ini = appIni(objects);
  const expect = (section, key, value) => {
    if (ini[section]?.[key] !== value) found.push(`[${section}] ${key} is ${ini[section]?.[key]}, not ${value}`);
  };
  expect('service', 'ENABLE_INTERNAL_SIGNIN', 'false');
  expect('service', 'ALLOW_ONLY_EXTERNAL_REGISTRATION', 'true');
  expect('oauth2_client', 'ENABLE_AUTO_REGISTRATION', 'true');
  expect('packages', 'ENABLED', 'false');
  expect('database', 'DB_TYPE', 'sqlite3');
  expect('webhook', 'ALLOWED_HOST_LIST', 'el-image-builder.image-builder.svc');
  expect('server', 'SSH_LISTEN_PORT', '2222');

  const deployment = objects.find(o => o.kind === 'Deployment' && o.metadata.name === 'forgejo');
  if (!deployment) return [...found, 'no Deployment forgejo'];
  const containers = [...deployment.spec.template.spec.initContainers, ...deployment.spec.template.spec.containers];
  if (containers.some(c => (c.env ?? []).some(e => e.name.startsWith('GITEA_ADMIN_')))) found.push('a local administrator is created');
  const ssh = deployment.spec.template.spec.containers.flatMap(c => c.ports ?? []).find(p => p.name === 'ssh');
  if (ssh?.hostPort !== 2222 || ssh?.containerPort !== 2222) found.push(`Git over SSH listens on ${ssh?.containerPort}, host port ${ssh?.hostPort}`);

  const claims = objects.filter(o => o.kind === 'PersistentVolumeClaim');
  if (claims.length !== 1 || claims[0].spec.storageClassName !== platform.storageClass) found.push(`${claims.length} volume claims, on ${claims.map(c => c.spec.storageClassName)}`);
  const extra = objects.filter(o => ['StatefulSet', 'DaemonSet', 'Job', 'CronJob', 'Pod'].includes(o.kind));
  if (extra.length > 0) found.push(`more than Forgejo runs: ${extra.map(o => `${o.kind}/${o.metadata.name}`).join(', ')}`);

  const ingresses = objects.filter(o => o.kind === 'Ingress');
  if (ingresses.length !== 1) return [...found, `${ingresses.length} Ingresses, not 1`];
  const [ingress] = ingresses;
  const annotations = ingress.metadata.annotations ?? {};
  if (annotations['traefik.ingress.kubernetes.io/router.entrypoints'] !== 'websecure') found.push('the Ingress is served on more than websecure');
  if (annotations['traefik.ingress.kubernetes.io/router.middlewares'] !== undefined) found.push('the Ingress sits behind a middleware, so Git clients cannot reach it');
  if (annotations['cert-manager.io/cluster-issuer'] !== platform.clusterIssuer) found.push(`the Ingress is issued by ${annotations['cert-manager.io/cluster-issuer']}`);
  const rule = ingress.spec.rules?.[0];
  const backend = rule?.http.paths[0].backend.service;
  if (rule?.host !== `forgejo.${clusterMap.domain}` || backend?.name !== 'forgejo-http' || backend?.port.number !== 3000) found.push(`the Ingress routes ${rule?.host} to ${backend?.name}:${backend?.port.number}`);

  const secrets = objects.filter(o => o.kind === 'ExternalSecret');
  const oauth = secrets.find(o => o.metadata.name === 'forgejo-oauth');
  if (secrets.length !== 1 || oauth?.spec.data.some(d => d.remoteRef.key !== 'prod/app/forgejo')) found.push(`${secrets.length} ExternalSecrets, not forgejo-oauth reading prod/app/forgejo alone`);
  if (oauth?.spec.target.template?.data?.key !== 'forgejo') found.push('forgejo-oauth does not name the client forgejo');
  return found;
}

/** Every way the identity provider's side breaks the rules above, named. */
function blueprintFindings(text, values) {
  const found = [];
  const blueprint = JSON.parse(execFileSync('yq', ['-o=json', '.', '-'], {input: text, encoding: 'utf8'}));
  const tag = path => execFileSync('yq', [`${path} | tag`, '-'], {input: text, encoding: 'utf8'}).trim();
  const provider = blueprint.entries.find(e => e.model === 'authentik_providers_oauth2.oauth2provider');
  if (provider?.attrs.client_id !== 'forgejo') found.push(`the client id is ${provider?.attrs.client_id}`);
  if (provider?.attrs.client_secret !== 'IDP_FORGEJO_CLIENT_SECRET' || tag('.entries[0].attrs.client_secret') !== '!Env') found.push('the client secret is not !Env IDP_FORGEJO_CLIENT_SECRET');
  if (JSON.stringify(provider?.attrs.redirect_uris?.map(r => r.url)) !== JSON.stringify([['https://forgejo.%s/user/oauth2/authentik/callback', 'IDP_DOMAIN']])) found.push('the redirect is not the callback of the source `authentik`');
  if (!provider?.attrs.property_mappings?.some(m => JSON.stringify(m) === JSON.stringify(['authentik_providers_oauth2.scopemapping', ['scope_name', 'groups']]))) found.push('the groups scope is not handed out, so adminGroup reads nothing');
  const bindings = blueprint.entries.filter(e => e.model === 'authentik_policies.policybinding');
  const admits = JSON.stringify(bindings.map(b => [b.identifiers.target, b.identifiers.group]));
  const forgejoApp = ['authentik_core.application', ['slug', 'forgejo']];
  if (admits !== JSON.stringify(['admins', 'plane-users'].map(name => [forgejoApp, ['authentik_core.group', ['name', name]]]))) found.push(`sign-in is admitted by ${admits}, not by the groups admins and plane-users alone`);
  const waitsFor = JSON.stringify(blueprint.conditions);
  for (const name of ['admins', 'plane-users']) {
    if (!waitsFor.includes(JSON.stringify(['authentik_core.group', ['name', name]]))) found.push(`the blueprint does not wait for the group ${name}, so a binding on it fails at a first start`);
  }
  if (!values.global.podAnnotations['platform/oidc-clients'].split(' ').includes('forgejo')) found.push('platform/oidc-clients does not list forgejo, so the provider never restarts onto the new secret');
  return found;
}

test('Forgejo renders the sign-in, storage, SSH, Ingress and secret rules', () => {
  assert.deepEqual(renderFindings(renderChart('forgejo')), []);
});

test('the identity provider admits the groups admins and plane-users alone to Forgejo', () => {
  assert.deepEqual(blueprintFindings(blueprintText, idpValues), []);
});

test('PLANTED DEFECT: a password form, a local administrator, a package registry, a wider webhook list and forward auth are each found', () => {
  const planted = {
    'the password form': ['--set', 'forgejo.gitea.config.service.ENABLE_INTERNAL_SIGNIN=true'],
    'a local administrator': ['--set', 'forgejo.gitea.admin.username=root', '--set', 'forgejo.gitea.admin.password=planted'],
    'a package registry': ['--set', 'forgejo.gitea.config.packages.ENABLED=true'],
    'webhooks to anywhere outside': ['--set', 'forgejo.gitea.config.webhook.ALLOWED_HOST_LIST=external'],
    'forward auth on Git': ['--set-string', 'ingress.ingress.annotations.traefik\\.ingress\\.kubernetes\\.io/router\\.middlewares=idp-forwardauth@kubernetescrd'],
  };
  for (const [name, args] of Object.entries(planted)) {
    assert.notDeepEqual(renderFindings(renderChart('forgejo', args)), [], name);
  }
});

test('PLANTED DEFECT: a blueprint without either binding, or with a third binding beside them, is found', () => {
  const unbound = blueprintText.replace(/  - id: forgejo-admins-binding[\s\S]*$/, '');
  assert.notEqual(unbound, blueprintText);
  assert.deepEqual(blueprintFindings(unbound, idpValues), ['sign-in is admitted by [], not by the groups admins and plane-users alone']);
  const adminsOnly = blueprintText.replace(/  - id: forgejo-plane-users-binding[\s\S]*$/, '');
  assert.notEqual(adminsOnly, blueprintText);
  assert.equal(blueprintFindings(adminsOnly, idpValues).length, 1, 'the group plane-users is not admitted');
  const widened = `${blueprintText}  - id: planted-everyone\n    model: authentik_policies.policybinding\n    identifiers:\n      target: !Find [authentik_core.application, [slug, forgejo]]\n      group: !Find [authentik_core.group, [name, everyone]]\n      order: 2\n`;
  assert.equal(blueprintFindings(widened, idpValues).length, 1);
  const unawaited = blueprintText.replace(/  - !Find \[authentik_core.group, \[name, plane-users\]\]\n/, '');
  assert.notEqual(unawaited, blueprintText);
  assert.equal(blueprintFindings(unawaited, idpValues).length, 1, 'the blueprint does not wait for the group plane-users');
});

test('PLANTED INNOCENT: another application name or another image tag changes nothing the rules hold', () => {
  assert.deepEqual(renderFindings(renderChart('forgejo', ['--set', 'forgejo.gitea.config.APP_NAME=planted', '--set', 'forgejo.image.tag=15.0.10'])), []);
});

test('a render a second later changes nothing a sync of forgejo writes', () => {
  const app = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/inventories/forgejo/app.yaml'], {encoding: 'utf8'}));
  assert.deepEqual(driftFindings(...renderTwice('forgejo'), applicationOf(app)), []);
});
