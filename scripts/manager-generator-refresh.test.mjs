import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';

const rendered = execFileSync('helm', ['template', 'manager', 'clusters/inventories/manager', '--namespace', 'manager',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
  '-f', 'clusters/inventories/manager/values-common.yaml', '-f', 'clusters/inventories/manager/values-prod.yaml',
  '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml'], {encoding: 'utf8'});
const select = expression => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input: rendered, encoding: 'utf8'}));
const name = 'manager-tenant-generator-refresh';
const role = select('select(.kind == "ClusterRole" and .metadata.name == "' + name + '")');
const exactRule = {apiGroups: ['argoproj.io'], resources: ['applicationsets'], resourceNames: ['tenants', 'consumer-apps'], verbs: ['patch']};
const check = rule => {
  assert.deepEqual(Object.keys(rule).sort(), Object.keys(exactRule).sort());
  for (const key of Object.keys(exactRule)) assert.deepEqual(rule[key], exactRule[key]);
};
test('the rendered role grants only the approved named generator patch to the existing Manager SA', () => {
  assert.equal(role.rules.length, 1); check(role.rules[0]);
  const binding = select('select(.kind == "ClusterRoleBinding" and .metadata.name == "' + name + '")');
  assert.deepEqual(binding.roleRef, {apiGroup: 'rbac.authorization.k8s.io', kind: 'ClusterRole', name});
  assert.deepEqual(binding.subjects, [{kind: 'ServiceAccount', name: 'manager', namespace: 'manager'}]);
  const existing = select('select(.kind == "ClusterRole" and .metadata.name == "manager-argocd-onboarding")');
  assert.ok(existing.rules.some(rule => rule.resources.includes('applications') && rule.verbs.includes('patch')));
});
test('planted broader verbs, resources, names and a missing name fence are refused', () => {
  for (const change of [{verbs: ['get', 'patch']}, {verbs: ['list', 'patch']}, {resources: ['applicationsets', 'secrets']},
    {resourceNames: ['*']}, {resourceNames: ['other-generator']}]) assert.throws(() => check({...exactRule, ...change}));
  const missing = {...exactRule}; delete missing.resourceNames; assert.throws(() => check(missing));
});
