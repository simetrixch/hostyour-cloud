import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';

// Renders an inventory chart of this repository with the stand-in values of scripts/standin, as scripts/check.sh does.
export function renderChart(chart, extra = []) {
  const rendered = execFileSync('helm', ['template', chart, 'clusters/inventories/' + chart,
    '--namespace', chart === 'image-builder' ? 'image-builder' : 'argocd',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
    '-f', 'clusters/inventories/' + chart + '/values-common.yaml',
    ...(existsSync('clusters/inventories/' + chart + '/values-prod.yaml') ?
      ['-f', 'clusters/inventories/' + chart + '/values-prod.yaml'] : []),
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
// ArgoCD keeps a field its Application ignores at the live value only under RespectIgnoreDifferences=true;
// without it the ignore hides the change from the comparison and the next sync writes it all the same.
// Only jsonPointers are read: a field a jqPathExpressions rule ignores is still named.
export function driftFindings(first, second, application) {
  const respected = (application.spec.syncPolicy?.syncOptions ?? []).includes('RespectIgnoreDifferences=true');
  const rules = respected ? application.spec.ignoreDifferences ?? [] : [];
  const key = object => `${object.kind}/${object.metadata.name}`;
  const live = new Map(first.map(object => [key(object), object]));
  const found = [];
  for (const object of second) {
    const before = live.get(key(object));
    live.delete(key(object));
    if (!before) { found.push(`${key(object)} is new`); continue; }
    const written = structuredClone(object);
    const group = object.apiVersion.includes('/') ? object.apiVersion.split('/')[0] : '';
    for (const rule of rules.filter(r => (r.group ?? '') === group && r.kind === object.kind && (r.name ?? object.metadata.name) === object.metadata.name)) {
      for (const pointer of rule.jsonPointers ?? []) {
        const steps = pointer.split('/').slice(1).map(step => step.replaceAll('~1', '/').replaceAll('~0', '~'));
        const last = steps.pop();
        const from = steps.reduce((at, step) => at?.[step], before);
        const into = steps.reduce((at, step) => at?.[step], written);
        if (into === undefined || into === null) continue;
        if (from?.[last] === undefined) delete into[last]; else into[last] = from[last];
      }
    }
    found.push(...leaves(before, written, '').map(path => `${key(object)} ${path}`));
  }
  return [...found, ...[...live.keys()].map(name => `${name} is gone`)];
}
