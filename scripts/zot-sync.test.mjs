import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';
import {renderChart} from './render-chart.mjs';

// The registry's zot pulls a Docker Hub image through on a miss (extensions.sync, onDemand). A repository the
// platform publishes itself must never reach Docker Hub: Hub answers a name it does not know with
// "unauthorized", zot turns that into a 503, and the publish step that asks whether a version exists refuses on
// it. A repository the sync content filters out is a plain local 404 (scripts/zot-sync-eval says which
// repositories a registry asks). The content lists the Docker Hub repositories by name, because the release
// binaries' <owner>/<repository> has the shape of a Hub name.

const owned = [
  'flat-build-name',
  'npm/digitaplatform/exchange-rates',
  'simetrixch/manager',
  'simetrixch/ansiwise-cli',
  'simetrixch/ghcr.io/project-zot/zot-linux-amd64',
  'digitaplatform/digita-platform',
  'digitaplatform/digita-plugins-free',
];
const hubOffTheList = ['bitnami/redis', 'maptiler/tileserver-gl', 'grafana/mimir'];

const syncRegistries = objects => JSON.parse(objects.find(o => o.kind === 'ConfigMap' && o.metadata.name === 'zot-config')
  .data['config.json']).extensions.sync.registries;
const asked = (registries, repositories) => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/zot-sync-eval',
  input: JSON.stringify({registries, repositories}), encoding: 'utf8'}));
const reached = (registries, repositories) => {
  const answer = asked(registries, repositories);
  return repositories.filter(repo => answer[repo].length > 0);
};
const unreached = (registries, repositories) => repositories.filter(repo => !reached(registries, [repo]).length);

// Every Docker Hub repository an `image:` of the rendered tree names (scripts/list-mirror-images.sh --hub).
const treeHubRepositories = () => [...new Set(execFileSync('bash', ['scripts/list-mirror-images.sh', '--hub'], {encoding: 'utf8'})
  .split('\n').filter(Boolean).map(line => line.split(' ')[0]))];

test('on a miss zot asks Docker Hub for every Docker Hub image the tree names', () => {
  const repositories = treeHubRepositories();
  assert.ok(repositories.length > 15, `the tree names ${repositories.length} Docker Hub repositories, which is too few to be the whole list`);
  assert.deepEqual(unreached(syncRegistries(renderChart('registry')), repositories), []);
});

test('on a miss zot asks Docker Hub for an official image and for a named image, and for nothing the platform publishes', () => {
  const registries = syncRegistries(renderChart('registry'));
  assert.deepEqual(reached(registries, ['library/redis', 'library/node', 'grafana/alloy', 'valkey/valkey']),
    ['library/redis', 'library/node', 'grafana/alloy', 'valkey/valkey']);
  assert.deepEqual(reached(registries, owned), []);
});

test('a Docker Hub image off the list is a plain 404 (the intended edge)', () => {
  assert.deepEqual(reached(syncRegistries(renderChart('registry')), hubOffTheList), []);
});

test('PLANTED DEFECT: a sync registry without content asks Docker Hub for a repository of the platform too', () => {
  const planted = syncRegistries(renderChart('registry')).map(({content, ...registry}) => registry);
  assert.deepEqual(reached(planted, owned), owned);
});

test('PLANTED DEFECT: any <namespace>/<name> in the content asks Docker Hub for the release binaries of a consumer', () => {
  const planted = [{urls: ['https://registry-1.docker.io'], onDemand: true, content: [{prefix: 'library/**'}, {prefix: '*/*'}]}];
  assert.deepEqual(reached(planted, owned), ['simetrixch/manager', 'simetrixch/ansiwise-cli', 'digitaplatform/digita-platform', 'digitaplatform/digita-plugins-free']);
});

test('PLANTED DEFECT: a content without a Docker Hub image of the tree leaves that image unlisted', () => {
  const registries = syncRegistries(renderChart('registry'));
  const planted = registries.map(registry => ({...registry, content: registry.content.filter(({prefix}) => prefix !== 'grafana/alloy')}));
  assert.deepEqual(unreached(planted, ['library/redis', 'grafana/alloy']), ['grafana/alloy']);
});

test('PLANTED INNOCENT: a registry that names its Docker Hub repositories keeps the platform out and the images in', () => {
  const registries = [{urls: ['https://registry-1.docker.io'], onDemand: true, content: [{prefix: 'library/**'}, {prefix: 'grafana/alloy'}]}];
  assert.deepEqual(reached(registries, [...owned, 'library/redis', 'grafana/alloy']), ['library/redis', 'grafana/alloy']);
});
