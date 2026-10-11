// What the tenant ApplicationSet tests share: the ApplicationSet as it stands in this repository,
// the renderer that evaluates its templates the way the controller does (scripts/appset-render), and
// a registration in the shape the Manager writes (registrations/<guid>/<stage>.yaml on the books branch).
import {execFileSync} from 'node:child_process';

export const yaml = (expression, input) => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input, encoding: 'utf8'}));
export const appset = JSON.parse(execFileSync('yq', ['-o=json', '.spec', 'clusters/argocd/files/tenants-appset.yaml'], {encoding: 'utf8'}));
export const patch = appset.templatePatch;

// A template rendered once per parameter set. Each answer is {output} or {error}.
export const render = (template, paramSets) => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
  input: JSON.stringify({template, options: appset.goTemplateOptions, params: paramSets}), encoding: 'utf8'}));

// The registration's fields, one chart source per name. The app and the standing members stand for
// the ones every registration carries; a test hands what it differs in as `extra`.
export const registration = (charts, extra) => ({
  cluster: 'apps1', subdomain: 'acme',
  apps: [{name: 'workshop', seedReference: true, seedDemo: false, selections: {}, needs: [], path: '/app/workshop'}],
  members: [{name: 'auth', path: '/auth'}, {name: 'web', path: '/'}],
  identityProvider: 'auth', namespaceLabels: {}, approvedTags: {}, removedApps: {},
  sources: charts.map(chart => ({chart, valueFiles: [], values: {}})),
  ownDomain: '', ownDomainRedirects: [], senderDomain: '', seedUsers: false, demo: false, resetNonce: '',
  suspended: false, quiesced: false, appsRepo: '', appsImage: '', appsImageTag: '',
  quota: {requestsCpu: '200m', requestsMemory: '1152Mi', limitsCpu: '4', limitsMemory: '4Gi', pods: '4', persistentVolumeClaims: '1'},
  ...extra,
});

// The parameter set the git files generator hands the templates for one registration: its fields, its
// path, and the generator's values.
export const paramSet = (guid, stage, body) => ({
  ...body,
  path: {path: `registrations/${guid}`, basename: guid, filename: `${stage}.yaml`, segments: ['registrations', guid]},
  values: {guid, stage},
});

// The tenant facts of every chart source of a rendered templatePatch, in source order.
export const chartTenants = output => yaml('[.spec.sources[].helm.valuesObject.tenant | select(. != null)]', output);
