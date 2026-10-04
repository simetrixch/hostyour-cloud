import {readFileSync, writeFileSync, chmodSync, lstatSync, realpathSync, mkdtempSync, chownSync, mkdirSync, globSync, readdirSync, existsSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {digest, emptyResult, parseNodeTAP, redact, validateBinding, validateResult} from './test-contract.mjs';
import {suiteProfile, fixtureProfile} from './test-suite-profiles.mjs';
import {sourceFile} from './test-dependency-policy.mjs';

const registration = JSON.parse(process.env.TEST_REGISTRATION);
const binding = {repositoryURL: process.env.TEST_REPOSITORY_URL, ref: process.env.TEST_REF,
  commit: process.env.TEST_COMMIT, recipeDigest: process.env.TEST_RECIPE_DIGEST,
  runnerDigest: process.env.TEST_RUNNER_DIGEST,
  pipelineRun: {name: process.env.TEST_RUN_NAME, namespace: process.env.TEST_RUN_NAMESPACE, uid: process.env.TEST_RUN_UID}};
validateBinding(binding, registration);
const startedAt = new Date().toISOString();
const source = realpathSync(process.env.TEST_SOURCE);
const resultPath = process.env.TEST_RESULT_PATH;
chownSync(dirname(resultPath), 0, 0);
chmodSync(dirname(resultPath), 0o755);
chmodSync('/tmp', 0o1777);
const childHome = mkdtempSync('/tmp/untrusted-');
chownSync(childHome, 1001, 1001);
const trustedScratch = mkdtempSync('/tmp/trusted-results-');
chmodSync(trustedScratch, 0o700);
mkdirSync(resolve(trustedScratch, 'cache'), {mode: 0o700});
const dependencies = process.env.TEST_DEPENDENCIES && realpathSync(process.env.TEST_DEPENDENCIES);
const environment = {PATH: (dependencies ? resolve(dependencies, 'bin') + ':' : '') + '/usr/local/bin:/usr/bin:/bin',
  HOME: childHome, CI: 'true', NO_COLOR: '1', DIGITA_TEST_RUN_ID: binding.pipelineRun.uid,
  GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', NPM_CONFIG_USERCONFIG: '/dev/null',
  NPM_CONFIG_GLOBALCONFIG: '/dev/null', MONGOMS_RUNTIME_DOWNLOAD: 'false'};
const profile = fixtureProfile(registration);
const fixtures = process.env.TEST_FIXTURES && realpathSync(process.env.TEST_FIXTURES);
if (registration.name === 'digita-platform') {
  if (!fixtures) throw new Error('required immutable fixtures are missing');
  environment.CATALOG_DIRS = ['digita-catalog', 'digita-catalog-show', 'digita-catalog-simetrix'].map(name => resolve(fixtures, name)).join(':');
}
if (profile !== 'node') environment.DIGITA_TEST_MONGODB_URI = 'mongodb://127.0.0.1:27017/?replicaSet=rs0&directConnection=true';
if (profile === 'mongo-redis') environment.AUTH_TEST_REDIS_URI = 'redis://127.0.0.1:6379';
if (profile === 'report') {
  environment.REPORT_CHROMIUM_PATH = '/usr/bin/chromium-browser';
  environment.REPORT_CHROMIUM_ARGS = '--no-sandbox,--disable-dev-shm-usage';
}
// The child has a different UID and cannot replace this root-owned file or
// its root-owned Tekton results directory. It receives no credential mount.
writeFileSync(resultPath, '', {mode: 0o600});
chmodSync(resultPath, 0o600);
const recipePath = resolve(source, registration.recipeFile);
for (const segment of ['deploy', registration.recipeFile]) {
  if (lstatSync(resolve(source, segment)).isSymbolicLink()) throw new Error('symbolic recipe path');
}
if (digest(readFileSync(recipePath)) !== registration.recipeDigest) throw new Error('recipe does not match reviewed bytes');

async function run(command, cwd = source, extraEnvironment = {}, collectEvidence = false) {
  return new Promise((finish, reject) => {
    const child = spawn(command[0], command.slice(1), {cwd, uid: 1001, gid: 1001,
      detached: true, stdio: collectEvidence ? ['ignore', 'pipe', 'pipe', 'pipe'] : ['ignore', 'pipe', 'pipe'],
      env: {...environment, ...extraEnvironment}});
    let output = '';
    let evidence = '';
    if (collectEvidence) child.stdio[3].on('data', bytes => {
      if (Buffer.byteLength(evidence) + bytes.length > 4096) stop('controller evidence exceeded its size budget');
      else evidence += bytes.toString();
    });
    let size = 0;
    let failure;
    let killTimer;
    const stop = reason => {
      failure ??= reason;
      try {process.kill(-child.pid, 'SIGKILL');} catch (error) {if (error.code !== 'ESRCH') reject(error);}
      killTimer ??= setTimeout(() => {
        child.stdout.destroy(); child.stderr.destroy();
        finish({code: 1, output, failure});
      }, 2000);
    };
    const timer = setTimeout(() => stop('suite exceeded its time budget'), 20 * 60 * 1000);
    const collect = bytes => {
      size += bytes.length;
      if (size > 4 * 1024 * 1024) stop('suite output exceeded its size budget');
      else output += bytes.toString();
    };
    child.stdout.on('data', collect); child.stderr.on('data', collect);
    child.on('error', error => {clearTimeout(timer); reject(error);});
    child.on('close', code => {
      clearTimeout(timer);
      clearTimeout(killTimer);
      // Kill orphaned children before writing trusted evidence.
      try {process.kill(-child.pid, 'SIGKILL');} catch (error) {if (error.code !== 'ESRCH') failure ??= 'could not stop suite children';}
      process.stdout.write(redact(output));
      finish({code, output, failure, evidence});
    });
  });
}

let receipt = emptyResult(binding, registration, 'not-run', 'required runtime has not run', startedAt, startedAt);
try {
  if (!['none', 'pnpm@11.7.0'].includes(registration.recipe.packageManager) ||
      process.env.TEST_FIXTURE_PROFILE !== profile) {
    throw new Error('required dependency/runtime profile is not available');
  }
  const pnpm = dependencies && [process.execPath, resolve(dependencies, 'tools/pnpm/bin/pnpm.cjs')];
  if (registration.recipe.packageManager === 'pnpm@11.7.0') {
    if (!pnpm) throw new Error('required locked package store is missing');
    // Only the credential-free store is copied to child-owned scratch. Tools
    // and the fixed test controller remain on the read-only root-owned mount.
    const copy = await run([process.execPath, '-e',
      'require("node:fs").cpSync(process.argv[1],process.argv[2],{recursive:true})',
      resolve(dependencies, 'store'), resolve(childHome, 'store')]);
    if (copy.code || copy.failure) throw new Error('offline store copy failed');
    for (const root of registration.recipe.dependencyRoots) {
      const install = await run([...pnpm, 'install', '--offline', '--frozen-lockfile', '--ignore-scripts', '--ignore-pnpmfile',
        '--store-dir', resolve(childHome, 'store'), '--config.manage-package-manager-versions=false',
        '--config.package-manager-strict=false'], resolve(source, root));
      if (install.code || install.failure) throw new Error('required offline dependency install failed');
    }
  } else if (registration.recipe.dependencyRoots.length) throw new Error('unexpected dependency roots');
  for (const prepare of registration.recipe.prepare) {
    if (!pnpm || JSON.stringify(prepare.command) !== '["pnpm","build"]') throw new Error('required preparation adapter is unavailable');
    const built = await run([...pnpm, 'build']);
    if (built.code || built.failure) throw new Error('required source preparation failed');
  }
  // Capture is a preparation artifact, never a passing golden comparison.
  // The runner remains alive briefly for authenticated, read-only retrieval;
  // PDF bytes and document contents are never printed into its logs.
  if (registration.name === 'digita-report') {
    const fixtures = readdirSync(resolve(source, 'backend/tests/golden/fixtures')).filter(file => file.endsWith('.json')).sort();
    if (!fixtures.length || fixtures.length > 100) throw new Error('required golden corpus is empty or oversized');
    for (const file of fixtures) sourceFile(source, 'backend/tests/golden/fixtures/' + file);
    const missing = fixtures.some(file => !existsSync(resolve(source, 'backend/tests/golden/__baselines__', file.replace(/\.json$/, '.pdf'))));
    if (missing) {
      const captured = await run([process.execPath, '--import', resolve(dependencies, 'toolchain/node_modules/tsx/dist/loader.mjs'),
        resolve(source, 'backend/scripts/golden-pdf.ts'), '--update'], resolve(source, 'backend'));
      if (captured.code || captured.failure) throw new Error('golden baseline artifact capture failed');
      for (const file of fixtures) {
        const path = sourceFile(source, 'backend/tests/golden/__baselines__/' + file.replace(/\.json$/, '.pdf'));
        const bytes = readFileSync(path);
        if (!bytes.subarray(0, 5).equals(Buffer.from('%PDF-')) || bytes.length > 1024 * 1024) throw new Error('golden capture is not a bounded PDF');
        console.log('GOLDEN CAPTURE READY ' + file + ' ' + digest(bytes));
      }
      await new Promise(done => setTimeout(done, 15 * 60 * 1000));
      throw new Error('golden baseline captured for review only; no normal comparison or required suites have passed');
    }
  }
  receipt.suites = [];
  receipt.notRun = [];
  for (const suite of registration.recipe.suites) {
    let counts = {passed: 0, failed: 0, skipped: 0};
    let passed = true;
    for (const profile of suiteProfile(registration, suite)) {
      const root = realpathSync(resolve(source, profile.path));
      if (root !== source && !root.startsWith(source + '/')) throw new Error('suite path escaped source');
      if (registration.name === 'digita-platform' && ['packages/engine', 'packages/app', 'packages/web'].includes(profile.path)) {
        environment.TRANSLATIONS_DIR = resolve(fixtures, 'digita-translations/translations/digita-' + profile.path.split('/')[1]);
      }
      let runResult;
      let counted;
      if (profile.adapter === 'static') {
      if (suite.command.length !== 2 || suite.command[0] !== 'bash' || suite.command[1] !== 'scripts/check.sh') {
        throw new Error('required static adapter is not available');
      }
        runResult = await run(profile.command, root);
        counted = {passed: runResult.code === 0 && !runResult.failure ? 1 : 0, failed: runResult.code || runResult.failure ? 1 : 0, skipped: 0};
      } else if (profile.adapter === 'node') {
        const files = profile.files.flatMap(pattern => globSync(pattern, {cwd: root})).sort();
        if (!files.length || profile.files.some(pattern => !globSync(pattern, {cwd: root}).length)) throw new Error('required Node test files are missing');
        runResult = await run([process.execPath, '--test', '--test-reporter=tap', ...files], root);
        counted = parseNodeTAP(runResult.output);
      } else if (profile.adapter === 'golden') {
        const files = readdirSync(resolve(root, 'tests/golden/fixtures')).filter(file => file.endsWith('.json'));
        if (!files.length || files.length > 100) throw new Error('required golden corpus is empty or oversized');
        for (const file of files) sourceFile(source, 'backend/tests/golden/__baselines__/' + file.replace(/\.json$/, '.pdf'));
        runResult = await run([process.execPath, '--import', resolve(dependencies, 'toolchain/node_modules/tsx/dist/loader.mjs'),
          resolve(root, 'scripts/golden-pdf.ts')], root);
        counted = {passed: runResult.code === 0 && !runResult.failure ? files.length : 0,
          failed: runResult.code || runResult.failure ? files.length : 0, skipped: 0};
      } else if (profile.adapter === 'vitest') {
        // Source can manipulate its own framework RPC; do not activate
        // positive receipts until the owner decides this trust boundary.
        throw new Error('Vitest result trust boundary is awaiting owner approval');
      } else throw new Error('required suite adapter is unavailable');
      for (const key of ['passed', 'failed', 'skipped']) counts[key] += counted[key];
      passed &&= runResult.code === 0 && !runResult.failure && counted.passed > 0 && !counted.failed && !counted.skipped;
      if (runResult.failure) receipt.notRun.push(runResult.failure);
    }
    receipt.suites.push({name: suite.name, kind: suite.kind, status: passed ? 'passed' : 'failed', cases: counts});
  }
  receipt.result = receipt.suites.every(suite => suite.status === 'passed') && !receipt.notRun.length ? 'passed' : 'failed';
} catch (error) {
  receipt = emptyResult(binding, registration, 'infrastructure-failed', redact(error.message), startedAt, new Date().toISOString());
}
receipt.completedAt = new Date().toISOString();
const passed = validateResult(receipt, binding, registration);
writeFileSync(resultPath, JSON.stringify(receipt));
process.exitCode = passed ? 0 : 1;
