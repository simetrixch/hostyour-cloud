import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// clusters/charts/ingress binds every Ingress it renders to websecure alone, and its line is the
// only one: a consumer that sets the entrypoints annotation again would otherwise render the key
// twice in one mapping, which yq reads as the last of the two and a strict decoder may refuse.
// The manager chart is the consumer here, rendered from the chain scripts/check.sh uses.
const KEY = 'traefik.ingress.kubernetes.io/router.entrypoints';
const escaped = KEY.replaceAll('.', '\\.');
const render = (...sets) => execFileSync('helm', ['template', 'manager', 'clusters/inventories/manager', '--namespace', 'manager',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
  '-f', 'clusters/inventories/manager/values-common.yaml', '-f', 'clusters/inventories/manager/values-prod.yaml',
  '-f', 'scripts/standin/installation-values.yaml', '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/registration.yaml',
  ...sets.flatMap(set => ['--set-string', set])], {encoding: 'utf8'});
/** The annotation lines of the rendered Ingress, as helm wrote them. */
const annotationLines = output => {
  const ingress = output.split(/^---\n/m).find(doc => /^kind: Ingress$/m.test(doc));
  assert.ok(ingress, 'the manager renders an Ingress');
  const block = ingress.slice(ingress.indexOf('  annotations:\n'), ingress.indexOf('\nspec:'));
  return block.split('\n').filter(line => /^ {4}\S/.test(line));
};

test('the chart writes the entrypoints annotation once, as websecure', () => {
  assert.deepEqual(annotationLines(render()).filter(line => line.includes(KEY)), [`    ${KEY}: websecure`]);
});

test('PLANTED DEFECT: a consumer that sets the entrypoints again leaves one line, websecure, and keeps its other annotations', () => {
  const lines = annotationLines(render(`ingress.ingress.annotations.${escaped}=web\\,websecure`, 'ingress.ingress.annotations.planted\\.example\\.invalid/kept=yes'));
  assert.deepEqual(lines.filter(line => line.includes(KEY)), [`    ${KEY}: websecure`]);
  assert.ok(lines.includes('    planted.example.invalid/kept: "yes"'), lines.join('\n'));
});
