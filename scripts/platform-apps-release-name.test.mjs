import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readdirSync} from 'node:fs';
import test from 'node:test';

// The Helm release name each platform Application renders with: its own name, as ArgoCD takes it
// without the line, unless the app.yaml names one. cert-manager names the addon's release, so ArgoCD
// adopts the running objects, whose Deployment selectors carry that name, instead of failing on them.

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

test('every app renders, each under its Application name, and cert-manager under the addon release name', () => {
  const params = apps.map(appYaml);
  const results = render(template, params);
  results.forEach((result, at) => {
    assert.equal(result.error, undefined, `${params[at].name}: ${result.error}`);
    const expected = params[at].name === 'cert-manager' ? 'cert-manager' : `${params[at].name}-prod`;
    assert.equal(releaseNameOf(result.output), expected, params[at].name);
  });
  assert.ok(apps.includes('cert-manager') && apps.length > 5, `the inventories were read: ${apps.join(', ')}`);
});

test('PLANTED DEFECT: a bare read of releaseName fails every app that names none', () => {
  const bare = template.replace('dig "releaseName" (printf "%s-prod" .name) .', '.releaseName');
  assert.notEqual(bare, template);
  const results = render(bare, [appYaml('redis')]);
  assert.match(results[0].error, /map has no entry for key "releaseName"/);
});
