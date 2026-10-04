import {readFileSync, writeFileSync, lstatSync, realpathSync, rmSync, readdirSync, lchownSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
import {digest, isCommit, isUID} from './test-contract.mjs';
import {prepareStaticTools, preparePackageTools} from './test-tools.mjs';
import {fetchPackages} from './test-package-fetch.mjs';

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
// Existing static checks need the tracked-file list and immutable HEAD. Keep
// those, replacing all clone configuration and hooks before source execution.
const git = join(source, '.git');
if (!lstatSync(git).isDirectory() || lstatSync(git).isSymbolicLink()) throw new Error('invalid Git metadata');
rmSync(join(git, 'hooks'), {recursive: true, force: true});
writeFileSync(join(git, 'config'), '[core]\n repositoryformatversion = 0\n bare = false\n hooksPath = /dev/null\n[remote "origin"]\n url = ' + registration.repositoryURL + '\n', {mode: 0o600});
const dependencies = realpathSync(process.env.TEST_DEPENDENCIES);
if (registration.recipe.packageManager === 'pnpm@11.7.0') {
  if (process.env.TEST_PACKAGE_MANAGER_VERSION !== '11.7.0' || process.env.TEST_REGISTRY_SCOPE !== 'digitaplatform') {
    throw new Error('package-manager identity mismatch');
  }
  await preparePackageTools(join(dependencies, 'tools'));
  await fetchPackages(source, registration.recipe.dependencyRoots, dependencies, '/npmrc/.npmrc');
} else if (registration.recipe.packageManager !== 'none' || registration.recipe.dependencyRoots.length) {
  throw new Error('unsupported dependency profile');
}
if (registration.recipe.runtime === 'helm' || registration.recipe.suites.some(suite => suite.kind === 'static')) {
  await prepareStaticTools(join(dependencies, 'bin'));
}
function giveSourceToChild(path) {
  const file = lstatSync(path);
  // chown follows symlinks; lchown does not let a source link retitle results.
  lchownSync(path, 1001, 1001);
  if (file.isDirectory()) for (const name of readdirSync(path)) giveSourceToChild(join(path, name));
}
giveSourceToChild(source);
writeFileSync(process.env.TEST_RECIPE_RESULT_PATH, recipeDigest, {mode: 0o600});
