import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {renderChart} from './render-chart.mjs';

// MongoDB's TCMalloc segfaults mongod on Linux 6.19 through 7.0.13 unless the pod carries
// GLIBC_TUNABLES=glibc.pthread.rseq=1. The platform switch global.mongod.rseqWorkaround decides, for the
// shared instance and for every unit's own mongod, whether a mongod pod carries that variable and the pod
// label that tells the cluster so; MongoDBRseqWorkaroundMissing (clusters/inventories/mongodb) reads the label
// against the kernel each machine reports. These cases render both charts and hold each pod to the switch.
// Run from the root of the repository, with the dependencies of both charts built, as scripts/check.sh does.
const SWITCH_OFF = ['--set', 'global.mongod.rseqWorkaround=false'];
const LABEL = 'hostyour.cloud/mongod-rseq-workaround';
const SHARED = 'clusters/inventories/mongodb';
const UNIT = 'clusters/units/mongodb';

const yq = (args, input) => execFileSync('yq', args, {encoding: 'utf8', input, maxBuffer: 8 * 1024 * 1024});
const documents = text => JSON.parse(yq(['ea', '-o=json', '-I=0', '[select(. != null)]', '-'], text));

/** The shared instance, as the platform renders it. */
const renderShared = (extra = [], folder = SHARED) => renderChart('mongodb', extra, folder);

/** A consumer's own mongod in one mode, rendered as the consumers ApplicationSet does (consumers-appset.yaml). */
const renderUnit = (mode, extra = [], folder = UNIT) => documents(execFileSync('helm', ['template', 'acme-test', folder,
  '--namespace', 'acme-test', '--api-versions', 'monitoring.coreos.com/v1',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml', '-f', 'scripts/standin/cluster-map.yaml',
  '-f', `${UNIT}/values-size-small.yaml`, '-f', `${UNIT}/values-mode-${mode}.yaml`, '--set', `mongodb.mode=${mode}`,
  '--set', 'mongodb.storageSize=10Gi', '--set', 'externalsecret-mongodb.externalSecret.vaultPath=test/consumer/acme/mongodb', ...extra],
{encoding: 'utf8', maxBuffer: 8 * 1024 * 1024}));

/** Every way a mongod pod of `docs` disagrees with the switch, named. */
function findings(docs, what, switchedOn) {
  const found = [];
  const sets = docs.filter(doc => doc.kind === 'StatefulSet');
  if (sets.length !== 1) found.push(`${what} renders ${sets.length} StatefulSets, not one`);
  for (const set of sets) {
    const template = set.spec.template;
    const mongod = template.spec.containers.find(container => container.name === 'mongodb');
    const tunables = (mongod?.env ?? []).filter(variable => variable.name === 'GLIBC_TUNABLES');
    const label = template.metadata.labels?.[LABEL];
    if (switchedOn) {
      if (JSON.stringify(tunables) !== JSON.stringify([{name: 'GLIBC_TUNABLES', value: 'glibc.pthread.rseq=1'}])) found.push(`${what} with the switch on carries ${JSON.stringify(tunables)}, not GLIBC_TUNABLES=glibc.pthread.rseq=1`);
      if (label !== 'true') found.push(`${what} with the switch on labels its pod ${LABEL}=${JSON.stringify(label)}, not "true"`);
    } else {
      if (tunables.length > 0) found.push(`${what} with the switch off still carries ${JSON.stringify(tunables)}`);
      if (label !== undefined) found.push(`${what} with the switch off still labels its pod ${LABEL}=${JSON.stringify(label)}`);
    }
  }
  return found;
}

const shared = {on: renderShared(), off: renderShared(SWITCH_OFF)};
const units = Object.fromEntries(['standalone', 'replicaset'].map(mode => [mode, {on: renderUnit(mode), off: renderUnit(mode, SWITCH_OFF)}]));

test('the shared instance and every mode of a unit carry the workaround and its label with the switch on, and neither with it off', () => {
  assert.deepEqual(findings(shared.on, 'the shared mongod', true), []);
  assert.deepEqual(findings(shared.off, 'the shared mongod', false), []);
  for (const [mode, rendered] of Object.entries(units)) {
    assert.deepEqual(findings(rendered.on, `the ${mode} unit mongod`, true), []);
    assert.deepEqual(findings(rendered.off, `the ${mode} unit mongod`, false), []);
  }
});

/** A copy of a chart folder whose StatefulSet template has one piece changed; the change must change something. */
function plantedCopy(source, pattern, replacement) {
  const dir = mkdtempSync(join(tmpdir(), 'mongod-rseq-'));
  const folder = join(dir, 'chart');
  cpSync(source, folder, {recursive: true});
  const file = join(folder, 'templates', 'statefulset.yaml');
  const text = readFileSync(file, 'utf8');
  const planted = text.replace(pattern, replacement);
  assert.notEqual(planted, text, `the plant looks for ${pattern} in ${source}, which its StatefulSet does not hold`);
  writeFileSync(file, planted);
  return {folder, remove: () => rmSync(dir, {recursive: true, force: true})};
}
const ENV_BLOCK = /\n +\{\{- with include "common.mongodRseqEnv" \. \}\}\n\{\{ \. \| indent 12 \}\}\n +\{\{- end \}\}/;
const LABEL_BLOCK = /\n +\{\{- with include "common.mongodRseqLabel" \. \}\}\n +\{\{ \. \}\}\n +\{\{- end \}\}/;
const LITERAL_ENV = '\n            - name: GLIBC_TUNABLES\n              value: "glibc.pthread.rseq=1"';

const CHARTS = [
  ['the shared instance', SHARED, (folder, extra) => renderShared(extra, folder)],
  ['a standalone unit', UNIT, (folder, extra) => renderUnit('standalone', extra, folder)],
  ['a replica set unit', UNIT, (folder, extra) => renderUnit('replicaset', extra, folder)],
];

for (const [what, source, render] of CHARTS) {
  test(`a copy of ${what} whose StatefulSet drops the workaround is caught with the switch on`, () => {
    const copy = plantedCopy(source, ENV_BLOCK, '');
    try {
      assert.notDeepEqual(findings(render(copy.folder, []), what, true), []);
    } finally { copy.remove(); }
  });
  test(`a copy of ${what} whose StatefulSet carries the workaround whatever the switch says is caught with the switch off`, () => {
    const copy = plantedCopy(source, ENV_BLOCK, LITERAL_ENV);
    try {
      assert.notDeepEqual(findings(render(copy.folder, SWITCH_OFF), what, false), []);
    } finally { copy.remove(); }
  });
  test(`a copy of ${what} whose StatefulSet drops the pod label is caught with the switch on`, () => {
    const copy = plantedCopy(source, LABEL_BLOCK, '');
    try {
      assert.notDeepEqual(findings(render(copy.folder, []), what, true), []);
    } finally { copy.remove(); }
  });
}

test('the label the pod carries is exported by both kube-state-metrics and read by MongoDBRseqWorkaroundMissing', () => {
  const master = JSON.parse(yq(['-o=json', '-I=0', '.kube-prometheus-stack.kube-state-metrics.metricLabelsAllowlist', 'clusters/inventories/observability/values-common.yaml']));
  const slave = JSON.parse(yq(['-o=json', '-I=0', '.kube-state-metrics.metricLabelsAllowlist', 'clusters/inventories/observability-agent/values-common.yaml']));
  assert.deepEqual(master, [`pods=[${LABEL}]`]);
  assert.deepEqual(slave, [`pods=[${LABEL}]`]);
  // kube-state-metrics writes a label key with every character outside [A-Za-z0-9_] as an underscore.
  const sanitized = `label_${LABEL.replace(/[^A-Za-z0-9_]/g, '_')}`;
  const rule = renderShared(['--api-versions', 'monitoring.coreos.com/v1']).filter(doc => doc.kind === 'PrometheusRule').flatMap(doc => doc.spec.groups).flatMap(group => group.rules)
    .find(each => each.alert === 'MongoDBRseqWorkaroundMissing');
  assert.ok(rule, 'the shared instance renders no MongoDBRseqWorkaroundMissing');
  assert.ok(rule.expr.includes(`${sanitized}="true"`), `MongoDBRseqWorkaroundMissing does not read ${sanitized}="true"`);
});
