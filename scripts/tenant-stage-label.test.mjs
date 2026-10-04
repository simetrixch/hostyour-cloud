import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

const yaml = (expression, input) => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input, encoding: 'utf8'}));
const template = JSON.parse(execFileSync('yq', ['-o=json', '.spec.templatePatch', 'clusters/argocd/files/tenants-appset.yaml'], {encoding: 'utf8'}));
const end = template.indexOf('\n  sources:');
assert.ok(end > 0, 'read the actual namespace patch before its chart sources');
const namespacePatch = template.slice(0, end);

function labels(stage, extra = {}, patch = namespacePatch) {
  const chart = mkdtempSync(join(tmpdir(), 'tenant-stage-label-'));
  try {
    mkdirSync(join(chart, 'templates'));
    writeFileSync(join(chart, 'Chart.yaml'), 'apiVersion: v2\nname: stage-label\nversion: 0.0.0\n');
    writeFileSync(join(chart, 'templates', 'namespace.yaml'), '{{ tpl .Values.patch (merge .Values.registration (dict "Template" .Template)) }}');
    writeFileSync(join(chart, 'values.yaml'), JSON.stringify({patch, registration: {values: {guid: 'abc123def456', stage}, namespaceLabels: extra}}));
    const rendered = execFileSync('helm', ['template', 'stage-label', chart], {encoding: 'utf8'});
    return yaml('.spec.syncPolicy.managedNamespaceMetadata.labels', rendered);
  } finally {
    rmSync(chart, {recursive: true, force: true});
  }
}

test('the actual ApplicationSet labels every tenant stage and ignores a forged stage override', () => {
  for (const stage of ['dev', 'test', 'prod']) {
    const got = labels(stage, {'platform/tenant-stage': 'foreign', 'platform/redis-consumer': 'true'});
    assert.equal(got['platform/tenant-stage'], stage);
    assert.equal(got['platform/tenant'], 'abc123def456');
    assert.equal(got['platform/tenant-managed'], 'true');
    assert.equal(got['platform/redis-consumer'], 'true');
  }
  const missing = namespacePatch.replace(/^\s*platform\/tenant-stage:.*\n/m, '\n');
  assert.notEqual(labels('test', {}, missing)['platform/tenant-stage'], 'test');
});

test('the rendered consumer boundary refuses tenant-stage labels on its own namespace', () => {
  const rendered = execFileSync('helm', ['template', 'acme-test', 'clusters/units/admissionpolicy', '--namespace', 'acme-test',
    '--set', 'registration.name=acme', '--set', 'registration.stage=test', '--set', 'registration.host=acme.test.example'], {encoding: 'utf8'});
  const policy = yaml('select(.kind == "ValidatingAdmissionPolicy")', rendered);
  const clause = policy.spec.validations.find(value => value.message.includes('namespace may carry no label'));
  assert.ok(clause);
  const js = clause.expression.replaceAll(' == ', ' === ').replaceAll(' != ', ' !== ')
    .replace(/has\(([^)]+)\)/g, '($1 !== undefined)')
    .replace(/object\.metadata\.labels\.all\(k, /g, 'Object.keys(object.metadata.labels).every(k => ');
  const evaluate = new Function('request', 'object', `return (${js});`);
  const request = {resource: {resource: 'namespaces'}};
  const object = {metadata: {name: 'acme-test', annotations: {'argocd.argoproj.io/tracking-id': 'acme-test:/Namespace:/acme-test'}, labels: {'hostyour.cloud/consumer': 'true'}}};
  assert.equal(evaluate(request, object), true);
  object.metadata.labels['platform/tenant-stage'] = 'test';
  assert.equal(evaluate(request, object), false);
});
