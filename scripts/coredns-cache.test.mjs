import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const render = serveStale => execFileSync('helm', [
  'template', 'coredns', 'clusters/inventories/coredns', '--namespace', 'kube-system',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
  '-f', 'clusters/inventories/coredns/values-common.yaml',
  '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml',
  '-f', 'scripts/standin/registration.yaml',
  ...(serveStale ? ['--set', 'cache.serveStale=true'] : []),
], {encoding: 'utf8'});

const readCorefile = rendered => JSON.parse(execFileSync('yq', [
  '-o=json', 'select(.kind == "ConfigMap") | .data.Corefile', '-',
], {input: rendered, encoding: 'utf8'}));

// Any other line in the block changes what is cached: a `success ... 30` caps every answer at 30s
// again, and a missing `disable` serves stale addresses of the cluster's own Services and pods.
const CACHE_BLOCK = [
  'disable success cluster.local in-addr.arpa ip6.arpa',
  'disable denial cluster.local in-addr.arpa ip6.arpa',
  'denial 9984 30',
  'serve_stale 1h immediate',
];

const checkCacheBlock = (corefile, serveStale) => {
  const lines = corefile.split('\n').map(line => line.trim());
  if (serveStale) {
    assert.ok(!lines.includes('cache 30'), 'Corefile must not contain a line that is "cache 30"');
    const match = corefile.match(/^[ \t]*(cache[^\n{]*)\{([^}]*)\}/m);
    assert.ok(match, 'Corefile must contain a cache { block');
    const [, cacheHeader, blockBody] = match;
    assert.equal(cacheHeader.trim(), 'cache', `cache line carries TTL argument: ${cacheHeader.trim()}`);
    const blockLines = blockBody.split('\n').map(line => line.trim()).filter(Boolean);
    assert.deepEqual(blockLines, CACHE_BLOCK, 'the cache block holds exactly the expected lines');
  } else {
    assert.ok(lines.includes('cache 30'), 'Corefile must contain a line that is exactly cache 30');
    assert.ok(!corefile.includes('serve_stale'), 'Corefile must not contain serve_stale');
  }
};

const defaultCorefile = readCorefile(render(false));
const staleCorefile = readCorefile(render(true));

test('both renders pass checkCacheBlock', () => {
  checkCacheBlock(defaultCorefile, false);
  checkCacheBlock(staleCorefile, true);
});

test('planted defects in the serveStale render throw while innocent extra indentation passes', () => {
  const defectBlockReplaced = staleCorefile.replace(/cache\s*\{[^}]*\}/, 'cache 30');
  assert.throws(() => checkCacheBlock(defectBlockReplaced, true));

  const defectNoDenial = staleCorefile.replace(/^[ \t]*denial 9984 30\r?\n/m, '');
  assert.throws(() => checkCacheBlock(defectNoDenial, true));

  const defectTtlArg = staleCorefile.replace('cache {', 'cache 3600 {');
  assert.throws(() => checkCacheBlock(defectTtlArg, true));

  const defectNoServeStale = staleCorefile.replace(/^[ \t]*serve_stale 1h immediate\r?\n/m, '');
  assert.throws(() => checkCacheBlock(defectNoServeStale, true));

  const defectSuccessCap = staleCorefile.replace('denial 9984 30', 'denial 9984 30\n      success 9984 30');
  assert.throws(() => checkCacheBlock(defectSuccessCap, true));

  for (const zoneLine of CACHE_BLOCK.slice(0, 2)) {
    const defectClusterCached = staleCorefile.replace(`${zoneLine}\n`, '');
    assert.notEqual(defectClusterCached, staleCorefile);
    assert.throws(() => checkCacheBlock(defectClusterCached, true));
  }

  const innocentIndent = staleCorefile
    .replace('denial 9984 30', '    denial 9984 30')
    .replace('serve_stale 1h immediate', '    serve_stale 1h immediate');
  checkCacheBlock(innocentIndent, true);
});

test('the false render planted with a serve_stale 1h immediate line must throw', () => {
  const defectFalseWithServeStale = defaultCorefile.replace('cache 30', 'cache 30\n    serve_stale 1h immediate');
  assert.throws(() => checkCacheBlock(defectFalseWithServeStale, false));
});
