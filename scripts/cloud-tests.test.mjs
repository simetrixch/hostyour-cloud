import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, chmodSync, chownSync, statSync, rmSync, symlinkSync, existsSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {digest, emptyResult, parseNodeTAP, redact, validateResult} from '../clusters/inventories/image-builder/files/test-contract.mjs';
import {bindRun, inspect} from '../clusters/inventories/image-builder/files/test-reporter-evidence.mjs';
import {readState, writeState} from '../clusters/inventories/image-builder/files/test-reporter-state.mjs';
import {registryURL, sanitizedDependencyRoot} from '../clusters/inventories/image-builder/files/test-dependency-policy.mjs';
import {preparePackageTools} from '../clusters/inventories/image-builder/files/test-tools.mjs';
import {fetchPackages} from '../clusters/inventories/image-builder/files/test-package-fetch.mjs';
import {installToolchain} from '../clusters/inventories/image-builder/files/test-toolchain-install.mjs';

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
  const result = structuredClone(emptyResult(binding, registration, 'passed', 'unused', '2026-10-04T01:00:01Z', '2026-10-04T01:00:02Z'));
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
test('an interrupted reporter cache is rebuilt and replaced atomically', () => {
  const directory = mkdtempSync(join(tmpdir(), 'hostyour-state-'));
  try {
    const path = join(directory, 'receipt.json');
    assert.equal(readState(path), undefined);
    writeFileSync(path, '{"receipt":');
    assert.equal(readState(path), undefined);
    const record = {fingerprint: 'current', receipt: {passed: false}};
    writeState(path, record);
    assert.deepEqual(readState(path), record);
    assert.equal(statSync(path).mode & 0o777, 0o600);
    writeState(path, {...record, fingerprint: 'new'});
    assert.equal(readState(path).fingerprint, 'new');
  } finally {rmSync(directory, {recursive: true, force: true});}
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

test('dependency preparation rejects external protocols, symbolic paths and configuration packages', () => {
  const directory = mkdtempSync(join(tmpdir(), 'hostyour-dependencies-'));
  const source = join(directory, 'source'); mkdirSync(source);
  const lock = {lockfileVersion: '9.0', importers: {'.': {}}, packages: {'yaml@2.9.0': {
    resolution: {integrity: 'sha512-ZmFrZQ=='}}}, snapshots: {'yaml@2.9.0': {}}};
  const manifest = {name: 'fixture', scripts: {postinstall: 'exit 99'}, dependencies: {yaml: '2.9.0'}};
  writeFileSync(join(source, 'package.json'), JSON.stringify(manifest));
  writeFileSync(join(source, '.npmrc'), 'registry=https://attacker.invalid');
  writeFileSync(join(source, '.pnpmfile.cjs'), 'throw new Error("source hook ran")');
  const save = () => writeFileSync(join(source, 'pnpm-lock.yaml'), JSON.stringify(lock));
  try {
    save();
    const clean = join(directory, 'clean'); mkdirSync(clean);
    sanitizedDependencyRoot(source, '.', clean, JSON.parse, JSON.stringify);
    assert.deepEqual(JSON.parse(readFileSync(join(clean, 'package.json'))), {name: 'fixture', private: true});
    assert.equal(existsSync(join(clean, '.npmrc')), false);
    assert.equal(existsSync(join(clean, '.pnpmfile.cjs')), false);
    for (const url of ['http://registry.npmjs.org/a', 'https://attacker.invalid/a',
      'https://password@npm.pkg.github.com/a', 'https://npm.pkg.github.com/a?token=credential']) assert.throws(() => registryURL(url));
    lock.packages['yaml@2.9.0'].resolution.tarball = 'https://attacker.invalid/fake.tgz'; save();
    assert.throws(() => sanitizedDependencyRoot(source, '.', clean, JSON.parse, JSON.stringify), /URL/);
    delete lock.packages['yaml@2.9.0'].resolution.tarball;
    lock.configDependencies = {evil: '1.0.0'}; save();
    assert.throws(() => sanitizedDependencyRoot(source, '.', clean, JSON.parse, JSON.stringify), /lock shape/);
    delete lock.configDependencies; save();
    manifest.dependencies.yaml = 'git+ssh://attacker.invalid/evil';
    writeFileSync(join(source, 'package.json'), JSON.stringify(manifest));
    assert.throws(() => sanitizedDependencyRoot(source, '.', clean, JSON.parse, JSON.stringify), /protocol/);
    rmSync(join(source, 'package.json')); symlinkSync(join(directory, 'outside.json'), join(source, 'package.json'));
    assert.throws(() => sanitizedDependencyRoot(source, '.', clean, JSON.parse, JSON.stringify), /symbolic/);
  } finally {rmSync(directory, {recursive: true, force: true});}
});

test('pinned pnpm fetches a public locked package without executing source hooks or copying reader credentials', async () => {
  // Public Actions only: this is the real downloader/PNPM integration, not a
  // local test. The placeholder reader can authenticate no private package.
  const directory = mkdtempSync(join(tmpdir(), 'hostyour-fetch-'));
  try {
    const source = join(directory, 'source'); const deps = join(directory, 'deps');
    mkdirSync(source); mkdirSync(deps);
    writeFileSync(join(source, 'package.json'), JSON.stringify({name: 'fixture', private: true,
      packageManager: 'pnpm@99.0.0', scripts: {postinstall: 'exit 99'}, dependencies: {yaml: '2.9.0'}}));
    writeFileSync(join(source, '.pnpmfile.cjs'), 'throw new Error("source hook ran")');
    writeFileSync(join(source, '.npmrc'), 'registry=https://attacker.invalid');
    writeFileSync(join(source, 'pnpm-workspace.yaml'), JSON.stringify({configDependencies: {evil: '1.0.0'},
      pnpmfile: '.pnpmfile.cjs', allowBuilds: {'*': true}, packages: ['.']}));
    const integrity = 'sha512-2AvhNX3mb8zd6Zy7INTtSpl1F15HW6Wnqj0srWlkKLcpYl/gMIMJiyuGq2KeI2YFxUPjdlB+3Lc10seMLtL4cA==';
    writeFileSync(join(source, 'pnpm-lock.yaml'), JSON.stringify({lockfileVersion: '9.0',
      settings: {autoInstallPeers: true, excludeLinksFromLockfile: false},
      importers: {'.': {dependencies: {yaml: {specifier: '2.9.0', version: '2.9.0'}}}},
      packages: {'yaml@2.9.0': {resolution: {integrity}}}, snapshots: {'yaml@2.9.0': {}}}));
    const reader = join(directory, 'reader');
    writeFileSync(reader, '@digitaplatform:registry=https://npm.pkg.github.com\n//npm.pkg.github.com/:_authToken=fixture-reader-with-no-grant\n', {mode: 0o600});
    await preparePackageTools(join(deps, 'tools'));
    const fetched = await fetchPackages(source, ['.'], deps, reader);
    assert.ok(fetched.connections > 0, 'pinned PNPM actually uses the host-restricted HTTPS proxy');
    assert.equal(existsSync(join(deps, '.npmrc')), false);
    assert.equal(existsSync(join(deps, 'store')), true);
    assert.equal(JSON.parse(readFileSync(join(deps, 'tools/pnpm/package.json'))).version, '11.7.0');
  } finally {rmSync(directory, {recursive: true, force: true});}
});

test('fixed Vitest counts real cases under UID1001 and ignores source test scripts and configuration', async () => {
  assert.equal(process.getuid(), 0, 'this fixture runs only on the public Actions runner');
  const directory = mkdtempSync(join(tmpdir(), 'hostyour-vitest-'));
  try {
    chmodSync(directory, 0o755);
    const deps = join(directory, 'deps'); mkdirSync(deps);
    const source = join(directory, 'source'); mkdirSync(source); mkdirSync(join(source, 'tests'));
    const protectedDirectory = join(directory, 'protected'); mkdirSync(protectedDirectory, {mode: 0o700});
    const result = join(protectedDirectory, 'result.json');
    const cache = join(protectedDirectory, 'cache'); mkdirSync(cache, {mode: 0o700});
    const reader = join(directory, 'reader');
    writeFileSync(reader, '@digitaplatform:registry=https://npm.pkg.github.com\n//npm.pkg.github.com/:_authToken=fixture-reader-with-no-grant\n', {mode: 0o600});
    await preparePackageTools(join(deps, 'tools'));
    await installToolchain(deps, resolve('clusters/inventories/image-builder/files/test-toolchain'), reader);
    writeFileSync(join(source, 'package.json'), JSON.stringify({type: 'module', scripts: {test: 'echo 9999 passed'}}));
    writeFileSync(join(source, 'vitest.config.ts'), 'throw new Error("untrusted configuration executed")');
    writeFileSync(join(source, 'postcss.config.js'), 'throw new Error("untrusted CSS configuration executed")');
    const runController = () => execFileSync(process.execPath, [resolve('clusters/inventories/image-builder/files/test-vitest-controller.mjs')], {
      timeout: 60000, stdio: 'pipe', env: {PATH: process.env.PATH, HOME: directory, CI: 'true', NO_COLOR: '1',
        TEST_PACKAGE_ROOT: source, TEST_TOOLCHAIN: join(deps, 'toolchain'), TEST_VITEST_RESULT: result,
        TEST_TRUSTED_CACHE: cache, TEST_SUITE_PROFILE: JSON.stringify({include: ['tests/**/*.test.ts']}),
        TEST_WORKER_ENVIRONMENT: JSON.stringify({CI: 'true', HOME: directory})}});
    writeFileSync(join(source, 'tests/proof.test.ts'), `import {test,expect} from 'vitest';\nimport {writeFileSync} from 'node:fs';\ntest('UID and protected evidence',()=>{expect(process.getuid()).toBe(1001);expect(()=>writeFileSync(${JSON.stringify(result)},'forged')).toThrow(); console.log('9999 passed');});\n`);
    runController();
    assert.deepEqual(JSON.parse(readFileSync(result, 'utf8')), {passed: 1, failed: 0, skipped: 0});
    assert.equal(statSync(result).uid, 0);
    for (const testCode of ["test('failing',()=>{expect(1).toBe(2)})", "test.skip('skipped',()=>{})", '']) {
      writeFileSync(result, '');
      writeFileSync(join(source, 'tests/proof.test.ts'), "import {test,expect} from 'vitest';\n" + testCode);
      assert.throws(runController, 'zero, skipped and failed cases cannot turn fake script stdout into success');
    }
  } finally {rmSync(directory, {recursive: true, force: true});}
});
