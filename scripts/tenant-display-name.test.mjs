import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

const yaml = (expression, input) => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input, encoding: 'utf8'}));
const appset = JSON.parse(execFileSync('yq', ['-o=json', '.spec', 'clusters/argocd/files/tenants-appset.yaml'], {encoding: 'utf8'}));
const patch = appset.templatePatch;

// The template patch rendered once per parameter set, as the ApplicationSet controller renders it
// (scripts/appset-render). Each answer is {output} or {error}.
const render = (template, paramSets) => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
  input: JSON.stringify({template, options: appset.goTemplateOptions, params: paramSets}), encoding: 'utf8'}));

// A registration with the fields the standing one carries (registrations/<guid>/prod.yaml on the books branch).
const registration = (members, extra) => ({
  cluster: 'apps1', subdomain: 'acme', apps: [], identityProvider: {}, routing: 'path', ownDomain: '',
  ownDomainRedirects: [], approvedTags: {}, senderDomain: '', seedUsers: false, demo: false, resetNonce: '',
  suspended: false, quiesced: false, appsRepo: '', appsImage: '', appsImageTag: '', size: 'small',
  quota: {requestsCpu: '200m', requestsMemory: '1152Mi', limitsCpu: '4', limitsMemory: '4Gi', pods: '4', persistentVolumeClaims: '1'},
  members: members.map(name => ({name, namespaceLabels: {}, sources: [{chart: name, valueFiles: [], values: {}}]})),
  ...extra,
});
const memberParams = (guid, stage, body) => body.members.map(member => ({
  ...body,
  path: {path: `registrations/${guid}`, basename: guid, filename: `${stage}.yaml`, segments: ['registrations', guid]},
  values: {guid, stage},
  ...member,
}));
// A registration written before the field existed carries no displayName at all. The name with an
// apostrophe and an ampersand is the planted innocent: it must reach the chart unchanged.
const tenants = [
  {guid: 'aaaaaaaaaaaa', stage: 'prod', name: "Müller & O'Brien", body: registration(['web', 'idp'], {displayName: "Müller & O'Brien"})},
  {guid: 'bbbbbbbbbbbb', stage: 'test', name: '', body: registration(['web', 'idp'], {})},
];
const paramSets = tenants.flatMap(({guid, stage, body}) => memberParams(guid, stage, body));
const nameOf = set => tenants.find(({guid}) => guid === set.values.guid).name;

test('every member is handed its tenant display name, or "" where the registration has none', () => {
  const results = render(patch, paramSets);
  assert.equal(results.length, paramSets.length);
  results.forEach((result, at) => {
    assert.equal(result.error, undefined, `${paramSets[at].values.guid} ${paramSets[at].name}: ${result.error}`);
    const handed = yaml('[.spec.sources[].helm.valuesObject.tenant | select(has("member")) | .displayName]', result.output);
    assert.deepEqual(handed, [nameOf(paramSets[at])]);
  });
});

// One failed parameter set is enough for the controller to create, update and delete no Application
// of the whole set, so a registration without the field must render as well as one with it.
test('a bare read of displayName fails every member of the registration without it', () => {
  const bare = patch.replace('dig "displayName" "" $', '$.displayName');
  assert.notEqual(bare, patch);
  const results = render(bare, paramSets);
  results.forEach((result, at) => {
    if (nameOf(paramSets[at])) assert.equal(result.error, undefined);
    else assert.match(result.error, /map has no entry for key "displayName"/);
  });
});
