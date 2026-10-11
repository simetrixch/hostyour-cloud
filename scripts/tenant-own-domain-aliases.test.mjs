import assert from 'node:assert/strict';
import test from 'node:test';
import {chartTenants, paramSet, patch, registration, render} from './tenant-appset-fixture.mjs';

// The Manager writes the key only while the list holds a domain.
const tenants = [
  {guid: 'aaaaaaaaaaaa', stage: 'prod', aliases: ['old.example.test', 'older.example.test'],
    body: registration(['charts/engine', 'charts/web'], {ownDomain: 'acme.example.test', ownDomainRedirects: ['www.acme.example.test'],
      ownDomainAliases: ['old.example.test', 'older.example.test']})},
  {guid: 'bbbbbbbbbbbb', stage: 'test', aliases: [], body: registration(['charts/engine', 'charts/web'], {ownDomain: 'acme.example.test', ownDomainRedirects: ['www.acme.example.test']})},
];
const paramSets = tenants.map(({guid, stage, body}) => paramSet(guid, stage, body));

test('every chart is handed its tenant own domain aliases, or [] where the registration has none', () => {
  const results = render(patch, paramSets);
  assert.equal(results.length, paramSets.length);
  results.forEach((result, at) => {
    assert.equal(result.error, undefined, `${paramSets[at].values.guid}: ${result.error}`);
    const handed = chartTenants(result.output).map(tenant => tenant.ownDomainAliases);
    assert.deepEqual(handed, tenants[at].body.sources.map(() => tenants[at].aliases));
  });
});

// One failed parameter set is enough for the controller to create, update and delete no Application
// of the whole set, which is why the first test admits no error at all.
test('a bare read of ownDomainAliases fails the registration without it', () => {
  const bare = patch.replace('dig "ownDomainAliases" (list) $', '$.ownDomainAliases');
  assert.notEqual(bare, patch);
  const results = render(bare, paramSets);
  results.forEach((result, at) => {
    if (tenants[at].aliases.length) assert.equal(result.error, undefined);
    else assert.match(result.error, /map has no entry for key "ownDomainAliases"/);
  });
});
