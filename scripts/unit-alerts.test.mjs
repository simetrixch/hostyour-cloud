import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const docs = rendered => JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(. != null)]', '-'], {encoding: 'utf8', input: rendered}));
// The master's rules as clusters/inventories/observability hands them to its monitoring dependency.
// Only a master runs that chart, and an app cluster evaluates no rule at all: its agent remote-writes.
const master = () => docs(execFileSync('helm', ['template', 'observability', 'clusters/charts/monitoring',
  '--namespace', 'observability', '--api-versions', 'monitoring.coreos.com/v1', '-f', '-'], {encoding: 'utf8',
  input: execFileSync('yq', ['.monitoring', 'clusters/inventories/observability/values-common.yaml'], {encoding: 'utf8'})}));
// A consumer's own PostgreSQL as clusters/argocd/files/consumers-appset.yaml renders it onto its app cluster.
const unit = () => docs(execFileSync('helm', ['template', 'acme-test', 'clusters/units/postgresql',
  '--namespace', 'acme-test', '--api-versions', 'monitoring.coreos.com/v1',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-test.yaml',
  '-f', 'clusters/units/postgresql/values-size-small.yaml', '-f', 'scripts/standin/cluster-map.yaml',
  '--set', 'externalsecret-postgres.externalSecret.vaultPath=test/consumer/acme/postgres'], {encoding: 'utf8'}));

const alerts = ['PostgreSQLDown', 'PostgreSQLConnectionsSaturated', 'PostgreSQLDeadlocksSpiking', 'PostgreSQLStorageFillingUp'];
const rulesOf = rendered => rendered.filter(({kind}) => kind === 'PrometheusRule')
  .flatMap(({spec}) => spec.groups.flatMap(({rules}) => rules));

// Every unit's alert is evaluated once, on the master, and names the one cluster and namespace it is about.
const checkMaster = (rendered, dataVolume) => {
  const rules = rulesOf(rendered);
  for (const alert of alerts) {
    const rule = rules.find(rule => rule.alert === alert);
    assert.ok(rule, `the master evaluates no ${alert}`);
    assert.doesNotMatch(rule.expr, /\b(?:cluster|namespace)\s*(?:=|!=|=~|!~)/, `${alert} is pinned to one unit`);
    for (const [, labels] of rule.expr.matchAll(/\b(?:by|on)\s*\(([^)]*)\)/g)) {
      const kept = labels.split(',').map(label => label.trim());
      assert.ok(kept.includes('cluster') && kept.includes('namespace'), `${alert} folds the cluster or the namespace away`);
    }
  }
  const storage = rules.find(rule => rule.alert === 'PostgreSQLStorageFillingUp').expr;
  assert.match(storage, new RegExp(`persistentvolumeclaim="${dataVolume}"`), 'the storage alert does not read the unit\'s data volume');
};
// The one claim the unit's database mounts.
const dataVolumeOf = rendered => {
  const claims = rendered.filter(({kind}) => kind === 'Deployment' || kind === 'StatefulSet')
    .flatMap(({spec}) => spec.template.spec.volumes ?? []).flatMap(({persistentVolumeClaim}) => persistentVolumeClaim?.claimName ?? []);
  assert.equal(claims.length, 1, 'the unit mounts no data volume, or more than one');
  return claims[0];
};
// A rule rendered onto an app cluster is evaluated nowhere.
const checkUnit = rendered =>
  assert.deepEqual(rulesOf(rendered).map(({alert}) => alert), [], 'the unit chart renders a rule no Prometheus evaluates');

test('the master evaluates every unit\'s PostgreSQL alerts, and the unit chart renders none', () => {
  const rendered = unit();
  checkUnit(rendered);
  checkMaster(master(), dataVolumeOf(rendered));
});

test('a pinned alert, a folded label and a unit rule are refused', () => {
  const rendered = master();
  const volume = dataVolumeOf(unit());
  const plant = (alert, change) => rendered.map(doc => doc.kind !== 'PrometheusRule' ? doc : {...doc, spec: {groups: doc.spec.groups
    .map(group => ({...group, rules: group.rules.map(rule => rule.alert === alert ? {...rule, expr: change(rule.expr)} : rule)}))}});
  assert.throws(() => checkMaster(plant('PostgreSQLDown', () => 'pg_up{namespace="acme-test"} == 0'), volume), /pinned to one unit/);
  assert.throws(() => checkMaster(plant('PostgreSQLConnectionsSaturated', expr => expr.replaceAll('cluster, ', '')), volume), /folds/);
  assert.throws(() => checkMaster(plant('PostgreSQLStorageFillingUp', expr => expr.replace(volume, 'other')), volume), /data volume/);
  assert.throws(() => checkUnit([{kind: 'PrometheusRule', spec: {groups: [{rules: [{alert: 'PostgreSQLDown'}]}]}}]), /evaluates/);
});
