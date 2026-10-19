import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';

// A refresh of the vendored Tekton manifest overwrites it verbatim and with it the feature flags this
// platform depends on (clusters/inventories/tekton/values-common.yaml says why each one stands).

const MANIFEST = 'clusters/inventories/tekton/templates/release-pipelines.yaml';
const VALUES = 'clusters/inventories/tekton/values-common.yaml';
const WANTED = {coschedule: 'disabled', 'enable-api-fields': 'beta', 'set-security-context': 'false'};

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

test('planted defect: a refresh that brings back the default security contexts is caught', () => {
  const refreshed = readFileSync(MANIFEST, 'utf8').replace(/^  set-security-context: "false"$/m, '  set-security-context: "true"');
  assert.deepEqual(drift(featureFlags(refreshed)), ['set-security-context']);
});

test('planted innocent: the read-only root filesystem flag moving changes nothing the platform depends on', () => {
  const refreshed = readFileSync(MANIFEST, 'utf8').replace(/^  set-security-context-read-only-root-filesystem: "false"$/m, '  set-security-context-read-only-root-filesystem: "true"');
  assert.deepEqual(drift(featureFlags(refreshed)), []);
});

test('the build plane alert stands with its expression', () => {
  const rules = JSON.parse(execFileSync('yq', ['-o=json', '.monitoring.prometheusRules.tekton.groups[].rules', VALUES], {encoding: 'utf8'}));
  const alert = rules.find((r) => r.alert === 'TektonBuildPlaneHasManyNodes');
  assert.ok(alert, 'no alert TektonBuildPlaneHasManyNodes');
  assert.equal(alert.expr, 'count by (cluster) (kube_node_info) > 1 and on (cluster) count by (cluster) (up{job=~"tekton.*"})');
});

// THE ALERTS READ THE METRICS THE VENDORED CONTROLLER EXPOSES, NOT THE NAMES OF AN OLDER RELEASE. The controller
// of v1.17.0 exposes tekton_pipelines_controller_pipelinerun_total, not the OpenCensus name with `_count`, and an
// alert that names a metric nothing exposes never fires. METRICS_RELEASE is the release whose metrics reference
// (docs/metrics.md of tektoncd/pipeline at that tag) the names below were read from; a refresh of the manifest to
// another release turns the first test red until the names are read from that release's reference again.
const METRICS_RELEASE = 'v1.17.0';
const CONTROLLER_PREFIX = 'tekton_pipelines_controller_';
const HISTOGRAMS = ['pipelinerun_duration_seconds', 'pipelinerun_taskrun_duration_seconds', 'taskrun_duration_seconds', 'taskruns_pod_latency_milliseconds'];
const CONTROLLER_METRICS = new Set([
  'pipelinerun_total', 'running_pipelineruns', 'taskrun_total', 'running_taskruns',
  'running_taskruns_throttled_by_quota', 'running_taskruns_throttled_by_node',
  'running_pipelineruns_waiting_on_pipeline_resolution', 'running_pipelineruns_waiting_on_task_resolution',
  'running_taskruns_waiting_on_task_resolution_count',
  ...HISTOGRAMS.flatMap((name) => ['bucket', 'sum', 'count'].map((suffix) => `${name}_${suffix}`)),
].map((name) => CONTROLLER_PREFIX + name));

const IMAGE_BUILDER_VALUES = 'clusters/inventories/image-builder/values-common.yaml';
const OBSERVABILITY_VALUES = 'clusters/inventories/observability/values-common.yaml';
const releaseOf = (manifest) => JSON.parse(execFileSync('yq', ['ea', '-o=json', 'select(.kind == "Deployment" and .metadata.name == "tekton-controller") | .metadata.labels["pipeline.tekton.dev/release"]'], {encoding: 'utf8', input: manifest}));
const rulesOf = (file, name) => JSON.parse(execFileSync('yq', ['-o=json', `.monitoring.prometheusRules["${name}"].groups[].rules`, file], {encoding: 'utf8'}));
const exprOf = (rules, alert) => rules.find((rule) => rule.alert === alert)?.expr;
const wordsWith = (prefix) => (expr) => expr.match(new RegExp(`${prefix}[a-z_]+`, 'g')) ?? [];
const unknownControllerNames = (expr) => wordsWith(CONTROLLER_PREFIX)(expr).filter((word) => !CONTROLLER_METRICS.has(word));

test('the names of the controller metrics were read from the release the platform vendors', () => {
  assert.equal(releaseOf(readFileSync(MANIFEST, 'utf8')), METRICS_RELEASE, `the vendored Tekton is not ${METRICS_RELEASE}: read docs/metrics.md of tektoncd/pipeline at the new tag and update CONTROLLER_METRICS and METRICS_RELEASE`);
  assert.notEqual(releaseOf(readFileSync(MANIFEST, 'utf8').replaceAll(`"${METRICS_RELEASE}"`, '"v9.9.9"')), METRICS_RELEASE, 'PLANTED DEFECT: a refresh of the manifest to another release is caught');
});

test('the four Tekton alert expressions name only metrics that the controller exposes', () => {
  const alerts = [['tekton', VALUES], ['image-builder', IMAGE_BUILDER_VALUES]].flatMap(([name, file]) => ['PipelineRunFailed', 'PipelineRunRunningTooLong'].map((alert) => {
    const expr = exprOf(rulesOf(file, name), alert);
    assert.ok(expr, `${file} carries no alert ${alert}`);
    return {file, alert, expr};
  }));
  assert.equal(alerts.length, 4);
  for (const {file, alert, expr} of alerts) assert.deepEqual(unknownControllerNames(expr), [], `${alert} in ${file} names a metric that the controller does not expose`);
  for (const {file, expr} of alerts.filter(({alert}) => alert === 'PipelineRunFailed')) {
    assert.deepEqual(wordsWith(CONTROLLER_PREFIX)(expr), [`${CONTROLLER_PREFIX}pipelinerun_total`], `PipelineRunFailed in ${file} counts the failed runs of the controller`);
  }
});

test('planted defect: an expression with the OpenCensus names is caught, the corrected one and a real name that ends in _count pass', () => {
  assert.deepEqual(unknownControllerNames('increase(tekton_pipelines_controller_pipelinerun_count{status="failed"}[10m]) > 0'), ['tekton_pipelines_controller_pipelinerun_count']);
  assert.deepEqual(unknownControllerNames('time() - max(tekton_pipelines_controller_running_pipelineruns_count > 0) > 1800'), ['tekton_pipelines_controller_running_pipelineruns_count']);
  assert.deepEqual(unknownControllerNames('increase(tekton_pipelines_controller_pipelinerun_total{status="failed"}[10m]) > 0'), []);
  assert.deepEqual(unknownControllerNames('tekton_pipelines_controller_running_taskruns_waiting_on_task_resolution_count > 0'), []);
});

test('the age of a run is read from the series that kube-state-metrics makes of the PipelineRun, and the alert names them', () => {
  const prefix = 'tekton_pipelinerun_';
  const config = JSON.parse(execFileSync('yq', ['-o=json', '.["kube-prometheus-stack"]["kube-state-metrics"]', OBSERVABILITY_VALUES], {encoding: 'utf8'}));
  const [resource] = config.customResourceState.config.spec.resources.filter((r) => r.groupVersionKind.kind === 'PipelineRun');
  assert.deepEqual(resource.groupVersionKind, {group: 'tekton.dev', version: 'v1', kind: 'PipelineRun'});
  assert.equal(config.customResourceState.enabled, true);
  assert.equal(`${resource.metricNamePrefix}_`, prefix);
  assert.deepEqual(resource.labelsFromPath, {namespace: ['metadata', 'namespace'], pipelinerun: ['metadata', 'name']});
  const paths = Object.fromEntries(resource.metrics.map((metric) => [`${prefix}${metric.name}`, metric.each.gauge.path.join('.')]));
  assert.deepEqual(paths, {tekton_pipelinerun_start_timestamp_seconds: 'status.startTime', tekton_pipelinerun_completion_timestamp_seconds: 'status.completionTime'});
  assert.deepEqual(config.rbac.extraRules, [{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['list', 'watch']}], 'the ClusterRole of kube-state-metrics reads the runs');
  const unknownSeries = (expr) => wordsWith(prefix)(expr).filter((word) => !(word in paths));
  for (const [name, file] of [['tekton', VALUES], ['image-builder', IMAGE_BUILDER_VALUES]]) {
    const expr = exprOf(rulesOf(file, name), 'PipelineRunRunningTooLong');
    assert.deepEqual(unknownSeries(expr), [], `PipelineRunRunningTooLong in ${file} names a series that kube-state-metrics does not make`);
    assert.deepEqual([...new Set(wordsWith(prefix)(expr))].sort(), Object.keys(paths).sort(), `PipelineRunRunningTooLong in ${file} reads the start and the completion series`);
  }
  assert.deepEqual(unknownSeries('time() - tekton_pipelinerun_start_time > 1800'), ['tekton_pipelinerun_start_time'], 'PLANTED DEFECT: a series name that no metric of the config makes is caught');
});
