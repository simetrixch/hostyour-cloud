import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// Loki is the sink of every access log the ingress writes, so what it keeps is bounded: a retention
// period that is set, finite and not zero (zero keeps everything), and the compactor that enforces
// it, which ignores the period while retention_enabled is off. No stage file may lift either.

const DIR = 'clusters/inventories/observability';
const STAGES = ['dev', 'test', 'prod'];
const read = file => JSON.parse(execFileSync('yq', ['-o=json', '.', file], {encoding: 'utf8'}));
const HOURS = {h: 1, d: 24, w: 168};

/** Every way [values] keep logs without bound, named, for the stage [stage]. */
function findings(common, stages) {
  const found = [];
  for (const stage of STAGES) {
    const merged = structuredClone(common.loki?.loki ?? {});
    for (const [section, fields] of Object.entries(stages[stage]?.loki?.loki ?? {})) merged[section] = {...merged[section], ...fields};
    const period = String(merged.limits_config?.retention_period ?? '');
    const [, amount, unit] = period.match(/^(\d+)([hdw])$/) ?? [];
    if (!amount || Number(amount) === 0) found.push(`${stage}: retention_period ${period || 'unset'} keeps every log`);
    else if (Number(amount) * HOURS[unit] > 336) found.push(`${stage}: retention_period ${period} is past the 14 days the access logs are kept`);
    if (merged.compactor?.retention_enabled !== true) found.push(`${stage}: the compactor does not enforce the retention period`);
  }
  return found;
}

const common = read(`${DIR}/values-common.yaml`);
const stages = Object.fromEntries(STAGES.map(stage => [stage, read(`${DIR}/values-${stage}.yaml`)]));

test('Loki keeps logs at most 14 days on every stage, and its compactor enforces it', () => {
  assert.deepEqual(findings(common, stages), []);
});

test('PLANTED DEFECT: retention off, zero, unset, too long or lifted by a stage is caught', () => {
  const change = edit => { const copy = structuredClone(common); edit(copy.loki.loki); return copy; };
  for (const [name, values, perStage] of [
    ['retention off', change(l => { l.compactor.retention_enabled = false; }), stages],
    ['zero', change(l => { l.limits_config.retention_period = '0s'; }), stages],
    ['unset', change(l => { delete l.limits_config.retention_period; }), stages],
    ['a year', change(l => { l.limits_config.retention_period = '52w'; }), stages],
    ['prod lifts it', common, {...stages, prod: {loki: {loki: {compactor: {retention_enabled: false}}}}}],
  ]) assert.notDeepEqual(findings(values, perStage), [], name);
});
