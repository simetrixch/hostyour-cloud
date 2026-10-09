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
