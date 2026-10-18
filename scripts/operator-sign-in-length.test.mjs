import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const readBlueprint = file => JSON.parse(execFileSync('yq', ['-o=json', '.',
  fileURLToPath(new URL(`../clusters/bootstrap/idp/blueprints/${file}`, import.meta.url))], {encoding: 'utf8'}));

// The ID token lives as long as the access token, and Argo CD and Headlamp keep it as the
// operator's session; the forward-auth gate in front of kube.<fqdn> ends Headlamp with its own, the provider
// whose external host that is.
const operatorSignIns = [
  ['99-argocd.yaml', 'ArgoCD'],
  ['99-argo-slave.yaml', 'ArgoCD Slave'],
  ['99-headlamp.yaml', 'Headlamp'],
  ['99-proxy-tekton.yaml', 'Tekton Dashboard'],
  ['99-proxy-headlamp.yaml', 'Headlamp Forward Auth'],
];
const day = 86400;
// The keys of Authentik's timedelta_from_string (authentik/lib/utils/time.py), in seconds.
const unitSeconds = {microseconds: 1e-6, milliseconds: 1e-3, seconds: 1, minutes: 60, hours: 3600, days: 86400, weeks: 604800};

const assertSignInLasts = (file, provider, blueprint) => {
  const where = `${file}: provider ${provider}`;
  const entry = blueprint.entries.find(each => each.model.startsWith('authentik_providers_') && each.identifiers.name === provider);
  assert.ok(entry, `${where} is missing`);
  const validity = String(entry.attrs.access_token_validity);
  // Authentik reads `key=value` pairs joined by `;`, and a repeated key keeps its last value.
  const pairs = Object.entries(Object.fromEntries(validity.split(';').map(pair => pair.split('='))));
  assert.ok(pairs.every(([key, value]) => Object.hasOwn(unitSeconds, key) && Number.isFinite(Number(value))),
    `${where}: access_token_validity ${validity} is not key=value pairs of ${Object.keys(unitSeconds).join(', ')}`);
  const seconds = pairs.reduce((sum, [key, value]) => sum + Number(value) * unitSeconds[key], 0);
  assert.ok(seconds >= day, `${where}: access_token_validity ${validity} signs an operator out after ${seconds} seconds, under a day`);
};

for (const [file, provider] of operatorSignIns) {
  test(`${provider} in ${file} keeps an operator signed in for at least a day`, () => {
    assertSignInLasts(file, provider, readBlueprint(file));
  });
}

test('a validity under a day, an unreadable one or a missing provider fails; a day in any spelling passes', () => {
  const headlamp = readBlueprint('99-headlamp.yaml');
  const withValidity = validity => {
    const planted = structuredClone(headlamp);
    planted.entries.find(each => each.identifiers.name === 'Headlamp').attrs.access_token_validity = validity;
    return planted;
  };
  for (const validity of ['days=1', 'hours=23;minutes=60', 'weeks=1']) {
    assertSignInLasts('99-headlamp.yaml', 'Headlamp', withValidity(validity));
  }
  assert.throws(() => assertSignInLasts('99-headlamp.yaml', 'Headlamp', withValidity('hours=23')),
    /99-headlamp\.yaml: provider Headlamp: access_token_validity hours=23 .* under a day/);
  assert.throws(() => assertSignInLasts('99-headlamp.yaml', 'Headlamp', withValidity('hours=48;hours=1')), /under a day/);
  assert.throws(() => assertSignInLasts('99-headlamp.yaml', 'Headlamp', withValidity('hour=24')), /is not key=value pairs/);
  assert.throws(() => assertSignInLasts('99-headlamp.yaml', 'Kubernetes', headlamp), /provider Kubernetes is missing/);
});
