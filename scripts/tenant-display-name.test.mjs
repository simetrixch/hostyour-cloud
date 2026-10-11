import assert from 'node:assert/strict';
import test from 'node:test';
import {chartTenants, paramSet, patch, registration, render} from './tenant-appset-fixture.mjs';

// A registration written before the field existed carries no displayName at all. The name with an
// apostrophe and an ampersand is the planted innocent: it must reach the chart unchanged.
const tenants = [
  {guid: 'aaaaaaaaaaaa', stage: 'prod', name: "Müller & O'Brien", body: registration(['charts/engine', 'charts/web'], {displayName: "Müller & O'Brien"})},
  {guid: 'bbbbbbbbbbbb', stage: 'test', name: '', body: registration(['charts/engine', 'charts/web'], {})},
];
const paramSets = tenants.map(({guid, stage, body}) => paramSet(guid, stage, body));

test('every chart is handed its tenant display name, or "" where the registration has none', () => {
  const results = render(patch, paramSets);
  assert.equal(results.length, paramSets.length);
  results.forEach((result, at) => {
    assert.equal(result.error, undefined, `${paramSets[at].values.guid}: ${result.error}`);
    const handed = chartTenants(result.output).map(tenant => tenant.displayName);
    assert.deepEqual(handed, tenants[at].body.sources.map(() => tenants[at].name));
  });
});

// One failed parameter set is enough for the controller to create, update and delete no Application
// of the whole set, so a registration without the field must render as well as one with it.
test('a bare read of displayName fails the registration without it', () => {
  const bare = patch.replace('dig "displayName" "" $', '$.displayName');
  assert.notEqual(bare, patch);
  const results = render(bare, paramSets);
  results.forEach((result, at) => {
    if (tenants[at].name) assert.equal(result.error, undefined);
    else assert.match(result.error, /map has no entry for key "displayName"/);
  });
});
