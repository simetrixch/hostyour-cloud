import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readdirSync, readFileSync} from 'node:fs';
import test from 'node:test';

// What the platform ApplicationSet makes of one app.yaml: the Helm release name each Application renders
// with, its own name unless the app.yaml names one (cert-manager names the addon's release, so ArgoCD
// adopts the running objects), and the clusters it stands on, where runsOn may name one cluster.

const appsetFile = 'clusters/argocd/files/platform-apps-appset.yaml';
const spec = JSON.parse(execFileSync('yq', ['-o=json', '.spec', appsetFile], {encoding: 'utf8'}));
// The template as the install branch hands it to the controller: the stage placeholder filled in.
const template = execFileSync('yq', ['.spec.template', appsetFile], {encoding: 'utf8'}).replaceAll('__STAGE__', 'prod');
const render = (text, paramSets) => JSON.parse(execFileSync('go', ['run', '.'], {cwd: 'scripts/appset-render',
  input: JSON.stringify({template: text, options: spec.goTemplateOptions, params: paramSets}), encoding: 'utf8'}));
const appYaml = name => JSON.parse(execFileSync('yq', ['-o=json', '.', `clusters/inventories/${name}/app.yaml`], {encoding: 'utf8'}));
const apps = readdirSync('clusters/inventories', {withFileTypes: true}).filter(e => e.isDirectory()).map(e => e.name)
  .filter(name => { try { return Boolean(appYaml(name).name); } catch { return false; } });
const releaseNameOf = output => JSON.parse(execFileSync('yq', ['-o=json', '.spec.sources[1].helm.releaseName'], {input: output, encoding: 'utf8'}));

test('every app renders under its Application name, or under the release name its app.yaml names', () => {
  const params = apps.map(appYaml);
  const results = render(template, params);
  results.forEach((result, at) => {
    assert.equal(result.error, undefined, `${params[at].name}: ${result.error}`);
    const expected = params[at].releaseName ?? `${params[at].name}-prod`;
    assert.equal(releaseNameOf(result.output), expected, params[at].name);
  });
  assert.ok(apps.includes('cert-manager') && apps.length > 5, `the inventories were read: ${apps.join(', ')}`);
  assert.equal(releaseNameOf(results[apps.indexOf('cert-manager')].output), 'cert-manager');
});

test('PLANTED DEFECT: a bare read of releaseName fails every app that names none', () => {
  const bare = template.replace('dig "releaseName" (printf "%s-prod" .name) .', '.releaseName');
  assert.notEqual(bare, template);
  const results = render(bare, [appYaml('redis')]);
  assert.match(results[0].error, /map has no entry for key "releaseName"/);
});

// The selector as clusters/argocd hands it to a cluster's ArgoCD, rendered from the stand-in cluster map.
const clusterMap = JSON.parse(execFileSync('yq', ['-o=json', '.', 'scripts/standin/cluster-map.yaml'], {encoding: 'utf8'}));
const appsets = execFileSync('helm', ['template', 'argocd-apps', 'clusters/argocd', '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/registration.yaml'], {encoding: 'utf8'});
const runsOnValues = JSON.parse(execFileSync('yq', ['-o=json', '-I=0',
  'select(.kind == "ApplicationSet" and (.metadata.name | test("^platform-apps-"))) | .spec.generators[0].selector.matchExpressions[] | select(.key == "runsOn") | .values'],
  {input: appsets, encoding: 'utf8'}));
const selects = runsOn => runsOnValues.includes(runsOn);

test('runsOn may name the cluster itself, and a name of another cluster selects nothing here', () => {
  assert.ok(selects(clusterMap.global.clusterName), `${clusterMap.global.clusterName} in ${runsOnValues}`);
  assert.ok(selects('every-cluster'));
  assert.ok(!selects('apps8'), 'PLANTED: another cluster\'s name');
});

// THE WAVES. platform-apps-<stage> syncs by RollingSync, one step per wave from 0 up to the count in
// clusters/argocd/templates/apps.yaml, and a step starts only once every Application of the steps
// before it is Healthy. The forge apps wait for Vault entries a later act writes, so they stand after
// every other app: while one of them waits, no app of the platform waits behind it.
const waveCount = Number(/\$waveCount := (\d+)/.exec(readFileSync('clusters/argocd/templates/apps.yaml', 'utf8'))[1]);
const FORGE_APPS = ['forgejo'];

/** Every app outside the steps, and every forge app not after all the others, named. */
function waveFindings(params) {
  const found = [];
  for (const app of params) {
    if (!/^\d+$/.test(String(app.syncWave)) || Number(app.syncWave) >= waveCount) found.push(`${app.name}: wave ${app.syncWave} is no step of 0 to ${waveCount - 1}`);
  }
  const last = Math.max(...params.filter(app => !FORGE_APPS.includes(app.name)).map(app => Number(app.syncWave)));
  for (const app of params.filter(app => FORGE_APPS.includes(app.name))) {
    if (Number(app.syncWave) <= last) found.push(`${app.name}: wave ${app.syncWave} does not stand after ${last}`);
  }
  return found;
}

test('every wave is a step of the RollingSync, and the forge apps stand after every other app', () => {
  const params = apps.map(appYaml);
  assert.deepEqual(FORGE_APPS.filter(name => !apps.includes(name)), [], 'every forge app is an inventory');
  assert.deepEqual(waveFindings(params), []);
});

test('PLANTED DEFECT: a forge app in an existing wave, a wave past the steps and an app.yaml with no wave are found', () => {
  const params = apps.map(appYaml);
  const forge = params.find(app => app.name === FORGE_APPS[0]);
  const last = Math.max(...params.filter(app => !FORGE_APPS.includes(app.name)).map(app => Number(app.syncWave)));
  assert.deepEqual(waveFindings(params.map(app => (app === forge ? {...app, syncWave: '25'} : app))), [`${forge.name}: wave 25 does not stand after ${last}`]);
  assert.equal(waveFindings(params.map(app => (app === forge ? {...app, syncWave: String(waveCount)} : app))).length, 1);
  const {syncWave, ...waveless} = forge;
  assert.match(render(template, [waveless])[0].error, /map has no entry for key "syncWave"/);
});

test('PLANTED INNOCENT: an app moved to another wave before the forge apps is not found', () => {
  const params = apps.map(appYaml).map(app => (app.name === 'postfix' ? {...app, syncWave: '21'} : app));
  assert.deepEqual(waveFindings(params), []);
});
