import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// clusters/units/networkpolicy fences every unit namespace. The render is evaluated as Kubernetes
// evaluates an ingress rule: a peer with both selectors is a pod matching podSelector in a namespace
// matching namespaceSelector; a peer with podSelector alone is a pod of the policy's own namespace.
// The callers are the pods running today, with their labels as read on master and apps1.

const UNIT = 'tenant-a-prod';
const render = (extra = []) => JSON.parse(execFileSync('yq', ['ea', '-o=json', '-I=0', '[.] | map(select(. != null))', '-'], {encoding: 'utf8',
  input: execFileSync('helm', ['template', 'unit-networkpolicy', 'clusters/units/networkpolicy', '--namespace', UNIT,
    '-f', 'clusters/units/networkpolicy/values.yaml', ...extra], {encoding: 'utf8', stdio: 'pipe'})}));

const selects = (selector, labels) => !selector || (
  Object.entries(selector.matchLabels ?? {}).every(([key, value]) => labels[key] === value) &&
  (selector.matchExpressions ?? []).every(({key, operator, values}) =>
    operator === 'In' ? values.includes(labels[key]) : operator === 'Exists' ? key in labels : false));
/** Whether [policies] admit a pod of namespace [namespace] with [labels] to a pod of the unit. */
function admits(policies, namespace, labels) {
  return policies.filter(p => p.kind === 'NetworkPolicy').some(policy => (policy.spec.ingress ?? []).some(rule => (rule.from ?? []).some(peer =>
    peer.ipBlock ? false : peer.namespaceSelector
      ? selects(peer.namespaceSelector, {'kubernetes.io/metadata.name': namespace}) && selects(peer.podSelector, labels)
      : namespace === policy.metadata.namespace && selects(peer.podSelector, labels))));
}
const pod = name => ({'app.kubernetes.io/name': name});
const REQUIRED = [
  ['the unit\'s own web, engine, auth, jobs and migrations', UNIT, pod('digita-web')],
  ['Traefik, every public request and every cross-unit call', 'ingress', pod('traefik')],
  ['Prometheus, scraping on the master', 'observability', pod('prometheus')],
  ['Alloy, scraping on an app cluster', 'observability', pod('alloy')],
];
const REFUSED = [
  ['Grafana', 'observability', pod('grafana')],
  ['Loki', 'observability', pod('loki')],
  ['a pod of another tenant', 'tenant-b-prod', pod('digita-web')],
  ['a pod of another tenant labelled as Traefik', 'tenant-b-prod', pod('traefik')],
  ['an unlabelled pod in ingress', 'ingress', {}],
];
/** Every required caller the policies refuse and every other pod they admit, named. */
const findings = policies => [
  ...REQUIRED.filter(([, namespace, labels]) => !admits(policies, namespace, labels)).map(([name]) => `refused: ${name}`),
  ...REFUSED.filter(([, namespace, labels]) => admits(policies, namespace, labels)).map(([name]) => `admitted: ${name}`),
];

test('a unit admits its own pods, Traefik and the scrapers, and refuses every other pod of the platform and of other tenants', () => {
  assert.deepEqual(findings(render()), []);
});

test('PLANTED DEFECT: a fence that admits a whole namespace, any namespace, or forgets a scraper is caught', () => {
  const policies = render();
  const peers = copy => copy[0].spec.ingress[0].from;
  const change = edit => { const copy = structuredClone(policies); edit(peers(copy)); return copy; };
  const planted = {
    'a whole namespace': change(from => { delete from[1].podSelector; }),
    'any namespace': change(from => { delete from[1].namespaceSelector; }),
    'no Alloy': render(['--set-json', 'admittedNamespaces={"ingress":["traefik"],"observability":["prometheus"]}']),
  };
  for (const [name, copy] of Object.entries(planted)) assert.notDeepEqual(findings(copy), [], name);
});
