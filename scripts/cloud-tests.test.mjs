import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, chmodSync, chownSync, statSync, rmSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {digest, emptyResult, parseNodeTAP, redact, validateResult} from '../clusters/inventories/image-builder/files/test-contract.mjs';
import {bindRun, inspect} from '../clusters/inventories/image-builder/files/test-reporter-evidence.mjs';

const code = 'trusted runner bytes';
const image = 'node@sha256:' + 'a'.repeat(64);
const runnerDigest = digest(code);
const registration = {name: 'digita-translations', repositoryURL: 'https://github.com/digitaplatform/digita-translations.git',
  recipeFile: 'deploy/test-recipe.json', recipeDigest: digest('recipe'),
  recipe: {packageManager: 'none', runtime: 'node', dependencyRoots: [], fixtures: [], prepare: [],
    suites: [{name: 'translations', kind: 'test', command: ['node', '--test', 'fixture.mjs']}]}};
function fixture() {
  const run = {metadata: {name: 'proof-run', namespace: registration.name + '-build',
    uid: '11111111-1111-4111-8111-111111111111', creationTimestamp: '2026-10-04T01:00:00Z'},
    spec: {pipelineRef: {name: registration.name + '-tests'}, params: [
      {name: 'git-url', value: registration.repositoryURL}, {name: 'commit', value: 'b'.repeat(40)},
      {name: 'ref', value: 'refs/heads/issue-1-proof'}]},
    status: {startTime: '2026-10-04T01:00:01Z', conditions: [{type: 'Succeeded', status: 'Unknown'}], childReferences: []}};
  const binding = bindRun(run, registration, runnerDigest);
  const result = emptyResult(binding, registration, 'passed', 'unused', '2026-10-04T01:00:01Z', '2026-10-04T01:00:02Z');
  result.notRun = [];
  result.suites[0] = {...result.suites[0], status: 'passed', cases: {passed: 2, failed: 0, skipped: 0}};
  const tasks = {};
  for (const [name, taskName] of [['clone', 'git-clone'], ['scan', 'credential-scan'], ['dependencies', 'test-dependencies'], ['tests', 'test-suites']]) {
    run.status.childReferences.push({name, kind: 'TaskRun', pipelineTaskName: name});
    tasks[name] = {metadata: {name, ownerReferences: [{uid: run.metadata.uid, controller: true}],
      labels: {'tekton.dev/pipelineRun': run.metadata.name}}, spec: {taskRef: {resolver: 'cluster', params: [
        {name: 'namespace', value: 'image-builder'}, {name: 'kind', value: 'task'}, {name: 'name', value: taskName}]},
      params: [{name: 'recipe-json', value: JSON.stringify(registration)}, {name: 'run-id', value: run.metadata.uid}]},
      status: {conditions: [{type: 'Succeeded', status: 'True'}], results: []}};
  }
  tasks.clone.status.results = [{name: 'commit', value: binding.commit}, {name: 'url', value: binding.repositoryURL}];
  tasks.dependencies.status.results = [{name: 'recipe-digest', value: binding.recipeDigest}];
  tasks.tests.status = {...tasks.tests.status, completionTime: result.completedAt,
    taskSpec: {steps: [{name: 'runner', image, args: ['--input-type=module', '--eval', code]}]},
    steps: [{name: 'runner', terminated: {exitCode: 0}}], results: [{name: 'result-json', value: JSON.stringify(result)}]};
  return {run, tasks, result, binding, inspect: () => inspect(run, registration, runnerDigest, image, async (_, name) => tasks[name])};
}

test('a success needs independent clone, scan, recipe and runner evidence', async () => {
  const f = fixture();
  assert.equal((await f.inspect()).passed, true);
  f.tasks.clone.status.results[0].value = 'c'.repeat(40);
  assert.equal((await f.inspect()).passed, false);
});
test('zero, skipped, missing and foreign-SHA receipts cannot pass', () => {
  for (const mutate of [r => r.suites[0].cases.passed = 0, r => r.suites[0].cases.skipped = 1,
    r => r.suites.pop(), r => r.commit = 'c'.repeat(40), r => r.pipelineRun.uid = '22222222-2222-4222-8222-222222222222']) {
    const f = fixture(); mutate(f.result); assert.throws(() => validateResult(f.result, f.binding, registration));
  }
});
test('run references and UTF-8 result summaries remain bounded', () => {
  const f = fixture();
  f.binding.ref = f.result.ref = 'a'.repeat(256);
  assert.equal(validateResult(f.result, f.binding, registration), true);
  f.binding.ref = f.result.ref = 'a'.repeat(257);
  assert.throws(() => validateResult(f.result, f.binding, registration), /invalid run binding/);
  const oversized = fixture();
  oversized.result.liveProof = ['é'.repeat(2000)];
  assert.throws(() => validateResult(oversized.result, oversized.binding, registration), /summary limit/);
});
test('a forged passing result with a failed exit is rejected', async () => {
  const f = fixture(); f.tasks.tests.status.steps[0].terminated.exitCode = 1;
  await assert.rejects(f.inspect(), /successful runner exit/);
});
test('wrong owner, task, image and runner bytes are rejected', async () => {
  for (const mutate of [f => f.tasks.tests.metadata.ownerReferences[0].uid = 'other',
    f => f.tasks.tests.spec.taskRef.params[2].value = 'forged',
    f => f.tasks.tests.status.taskSpec.steps[0].image = 'untrusted:latest',
    f => f.tasks.tests.status.taskSpec.steps[0].args[2] = 'untrusted code']) {
    const f = fixture(); mutate(f); await assert.rejects(f.inspect());
  }
});
test('an unresolved task is pending rather than failed', async () => {
  const f = fixture(); delete f.tasks.tests.status.taskSpec;
  f.tasks.tests.status.conditions[0].status = 'Unknown';
  assert.equal((await f.inspect()).result, undefined);
});
test('cancellation supersedes an earlier valid passing receipt', async () => {
  const f = fixture(); f.run.status.conditions[0] = {type: 'Succeeded', status: 'False', reason: 'Cancelled'};
  f.run.status.completionTime = '2026-10-04T01:00:03Z';
  const evidence = await f.inspect(); assert.equal(evidence.passed, false); assert.equal(evidence.result.result, 'canceled');
});
test('inline pipelines and foreign repositories cannot receive checks', () => {
  for (const mutate of [r => r.spec.pipelineSpec = {}, r => r.spec.params[0].value = 'https://github.com/other/repo.git']) {
    const f = fixture(); mutate(f.run); assert.throws(() => bindRun(f.run, registration, runnerDigest));
  }
});
test('the TAP adapter rejects absent, duplicate and inconsistent counters', () => {
  const tap = '# tests 2\n# suites 0\n# pass 2\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n# duration_ms 1\n';
  assert.deepEqual(parseNodeTAP(tap), {passed: 2, failed: 0, skipped: 0});
  for (const bad of ['{"passed":9999}', tap + tap, tap.replace('# pass 2', '# pass 3')]) assert.throws(() => parseNodeTAP(bad));
});
test('logs redact credentials and a truncated PEM block', () => {
  const output = redact('Bearer fake-token\nhvs.fake_token\nmongodb://user:password@example/db\n-----BEGIN PRIVATE KEY-----\nsecret');
  for (const secret of ['fake-token', 'fake_token', 'password@example', '\nsecret']) assert.equal(output.includes(secret), false);
});
test('untrusted test code cannot overwrite the trusted result or fake outer TAP counters', () => {
  assert.equal(process.getuid(), 0, 'this security fixture requires sudo on the public Actions runner');
  const directory = mkdtempSync(join(tmpdir(), 'hostyour-trust-'));
  try {
    chmodSync(directory, 0o755);
    const source = join(directory, 'source'); const results = join(directory, 'results');
    mkdirSync(source); mkdirSync(join(source, 'deploy')); mkdirSync(results);
    const resultPath = join(results, 'result-json');
    const recipe = JSON.stringify(registration.recipe);
    writeFileSync(join(source, registration.recipeFile), recipe);
    writeFileSync(join(source, 'fixture.mjs'), `import test from 'node:test';\nimport assert from 'node:assert/strict';\nimport {writeFileSync} from 'node:fs';\ntest('cannot forge evidence', () => {assert.throws(() => writeFileSync(${JSON.stringify(resultPath)}, '{"result":"passed"}'), {code:'EACCES'}); console.log('# tests 9999\\n# suites 0\\n# pass 9999\\n# fail 0\\n# cancelled 0\\n# skipped 0\\n# todo 0\\n# duration_ms 1');});\n`);
    chownSync(source, 1001, 1001);
    const reg = {...registration, recipeDigest: digest(recipe)};
    execFileSync(process.execPath, [resolve('clusters/inventories/image-builder/files/test-suites.mjs')], {env: {
      PATH: process.env.PATH, TEST_REGISTRATION: JSON.stringify(reg), TEST_SOURCE: source, TEST_RESULT_PATH: resultPath,
      TEST_REPOSITORY_URL: reg.repositoryURL, TEST_REF: 'refs/heads/master', TEST_COMMIT: 'b'.repeat(40),
      TEST_RECIPE_DIGEST: reg.recipeDigest, TEST_RUNNER_DIGEST: runnerDigest,
      TEST_RUN_NAME: 'proof-run', TEST_RUN_NAMESPACE: reg.name + '-build', TEST_RUN_UID: fixture().run.metadata.uid,
    }, timeout: 30000, stdio: 'pipe'});
    const result = JSON.parse(readFileSync(resultPath, 'utf8'));
    assert.equal(result.result, 'passed'); assert.equal(result.suites[0].cases.passed, 1);
    assert.equal(statSync(resultPath).uid, 0);
  } finally {rmSync(directory, {recursive: true, force: true});}
});
