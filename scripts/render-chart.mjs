import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {ignoredFields, withoutIgnored} from './check-immutable.mjs';

// Renders an inventory chart of this repository with the stand-in values of scripts/standin, as scripts/check.sh does.
// `folder` names a copy of the chart's folder to render instead, as a test of a planted defect in the chart does.
export function renderChart(chart, extra = [], folder = 'clusters/inventories/' + chart) {
  const rendered = execFileSync('helm', ['template', chart, folder,
    '--namespace', chart === 'image-builder' ? 'image-builder' : 'argocd',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
    '-f', folder + '/values-common.yaml',
    ...(existsSync(folder + '/values-prod.yaml') ? ['-f', folder + '/values-prod.yaml'] : []),
    '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/registration.yaml', ...extra],
    {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe']});
  return JSON.parse(execFileSync('yq', ['eval-all', '-o=json', '-I=0', '[.]', '-'],
    {input: rendered, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024})).filter(Boolean);
}

// The same chart rendered twice, a second apart, as the repo-server renders it for two revisions.
export function renderTwice(chart, extra = []) {
  const first = renderChart(chart, extra);
  execFileSync('sleep', ['1']);
  return [first, renderChart(chart, extra)];
}

// The Application the platform ApplicationSet makes of one app.yaml: its templatePatch, as the controller renders it.
export function applicationOf(app) {
  const appset = JSON.parse(execFileSync('yq', ['-o=json', '.spec', 'clusters/argocd/files/platform-apps-appset.yaml'], {encoding: 'utf8'}));
  const [{output, error}] = JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
    input: JSON.stringify({template: appset.templatePatch, options: appset.goTemplateOptions, params: [app]}), encoding: 'utf8'}));
  if (error) throw new Error(error);
  return JSON.parse(execFileSync('yq', ['-o=json', '.'], {input: output, encoding: 'utf8'}));
}

const leaves = (live, written, path) => live && written && typeof live === 'object' && typeof written === 'object' ?
  [...new Set([...Object.keys(live), ...Object.keys(written)])].flatMap(key => leaves(live[key], written[key], `${path}/${key}`)) :
  JSON.stringify(live) === JSON.stringify(written) ? [] : [path];

// Every leaf a sync of the second render writes over what the first left live, as `<kind>/<name> <path>`.
// The fields ArgoCD keeps at the live value are the immutable check's: only under
// RespectIgnoreDifferences=true, without which the next sync writes an ignored field all the same, and
// only one annotation or label per path (scripts/check-immutable.mjs).
export function driftFindings(first, second, application) {
  const rules = ignoredFields({name: application.metadata?.name, ignoreDifferences: application.spec.ignoreDifferences,
    respectIgnoreDifferences: String((application.spec.syncPolicy?.syncOptions ?? []).includes('RespectIgnoreDifferences=true'))});
  const key = object => `${object.kind}/${object.metadata.name}`;
  const live = new Map(first.map(object => [key(object), object]));
  const found = [];
  for (const object of second) {
    const before = live.get(key(object));
    live.delete(key(object));
    if (!before) { found.push(`${key(object)} is new`); continue; }
    found.push(...leaves(withoutIgnored(before, undefined, rules), withoutIgnored(object, undefined, rules), '').map(path => `${key(object)} ${path}`));
  }
  return [...found, ...[...live.keys()].map(name => `${name} is gone`)];
}
