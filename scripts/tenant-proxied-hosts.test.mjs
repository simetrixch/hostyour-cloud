import assert from 'node:assert/strict';
import test from 'node:test';
import {chartTenants, paramSet, patch, registration, render} from './tenant-appset-fixture.mjs';

// The Manager writes the key only while the list holds a host, and the list holds the own domain or nothing.
const tenants = [
  {guid: 'aaaaaaaaaaaa', stage: 'prod', proxied: ['acme.example.test'],
    body: registration(['charts/engine', 'charts/web'], {ownDomain: 'acme.example.test', ownDomainRedirects: ['www.acme.example.test'],
      proxiedHosts: ['acme.example.test']})},
  {guid: 'bbbbbbbbbbbb', stage: 'test', proxied: [], body: registration(['charts/engine', 'charts/web'], {ownDomain: 'acme.example.test', ownDomainRedirects: ['www.acme.example.test']})},
];
const paramSets = tenants.map(({guid, stage, body}) => paramSet(guid, stage, body));

test('every chart is handed its tenant proxied hosts, or [] where the registration has none', () => {
  const results = render(patch, paramSets);
  assert.equal(results.length, paramSets.length);
  results.forEach((result, at) => {
    assert.equal(result.error, undefined, `${paramSets[at].values.guid}: ${result.error}`);
    const handed = chartTenants(result.output).map(tenant => tenant.proxiedHosts);
    assert.deepEqual(handed, tenants[at].body.sources.map(() => tenants[at].proxied));
  });
});

// One failed parameter set is enough for the controller to create, update and delete no Application
// of the whole set, which is why the first test admits no error at all.
test('PLANTED DEFECT: a bare read of proxiedHosts fails the registration without it', () => {
  const bare = patch.replace('dig "proxiedHosts" (list) $', '$.proxiedHosts');
  assert.notEqual(bare, patch);
  const results = render(bare, paramSets);
  results.forEach((result, at) => {
    if (tenants[at].proxied.length) assert.equal(result.error, undefined);
    else assert.match(result.error, /map has no entry for key "proxiedHosts"/);
  });
});
