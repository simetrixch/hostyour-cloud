import {readFileSync, writeFileSync, lstatSync, realpathSync, rmSync, readdirSync, lchownSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
import {digest, isCommit, isUID} from './test-contract.mjs';

const registration = JSON.parse(process.env.TEST_REGISTRATION);
const source = realpathSync(process.env.TEST_SOURCE);
if (registration.repositoryURL !== process.env.TEST_REPOSITORY_URL || !isCommit(process.env.TEST_COMMIT) ||
    !isUID(process.env.TEST_RUN_UID)) throw new Error('invalid source identity');
const commit = execFileSync('git', ['-C', source, '-c', 'core.hooksPath=/dev/null', 'rev-parse', 'HEAD'],
  {encoding: 'utf8', env: {PATH: '/usr/local/bin:/usr/bin:/bin', HOME: '/tmp'}}).trim();
const origin = execFileSync('git', ['-C', source, 'remote', 'get-url', 'origin'],
  {encoding: 'utf8', env: {PATH: '/usr/local/bin:/usr/bin:/bin', HOME: '/tmp'}}).trim();
if (commit !== process.env.TEST_COMMIT || origin !== registration.repositoryURL) throw new Error('cloned repository or commit mismatch');
for (const path of ['deploy', registration.recipeFile]) {
  if (lstatSync(resolve(source, path)).isSymbolicLink()) throw new Error('symbolic recipe path');
}
const recipeDigest = digest(readFileSync(resolve(source, registration.recipeFile)));
if (recipeDigest !== registration.recipeDigest || recipeDigest !== process.env.TEST_RECIPE_DIGEST) throw new Error('source recipe is not the reviewed recipe');
// Clone credentials lived in the clone container's /tmp. Remove Git metadata
// before any repository code runs, including credentials a remote URL could hold.
rmSync(join(source, '.git'), {recursive: true, force: true});
if (registration.recipe.packageManager !== 'none' || registration.recipe.dependencyRoots.length) {
  throw new Error('required credential-isolated dependency profile is not available');
}
function giveSourceToChild(path) {
  const file = lstatSync(path);
  // chown follows symlinks; lchown does not let a source link retitle results.
  lchownSync(path, 1001, 1001);
  if (file.isDirectory()) for (const name of readdirSync(path)) giveSourceToChild(join(path, name));
}
giveSourceToChild(source);
writeFileSync(process.env.TEST_RECIPE_RESULT_PATH, recipeDigest, {mode: 0o600});
