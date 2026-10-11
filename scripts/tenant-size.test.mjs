import assert from 'node:assert/strict';
import test from 'node:test';
import {chartTenants, paramSet, patch, registration, render} from './tenant-appset-fixture.mjs';

const tenants = [
  {guid: 'aaaaaaaaaaaa', stage: 'prod', size: 'small', body: registration(['charts/engine', 'charts/web'], {size: 'small'})},
  {guid: 'bbbbbbbbbbbb', stage: 'test', size: '', body: registration(['charts/engine', 'charts/web'], {})},
  {guid: 'cccccccccccc', stage: 'dev', size: 'xsmall', body: registration(['charts/engine'], {size: 'xsmall'})},
];
const paramSets = tenants.map(({guid, stage, body}) => paramSet(guid, stage, body));

test('every registration renders, and each chart is handed its tenant stage size word, or "" without one', () => {
  const results = render(patch, paramSets);
  assert.equal(results.length, paramSets.length);
  results.forEach((result, at) => {
    assert.equal(result.error, undefined, `${paramSets[at].values.guid}: ${result.error}`);
    const handed = chartTenants(result.output).map(tenant => tenant.size);
    assert.deepEqual(handed, tenants[at].body.sources.map(() => tenants[at].size));
  });
});

// One failed parameter set is enough for the controller to create, update and delete no Application
// of the whole set (argo-cd v3.4.5 applicationset/controllers/template/template.go:37-61 and
// applicationset_controller.go:201-216), which is why the first test admits no error at all.
test('a bare read of size fails the registration without it', () => {
  const bare = patch.replace('dig "size" "" $', '$.size');
  assert.notEqual(bare, patch);
  const results = render(bare, paramSets);
  results.forEach((result, at) => {
    if (tenants[at].size) assert.equal(result.error, undefined);
    else assert.match(result.error, /map has no entry for key "size"/);
  });
});
