import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {renderChart} from './render-chart.mjs';

// Plane on the master. Every page waits for the identity provider's forward auth, and only /api/v1,
// Plane's API-key API, is reached without it. Its PostgreSQL, Redis, RabbitMQ and MinIO run beside
// it on the platform's StorageClass, and every secret it holds comes from <stage>/app/plane: the
// chart's public default keys and passwords never render.

const yq = (args, input) => JSON.parse(execFileSync('yq', ['-o=json', ...args], {encoding: 'utf8', ...(input ? {input} : {})}));
const platform = yq(['.global', 'clusters/platform/values-common.yaml']);
const app = yq(['.', 'clusters/inventories/plane/app.yaml']);
const FORWARD_AUTH = 'idp-forwardauth@kubernetescrd';
// The values plane-ce 1.8.5 falls back to, public in its own values.yaml.
const PUBLIC_DEFAULTS = ['60gp0byfz2dvffa45cxl20p1scy9xbpf6d8c5y0geejgkyp1b5', 'htbqvBJAgpm9bzvf3r4urJer0ENReatceh', 'plane:plane@'];

/** Every way the render breaks the rules above, named. */
function renderFindings(objects) {
  const found = [];
  const ingresses = objects.filter(o => o.kind === 'Ingress');
  const routes = objects.filter(o => o.kind === 'IngressRoute');
  if (routes.length > 0) found.push(`${routes.length} IngressRoutes beside the Ingresses`);
  for (const ingress of ingresses) {
    const annotations = ingress.metadata.annotations ?? {};
    if (annotations['traefik.ingress.kubernetes.io/router.entrypoints'] !== 'websecure') found.push(`${ingress.metadata.name} is served on more than websecure`);
    if (ingress.spec.tls?.[0]?.secretName !== 'plane-tls') found.push(`${ingress.metadata.name} is served without the certificate plane-tls`);
    const paths = ingress.spec.rules.flatMap(rule => rule.http.paths.map(path => path.path));
    const gated = annotations['traefik.ingress.kubernetes.io/router.middlewares'] === FORWARD_AUTH;
    if (!gated && JSON.stringify(paths) !== '["/api/v1"]') found.push(`${ingress.metadata.name} serves ${paths.join(', ')} without the forward auth`);
  }
  const api = ingresses.find(o => o.metadata.name === 'plane-api-v1');
  const backend = api?.spec.rules[0].http.paths[0].backend.service;
  if (backend?.name !== 'plane-api' || backend?.port.number !== 8000) found.push(`/api/v1 goes to ${backend?.name}:${backend?.port.number}, not Plane's API`);
  if (api?.metadata.annotations?.['cert-manager.io/cluster-issuer'] !== undefined) found.push('/api/v1 asks for the certificate a second time');
  if (!ingresses.some(o => o.metadata.annotations?.['traefik.ingress.kubernetes.io/router.middlewares'] === FORWARD_AUTH)) found.push('no Ingress waits for the forward auth');

  for (const name of ['pgdb', 'redis', 'rabbitmq', 'minio']) {
    const set = objects.find(o => o.kind === 'StatefulSet' && o.metadata.name === `plane-${name}-wl`);
    const classes = (set?.spec.volumeClaimTemplates ?? []).map(t => t.spec.storageClassName);
    if (classes.length !== 1 || classes[0] !== platform.storageClass) found.push(`${name} keeps its data on ${classes.join(', ') || 'nothing'}`);
  }

  const text = JSON.stringify(objects);
  for (const value of PUBLIC_DEFAULTS) if (text.includes(value)) found.push(`a public default of the chart renders: ${value}`);
  const chartSecrets = objects.filter(o => o.kind === 'Secret').map(o => o.metadata.name);
  if (JSON.stringify(chartSecrets) !== '["plane-live-secrets"]') found.push(`the chart writes the Secrets ${chartSecrets.join(', ')}`);
  const external = objects.filter(o => o.kind === 'ExternalSecret');
  for (const secret of external) {
    if (secret.spec.data.some(d => d.remoteRef.key !== 'prod/app/plane')) found.push(`${secret.metadata.name} reads beyond prod/app/plane`);
  }
  const workloads = objects.filter(o => ['Deployment', 'StatefulSet', 'Job'].includes(o.kind));
  const referenced = new Set(workloads.flatMap(w => [...(w.spec.template.spec.initContainers ?? []), ...w.spec.template.spec.containers])
    .flatMap(c => (c.envFrom ?? []).map(e => e.secretRef?.name).filter(Boolean)));
  const delivered = new Set([...external.map(s => s.spec.target.name), ...chartSecrets]);
  const missing = [...referenced].filter(name => !delivered.has(name));
  if (missing.length > 0) found.push(`the workloads read Secrets nothing delivers: ${missing.join(', ')}`);

  // The addresses the app is handed name the chart's own Services in the app's own namespace.
  const services = new Set(objects.filter(o => o.kind === 'Service').map(o => o.metadata.name));
  const env = external.find(o => o.metadata.name === 'plane-app-env')?.spec.target.template?.data ?? {};
  for (const [key, url] of Object.entries(env)) {
    const host = /^[a-z]+:\/\/(?:[^@/]*@)?([^:/]+)/.exec(url)?.[1] ?? '';
    const [service, namespace] = host.split('.');
    if (!services.has(service) || namespace !== app.namespace) found.push(`${key} names ${host}, not a Service of the chart in ${app.namespace}`);
  }
  const vars = objects.find(o => o.kind === 'ConfigMap' && o.metadata.name === 'plane-app-vars')?.data ?? {};
  if (!String(vars.WEB_URL).startsWith('https://')) found.push(`Plane is told it stands at ${vars.WEB_URL}`);
  return found;
}

const blueprints = 'clusters/bootstrap/idp/blueprints';
/** Every way the identity provider's side misses Plane, named. */
function blueprintFindings(proxyText, bindingsText) {
  const found = [];
  const proxy = yq(['.', '-'], proxyText).entries.find(e => e.model === 'authentik_providers_proxy.proxyprovider');
  if (JSON.stringify(proxy?.attrs.external_host) !== JSON.stringify(['https://plane.%s', 'IDP_DOMAIN'])) found.push(`the gate stands at ${JSON.stringify(proxy?.attrs.external_host)}`);
  const bindings = yq(['.', '-'], bindingsText);
  const plane = JSON.stringify(['authentik_providers_proxy.proxyprovider', ['name', proxy?.identifiers.name]]);
  if (!bindings.conditions.some(c => JSON.stringify(c) === plane)) found.push('the outpost binding does not wait for the Plane provider');
  if (!bindings.entries[0].attrs.providers.some(p => JSON.stringify(p) === plane)) found.push('the embedded outpost does not serve the Plane provider');
  return found;
}
const proxyText = readFileSync(`${blueprints}/99-proxy-plane.yaml`, 'utf8');
const bindingsText = readFileSync(`${blueprints}/99-z-outpost-bindings.yaml`, 'utf8');

test('Plane renders behind the forward auth, with /api/v1 alone outside it, its own data and no public default', () => {
  assert.deepEqual(renderFindings(renderChart('plane')), []);
});

test('the embedded outpost gates plane.<domain>', () => {
  assert.deepEqual(blueprintFindings(proxyText, bindingsText), []);
});

test('PLANTED DEFECT: an ungated page, a second ungated path, a public default, a volume off the platform class and a missing outpost binding are found', () => {
  const planted = {
    'the pages without the gate': ['--set-string', 'plane-ce.ingress.ingress_annotations.traefik\\.ingress\\.kubernetes\\.io/router\\.middlewares='],
    'the public default keys': ['--set', 'plane-ce.external_secrets.app_keys_existingSecret=', '--set', 'plane-ce.env.requireExplicitSecrets=false'],
    'the public database password': ['--set', 'plane-ce.external_secrets.app_env_existingSecret='],
    'a volume on no named class': ['--set', 'plane-ce.minio.storageClass='],
  };
  for (const [name, args] of Object.entries(planted)) {
    assert.notDeepEqual(renderFindings(renderChart('plane', args)), [], name);
  }
  const widened = renderChart('plane');
  widened.find(o => o.metadata?.name === 'plane-api-v1').spec.rules[0].http.paths.push({path: '/api', pathType: 'Prefix', backend: {service: {name: 'plane-api', port: {number: 8000}}}});
  assert.deepEqual(renderFindings(widened), ['plane-api-v1 serves /api/v1, /api without the forward auth']);
  assert.notDeepEqual(blueprintFindings(proxyText, bindingsText.replace(/\n\s*- !Find \[authentik_providers_proxy.proxyprovider, \[name, Plane\]\]/g, '')), []);
});

test('PLANTED INNOCENT: more replicas of the web app and a larger upload limit change nothing the rules hold', () => {
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.web.replicas=2', '--set', 'plane-ce.env.doc_upload_size_limit=10485760'])), []);
});
