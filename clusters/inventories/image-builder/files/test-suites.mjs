import {readFileSync, writeFileSync, chmodSync, lstatSync, realpathSync, mkdtempSync, chownSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {resolve, dirname} from 'node:path';
import {digest, emptyResult, parseNodeTAP, redact, validateBinding, validateResult} from './test-contract.mjs';

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
// The child has a different UID and cannot replace this root-owned file or
// its root-owned Tekton results directory. It receives no credential mount.
writeFileSync(resultPath, '', {mode: 0o600});
chmodSync(resultPath, 0o600);
const recipePath = resolve(source, registration.recipeFile);
for (const segment of ['deploy', registration.recipeFile]) {
  if (lstatSync(resolve(source, segment)).isSymbolicLink()) throw new Error('symbolic recipe path');
}
if (digest(readFileSync(recipePath)) !== registration.recipeDigest) throw new Error('recipe does not match reviewed bytes');

async function run(command) {
  return new Promise((finish, reject) => {
    const child = spawn(command[0], command.slice(1), {cwd: source, uid: 1001, gid: 1001,
      detached: true, env: {PATH: '/usr/local/bin:/usr/bin:/bin', HOME: childHome,
        CI: 'true', NO_COLOR: '1', DIGITA_TEST_RUN_ID: binding.pipelineRun.uid}});
    let output = '';
    let size = 0;
    let failure;
    const stop = reason => {
      failure ??= reason;
      try {process.kill(-child.pid, 'SIGKILL');} catch (error) {if (error.code !== 'ESRCH') reject(error);}
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
      // Kill orphaned children before writing trusted evidence.
      try {process.kill(-child.pid, 'SIGKILL');} catch (error) {if (error.code !== 'ESRCH') failure ??= 'could not stop suite children';}
      process.stdout.write(redact(output));
      finish({code, output, failure});
    });
  });
}

let receipt = emptyResult(binding, registration, 'not-run', 'required runtime has not run', startedAt, startedAt);
try {
  if (registration.recipe.packageManager !== 'none' || registration.recipe.runtime !== 'node' ||
      registration.recipe.dependencyRoots.length || registration.recipe.fixtures.length || registration.recipe.prepare.length) {
    throw new Error('required dependency/runtime profile is not available');
  }
  receipt.suites = [];
  receipt.notRun = [];
  for (const suite of registration.recipe.suites) {
    if (suite.kind !== 'test' || suite.command[0] !== 'node' || suite.command[1] !== '--test') {
      throw new Error('required suite adapter is not available');
    }
    const command = ['node', '--test', '--test-reporter=tap', ...suite.command.slice(2)];
    const runResult = await run(command);
    const counts = parseNodeTAP(runResult.output);
    const passed = runResult.code === 0 && !runResult.failure && counts.passed > 0 && !counts.failed && !counts.skipped;
    receipt.suites.push({name: suite.name, kind: suite.kind, status: passed ? 'passed' : 'failed', cases: counts});
    if (runResult.failure) receipt.notRun.push(runResult.failure);
  }
  receipt.result = receipt.suites.every(suite => suite.status === 'passed') && !receipt.notRun.length ? 'passed' : 'failed';
} catch (error) {
  receipt = emptyResult(binding, registration, 'infrastructure-failed', redact(error.message), startedAt, new Date().toISOString());
}
receipt.completedAt = new Date().toISOString();
const passed = validateResult(receipt, binding, registration);
writeFileSync(resultPath, JSON.stringify(receipt));
process.exitCode = passed ? 0 : 1;
