import {execFileSync} from 'node:child_process';
import {copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// The master's log alerts as the observability chart renders them: templates/loki-rules.yaml alone, in a chart of its
// own, because the chart's dependencies are fetched at deploy and are not in the tree, and this template reads none of them.
export function renderLokiRules() {
  const chart = mkdtempSync(join(tmpdir(), 'loki-rules-'));
  try {
    mkdirSync(join(chart, 'templates'));
    writeFileSync(join(chart, 'Chart.yaml'), 'apiVersion: v2\nname: observability\nversion: 1.0.0\n');
    copyFileSync('clusters/inventories/observability/templates/loki-rules.yaml', join(chart, 'templates/loki-rules.yaml'));
    const out = execFileSync('helm', ['template', 'observability', chart, '--namespace', 'observability'], {encoding: 'utf8'});
    return JSON.parse(execFileSync('yq', ['ea', '-o=json', '[select(. != null)]', '-'], {encoding: 'utf8', input: out}));
  } finally {
    rmSync(chart, {recursive: true, force: true});
  }
}
