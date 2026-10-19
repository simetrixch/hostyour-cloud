import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {cpSync, mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {applicationOf, driftFindings, renderChart, renderTwice} from './render-chart.mjs';

// Plane on the master. Every page waits for the identity provider's forward auth, and only /api/v1,
// Plane's API-key API, is reached without it. Its PostgreSQL, Redis, RabbitMQ and MinIO run beside
// it on the platform's StorageClass, and every secret it holds comes from <stage>/app/plane: the
// chart's public default keys and passwords never render. The four images of the data services run at
// the versions versions.yaml pins, which values-common.yaml states by hand.

const yq = (args, input) => JSON.parse(execFileSync('yq', ['-o=json', ...args], {encoding: 'utf8', ...(input ? {input} : {})}));
const platform = yq(['.global', 'clusters/platform/values-common.yaml']);
const pins = yq(['.images', 'clusters/platform/versions.yaml']);
const app = yq(['.', 'clusters/inventories/plane/app.yaml']);
const FORWARD_AUTH = 'idp-forwardauth@kubernetescrd';
const MIDDLEWARES = 'traefik.ingress.kubernetes.io/router.middlewares';
// The values plane-ce 1.8.5 falls back to, public in its own values.yaml.
const PUBLIC_DEFAULTS = ['60gp0byfz2dvffa45cxl20p1scy9xbpf6d8c5y0geejgkyp1b5', 'htbqvBJAgpm9bzvf3r4urJer0ENReatceh', 'plane:plane@'];

// plane-ce names its two Jobs by a hash of the images they run (clusters/inventories/plane/vendor).
const MIGRATION_JOB = /^plane-api-migrate-[0-9a-f]{8}$/;
const BUCKET_JOB = /^plane-minio-bucket-[0-9a-f]{8}$/;

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
    const gated = (annotations[MIDDLEWARES] ?? '').split(',')[0] === FORWARD_AUTH;
    if (!gated && JSON.stringify(paths) !== '["/api/v1"]') found.push(`${ingress.metadata.name} serves ${paths.join(', ')} without the forward auth`);
  }
  const api = ingresses.find(o => o.metadata.name === 'plane-api-v1');
  const backend = api?.spec.rules[0].http.paths[0].backend.service;
  if (backend?.name !== 'plane-api' || backend?.port.number !== 8000) found.push(`/api/v1 goes to ${backend?.name}:${backend?.port.number}, not Plane's API`);
  if (api?.metadata.annotations?.['cert-manager.io/cluster-issuer'] !== undefined) found.push('/api/v1 asks for the certificate a second time');
  if (!ingresses.some(o => (o.metadata.annotations?.[MIDDLEWARES] ?? '').split(',')[0] === FORWARD_AUTH)) found.push('no Ingress waits for the forward auth');

  // plane-admin's nginx answers /god-mode, which Plane's "Get started" opens, with a 301 to its own port,
  // http://<host>:3000/god-mode/. The chart's Ingress answers it first, after the forward auth, on the host
  // it was asked on; every other path passes untouched.
  const pages = ingresses.find(o => o.spec.rules[0].http.paths.some(path => path.path === '/god-mode'));
  const host = pages?.spec.rules[0].host;
  const slash = objects.find(o => o.kind === 'Middleware' && o.metadata.name === 'god-mode-trailing-slash');
  const chain = (pages?.metadata.annotations?.[MIDDLEWARES] ?? '').split(',');
  if (JSON.stringify(chain) !== JSON.stringify([FORWARD_AUTH, `${app.namespace}-god-mode-trailing-slash@kubernetescrd`])) found.push(`/god-mode passes ${chain.join(', ')}, not the forward auth and then the trailing-slash redirect`);
  const redirect = slash?.spec.redirectRegex;
  const answer = url => redirect && new RegExp(redirect.regex).test(url) ? url.replace(new RegExp(redirect.regex), redirect.replacement.replace(/\$\{(\d+)\}/g, '$$$1')) : url;
  for (const [asked, sent] of [['/god-mode', '/god-mode/'], ['/god-mode?next=1', '/god-mode/?next=1'], ['/god-mode/', '/god-mode/'],
    ['/god-mode/general', '/god-mode/general'], ['/god-modes', '/god-modes'], ['/spaces', '/spaces'], ['/', '/']]) {
    if (answer(`https://${host}${asked}`) !== `https://${host}${sent}`) found.push(`https://${host}${asked} is sent to ${answer(`https://${host}${asked}`)}`);
  }

  for (const name of ['pgdb', 'redis', 'rabbitmq', 'minio']) {
    const set = objects.find(o => o.kind === 'StatefulSet' && o.metadata.name === `plane-${name}-wl`);
    const classes = (set?.spec.volumeClaimTemplates ?? []).map(t => t.spec.storageClassName);
    if (classes.length !== 1 || classes[0] !== platform.storageClass) found.push(`${name} keeps its data on ${classes.join(', ') || 'nothing'}`);
  }
  for (const [name, pin] of [['pgdb', 'plane-postgres'], ['redis', 'plane-redis'], ['rabbitmq', 'plane-rabbitmq']]) {
    const set = objects.find(o => o.kind === 'StatefulSet' && o.metadata.name === `plane-${name}-wl`);
    const wanted = `${pins[pin].upstream.image.replace(/^library\//, '')}:${pins[pin].version}`;
    const images = (set?.spec.template.spec.containers ?? []).map(c => c.image);
    if (images.length !== 1 || images[0] !== wanted) found.push(`${name} runs ${images.join(', ') || 'nothing'}, not ${wanted} of versions.yaml`);
  }
  const silo = pins['plane-silo'];
  const store = objects.find(o => o.kind === 'StatefulSet' && o.metadata.name === 'plane-minio-wl')?.spec.template.spec.containers.map(c => c.image);
  if (JSON.stringify(store) !== JSON.stringify([`docker.io/${silo.upstream.image}:${silo.version}`])) found.push(`minio runs ${store?.join(', ') ?? 'nothing'}, not docker.io/${silo.upstream.image}:${silo.version} of versions.yaml`);
  const mc = pins['plane-mc'];
  const bucket = objects.find(o => o.kind === 'Job' && BUCKET_JOB.test(o.metadata.name))?.spec.template.spec.containers.map(c => c.image);
  if (JSON.stringify(bucket) !== JSON.stringify([`docker.io/${mc.upstream.image}:${mc.version}`])) found.push(`the bucket Job runs ${bucket?.join(', ') ?? 'nothing'}, not docker.io/${mc.upstream.image}:${mc.version} of versions.yaml`);

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

  // The worker runs `celery -A plane worker` with no --concurrency, so Celery forks one process per core
  // of the node (32 on the master) unless CELERY_WORKER_CONCURRENCY names a number. Each process holds
  // Plane's Django app (the beat worker, the same app, holds 147Mi on the master), so the limit carries
  // the main process and every child at 200Mi each.
  const worker = workloads.find(o => o.metadata.name === 'plane-worker-wl')?.spec.template.spec.containers[0];
  const workerEnv = Object.assign({}, ...(worker?.envFrom ?? []).map(source => source.configMapRef ?
    objects.find(o => o.kind === 'ConfigMap' && o.metadata.name === source.configMapRef.name)?.data :
    external.find(o => o.spec.target.name === source.secretRef?.name)?.spec.target.template?.data));
  const concurrency = workerEnv.CELERY_WORKER_CONCURRENCY;
  const memory = Number(/^(\d+)Mi$/.exec(worker?.resources.limits.memory ?? '')?.[1]);
  if (!/^[1-4]$/.test(concurrency ?? '')) found.push(`the worker forks ${concurrency ?? 'one process per core of the node'}, not a fixed few`);
  else if (!(memory >= (Number(concurrency) + 1) * 200)) found.push(`the worker's ${worker?.resources.limits.memory} does not hold ${concurrency} children and their parent`);
  // At concurrency 2 the worker's working set stood flat at 260.1Mi (p95 of 5.5 h on the master,
  // 2026-10-15); the chart's 50Mi request lets the scheduler place it where that
  // does not fit. The request is the measured p95, rounded up, and never above the limit.
  const request = Number(/^(\d+)Mi$/.exec(worker?.resources.requests.memory ?? '')?.[1]);
  if (!(request >= 261 && request <= memory)) found.push(`the worker requests ${worker?.resources.requests.memory}, not its measured 261Mi up to its limit`);

  // The addresses the app is handed name the chart's own Services in the app's own namespace.
  const services = new Set(objects.filter(o => o.kind === 'Service').map(o => o.metadata.name));
  const env = external.find(o => o.metadata.name === 'plane-app-env')?.spec.target.template?.data ?? {};
  for (const [key, url] of Object.entries(env).filter(([key]) => key.endsWith('_URL'))) {
    const host = /^[a-z]+:\/\/(?:[^@/]*@)?([^:/]+)/.exec(url)?.[1] ?? '';
    const [service, namespace] = host.split('.');
    if (!services.has(service) || namespace !== app.namespace) found.push(`${key} names ${host}, not a Service of the chart in ${app.namespace}`);
  }
  const vars = objects.find(o => o.kind === 'ConfigMap' && o.metadata.name === 'plane-app-vars')?.data ?? {};
  if (vars.WEB_URL !== `https://${host}`) found.push(`Plane is told it stands at ${vars.WEB_URL}`);
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

test('PLANTED DEFECT: an ungated page, a second ungated path, a public default, a volume off the platform class, a missing outpost binding, the chart\'s own /god-mode, a redirect to a port, a worker forking per core, a limit too small for it and an image off its pin are found', () => {
  const planted = {
    'the pages without the gate': ['--set-string', 'plane-ce.ingress.ingress_annotations.traefik\\.ingress\\.kubernetes\\.io/router\\.middlewares='],
    'the public default keys': ['--set', 'plane-ce.external_secrets.app_keys_existingSecret=', '--set', 'plane-ce.env.requireExplicitSecrets=false'],
    'the public database password': ['--set', 'plane-ce.external_secrets.app_env_existingSecret='],
    'a volume on no named class': ['--set', 'plane-ce.minio.storageClass='],
    'the chart\'s own database image': ['--set', 'plane-ce.postgres.image=postgres:15.7-alpine'],
    'the chart\'s own queue image': ['--set', 'plane-ce.rabbitmq.image=rabbitmq:3.13.6-management-alpine'],
    'the chart\'s own cache image': ['--set', 'plane-ce.redis.image=valkey/valkey:7.2.11-alpine'],
    'a database one release behind its pin': ['--set', 'plane-ce.postgres.image=postgres:18.5-alpine'],
    'a queue on another repository': ['--set', 'plane-ce.rabbitmq.image=bitnami/rabbitmq:4.3.6-management-alpine'],
    'the chart\'s own object store image': ['--set', 'plane-ce.minio.image=docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z'],
    'the chart\'s own bucket client image': ['--set', 'plane-ce.minio.image_mc=docker.io/pgsty/mc:RELEASE.2026-09-16T00-00-00Z'],
  };
  for (const [name, args] of Object.entries(planted)) {
    assert.notDeepEqual(renderFindings(renderChart('plane', args)), [], name);
  }
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.postgres.image=postgres:15.7-alpine'])),
    ['pgdb runs postgres:15.7-alpine, not postgres:18.6-alpine of versions.yaml']);
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.minio.image=docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z'])),
    ['minio runs docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z, not docker.io/pgsty/silo:RELEASE.2026-10-18T00-00-00Z of versions.yaml']);
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.minio.image_mc=docker.io/pgsty/mc:RELEASE.2026-09-16T00-00-00Z'])),
    ['the bucket Job runs docker.io/pgsty/mc:RELEASE.2026-09-16T00-00-00Z, not docker.io/pgsty/mc:RELEASE.2026-10-18T00-00-00Z of versions.yaml']);
  const widened = renderChart('plane');
  widened.find(o => o.metadata?.name === 'plane-api-v1').spec.rules[0].http.paths.push({path: '/api', pathType: 'Prefix', backend: {service: {name: 'plane-api', port: {number: 8000}}}});
  assert.deepEqual(renderFindings(widened), ['plane-api-v1 serves /api/v1, /api without the forward auth']);
  const plain = renderChart('plane', ['--set-string', `plane-ce.ingress.ingress_annotations.traefik\\.ingress\\.kubernetes\\.io/router\\.middlewares=${FORWARD_AUTH}`])
    .filter(o => o.kind !== 'Middleware');
  assert.deepEqual(renderFindings(plain), [`/god-mode passes ${FORWARD_AUTH}, not the forward auth and then the trailing-slash redirect`,
    'https://plane.example.com/god-mode is sent to https://plane.example.com/god-mode', 'https://plane.example.com/god-mode?next=1 is sent to https://plane.example.com/god-mode?next=1']);
  const forking = renderChart('plane');
  delete forking.find(o => o.metadata.name === 'plane-app-env').spec.target.template.data.CELERY_WORKER_CONCURRENCY;
  assert.deepEqual(renderFindings(forking), ['the worker forks one process per core of the node, not a fixed few']);
  assert.deepEqual(renderFindings(renderChart('plane', ['--set-string', 'externalsecret-app-env.externalSecret.template.data.CELERY_WORKER_CONCURRENCY=32'])),
    ['the worker forks 32, not a fixed few']);
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.worker.memoryLimit=500Mi'])),
    ["the worker's 500Mi does not hold 2 children and their parent"]);
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.worker.memoryRequest=50Mi'])),
    ['the worker requests 50Mi, not its measured 261Mi up to its limit']);
  const ported = renderChart('plane');
  ported.find(o => o.kind === 'Middleware').spec.redirectRegex.replacement = 'https://${1}:3000/god-mode/${2}';
  assert.deepEqual(renderFindings(ported), ['https://plane.example.com/god-mode is sent to https://plane.example.com:3000/god-mode/',
    'https://plane.example.com/god-mode?next=1 is sent to https://plane.example.com:3000/god-mode/?next=1']);
  assert.notDeepEqual(blueprintFindings(proxyText, bindingsText.replace(/\n\s*- !Find \[authentik_providers_proxy.proxyprovider, \[name, Plane\]\]/g, '')), []);
});

test('PLANTED INNOCENT: more replicas of the web app and a larger upload limit change nothing the rules hold', () => {
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.web.replicas=2', '--set', 'plane-ce.env.doc_upload_size_limit=10485760'])), []);
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.worker.memoryRequest=300Mi', '--set', 'plane-ce.worker.cpuRequest=100m'])), []);
  assert.deepEqual(renderFindings(renderChart('plane', ['--set', 'plane-ce.minio.init_image=busybox:1.37', '--set', 'plane-ce.minio.image_mc=docker.io/pgsty/mc:RELEASE.2026-10-18T00-00-00Z'])), []);
});

// plane-ce stamps the render time into the pod template of its seven Deployments and of its migration
// Job. A render of a later revision may change nothing a sync writes: the Job's pod template is
// immutable, so one changed field fails every sync of plane, and the RollingSync waits behind it.
const [first, second] = renderTwice('plane');
const STAMPED = ['admin', 'api', 'beat-worker', 'live', 'space', 'web', 'worker'].map(name => `Deployment/plane-${name}-wl`)
  .concat(`Job/${first.find(o => o.kind === 'Job' && MIGRATION_JOB.test(o.metadata.name)).metadata.name}`)
  .map(object => `${object} /spec/template/metadata/annotations/timestamp`);

test('a render a second later changes nothing a sync of plane writes', () => {
  assert.deepEqual(driftFindings(first, second, applicationOf(app)), []);
});

test('PLANTED DEFECT: the plain chart, and the timestamp ignored without RespectIgnoreDifferences, change the migration Job and the seven Deployments', () => {
  const {ignoreDifferences, respectIgnoreDifferences, ...plain} = app;
  assert.deepEqual(driftFindings(first, second, applicationOf(plain)), STAMPED);
  const {respectIgnoreDifferences: dropped, ...unrespected} = app;
  assert.deepEqual(driftFindings(first, second, applicationOf(unrespected)), STAMPED);
});

test('PLANTED INNOCENT: more replicas of the web app, rendered twice, change nothing a sync writes', () => {
  assert.deepEqual(driftFindings(...renderTwice('plane', ['--set', 'plane-ce.web.replicas=2']), applicationOf(app)), []);
});

// Argo CD renders plane-ce as Helm release revision 1 every time, so a Job named by the revision keeps its name
// and its immutable pod template for good: a new Plane version never migrates, and a new bucket client never
// runs. The vendored chart names the Jobs by the images they run instead, and a new image is a new Job.
const jobName = (objects, pattern) => objects.find(o => o.kind === 'Job' && pattern.test(o.metadata.name))?.metadata.name;
const plain = renderChart('plane');

/** Every Job of the release that keeps its name when the image it runs changes, or is not named by a hash at all. */
function unmovedJobs(folder) {
  const base = renderChart('plane', [], folder);
  const moved = (pattern, ...args) => {
    const before = jobName(base, pattern), after = jobName(renderChart('plane', args, folder), pattern);
    return before !== undefined && after !== undefined && before !== after;
  };
  const found = [];
  if (!moved(MIGRATION_JOB, '--set', 'plane-ce.planeVersion=v0.0.0-planted')) found.push('the migration Job keeps its name when the Plane version moves');
  if (!moved(MIGRATION_JOB, '--set', 'plane-ce.api.image=example.com/plane-backend')) found.push('the migration Job keeps its name when its image moves');
  if (!moved(BUCKET_JOB, '--set', 'plane-ce.minio.image_mc=example.com/mc:planted')) found.push('the bucket Job keeps its name when the bucket client moves');
  if (!moved(BUCKET_JOB, '--set', 'plane-ce.minio.init_image=example.com/busybox:planted')) found.push('the bucket Job keeps its name when its init image moves');
  if (!moved(BUCKET_JOB, '--set', 'plane-ce.minio.image=example.com/silo:planted')) found.push('the bucket Job keeps its name when the object store moves');
  return found;
}

/** The chart folder with the vendored patch reversed: plane-ce as upstream ships it. */
function upstreamChart() {
  const root = mkdtempSync(join(tmpdir(), 'plane-upstream-'));
  cpSync('clusters/inventories/plane', join(root, 'clusters/inventories/plane'), {recursive: true});
  cpSync('clusters/charts', join(root, 'clusters/charts'), {recursive: true});
  execFileSync('patch', ['-R', '-p1', '-F0', '-s', '--no-backup-if-mismatch', '-i', join(process.cwd(), 'clusters/inventories/plane/vendor/plane-ce-1.8.5.patch')],
    {cwd: join(root, 'clusters/inventories/plane/charts')});
  return {root, folder: join(root, 'clusters/inventories/plane')};
}

test('the migration Job and the bucket Job are named by a hash of their images, and a new image gives each a new name', () => {
  assert.match(jobName(plain, MIGRATION_JOB) ?? '', MIGRATION_JOB);
  assert.match(jobName(plain, BUCKET_JOB) ?? '', BUCKET_JOB);
  assert.deepEqual(unmovedJobs(undefined), []);
});

test('PLANTED DEFECT: the chart as upstream ships it names both Jobs by the release revision, and both keep their name when their image moves', () => {
  const {root, folder} = upstreamChart();
  try {
    const upstream = renderChart('plane', [], folder);
    assert.deepEqual(['plane-api-migrate-1', 'plane-minio-bucket-1'].map(name => upstream.some(o => o.kind === 'Job' && o.metadata.name === name)), [true, true]);
    assert.deepEqual(unmovedJobs(folder), ['the migration Job keeps its name when the Plane version moves', 'the migration Job keeps its name when its image moves',
      'the bucket Job keeps its name when the bucket client moves', 'the bucket Job keeps its name when its init image moves',
      'the bucket Job keeps its name when the object store moves']);
  } finally {
    rmSync(root, {recursive: true, force: true});
  }
});

test('PLANTED INNOCENT: more replicas of the web app and a larger worker request keep the names of both Jobs', () => {
  for (const args of [['--set', 'plane-ce.web.replicas=2'], ['--set', 'plane-ce.worker.memoryRequest=300Mi'], ['--set', 'plane-ce.env.doc_upload_size_limit=10485760']]) {
    const changed = renderChart('plane', args);
    assert.equal(jobName(changed, MIGRATION_JOB), jobName(plain, MIGRATION_JOB), args.join(' '));
    assert.equal(jobName(changed, BUCKET_JOB), jobName(plain, BUCKET_JOB), args.join(' '));
  }
});
