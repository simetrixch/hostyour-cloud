import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';

// Every cluster answers a plain-http request that no route claims with a permanent redirect to
// https, host, path and query kept. cert-manager's HTTP-01 solver keeps its own route on `web`
// (a host and a path), and every route that serves http today keeps it, so the catch-all must
// stand below all of them: priority 1, where Traefik's default is the length of the rule.
const chart = 'clusters/inventories/https-redirect';
const docs = input => JSON.parse(execFileSync('yq', ['ea', '-o=json', '[.]', '-'], {input, encoding: 'utf8'})).filter(Boolean);
const rendered = docs(execFileSync('helm', ['template', 'https-redirect', chart, '--namespace', 'ingress'], {encoding: 'utf8'}));

/** Every way the objects miss the lowest, permanent, https-only catch-all on `web`. */
function findings(objects) {
  const found = [];
  const routes = objects.filter(o => o.kind === 'IngressRoute');
  if (routes.length !== 1) found.push(`${routes.length} IngressRoutes`);
  for (const route of routes) {
    if (JSON.stringify(route.spec.entryPoints) !== '["web"]') found.push(`entryPoints ${JSON.stringify(route.spec.entryPoints)}`);
    if (route.spec.tls !== undefined) found.push('tls on a plain-http route');
    for (const rule of route.spec.routes) {
      if (rule.match !== 'PathPrefix(`/`)') found.push(`match ${rule.match}`);
      if (rule.priority !== 1) found.push(`priority ${rule.priority}`);
      if ((rule.middlewares ?? []).length !== 1) found.push(`${(rule.middlewares ?? []).length} middlewares`);
      for (const {name} of rule.middlewares ?? []) {
        const scheme = objects.find(o => o.kind === 'Middleware' && o.metadata.name === name)?.spec.redirectScheme;
        if (!scheme) found.push(`middleware ${name} is no redirectScheme`);
        else {
          if (scheme.scheme !== 'https') found.push(`scheme ${scheme.scheme}`);
          if (scheme.permanent !== true) found.push(`permanent ${scheme.permanent}`);
          if (scheme.port !== undefined) found.push(`port ${scheme.port}`);
        }
      }
    }
  }
  return found;
}

test('the chart renders one lowest, permanent, https-only catch-all on web', () => {
  assert.deepEqual(findings(rendered), []);
});

test('PLANTED DEFECT: each way out of the catch-all is found, and the render itself is not', () => {
  const route = objects => objects.find(o => o.kind === 'IngressRoute').spec;
  const redirect = objects => objects.find(o => o.kind === 'Middleware').spec.redirectScheme;
  const planted = {
    'bound to websecure': os => { route(os).entryPoints = ['websecure']; },
    'bound to both entrypoints': os => { route(os).entryPoints = ['web', 'websecure']; },
    'above the solver': os => { route(os).routes[0].priority = 100; },
    'at the rule-length default': os => { delete route(os).routes[0].priority; },
    'one host only': os => { route(os).routes[0].match = 'Host(`example.invalid`)'; },
    'temporary': os => { redirect(os).permanent = false; },
    'to http': os => { redirect(os).scheme = 'http'; },
    'to a fixed port': os => { redirect(os).port = '8443'; },
  };
  for (const [name, plant] of Object.entries(planted)) {
    const objects = structuredClone(rendered);
    plant(objects);
    assert.notDeepEqual(findings(objects), [], name);
  }
  assert.deepEqual(findings(structuredClone(rendered)), [], 'the planted innocent: the render as it is');
});

test('it reaches every cluster, in the namespace of the ingress controller, through a project that admits it', () => {
  const app = docs(readFileSync(`${chart}/app.yaml`, 'utf8'))[0];
  assert.equal(app.runsOn, 'every-cluster');
  assert.equal(app.namespace, 'ingress');
  assert.equal(app.createNamespace, 'false');
  const projects = docs(readFileSync('clusters/argocd/files/projects.yaml', 'utf8'));
  const project = projects.find(p => p.kind === 'AppProject' && p.metadata.name === app.project);
  assert.ok(project, app.project);
  assert.ok(project.spec.destinations.some(d => d.name === '__CLUSTER_NAME__' && d.namespace === 'ingress'), 'a destination for ingress');
});
