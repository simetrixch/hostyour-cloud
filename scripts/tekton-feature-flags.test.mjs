import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';

// A refresh of the vendored Tekton manifest overwrites it verbatim and with it the feature flags this
// platform depends on (clusters/inventories/tekton/values-common.yaml says why each one stands).

const MANIFEST = 'clusters/inventories/tekton/templates/release-pipelines.yaml';
const VALUES = 'clusters/inventories/tekton/values-common.yaml';
const WANTED = {coschedule: 'disabled', 'enable-api-fields': 'beta'};

const featureFlags = (manifest) =>
  JSON.parse(execFileSync('yq', ['ea', '-o=json', 'select(.kind == "ConfigMap" and .metadata.name == "feature-flags") | .data'], {encoding: 'utf8', input: manifest}));

const drift = (flags) => Object.entries(WANTED).filter(([key, value]) => flags[key] !== value).map(([key]) => key);

test('the vendored feature-flags carry the values the platform depends on', () => {
  assert.deepEqual(drift(featureFlags(readFileSync(MANIFEST, 'utf8'))), []);
});

test('planted defect: a refresh that brings back the default coschedule is caught', () => {
  const refreshed = readFileSync(MANIFEST, 'utf8').replace(/^  coschedule: "disabled"$/m, '  coschedule: "workspaces"');
  assert.deepEqual(drift(featureFlags(refreshed)), ['coschedule']);
});

test('the build plane alert names the cluster that runs Tekton and fires above one node', () => {
  const rules = JSON.parse(execFileSync('yq', ['-o=json', '.monitoring.prometheusRules.tekton.groups[].rules', VALUES], {encoding: 'utf8'}));
  const alert = rules.find((r) => r.alert === 'TektonBuildPlaneHasManyNodes');
  assert.ok(alert, 'no alert TektonBuildPlaneHasManyNodes');
  assert.equal(alert.expr, 'count by (cluster) (kube_node_info) > 1 and on (cluster) count by (cluster) (up{job=~"tekton.*"})');
});
