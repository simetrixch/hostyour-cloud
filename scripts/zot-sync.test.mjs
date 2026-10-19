import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';
import {renderChart} from './render-chart.mjs';

// The registry's zot pulls a Docker Hub image through on a miss (extensions.sync, onDemand). A repository the
// platform publishes itself must never reach Docker Hub: Hub answers a name it does not know with
// "unauthorized", zot turns that into a 503, and the publish step that asks whether a version exists refuses on
// it. A repository the sync content filters out is a plain local 404 (scripts/zot-sync-eval says which
// repositories a registry asks).

const owned = [
  'flat-build-name',
  'npm/digitaplatform/exchange-rates',
  'simetrixch/manager',
  'simetrixch/ghcr.io/project-zot/zot-linux-amd64',
  'simetrixch/s', 'simetrixch/simetrixc', 'simetrixch/simetrixchx',
];
const hub = ['library/redis', 'grafana/alloy', 'cdkbot/hostpath-provisioner', 'calico/node', 'sim/redis', 'simetrixc/redis', 'simetrixcx/redis', 'simetrixhh/redis', 'simetrixchx/redis'];

const syncRegistries = objects => JSON.parse(objects.find(o => o.kind === 'ConfigMap' && o.metadata.name === 'zot-config')
  .data['config.json']).extensions.sync.registries;
const asked = (registries, repositories) => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/zot-sync-eval',
  input: JSON.stringify({registries, repositories}), encoding: 'utf8'}));
const reached = (registries, repositories) => {
  const answer = asked(registries, repositories);
  return repositories.filter(repo => answer[repo].length > 0);
};

test('on a miss zot asks Docker Hub for a Docker Hub image and for nothing the platform publishes', () => {
  const registries = syncRegistries(renderChart('registry'));
  assert.deepEqual(reached(registries, [...owned, ...hub]), hub);
});

test('PLANTED DEFECT: a sync registry without content asks Docker Hub for a repository of the platform too', () => {
  const planted = syncRegistries(renderChart('registry')).map(({content, ...registry}) => registry);
  assert.deepEqual(reached(planted, owned), owned);
});

test('PLANTED INNOCENT: a registry that names the Docker Hub namespaces keeps the platform out and the images in', () => {
  const registries = [{urls: ['https://registry-1.docker.io'], onDemand: true, content: [{prefix: '{library,grafana}/*'}]}];
  assert.deepEqual(reached(registries, [...owned, 'library/redis', 'grafana/alloy']), ['library/redis', 'grafana/alloy']);
});
