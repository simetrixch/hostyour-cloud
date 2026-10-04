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
  cluster: 'apps1', subdomain: 'acme', apps: [], identityProvider: {}, routing: 'host', ownDomain: '',
  ownDomainRedirects: [], approvedTags: {}, senderDomain: '', seedUsers: false, demo: false, resetNonce: '',
  suspended: false, quiesced: false, appsRepo: '', appsImage: '', appsImageTag: '',
  quota: {requestsCpu: '100m', requestsMemory: '576Mi', limitsCpu: '2', limitsMemory: '2Gi', pods: '4', persistentVolumeClaims: '1'},
  members: members.map(name => ({name, namespaceLabels: {}, sources: [{chart: name, valueFiles: [], values: {}}]})),
  ...extra,
});
// What the matrix hands the patch for each member: the git files generator's parameters (the
// registration's own fields, its path, the generator's values) with the list generator's member over them.
const memberParams = (guid, stage, body) => body.members.map(member => ({
  ...body,
  path: {path: `registrations/${guid}`, basename: guid, filename: `${stage}.yaml`, segments: ['registrations', guid]},
  values: {guid, stage},
  ...member,
}));
const tenants = [
  {guid: 'aaaaaaaaaaaa', stage: 'prod', size: 'small', body: registration(['web', 'idp'], {size: 'small'})},
  {guid: 'bbbbbbbbbbbb', stage: 'test', size: '', body: registration(['web', 'idp'], {})},
  {guid: 'cccccccccccc', stage: 'dev', size: 'xsmall', body: registration(['web'], {size: 'xsmall'})},
];
const paramSets = tenants.flatMap(({guid, stage, body}) => memberParams(guid, stage, body));
const sizeOf = set => tenants.find(({guid}) => guid === set.values.guid).size;

test('every registration renders, and each member is handed its tenant stage size word, or "" without one', () => {
  const results = render(patch, paramSets);
  assert.equal(results.length, paramSets.length);
  results.forEach((result, at) => {
    assert.equal(result.error, undefined, `${paramSets[at].values.guid} ${paramSets[at].name}: ${result.error}`);
    const handed = yaml('[.spec.sources[].helm.valuesObject.tenant | select(has("member")) | .size]', result.output);
    assert.deepEqual(handed, [sizeOf(paramSets[at])]);
  });
});

// One failed parameter set is enough for the controller to create, update and delete no Application
// of the whole set (argo-cd v3.4.5 applicationset/controllers/template/template.go:37-61 and
// applicationset_controller.go:201-216), which is why the first test admits no error at all.
test('a bare read of size fails every member of the registration without it', () => {
  const bare = patch.replace('dig "size" "" $', '$.size');
  assert.notEqual(bare, patch);
  const results = render(bare, paramSets);
  results.forEach((result, at) => {
    if (sizeOf(paramSets[at])) assert.equal(result.error, undefined);
    else assert.match(result.error, /map has no entry for key "size"/);
  });
});
